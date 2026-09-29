import ApplicationServices
import BCUCore
import Foundation

// The outline a look returns, and how lines read from the screen join it. Kept apart from
// the platform calls so the attachment rules are unit-tested without a live desktop.

struct OCRBox {
	let string: String
	let confidence: Double
	let rect: CGRect
}

/// A look's outline is built once and handed to the caller, which owns it from then on.
public final class LookNode: @unchecked Sendable {
	/// Role of a line read from the screen; it has no accessibility element.
	public static let ocrRole = "OCR"

	/// The element behind the node; nil for lines read from the screen and picture-only roots.
	public let handle: Handle?
	/// What names a node without an element: `ocr_<n>` for the n-th line read from the screen,
	/// `cgmenu:<windowId>` for a popup menu root. Empty for element nodes.
	public let name: String
	public let role: String
	public let subrole: String
	public let identifier: String
	public let title: String
	public let description: String
	public let value: String
	public let actions: [String]
	public let canPress: Bool
	public let canFocus: Bool
	public let canSetValue: Bool
	public let canScroll: Bool
	public let canIncrement: Bool
	public let canDecrement: Bool
	public let isTextInput: Bool
	public let rect: CGRect
	public let focused: Bool
	public internal(set) var offscreen: Bool
	public internal(set) var pictureOnly: Bool
	public internal(set) var truncated: Bool
	public internal(set) var scrollExtent: ScrollExtent?
	public internal(set) var children: [LookNode]

	init(handle: Handle?, name: String, role: String, subrole: String, identifier: String, title: String, description: String, value: String, actions: [String], canPress: Bool, canFocus: Bool, canSetValue: Bool, canScroll: Bool, canIncrement: Bool, canDecrement: Bool, isTextInput: Bool, rect: CGRect, focused: Bool = false, offscreen: Bool = false, pictureOnly: Bool = false) {
		self.handle = handle
		self.name = name
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
		self.truncated = false
		self.children = []
	}
}

/// Every line Accessibility does not already say becomes its own node, under the
/// deepest container around it; an agent presses it by its coordinates.
func attachOCR(_ boxes: [OCRBox], to root: LookNode) {
	for (index, box) in boxes.enumerated() where !ocrBoxDuplicatesAXLabel(box, in: root) {
		let parent = deepestNode(containing: CGPoint(x: box.rect.midX, y: box.rect.midY), in: root) ?? root
		parent.children.append(LookNode(handle: nil, name: "ocr_\(index + 1)", role: LookNode.ocrRole, subrole: "", identifier: "", title: box.string, description: "", value: "", actions: [], canPress: false, canFocus: false, canSetValue: false, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: false, rect: box.rect, pictureOnly: true))
	}
}

private func ocrBoxDuplicatesAXLabel(_ box: OCRBox, in root: LookNode) -> Bool {
	let boxLabel = normalizedLabel(box.string)
	if boxLabel.isEmpty { return true }
	var queue = [root]
	var index = 0
	while index < queue.count {
		let node = queue[index]
		index += 1
		if !node.pictureOnly, node.rect.intersects(box.rect) {
			let fields = [node.title, node.value, node.description]
			if fields.contains(where: { normalizedLabel($0).contains(boxLabel) }) { return true }
		}
		queue.append(contentsOf: node.children)
	}
	return false
}

/// Traffic-light buttons: window chrome, never content.
let windowControls: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

/// Window controls, and leaf controls that already have a name, hold no content of their
/// own: a line over them is part of whatever holds them.
private func holdsContent(_ node: LookNode) -> Bool {
	if windowControls.contains(node.subrole) { return false }
	let leaf = !node.children.contains { !$0.pictureOnly }
	let named = [node.title, node.description, node.value].contains { !$0.isEmpty }
	return !(leaf && named)
}

private func deepestNode(containing point: CGPoint, in root: LookNode) -> LookNode? {
	guard root.rect.contains(point), !root.pictureOnly else { return nil }
	for child in root.children.reversed() {
		if let match = deepestNode(containing: point, in: child) { return match }
	}
	return holdsContent(root) ? root : nil
}

func normalizedLabel(_ value: String) -> String {
	value.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}
