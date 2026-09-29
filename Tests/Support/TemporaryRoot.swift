import Foundation
import Testing

/// Gives each test its own directory under /tmp and removes it when the test ends. /tmp
/// rather than the per-user temporary directory: a Unix socket path holds at most 104 bytes.
public struct TemporaryRoot: SuiteTrait, TestTrait, TestScoping {
	@TaskLocal static var current: String?

	public var isRecursive: Bool { true }

	public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
		guard !test.isSuite else { return try await function() }
		let root = "/tmp/bcu-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
		try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: root) }
		try await Self.$current.withValue(root) { try await function() }
	}

	/// A fresh path inside the current test's directory; nothing is created at it.
	public static func path(_ name: String) -> String {
		guard let current else { preconditionFailure("Temporary paths need the suite to carry .temporaryRoot.") }
		return "\(current)/\(name)-\(UInt32.random(in: 0...UInt32.max))"
	}
}

public extension Trait where Self == TemporaryRoot {
	/// Scopes every test of the suite to its own temporary directory.
	static var temporaryRoot: Self { TemporaryRoot() }
}
