import Testing
@testable import BCURuntime

/// A platform root: the same window is equal by its handle, whatever its title says now.
private struct FakeRoot: Equatable, Sendable {
	let handle: Int
	let title: String

	static func == (lhs: FakeRoot, rhs: FakeRoot) -> Bool { lhs.handle == rhs.handle }
}

@Suite struct RootRegistryTests {
	@Test func sameRootKeepsItsRefAcrossTitleChanges() {
		let registry = RootRegistry<FakeRoot>()
		#expect(registry.ref(for: FakeRoot(handle: 1, title: "Untitled")) == "@r1")
		#expect(registry.ref(for: FakeRoot(handle: 2, title: "Untitled")) == "@r2")
		#expect(registry.ref(for: FakeRoot(handle: 1, title: "Saved.txt")) == "@r1")
		#expect(registry.root("@r1")?.title == "Saved.txt")
	}

	@Test func capacityEvictsTheLeastRecentlyUsedAndNeverReusesRefs() {
		let registry = RootRegistry<FakeRoot>(capacity: 2)
		_ = registry.ref(for: FakeRoot(handle: 1, title: "a"))
		_ = registry.ref(for: FakeRoot(handle: 2, title: "b"))
		_ = registry.root("@r1")
		#expect(registry.ref(for: FakeRoot(handle: 3, title: "c")) == "@r3")
		#expect(registry.root("@r2") == nil)
		#expect(registry.root("@r1")?.handle == 1)
		#expect(registry.ref(for: FakeRoot(handle: 2, title: "b")) == "@r4")
	}
}
