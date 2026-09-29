import AppKit
import BCUPlatform

// `open -n -g bcu.app --args serve --socket <path>` starts the helper daemon; without
// `serve` the helper answers requests on standard input and output.
let arguments = CommandLine.arguments
let serves = arguments.contains("serve")
_ = NSApplication.shared
NSApp.setActivationPolicy(serves ? .accessory : .prohibited)
let server = HelperServer(showsAgentCursor: serves)
guard serves else { server.serveStandardIO() }
let socketPath = arguments.firstIndex(of: "--socket").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
	?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Caches/bcu/bridge.sock"
server.serve(socketPath: socketPath)
