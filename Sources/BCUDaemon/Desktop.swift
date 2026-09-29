/// The platform calls the resident handlers make. `Platform` is the real desktop; handler
/// tests run against a fake one.
import BCUPlatform
import Foundation

protocol Desktop: Sendable {
	func listApps() -> [RunningApp]
	func listRoots(pid: Int32?, title: String?) -> [Root]
	func frontmost() throws -> Frontmost
	func look(_ request: LookRequest) throws -> LookResult
	func act(_ request: ActRequest) throws -> ActionReport
	func actBatch(_ requests: [ActRequest]) throws -> BatchReport
	func waitFor(_ request: WaitForRequest) throws -> WaitOutcome
	func readText(_ handle: Handle, offset: Int, limit: Int) throws -> TextPage
	func diagnostics() -> Diagnostics
	func checkPermissions() -> PermissionStatus
	func registerPermissions() -> PermissionRegistration
}

extension Platform: Desktop {}

/// Runs a blocking platform call on a thread of its own, so accessibility round trips and
/// screen captures never hold a thread of the cooperative pool.
func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { continuation in
		DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
	}
}
