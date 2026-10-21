// A window with an "Add one" button and a "count N" label it raises. Every press the app
// handles appends `pressed` to the log file given as the first argument, so a test can count
// deliveries, and every Accessibility read of the label appends `read count N`, so a test
// can see what a reader saw. SIGUSR1 raises a second label, "nudge N", waking whoever waits
// on the app without touching the count. It takes the window title from the second argument
// and prints `ready` once the window is on screen, without taking the front.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let log = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: log.path, contents: nil)

func append(_ line: String) {
	let handle = try! FileHandle(forWritingTo: log)
	handle.seekToEndOfFile()
	handle.write(Data("\(line)\n".utf8))
	try! handle.close()
}

final class Label: NSTextField {
	override func accessibilityValue() -> String? {
		append("read \(stringValue)")
		return super.accessibilityValue()
	}
}

final class Counter: NSObject {
	let window = NSWindow(contentRect: NSRect(x: 780, y: 360, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
	let label = Label(labelWithString: "count 0")
	let nudges = NSTextField(labelWithString: "nudge 0")
	var count = 0
	var nudged = 0

	func build() {
		window.title = CommandLine.arguments[2]
		let add = NSButton(title: "Add one", target: self, action: #selector(add(_:)))
		add.frame = NSRect(x: 20, y: 50, width: 120, height: 30)
		label.frame = NSRect(x: 160, y: 55, width: 140, height: 20)
		nudges.frame = NSRect(x: 160, y: 20, width: 140, height: 20)
		window.contentView!.addSubview(add)
		window.contentView!.addSubview(label)
		window.contentView!.addSubview(nudges)
		window.orderFront(nil)
	}

	@objc func add(_ sender: NSButton) {
		count += 1
		label.stringValue = "count \(count)"
		append("pressed")
	}

	func nudge() {
		nudged += 1
		nudges.stringValue = "nudge \(nudged)"
	}
}

let counter = Counter()
counter.build()
signal(SIGUSR1, SIG_IGN)
let nudge = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
nudge.setEventHandler { counter.nudge() }
nudge.resume()
print("ready")
fflush(stdout)
app.run()
