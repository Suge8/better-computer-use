import CoreGraphics
@testable import BCUPlatform
import Testing

// Agents spell key names every way their habits suggest; one that misses costs a turn.

struct KeyNameTests {
	@Test(arguments: [
		("PgDn", 121), ("Page_Down", 121), ("page-down", 121), ("Page Down", 121), ("pagedown", 121),
		("PgUp", 116), ("Page Up", 116), ("page_up", 116),
		("ArrowLeft", 123), ("left_arrow", 123), ("Left", 123),
		("DownArrow", 125), ("arrow-up", 126),
		("Forward_Delete", 117), ("forward delete", 117), ("Fwd-Delete", 117),
		("KP_Enter", 36), ("numpad enter", 36), ("ENTER", 36),
		("Bksp", 51), ("ESC", 53), ("Escape", 53),
		("-", 27), ("+", 24), ("a", 0),
	])
	func spellingsOfOneKeyResolveToIt(spelling: String, code: Int) {
		#expect(Platform().keyCode(spelling) == CGKeyCode(code))
	}
}
