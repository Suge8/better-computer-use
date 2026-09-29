import BCUCore
import BCUPlatform
import BCURuntime
import os

/// A root under a stable `@r` ref: equal when the platform names the same root.
struct RegisteredRoot: Equatable, Sendable {
	let handle: Handle
	let pid: Int32
	let appName: String
	let bundleId: String?

	static func == (lhs: RegisteredRoot, rhs: RegisteredRoot) -> Bool {
		lhs.handle == rhs.handle
	}
}

/// One saved observation: the root it looked at, its outline and the platform handles
/// behind the outline's refs. Evicting the state releases the handles.
struct Observation: StatePayload {
	let byteCount: Int
}
