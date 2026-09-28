// A window that draws its own text buttons and exposes nothing to Accessibility, the way
// WeChat, Qt and game windows look to bcu. Pressing a button appends its label to the log
// file given as the first argument; the second argument is the window title. It prints
// `ready` once the window is on screen.
import AppKit

final class ButtonsView: NSView {
	static let labels = ["发送", "取消"]
	let log: URL

	init(log: URL) {
		self.log = log
		super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
	}

	required init?(coder: NSCoder) { fatalError("unused") }

	func buttonRect(_ index: Int) -> NSRect { NSRect(x: 40 + CGFloat(index) * 190, y: 60, width: 150, height: 56) }

	override func draw(_ dirtyRect: NSRect) {
		NSColor.white.setFill()
		bounds.fill()
		for (index, label) in Self.labels.enumerated() {
			let rect = buttonRect(index)
			NSColor.systemBlue.setFill()
			NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
			let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
			let size = text.size()
			text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
		}
	}

	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		guard let index = Self.labels.indices.first(where: { buttonRect($0).contains(point) }) else { return }
		let handle = try! FileHandle(forWritingTo: log)
		handle.seekToEndOfFile()
		handle.write(Data((Self.labels[index] + "\n").utf8))
		try! handle.close()
	}

	override func isAccessibilityElement() -> Bool { false }
	override func accessibilityChildren() -> [Any]? { [] }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let log = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: log.path, contents: nil)
let window = NSWindow(contentRect: NSRect(x: 240, y: 320, width: 420, height: 180), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = CommandLine.arguments[2]
window.contentView = ButtonsView(log: log)
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async {
	print("ready")
	fflush(stdout)
}
app.run()
