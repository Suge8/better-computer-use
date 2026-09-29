import AppKit
import BCUCore
import ImageIO
import ScreenCaptureKit

/// How long one ScreenCaptureKit request may take before the capture fails as timed out.
let captureTimeout: TimeInterval = 8

struct CapturedWindowImage {
	let image: CGImage
	let windowId: UInt32
	/// The window in screen points, as ScreenCaptureKit framed it.
	let frame: CGRect
}

/// One window as ScreenCaptureKit sees it, looked up once and captured as often as needed.
///
/// Sendable although its filter and configuration are not marked so: both are built in `init`
/// and never changed afterwards, and a capturer serves one capture at a time — the action it
/// belongs to captures before delivery and then after it, never concurrently.
final class WindowCapturer: @unchecked Sendable {
	let windowId: UInt32
	let frame: CGRect
	private let filter: SCContentFilter
	private let configuration: SCStreamConfiguration

	init(windowId: UInt32, scale: @Sendable (CGRect) -> Double) async throws {
		let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
		guard let window = shareable.windows.first(where: { $0.windowID == windowId }) else {
			throw BCUError(.windowStale, "Window \(windowId) is not available for capture.")
		}
		self.windowId = windowId
		frame = window.frame
		filter = SCContentFilter(desktopIndependentWindow: window)
		let configuration = SCStreamConfiguration()
		// ScreenCaptureKit's default canvas is 1920x1080 whatever the window's size.
		let pixelsPerPoint = scale(window.frame)
		configuration.width = max(1, Int((window.frame.width * pixelsPerPoint).rounded()))
		configuration.height = max(1, Int((window.frame.height * pixelsPerPoint).rounded()))
		configuration.showsCursor = false
		configuration.ignoreShadowsSingleWindow = true
		self.configuration = configuration
	}

	func capture() async throws -> CGImage {
		try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
	}
}

extension Platform {
	/// Looks the window up and captures it once; the capturer is handed back for later captures.
	func captureWindow(windowId: UInt32) throws -> (capture: CapturedWindowImage, capturer: WindowCapturer) {
		try captured(windowId: windowId) { [self] in
			let capturer = try await WindowCapturer(windowId: windowId) { displayScaleFactor(for: $0) }
			let image = try await capturer.capture()
			return (CapturedWindowImage(image: image, windowId: windowId, frame: capturer.frame), capturer)
		}
	}

	/// Captures the window again through a capturer it was already looked up with.
	func captureAgain(_ capturer: WindowCapturer, within timeout: TimeInterval = captureTimeout) throws -> CGImage {
		try captured(windowId: capturer.windowId, within: timeout) { try await capturer.capture() }
	}

	private func captured<T: Sendable>(windowId: UInt32, within timeout: TimeInterval = captureTimeout, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
		guard let result = blocking(timeout: timeout, operation) else {
			throw BCUError(.actionTimeout, "Capturing window \(windowId) took longer than \(String(format: "%.1f", timeout)) s.")
		}
		do {
			return try result.get()
		} catch {
			throw captureError(error, windowId: windowId)
		}
	}

	func jpegData(image: CGImage, quality: Double) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return data as Data
	}

	func downscaledImage(_ image: CGImage, maxDimension: Int?) -> CGImage? {
		guard let maxDimension, max(image.width, image.height) > maxDimension else { return nil }
		let scale = Double(maxDimension) / Double(max(image.width, image.height))
		let width = max(1, Int(Double(image.width) * scale))
		let height = max(1, Int(Double(image.height) * scale))
		guard let context = CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: image.bitsPerComponent,
			bytesPerRow: 0,
			space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: image.bitmapInfo.rawValue
		) else { return nil }
		context.interpolationQuality = .medium
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return context.makeImage()
	}

	func windowInfo(windowId: UInt32) -> (pid: Int32, bounds: CGRect)? {
		func matchingEntry(_ entries: [[String: Any]]?) -> [String: Any]? {
			entries?.first {
				($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowId
			}
		}

		let requestedIds = [NSNumber(value: windowId)] as CFArray
		let targetedEntries = CGWindowListCreateDescriptionFromArray(requestedIds) as? [[String: Any]]
		let entry = matchingEntry(targetedEntries) ?? matchingEntry(
			CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
		)
		guard let entry,
			let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
			let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
			let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
		else {
			return nil
		}
		return (pid, bounds)
	}
}

/// The public failure for a capture ScreenCaptureKit refused or could not make.
func captureError(_ error: any Error, windowId: UInt32) -> BCUError {
	if let failure = error as? BCUError { return failure }
	switch (error as? SCStreamError)?.code {
	case .userDeclined:
		// The resident read the grant once when it started; a grant revoked since then shows up
		// only here, and only a fresh resident reads it again.
		return BCUError(.permissionMissing, "Screen Recording is not granted to bcu, so window \(windowId) cannot be captured.", recovery: "Run 'bcu stop', then 'bcu setup' in an interactive terminal, and retry.")
	case .noCaptureSource:
		return BCUError(.windowStale, "Window \(windowId) is gone and cannot be captured.")
	default:
		return BCUError(.actionFailed, "Window \(windowId) could not be captured: \(error.localizedDescription)")
	}
}
