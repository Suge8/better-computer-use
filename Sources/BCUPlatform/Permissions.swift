import AppKit
import ScreenCaptureKit

/// This process's privacy grants as the system keeps them: reading them never asks the user,
/// and `request` is the only call that shows the system's authorization prompts.
protocol PrivacyGrants: Sendable {
	var accessibility: Bool { get }
	var screenRecording: Bool { get }
	/// Whether a ScreenCaptureKit fetch succeeds; for a process without the grant this shows
	/// the system prompt.
	func probeScreenCapture() -> Bool
	func request() -> PermissionRegistration
}

/// The grants TCC holds for this process.
struct SystemGrants: PrivacyGrants {
	var accessibility: Bool { AXIsProcessTrusted() }
	var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

	func probeScreenCapture() -> Bool {
		let probe = blocking(timeout: captureTimeout) {
			!(try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)).displays.isEmpty
		}
		return (try? probe?.get()) == true
	}

	/// Registers this process with both privacy panes so bcu is listed there before the user
	/// is sent to grant it: the Accessibility request adds and prompts for it, and on recent
	/// macOS an app appears under Screen Recording only after a real ScreenCaptureKit attempt.
	func request() -> PermissionRegistration {
		// The value of `kAXTrustedCheckOptionPrompt`, a C global Swift 6 cannot read without isolation.
		let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
		let accessibility = AXIsProcessTrustedWithOptions(options)
		_ = CGRequestScreenCaptureAccess()
		return PermissionRegistration(accessibility: accessibility, screenRecording: probeScreenCapture())
	}
}

extension Platform {
	/// Cheap booleans only: diagnostics doubles as the daemon liveness probe (1s client
	/// timeout), so it must not run the ScreenCaptureKit capturable check (up to 3s when
	/// ungranted). Permission truth comes from checkPermissions.
	public func diagnostics() -> Diagnostics {
		#if arch(arm64)
		let arch = "arm64"
		#elseif arch(x86_64)
		let arch = "x86_64"
		#else
		let arch = "unknown"
		#endif
		let parentPid = Int32(getppid())
		let parentApp = NSRunningApplication(processIdentifier: parentPid)
		let parentPath = processPath(pid: parentPid)
		return Diagnostics(
			accessibility: grants.accessibility,
			screenRecording: grants.screenRecording,
			pid: Int32(getpid()),
			parentPid: parentPid,
			parentPath: parentPath,
			parentAppName: parentApp?.localizedName ?? parentPath.map { URL(fileURLWithPath: $0).lastPathComponent },
			parentBundleId: parentApp?.bundleIdentifier,
			executablePath: CommandLine.arguments.first ?? "",
			macOS: ProcessInfo.processInfo.operatingSystemVersionString,
			arch: arch
		)
	}

	/// Which TCC identity the permission booleans reflect. macOS attributes
	/// grants to the *responsible process* (the LaunchServices launching
	/// app), so:
	///   - "bcu-app": running from the installed bundle, launched via
	///     LaunchServices — grants belong to the installed bcu.app.
	///   - "caller": anything else (dev binary under a terminal, etc.) —
	///     the booleans reflect whatever app spawned us, NOT the canonical
	///     app. Callers surface this instead of guessing.
	func permissionSource() -> PermissionSource {
		let parentPid = Int32(getppid())
		let executable = CommandLine.arguments.first ?? ""
		// Non-spoofable signals only: installed-bundle executable path + launchd parent
		// (`open` handed us to LaunchServices). A dev binary or a directly-spawned copy
		// fails closed to "caller".
		let attribution: PermissionAttribution = executable.contains("/bcu.app/Contents/MacOS/") && parentPid == 1 ? .bcuApp : .caller
		return PermissionSource(
			pid: Int32(getpid()),
			parentPid: parentPid,
			parentPath: processPath(pid: parentPid),
			parentBundleId: NSRunningApplication(processIdentifier: parentPid)?.bundleIdentifier,
			executablePath: executable,
			macOS: ProcessInfo.processInfo.operatingSystemVersionString,
			attribution: attribution
		)
	}

	public func checkPermissions() -> PermissionStatus {
		if let cached = grantedPermissionStatus.withLock({ $0 }) { return cached }
		let accessibility = grants.accessibility
		let screenRecordingPreflight = grants.screenRecording
		let capturable = grants.probeScreenCapture()
		let result = PermissionStatus(
			accessibility: accessibility,
			screenRecording: capturable,
			screenRecordingPreflight: screenRecordingPreflight,
			source: permissionSource()
		)
		// A successful TCC grant is process-stable in practice. Cache only the
		// positive result so missing grants are always rechecked after the user
		// enables them, while fresh agent processes avoid repeating a multi-second
		// ScreenCaptureKit probe against the same long-lived resident process.
		if accessibility && capturable {
			grantedPermissionStatus.withLock { $0 = result }
		}
		return result
	}

	/// The system's prompts for both grants; `bcu setup` is the only caller.
	public func registerPermissions() -> PermissionRegistration {
		grants.request()
	}
}
