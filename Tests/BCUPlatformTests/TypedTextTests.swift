import BCUCore
@testable import BCUPlatform
import Testing

// Typing is judged on the field's value, but a value only speaks for typed text when it can
// hold it: a field that submits or empties itself on Return, moves focus on Tab, or masks
// what it holds has not done nothing when its value stays. A verdict of `didnt` climbs the
// ladder and types the text again, so it is given only when nothing could have happened.

struct TypedTextTests {
	@Test(arguments: [
		// Plain text: the value either took it or the typing did nothing.
		(text: "abc", before: "" as String?, after: "abc" as String?, masked: false, want: ActOutcome.worked),
		(text: "abc", before: "x", after: "x", masked: false, want: .didnt),
		// A line break or tab: only the full text in the value proves it; otherwise the field
		// may have submitted, been emptied or moved on.
		(text: "hi\n", before: "", after: "hi\n", masked: false, want: .worked),
		(text: "hi\n", before: "", after: "", masked: false, want: .unknown),
		(text: "hi\n", before: "old", after: "old", masked: false, want: .unknown),
		(text: "a\tb", before: "", after: "ab", masked: false, want: .unknown),
		// A mask or an unreadable value says nothing about what was typed.
		(text: "abc", before: "", after: "\u{2022}\u{2022}\u{2022}", masked: true, want: .unknown),
		(text: "abc", before: "\u{2022}", after: "\u{2022}", masked: true, want: .unknown),
		(text: "abc", before: nil, after: nil, masked: false, want: .unknown),
	])
	func theVerdictRespectsWhatTheValueCanShow(text: String, before: String?, after: String?, masked: Bool, want: ActOutcome) {
		#expect(Platform.typedOutcome(text: text, before: before, after: after, masked: masked) == want)
	}
}
