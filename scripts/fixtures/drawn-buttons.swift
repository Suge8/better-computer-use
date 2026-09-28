// A window that draws its own text buttons and exposes nothing of them to Accessibility, the
// way WeChat, Qt and game windows look to bcu. Pressing a button appends its label to the
// log file given as the first argument; the second argument is the window title. 发送 and
// 取消 draw what was pressed below the buttons; 静默 changes nothing on screen. Like a stock
// NSView it does not accept the first click on an inactive window. One standard NSButton,
// the toggle 原生, is the only Accessibility content; toggling it logs 原生 too. It prints
// `ready` once the window is on screen.
import AppKit

final class ButtonsView: NSView {
	static let labels = ["发送", "取消", "静默"]
	static let silent = "静默"
	let log: URL
	var status = ""

	init(log: URL) {
		self.log = log
		super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
		let native = NSButton(title: "原生", target: nil, action: nil)
		native.frame = NSRect(x: 165, y: 20, width: 100, height: 28)
		native.setButtonType(.pushOnPushOff)
		native.target = self
		native.action = #selector(nativeClicked(_:))
		addSubview(native)
	}

	required init?(coder: NSCoder) { fatalError("unused") }

	func buttonRect(_ index: Int) -> NSRect { NSRect(x: 30 + CGFloat(index) * 140, y: 80, width: 110, height: 56) }

	@objc func nativeClicked(_ sender: NSButton) { append("原生") }

	func append(_ label: String) {
		let handle = try! FileHandle(forWritingTo: log)
		handle.seekToEndOfFile()
		handle.write(Data((label + "\n").utf8))
		try! handle.close()
	}

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
		NSAttributedString(string: status, attributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 30, y: 24))
	}

	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		guard let index = Self.labels.indices.first(where: { buttonRect($0).contains(point) }) else { return }
		append(Self.labels[index])
		guard Self.labels[index] != Self.silent else { return }
		status = "已按\(Self.labels[index])"
		needsDisplay = true
	}

}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let log = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: log.path, contents: nil)
let window = NSWindow(contentRect: NSRect(x: 240, y: 320, width: 440, height: 180), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = CommandLine.arguments[2]
window.contentView = ButtonsView(log: log)
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async {
	print("ready")
	fflush(stdout)
}
app.run()
