import { AsyncLocalStorage } from "node:async_hooks";
import { BcuError } from "./errors.ts";
import { restoreOutline, serializeOutline, type LookResponse, type Outline, type SerializedOutline } from "./outline.ts";
import { StateStore, type StoredState } from "./runtime.ts";

interface StateTargetSnapshot {
	pid: number;
	windowId: number;
	windowRef?: string;
}

export interface CurrentTarget {
	appName: string;
	bundleId?: string;
	pid: number;
	windowTitle: string;
	windowId: number;
	windowRef?: string;
	nativeWindowRef?: string;
}

export interface CurrentCapture {
	stateId: string;
	timestamp: number;
}

export interface OperationState {
	currentTarget?: CurrentTarget;
	currentCapture?: CurrentCapture;
	currentStateTarget?: StateTargetSnapshot;
	currentLook?: LookResponse;
	currentOutline?: Outline;
	resourceKey?: string;
	epoch?: number;
	lastSearchOcrEscalatedLookId?: string;
}

export interface UiObservation {
	target: CurrentTarget;
	capture: CurrentCapture;
	look: Omit<LookResponse, "parsedOutline" | "outline">;
	outline: SerializedOutline;
}

export class SavedStates {
	readonly store = new StateStore<UiObservation>(128);
	readonly operations = new AsyncLocalStorage<OperationState>();

	current(): OperationState {
		const state = this.operations.getStore();
		if (!state) throw new BcuError("internal_error", "Operation state is unavailable outside a tool execution.");
		return state;
	}

	get(stateId: string): StoredState<UiObservation> | undefined {
		return this.store.get(stateId);
	}

	set(record: StoredState<UiObservation>): void {
		this.store.set(record);
	}

	clear(): void {
		this.store.clear();
	}

	hydrate(record: StoredState<UiObservation> | undefined): OperationState {
		if (!record) return {};
		const outline = restoreOutline(record.value.outline);
		return {
			currentTarget: { ...record.value.target },
			currentCapture: { ...record.value.capture },
			currentStateTarget: { pid: record.value.target.pid, windowId: record.value.target.windowId, windowRef: record.value.target.windowRef },
			currentLook: { ...record.value.look, outline: outline.root, parsedOutline: outline },
			currentOutline: outline,
			resourceKey: record.resourceKey,
			epoch: record.epoch,
		};
	}

	saveDesktop(state: OperationState, resourceKey: string, epoch: number): void {
		if (!state.currentTarget || !state.currentCapture || !state.currentLook || !state.currentOutline) return;
		this.store.set({
			stateId: state.currentCapture.stateId,
			resourceKey,
			epoch,
			value: {
				target: { ...state.currentTarget },
				capture: { ...state.currentCapture },
				look: {
					lookId: state.currentLook.lookId,
					capturedAt: state.currentLook.capturedAt,
					window: structuredClone(state.currentLook.window),
					image: state.currentLook.image ? {
						mimeType: state.currentLook.image.mimeType,
						width: state.currentLook.image.width,
						height: state.currentLook.image.height,
					} : undefined,
					timings: { ...state.currentLook.timings },
					readText: state.currentLook.readText ? { ...state.currentLook.readText } : undefined,
				},
				outline: serializeOutline(state.currentOutline),
			},
		});
	}
}
