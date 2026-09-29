import AppKit

/// Everything bcu does to the desktop, called in process: discovery (`listApps`,
/// `listRoots`, `frontmost`), observation (`look`), actions (`act`, `actBatch`), queries
/// (`waitFor`, `readText`) and the process's own state (`diagnostics`, `checkPermissions`,
/// `registerPermissions`). Methods block and are safe to call from concurrent threads;
/// physical input is serialized inside.
///
/// The platform keeps no record of what it returned: elements and roots come back as
/// handles the caller keeps with its own observation.
public final class Platform: @unchecked Sendable {
	/// Pointer actions delivered in the background animate an on-screen agent cursor; it
	/// needs a running AppKit application.
	let showsAgentCursor: Bool

	let physicalInputLock = NSRecursiveLock()
	let browserBundleIds: Set<String> = [
		"com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "net.imput.helium", "org.mozilla.firefox",
	]
	var enhancedAccessibilityPids = Set<Int32>()
	let enhancedAccessibilityLock = NSLock()
	let rootObserverLock = NSLock()
	var rootObservers: [Int32: RootAXObserverState] = [:]
	let maxRootObservers = 4
	let permissionCacheLock = NSLock()
	var grantedPermissionStatus: PermissionStatus?

	public init(showsAgentCursor: Bool) {
		self.showsAgentCursor = showsAgentCursor
	}
}
