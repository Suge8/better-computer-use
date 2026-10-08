/// A step that names its element instead of carrying a ref: the role and name the view shows,
/// matched in a fresh observation of the step's root. Pure matching; the caller observes,
/// waits for a match to appear and acts on the ref this returns.

public enum Located: Sendable, Equatable {
	case found(ref: String)
	/// Nothing matches yet; waiting may change that.
	case missing(BCUError)
	/// Candidates remain after the tie rules; waiting cannot change that.
	case ambiguous(BCUError)
}

private let candidatesShown = 5

private let missingRecovery = "Compare the locator with a fresh observe-ui of that root, or raise its timeoutMs."
private let ambiguousRecovery = "Add nth, or a more exact role or name, to the locator."

/// The element of `outline` the locator names, for the action that will use it.
///
/// Role matches the view's role word or the accessibility role or subrole, exactly. A name
/// matches exactly, or as a part of a name when no name is exact. Candidates left tied are
/// narrowed by what is on screen and by the capability the action needs, so "Reason" for a
/// setText is the field, not its label; a tie no rule breaks is ambiguous.
public func locate(_ locator: Locator, for action: ActionName, in outline: Outline) -> Located {
	let nodes = project(outline, .unfolded).nodes
	let roles = roleMatcher(locator.role, outline)
	let described = describe(locator)
	let byRole = nodes.filter(roles)
	var pool = byRole
	if let name = locator.name {
		let wanted = searchKey(name)
		let exact = byRole.filter { searchKey($0.name) == wanted }
		pool = exact.isEmpty ? byRole.filter { searchKey($0.name).contains(wanted) } : exact
	}
	pool = narrowed(pool) { $0.state?.offscreen != true }
	if let needed = ownedCapabilities[action] { pool = narrowed(pool) { node in needed.contains { node.caps.contains($0) } } }

	guard !pool.isEmpty else {
		return .missing(BCUError(.elementNotFound, "Locator \(described) matches nothing.\(nearest(locator, nodes, roles))", recovery: missingRecovery))
	}
	if let nth = locator.nth {
		guard nth < pool.count else {
			return .missing(BCUError(.elementNotFound, "Locator \(described) nth \(nth) asked but only \(pool.count) match", recovery: missingRecovery))
		}
		return .found(ref: pool[nth].ref)
	}
	guard pool.count == 1 else {
		return .ambiguous(BCUError(.elementNotFound, "Locator \(described) matches \(pool.count) elements: \(candidates(pool, nodes))", recovery: ambiguousRecovery))
	}
	return .found(ref: pool[0].ref)
}

private func searchKey(_ value: String) -> String {
	Text.normalized(foldedForSearch(value))
}

private func roleMatcher(_ wanted: String?, _ outline: Outline) -> (ProjectedNode) -> Bool {
	guard let wanted else { return { _ in true } }
	let query = normalizedSearchRole(wanted)
	let raw = Dictionary(outline.nodes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
	return { node in
		let source = raw[node.ref]
		return [normalizedSearchRole(node.role), source.map { normalizedSearchRole($0.role) }, source.map { normalizedSearchRole($0.subrole) }].contains(query)
	}
}

/// The rule's survivors, or everyone when it would leave nobody.
private func narrowed(_ pool: [ProjectedNode], by keep: (ProjectedNode) -> Bool) -> [ProjectedNode] {
	guard pool.count > 1 else { return pool }
	let kept = pool.filter(keep)
	return kept.isEmpty ? pool : kept
}

private func describe(_ locator: Locator) -> String {
	[locator.role ?? "element", locator.name.map(Text.quote)].compactMap { $0 }.joined(separator: " ")
}

private func candidates(_ pool: [ProjectedNode], _ all: [ProjectedNode]) -> String {
	let byRef = Dictionary(all.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
	var lines = pool.prefix(candidatesShown).enumerated().map { index, node -> String in
		let parent = node.parent.flatMap { byRef[$0] }.map { " in " + [$0.role, $0.name.isEmpty ? nil : Text.quote($0.name)].compactMap { $0 }.joined(separator: " ") } ?? ""
		return "nth \(index): \(renderNodeBody(node))\(parent)"
	}
	if pool.count > candidatesShown { lines.append("… \(pool.count - candidatesShown) more") }
	return lines.joined(separator: "; ")
}

/// What the wanted element was probably mistaken for: other elements of the role named, or
/// elements sharing the first word of the name.
private func nearest(_ locator: Locator, _ nodes: [ProjectedNode], _ roles: (ProjectedNode) -> Bool) -> String {
	var near: [ProjectedNode] = []
	if locator.role != nil {
		near = nodes.filter(roles)
	} else if let word = locator.name.map(searchKey)?.split(separator: " ").first {
		near = nodes.filter { searchKey($0.name).contains(word) }
	}
	guard !near.isEmpty else { return "" }
	return " Nearest: " + near.prefix(candidatesShown).map(renderNodeBody).joined(separator: "; ")
}
