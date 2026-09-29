import ApplicationServices
import Foundation

// The outline a look returns, and how lines read from the screen join it. Kept apart from
// the bridge so the attachment rules are unit-tested without a live desktop.

struct OCRBox {
	let string: String
	let confidence: Double
	let rect: CGRect
}

final class LookNode {
	/// Role of a line read from the screen; it has no accessibility element.
	static let ocrRole = "OCR"

	let element: AXUIElement?
	let ref: String
	let role: String
	let subrole: String
	let identifier: String
	let title: String
	let description: String
	let value: String
	let actions: [String]
	let canPress: Bool
	let canFocus: Bool
	let canSetValue: Bool
	let canScroll: Bool
	let canIncrement: Bool
	let canDecrement: Bool
	let isTextInput: Bool
	let rect: CGRect
	let focused: Bool
	var offscreen: Bool
	var pictureOnly: Bool
	var truncated: Bool
	var scrollExtent: [String: Int]?
	var children: [LookNode]

	init(element: AXUIElement?, ref: String, role: String, subrole: String, identifier: String, title: String, description: String, value: String, actions: [String], canPress: Bool, canFocus: Bool, canSetValue: Bool, canScroll: Bool, canIncrement: Bool, canDecrement: Bool, isTextInput: Bool, rect: CGRect, focused: Bool = false, offscreen: Bool = false, pictureOnly: Bool = false) {
		self.element = element
		self.ref = ref
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

	func payload() -> [String: Any] {
		var output: [String: Any] = [
			"ref": ref,
			"role": role,
			"subrole": subrole,
			"identifier": identifier,
			"title": title,
			"description": description,
			"value": value,
			"actions": actions,
			"canPress": canPress,
			"canFocus": canFocus,
			"canSetValue": canSetValue,
			"canScroll": canScroll,
			"canIncrement": canIncrement,
			"canDecrement": canDecrement,
			"isTextInput": isTextInput,
			"rect": ["x": rect.origin.x, "y": rect.origin.y, "w": rect.width, "h": rect.height],
			"children": children.map { $0.payload() },
		]
		if focused { output["focused"] = true }
		if offscreen { output["offscreen"] = true }
		if pictureOnly { output["pictureOnly"] = true }
		if truncated { output["truncated"] = true }
		if let scrollExtent { output["scrollExtent"] = scrollExtent }
		return output
	}

}

/// Every line Accessibility does not already say becomes its own node, under the
/// deepest element that contains it; an agent presses it by its coordinates.
func attachOCR(_ boxes: [OCRBox], to root: LookNode) {
	for (index, box) in boxes.enumerated() where !ocrBoxDuplicatesAXLabel(box, in: root) {
		let parent = deepestNode(containing: CGPoint(x: box.rect.midX, y: box.rect.midY), in: root) ?? root
		parent.children.append(LookNode(element: nil, ref: "ocr_\(index + 1)", role: LookNode.ocrRole, subrole: "", identifier: "", title: box.string, description: "", value: "", actions: [], canPress: false, canFocus: false, canSetValue: false, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: false, rect: box.rect, pictureOnly: true))
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

private func deepestNode(containing point: CGPoint, in root: LookNode) -> LookNode? {
	guard root.rect.contains(point), !root.pictureOnly else { return nil }
	for child in root.children.reversed() {
		if let match = deepestNode(containing: point, in: child) { return match }
	}
	return root
}

func normalizedLabel(_ value: String) -> String {
	value.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}
