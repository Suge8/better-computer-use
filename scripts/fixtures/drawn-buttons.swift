// A window that draws its own controls and exposes nothing of them to Accessibility, the
// way WeChat, Qt and game windows look to bcu. Pressing a button appends its label to the
// log file given as the first argument; the second argument is the window title. 发送 and
// 取消 show what was pressed in a band above the buttons; 静默 changes nothing on screen. Like a stock
// NSView it does not accept the first click on an inactive window. One standard NSButton,
// the toggle 原生, is the only Accessibility content; toggling it logs 原生 too.
// Above the buttons is a list of rows 行1…行40 that scrolls itself on wheel events over it
// the way a Qt list (WeChat's conversation list) does: by whole rows, three per wheel notch.
// A notch is 120 units; a line-based wheel event is one notch whatever its size, and a
// precise (pixel) delta counts 2 units per pixel, so a few pixels accumulate below one notch
// and move nothing. It logs `scroll <first row shown>` whenever that changes. Beside it,
// a block 块 follows a mouse drag started on it and logs `drag <x>,<y>`, its new origin in
// view points, when the drag ends. It prints `ready` once the window is on screen.
import AppKit

final class ButtonsView: NSView {
	static let labels = ["发送", "取消", "静默"]
	static let silent = "静默"
	static let list = NSRect(x: 30, y: 180, width: 180, height: 180)
	static let rowHeight: CGFloat = 36
	static let rows = 40
	static let blockSize: CGFloat = 60
	static let statusBand = NSRect(x: 30, y: 146, width: 380, height: 26)
	let log: URL
	var status = ""
	var firstRow = 0
	var pendingUnits: CGFloat = 0
	var block = NSPoint(x: 250, y: 240)
	var dragFrom: NSPoint?

	init(log: URL) {
		self.log = log
		super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 380))
		let native = NSButton(title: "原生", target: nil, action: nil)
		native.frame = NSRect(x: 165, y: 20, width: 100, height: 28)
		native.setButtonType(.pushOnPushOff)
		native.target = self
		native.action = #selector(nativeClicked(_:))
		addSubview(native)
	}

	required init?(coder: NSCoder) { fatalError("unused") }

	func buttonRect(_ index: Int) -> NSRect { NSRect(x: 30 + CGFloat(index) * 140, y: 80, width: 110, height: 56) }
	var blockRect: NSRect { NSRect(origin: block, size: NSSize(width: Self.blockSize, height: Self.blockSize)) }

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
		if !status.isEmpty {
			// A band wide enough that the press shows as more than a sliver of the window.
			NSColor.systemGreen.setFill()
			Self.statusBand.fill()
			NSAttributedString(string: status, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: Self.statusBand.minX + 8, y: Self.statusBand.minY + 2))
		}
		drawList()
		NSColor.systemOrange.setFill()
		NSBezierPath(roundedRect: blockRect, xRadius: 8, yRadius: 8).fill()
		NSAttributedString(string: "块", attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: block.x + 18, y: block.y + 16))
	}

	func drawList() {
		NSGraphicsContext.saveGraphicsState()
		NSBezierPath(rect: Self.list).addClip()
		for index in 0..<Self.rows {
			let top = Self.list.maxY - CGFloat(index + 1 - firstRow) * Self.rowHeight
			NSAttributedString(string: "行 \(index + 1)", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.black])
				.draw(at: NSPoint(x: Self.list.minX + 12, y: top + 4))
		}
		NSGraphicsContext.restoreGraphicsState()
		NSColor.systemGray.setStroke()
		NSBezierPath(rect: Self.list).stroke()
	}

	override func scrollWheel(with event: NSEvent) {
		guard Self.list.contains(convert(event.locationInWindow, from: nil)) else { return }
		pendingUnits += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 2 : (event.deltaY > 0 ? 120 : event.deltaY < 0 ? -120 : 0)
		let notches = Int(pendingUnits / 120)
		guard notches != 0 else { return }
		pendingUnits -= CGFloat(notches * 120)
		let visible = Int(Self.list.height / Self.rowHeight)
		let next = min(max(firstRow - notches * 3, 0), Self.rows - visible)
		guard next != firstRow else { return }
		firstRow = next
		append("scroll \(firstRow + 1)")
		needsDisplay = true
	}

	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		if blockRect.contains(point) {
			dragFrom = point
			return
		}
		guard let index = Self.labels.indices.first(where: { buttonRect($0).contains(point) }) else { return }
		append(Self.labels[index])
		guard Self.labels[index] != Self.silent else { return }
		status = "已按\(Self.labels[index])"
		needsDisplay = true
	}

	override func mouseDragged(with event: NSEvent) {
		guard let from = dragFrom else { return }
		let point = convert(event.locationInWindow, from: nil)
		block.x += point.x - from.x
		block.y += point.y - from.y
		dragFrom = point
		needsDisplay = true
	}

	override func mouseUp(with event: NSEvent) {
		guard dragFrom != nil else { return }
		dragFrom = nil
		append("drag \(Int(block.x)),\(Int(block.y))")
	}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let log = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: log.path, contents: nil)
let window = NSWindow(contentRect: NSRect(x: 240, y: 120, width: 440, height: 380), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = CommandLine.arguments[2]
window.contentView = ButtonsView(log: log)
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async {
	print("ready")
	fflush(stdout)
}
app.run()
