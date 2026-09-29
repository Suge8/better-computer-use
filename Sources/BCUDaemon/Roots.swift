/// Root discovery and selection: find-roots, the root observe-ui picks, and the current state
/// of a saved observation's root. A root's `@r` ref follows the platform's identity of it.
import BCUCore
import BCUPlatform
import Foundation

/// Score gap that makes one candidate an unambiguous winner.
private let decisiveScoreGap = 25

private let currentRootGone = "The controlled root is gone. Run observe-ui to choose a current root."

extension Daemon {
	func apps() async throws -> [RunningApp] {
		try await offload { [desktop = self.desktop] in desktop.listApps() }
	}

	func roots(pid: Int32? = nil, title: String? = nil) async throws -> [Root] {
		try await offload { [desktop = self.desktop] in desktop.listRoots(pid: pid, title: title) }
	}

	/// Names a root and mints or keeps its `@r` ref.
	func target(_ root: Root, appName: String, bundleId: String?) -> Target {
		let ref = rootRefs.ref(for: RegisteredRoot(handle: root.handle, pid: root.pid, appName: appName, bundleId: bundleId))
		return Target(root: root, ref: ref, appName: appName, bundleId: bundleId)
	}

	func target(_ root: Root, in app: RunningApp) -> Target {
		target(root, appName: app.appName, bundleId: app.bundleId)
	}

	/// A root the platform reported on its own, as an action's successor names it.
	func appearance(of root: Root) -> RootAppearance? {
		guard root.pid > 0 else { return nil }
		return target(root, appName: root.appName, bundleId: root.bundleId).appearance
	}

	// MARK: find-roots

	func findRoots(_ params: FindParams) async throws -> FindRootsResult {
		let app = trimmed(params.app)
		let bundleId = trimmed(params.bundleId)
		let broad = app == nil && bundleId == nil && params.pid == nil
		var discovered: [Target]
		if broad {
			discovered = try await roots().filter { $0.pid > 0 }.map { target($0, appName: $0.appName, bundleId: $0.bundleId) }
		} else {
			discovered = []
			for match in appsMatching(try await apps(), app: app, bundleId: bundleId, pid: params.pid) {
				discovered += try await roots(pid: match.pid).map { target($0, in: match) }
			}
		}
		discovered = stableSorted(discovered) { lhs, rhs in
			let (left, right) = (selectionScore(lhs.root), selectionScore(rhs.root))
			if left != right { return left > right }
			if lhs.appName != rhs.appName { return lhs.appName.localizedCompare(rhs.appName) == .orderedAscending }
			return lhs.title.localizedCompare(rhs.title) == .orderedAscending
		}
		// A menu bar only answers in the frontmost app, so an undirected listing would fill up
		// with roots the agent cannot press. It appears when an app or the kind names it.
		let wantsMenuBars = !broad || params.kind == .menubar
		let forest = discovered.filter { (wantsMenuBars || $0.root.kind != .menubar) && (params.kind == nil || $0.root.kind == params.kind) }
		let query = normalized(params.query)
		let exact = query.isEmpty ? [] : forest.filter { normalized($0.appName) == query || normalized($0.title) == query }
		let fuzzy = query.isEmpty || !exact.isEmpty ? [] : forest.filter { "\(normalized($0.appName)) \(normalized($0.title))".contains(query) }
		let listed = stableSorted(!exact.isEmpty ? exact : !fuzzy.isEmpty ? fuzzy : forest) { lhs, rhs in
			if lhs.root.isFocused != rhs.root.isFocused { return lhs.root.isFocused }
			if lhs.root.zOrder != rhs.root.zOrder { return lhs.root.zOrder < rhs.root.zOrder }
			return lhs.appName.localizedCompare(rhs.appName) == .orderedAscending
		}
		return FindRootsResult(roots: listed.map(rootInfo))
	}

	private func rootInfo(_ target: Target) -> RootInfo {
		let frame = target.root.framePoints
		return RootInfo(
			ref: target.ref, app: target.appName, bundleId: target.bundleId, pid: Int(target.pid), title: target.title,
			windowId: target.windowId, kind: target.root.kind,
			frame: Frame(x: jsRound(frame.origin.x), y: jsRound(frame.origin.y), w: jsRound(max(1, frame.width)), h: jsRound(max(1, frame.height))),
			focused: target.root.isFocused, main: target.root.isMain, onscreen: target.root.isOnscreen,
			minimized: target.root.isMinimized, modal: target.root.isModal
		)
	}

	// MARK: observe-ui selection

	/// The root `observe-ui` names by `--root`, by `--app` and `--window-title`, or, with
	/// neither, the frontmost app's most prominent window.
	func observedTarget(_ params: ObserveParams) async throws -> Target {
		if let root = params.root { return try await target(named: root) }
		let app = trimmed(params.app)
		let windowTitle = trimmed(params.windowTitle)
		if let app {
			let chosen = try chooseApp(try await apps(), query: app)
			let windows = try await roots(pid: chosen.pid)
			if windows.isEmpty { throw noControllableRoot(chosen.appName) }
			let window = try windowTitle.map { try chooseWindow(windows.filter(isSelectable), title: $0, appName: chosen.appName) } ?? choosePreferred(windows, appName: chosen.appName)
			return target(window, in: chosen)
		}
		if let windowTitle { return try await target(titled: windowTitle) }
		return try await frontmostTarget()
	}

	private func target(named selector: String) async throws -> Target {
		guard let name = trimmed(selector) else { throw BCUError(.invalidArguments, "--root requires a non-empty @r ref or numeric windowId.") }
		if let registered = rootRefs.root(name) {
			guard let root = try await roots(pid: registered.pid).first(where: { $0.handle == registered.handle }) else {
				throw BCUError(.windowStale, "Root ref '\(name)' is stale. Run find-roots again and choose a current root.")
			}
			return target(root, appName: registered.appName, bundleId: registered.bundleId)
		}
		if let windowId = Int(name), windowId > 0 {
			for app in try await apps() {
				if let root = try await roots(pid: app.pid).first(where: { $0.windowId.map(Int.init) == windowId }) { return target(root, in: app) }
			}
			throw BCUError(.windowStale, "Window id '\(windowId)' was not found. Run find-roots again and choose a current root.")
		}
		if name.hasPrefix("@r") {
			throw BCUError(.windowStale, "Root ref '\(name)' is not available in this session. Run find-roots first.")
		}
		var candidates: [Target] = []
		for app in try await apps() { candidates += try await roots(pid: app.pid).map { target($0, in: app) } }
		let query = normalized(name)
		let exact = candidates.filter { normalized($0.appName) == query || normalized($0.title) == query }
		let fuzzy = !exact.isEmpty ? exact : candidates.filter { "\(normalized($0.appName)) \(normalized($0.title))".contains(query) }
		let ranked = stableSorted(fuzzy) { lhs, rhs in
			if lhs.root.isFocused != rhs.root.isFocused { return lhs.root.isFocused }
			return lhs.root.zOrder < rhs.root.zOrder
		}
		guard let match = ranked.first else {
			throw BCUError(.windowStale, "Root query '\(name)' did not match any current root. Run find-roots to list roots.")
		}
		return match
	}

	private func target(titled title: String) async throws -> Target {
		let query = normalized(title)
		var exact: [Target] = [], partial: [Target] = []
		func collect(_ root: Root, appName: String, bundleId: String?) {
			let candidate = normalized(root.title)
			guard !candidate.isEmpty, isSelectable(root) else { return }
			if candidate == query { exact.append(target(root, appName: appName, bundleId: bundleId)) }
			else if candidate.contains(query) { partial.append(target(root, appName: appName, bundleId: bundleId)) }
		}
		for root in try await roots(title: title) where root.pid > 0 { collect(root, appName: root.appName, bundleId: root.bundleId) }
		// A freshly created or off-Space window can be missing from the window server's title
		// index for a moment; complete discovery is the cold fallback, not a false miss.
		if exact.isEmpty && partial.isEmpty {
			for app in try await apps() {
				for root in try await roots(pid: app.pid) { collect(root, appName: app.appName, bundleId: app.bundleId) }
			}
		}
		let ranked = stableSorted(exact.isEmpty ? partial : exact) { selectionScore($0.root) > selectionScore($1.root) }
		guard let best = ranked.first else { throw BCUError(.windowStale, "Window '\(title)' was not found in any running app.") }
		if ranked.count > 1, selectionScore(best.root) < selectionScore(ranked[1].root) + decisiveScoreGap {
			let options = ranked.prefix(6).map { "\($0.appName) — \(summary($0.root))" }.joined(separator: ", ")
			throw BCUError(.invalidArguments, "Window title '\(title)' is ambiguous (\(options)). Specify --app as well.")
		}
		return best
	}

	private func frontmostTarget() async throws -> Target {
		let frontmost = try await offload { [desktop = self.desktop] in try desktop.frontmost() }
		let app = try await apps().first { $0.pid == frontmost.pid }
		let appName = app?.appName ?? frontmost.appName
		let windows = try await roots(pid: frontmost.pid)
		if windows.isEmpty { throw noControllableRoot(appName) }
		let chosen = try windows.first { $0.handle == frontmost.window?.handle } ?? choosePreferred(windows, appName: appName)
		return target(chosen, appName: appName, bundleId: app?.bundleId ?? frontmost.bundleId)
	}

	// MARK: a saved observation's root

	/// The observation's root as it is now; it must still exist. A modal in front of it is a
	/// new root, never swapped in, or the next action would be judged against the wrong root.
	func current(_ observed: Target) async throws -> Target {
		let windows = try await roots(pid: observed.pid)
		if windows.isEmpty { throw noControllableRoot(observed.appName) }
		guard let root = windows.first(where: { $0.handle == observed.root.handle }) else {
			throw BCUError(.windowStale, currentRootGone)
		}
		return target(root, appName: observed.appName, bundleId: observed.bundleId)
	}

	func isLive(_ observed: Target) async throws -> Bool {
		try await roots(pid: observed.pid).contains { $0.handle == observed.root.handle }
	}

	/// The root bcu would pick in the app of a closed root now, if the app still shows one.
	func preferredRoot(after closed: Target) async throws -> Target? {
		let selectable = try await roots(pid: closed.pid).filter { isSelectable($0) && $0.handle != closed.root.handle }
		guard !selectable.isEmpty else { return nil }
		return target(try choosePreferred(selectable, appName: closed.appName), appName: closed.appName, bundleId: closed.bundleId)
	}
}

// MARK: - selection rules

/// How prominent a root is: modal first, then focus, main, visibility and a window id.
func selectionScore(_ root: Root) -> Int {
	var score = 0
	if root.isModal { score += 180 }
	if root.isFocused { score += 100 }
	if root.isMain { score += 80 }
	if !root.isMinimized { score += 40 }
	if root.isOnscreen { score += 20 }
	if (root.windowId ?? 0) > 0 { score += 10 }
	if !root.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 2 }
	return score
}

/// The desktop and an app's menu bar are roots an agent can observe on request, never ones bcu picks for it.
private func isSelectable(_ root: Root) -> Bool {
	root.subrole != "AXDesktop" && root.kind != .menubar
}

/// The app is alive but shows nothing bcu can drive; that is a window problem, not a bug.
private func noControllableRoot(_ appName: String) -> BCUError {
	BCUError(.windowStale, "App '\(appName)' is running but has no controllable window. Open a window in it, or run find-roots and observe another root.")
}

private func choosePreferred(_ windows: [Root], appName: String) throws -> Root {
	guard let best = stableSorted(windows.filter(isSelectable), by: { selectionScore($0) > selectionScore($1) }).first else {
		throw noControllableRoot(appName)
	}
	return best
}

private func summary(_ root: Root) -> String {
	let flags = [root.isFocused ? "focused" : nil, root.isMain ? "main" : nil, root.isOnscreen ? "onscreen" : nil, root.isMinimized ? "minimized" : nil].compactMap { $0 }.joined(separator: ",")
	return "\(root.title.isEmpty ? "(untitled)" : root.title) [score=\(selectionScore(root))\(flags.isEmpty ? "" : ", \(flags)")]"
}

private func summaries(_ windows: [Root]) -> String {
	stableSorted(windows) { selectionScore($0) > selectionScore($1) }.prefix(6).map(summary).joined(separator: "; ")
}

private func clearWinner(_ candidates: [Root]) -> Root? {
	let ranked = stableSorted(candidates.filter(isSelectable)) { selectionScore($0) > selectionScore($1) }
	guard let first = ranked.first else { return nil }
	if ranked.count == 1 { return first }
	return selectionScore(first) >= selectionScore(ranked[1]) + decisiveScoreGap ? first : nil
}

private func chooseWindow(_ windows: [Root], title: String, appName: String) throws -> Root {
	let query = normalized(title)
	let exact = windows.filter { normalized($0.title) == query }
	if exact.count == 1 { return exact[0] }
	if exact.count > 1 {
		if let winner = clearWinner(exact) { return winner }
		throw BCUError(.invalidArguments, "Window title '\(title)' is ambiguous in app '\(appName)'. Candidates: \(summaries(exact)).")
	}
	let partial = windows.filter { normalized($0.title).contains(query) }
	if partial.isEmpty {
		throw BCUError(.windowStale, "Window '\(title)' was not found in app '\(appName)'. Available windows: \(summaries(windows)).")
	}
	if partial.count == 1 { return partial[0] }
	if let winner = clearWinner(partial) { return winner }
	throw BCUError(.invalidArguments, "Window title '\(title)' is ambiguous in app '\(appName)'. Candidates: \(summaries(partial)).")
}

private func appNames(_ app: RunningApp) -> [String] {
	let bundleId = normalized(app.bundleId)
	return [normalized(app.appName), bundleId, bundleId.split(separator: ".").last.map(String.init) ?? ""].filter { !$0.isEmpty }
}

private func appMatches(_ app: RunningApp, _ query: String, exact: Bool = false) -> Bool {
	let query = normalized(query)
	return appNames(app).contains { exact ? $0 == query : $0.contains(query) }
}

/// An exact app name wins over the longer names that contain it ("Google Chrome" vs "Google Chrome for Testing").
private func appsMatching(_ apps: [RunningApp], app: String?, bundleId: String?, pid: Int?) -> [RunningApp] {
	let matching = apps.filter { candidate in
		if let pid, Int(candidate.pid) != pid { return false }
		if let bundleId, normalized(candidate.bundleId) != normalized(bundleId) { return false }
		if let app, !appMatches(candidate, app) { return false }
		return true
	}
	let exact = app.map { query in matching.filter { appMatches($0, query, exact: true) } } ?? []
	return exact.isEmpty ? matching : exact
}

private func chooseApp(_ apps: [RunningApp], query: String) throws -> RunningApp {
	let exact = apps.filter { appMatches($0, query, exact: true) }
	if exact.count == 1 { return exact[0] }
	if exact.count > 1 { return exact.first { $0.isFrontmost } ?? exact[0] }
	let partial = apps.filter { appMatches($0, query) }
	if partial.isEmpty {
		let running = apps.prefix(12).map(\.appName).joined(separator: ", ")
		throw BCUError(.appNotFound, "App '\(query)' is not running. Running apps: \(running.isEmpty ? "none" : running).")
	}
	if partial.count == 1 { return partial[0] }
	throw BCUError(.invalidArguments, "App name '\(query)' is ambiguous (\(partial.map(\.appName).joined(separator: ", "))). Use a more specific app name.")
}

// MARK: - text rules

/// The trimmed value, or nil when it is absent or blank.
func trimmed(_ value: String?) -> String? {
	guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
	return value
}

func normalized(_ value: String?) -> String {
	(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// `Math.round`: halves round up, toward positive infinity.
func jsRound(_ value: Double) -> Double {
	(value + 0.5).rounded(.down)
}

/// Sorts keeping the original order of elements the comparison calls equal.
func stableSorted<T>(_ values: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
	values.enumerated().sorted { lhs, rhs in
		if areInIncreasingOrder(lhs.element, rhs.element) { return true }
		if areInIncreasingOrder(rhs.element, lhs.element) { return false }
		return lhs.offset < rhs.offset
	}.map(\.element)
}
