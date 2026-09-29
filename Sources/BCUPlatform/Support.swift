import AppKit
import os

/// A value a callback, task or thread hands to the thread that waits for it.
final class Handoff<Value: Sendable>: Sendable {
	private let lock: OSAllocatedUnfairLock<Value>

	init(_ value: Value) {
		lock = OSAllocatedUnfairLock(initialState: value)
	}

	var value: Value {
		get { lock.withLock { $0 } }
		set { lock.withLock { $0 = newValue } }
	}
}

extension Platform {
	func processPath(pid: pid_t) -> String? {
		var buffer = [CChar](repeating: 0, count: 4096)
		let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
		return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
	}

	func processName(pid: pid_t) -> String? {
		processPath(pid: pid).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
	}

	func pidIsAlive(_ pid: pid_t) -> Bool {
		pid > 0 && kill(pid, 0) == 0
	}

	func elapsedMs(_ start: Date) -> Int {
		max(0, Int(Date().timeIntervalSince(start) * 1000.0))
	}
}

/// Runs async platform work for a caller that has to block for it. Nil when the work outlasts
/// `timeout`; it is cancelled then.
func blocking<T: Sendable>(timeout: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) -> Result<T, any Error>? {
	let done = DispatchSemaphore(value: 0)
	let result = Handoff<Result<T, any Error>?>(nil)
	let task = Task {
		do {
			result.value = .success(try await operation())
		} catch {
			result.value = .failure(error)
		}
		done.signal()
	}
	guard done.wait(timeout: .now() + timeout) == .success else {
		task.cancel()
		return nil
	}
	return result.value
}
