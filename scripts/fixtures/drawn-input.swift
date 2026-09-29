// A text input that draws itself and exposes nothing to Accessibility, the way the message
// box of WeChat or a Qt window looks to bcu. It takes text only through the input method
// (NSTextInputClient), so an active IME sees every key it gets, and appends each committed
// string, unseparated, to the log file given as the first argument; the second argument is
// the window title. The box is labelled 输入区 and shows what it holds. A click inside the
// box makes it first responder. Like a stock NSView it does not accept the first click on an
// inactive window. The third argument is an event log: every change of the input method's
// uncommitted (marked) text appends `marked <text>`, and, the way some apps show search
// results only while they are active, each commit made while NSApp.isActive shows a result
// area below the box and appends `popup <text so far>`; a commit made while inactive shows
// nothing. It prints `ready` once on screen.
import AppKit

final class InputView: NSView, NSTextInputClient {
	static let box = NSRect(x: 30, y: 40, width: 380, height: 60)
	static let results = NSRect(x: 30, y: 4, width: 380, height: 30)
	let log: URL
	let events: URL
	var committed = ""
	var marked = ""
	var popup: String?

	init(log: URL, events: URL) {
		self.log = log
		self.events = events
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
		if let popup {
			NSColor.systemYellow.setFill()
			Self.results.fill()
			NSAttributedString(string: "结果 " + popup, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
				.draw(at: NSPoint(x: Self.results.minX + 8, y: Self.results.minY + 4))
		}
	}

	func append(_ data: String, to file: URL) {
		let handle = try! FileHandle(forWritingTo: file)
		handle.seekToEndOfFile()
		handle.write(Data(data.utf8))
		try! handle.close()
	}

	func insertText(_ string: Any, replacementRange: NSRange) {
		let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
		setMarked("")
		committed += text
		append(text, to: log)
		if NSApp.isActive {
			popup = committed
			append("popup \(committed)\n", to: events)
		}
		needsDisplay = true
	}

	func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		setMarked((string as? NSAttributedString)?.string ?? string as? String ?? "")
	}

	func setMarked(_ text: String) {
		guard text != marked else { return }
		marked = text
		append("marked \(text)\n", to: events)
		needsDisplay = true
	}

	func unmarkText() { setMarked("") }
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
let events = URL(fileURLWithPath: CommandLine.arguments[3])
for file in [log, events] { FileManager.default.createFile(atPath: file.path, contents: nil) }
let window = NSWindow(contentRect: NSRect(x: 240, y: 520, width: 440, height: 140), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = CommandLine.arguments[2]
window.contentView = InputView(log: log, events: events)
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async {
	print("ready")
	fflush(stdout)
}
app.run()
