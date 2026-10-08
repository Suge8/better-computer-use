// A notes window as an app with dropdowns and dialogs shows it: a font popup whose menu exists
// only while open, a "New note…" button that raises a sheet with a Name field and Create and
// Cancel buttons, and labels showing the last font and note. It appends `font <name>` and
// `created <name>` to the log file given as the first argument, takes the window title from
// the second, and prints `ready` once the window is on screen, without taking the front.
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

final class Form: NSObject {
	let window = NSWindow(contentRect: NSRect(x: 760, y: 320, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
	let fontLabel = NSTextField(labelWithString: "font: Helvetica")
	let docLabel = NSTextField(labelWithString: "note: none")
	let nameField = NSTextField(frame: NSRect(x: 20, y: 70, width: 320, height: 24))
	let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130), styleMask: [.titled], backing: .buffered, defer: false)

	func build() {
		window.title = CommandLine.arguments[2]
		let content = window.contentView!
		let popup = NSPopUpButton(frame: NSRect(x: 20, y: 150, width: 160, height: 26), pullsDown: false)
		popup.addItems(withTitles: ["Helvetica", "Times", "Courier"])
		popup.setAccessibilityLabel("Font")
		popup.target = self
		popup.action = #selector(fontChosen(_:))
		let new = NSButton(title: "New note…", target: self, action: #selector(openSheet))
		new.frame = NSRect(x: 200, y: 150, width: 120, height: 26)
		fontLabel.frame = NSRect(x: 20, y: 100, width: 380, height: 20)
		docLabel.frame = NSRect(x: 20, y: 70, width: 380, height: 20)
		for view in [popup, new, fontLabel, docLabel] { content.addSubview(view) }

		let sheetContent = sheet.contentView!
		nameField.frame = NSRect(x: 20, y: 80, width: 320, height: 24)
		nameField.setAccessibilityLabel("Name")
		let create = NSButton(title: "Create", target: self, action: #selector(create))
		create.frame = NSRect(x: 250, y: 20, width: 90, height: 28)
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
		cancel.frame = NSRect(x: 150, y: 20, width: 90, height: 28)
		for view in [nameField, create, cancel] { sheetContent.addSubview(view) }
	}

	@objc func fontChosen(_ sender: NSPopUpButton) {
		let font = sender.titleOfSelectedItem ?? ""
		fontLabel.stringValue = "font: \(font)"
		append("font \(font)")
	}

	@objc func openSheet() {
		nameField.stringValue = ""
		window.beginSheet(sheet)
	}

	@objc func create() {
		docLabel.stringValue = "note: \(nameField.stringValue)"
		append("created \(nameField.stringValue)")
		window.endSheet(sheet)
	}

	@objc func cancel() {
		window.endSheet(sheet)
	}
}

let form = Form()
form.build()
form.window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
	print("ready")
	fflush(stdout)
}
app.run()
