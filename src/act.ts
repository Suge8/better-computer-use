import { canRetryInForeground, outcomeAfterCheck, outcomeAfterObservedValues, prepareAction, validateActions, type ActionState, type PreparedAction } from "./actions.ts";
import { getComputerUseConfig, isHeadlessMode } from "./config.ts";
import type { ActParams, ToolResult, UiAction } from "./contract.ts";
import { BcuError } from "./errors.ts";
import { macosBackend } from "./macos/backend.ts";
import type { ActOutcome, ActRequest, DeliveryPolicy, HelperActResult, NativeInputDelivery } from "./macos/protocol.ts";
import { noteAfterAct } from "./note.ts";
import { nodeByRef, searchOutline, type LookResponse } from "./outline.ts";
import {
	buildToolResult,
	captureCurrentTarget,
	ensurePointIsInLookImage,
	executionTrace,
	modelRefForRootDelta,
	normalizeImageMode,
	normalizeWaitTimeoutMs,
	noteWindowForTarget,
	outlineNodeByRef,
	outlineNodeCenter,
	AUTO_IMAGE_MAX_DIMENSION,
	EXPLICIT_IMAGE_MAX_DIMENSION,
	type ComputerUseDetails,
	type ExecutionTrace,
} from "./observe.ts";
import { ensureTargetWindowId, nativeWindowRequest, resolveCurrentTarget, type ResolvedTarget } from "./roots.ts";
import { COMMAND_TIMEOUT_MS, currentLookOrThrow, makeToolExecutor, operationState, sleep, validateStateId, withWindowWriteLock } from "./session.ts";
import { normalizeText, trimOrUndefined } from "./text.ts";

const ACTION_SETTLE_MS = 280;
/** Milliseconds of helper budget granted per character of typed text. */
const TEXT_DELIVERY_MS_PER_CHAR = 25;

type NativePreparedAction = Exclude<PreparedAction, { action: "wait" }>;

function currentDeliveryPolicy(): DeliveryPolicy {
	if (isHeadlessMode()) return "background";
	const value = (process.env.BCU_DELIVERY_POLICY ?? process.env.BCU_EVENT_DELIVERY ?? "default").toLowerCase();
	return value === "background" || value === "pid" ? "background"
		: value === "foreground" || value === "hid" ? "foreground"
		: value === "ax_only" || value === "ax-only" ? "ax_only"
		: "default";
}

function nativeInputDelivery(policy = currentDeliveryPolicy()): NativeInputDelivery {
	return policy === "foreground" ? "hid" : "pid";
}

function settleMsForExecution(execution: ExecutionTrace): number {
	// Any deltaSource means the helper already awaited UI quiescence; the
	// coordinator must not double-pay with its own settle sleep.
	if (execution.performed?.deltaSource) return 0;
	return execution.variant === "stealth" ? 120 : ACTION_SETTLE_MS;
}

function executionTraceFromAct(result: HelperActResult, policy = currentDeliveryPolicy()): ExecutionTrace {
	const rootDelta = result.rootDelta?.map((delta) => ({ ...delta, ref: modelRefForRootDelta(delta) }));
	return executionTrace("act", result.performed?.delivery === "ax" ? "stealth" : "default", {
		outcome: result.outcome,
		performed: result.performed,
		evidence: result.evidence,
		error: result.error,
		stoppedAt: result.stoppedAt,
		rootDelta,
		delivery: result.performed?.delivery,
		deliveryPolicy: policy,
	});
}

function helperActRequest(target: ResolvedTarget, action: NativePreparedAction, policy = currentDeliveryPolicy()): ActRequest {
	const look = currentLookOrThrow();
	const delivery = nativeInputDelivery(policy);
	const base = { lookId: look.lookId, pid: target.pid, target: action.target, policy };
	switch (action.action) {
		case "press":
		case "click": return { ...base, action: action.action, params: { ...action.params, delivery } };
		case "setText": return { ...base, action: action.action, params: { text: action.params.text, delivery } };
		case "typeText": return { ...base, action: action.action, params: { text: action.params.text, delivery } };
		case "keypress": return { ...base, action: action.action, params: { keys: action.params.keys, delivery } };
		case "scroll": return { ...base, action: action.action, params: { scrollX: action.params.scrollX, scrollY: action.params.scrollY, delivery } };
		case "drag": return { ...base, action: action.action, params: { path: action.params.path, delivery } };
		case "moveMouse": return { ...base, action: action.action, params: { delivery } };
	}
}

function checkedActResult(candidate: HelperActResult): HelperActResult {
	if (!candidate || !["worked", "didnt", "unknown"].includes(candidate.outcome)) {
		throw new Error("Helper act returned an invalid result without an outcome.");
	}
	return candidate;
}

function actTimeoutMs(action: NativePreparedAction): number {
	const textTimeout = "text" in action.params ? action.params.text.length * TEXT_DELIVERY_MS_PER_CHAR + 4_000 : COMMAND_TIMEOUT_MS;
	return Math.max(COMMAND_TIMEOUT_MS, textTimeout);
}

async function helperAct(
	target: ResolvedTarget,
	action: NativePreparedAction,
	headless: boolean,
	signal?: AbortSignal,
): Promise<ExecutionTrace> {
	const timeoutMs = actTimeoutMs(action);
	if ((action.usesCurrentFocus || action.needsForeground) && !headless) {
		const foreground = checkedActResult(await macosBackend.act(helperActRequest(target, action, "foreground"), { signal, timeoutMs }));
		const trace = executionTraceFromAct(foreground, "foreground");
		trace.backgroundFirst = false;
		return trace;
	}
	try {
		const initialPolicy = headless ? "ax_only" : "background";
		const result = checkedActResult(await macosBackend.act(helperActRequest(target, action, initialPolicy), { signal, timeoutMs }));
		if (canRetryInForeground(action, result.outcome, headless)) {
			const foreground = checkedActResult(await macosBackend.act(helperActRequest(target, action, "foreground"), { signal, timeoutMs }));
			const trace = executionTraceFromAct(foreground, "foreground");
			trace.backgroundFirst = true;
			trace.escalatedToForeground = true;
			trace.escalationReason = "side_effect_free_didnt";
			trace.backgroundAttempt = { outcome: "didnt", reason: "Background input produced no observable value change; a foreground retry was safe." };
			return trace;
		}
		const trace = executionTraceFromAct(result, "background");
		trace.backgroundFirst = true;
		return trace;
	} catch (error) {
		const code = (error as Error & { code?: string })?.code;
		if (code !== "foreground_required" || headless) throw error;
		const foreground = checkedActResult(await macosBackend.act(helperActRequest(target, action, "foreground"), { signal, timeoutMs }));
		const trace = executionTraceFromAct(foreground, "foreground");
		trace.backgroundFirst = true;
		trace.escalatedToForeground = true;
		trace.escalationReason = code;
		trace.backgroundAttempt = { outcome: "foreground_required", reason: error instanceof Error ? error.message : String(error) };
		return trace;
	}
}

function prepareUiAction(action: UiAction, state: ActionState, look: LookResponse, headless: boolean): PreparedAction {
	return prepareAction(action, state, {
		headless,
		image: look.image,
		node: outlineNodeByRef,
		center: outlineNodeCenter,
		validatePoint: (x, y, label) => ensurePointIsInLookImage(x, y, look, label),
	});
}

function aggregateExecutions(steps: ExecutionTrace[]): ExecutionTrace {
	const outcomes = steps.map((step) => step.outcome);
	const outcome: ActOutcome = outcomes.includes("didnt") ? "didnt" : outcomes.includes("unknown") ? "unknown" : "worked";
	const fallback = steps.find((step) => step.escalatedToForeground);
	return executionTrace("act", steps.every((step) => step.variant === "stealth") ? "stealth" : "default", {
		outcome,
		steps,
		actionCount: steps.length,
		rootDelta: steps.flatMap((step) => step.rootDelta ?? []),
		backgroundFirst: true,
		escalatedToForeground: Boolean(fallback),
		escalationReason: fallback?.escalationReason,
		backgroundAttempt: fallback?.backgroundAttempt,
	});
}

async function dispatchUiAction(action: UiAction, target: ResolvedTarget, look: LookResponse, headless: boolean, state: ActionState, signal?: AbortSignal): Promise<ExecutionTrace> {
	const prepared = prepareUiAction(action, state, look, headless);
	if (prepared.action === "wait") {
		await sleep(prepared.params.ms, signal);
		return executionTrace("wait", "stealth", { outcome: "worked" });
	}
	const trace = await helperAct(target, prepared, headless, signal);
	if (!headless && (prepared.establishesFocus || (prepared.action === "click" && "x" in prepared.target))) {
		state.currentFocus = true;
	}
	return trace;
}

async function dispatchUiTransaction(actions: UiAction[], target: ResolvedTarget, look: LookResponse, headless: boolean, signal?: AbortSignal): Promise<ExecutionTrace> {
	// Strict-headless batches have one immutable delivery class. When foreground
	// fallback is permitted, decide independently per action so a completed
	// background prefix is never replayed as part of a foreground batch.
	if (headless && actions.every((action) => action.action !== "wait")) {
		const actionState: ActionState = { currentFocus: false };
		const requests = actions.map((action) => helperActRequest(target, prepareUiAction(action, actionState, look, true) as NativePreparedAction, "ax_only"));
		const textLength = actions.reduce((sum, action) => sum + (action.text?.length ?? 0), 0);
		const result = await macosBackend.actBatch(requests, { signal, timeoutMs: Math.max(COMMAND_TIMEOUT_MS, textLength * TEXT_DELIVERY_MS_PER_CHAR + 6_000) });
		if (!result.steps || result.steps.length === 0) throw new Error("Native action transaction returned no checked steps.");
		const execution = aggregateExecutions(result.steps.map((step) => executionTraceFromAct(step, "ax_only")));
		const batchTrace = executionTraceFromAct(result, "ax_only");
		execution.outcome = result.outcome;
		execution.performed = result.performed;
		execution.rootDelta = batchTrace.rootDelta;
		execution.stoppedAt = result.stoppedAt;
		return execution;
	}
	const steps: ExecutionTrace[] = [];
	const actionState: ActionState = { currentFocus: false };
	for (const action of actions) {
		const step = await dispatchUiAction(action, target, look, headless, actionState, signal);
		steps.push(step);
		if (step.outcome === "didnt") break;
	}
	return aggregateExecutions(steps);
}

/** Runs the requested postcondition and folds its result into the execution trace. */
async function verifyExpectation(params: ActParams, target: ResolvedTarget, look: LookResponse, execution: ExecutionTrace, signal?: AbortSignal): Promise<void> {
	const expectedText = trimOrUndefined(params.expect?.text);
	const expectedRole = trimOrUndefined(params.expect?.role);
	const expectedValue = trimOrUndefined(params.expect?.value);
	if (!expectedText && !expectedRole && !expectedValue) throw new BcuError("invalid_arguments", "act-ui expect requires text, role, or value.");
	const timeoutMs = normalizeWaitTimeoutMs(params.expect!.timeoutMs);
	const beforePresent = searchOutline(look.parsedOutline!, expectedText, expectedRole, undefined, 50)
		.some((match) => !expectedValue || normalizeText(match.node.value) === normalizeText(expectedValue));
	const desiredWasPreexisting = beforePresent !== (params.expect!.gone === true);
	const verification = await macosBackend.waitFor({
		...nativeWindowRequest(target),
		text: expectedText,
		role: expectedRole,
		value: expectedValue,
		gone: params.expect!.gone === true,
		timeoutMs,
	}, { signal, timeoutMs: timeoutMs + 2_000 });
	execution.verification = {
		status: verification.found ? (desiredWasPreexisting ? "preexisting" : "verified") : "failed",
		text: expectedText,
		role: expectedRole,
		value: expectedValue,
		gone: params.expect!.gone === true || undefined,
		timeoutMs,
	};
	execution.outcome = outcomeAfterCheck(execution.outcome ?? "unknown", execution.verification.status);
	if (!verification.found) {
		execution.error = {
			code: "postcondition_failed",
			message: `The action was delivered but its postcondition was not satisfied within ${timeoutMs}ms.`,
		};
	}
}

async function performAct(params: ActParams, signal?: AbortSignal): Promise<ToolResult<ComputerUseDetails>> {
	const actions = Array.isArray(params.actions) ? params.actions : [];
	validateActions(actions);
	const state = operationState();
	state.currentImageMode = normalizeImageMode(params.image ?? "never");
	validateStateId(params.stateId);
	const look = currentLookOrThrow();
	const baseView = { stateId: state.currentCapture!.stateId, outline: state.currentOutline! };
	const target = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
	const noteBefore = state.currentNote;
	return await withWindowWriteLock(target, async () => {
		const headless = params.headless ?? getComputerUseConfig().headless;
		const execution = await dispatchUiTransaction(actions, target, look, headless, signal);
		const executedActions = actions.slice(0, execution.actionCount ?? actions.length);
		if (params.expect) await verifyExpectation(params, target, look, execution, signal);
		else await sleep(settleMsForExecution(execution), signal);
		const capture = await captureCurrentTarget(
			signal,
			"never",
			state.currentImageMode === "always" ? EXPLICIT_IMAGE_MAX_DIMENSION : AUTO_IMAGE_MAX_DIMENSION,
			target,
			state.currentImageMode !== "never",
		);
		execution.outcome = outcomeAfterObservedValues(execution.outcome ?? "unknown", executedActions, (ref) => nodeByRef(capture.outline, ref)?.value);
		for (const action of executedActions) {
			state.currentNote = noteAfterAct(state.currentNote ?? noteBefore, action.ref, capture.outline, { window: noteWindowForTarget(capture.target, capture.look), rootDelta: execution.rootDelta });
		}
		return buildToolResult(
			"act_ui",
			`Executed ${executedActions.length} checked UI action${executedActions.length === 1 ? "" : "s"} in ${target.appName} — ${target.windowTitle}. Returned state ${capture.capture.stateId}.`,
			capture,
			execution,
			state.currentImageMode,
			baseView,
		);
	});
}

export const executeAct = makeToolExecutor(performAct);
