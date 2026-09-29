/// Stable `@r` refs for roots. The platform's root type decides identity through `==` (the
/// same accessibility element), so a window keeps its ref when its title or frame changes.
import os

public final class RootRegistry<Root: Equatable & Sendable>: Sendable {
	private struct Contents: Sendable {
		/// Least recently used first.
		var entries: [(ref: String, root: Root)] = []
		var next = 1
	}

	private let capacity: Int
	private let contents = OSAllocatedUnfairLock(initialState: Contents())

	public init(capacity: Int = 256) {
		self.capacity = capacity
	}

	/// The root's ref, minted on first sight; the stored root becomes this latest one. Refs are
	/// never reused, so an evicted ref cannot come to name another root.
	public func ref(for root: Root) -> String {
		contents.withLock { contents in
			if let index = contents.entries.firstIndex(where: { $0.root == root }) {
				let ref = contents.entries.remove(at: index).ref
				contents.entries.append((ref, root))
				return ref
			}
			let ref = "@r\(contents.next)"
			contents.next += 1
			contents.entries.append((ref, root))
			if contents.entries.count > capacity { contents.entries.removeFirst() }
			return ref
		}
	}

	public func root(_ ref: String) -> Root? {
		contents.withLock { contents in
			guard let index = contents.entries.firstIndex(where: { $0.ref == ref }) else { return nil }
			let entry = contents.entries.remove(at: index)
			contents.entries.append(entry)
			return entry.root
		}
	}
}
