// A text input that draws itself and exposes nothing to Accessibility, the way the message
// box of WeChat or a Qt window looks to bcu. It takes text only through the input method
// (NSTextInputClient), so an active IME sees every key it gets, and appends each committed
// string, unseparated, to the log file given as the first argument; the second argument is
// the window title. The box is labelled 输入区 and shows what it holds. A click inside the box makes it first responder. Like a stock NSView it
// does not accept the first click on an inactive window. It prints `ready` once on screen.
import AppKit

final class InputView: NSView, NSTextInputClient {
	static let box = NSRect(x: 30, y: 40, width: 380, height: 60)
	let log: URL
	var committed = ""
	var marked = ""

	init(log: URL) {
		self.log = log
		super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 140))
	}

	required init?(coder: NSCoder) { fatalError("unused") }

	override var acceptsFirstResponder: Bool { true }

	override func mouseDown(with event: NSEvent) {
		if Self.box.contains(convert(event.locationInWindow, from: nil)) { window?.makeFirstResponder(self) }
	}

	override func keyDown(with event: NSEvent) { inputContext?.handleEvent(event) }

	override func draw(_ dirtyRect: NSRect) {
		NSColor.white.setFill()
		bounds.fill()
		NSColor.systemGray.setStroke()
		NSBezierPath(rect: Self.box).stroke()
		let font = NSFont.systemFont(ofSize: 24)
		NSAttributedString(string: "输入区", attributes: [.font: font, .foregroundColor: NSColor.systemGray])
			.draw(at: NSPoint(x: Self.box.minX + 12, y: Self.box.minY + 16))
		NSAttributedString(string: committed + marked, attributes: [.font: font, .foregroundColor: NSColor.black])
			.draw(at: NSPoint(x: Self.box.minX + 110, y: Self.box.minY + 16))
	}

	func insertText(_ string: Any, replacementRange: NSRange) {
		let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
		marked = ""
		committed += text
		let handle = try! FileHandle(forWritingTo: log)
		handle.seekToEndOfFile()
		handle.write(Data(text.utf8))
		try! handle.close()
		needsDisplay = true
	}

	func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
		needsDisplay = true
	}

	func unmarkText() { marked = "" }
	override func doCommand(by selector: Selector) {}
	func hasMarkedText() -> Bool { !marked.isEmpty }
	func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: committed.utf16.count, length: marked.utf16.count) }
	func selectedRange() -> NSRange { NSRange(location: committed.utf16.count + marked.utf16.count, length: 0) }
	func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
	func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
	func characterIndex(for point: NSPoint) -> Int { committed.utf16.count }
	func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
		window?.convertToScreen(convert(Self.box, to: nil)) ?? .zero
	}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let log = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: log.path, contents: nil)
let window = NSWindow(contentRect: NSRect(x: 240, y: 520, width: 440, height: 140), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = CommandLine.arguments[2]
window.contentView = InputView(log: log)
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async {
	print("ready")
	fflush(stdout)
}
app.run()
