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

/// Runs each command against the desktop: facts and delivery come from the platform; saved
/// observations with their platform handles, per-app ordering and `@r` refs live here.
final class Daemon<D: Desktop>: Sendable {
	let desktop: D
	let runtime = Runtime<Observation>()
	let rootRefs = RootRegistry<RegisteredRoot>()
	let artifacts: ArtifactStore
	/// Waits between delivering an action and reading its effect back.
	let pause: @Sendable (Duration) async throws -> Void

	init(desktop: D, artifacts: ArtifactStore = ArtifactStore(), pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.desktop = desktop
		self.artifacts = artifacts
		self.pause = pause
	}

	func handle(_ request: Request) async throws -> JSONValue {
		switch request {
		case .plain(.doctor): return try await doctor()
		case .plain(.setup): return try await setup()
		case .plain(let command): throw BCUError(.internalError, "'\(command.rawValue)' is answered by the resident server, not by a handler.")
		case .command(let command):
			// A state that is gone says so before anything else is checked.
			if let stateId = command.stateId { _ = try runtime.state(stateId) }
			try await ensurePermissions()
			return try await run(command).json()
		}
	}

	private func run(_ command: CommandRequest) async throws -> CommandResult {
		switch command {
		case .findRoots(let params): .findRoots(try await findRoots(params))
		case .observeUi(let params): .observeUi(try await observe(params))
		case .searchUi(let params): .searchUi(try await search(params))
		case .expandUi(let params): .expandUi(try await expand(params))
		case .inspectUi(let params): .inspectUi(try inspect(params))
		case .actUi(let params): .actUi(try await act(params))
		case .readText(let params): .readText(try await readText(params))
		case .waitFor(let params): .waitFor(try await waitFor(params))
		}
	}
}

private extension CommandRequest {
	var stateId: String? {
		switch self {
		case .findRoots, .observeUi: nil
		case .searchUi(let params): params.stateId
		case .expandUi(let params): params.stateId
		case .inspectUi(let params): params.stateId
		case .actUi(let params): params.stateId
		case .readText(let params): params.stateId
		case .waitFor(let params): params.stateId
		}
	}
}
