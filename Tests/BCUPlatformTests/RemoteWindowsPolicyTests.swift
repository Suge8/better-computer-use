@testable import BCUPlatform
import CoreGraphics
import Testing

// A caller that is not after one app (the undirected find-roots) must not probe every closed
// window WindowServer still lists: no probe finds those, and each costs 50–160 ms once a minute.

struct StaleViewPolicyTests {
	private let hidden = CGWindowCandidate(windowId: 1, title: "", bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isOnscreen: false, layer: 0, zOrder: 0)

	@Test func anUndirectedSearchLeavesStaleViewsAlone() {
		let plan = windowsToRecover(from: [hidden], includingStaleViews: false, placement: { _ in .shown }, listedWindowIds: { [] })
		#expect(plan.isEmpty)
	}

	@Test func anUndirectedSearchStillRecoversWindowsOnOtherSpaces() {
		let plan = windowsToRecover(from: [hidden], includingStaleViews: false, placement: { _ in .elsewhere }, listedWindowIds: { [] })
		#expect(plan.map(\.windowId) == [1])
	}
}
