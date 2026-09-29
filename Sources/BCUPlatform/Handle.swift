import ApplicationServices

/// An opaque platform object a caller holds on to between calls: an accessibility element or
/// a root. It compares by the identity of what it names, so the same window found twice is
/// the same handle. The platform alone looks inside; a caller keeps it with the observation
/// it came from, and it is released with that observation.
public struct Handle: Hashable, @unchecked Sendable {
	let base: AnyHashable

	/// Wraps any value as a handle; the platform's own handles wrap accessibility elements.
	public init<Value: Hashable & Sendable>(_ value: Value) {
		base = AnyHashable(value)
	}
}

/// An accessibility element, equal to another when both name the same UI object.
struct AXElement: Hashable {
	let element: AXUIElement

	static func == (lhs: AXElement, rhs: AXElement) -> Bool {
		CFEqual(lhs.element, rhs.element)
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(CFHash(element))
	}
}

/// What an element looked like when it was observed, to find it again if its accessibility
/// object is replaced (a list row rebuilt, a view reloaded).
struct ElementSnapshot {
	let role: String
	let identifier: String
	let label: String
	/// Screen points.
	let rect: CGRect
}

/// An observed element and its snapshot; identity is the element alone.
struct ElementRecord: Hashable {
	let element: AXElement
	let snapshot: ElementSnapshot

	static func == (lhs: ElementRecord, rhs: ElementRecord) -> Bool {
		lhs.element == rhs.element
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(element)
	}
}

/// A root: its accessibility element, or for a popup menu Accessibility never exposed, the
/// window-server window that draws it.
enum RootObject: Hashable {
	case element(AXElement)
	case popupMenu(windowId: UInt32)
}

extension Handle {
	static func element(_ element: AXUIElement, snapshot: ElementSnapshot) -> Handle {
		Handle(ElementRecord(element: AXElement(element: element), snapshot: snapshot))
	}

	static func root(_ element: AXUIElement) -> Handle {
		Handle(RootObject.element(AXElement(element: element)))
	}

	static func popupMenu(windowId: UInt32) -> Handle {
		Handle(RootObject.popupMenu(windowId: windowId))
	}

	var elementRecord: ElementRecord? {
		base.base as? ElementRecord
	}

	var rootObject: RootObject? {
		base.base as? RootObject
	}
}

extension AXElement: @unchecked Sendable {}
extension ElementRecord: @unchecked Sendable {}
extension RootObject: @unchecked Sendable {}
