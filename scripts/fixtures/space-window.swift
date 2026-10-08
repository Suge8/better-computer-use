// A window that can be sent to a Space of its own and appends what reaches it to the log file
// given as the first argument (the second is the window title): `pressed` for its button,
// `click x y` for its drawn pad, and `text <contents>` after every edit of its text field. It
// prints `ready` once on screen. SIGUSR1 makes the window full screen, which gives it a Space,
// and then switches the display back to the Space it came from, so the window is left on
// another Space; `offspace` is printed when that is done. SIGUSR2 switches the display to the
// window's Space (`shown`) and back (`hidden`). Quitting the app removes the Space.
import AppKit

final class Pad: NSView {
	let log: (String) -> Void
	init(frame: NSRect, log: @escaping (String) -> Void) {
		self.log = log
		super.init(frame: frame)
	}
	required init?(coder: NSCoder) { fatalError("unused") }
	override var acceptsFirstResponder: Bool { true }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		log("click \(Int(point.x)) \(Int(point.y))")
	}
	override func draw(_ dirtyRect: NSRect) {
		NSColor.systemOrange.setFill()
		bounds.fill()
	}
}

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
	let logURL = URL(fileURLWithPath: CommandLine.arguments[1])
	var window: NSWindow!
	var homeSpace: UInt64 = 0
	var windowSpace: UInt64 = 0

	func log(_ line: String) {
		let handle = try! FileHandle(forWritingTo: logURL)
		handle.seekToEndOfFile()
		handle.write(Data((line + "\n").utf8))
		try! handle.close()
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		FileManager.default.createFile(atPath: logURL.path, contents: nil)
		window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 480, height: 260), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
		window.title = CommandLine.arguments[2]
		window.collectionBehavior = [.fullScreenPrimary]
		window.delegate = self
		let content = window.contentView!
		let button = NSButton(title: "Press me", target: self, action: #selector(pressed))
		button.frame = NSRect(x: 20, y: 200, width: 120, height: 32)
		let field = NSTextField(frame: NSRect(x: 160, y: 200, width: 280, height: 28))
		field.setAccessibilityLabel("Space input")
		field.delegate = self
		content.addSubview(button)
		content.addSubview(field)
		content.addSubview(Pad(frame: NSRect(x: 20, y: 20, width: 200, height: 100), log: log))
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(field)
		NSApp.activate(ignoringOtherApps: true)
		print("ready")
		fflush(stdout)
	}

	@objc func pressed() { log("pressed") }

	func controlTextDidChange(_ notification: Notification) {
		log("text " + ((notification.object as? NSTextField)?.stringValue ?? ""))
	}

	func sendToOtherSpace() {
		homeSpace = Spaces.active
		window.toggleFullScreen(nil)
	}

	func toggleShown() {
		let showing = Spaces.active != windowSpace
		Spaces.show(showing ? windowSpace : homeSpace)
		print(showing ? "shown" : "hidden")
		fflush(stdout)
	}

	func windowDidEnterFullScreen(_ notification: Notification) {
		windowSpace = Spaces.active
		Spaces.show(homeSpace)
		print("offspace")
		fflush(stdout)
	}
}

enum Spaces {
	private typealias Connection = @convention(c) () -> UInt32
	private typealias Active = @convention(c) (UInt32) -> UInt64
	private typealias Displays = @convention(c) (UInt32) -> Unmanaged<CFArray>?
	private typealias SetCurrent = @convention(c) (UInt32, CFString, UInt64) -> Void
	private static func symbol<T>(_ name: String, as _: T.Type) -> T {
		_ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
		return unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)!, to: T.self)
	}
	static var active: UInt64 { symbol("SLSGetActiveSpace", as: Active.self)(symbol("CGSMainConnectionID", as: Connection.self)()) }
	static func show(_ space: UInt64) {
		let connection = symbol("CGSMainConnectionID", as: Connection.self)()
		let displays = symbol("SLSCopyManagedDisplaySpaces", as: Displays.self)(connection)!.takeRetainedValue() as! [[String: Any]]
		let display = displays.first { ($0["Spaces"] as! [[String: Any]]).contains { $0["id64"] as? UInt64 == space } }!
		symbol("SLSManagedDisplaySetCurrentSpace", as: SetCurrent.self)(connection, display["Display Identifier"] as! CFString, space)
	}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
signal(SIGUSR1, SIG_IGN)
let toSpace = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
toSpace.setEventHandler { delegate.sendToOtherSpace() }
toSpace.resume()
signal(SIGUSR2, SIG_IGN)
let toggle = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
toggle.setEventHandler { delegate.toggleShown() }
toggle.resume()
app.run()
