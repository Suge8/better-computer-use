import ApplicationServices
@testable import BCUPlatform
import Testing

// An AX action that errors may still have run, and running it again can apply it twice; only
// an error that proves the request never arrived lets bcu retry or climb to raw input.

struct ActionErrorTests {
	@Test(arguments: [AXError.invalidUIElement, .illegalArgument, .actionUnsupported, .notImplemented])
	func theseErrorsProveNothingWasDelivered(status: AXError) {
		#expect(Platform.actionNeverArrived(status))
	}

	@Test(arguments: [AXError.success, .failure, .cannotComplete, .attributeUnsupported])
	func otherErrorsLeaveItUnknown(status: AXError) {
		#expect(!Platform.actionNeverArrived(status))
	}
}
