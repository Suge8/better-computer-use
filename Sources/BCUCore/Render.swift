/// The text view of each command result. `--json` prints the same result object instead.

func render(_ result: CommandResult) throws -> String {
	switch result {
	case .findRoots(let result): result.roots.isEmpty ? "no roots are visible to bcu" : result.roots.map(rootLine).joined(separator: "\n")
	case .observeUi(let result): lines([
			renderObservation(ObservationView(stateId: result.stateId, root: ObservationRoot(ref: result.root.ref, app: result.root.app, title: result.root.title), nodes: result.nodes, shown: result.shown, total: result.total)),
			imageLine(result.image),
		])
	case .searchUi(let result): (["\(result.matches.count) of \(result.total) matches · state \(result.stateId)"] + result.matches.map { match in
			renderNode(match.node) + (match.path.last.map { " in \($0)" } ?? "")
		}).joined(separator: "\n")
	case .expandUi(let result): lines(["\(result.ref) · state \(result.stateId)", renderNodes(result.nodes)])
	case .inspectUi(let result): try JSONCoding.string(result.node, pretty: true)
	case .actUi(let result): renderAct(result)
	case .readText(let result): "\(result.ref) \(result.offset)-\(result.offset + result.text.count) of \(result.total)\n\(result.text)"
	case .waitFor(let result): lines([
			"state \(result.stateId) · \(result.gone == true ? "gone" : "found")",
			successorLines(changes: result.changes, offscreen: result.offscreen, nodes: result.nodes),
		])
	}
}

/// Non-empty lines joined.
private func lines(_ parts: [String]) -> String {
	parts.filter { !$0.isEmpty }.joined(separator: "\n")
}

private func number(_ value: Double) -> String {
	Text.number(value)
}

private func rootLine(_ root: RootInfo) -> String {
	let flags = [
		root.focused ? "focused" : nil,
		root.main ? "main" : nil,
		root.modal ? "modal" : nil,
		root.onscreen ? "onscreen" : nil,
		root.minimized ? "minimized" : nil,
	].compactMap { $0 }.joined(separator: " ")
	let id = root.windowId.flatMap { $0 != 0 ? "id \($0)" : nil } ?? "no window id"
	let frame = "\(number(root.frame.x)),\(number(root.frame.y)) \(number(root.frame.w))x\(number(root.frame.h))"
	return "\(root.ref) \(root.kind.rawValue) \(root.app) \(Text.quote(root.title)) · pid \(root.pid) · \(id) · \(frame) · \(flags)"
}

private func imageLine(_ image: ImageInfo?) -> String {
	image.map { "image \($0.path) (\($0.width)x\($0.height))" } ?? ""
}

private func successorLines(changes: [Change]?, offscreen: OffscreenChanges?, nodes: [ProjectedNode]?) -> String {
	if let nodes { return renderNodes(nodes) }
	guard let changes else { return "" }
	let text = lines([renderChanges(changes), renderOffscreen(offscreen)])
	return text.isEmpty ? "(no element changes)" : text
}

private func rootWords(_ root: RootAppearance) -> String {
	"\(root.ref) \(root.kind.rawValue) \(Text.quote(root.title))"
}

/// An opened root reads like the observe-ui of it.
private func openedLines(_ opened: OpenedRoot) -> String {
	renderObservation(ObservationView(
		stateId: opened.stateId, root: ObservationRoot(ref: opened.root.ref, app: opened.root.app, title: opened.root.title),
		nodes: opened.nodes, shown: opened.shown, total: opened.total
	))
}

/// The platform's reason for the outcome, as it reported it.
private func evidenceWords(_ evidence: ActEvidence?) -> String {
	guard let evidence else { return "" }
	if evidence.source == .screen { return " · screen changed" }
	if evidence.source == .root, evidence.field == .closed { return " · root closed" }
	if let field = evidence.field, let from = evidence.from, let to = evidence.to { return " · \(field.rawValue) \(from)→\(to)" }
	return " · \(evidence.field?.rawValue ?? evidence.source.rawValue)"
}

/// A closed root leads, since the refs of the base state went with it; then where to go next.
private func renderAct(_ result: ActResult) -> String {
	let verified = result.verification.status == .verified ? " · verified" + (result.verification.preexisting == true ? " (preexisting)" : "") : ""
	let outcome = result.outcome == .unknown ? "unverified" : result.outcome.rawValue
	var parts = ["state \(result.stateId ?? "none") ← \(result.baseStateId) · \(outcome) via \(result.delivery)\(evidenceWords(result.verification.evidence))\(verified)"]
	if let closed = result.closed { parts.append("- root \(rootWords(closed.root))") }
	parts += (result.roots ?? []).map { "+ root \(rootWords($0))" }
	if let closed = result.closed {
		let skipped = closed.skipped ?? 0
		if skipped > 0 { parts.append("skipped \(skipped) later step\(skipped == 1 ? "" : "s"): its root closed") }
		if let next = result.next {
			parts.append("next root \(rootWords(next))")
		} else if result.stateId == nil {
			parts.append("no root of \(closed.root.app) remains; run find-roots")
		}
	}
	parts.append(successorLines(changes: result.changes, offscreen: result.offscreen, nodes: result.nodes))
	parts.append(imageLine(result.image))
	parts.append(result.opened.map(openedLines) ?? "")
	return lines(parts)
}
