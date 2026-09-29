/// The platform calls the resident handlers make. `Platform` is the real desktop; handler
/// tests run against a fake one.
import BCUPlatform
import Foundation

protocol Desktop: Sendable {
	func listApps() -> [RunningApp]
	func listRoots(pid: Int32?, title: String?) -> [Root]
	func frontmost() throws -> Frontmost
	/// The look is built for this call and handed over, not shared.
	func look(_ request: LookRequest) throws -> sending LookResult
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
func offload<T>(_ body: @escaping @Sendable () throws -> sending T) async throws -> sending T {
	try await withCheckedThrowingContinuation { continuation in
		DispatchQueue.global().async {
			do {
				continuation.resume(returning: try body())
			} catch {
				continuation.resume(throwing: error)
			}
		}
	}
}
