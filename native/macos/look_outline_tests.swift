import CoreGraphics
import Foundation

// A line read from the screen joins the deepest container around it. Window controls and
// leaf controls that already have a name are not containers: a line over them belongs to
// the element that holds them.
@main
struct LookOutlineTests {
	static func main() {
		testOCRParents()
		print("PASS look outline OCR attachment")
	}

	private static func node(_ ref: String, role: String, subrole: String = "", title: String = "", value: String = "", rect: CGRect, children: [LookNode] = []) -> LookNode {
		let node = LookNode(element: nil, ref: ref, role: role, subrole: subrole, identifier: "", title: title, description: "", value: value, actions: [], canPress: role == "AXButton", canFocus: false, canSetValue: false, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: false, rect: rect)
		node.children = children
		return node
	}

	private static func box(_ text: String, centeredIn rect: CGRect) -> OCRBox {
		OCRBox(string: text, confidence: 1, rect: CGRect(x: rect.midX - 4, y: rect.midY - 3, width: 8, height: 6))
	}

	private static func testOCRParents() {
		let minimize = node("min", role: "AXButton", subrole: "AXMinimizeButton", rect: CGRect(x: 30, y: 10, width: 14, height: 14))
		let close = node("close", role: "AXButton", subrole: "AXCloseButton", rect: CGRect(x: 10, y: 10, width: 14, height: 14))
		let send = node("send", role: "AXButton", title: "Send", rect: CGRect(x: 600, y: 500, width: 80, height: 30))
		let icon = node("icon", role: "AXButton", rect: CGRect(x: 100, y: 500, width: 40, height: 40))
		let label = node("label", role: "AXStaticText", value: "Hello", rect: CGRect(x: 200, y: 200, width: 100, height: 20))
		let pane = node("pane", role: "AXGroup", rect: CGRect(x: 0, y: 100, width: 800, height: 380), children: [label])
		let window = node("window", role: "AXWindow", title: "Chat", rect: CGRect(x: 0, y: 0, width: 800, height: 600), children: [close, minimize, pane, send, icon])

		attachOCR([
			box("文件传输助手", centeredIn: minimize.rect),
			box("最小化", centeredIn: close.rect),
			box("发送", centeredIn: send.rect),
			box("表情", centeredIn: icon.rect),
			box("World", centeredIn: label.rect),
			box("Pane text", centeredIn: CGRect(x: 400, y: 400, width: 10, height: 10)),
		], to: window)

		func lines(_ node: LookNode) -> [String] {
			node.children.filter(\.pictureOnly).map(\.title)
		}
		expect(lines(minimize).isEmpty && lines(close).isEmpty, "a line over a window control was attached to the control: \(lines(minimize) + lines(close))")
		expect(lines(send).isEmpty, "a line over a named button was attached to the button: \(lines(send))")
		expect(lines(label).isEmpty, "a line over named text was attached to the text: \(lines(label))")
		expect(lines(window) == ["文件传输助手", "最小化", "发送"], "lines over controls did not join the window that holds them: \(lines(window))")
		expect(lines(icon) == ["表情"], "an unnamed control lost the line that names it: \(lines(icon))")
		expect(lines(pane) == ["World", "Pane text"], "lines inside a container did not join it: \(lines(pane))")
	}

	private static func expect(_ condition: Bool, _ message: String) {
		if !condition {
			FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
			exit(1)
		}
	}
}
