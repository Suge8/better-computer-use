import ApplicationServices
import CoreGraphics
import os

// macOS leaves the windows of other Spaces out of an app's AXWindows, so a root search driven by
// that list never sees them. The accessibility element of such a window still exists, and
// `_AXUIElementCreateWithRemoteToken` (what alt-tab-macos and trycua/cua use too) makes one from
// the app's pid and an element id. Window elements are allocated early in an app's life, so
// probing the first ids finds them; only an AXWindow whose `_AXUIElementGetWindow` is the id
// WindowServer gave the window is accepted, so the result is as exact as an AXWindows match.

/// Windows smaller than this are no roots (menu-bar-high windows of full-screen Spaces, tooltips).
let minimumWindowSize = CGSize(width: 100, height: 80)
/// A window whose element id is beyond this (late in a long-running browser) is not recovered.
let remoteElementLimit: UInt64 = 2000
let remoteProbeDeadline: Duration = .milliseconds(300)
/// A candidate probe answers within this; the probe asks up to `remoteElementLimit` times.
private let remoteCandidateTimeout: Float = 0.05
private let remoteTokenMagic: Int32 = 0x636f_636f  // 'coco'

/// The windows WindowServer lists that AXWindows should have listed but did not: on a Space the
/// displays do not show, or on a shown one yet reported off screen (a stale view of a Space
/// change, in which AX drops the window the same way). Windows in no Space are AppKit helpers
/// with no accessibility counterpart. `listedWindowIds` costs accessibility calls, so it is read
/// only when some window is suspect. The stale view cannot be told from a window an app closed
/// but WindowServer still lists (this desktop has five), which no probe finds, so a caller that
/// is not after one particular app leaves it out (`includingStaleViews`).
func windowsToRecover(from candidates: [CGWindowCandidate], includingStaleViews: Bool = true, placement: (UInt32) -> SpacePlacement, listedWindowIds: () -> Set<UInt32>) -> [CGWindowCandidate] {
	let suspects = candidates.filter { candidate in
		guard candidate.bounds.width >= minimumWindowSize.width, candidate.bounds.height >= minimumWindowSize.height else { return false }
		switch placement(candidate.windowId) {
		case .elsewhere: return true
		case .shown: return includingStaleViews && !candidate.isOnscreen
		case .unknown: return false
		}
	}
	guard !suspects.isEmpty else { return [] }
	let listed = listedWindowIds()
	return suspects.filter { !listed.contains($0.windowId) }
}

/// Finds the element id of each wanted window by probing, and remembers what it learned: an
/// element id keeps naming its window, and a window the probe could not find is not searched for
/// again for a while (every find-roots would otherwise pay the full probe for it: 50–160 ms per
/// app, and apps keep closed windows WindowServer still lists). The pause is long when the
/// whole range was searched and short when the deadline cut the search off.
final class RemoteWindowIndex: Sendable {
	private struct Memory {
		var elements: [Int32: [UInt32: UInt64]] = [:]
		/// When a window that was not found may be searched for again.
		var retryAt: [Int32: [UInt32: ContinuousClock.Instant]] = [:]
	}

	private let limit: UInt64
	private let deadline: Duration
	private let retryAfterSearch: Duration
	private let retryAfterTimeout: Duration
	private let memory = OSAllocatedUnfairLock(initialState: Memory())

	init(limit: UInt64 = remoteElementLimit, deadline: Duration = remoteProbeDeadline, retryAfterSearch: Duration = .seconds(60), retryAfterTimeout: Duration = .seconds(10)) {
		self.limit = limit
		self.deadline = deadline
		self.retryAfterSearch = retryAfterSearch
		self.retryAfterTimeout = retryAfterTimeout
	}

	/// The element id of each of `wanted` that is found. `windowId` answers, for an element id of
	/// the app, the window id when the element is an AXWindow.
	func elementIds(pid: Int32, wanted: Set<UInt32>, windowId: (UInt64) -> UInt32?) -> [UInt32: UInt64] {
		let clock = ContinuousClock()
		let start = clock.now
		let (known, retryAt) = memory.withLock { ($0.elements[pid] ?? [:], $0.retryAt[pid] ?? [:]) }
		var found: [UInt32: UInt64] = [:]
		for (id, element) in known where wanted.contains(id) && windowId(element) == id { found[id] = element }
		var missing = wanted.filter { found[$0] == nil && start >= retryAt[$0] ?? start }
		let searched = missing
		var timedOut = false
		var element: UInt64 = 0
		while !missing.isEmpty, element < limit {
			if clock.now - start > deadline {
				timedOut = true
				break
			}
			if let id = windowId(element), missing.remove(id) != nil { found[id] = element }
			element += 1
		}
		let retry = clock.now + (timedOut ? retryAfterTimeout : retryAfterSearch)
		let result = found
		memory.withLock {
			$0.elements[pid] = result
			$0.retryAt[pid] = Dictionary(uniqueKeysWithValues: wanted.filter { result[$0] == nil }.map { ($0, searched.contains($0) ? retry : retryAt[$0] ?? retry) })
		}
		return result
	}
}

private let remoteWindows = RemoteWindowIndex()

/// The private accessibility calls the recovery needs.
private enum RemoteAX {
	private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
	private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
	private static let create = SkyLight.resolve("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self)
	private static let window = SkyLight.resolve("_AXUIElementGetWindow", as: GetWindow.self)

	/// The element of `pid` with this id, or nil when there is none or this macOS lacks the call.
	static func element(pid: Int32, id: UInt64) -> AXUIElement? {
		var token = [UInt8](repeating: 0, count: 20)
		withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
		withUnsafeBytes(of: remoteTokenMagic) { token.replaceSubrange(8..<12, with: $0) }
		withUnsafeBytes(of: id) { token.replaceSubrange(12..<20, with: $0) }
		return create?(Data(token) as CFData)?.takeRetainedValue()
	}

	static func windowId(of element: AXUIElement) -> UInt32? {
		var id: UInt32 = 0
		return window?(element, &id) == .success && id != 0 ? id : nil
	}

	/// The window id when `element` is an AXWindow.
	static func windowId(ofWindow element: AXUIElement) -> UInt32? {
		var role: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success, role as? String == kAXWindowRole as String else { return nil }
		return windowId(of: element)
	}
}

/// A window recovered from outside AXWindows, with WindowServer's record of it.
struct RecoveredWindow {
	let element: AXUIElement
	let candidate: CGWindowCandidate
	/// On a Space the displays do not show, whatever WindowServer says about being on screen.
	let isElsewhere: Bool
}

extension Platform {
	/// The windows of `pid` among `candidates` that AXWindows (`listed`) lacks, as elements with
	/// `timeout` restored (the probe runs them at a short one). While every window of the app is
	/// listed it costs one Space lookup per window; `spaces` is read once by the caller for all apps.
	func recoverUnlistedWindows(pid: Int32, listed: [AXUIElement], candidates: [CGWindowCandidate], spaces: SpaceView?, includingStaleViews: Bool = true, timeout: Float) -> [RecoveredWindow] {
		guard let spaces else { return [] }
		let missing = windowsToRecover(from: candidates, includingStaleViews: includingStaleViews, placement: spaces.placement(of:), listedWindowIds: { Set(listed.compactMap(RemoteAX.windowId(of:))) })
		guard !missing.isEmpty else { return [] }
		let elementIds = remoteWindows.elementIds(pid: pid, wanted: Set(missing.map(\.windowId))) { id in
			guard let element = RemoteAX.element(pid: pid, id: id) else { return nil }
			AXUIElementSetMessagingTimeout(element, remoteCandidateTimeout)
			return RemoteAX.windowId(ofWindow: element)
		}
		return missing.compactMap { candidate in
			guard let id = elementIds[candidate.windowId], let element = RemoteAX.element(pid: pid, id: id) else { return nil }
			AXUIElementSetMessagingTimeout(element, timeout)
			return RecoveredWindow(element: element, candidate: candidate, isElsewhere: spaces.placement(of: candidate.windowId) == .elsewhere)
		}
	}
}
