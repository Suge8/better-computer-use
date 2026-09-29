import AppKit

/// Everything bcu does to the desktop, callable in process: discovery (`listApps`,
/// `listRoots`, `frontmost`, `focusWindow`), observation (`look`, `hitTest`), actions
/// (`act`, `actBatch`), queries (`waitFor`, `readText`) and the process's own state
/// (`diagnostics`, `checkPermissions`, `registerPermissions`). Methods are safe to call
/// from concurrent threads; physical input is serialized inside.
///
/// Root and element refs, and the last looks, live in this object: a ref is only
/// meaningful to the Platform that issued it.
public final class Platform {
	/// Pointer actions delivered in the background animate an on-screen agent cursor; it
	/// needs a running AppKit application.
	let showsAgentCursor: Bool

	let cgMenuRefPrefix = "cgmenu:"
	let refStore = AXRefStore()
	let physicalInputLock = NSRecursiveLock()
	let browserBundleIds: Set<String> = [
		"com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "net.imput.helium", "org.mozilla.firefox",
	]
	var enhancedAccessibilityPids = Set<Int32>()
	let enhancedAccessibilityLock = NSLock()
	var nextLookId: UInt64 = 0
	var lookRecords: [String: LookRecord] = [:]
	var lookRecordOrder: [String] = []
	let lookRecordLock = NSLock()
	let rootObserverLock = NSLock()
	var rootObservers: [Int32: RootAXObserverState] = [:]
	let maxRootObservers = 4
	let permissionCacheLock = NSLock()
	var grantedPermissionStatus: PermissionStatus?

	public init(showsAgentCursor: Bool) {
		self.showsAgentCursor = showsAgentCursor
	}
}
