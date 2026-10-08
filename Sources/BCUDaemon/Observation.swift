import BCUCore
import BCUPlatform
import BCURuntime
import Foundation
import os

/// A root under a stable `@r` ref: equal when the platform names the same root.
struct RegisteredRoot: Equatable, Sendable {
	let handle: Handle
	let pid: Int32
	let appName: String
	let bundleId: String?

	static func == (lhs: RegisteredRoot, rhs: RegisteredRoot) -> Bool {
		lhs.handle == rhs.handle
	}
}

/// A root the daemon works on: the platform's view of it, named by the app discovery found
/// it in and by its `@r` ref.
struct Target: Sendable {
	let root: Root
	let ref: String
	let appName: String
	let bundleId: String?

	var pid: Int32 { root.pid }
	var title: String { root.title.isEmpty ? "(untitled)" : root.title }
	var windowId: Int? { root.windowId.map(Int.init).flatMap { $0 > 0 ? $0 : nil } }

	var appearance: RootAppearance {
		RootAppearance(ref: ref, kind: root.kind, app: appName, title: title)
	}
}

/// One saved observation: the root it looked at, its outline with the platform handles
/// behind the outline's refs, and the geometry coordinates were measured in. Evicting the
/// state releases the handles.
struct Observation: StatePayload {
	let target: Target
	let outline: ObservedOutline
	let geometry: LookGeometry
	let image: ImageSize?
	let readText: ReadTextMode?
	let readScreen: Bool
	let frame: Frame
	let scale: Double
	let byteCount: Int
}

/// An observation's outline and handles. Expanding a subtree the platform cut short refines
/// the observation in place, under the same stateId.
final class ObservedOutline: Sendable {
	struct Contents: Sendable {
		var outline: SerializedOutline
		/// Wire ref → the element behind it.
		var handles: [String: Handle]
	}

	private let contents: OSAllocatedUnfairLock<Contents>

	init(_ contents: Contents) {
		self.contents = OSAllocatedUnfairLock(initialState: contents)
	}

	var current: Contents { contents.withLock { $0 } }

	/// A fresh copy to query or change; the saved one changes only through `replace`.
	func outline() -> Outline {
		Outline(restoring: current.outline)
	}

	func replace(_ outline: Outline, adding handles: [String: Handle]) {
		let serialized = outline.serialized
		contents.withLock { contents in
			contents.outline = serialized
			contents.handles.merge(handles) { $1 }
		}
	}

	/// Refs of the nodes that are the element `handle`: a root seen from inside another root's tree.
	func refs(of handle: Handle) -> Set<String> {
		let contents = current
		let outline = Outline(restoring: contents.outline)
		return Set(contents.handles.filter { $0.value == handle }.compactMap { outline.node($0.key)?.ref })
	}

	/// The element behind a node; nodes read from the screen have none.
	func handle(of node: OutlineNode) throws -> Handle {
		let wireRef = try node.accessibilityRef()
		guard let handle = current.handles[wireRef] else {
			throw BCUError(.elementNotFound, "Ref '\(node.ref)' has no accessibility element; it can only be clicked by coordinates.")
		}
		return handle
	}
}

/// Turns a look into an outline. Elements the base observation already named keep their wire
/// refs, so a successor keeps the `@e` refs of what it still shows; new elements get wire refs
/// the base never used.
func adopt(_ look: LookNode, base: ObservedOutline.Contents?) -> (outline: Outline, handles: [String: Handle]) {
	var known: [Handle: String] = [:]
	for (wireRef, handle) in base?.handles ?? [:] { known[handle] = wireRef }
	var next = (base?.handles.keys.compactMap { Int($0.dropFirst(wirePrefix.count)) }.max() ?? 0) + 1
	var handles: [String: Handle] = [:]
	func serialize(_ node: LookNode) -> SerializedOutlineNode {
		var wireRef: String?
		if let handle = node.handle {
			let ref = known[handle] ?? {
				let fresh = "\(wirePrefix)\(next)"
				next += 1
				known[handle] = fresh
				return fresh
			}()
			handles[ref] = handle
			wireRef = ref
		} else if !node.name.isEmpty {
			wireRef = node.name
		}
		return SerializedOutlineNode(
			ref: "", wireRef: wireRef, role: node.role, subrole: node.subrole, identifier: node.identifier, title: node.title,
			description: node.description, value: node.value, actions: node.actions, canPress: node.canPress, canFocus: node.canFocus,
			canSetValue: node.canSetValue, canScroll: node.canScroll, canIncrement: node.canIncrement, canDecrement: node.canDecrement,
			isTextInput: node.isTextInput,
			rect: OutlineRect(x: node.rect.origin.x, y: node.rect.origin.y, w: max(0, node.rect.width), h: max(0, node.rect.height)),
			focused: node.focused, offscreen: node.offscreen, pictureOnly: node.pictureOnly, truncated: node.truncated,
			scrollExtent: node.scrollExtent, children: node.children.map(serialize)
		)
	}
	let root = serialize(look)
	return (Outline(root: OutlineNode(root)), handles)
}

private let wirePrefix = "h"

extension OutlineNode {
	var subtree: [OutlineNode] {
		[self] + children.flatMap(\.subtree)
	}
}
