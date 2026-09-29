import AppKit

public final class Bridge {
	public init() {}

	let protocolVersion = 10

	let cgMenuRefPrefix = "cgmenu:"

	let refStore = AXRefStore()

	let inputSuppressionGuard = InputSuppressionGuard()

	let physicalInputLock = NSRecursiveLock()

	let supportsAgentCursor = CommandLine.arguments.contains("serve")

	let browserBundleIds: Set<String> = [
		"com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "net.imput.helium", "org.mozilla.firefox",
	]

	var enhancedAccessibilityPids = Set<Int32>()

	let enhancedAccessibilityLock = NSLock()

	var stdinBuffer = Data()

	var output = FileHandle.standardOutput

	var nextLookId: UInt64 = 0

	var lookRecords: [String: LookRecord] = [:]

	var lookRecordOrder: [String] = []

	let lookRecordLock = NSLock()

	let rootObserverLock = NSLock()

	var rootObservers: [Int32: RootAXObserverState] = [:]

	let maxRootObservers = 4

	let permissionCacheLock = NSLock()

	var grantedPermissionStatus: [String: Any]?

	let completedRequestLock = NSLock()

	var recentCompletedRequestIds: [String] = []
}
