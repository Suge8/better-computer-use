import AppKit
import BCUPlatform

// `open -n -g bcu.app --args serve --socket <path>` starts the helper daemon. LaunchServices
// can also start the app bare (from Finder or the privacy settings); there is nothing to do then.
let arguments = CommandLine.arguments
guard arguments.contains("serve") else { exit(0) }
let socketPath = arguments.firstIndex(of: "--socket").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
	?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Caches/bcu/bridge.sock"
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
HelperServer(socketPath: socketPath).run()
