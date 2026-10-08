// Native controls whose delivery has side effects the accessibility value does not show.
// Arguments: the log file, then the window title. `chat` is a text field that, like a chat
// box, clears itself on Return and logs `submit <text>`; Tab in it logs `tab`. `secret` is a
// secure field that logs `secret <character count>` on Return and clears. `slow` is a button whose
// action logs `slow` and then keeps the main thread busy for 2.5 s, so an AXPress on it fails
// with a timeout although the action did start. It prints `ready` once the window is on screen.
import AppKit

final class Fields: NSObject, NSTextFieldDelegate {
	let log: URL

	init(log: URL) { self.log = log }

	func append(_ line: String) {
		let handle = try! FileHandle(forWritingTo: log)
		handle.seekToEndOfFile()
		handle.write(Data((line + "\n").utf8))
		try! handle.close()
	}

	func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
		switch selector {
		case #selector(NSResponder.insertNewline(_:)):
			append(control is NSSecureTextField ? "secret \(control.stringValue.count)" : "submit \(control.stringValue)")
			control.stringValue = ""
			return true
		case #selector(NSResponder.insertTab(_:)):
			append("tab")
			return true
		default:
			return false
		}
	}

	@objc func slowAction(_ sender: NSButton) {
		append("slow")
		Thread.sleep(forTimeInterval: 2.5)
	}

}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let log = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: log.path, contents: nil)
let fields = Fields(log: log)
let window = NSWindow(contentRect: NSRect(x: 260, y: 140, width: 420, height: 200), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = CommandLine.arguments[2]
let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
func place(_ field: NSTextField, label: String, y: CGFloat) {
	field.frame = NSRect(x: 20, y: y, width: 380, height: 24)
	field.setAccessibilityLabel(label)
	field.delegate = fields
	content.addSubview(field)
}
place(NSTextField(string: ""), label: "chat", y: 150)
place(NSSecureTextField(string: ""), label: "secret", y: 110)
let slow = NSButton(title: "slow", target: fields, action: #selector(Fields.slowAction(_:)))
slow.frame = NSRect(x: 160, y: 60, width: 120, height: 28)
content.addSubview(slow)
window.contentView = content
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async {
	print("ready")
	fflush(stdout)
}
app.run()
