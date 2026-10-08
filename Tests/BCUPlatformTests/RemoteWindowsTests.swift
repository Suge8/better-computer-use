@testable import BCUPlatform
import CoreGraphics
import Foundation
import Testing

// macOS leaves the windows of other Spaces out of an app's AXWindows. Windows are recovered
// by probing element ids for the one AXWindow that WindowServer's window id names; the probe
// is bounded and runs only for windows that AXWindows should have listed.

private func candidate(_ id: UInt32, size: CGSize = CGSize(width: 800, height: 600), onscreen: Bool = true) -> CGWindowCandidate {
	CGWindowCandidate(windowId: id, title: "", bounds: CGRect(origin: .zero, size: size), isOnscreen: onscreen, layer: 0, zOrder: Int(id))
}

struct RecoverPlanTests {
	private func recovered(_ candidates: [CGWindowCandidate], _ placements: [UInt32: SpacePlacement], listed: Set<UInt32> = []) -> [UInt32] {
		windowsToRecover(from: candidates, placement: { placements[$0] ?? .unknown }, listedWindowIds: { listed }).map(\.windowId)
	}

	@Test func unlistedWindowOnAnotherSpaceIsRecovered() {
		// A full-screen app's window reads as on screen to WindowServer while its Space is not shown.
		#expect(recovered([candidate(1), candidate(2, onscreen: false)], [1: .elsewhere, 2: .elsewhere]) == [1, 2])
	}

	@Test func staleViewOfAShownSpaceIsRecoveredToo() {
		#expect(recovered([candidate(1, onscreen: false), candidate(2)], [1: .shown, 2: .shown]) == [1])
	}

	@Test func listedWindowsAreLeftAlone() {
		#expect(recovered([candidate(1), candidate(2)], [1: .elsewhere, 2: .elsewhere], listed: [1]) == [2])
	}

	@Test func helperWindowsWithoutASpaceOrOfBarSizeAreNeverProbed() {
		// AppKit keeps untitled helper windows in no Space; a full-screen Space has a menu-bar-high window.
		let menuBar = candidate(3, size: CGSize(width: 2560, height: 32))
		#expect(recovered([candidate(1, onscreen: false), candidate(2, onscreen: false), menuBar], [2: .elsewhere, 3: .elsewhere]) == [2])
	}

	@Test func listedWindowsAreNotReadWhenNothingIsMissing() {
		var read = false
		let plan = windowsToRecover(from: [candidate(1)], placement: { _ in .shown }, listedWindowIds: { read = true; return [] })
		#expect(plan.isEmpty && !read)
	}
}

struct RemoteWindowIndexTests {
	/// An app whose element `id` is the AXWindow of window `windows[id]`, counting lookups.
	private final class App: @unchecked Sendable {
		let windows: [UInt64: UInt32]
		var lookups = 0
		var pause: TimeInterval = 0
		init(_ windows: [UInt64: UInt32]) { self.windows = windows }
		func windowId(_ element: UInt64) -> UInt32? {
			lookups += 1
			if pause > 0 { Thread.sleep(forTimeInterval: pause) }
			return windows[element]
		}
	}

	@Test func findsTheElementOfEachWantedWindowAndNothingElse() {
		let app = App([3: 10, 42: 7, 90: 8])
		let found = RemoteWindowIndex().elementIds(pid: 1, wanted: [7, 8], windowId: app.windowId)
		#expect(found == [7: 42, 8: 90])
		#expect(app.lookups == 91)
	}

	@Test func probesNoFurtherThanTheElementLimit() {
		let app = App([2500: 7])
		let found = RemoteWindowIndex(limit: 2000).elementIds(pid: 1, wanted: [7], windowId: app.windowId)
		#expect(found.isEmpty && app.lookups == 2000)
	}

	@Test func stopsAtTheDeadlineWhenTheAppIsSlow() {
		let app = App([:])
		app.pause = 0.01
		let found = RemoteWindowIndex(deadline: .milliseconds(50)).elementIds(pid: 1, wanted: [7], windowId: app.windowId)
		#expect(found.isEmpty && app.lookups < 20)
	}

	@Test func aKnownElementIsCheckedWithoutScanningAgain() {
		let app = App([42: 7])
		let index = RemoteWindowIndex()
		_ = index.elementIds(pid: 1, wanted: [7], windowId: app.windowId)
		app.lookups = 0
		#expect(index.elementIds(pid: 1, wanted: [7], windowId: app.windowId) == [7: 42])
		#expect(app.lookups == 1)
	}

	@Test func aWindowThatIsNotThereIsNotScannedForAgain() {
		let app = App([:])
		let index = RemoteWindowIndex(limit: 100)
		_ = index.elementIds(pid: 1, wanted: [7], windowId: app.windowId)
		app.lookups = 0
		#expect(index.elementIds(pid: 1, wanted: [7], windowId: app.windowId).isEmpty)
		#expect(app.lookups == 0)
	}

	@Test func aScanCutOffByTheDeadlineIsRetried() {
		let app = App([:])
		app.pause = 0.01
		let index = RemoteWindowIndex(deadline: .milliseconds(30), retryAfterTimeout: .zero)
		_ = index.elementIds(pid: 1, wanted: [7], windowId: app.windowId)
		app.lookups = 0
		_ = index.elementIds(pid: 1, wanted: [7], windowId: app.windowId)
		#expect(app.lookups > 0)
	}
}
