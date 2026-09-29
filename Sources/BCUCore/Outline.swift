/// The full accessibility tree of one observation. Refs are `@eN`; `wireRef` is the platform
/// element the node was read from, absent for text read from the screen.
public struct OutlineRect: Codable, Sendable, Equatable {
	public var x: Double
	public var y: Double
	public var w: Double
	public var h: Double

	public init(x: Double, y: Double, w: Double, h: Double) {
		self.x = x
		self.y = y
		self.w = w
		self.h = h
	}
}

public struct ScrollExtent: Codable, Sendable, Equatable {
	public var seen: Int
	public var total: Int

	public init(seen: Int, total: Int) {
		self.seen = seen
		self.total = total
	}
}

/// One node as a saved state holds it and as inspect-ui prints it.
public struct SerializedOutlineNode: Codable, Sendable, Equatable {
	public var ref: String
	public var wireRef: String?
	public var role: String
	public var subrole: String
	public var identifier: String
	public var title: String
	public var description: String
	public var value: String
	public var actions: [String]
	public var canPress: Bool
	public var canFocus: Bool
	public var canSetValue: Bool
	public var canScroll: Bool
	public var canIncrement: Bool
	public var canDecrement: Bool
	public var isTextInput: Bool
	public var rect: OutlineRect?
	public var focused: Bool
	public var offscreen: Bool
	public var pictureOnly: Bool
	public var truncated: Bool
	public var scrollExtent: ScrollExtent?
	public var children: [SerializedOutlineNode]

	public init(ref: String, wireRef: String? = nil, role: String, subrole: String, identifier: String, title: String, description: String, value: String, actions: [String], canPress: Bool, canFocus: Bool, canSetValue: Bool, canScroll: Bool, canIncrement: Bool, canDecrement: Bool, isTextInput: Bool, rect: OutlineRect? = nil, focused: Bool, offscreen: Bool, pictureOnly: Bool, truncated: Bool, scrollExtent: ScrollExtent? = nil, children: [SerializedOutlineNode]) {
		self.ref = ref
		self.wireRef = wireRef
		self.role = role
		self.subrole = subrole
		self.identifier = identifier
		self.title = title
		self.description = description
		self.value = value
		self.actions = actions
		self.canPress = canPress
		self.canFocus = canFocus
		self.canSetValue = canSetValue
		self.canScroll = canScroll
		self.canIncrement = canIncrement
		self.canDecrement = canDecrement
		self.isTextInput = isTextInput
		self.rect = rect
		self.focused = focused
		self.offscreen = offscreen
		self.pictureOnly = pictureOnly
		self.truncated = truncated
		self.scrollExtent = scrollExtent
		self.children = children
	}
}

public struct SerializedOutline: Codable, Sendable, Equatable {
	public var lookId: String
	public var root: SerializedOutlineNode

	public init(lookId: String, root: SerializedOutlineNode) {
		self.lookId = lookId
		self.root = root
	}
}

public final class OutlineNode {
	public var ref: String
	public var wireRef: String?
	public var role: String
	public var subrole: String
	public var identifier: String
	public var title: String
	public var description: String
	public var value: String
	public var actions: [String]
	public var canPress: Bool
	public var canFocus: Bool
	public var canSetValue: Bool
	public var canScroll: Bool
	public var canIncrement: Bool
	public var canDecrement: Bool
	public var isTextInput: Bool
	public var rect: OutlineRect?
	public var focused: Bool
	public var offscreen: Bool
	public var pictureOnly: Bool
	public var truncated: Bool
	public var scrollExtent: ScrollExtent?
	public var children: [OutlineNode] = []
	public weak var parent: OutlineNode?

	public init(_ serialized: SerializedOutlineNode) {
		ref = serialized.ref
		wireRef = serialized.wireRef
		role = serialized.role
		subrole = serialized.subrole
		identifier = serialized.identifier
		title = serialized.title
		description = serialized.description
		value = serialized.value
		actions = serialized.actions
		canPress = serialized.canPress
		canFocus = serialized.canFocus
		canSetValue = serialized.canSetValue
		canScroll = serialized.canScroll
		canIncrement = serialized.canIncrement
		canDecrement = serialized.canDecrement
		isTextInput = serialized.isTextInput
		rect = serialized.rect
		focused = serialized.focused
		offscreen = serialized.offscreen
		pictureOnly = serialized.pictureOnly
		truncated = serialized.truncated
		scrollExtent = serialized.scrollExtent
		children = serialized.children.map(OutlineNode.init)
		for child in children { child.parent = self }
	}

	public var serialized: SerializedOutlineNode {
		var node = fieldsWithoutChildren
		node.children = children.map(\.serialized)
		return node
	}

	var fieldsWithoutChildren: SerializedOutlineNode {
		SerializedOutlineNode(
			ref: ref, wireRef: wireRef, role: role, subrole: subrole, identifier: identifier, title: title, description: description,
			value: value, actions: actions, canPress: canPress, canFocus: canFocus, canSetValue: canSetValue, canScroll: canScroll,
			canIncrement: canIncrement, canDecrement: canDecrement, isTextInput: isTextInput, rect: rect, focused: focused,
			offscreen: offscreen, pictureOnly: pictureOnly, truncated: truncated, scrollExtent: scrollExtent, children: []
		)
	}

	/// Every field but identity and structure; a grafted node is complete again.
	fileprivate func copyFields(from source: OutlineNode, keepingWireRef: Bool) {
		if !keepingWireRef { wireRef = source.wireRef }
		role = source.role
		subrole = source.subrole
		identifier = source.identifier
		title = source.title
		description = source.description
		value = source.value
		actions = source.actions
		canPress = source.canPress
		canFocus = source.canFocus
		canSetValue = source.canSetValue
		canScroll = source.canScroll
		canIncrement = source.canIncrement
		canDecrement = source.canDecrement
		isTextInput = source.isTextInput
		rect = source.rect
		focused = source.focused
		offscreen = source.offscreen
		pictureOnly = source.pictureOnly
		truncated = false
		scrollExtent = source.scrollExtent
	}

	/// The platform element behind this ref; text read from the screen has none.
	public func accessibilityRef() throws -> String {
		guard !pictureOnly, let wireRef, !wireRef.isEmpty else {
			throw BCUError(.elementNotFound, "Ref '\(ref)' has no accessibility element; it can only be clicked by coordinates.")
		}
		return wireRef
	}

	var preorder: [OutlineNode] {
		[self] + children.flatMap(\.preorder)
	}
}

public final class Outline {
	public var lookId: String
	public let root: OutlineNode
	/// Breadth-first for a fresh look; a restored saved state lists its nodes depth-first.
	public private(set) var nodes: [OutlineNode] = []

	/// A fresh look: refs are numbered breadth-first from `@e1`.
	public init(lookId: String, root: OutlineNode) {
		self.lookId = lookId
		self.root = root
		root.parent = nil
		rebuildIndexes()
		for (index, node) in nodes.enumerated() { node.ref = "@e\(index + 1)" }
	}

	/// A saved state: refs are kept as saved.
	public init(restoring serialized: SerializedOutline) {
		lookId = serialized.lookId
		root = OutlineNode(serialized.root)
		nodes = root.preorder
	}

	public var serialized: SerializedOutline {
		SerializedOutline(lookId: lookId, root: root.serialized)
	}

	/// An `@e` ref, or the platform ref of an element.
	public func node(_ ref: String) -> OutlineNode? {
		nodes.first { $0.ref == ref || $0.wireRef == ref }
	}

	private func rebuildIndexes() {
		var queue = [root]
		var index = 0
		while index < queue.count {
			queue.append(contentsOf: queue[index].children)
			index += 1
		}
		nodes = queue
	}

	private var highestRefNumber: Int {
		nodes.map { refNumber($0.ref) }.max() ?? 0
	}

	/// Keeps a base ref only when native or structural identity is unambiguous; every other
	/// node gets a number the base never used.
	public func stabilizeRefs(against base: Outline?) {
		guard let base else { return }
		var reserved = Set<String>()
		var assigned = Set<ObjectIdentifier>()
		var byWireRef: [String: String] = [:]
		var structuralGroups: [String: [OutlineNode]] = [:]
		for node in base.nodes {
			if let wireRef = node.wireRef, !wireRef.isEmpty { byWireRef[wireRef] = node.ref }
			structuralGroups[structuralKey(node), default: []].append(node)
		}
		var nextIndex = max(0, base.highestRefNumber) + 1
		for node in nodes {
			let matches = structuralGroups[structuralKey(node)] ?? []
			let stable = node.wireRef.flatMap { byWireRef[$0] } ?? (matches.count == 1 ? matches[0].ref : nil)
			guard let stable, !reserved.contains(stable) else { continue }
			node.ref = stable
			reserved.insert(stable)
			assigned.insert(ObjectIdentifier(node))
		}
		for node in nodes where !assigned.contains(ObjectIdentifier(node)) {
			while reserved.contains("@e\(nextIndex)") { nextIndex += 1 }
			node.ref = "@e\(nextIndex)"
			nextIndex += 1
			reserved.insert(node.ref)
		}
		rebuildIndexes()
	}

	/// Replaces a subtree the platform cut short with a scoped look of it. Existing refs survive,
	/// new nodes get refs above every ref in use, and grafted nodes carry no geometry: the
	/// scoped look measured them in another image.
	@discardableResult
	public func graft(_ scoped: Outline, at targetRef: String) throws -> OutlineNode {
		guard let target = node(targetRef) else {
			throw BCUError(.internalError, "Cannot graft scoped outline: target \(targetRef) is not in the current outline.")
		}
		var grafting = Grafting(nextNumber: highestRefNumber + 1, used: [ObjectIdentifier(target)])
		for node in target.preorder {
			if let wireRef = node.wireRef, !wireRef.isEmpty { grafting.reusable[wireRef] = node }
		}
		let targetRect = target.rect
		let oldChildren = target.children
		target.copyFields(from: scoped.root, keepingWireRef: true)
		target.ref = targetRef
		target.rect = targetRect
		let grafted = scoped.root.children.map { grafting.clone($0, parent: target) }
		target.children = grafted + oldChildren.compactMap { grafting.preserve($0, parent: target) }
		for child in target.children {
			for node in child.preorder { node.rect = nil }
		}
		rebuildIndexes()
		return target
	}
}

private struct Grafting {
	var nextNumber: Int
	var used: Set<ObjectIdentifier>
	var reusable: [String: OutlineNode] = [:]

	init(nextNumber: Int, used: Set<ObjectIdentifier>) {
		self.nextNumber = nextNumber
		self.used = used
	}

	mutating func clone(_ source: OutlineNode, parent: OutlineNode) -> OutlineNode {
		let existing = source.wireRef.flatMap { reusable[$0] }
		if let existing { used.insert(ObjectIdentifier(existing)) }
		let oldChildren = existing?.children ?? []
		let node: OutlineNode
		if let existing {
			node = existing
		} else {
			node = OutlineNode(source.fieldsWithoutChildren)
			node.ref = "@e\(nextNumber)"
			nextNumber += 1
		}
		node.copyFields(from: source, keepingWireRef: existing != nil)
		node.parent = parent
		let grafted = source.children.map { clone($0, parent: node) }
		node.children = grafted + oldChildren.compactMap { preserve($0, parent: node) }
		return node
	}

	func preserve(_ node: OutlineNode, parent: OutlineNode) -> OutlineNode? {
		guard !used.contains(ObjectIdentifier(node)) else { return nil }
		node.parent = parent
		node.children = node.children.compactMap { preserve($0, parent: node) }
		return node
	}
}


func refNumber(_ ref: String) -> Int {
	guard ref.hasPrefix("@e"), ref.count > 2, ref.dropFirst(2).allSatisfy(\.isASCIIDigit) else { return 0 }
	return Int(ref.dropFirst(2)) ?? 0
}

private func structuralToken(_ node: OutlineNode) -> String {
	[node.role, node.subrole, node.identifier, node.title, node.description].map { Text.trim($0).lowercased() }.joined(separator: "|")
}

/// The node's path from the root as role and label tokens, each with its index among same-token siblings.
private func structuralKey(_ node: OutlineNode) -> String {
	var parts: [String] = []
	var current: OutlineNode? = node
	while let node = current {
		let token = structuralToken(node)
		let peers = (node.parent?.children ?? [node]).filter { structuralToken($0) == token }
		parts.append("\(token)#\(peers.firstIndex { $0 === node } ?? 0)")
		current = node.parent
	}
	return parts.reversed().joined(separator: ">")
}

/// Matches anywhere in the outline, depth first; role accepts short words as well as AX names.
public func searchOutline(_ outline: Outline, text: String?, role: String?) -> [OutlineNode] {
	let query = text.map { Text.trim($0).lowercased() } ?? ""
	let roleQuery = role.map(normalizedSearchRole)
	return outline.root.preorder.filter { node in
		let haystack = [node.role, node.subrole, node.identifier, node.title, node.description, node.value].joined(separator: " ").lowercased()
		if !query.isEmpty, !haystack.contains(query) { return false }
		if let roleQuery, !roleQuery.isEmpty, normalizedSearchRole(node.role) != roleQuery, normalizedSearchRole(node.subrole) != roleQuery { return false }
		return true
	}
}

private func normalizedSearchRole(_ value: String) -> String {
	var word = Text.trim(value).lowercased()
	if word.hasPrefix("ax") { word.removeFirst(2) }
	return String(word.unicodeScalars.filter { $0 != " " && $0 != "_" && $0 != "-" }.map(Character.init))
}
