@testable import BCUPlatform
import Testing

// Tk and LibreOffice's VCL drop pointer events posted to a pid: Tk reads the pointer from the
// hardware, VCL ignores the event. Such an app is recognized by the libraries it maps.

struct PointerToolkitTests {
	@Test(arguments: [
		"/System/Library/Frameworks/Tk.framework/Versions/8.5/Tk",
		"/opt/homebrew/opt/tcl-tk/lib/libtk8.6.dylib",
		"/usr/local/lib/libtcl9tk9.0.dylib",
		"/opt/homebrew/lib/python3.12/lib-dynload/_tkinter.cpython-312-darwin.so",
		"/Applications/LibreOffice.app/Contents/Frameworks/libvclplug_osxlo.dylib",
	])
	func aMappedToolkitLibraryIsRecognized(path: String) {
		#expect(PointerToolkit.mapped(inImagePath: path) != nil)
	}

	@Test(arguments: [
		"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
		"/usr/lib/libtcl8.6.dylib",
		"/opt/homebrew/lib/libtkrzw.dylib",
		"/Applications/LibreOffice.app/Contents/Frameworks/libvcllo.dylib",
	])
	func otherLibrariesAreNot(path: String) {
		#expect(PointerToolkit.mapped(inImagePath: path) == nil)
	}
}
