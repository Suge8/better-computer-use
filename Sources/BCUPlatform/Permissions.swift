import AppKit
import ScreenCaptureKit

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
			accessibility: AXIsProcessTrusted(),
			screenRecording: CGPreflightScreenCaptureAccess(),
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

	/// Live Screen Recording probe. `CGPreflightScreenCaptureAccess()`
	/// answers from a per-process cache that goes stale after `tccutil
	/// reset` or a Settings toggle; a ScreenCaptureKit content fetch only
	/// succeeds when THIS process can genuinely capture right now. When the
	/// two disagree, the preflight boolean is the one lying.
	func screenRecordingCapturable() -> Bool {
		let sema = DispatchSemaphore(value: 0)
		let capturable = Box<Bool>(false)
		SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { shareable, error in
			if let shareable = shareable {
				capturable.value = !shareable.displays.isEmpty
			}
			sema.signal()
		}
		guard sema.wait(timeout: .now() + .seconds(5)) == .success else { return false }
		return capturable.value
	}

	/// Which TCC identity the permission booleans reflect. macOS attributes
	/// grants to the *responsible process* (the LaunchServices launching
	/// app), so:
	///   - "helper-app": running from the installed bundle, launched via
	///     LaunchServices — grants belong to the canonical helper identity.
	///   - "caller": anything else (dev binary under a terminal, etc.) —
	///     the booleans reflect whatever app spawned us, NOT the canonical
	///     helper. The Broker surfaces this instead of guessing.
	func permissionSource() -> PermissionSource {
		let parentPid = Int32(getppid())
		let executable = CommandLine.arguments.first ?? ""
		// Non-spoofable signals only: installed-bundle executable path + launchd parent
		// (`open` handed us to LaunchServices). A dev binary or a directly-spawned copy
		// fails closed to "caller".
		let attribution: PermissionAttribution = executable.contains("/bcu.app/Contents/MacOS/") && parentPid == 1 ? .helperApp : .caller
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
		permissionCacheLock.lock()
		if let cached = grantedPermissionStatus {
			permissionCacheLock.unlock()
			return cached
		}
		permissionCacheLock.unlock()
		let accessibility = AXIsProcessTrusted()
		let screenRecordingPreflight = CGPreflightScreenCaptureAccess()
		let capturable = screenRecordingCapturable()
		let result = PermissionStatus(
			accessibility: accessibility,
			screenRecording: capturable,
			screenRecordingPreflight: screenRecordingPreflight,
			source: permissionSource()
		)
		// A successful TCC grant is process-stable in practice. Cache only the
		// positive result so missing grants are always rechecked after the user
		// enables them, while fresh agent processes avoid repeating a multi-second
		// ScreenCaptureKit probe against the same long-lived helper daemon.
		if accessibility && capturable {
			permissionCacheLock.lock()
			grantedPermissionStatus = result
			permissionCacheLock.unlock()
		}
		return result
	}

	/// Register this process's identity with TCC for both grants so the app
	/// appears in the Settings panes BEFORE the user is sent there. The AX
	/// request registers (and prompts for) Accessibility; on recent macOS an
	/// app only appears under Screen Recording after a real ScreenCaptureKit
	/// attempt, which the capturable probe performs.
	public func registerPermissions() -> PermissionRegistration {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
		let accessibility = AXIsProcessTrustedWithOptions(options)
		_ = CGRequestScreenCaptureAccess()
		return PermissionRegistration(accessibility: accessibility, screenRecording: screenRecordingCapturable())
	}
}

