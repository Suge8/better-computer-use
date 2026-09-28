// The user's own front app, as a background action must leave it: in front, with its key
// window still taking the keyboard. It activates itself with a focused text field and
// appends `resigned` to the log file given as the first argument whenever its window stops
// being key or the app stops being active. It prints `ready` once it is key and in front,
// and again after each SIGUSR1, which makes it take the front back.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let log = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: log.path, contents: nil)
func append(_ line: String) {
	let handle = try! FileHandle(forWritingTo: log)
	handle.seekToEndOfFile()
	handle.write(Data((line + "\n").utf8))
	try! handle.close()
}
let window = NSWindow(contentRect: NSRect(x: 760, y: 320, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "bcu key holder"
let field = NSTextField(frame: NSRect(x: 20, y: 25, width: 260, height: 30))
window.contentView!.addSubview(field)
for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
	NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in append("resigned") }
}
var announced = false
func announceWhenReady() {
	guard !announced, app.isActive, window.isKeyWindow else { return }
	announced = true
	print("ready")
	fflush(stdout)
}
for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
	NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in announceWhenReady() }
}
func takeFront() {
	announced = false
	window.makeKeyAndOrderFront(nil)
	window.makeFirstResponder(field)
	// A process started from a terminal is not granted activation cooperatively.
	app.activate(ignoringOtherApps: true)
	announceWhenReady()
}
signal(SIGUSR1, SIG_IGN)
let takeFrontSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
takeFrontSignal.setEventHandler(handler: takeFront)
takeFrontSignal.resume()
takeFront()
app.run()
