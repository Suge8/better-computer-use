import CoreGraphics
@testable import BCUPlatform
import Testing

// Agents spell key names every way their habits suggest; one that misses costs a turn.

struct KeyNameTests {
	@Test(arguments: [
		("PgDn", 121), ("Page_Down", 121), ("page-down", 121),
		("Page Up", 116), ("left_arrow", 123), ("DownArrow", 125),
		("Fwd-Delete", 117), ("KP_Enter", 36), ("Bksp", 51),
		("-", 27), ("a", 0),
	])
	func spellingsOfOneKeyResolveToIt(spelling: String, code: Int) {
		#expect(Platform().keyCode(spelling) == CGKeyCode(code))
	}
}
