import BCUCore
import BCURuntime

/// The resident process's request handler: every command except `status` and `stop`,
/// which `Server` answers itself. `bcu serve` passes it to `Server`; this signature is the
/// seam between the daemon wiring and the executable.
public func makeRequestHandler(showsAgentCursor: Bool) -> RequestHandler {
	{ _ in throw BCUError(.internalError, "The resident handler is not wired yet.") }
}
