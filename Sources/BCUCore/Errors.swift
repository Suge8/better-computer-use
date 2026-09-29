/// Every failure a caller can recover from, with its exit code and default next step. There is
/// one set: each failure path throws its public code where it happens.
public enum ErrorCode: String, CaseIterable, Codable, Sendable {
	case invalidArguments = "invalid_arguments"
	case staleState = "stale_state"
	case permissionMissing = "permission_missing"
	case appNotFound = "app_not_found"
	case windowStale = "window_stale"
	case elementNotFound = "element_not_found"
	case actionTimeout = "action_timeout"
	case actionFailed = "action_failed"
	case residentUnavailable = "resident_unavailable"
	case stateTooLarge = "state_too_large"
	case internalError = "internal_error"

	public var exitCode: Int32 {
		switch self {
		case .internalError: 1
		case .invalidArguments: 2
		case .staleState: 3
		case .permissionMissing: 4
		case .appNotFound: 5
		case .windowStale: 6
		case .elementNotFound: 7
		case .actionTimeout: 8
		case .actionFailed: 9
		case .residentUnavailable: 10
		case .stateTooLarge: 13
		}
	}

	public var recovery: String {
		switch self {
		case .invalidArguments: "Run 'bcu --help' and correct the command arguments."
		case .staleState: "Run observe-ui again and retry with the new stateId and refs."
		case .permissionMissing: "Run 'bcu setup' in an interactive terminal, grant both permissions, then retry."
		case .appNotFound: "Open the app, then run 'bcu find-roots' to confirm its current name."
		case .windowStale: "Run 'bcu find-roots', observe a current root, and retry."
		case .elementNotFound: "Run observe-ui again and use an @e ref from the returned state."
		case .actionTimeout: "Inspect the current UI, then retry with a valid condition or a longer --timeout."
		case .actionFailed: "Observe the current UI before deciding whether the action is safe to retry."
		case .residentUnavailable: "Run 'bcu doctor'. If a stale process remains, run 'bcu stop' and retry."
		case .stateTooLarge: "Observe a smaller root or narrow the UI before retrying."
		case .internalError: "Run 'bcu doctor' and retry. If it repeats, report the full error."
		}
	}
}

public struct BCUError: Error, Codable, Sendable, Equatable {
	public let code: ErrorCode
	public let message: String
	public let recovery: String

	public init(_ code: ErrorCode, _ message: String, recovery: String? = nil) {
		self.code = code
		self.message = message
		self.recovery = recovery ?? code.recovery
	}

	public var exitCode: Int32 { code.exitCode }

	/// What the CLI writes to stderr; stdout stays empty on failure.
	public var formatted: String {
		let message = Text.trim(Text.collapseWhitespace(message))
		return "error \(code.rawValue): \(message.isEmpty ? "Unknown failure." : message)\nrecovery: \(recovery)\n"
	}

	/// An error that reaches the CLI without a code is a bug, not a recoverable state.
	public static func normalize(_ error: any Error) -> BCUError {
		error as? BCUError ?? BCUError(.internalError, String(describing: error))
	}
}

func invalid(_ message: String) -> BCUError {
	BCUError(.invalidArguments, message)
}
