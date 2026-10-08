@testable import BCUPlatform
import Testing

// Only `bcu setup` may make macOS ask the user for a grant. Checking the grants before a
// command and reporting them in doctor read what the system already holds, whether or not
// the grants are there.

/// Grants that count every call able to show a system prompt.
private final class RecordingGrants: PrivacyGrants, Sendable {
	private let prompts = Handoff(0)
	let accessibility: Bool
	let screenRecording: Bool

	init(granted: Bool) {
		accessibility = granted
		screenRecording = granted
	}

	var promptCount: Int { prompts.value }

	func probeScreenCapture() -> Bool {
		prompts.value += 1
		return screenRecording
	}

	func request() -> PermissionRegistration {
		prompts.value += 1
		return PermissionRegistration(accessibility: accessibility, screenRecording: screenRecording)
	}
}

struct PrivacyPromptTests {
	@Test(arguments: [false, true])
	func checkingAndReportingTheGrantsNeverPrompts(granted: Bool) {
		let grants = RecordingGrants(granted: granted)
		let platform = Platform(grants: grants)
		let status = platform.checkPermissions()
		let diagnostics = platform.diagnostics()
		#expect(grants.promptCount == 0)
		#expect(status.accessibility == granted && status.screenRecording == granted)
		#expect(diagnostics.accessibility == granted && diagnostics.screenRecording == granted)
	}

	@Test func setupAsksForTheGrants() {
		let grants = RecordingGrants(granted: false)
		_ = Platform(grants: grants).registerPermissions()
		#expect(grants.promptCount > 0)
	}
}
