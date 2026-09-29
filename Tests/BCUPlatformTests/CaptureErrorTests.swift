@testable import BCUPlatform
import BCUCore
import ScreenCaptureKit
import Testing

// A capture that ScreenCaptureKit cannot make fails with the reason the caller can act on:
// a missing Screen Recording grant, a window that is gone, or a window that cannot be captured.
struct CaptureErrorTests {
	@Test func aDeclinedGrantIsAMissingPermission() {
		let failure = captureError(SCStreamError(.userDeclined), windowId: 7)
		#expect(failure.code == .permissionMissing)
		// The running resident keeps the grant it read at start, so the way out goes through a new one.
		#expect(failure.recovery.contains("bcu stop"))
	}

	@Test func aWindowThatIsGoneIsAStaleWindow() {
		#expect(captureError(SCStreamError(.noCaptureSource), windowId: 7).code == .windowStale)
	}

	@Test func anyOtherRefusalSaysTheWindowCouldNotBeCaptured() {
		let error = captureError(SCStreamError(.failedToStart), windowId: 7)
		#expect(error.code == .actionFailed)
		#expect(error.message.contains("7"))
	}
}
