import ApplicationServices
@testable import BCUPlatform
import Testing

// An AX action that errors may still have run, and running it again can apply it twice; only
// an error that proves the request never arrived lets bcu retry or climb to raw input.

struct ActionErrorTests {
	@Test(arguments: [
		(AXError.invalidUIElement, true), (.illegalArgument, true), (.notImplemented, true),
		(.cannotComplete, false), (.failure, false), (.actionUnsupported, false),
	])
	func onlyProofOfNonDeliveryAllowsAnotherTry(status: AXError, neverArrived: Bool) {
		#expect(Platform.actionNeverArrived(status) == neverArrived)
	}
}
