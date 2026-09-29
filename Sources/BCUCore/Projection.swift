/// The agent's only view of an outline: short roles, a closed capability vocabulary, folded
/// entries, and a first view small enough to read. Text and `--json` render the same nodes.

/// The only capability words an agent ever sees; anything else stays inside the outline.
public enum Capability: String, CaseIterable, Codable, Sendable {
	case press, toggle, setText, typeText, menu, open, expand, scroll, increment, decrement, raise
}

public struct ProjectedState: Codable, Sendable, Equatable {
	public var focused: Bool?
	public var offscreen: Bool?
	public var truncated: Bool?
	public var scroll: ScrollExtent?
}

/// Descendants the render budget folded away; they stay expandable through expand-ui.
public struct HiddenSummary: Codable, Sendable, Equatable {
	public var count: Int
	public var roles: [String: Int]
}

public struct ProjectedNode: Codable, Sendable, Equatable {
	public var ref: String
	public var role: String
	public var name: String
	public var value: String?
	public var caps: [Capability]
	public var state: ProjectedState?
	/// Capabilities this node inherited from a merged descendant, and the ref that performs them.
	public var owners: [String: String]?
	public var depth: Int
	public var parent: String?
	public var hidden: HiddenSummary?
	/// Text lines a text input folds away: its value already says them, read-text reads them in full.
	public var lines: Int?
}

public struct Projection: Sendable {
	public var nodes: [ProjectedNode]
	public var shown: Int
	public var total: Int
	public var truncated: Bool
	/// Outline ref → the projected node that speaks for it. Dropped nodes are absent.
	public var represents: [String: String]
}

public struct ProjectOptions {
	public var maxDepth: Int?
	public var maxNodes: Int?
	public var unfold: [String] = []
	/// Projects this subtree instead of the whole root.
	public var from: OutlineNode?

	public init(maxDepth: Int? = nil, maxNodes: Int? = nil, unfold: [String] = [], from: OutlineNode? = nil) {
		self.maxDepth = maxDepth
		self.maxNodes = maxNodes
		self.unfold = unfold
		self.from = from
	}

	/// Diffs and cached queries compare complete projections; only the rendered view is folded.
	public static var unfolded: ProjectOptions { ProjectOptions(maxDepth: Int.max, maxNodes: Int.max) }
}

public struct ObservationRoot: Sendable {
	public var ref: String?
	public var app: String
	public var title: String

	public init(ref: String?, app: String, title: String) {
		self.ref = ref
		self.app = app
		self.title = title
	}
}

public struct ObservationView: Sendable {
	public var stateId: String
	public var root: ObservationRoot
	public var nodes: [ProjectedNode]
	public var shown: Int
	public var total: Int

	public init(stateId: String, root: ObservationRoot, nodes: [ProjectedNode], shown: Int, total: Int) {
		self.stateId = stateId
		self.root = root
		self.nodes = nodes
		self.shown = shown
		self.total = total
	}
}

private let maxNodes = 150
/// The first view grows one level at a time while it still fits this many bytes.
private let viewByteBudget = 900
private let maxAutoDepth = 8
private let maxNameCharacters = 120
private let maxValueCharacters = 160

/// Subrole words that are less useful than the role they specialize.
private let roleAliases: [String: String] = [
	"statictext": "text",
	"popupbutton": "popup",
	"radiobutton": "radio",
	"standardwindow": "window",
	"systemdialog": "dialog",
	"floatingwindow": "window",
	"systemfloatingwindow": "window",
	"dialogwindow": "dialog",
	"outlinerow": "row",
	"tablerow": "row",
	"menubaritem": "menuitem",
	"sortbutton": "button",
	"textattachment": "image",
]

private let actionCapabilities: [String: Capability] = [
	"axpress": .press,
	"axopen": .open,
	"axshowmenu": .menu,
	"axpick": .menu,
	"axexpand": .expand,
	"axdisclose": .expand,
	"axincrement": .increment,
	"axdecrement": .decrement,
	"axraise": .raise,
	"axscrollupbypage": .scroll,
	"axscrolldownbypage": .scroll,
	"axscrollleftbypage": .scroll,
	"axscrollrightbypage": .scroll,
]

/// Scrollbars and their arrows are never an agent's target; the scroll capability replaces them.
private let droppedRoles: Set<String> = ["scrollbar"]
private let structuralRoles: Set<String> = ["group", "splitgroup", "scrollarea", "cell", "column", "splitter", "scrollbar", "layoutarea", "layoutitem", "unknown", "matte"]
/// Roles that speak through the content they wrap; a window or a list never does.
private let absorbingRoles = structuralRoles.union(["row", "listitem", "tab", "link", "menuitem", "button", "checkbox", "radio"])
private let textRoles: Set<String> = ["textfield", "textarea", "combobox", "searchfield"]
/// Role words whose press flips a value. The platform judges the same family by AX role and subrole.
private let toggleRoles: Set<String> = ["checkbox", "radio", "switch", "disclosuretriangle", "togglebutton", "segment"]

private struct Tree {
	var ref: String
	var role: String
	var name: String
	var value: String?
	var caps: [Capability]
	var state: ProjectedState?
	var children: [Tree]
	var owners = [String: String]()
	/// Outline refs this node speaks for: itself plus everything merged into it.
	var refs: [String]
	var lines: Int?

	var isTextLeaf: Bool { children.isEmpty && (role == "text" || role == "image") }
}

private func word(_ value: String) -> String {
	var trimmed = Text.trim(value)
	if trimmed.hasPrefix("AX") { trimmed.removeFirst(2) }
	return trimmed.lowercased()
}

private func roleWord(_ node: OutlineNode) -> String {
	let main = roleAliases[word(node.role)] ?? word(node.role)
	let sub = word(node.subrole)
	if sub.isEmpty { return main.isEmpty ? "unknown" : main }
	let specific = roleAliases[sub] ?? sub
	return specific == main ? main : specific
}

private func clean(_ value: String, _ limit: Int) -> String {
	let normalized = Text.normalized(value)
	return normalized.count > limit ? String(normalized.prefix(limit)) + "…" : normalized
}

/// AppKit hands out developer strings where a label belongs — private names, build-time
/// constants and Objective-C selectors. None of them is a name an agent can read or say.
private func isInternalIdentifier(_ value: String) -> Bool {
	if value.hasPrefix("_") { return true }
	let scalars = Array(value.unicodeScalars)
	let upper = { (scalar: Unicode.Scalar) in ("A"..."Z").contains(scalar) }
	let lower = { (scalar: Unicode.Scalar) in ("a"..."z").contains(scalar) }
	let digit = { (scalar: Unicode.Scalar) in ("0"..."9").contains(scalar) }
	// ^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$
	let constantParts = value.split(separator: "_", omittingEmptySubsequences: false)
	if constantParts.count > 1, let first = scalars.first, upper(first),
	   constantParts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { upper($0) || digit($0) } }) { return true }
	// ^[a-z][A-Za-z0-9_]*:[A-Za-z0-9_:]*$
	if let first = scalars.first, lower(first), scalars.contains(":"),
	   scalars.allSatisfy({ upper($0) || lower($0) || digit($0) || $0 == "_" || $0 == ":" }) { return true }
	// Identifier(\.\d+)?$
	if value.hasSuffix("Identifier") { return true }
	if let dot = value.lastIndex(of: ".") {
		let suffix = value[value.index(after: dot)...]
		return !suffix.isEmpty && suffix.allSatisfy(\.isASCIIDigit) && value[..<dot].hasSuffix("Identifier")
	}
	return false
}

private func nameOf(_ node: OutlineNode) -> String {
	for candidate in [node.title, node.description] {
		let text = clean(candidate, maxNameCharacters)
		if !text.isEmpty, !isInternalIdentifier(text) { return text }
	}
	return ""
}

/// Last-resort name: a developer identifier is better than nothing, unless it is AppKit noise.
private func identifierName(_ node: OutlineNode) -> String {
	let text = clean(node.identifier, maxNameCharacters)
	return !text.isEmpty && !isInternalIdentifier(text) ? text : ""
}

private func insideWebArea(_ node: OutlineNode?) -> Bool {
	var current = node
	while let node = current {
		if node.role == "AXWebArea" { return true }
		current = node.parent
	}
	return false
}

private func ordered(_ found: Set<Capability>) -> [Capability] {
	Capability.allCases.filter(found.contains)
}

private func capabilitiesOf(_ node: OutlineNode, role: String, web: Bool) -> [Capability] {
	var found = Set<Capability>()
	for action in node.actions {
		if let capability = actionCapabilities[Text.trim(action).lowercased()] { found.insert(capability) }
	}
	// A line read from the screen is pressed at its coordinates; that is all it offers.
	if node.canPress || node.pictureOnly { found.insert(.press) }
	if node.canScroll { found.insert(.scroll) }
	if node.canIncrement { found.insert(.increment) }
	if node.canDecrement { found.insert(.decrement) }
	if node.isTextInput || textRoles.contains(role) {
		if node.canSetValue { found.insert(.setText) }
		if node.isTextInput { found.insert(.typeText) }
	}
	if toggleRoles.contains(role), found.remove(.press) != nil || node.canSetValue { found.insert(.toggle) }
	// Chromium answers AXShowMenu on every web node and every menu item answers AXPick;
	// neither opens anything an agent would choose.
	if web || role == "menuitem" { found.remove(.menu) }
	// Chromium exposes no scroll action on a web scroller, but makes one focusable when it
	// holds nothing focusable itself; act-ui scrolls it with a wheel turn over it.
	if web, node.role != "AXWebArea", node.canFocus, !node.canPress, !node.canSetValue, !node.isTextInput { found.insert(.scroll) }
	return ordered(found)
}

private func stateOf(_ node: OutlineNode) -> ProjectedState? {
	var state = ProjectedState()
	if node.focused { state.focused = true }
	if node.offscreen { state.offscreen = true }
	if node.truncated { state.truncated = true }
	if let extent = node.scrollExtent, extent.seen < extent.total { state.scroll = extent }
	return state == ProjectedState() ? nil : state
}

private func mergeCapabilities(_ groups: [Capability]...) -> [Capability] {
	ordered(Set(groups.joined()))
}

/// Records who actually performs the capabilities a node inherits from a merged node.
private func delegate(_ target: Tree, _ sources: [Tree]) -> [String: String] {
	var owners = target.owners
	for source in sources {
		for capability in source.caps where !target.caps.contains(capability) && owners[capability.rawValue] == nil {
			owners[capability.rawValue] = source.owners[capability.rawValue] ?? source.ref
		}
	}
	return owners
}

/// A subtree that says nothing but text: the lines and paragraphs of an editor.
private func isTextOnly(_ tree: Tree) -> Bool {
	tree.role == "text" || (structuralRoles.contains(tree.role) && tree.children.allSatisfy(isTextOnly))
}

private func subtreeRefs(_ tree: Tree) -> [String] {
	tree.refs + tree.children.flatMap(subtreeRefs)
}

/// A text input already says its text in its value, so the lines under it fold into a count
/// the input speaks for. Structure around them dissolves; links, buttons and other non-text
/// descendants stay.
private func foldTextLines(_ children: [Tree]) -> (children: [Tree], lines: Int, refs: [String]) {
	var folded: (children: [Tree], lines: Int, refs: [String]) = ([], 0, [])
	for child in children {
		if isTextOnly(child) {
			folded.lines += 1
			folded.refs += subtreeRefs(child)
		} else if structuralRoles.contains(child.role) {
			let inner = foldTextLines(child.children)
			if !child.name.isEmpty { folded.lines += 1 }
			folded.refs += child.refs + inner.refs
			folded.children += inner.children
			folded.lines += inner.lines
		} else {
			folded.children.append(child)
		}
	}
	return folded
}

private func buildTrees(_ node: OutlineNode, insideWeb: Bool) -> [Tree] {
	let role = roleWord(node)
	if droppedRoles.contains(role) { return [] }
	let web = insideWeb || node.role == "AXWebArea"
	let children = node.children.flatMap { buildTrees($0, insideWeb: web) }
	let caps = capabilitiesOf(node, role: role, web: web)
	let state = stateOf(node)
	let value = clean(node.value, maxValueCharacters)
	var name = nameOf(node)
	if name.isEmpty, role == "text" { name = value }
	// A node with no name, no capability and no state says nothing an agent can use.
	// Structural wrappers hand their children up; everything else disappears.
	if name.isEmpty, caps.isEmpty, state == nil, children.isEmpty || structuralRoles.contains(role) || role == "image" { return children }
	// An unnamed, childless menu item is a separator: it answers AXPress but does nothing.
	if name.isEmpty, role == "menuitem", children.isEmpty { return [] }

	var tree = Tree(
		ref: node.ref, role: role, name: name,
		value: !value.isEmpty && value != name && role != "text" ? value : nil,
		caps: caps, state: state, children: children, refs: [node.ref]
	)
	if name.isEmpty, absorbingRoles.contains(role) { tree = absorb(tree) }
	if tree.name.isEmpty { tree.name = identifierName(node) }
	if node.isTextInput || textRoles.contains(role) {
		let folded = foldTextLines(tree.children)
		if folded.lines > 0 {
			tree.children = folded.children
			tree.refs += folded.refs
			tree.lines = folded.lines
		}
	}
	return [tree]
}

/// An unnamed wrapper speaks through the text it wraps, and through the one structural
/// child that carries the real capability.
private func absorb(_ wrapper: Tree) -> Tree {
	var tree = wrapper
	let absorbed = wrapper.children.filter(\.isTextLeaf)
	if !absorbed.isEmpty {
		tree.name = absorbed.map(\.name).filter { !$0.isEmpty }.joined(separator: " ")
		tree.caps = mergeCapabilities(wrapper.caps, absorbed.flatMap(\.caps))
		tree.owners = delegate(wrapper, absorbed)
		tree.children = wrapper.children.filter { !$0.isTextLeaf }
		tree.refs = wrapper.refs + absorbed.flatMap(\.refs)
	}
	// An unnamed wrapper and its only child are one thing to an agent. The node that is
	// not a structural wrapper keeps its ref, role and name; the other lends caps.
	guard tree.name.isEmpty, tree.children.count == 1 else { return tree }
	let only = tree.children[0]
	let caps = mergeCapabilities(tree.caps, only.caps)
	let refs = tree.refs + only.refs
	if structuralRoles.contains(only.role) {
		var merged = tree
		merged.name = only.name
		merged.value = tree.value ?? only.value
		merged.caps = caps
		merged.owners = delegate(tree, [only])
		merged.children = only.children
		merged.refs = refs
		return merged
	}
	if structuralRoles.contains(tree.role) {
		var merged = only
		merged.caps = caps
		merged.owners = delegate(only, [tree])
		merged.refs = refs
		return merged
	}
	return tree
}

private func descendantRoles(_ tree: Tree) -> HiddenSummary {
	var roles = [String: Int]()
	var count = 0
	func visit(_ current: Tree) {
		for child in current.children {
			count += 1
			roles[child.role] = (roles[child.role] ?? 0) + 1
			visit(child)
		}
	}
	visit(tree)
	return HiddenSummary(count: count, roles: roles)
}

private func pathRefs(_ node: OutlineNode) -> [String] {
	var refs: [String] = []
	var current: OutlineNode? = node
	while let node = current {
		refs.insert(node.ref, at: 0)
		current = node.parent
	}
	return refs
}

// Always-open paths: the live focus and modal roots. A subtree the platform cut short
// keeps its `truncated` state word instead, so one deep frontier cannot blow up the view.
private func defaultUnfolded(_ outline: Outline, _ requested: [String]) -> Set<String> {
	var refs = Set(requested)
	for node in outline.nodes where (node.focused && node.canFocus) || node.role == "AXSheet" || node.role == "AXDialog" {
		refs.formUnion(pathRefs(node))
	}
	return refs
}

private func representation(_ trees: [Tree]) -> [String: String] {
	var represents: [String: String] = [:]
	func visit(_ tree: Tree) {
		for ref in tree.refs { represents[ref] = tree.ref }
		tree.children.forEach(visit)
	}
	trees.forEach(visit)
	return represents
}

private struct Folded {
	var nodes: [ProjectedNode] = []
	var truncated = false
}

private func fold(_ trees: [Tree], maxDepth: Int, maxNodes: Int, unfolded: Set<String>) -> Folded {
	var folded = Folded()
	func emit(_ tree: Tree, depth: Int, parent: String?) {
		if folded.nodes.count >= maxNodes {
			folded.truncated = true
			return
		}
		let hide = !tree.children.isEmpty && depth >= maxDepth && !unfolded.contains(tree.ref)
		folded.nodes.append(ProjectedNode(
			ref: tree.ref, role: tree.role, name: tree.name, value: tree.value, caps: tree.caps, state: tree.state,
			owners: tree.owners.isEmpty ? nil : tree.owners, depth: depth, parent: parent, hidden: hide ? descendantRoles(tree) : nil,
			lines: tree.lines
		))
		if hide { return }
		for child in tree.children { emit(child, depth: depth + 1, parent: tree.ref) }
	}
	for tree in trees { emit(tree, depth: 0, parent: nil) }
	return folded
}

private func subtreeSize(_ node: OutlineNode) -> Int {
	1 + node.children.reduce(0) { $0 + subtreeSize($1) }
}

public func project(_ outline: Outline, _ options: ProjectOptions = ProjectOptions()) -> Projection {
	let start = options.from ?? outline.root
	let trees = buildTrees(start, insideWeb: insideWebArea(start.parent))
	let total = start === outline.root ? outline.nodes.count : subtreeSize(start)
	let limit = options.maxNodes ?? maxNodes
	let unfolded = defaultUnfolded(outline, options.unfold)
	let represents = representation(trees)
	func projection(_ folded: Folded) -> Projection {
		Projection(nodes: folded.nodes, shown: folded.nodes.count, total: total, truncated: folded.truncated, represents: represents)
	}
	if let maxDepth = options.maxDepth { return projection(fold(trees, maxDepth: maxDepth, maxNodes: limit, unfolded: unfolded)) }

	// Show as much structure as a bounded first view can carry: the focused region is
	// always open, and everything else opens one level at a time while the view fits.
	var best = fold(trees, maxDepth: 1, maxNodes: limit, unfolded: unfolded)
	for depth in 2...maxAutoDepth {
		let candidate = fold(trees, maxDepth: depth, maxNodes: limit, unfolded: unfolded)
		if candidate.nodes.count == best.nodes.count { break }
		if renderNodes(candidate.nodes).utf8.count > viewByteBudget { break }
		best = candidate
	}
	return projection(best)
}

private func stateWords(_ state: ProjectedState?) -> String {
	guard let state else { return "" }
	let words = [
		state.focused == true ? "focused" : nil,
		state.offscreen == true ? "offscreen" : nil,
		state.truncated == true ? "truncated" : nil,
		state.scroll.map { "scroll \($0.seen)/\($0.total)" },
	].compactMap { $0 }
	return words.isEmpty ? "" : " " + words.joined(separator: " ")
}

private func hiddenSummary(_ hidden: HiddenSummary?) -> String {
	guard let hidden else { return "" }
	let roles = hidden.roles
		.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
		.prefix(4)
		.map { "\($0.key)×\($0.value)" }
		.joined(separator: " ")
	return " ▸ \(hidden.count) hidden: \(roles)"
}

private func linesSummary(_ node: ProjectedNode) -> String {
	guard let lines = node.lines, lines > 0 else { return "" }
	return " ▸ \(lines) line\(lines == 1 ? "" : "s"), read-text \(node.ref)"
}

/// One node without its indent or ref, for diff lines.
public func renderNodeBody(_ node: ProjectedNode) -> String {
	let name = node.name.isEmpty ? "" : " " + Text.quote(node.name)
	let value = node.value.map { " =" + Text.quote($0) } ?? ""
	let caps = node.caps.isEmpty ? "" : " {" + node.caps.map(\.rawValue).joined(separator: ",") + "}"
	return node.role + name + value + caps + stateWords(node.state) + hiddenSummary(node.hidden) + linesSummary(node)
}

public func renderNode(_ node: ProjectedNode) -> String {
	String(repeating: "  ", count: node.depth) + node.ref + " " + renderNodeBody(node)
}

public func renderNodes(_ nodes: [ProjectedNode]) -> String {
	nodes.map(renderNode).joined(separator: "\n")
}

public func renderObservation(_ view: ObservationView) -> String {
	let ref = view.root.ref.map { $0 + " " } ?? ""
	let header = "\(ref)\(view.root.app) — \(view.root.title) · state \(view.stateId) · \(view.total) nodes, \(view.shown) shown"
	return [header, renderNodes(view.nodes)].filter { !$0.isEmpty }.joined(separator: "\n")
}
