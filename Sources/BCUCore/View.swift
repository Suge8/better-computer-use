/// What changed between two states of one root, and how a successor state is shown: a diff
/// when node identity holds, the full folded view otherwise.

/// `state` names the words that moved, e.g. `["onscreen"]`, not the whole state object.
public struct ChangedFields: Codable, Sendable, Equatable {
	public var role: String?
	public var name: String?
	/// `.some(nil)`: the value went away.
	public var value: String??
	public var caps: [Capability]?
	public var state: [String]?

	var count: Int { [role != nil, name != nil, value != nil, caps != nil, state != nil].filter { $0 }.count }

	enum CodingKeys: String, CodingKey { case role, name, value, caps, state }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		role = try container.decodeIfPresent(String.self, forKey: .role)
		name = try container.decodeIfPresent(String.self, forKey: .name)
		value = container.contains(.value) ? .some(try container.decodeIfPresent(String.self, forKey: .value)) : nil
		caps = try container.decodeIfPresent([Capability].self, forKey: .caps)
		state = try container.decodeIfPresent([String].self, forKey: .state)
	}

	init() {}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encodeIfPresent(role, forKey: .role)
		try container.encodeIfPresent(name, forKey: .name)
		if case .some(.some(let value)) = value { try container.encode(value, forKey: .value) }
		try container.encodeIfPresent(caps, forKey: .caps)
		try container.encodeIfPresent(state, forKey: .state)
	}
}

public enum Change: Codable, Sendable, Equatable {
	case added(ref: String, parent: String?, node: ProjectedNode)
	case updated(ref: String, fields: ChangedFields)
	case removed(ref: String, parent: String?)

	enum CodingKeys: String, CodingKey { case type, ref, parent, node, fields }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let ref = try container.decode(String.self, forKey: .ref)
		switch try container.decode(String.self, forKey: .type) {
		case "added": self = .added(ref: ref, parent: try container.decodeIfPresent(String.self, forKey: .parent), node: try container.decode(ProjectedNode.self, forKey: .node))
		case "updated": self = .updated(ref: ref, fields: try container.decode(ChangedFields.self, forKey: .fields))
		case "removed": self = .removed(ref: ref, parent: try container.decodeIfPresent(String.self, forKey: .parent))
		case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown change type '\(other)'")
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .added(let ref, let parent, let node):
			try container.encode("added", forKey: .type)
			try container.encode(ref, forKey: .ref)
			try container.encodeIfPresent(parent, forKey: .parent)
			try container.encode(node, forKey: .node)
		case .updated(let ref, let fields):
			try container.encode("updated", forKey: .type)
			try container.encode(ref, forKey: .ref)
			try container.encode(fields, forKey: .fields)
		case .removed(let ref, let parent):
			try container.encode("removed", forKey: .type)
			try container.encode(ref, forKey: .ref)
			try container.encodeIfPresent(parent, forKey: .parent)
		}
	}
}

/// Offscreen elements outside the view that came and went; they get no change of their own.
public struct OffscreenChanges: Codable, Sendable, Equatable {
	public var added: Int
	public var removed: Int
}

public struct Transition: Codable, Sendable, Equatable {
	public var changes: [Change]
	public var offscreen: OffscreenChanges
	/// True when the successor is too different to describe as a diff.
	public var useFullView: Bool
}

/// Names every state word that moved, so a diff line never reads just "changed": what the
/// word says when it turns on, and what it says when it turns off.
private func changedStateWords(_ before: ProjectedState?, _ after: ProjectedState?) -> [String] {
	let flags: [(Bool?, Bool?, on: String, off: String)] = [
		(before?.focused, after?.focused, "focused", "unfocused"),
		(before?.offscreen, after?.offscreen, "offscreen", "onscreen"),
		(before?.truncated, after?.truncated, "truncated", "complete"),
	]
	var words: [String] = []
	for (was, now, on, off) in flags where (was == true) != (now == true) {
		words.append(now == true ? on : off)
	}
	let scroll = after?.scroll
	if before?.scroll != scroll { words.append(scroll.map { "scroll \($0.seen)/\($0.total)" } ?? "scroll end") }
	return words
}

private func changedFields(_ before: ProjectedNode, _ after: ProjectedNode) -> ChangedFields {
	var fields = ChangedFields()
	if before.role != after.role { fields.role = after.role }
	if before.name != after.name { fields.name = after.name }
	if before.value != after.value { fields.value = .some(after.value) }
	if before.caps != after.caps { fields.caps = after.caps }
	let state = changedStateWords(before.state, after.state)
	if !state.isEmpty { fields.state = state }
	return fields
}

/// Scrolling in and out of sight is not news about a node the view does not show.
private func isInvisibleVisibilityFlip(_ fields: ChangedFields, _ ref: String, _ visible: Set<String>?) -> Bool {
	guard let visible, !visible.contains(ref), fields.count == 1, let state = fields.state else { return false }
	return state.allSatisfy { $0 == "onscreen" || $0 == "offscreen" }
}

/// Refs that are offscreen themselves or sit under an offscreen node, such as a closed menu's items.
private func offscreenRefs(_ nodes: [ProjectedNode]) -> Set<String> {
	var offscreen = Set<String>()
	for node in nodes where node.state?.offscreen == true || node.parent.map(offscreen.contains) == true { offscreen.insert(node.ref) }
	return offscreen
}

/// Menus and everything inside them; a menu bar item is not inside a menu.
private func menuTreeRefs(_ nodes: [ProjectedNode]) -> Set<String> {
	var inMenu = Set<String>()
	for node in nodes where node.role == "menu" || node.parent.map(inMenu.contains) == true { inMenu.insert(node.ref) }
	return inMenu
}

/// Compares two unfolded projections of the same root; `visible` is what the successor view
/// will show and `baseVisible` what the base view showed. An offscreen node outside the view
/// on its side of the change is counted, not listed, and so is the menu tree bcu's own menu
/// opening moved.
public func changesBetween(_ base: [ProjectedNode], _ next: [ProjectedNode], visible: Set<String>?, baseVisible: Set<String>? = nil, menusOpenedByBcu: Bool = false) -> Transition {
	let before = Dictionary(base.map { ($0.ref, $0) }, uniquingKeysWith: { $1 })
	let after = Set(next.map(\.ref))
	let quietAfter = offscreenRefs(next)
	let quietBefore = offscreenRefs(base)
	let menuAfter = menusOpenedByBcu ? menuTreeRefs(next) : []
	let menuBefore = menusOpenedByBcu ? menuTreeRefs(base) : []
	var changes: [Change] = []
	var offscreen = OffscreenChanges(added: 0, removed: 0)
	for node in next {
		guard let previous = before[node.ref] else {
			if menuAfter.contains(node.ref) || (visible.map { !$0.contains(node.ref) } == true && quietAfter.contains(node.ref)) {
				offscreen.added += 1
			} else {
				changes.append(.added(ref: node.ref, parent: node.parent, node: node))
			}
			continue
		}
		let fields = changedFields(previous, node)
		if fields.count == 0 || isInvisibleVisibilityFlip(fields, node.ref, visible) { continue }
		changes.append(.updated(ref: node.ref, fields: fields))
	}
	for node in base where !after.contains(node.ref) {
		if menuBefore.contains(node.ref) || (baseVisible.map { !$0.contains(node.ref) } == true && quietBefore.contains(node.ref)) {
			offscreen.removed += 1
		} else {
			changes.append(.removed(ref: node.ref, parent: node.parent))
		}
	}

	let rootReplaced = base.first?.ref != next.first?.ref || base.first?.role != next.first?.role
	let kept = next.filter { before[$0.ref] != nil }.count
	let identityLow = next.count > 8 && Double(kept) / Double(next.count) < 0.4
	let overBudget = changes.count > 40 || (changes.count > 20 && Double(changes.count) / Double(max(1, base.count, next.count)) > 0.65)
	return Transition(changes: changes, offscreen: offscreen, useFullView: rootReplaced || identityLow || overBudget)
}

private func renderFields(_ fields: ChangedFields) -> String {
	let parts = [
		fields.role,
		fields.name.map(Text.quote),
		fields.value.flatMap { $0 }.map { "=" + Text.quote($0) },
		fields.caps.map { "{" + $0.map(\.rawValue).joined(separator: ",") + "}" },
		fields.state?.joined(separator: " "),
	].compactMap { $0 }.filter { !$0.isEmpty }
	return parts.isEmpty ? "changed" : parts.joined(separator: " ")
}

public func renderOffscreen(_ offscreen: OffscreenChanges?) -> String {
	guard let offscreen else { return "" }
	let counts = [offscreen.added > 0 ? "\(offscreen.added) added" : "", offscreen.removed > 0 ? "\(offscreen.removed) removed" : ""].filter { !$0.isEmpty }
	return counts.isEmpty ? "" : "… offscreen elements outside the view: " + counts.joined(separator: ", ")
}

public func renderChanges(_ changes: [Change]) -> String {
	changes.map { change in
		switch change {
		case .added(let ref, let parent, let node): "+ \(ref)\(parent.map { " in \($0)" } ?? "") \(renderNodeBody(node))"
		case .removed(let ref, _): "- \(ref)"
		case .updated(let ref, let fields): "~ \(ref) \(renderFields(fields))"
		}
	}.joined(separator: "\n")
}

/// A successor state as a result carries it: a diff, or the full folded view.
public struct SuccessorView: Codable, Sendable, Equatable {
	public var changes: [Change]?
	public var offscreen: OffscreenChanges?
	public var nodes: [ProjectedNode]?
	public var shown: Int?
	public var total: Int?
}

private func viewRefs(_ outline: Outline, omitting: Set<String> = []) -> Set<String> {
	Set(project(outline, ProjectOptions(omitting: omitting)).nodes.map(\.ref))
}

/// The whole folded view of a root, for a successor that is not a diff of its base.
public func fullView(_ outline: Outline, omitting: Set<String> = []) -> SuccessorView {
	let folded = project(outline, ProjectOptions(omitting: omitting))
	return SuccessorView(nodes: folded.nodes, shown: folded.shown, total: folded.total)
}

/// An act-ui result carries the view of a root it opened, so the view is held to this many
/// nodes; search-ui over the root's stateId reaches what it leaves out.
private let openedViewMaxNodes = 60

/// The view of a root an action opened: the observe-ui view under a node budget.
public func openedView(_ outline: Outline) -> SuccessorView {
	let folded = project(outline, ProjectOptions(maxNodes: openedViewMaxNodes))
	return SuccessorView(nodes: folded.nodes, shown: folded.shown, total: folded.total)
}

/// Successor view of a state transition: a diff when identity holds, the full view otherwise.
/// `menusOpenedByBcu`: bcu opened and closed menus to act, so the menu tree it moved is not news.
/// `omitting`, `baseOmitting`: refs of `next` and of `base` that are another root's tree, such as a
/// menu hanging under its popup; that root is reported as itself, so here it is neither new nor gone.
public func successorView(base: Outline, next: Outline, menusOpenedByBcu: Bool = false, omitting: Set<String> = [], baseOmitting: Set<String> = []) -> SuccessorView {
	var nextOptions = ProjectOptions.unfolded
	nextOptions.omitting = omitting
	var baseOptions = ProjectOptions.unfolded
	baseOptions.omitting = baseOmitting
	let transition = changesBetween(
		project(base, baseOptions).nodes,
		project(next, nextOptions).nodes,
		visible: viewRefs(next, omitting: omitting),
		baseVisible: viewRefs(base, omitting: baseOmitting),
		menusOpenedByBcu: menusOpenedByBcu
	)
	if transition.useFullView { return fullView(next, omitting: omitting) }
	let quiet = transition.offscreen.added + transition.offscreen.removed > 0
	return SuccessorView(changes: transition.changes, offscreen: quiet ? transition.offscreen : nil)
}
