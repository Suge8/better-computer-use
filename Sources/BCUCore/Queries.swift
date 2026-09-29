/// Queries over one saved observation: its view, search, expansion and raw fields. Only a
/// subtree the platform cut short needs a live read, which the caller supplies.

public func observeResult(stateId: String, root: RootSummary, outline: Outline, image: ImageInfo? = nil) -> ObserveResult {
	let projection = project(outline)
	return ObserveResult(stateId: stateId, root: root, nodes: projection.nodes, shown: projection.shown, total: projection.total, image: image)
}

private let defaultSearchLimit = 12
private let maxSearchLimit = 50
private let defaultExpandDepth = 3
private let maxExpandDepth = 8

private func capabilityQuery(_ action: String?) throws -> Capability? {
	guard let action else { return nil }
	guard let capability = Capability.allCases.first(where: { $0.rawValue.lowercased() == action.lowercased() }) else {
		throw invalid("Unknown capability '\(action)'. Use one of: \(Capability.allCases.map(\.rawValue).joined(separator: ", ")).")
	}
	return capability
}

/// Maps outline hits onto the nodes the agent actually sees, with their projected ancestry.
/// A hit the projection dropped is noise the agent cannot act on; only a node that speaks
/// for the hit may stand in for it.
private func projectedMatches(_ outline: Outline, _ hits: [OutlineNode], _ capability: Capability?) -> [SearchMatch] {
	let projection = project(outline, .unfolded)
	let projected = Dictionary(projection.nodes.map { ($0.ref, $0) }, uniquingKeysWith: { $1 })
	var matches: [SearchMatch] = []
	var seen = Set<String>()
	for hit in hits {
		guard var node = projected[projection.represents[hit.ref] ?? ""], !seen.contains(node.ref) else { continue }
		if let capability, !node.caps.contains(capability) { continue }
		seen.insert(node.ref)
		var path: [String] = []
		var parent = node.parent
		while let ref = parent {
			path.insert(ref, at: 0)
			parent = projected[ref]?.parent
		}
		node.depth = 0
		matches.append(SearchMatch(node: node, path: path))
	}
	return matches
}

public func searchUI(_ params: SearchUiParams, in outline: Outline, stateId: String) throws -> SearchResult {
	let capability = try capabilityQuery(Text.trimmedOrNil(params.action))
	let limit = max(1, min(maxSearchLimit, params.limit ?? defaultSearchLimit))
	let hits = searchOutline(outline, text: Text.trimmedOrNil(params.text), role: Text.trimmedOrNil(params.role))
	let matches = projectedMatches(outline, hits, capability)
	return SearchResult(stateId: stateId, matches: Array(matches.prefix(limit)), total: matches.count)
}

/// `scopedLook` reads the live subtree of a node the platform cut short; it is grafted into
/// the outline before the subtree is projected.
public func expandUI(_ params: ExpandUiParams, in outline: Outline, stateId: String, scopedLook: (OutlineNode) throws -> Outline) throws -> ExpandResult {
	guard let ref = Text.trimmedOrNil(params.ref) else { throw invalid("expand-ui requires --ref.") }
	guard var target = outline.node(ref) else { throw BCUError(.elementNotFound, "Ref '\(ref)' is not in the current state.") }
	let depth = max(1, min(maxExpandDepth, params.depth ?? defaultExpandDepth))
	if target.truncated {
		_ = try target.accessibilityRef()
		let scoped = try scopedLook(target)
		target = try outline.graft(scoped, at: target.ref)
		outline.lookId = scoped.lookId
	}
	let projection = project(outline, ProjectOptions(maxDepth: depth, from: target))
	return ExpandResult(stateId: stateId, ref: target.ref, nodes: projection.nodes)
}

/// Every raw field the projection hides, and who performs the capabilities the ref advertises.
public func inspectUI(_ params: InspectUiParams, in outline: Outline, stateId: String) throws -> InspectResult {
	guard let ref = Text.trimmedOrNil(params.ref) else { throw invalid("inspect-ui requires --ref.") }
	guard let target = outline.node(ref) else { throw BCUError(.elementNotFound, "Ref '\(ref)' is not in the current state.") }
	let projected = project(outline, .unfolded).nodes.first { $0.ref == target.ref }
	return InspectResult(stateId: stateId, node: target.fieldsWithoutChildren, owners: projected?.owners)
}
