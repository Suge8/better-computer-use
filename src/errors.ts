export const ERROR_DEFINITIONS = {
	invalid_arguments: { exitCode: 2, recovery: "Run 'bcu --help' and correct the command arguments." },
	stale_state: { exitCode: 3, recovery: "Run observe-ui again and retry with the new stateId and refs." },
	permission_missing: { exitCode: 4, recovery: "Run 'bcu setup' in an interactive terminal, grant both permissions, then retry." },
	app_not_found: { exitCode: 5, recovery: "Open the app, then run 'bcu find-roots' to confirm its current name." },
	window_stale: { exitCode: 6, recovery: "Run 'bcu find-roots', observe a current root, and retry." },
	element_not_found: { exitCode: 7, recovery: "Run observe-ui again and use an @e ref from the returned state." },
	action_timeout: { exitCode: 8, recovery: "Inspect the current UI, then retry with a valid condition or a longer --timeout." },
	action_failed: { exitCode: 9, recovery: "Observe the current UI before deciding whether the action is safe to retry." },
	broker_unavailable: { exitCode: 10, recovery: "Run 'bcu doctor'. If a stale process remains, run 'bcu stop' and retry." },
	helper_unavailable: { exitCode: 11, recovery: "Run 'bcu doctor', repair the helper it reports, then retry." },
	unsupported_platform: { exitCode: 12, recovery: "Run bcu in an interactive macOS desktop session." },
	state_too_large: { exitCode: 13, recovery: "Observe a smaller root or narrow the UI before retrying." },
	internal_error: { exitCode: 1, recovery: "Run 'bcu doctor' and retry. If it repeats, report the full error." },
} as const;

export type ErrorCode = keyof typeof ERROR_DEFINITIONS;

export class BcuError extends Error {
	readonly code: ErrorCode;
	readonly recovery: string;
	readonly exitCode: number;

	constructor(code: ErrorCode, message: string) {
		super(message);
		this.name = "BcuError";
		this.code = code;
		this.recovery = ERROR_DEFINITIONS[code].recovery;
		this.exitCode = ERROR_DEFINITIONS[code].exitCode;
	}
}

export const ERROR_CODE_ALIASES = {
	invalid_args: "invalid_arguments",
	invalid_argument: "invalid_arguments",
	invalid_arguments: "invalid_arguments",
	invalid_request: "invalid_arguments",
	unknown_command: "invalid_arguments",
	unsupported_command: "invalid_arguments",
	protocol_error: "broker_unavailable",
	stale_state: "stale_state",
	stale_look: "stale_state",
	state_too_large: "state_too_large",
	permission_missing: "permission_missing",
	app_not_found: "app_not_found",
	app_not_running: "app_not_found",
	window_not_found: "window_stale",
	window_stale: "window_stale",
	root_not_found: "window_stale",
	target_not_found: "window_stale",
	frontmost_unavailable: "window_stale",
	stale_ref: "element_not_found",
	element_ref_invalid: "element_not_found",
	element_not_found: "element_not_found",
	hit_test_failed: "element_not_found",
	postcondition_failed: "action_failed",
	action_failed: "action_failed",
	capability_deferred: "action_failed",
	capture_failed: "action_failed",
	coordinate_unavailable: "action_failed",
	coordinate_unavailable_for_root: "action_failed",
	coordinate_blocked: "action_failed",
	foreground_required: "action_failed",
	frame_value_failed: "action_failed",
	input_failed: "action_failed",
	input_suppression_unavailable: "action_failed",
	occluded_target: "action_failed",
	secure_text_unreadable: "action_failed",
	text_recognition_failed: "action_failed",
	text_unavailable: "action_failed",
	action_timeout: "action_timeout",
	capture_timeout: "action_timeout",
	text_recognition_timeout: "action_timeout",
	input_suppression_timeout: "action_timeout",
	helper_unavailable: "helper_unavailable",
	broker_unavailable: "broker_unavailable",
	unsupported_platform: "unsupported_platform",
	encoding_failed: "internal_error",
	internal_error: "internal_error",
} as const satisfies Record<string, ErrorCode>;

function explicitCode(error: Error): ErrorCode | undefined {
	const code = "code" in error && typeof error.code === "string" ? error.code : undefined;
	return code && code in ERROR_CODE_ALIASES
		? ERROR_CODE_ALIASES[code as keyof typeof ERROR_CODE_ALIASES]
		: undefined;
}

/** Every failure path names its own code; an error that reaches here without one is a bug. */
export function normalizeCliError(error: unknown): BcuError {
	if (error instanceof BcuError) return error;
	const normalized = error instanceof Error ? error : new Error(String(error));
	return new BcuError(explicitCode(normalized) ?? "internal_error", normalized.message);
}

export function formatCliError(error: BcuError): string {
	const message = error.message.replace(/\s+/g, " ").trim() || "Unknown failure.";
	return `error ${error.code}: ${message}\nrecovery: ${error.recovery}\n`;
}
