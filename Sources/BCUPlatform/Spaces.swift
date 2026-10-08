import CoreGraphics
import Foundation

/// Where WindowServer puts a window relative to the Spaces the displays show now.
enum SpacePlacement: Sendable {
	case shown, elsewhere
	/// In no Space: AppKit's untitled helper windows, which no accessibility tree backs.
	case unknown
}

/// One reading of which Spaces the displays show and which Spaces hold a window.
struct SpaceView {
	private typealias Connection = @convention(c) () -> UInt32
	private typealias DisplaySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
	private typealias WindowSpaces = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
	/// `SLSCopySpacesForWindows` mask selecting every Space a window is in.
	private static let allSpaces: Int32 = 7

	private let connection: UInt32
	private let shown: Set<Int>
	private let windowSpaces: WindowSpaces

	/// Nil when this macOS no longer has the private calls.
	init?() {
		guard let mainConnection = SkyLight.resolve("CGSMainConnectionID", as: Connection.self),
			let displaySpaces = SkyLight.resolve("SLSCopyManagedDisplaySpaces", as: DisplaySpaces.self),
			let windowSpaces = SkyLight.resolve("SLSCopySpacesForWindows", as: WindowSpaces.self)
		else { return nil }
		let connection = mainConnection()
		let displays = displaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
		self.connection = connection
		self.windowSpaces = windowSpaces
		shown = Set(displays.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? Int })
	}

	func placement(of windowId: UInt32) -> SpacePlacement {
		guard let spaces = windowSpaces(connection, Self.allSpaces, [windowId] as CFArray)?.takeRetainedValue() as? [Int], !spaces.isEmpty else { return .unknown }
		return spaces.contains(where: shown.contains) ? .shown : .elsewhere
	}
}
