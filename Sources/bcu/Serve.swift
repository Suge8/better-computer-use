import AppKit
import BCUCore
import BCUDaemon
import BCURuntime
import Foundation

/// `bcu serve`: the resident process inside bcu.app. AppKit owns the main thread (the agent
/// cursor draws there); requests run on the server's connection threads and the Swift
/// concurrency pool, and the process exits once the server stops.
@MainActor
func serve() -> Never {
	let settings: Settings
	let server: Server
	do {
		settings = try currentSettings()
		server = Server(socketPath: settings.socketPath, idleTimeout: settings.idleTimeout, handler: makeRequestHandler(showsAgentCursor: settings.showsAgentCursor))
		// Another resident already listens: this launch lost the race and has nothing to do.
		guard try server.start() else { exit(0) }
	} catch {
		FileHandle.standardError.write(Data(BCUError.normalize(error).formatted.utf8))
		exit(1)
	}
	_ = NSApplication.shared
	NSApp.setActivationPolicy(.accessory)
	Task.detached {
		await server.stopped()
		exit(0)
	}
	NSApp.run()
	exit(0)
}
