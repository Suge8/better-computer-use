@testable import BCUPlatform
import Testing

// Tk drops pointer events posted to a pid, and an app is recognized by the libraries it maps.
// Missing one costs an unverified click; taking another library for Tk sends the app's
// clicks through the foreground for nothing.

struct PointerToolkitTests {
	@Test(arguments: [
		("/System/Library/Frameworks/Tk.framework/Versions/8.5/Tk", true),
		("/opt/homebrew/opt/tcl-tk/lib/libtk8.6.dylib", true),
		("/usr/local/lib/libtcl9tk9.0.dylib", true),
		("/opt/homebrew/lib/python3.12/lib-dynload/_tkinter.cpython-312-darwin.so", true),
		("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", false),
		("/usr/lib/libtcl8.6.dylib", false),
		("/opt/homebrew/lib/libtkrzw.dylib", false),
	])
	func aMappedTkLibraryIsRecognized(path: String, isTk: Bool) {
		#expect(Tk.isImage(path: path) == isTk)
	}
}
