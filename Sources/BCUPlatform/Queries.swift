import AppKit
import BCUCore

extension Platform {
	/// Waits until an element matching role, text or value appears in the root (or, with
	/// `gone`, until none does), re-reading the tree whenever the app reports a change.
	public func waitFor(_ request: WaitForRequest) throws -> WaitOutcome {
		let pid = request.pid
		requestAccessibility(pid: pid)
		let role = request.role?.trimmingCharacters(in: .whitespacesAndNewlines)
		let text = request.text.map { foldedForSearch($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
		let expectedValue = request.value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let timeoutMs = max(Self.waitTimeoutRange.lowerBound, min(Self.waitTimeoutRange.upperBound, request.timeoutMs ?? Self.defaultWaitTimeoutMs))
		guard role?.isEmpty == false || text?.isEmpty == false || expectedValue?.isEmpty == false else {
			throw BCUError(.invalidArguments, "A wait needs a role, text, or value.")
		}
		guard let window = resolveRoot(pid: pid, windowId: nil, root: request.root) else {
			return .rootNotFound
		}
		let rootElement: AXUIElement
		if let scope = request.scope {
			guard let scoped = scope.elementRecord?.element.element, isElement(scoped, descendantOf: window) else {
				throw BCUError(.elementNotFound, "Condition scope ref is stale or outside the target root")
			}
			rootElement = scoped
		} else {
			rootElement = window
		}
		func matches(_ element: AXUIElement) -> Bool {
			let candidateRole = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
			if let role, !role.isEmpty, !roleMatches(role, role: candidateRole, subrole: stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? "") { return false }
			if let text, !text.isEmpty {
				let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
				let haystack = foldedForSearch([
					stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "",
					stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? "",
					displayValue(element, role: candidateRole, subrole: subrole),
				].joined(separator: "\n"))
				if !haystack.contains(text) { return false }
			}
			if let expectedValue, !expectedValue.isEmpty {
				let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
				if displayValue(element, role: candidateRole, subrole: subrole).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != expectedValue { return false }
			}
			return true
		}

		// Every look stops at the deadline, also the one a wait with no time left still makes.
		// A look cut short proves a match but not its absence.
		let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
		func found() -> Bool? {
			containsDescendant(startingAt: rootElement, until: deadline, where: matches)
		}
		let settled = try awaitChange(in: pid, timeout: Double(timeoutMs) / 1000) {
			request.gone ? found() == false : found() == true
		}
		guard settled else { return .timedOut }
		return request.gone ? .gone : .found
	}

	/// Where an app's stream of accessibility notifications stands, to wait for what comes
	/// after it. Take it before looking, so a change made during the look ends the wait at once.
	public func changeMark(pid: Int32) throws -> ChangeMark {
		ChangeMark(generation: try observedApp(pid).generation)
	}

	/// Returns after the app posts a notification or an app takes the front since `mark`, or
	/// after `timeoutMs`; the caller looks again either way.
	public func waitForChange(pid: Int32, since mark: ChangeMark, timeoutMs: Int) throws {
		let app = try observedApp(pid)
		_ = app.wait(until: Date().addingTimeInterval(Double(timeoutMs) / 1000)) { app.generation != mark.generation }
	}

	/// Starts watching the apps for the windows they open, retitle or focus, and returns where
	/// the desktop's changes stood when it started: such a window, an app launching, quitting
	/// or taking the front, or a notification of an observed app counts as a change. Apps that
	/// show windows are watched: regular apps, and others that own a window now; agents and
	/// helpers without one are left out, they take the front when they open one. One thread
	/// hosts an observer per app and registers them without the caller waiting: registering
	/// waits on each app's answer, a hung app's for the messaging timeout. Its end counts as a
	/// change, so a window opened before its app was registered is looked for again. Stop the
	/// watch when the wait is over.
	public func watchRoots(of pids: [Int32]) -> RootWatch {
		let signal = rootObservers.desktop
		let mark = ChangeMark(generation: signal.generation)
		let owners = Set(cgWindowOwners(entries: nil).map(\.pid))
		let watched = pids.filter { owners.contains($0) || NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
		guard !watched.isEmpty else { return RootWatch(mark: mark, thread: nil) }
		let thread = RunLoopThread.start { [self] in
			let observers = NSMutableArray()
			CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue) {
				for observer in watched.compactMap({ self.rootObserver(pid: $0, signal: signal) }) {
					observers.add(observer)
					CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
				}
				signal.bump()
			}
			return observers
		}
		return RootWatch(mark: mark, thread: thread)
	}

	/// Returns after a desktop change since `mark`, or after `timeoutMs`; the caller looks again either way.
	public func waitForDesktopChange(since mark: ChangeMark, timeoutMs: Int) {
		rootObservers.desktop.wait(since: mark.generation, until: Date().addingTimeInterval(Double(timeoutMs) / 1000))
	}

	/// A wait lasts 10 s unless asked otherwise, and at most 60 s. A caller whose own time has run
	/// out asks for 0: the condition is checked once.
	static let defaultWaitTimeoutMs = 10_000
	static let waitTimeoutRange = 0...60_000

	/// A page of an element's text value, counted in characters. Secure fields are refused.
	public func readText(_ handle: Handle, offset: Int, limit: Int) throws -> TextPage {
		let offset = max(0, offset)
		let limit = max(1, min(100_000, limit))
		guard let element = handle.elementRecord?.element.element else {
			throw BCUError(.elementNotFound, "Element reference is no longer valid")
		}
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		guard !isSecureTextElement(role: role, subrole: subrole) else {
			throw BCUError(.actionFailed, "Refers to a secure text field; refusing to read its value")
		}
		guard let value = stringAttribute(element, attribute: kAXValueAttribute as CFString) else {
			throw BCUError(.actionFailed, "Element has no readable AXValue. Call snapshot/screenshot and choose a text-bearing ref.")
		}
		let characters = Array(value)
		if offset >= characters.count {
			return TextPage(text: "", offset: offset, limit: limit, totalChars: characters.count, hasMore: false)
		}
		let end = min(characters.count, offset + limit)
		return TextPage(text: String(characters[offset..<end]), offset: offset, limit: limit, totalChars: characters.count, hasMore: end < characters.count)
	}
}
