import AppKit
import os

/// Everything bcu does to the desktop, called in process: discovery (`listApps`,
/// `listRoots`, `frontmost`), observation (`look`), actions (`act`, `actBatch`), queries
/// (`waitFor`, `readText`) and the process's own state (`diagnostics`, `checkPermissions`,
/// `registerPermissions`). Methods block and are safe to call from concurrent threads;
/// physical input is serialized inside.
///
/// The platform keeps no record of what it returned: elements and roots come back as
/// handles the caller keeps with its own observation.
public final class Platform: Sendable {
	/// Pointer actions delivered in the background animate an on-screen agent cursor; it
	/// needs a running AppKit application.
	let showsAgentCursor: Bool

	/// Held across one delivery of real (HID) input, so two requests never interleave the
	/// pointer or keyboard; recursive because a delivery calls the smaller posts that take it too.
	let physicalInputLock = NSRecursiveLock()
	let browserBundleIds: Set<String> = [
		"com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "net.imput.helium", "org.mozilla.firefox",
	]
	/// Apps already told to build their full accessibility tree.
	let enhancedAccessibilityPids = OSAllocatedUnfairLock(initialState: Set<Int32>())
	let rootObservers = RootObservers()
	/// Granted permissions, kept once both are in place; missing ones are asked again each time.
	let grantedPermissionStatus = OSAllocatedUnfairLock<PermissionStatus?>(initialState: nil)

	public init(showsAgentCursor: Bool) {
		self.showsAgentCursor = showsAgentCursor
	}
}
