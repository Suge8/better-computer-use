import { loadComputerUseConfig } from "./config.ts";
import { BcuError } from "./errors.ts";
import { ensureMacosReady } from "./macos/permissions.ts";
import { macosBackend } from "./macos/backend.ts";
import type { HelperDiagnostics } from "./macos/protocol.ts";
import type { Outline, LookResponse } from "./outline.ts";
import type { PermissionStatus } from "./permissions.ts";
import { clearRootRefs } from "./root-refs.ts";
import { ResourceScheduler } from "./runtime.ts";
import { SavedStates, type CurrentCapture, type CurrentTarget, type OperationState } from "./state.ts";
import { trimOrUndefined } from "./text.ts";

export const MISSING_TARGET_ERROR = "No root is being controlled. Run observe-ui first to choose one.";
export const CURRENT_TARGET_GONE_ERROR = "The controlled root is gone. Run observe-ui to choose a current root.";
export const COMMAND_TIMEOUT_MS = 15_000;

interface SessionRuntime {
	permissionStatus?: PermissionStatus;
	helperDiagnostics?: HelperDiagnostics;
	lastPermissionCheckAt: number;
}

const runtime: SessionRuntime = { lastPermissionCheckAt: 0 };

export const savedStates = new SavedStates();
export let resourceScheduler = new ResourceScheduler();

export function helperDiagnostics(): HelperDiagnostics | undefined {
	return runtime.helperDiagnostics;
}

export function operationState(): OperationState {
	return savedStates.current();
}

export function desktopResourceKey(target: Pick<CurrentTarget, "pid">): string {
	return `desktop-pid:${target.pid}`;
}

export function persistOperation(state: OperationState): void {
	if (!state.currentTarget || !state.currentCapture || !state.currentLook || !state.currentOutline) return;
	const resourceKey = state.resourceKey ?? desktopResourceKey(state.currentTarget);
	const epoch = state.epoch ?? resourceScheduler.epoch(resourceKey);
	savedStates.saveDesktop(state, resourceKey, epoch);
}

/** Release handles and state owned by the current session. */
export async function shutdownComputerUseSession(): Promise<void> {
	await resourceScheduler.close();
	resourceScheduler = new ResourceScheduler();
	savedStates.clear();
	clearRootRefs();
	runtime.permissionStatus = undefined;
	runtime.helperDiagnostics = undefined;
	runtime.lastPermissionCheckAt = 0;
	macosBackend.shutdown();
}

export function throwIfAborted(signal?: AbortSignal): void {
	if (signal?.aborted) throw new BcuError("internal_error", "Operation aborted.");
}

export async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
	if (ms <= 0) return;
	throwIfAborted(signal);

	await new Promise<void>((resolve, reject) => {
		const timer = setTimeout(() => {
			cleanup();
			resolve();
		}, ms);

		const onAbort = () => {
			cleanup();
			reject(new BcuError("internal_error", "Operation aborted."));
		};

		const cleanup = () => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
		};

		signal?.addEventListener("abort", onAbort, { once: true });
	});
}

export async function withWindowWriteLock<T>(target: Pick<CurrentTarget, "pid">, work: () => Promise<T>): Promise<T> {
	const state = operationState();
	const key = desktopResourceKey(target);
	const baseEpoch = state.epoch ?? resourceScheduler.epoch(key);
	const result = await resourceScheduler.write(key, baseEpoch, async (nextEpoch) => {
		state.resourceKey = key;
		state.epoch = nextEpoch;
		return await work();
	});
	return result.value;
}

export function currentTargetOrThrow(): CurrentTarget {
	const target = operationState().currentTarget;
	if (!target) throw new BcuError("window_stale", MISSING_TARGET_ERROR);
	return target;
}

export function currentLookOrThrow(): LookResponse {
	const state = operationState();
	if (!state.currentLook || !state.currentCapture) throw new BcuError("stale_state", "No observation is available. Run observe-ui first.");
	return state.currentLook;
}

export function validateStateId(stateId?: string): CurrentCapture {
	const state = operationState();
	if (!state.currentCapture) throw new BcuError("stale_state", "No observation is available. Run observe-ui first.");
	if (stateId && state.currentCapture.stateId !== stateId) {
		throw new BcuError("stale_state", `State '${stateId}' is not the active state '${state.currentCapture.stateId}'. Observe the root again.`);
	}
	const stateTarget = state.currentStateTarget;
	if (stateTarget && state.currentTarget && (stateTarget.pid !== state.currentTarget.pid || stateTarget.windowId !== state.currentTarget.windowId)) {
		throw new BcuError("stale_state", "The saved state belongs to another root. Observe the root you want and retry.");
	}
	return state.currentCapture;
}

export function currentOutlineOrThrow(stateId?: string): Outline {
	validateStateId(stateId);
	const outline = operationState().currentOutline;
	if (!outline) throw new BcuError("stale_state", "No observation outline is available. Run observe-ui first.");
	return outline;
}

/** Live resource identity of the current observation, required before scheduled reads. */
export function currentResourceOrThrow(): { resourceKey: string; epoch: number } {
	const state = operationState();
	if (!state.resourceKey || state.epoch === undefined) throw new BcuError("stale_state", "The observation has no live resource identity. Observe again.");
	return { resourceKey: state.resourceKey, epoch: state.epoch };
}

async function ensureReady(signal?: AbortSignal): Promise<void> {
	loadComputerUseConfig();
	throwIfAborted(signal);
	const ready = await ensureMacosReady({
		permissionStatus: runtime.permissionStatus,
		lastPermissionCheckAt: runtime.lastPermissionCheckAt,
		helperDiagnostics: runtime.helperDiagnostics,
	}, signal);
	runtime.permissionStatus = ready.permissionStatus;
	runtime.lastPermissionCheckAt = ready.lastPermissionCheckAt;
	runtime.helperDiagnostics = ready.helperDiagnostics;
}

/**
 * Runs one tool inside a request-local operation state hydrated from `stateId`,
 * after the helper and permissions are ready.
 */
export function makeToolExecutor<P, R>(perform: (params: P, signal?: AbortSignal) => Promise<R>) {
	return async (params: P, signal?: AbortSignal): Promise<R> => {
		const requestedStateId = trimOrUndefined((params as { stateId?: string } | undefined)?.stateId);
		const stateRecord = requestedStateId ? savedStates.get(requestedStateId) : undefined;
		if (requestedStateId && !stateRecord) {
			throw new BcuError("stale_state", `State '${requestedStateId}' is unavailable or was evicted. Observe the root again.`);
		}
		const operation = savedStates.hydrate(stateRecord);
		return await savedStates.operations.run(operation, async () => {
			await resourceScheduler.read("session-lifecycle", async () => await ensureReady(signal));
			throwIfAborted(signal);
			const result = await perform(params, signal);
			persistOperation(operation);
			return result;
		});
	};
}
