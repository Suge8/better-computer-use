import AppKit
import BCUCore

extension Platform {
	/// The real key a typed line break or tab stands for. Everything else is typed as the
	/// character itself; see `postUnicodeText`.
	static func keyTyped(as character: Character) -> String? {
		switch character {
		case "\n", "\r", "\r\n": "return"
		case "\t": "tab"
		default: nil
		}
	}

	/// Whether typing `text` presses Return or Tab, which a field may answer by submitting,
	/// emptying itself or moving focus instead of keeping the text.
	static func typesKeystrokes(_ text: String) -> Bool {
		text.contains { keyTyped(as: $0) != nil }
	}

	/// Judges typed text on the field's value, which only speaks for it when it can hold it.
	/// A `didnt` climbs the ladder and types the text again, so it is given only when nothing
	/// could have happened: not when the value became unreadable, and not when the text
	/// presses Return or Tab, after which a chat box is empty again. Those need the full text
	/// in the value to be `worked`.
	static func typedOutcome(text: String, before: String, after: String?) -> ActOutcome {
		guard let after else { return .unknown }
		let keystrokes = typesKeystrokes(text)
		if after != before { return keystrokes && !after.contains(text) ? .unknown : .worked }
		return keystrokes ? .unknown : .didnt
	}

	/// Waits for `text` typed into `element` to show in its value and judges the typing.
	/// Nothing is waited for, and no value is reported, when the value is masked (a secure
	/// field's value is bullets or plaintext, never evidence to hand back) or was unreadable.
	func judgeTyped(_ text: String, in element: AXUIElement, pid: Int32, valueBefore: String?) throws -> (outcome: ActOutcome, evidence: ActEvidence?) {
		let masked = isSecureTextElement(
			role: stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? "",
			subrole: stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		)
		guard !masked, let valueBefore else { return (.unknown, nil) }
		var valueAfter: String? = valueBefore
		var outcome = ActOutcome.unknown
		_ = try awaitChange(in: pid, timeout: Self.evidenceTimeout) {
			valueAfter = attributeSignature(element, attribute: kAXValueAttribute as CFString)
			outcome = Self.typedOutcome(text: text, before: valueBefore, after: valueAfter)
			return outcome == .worked
		}
		guard outcome == .worked else { return (outcome, nil) }
		return (outcome, ActEvidence(source: .ax, field: .value, from: evidenceExcerpt(valueBefore), to: evidenceExcerpt(valueAfter ?? "")))
	}
}
