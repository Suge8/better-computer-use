/// Screenshot files, written as `<stateId>.jpg|png` into a private directory and pruned on
/// each write; no background timer. The actor serializes writes and pruning of its directory.
import BCUCore
import Foundation

public struct ArtifactLimits: Sendable {
	public var ttl: Duration
	public var maxFiles: Int
	public var maxBytes: Int
	public var maxImageBytes: Int

	public init(ttl: Duration = .seconds(600), maxFiles: Int = 128, maxBytes: Int = 256 * 1024 * 1024, maxImageBytes: Int = 16 * 1024 * 1024) {
		self.ttl = ttl
		self.maxFiles = maxFiles
		self.maxBytes = maxBytes
		self.maxImageBytes = maxImageBytes
	}
}

private let safeNameCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

public actor ArtifactStore {
	private let directory: String
	private let limits: ArtifactLimits
	private let now: @Sendable () -> Date

	public init(directory: String = RuntimePaths.shots, limits: ArtifactLimits = ArtifactLimits(), now: @escaping @Sendable () -> Date = Date.init) {
		self.directory = directory
		self.limits = limits
		self.now = now
	}

	/// Writes one screenshot and returns its path.
	public func save(stateId: String, bytes: Data, mime: String) throws -> String {
		guard !stateId.isEmpty, stateId.allSatisfy(safeNameCharacters.contains) else {
			throw BCUError(.internalError, "Screenshot stateId '\(stateId)' is not a safe artifact name.")
		}
		guard (1...limits.maxImageBytes).contains(bytes.count) else {
			throw BCUError(.internalError, "Screenshot size \(bytes.count) is outside the supported range.")
		}
		try ensurePrivateDirectory(directory)
		let path = "\(directory)/\(stateId).\(mime == "image/png" ? "png" : "jpg")"
		try bytes.write(to: URL(filePath: path))
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
		try prune(keeping: path)
		return path
	}

	private func prune(keeping kept: String) throws {
		let files = try FileManager.default.contentsOfDirectory(atPath: directory)
			.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }
			.compactMap(artifact)
			.sorted { $0.modified < $1.modified }
		let ttl = Double(limits.ttl.nanoseconds) / 1e9
		var count = files.count
		var bytes = files.reduce(0) { $0 + $1.size }
		for file in files where file.path != kept {
			let expired = now().timeIntervalSince(file.modified) > ttl
			guard expired || count > limits.maxFiles || bytes > limits.maxBytes else { continue }
			do {
				try FileManager.default.removeItem(atPath: file.path)
			} catch CocoaError.fileNoSuchFile {}
			count -= 1
			bytes -= file.size
		}
	}

	/// A screenshot file's size and age; nil when it vanished since the listing.
	private func artifact(_ name: String) throws -> (path: String, size: Int, modified: Date)? {
		let path = "\(directory)/\(name)"
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: path)
			guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
			return (path, (attributes[.size] as! NSNumber).intValue, attributes[.modificationDate] as! Date)
		} catch CocoaError.fileReadNoSuchFile {
			return nil
		}
	}
}
