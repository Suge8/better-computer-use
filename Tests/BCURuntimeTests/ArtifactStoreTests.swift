import BCUCore
import Foundation
import BCUTestSupport
import Testing
@testable import BCURuntime

/// Screenshot files: private, named by state, pruned on write.
@Suite(.temporaryRoot) struct ArtifactStoreTests {
	private let image = Data([0xFF, 0xD8, 0xFF, 0xE0])

	private func files(_ directory: String) throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
	}

	@Test func screenshotIsWrittenPrivatelyUnderItsStateId() async throws {
		let directory = try temporaryDirectory() + "/shots"
		let store = ArtifactStore(directory: directory)
		let jpeg = try await store.save(stateId: "ab12cd34", bytes: image, mime: "image/jpeg")
		let png = try await store.save(stateId: "ef56ab78", bytes: image, mime: "image/png")
		#expect(jpeg == directory + "/ab12cd34.jpg")
		#expect(png == directory + "/ef56ab78.png")
		#expect(FileManager.default.contents(atPath: jpeg) == image)
		#expect(try permissions(directory) == 0o700)
		#expect(try permissions(jpeg) == 0o600)
	}

	@Test func expiredScreenshotsArePrunedOnWrite() async throws {
		let directory = try temporaryDirectory()
		let store = ArtifactStore(directory: directory, limits: ArtifactLimits(ttl: .seconds(600)))
		let old = try await store.save(stateId: "00000001", bytes: image, mime: "image/jpeg")
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -601)], ofItemAtPath: old)
		_ = try await store.save(stateId: "00000002", bytes: image, mime: "image/jpeg")
		#expect(try files(directory) == ["00000002.jpg"])
	}

	@Test func capacityPrunesTheOldestButKeepsTheNewScreenshot() async throws {
		let directory = try temporaryDirectory()
		let store = ArtifactStore(directory: directory, limits: ArtifactLimits(maxFiles: 2, maxBytes: 6))
		for (index, id) in ["00000001", "00000002"].enumerated() {
			let path = try await store.save(stateId: id, bytes: image, mime: "image/jpeg")
			try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10))], ofItemAtPath: path)
		}
		#expect(try files(directory) == ["00000002.jpg"])
		_ = try await store.save(stateId: "00000003", bytes: Data(repeating: 1, count: 8), mime: "image/jpeg")
		#expect(try files(directory) == ["00000003.jpg"])
	}

	@Test func concurrentWritesKeepTheDirectoryWithinCapacity() async throws {
		let directory = try temporaryDirectory()
		let store = ArtifactStore(directory: directory, limits: ArtifactLimits(maxFiles: 5))
		try await withThrowingTaskGroup(of: Void.self) { group in
			for index in 0..<20 {
				group.addTask { _ = try await store.save(stateId: String(format: "%08x", index), bytes: image, mime: "image/jpeg") }
			}
			try await group.waitForAll()
		}
		#expect(try files(directory).count == 5)
	}

	@Test func unsafeNamesAndEmptyImagesAreRefused() async throws {
		let directory = try temporaryDirectory()
		let store = ArtifactStore(directory: directory, limits: ArtifactLimits(maxImageBytes: 8))
		await #expect(throws: BCUError.self) { try await store.save(stateId: "../escape", bytes: image, mime: "image/jpeg") }
		await #expect(throws: BCUError.self) { try await store.save(stateId: "ab12cd34", bytes: Data(), mime: "image/jpeg") }
		await #expect(throws: BCUError.self) { try await store.save(stateId: "ab12cd34", bytes: Data(count: 9), mime: "image/jpeg") }
		#expect(try files(directory).isEmpty)
		_ = try await store.save(stateId: "ab12cd34", bytes: Data(count: 8), mime: "image/jpeg")
		#expect(try files(directory) == ["ab12cd34.jpg"])
	}
}
