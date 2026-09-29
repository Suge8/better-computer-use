import BCUCore
import BCUPlatform
import BCURuntime
import Foundation

/// The resident process's request handler: every command except `status` and `stop`,
/// which `Server` answers itself. `bcu serve` passes it to `Server`; this signature is the
/// seam between the daemon wiring and the executable.
public func makeRequestHandler(showsAgentCursor: Bool) -> RequestHandler {
	let daemon = Daemon(desktop: Platform(showsAgentCursor: showsAgentCursor))
	return { request in try await daemon.handle(request) }
}

/// Runs each command against the desktop: facts and delivery come from the platform, saved
/// observations, per-app ordering and `@r` refs live here.
final class Daemon<D: Desktop>: Sendable {
	let desktop: D
	let runtime = Runtime<Observation>()
	let roots = RootRegistry<RegisteredRoot>()
	let artifacts: ArtifactStore
	/// Waits between delivering an action and reading its effect back.
	let pause: @Sendable (Duration) async throws -> Void

	init(desktop: D, artifacts: ArtifactStore = ArtifactStore(), pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.desktop = desktop
		self.artifacts = artifacts
		self.pause = pause
	}

	func handle(_ request: Request) async throws -> JSONValue {
		throw BCUError(.internalError, "The resident handler is not wired yet.")
	}
}
