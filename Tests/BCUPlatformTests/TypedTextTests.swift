import BCUCore
@testable import BCUPlatform
import Testing

// Typing is judged on the field's value, but a value only speaks for typed text when it can
// hold it: a field that submits or empties itself on Return, or moves focus on Tab, has not
// done nothing when its value stays. A verdict of `didnt` climbs the ladder and types the text
// again, so it is given only when nothing could have happened. (A chat box that empties
// itself on Return and a masked field are covered by check-field-delivery.)

struct TypedTextTests {
	@Test(arguments: [
		(text: "abc", before: "", after: "abc" as String?, want: ActOutcome.worked),
		(text: "abc", before: "x", after: "x", want: .didnt),
		(text: "abc", before: "x", after: nil, want: .unknown),
		(text: "hi\n", before: "", after: "hi\n", want: .worked),
		(text: "a\tb", before: "", after: "ab", want: .unknown),
	])
	func theVerdictRespectsWhatTheValueCanShow(text: String, before: String, after: String?, want: ActOutcome) {
		#expect(Platform.typedOutcome(text: text, before: before, after: after) == want)
	}
}
