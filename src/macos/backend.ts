import { getComputerUseConfig } from "../config.ts";
import { parseLookResponse, type LookResponse } from "../outline.ts";
import { toBoolean, toFiniteNumber, toOptionalString, type ActRequest, type FocusWindowResult, type FramePoints, type FrontmostResult, type HelperActResult, type HelperApp, type HelperRoot, type HelperTarget, type ObserveRequest, type ReadTextRequest, type ReadTextResponse, type RootKind, type RootQuery, type WaitForRequest, type WaitForResponse } from "./protocol.ts";
import { macosHelper } from "./helper.ts";

function parseApps(result: unknown): HelperApp[] {
	const array = Array.isArray(result) ? result : (result as any)?.apps;
	if (!Array.isArray(array)) return [];

	return array
		.map((raw) => {
			const pid = Math.trunc(toFiniteNumber((raw as any)?.pid, NaN));
			if (!Number.isFinite(pid) || pid <= 0) return undefined;
			const appName = toOptionalString((raw as any)?.appName) ?? "Unknown App";
			return {
				appName,
				bundleId: toOptionalString((raw as any)?.bundleId),
				pid,
				isFrontmost: toBoolean((raw as any)?.isFrontmost),
			} as HelperApp;
		})
		.filter((item): item is HelperApp => Boolean(item));
}

function parseFramePoints(raw: unknown): FramePoints {
	const frame = (raw as any)?.framePoints ?? {};
	return {
		x: toFiniteNumber(frame.x, 0),
		y: toFiniteNumber(frame.y, 0),
		w: Math.max(1, toFiniteNumber(frame.w, 1)),
		h: Math.max(1, toFiniteNumber(frame.h, 1)),
	};
}

function parseRoots(result: unknown): HelperRoot[] {
	const array = Array.isArray(result) ? result : (result as any)?.roots;
	if (!Array.isArray(array)) return [];

	return array.flatMap((raw) => {
		const rootRef = toOptionalString((raw as any)?.rootRef);
		if (!rootRef) return [];
		const metadata = typeof (raw as any)?.metadata === "object" && (raw as any).metadata !== null ? (raw as any).metadata as Record<string, unknown> : {};
		const kind = ["window", "menu", "sheet", "popover", "dialog"].includes((raw as any)?.kind) ? (raw as any).kind as RootKind : "window";
		return [{
			kind,
			rootRef,
			windowId: Number.isFinite((raw as any)?.windowId) ? Math.trunc((raw as any).windowId) : undefined,
			pid: Number.isFinite((raw as any)?.pid) ? Math.trunc((raw as any).pid) : undefined,
			appName: toOptionalString((raw as any)?.appName),
			bundleId: toOptionalString((raw as any)?.bundleId),
			title: toOptionalString((raw as any)?.title) ?? "",
			role: toOptionalString((raw as any)?.role),
			subrole: toOptionalString((raw as any)?.subrole),
			framePoints: parseFramePoints(raw),
			scaleFactor: Math.max(1, toFiniteNumber((raw as any)?.scaleFactor, 1)),
			zOrder: Math.trunc(toFiniteNumber((raw as any)?.zOrder, 0)),
			isMinimized: toBoolean((raw as any)?.isMinimized),
			isOnscreen: toBoolean((raw as any)?.isOnscreen),
			isMain: toBoolean((raw as any)?.isMain),
			isFocused: toBoolean((raw as any)?.isFocused),
			isModal: toBoolean((raw as any)?.isModal),
			metadata,
		}];
	});
}

function helperAction(request: ActRequest): Record<string, unknown> {
	if (!("focus" in request.target)) return { ...request };
	return { ...request, target: request.target.focus, params: { ...request.params, preserveFocus: true } };
}

export const macosBackend = {
	async listApps(signal?: AbortSignal): Promise<HelperApp[]> {
		return parseApps(await macosHelper.command<unknown>("listApps", {}, { signal }));
	},

	async listRoots(query: RootQuery, signal?: AbortSignal): Promise<HelperRoot[]> {
		return parseRoots(await macosHelper.command<unknown>("listRoots", {
			...(Number.isFinite(query.pid) ? { pid: Math.trunc(query.pid!) } : {}),
			...(query.title?.trim() ? { title: query.title.trim() } : {}),
		}, { signal }));
	},

	async getFrontmost(signal?: AbortSignal): Promise<FrontmostResult> {
		const result = await macosHelper.command<any>("getFrontmost", {}, { signal });
		const pid = Math.trunc(toFiniteNumber(result?.pid, NaN));
		if (!Number.isFinite(pid) || pid <= 0) {
			throw new Error("No frontmost app was available for screenshot targeting.");
		}
		return {
			appName: toOptionalString(result?.appName) ?? "Unknown App",
			bundleId: toOptionalString(result?.bundleId),
			pid,
			windowTitle: toOptionalString(result?.windowTitle),
			windowId: Number.isFinite(result?.windowId) ? Math.trunc(result.windowId) : undefined,
			rootRef: toOptionalString(result?.rootRef),
		};
	},

	async focusWindow(target: HelperTarget, signal?: AbortSignal): Promise<FocusWindowResult> {
		return await macosHelper.command<FocusWindowResult>("focusWindow", { ...target }, { signal });
	},

	async observe(request: ObserveRequest, options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<LookResponse> {
		return parseLookResponse(await macosHelper.command("look", {
			baseLookId: request.baseLookId,
			rootRef: request.rootRef,
			windowId: request.windowId,
			maxDimension: request.maxDimension,
			readText: request.readText,
			scopeRef: request.scopeRef,
			includeImage: request.includeImage,
		}, options));
	},

	async act(request: ActRequest, options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<HelperActResult> {
		return await macosHelper.command<HelperActResult>("act", { ...helperAction(request), cursorOverlay: getComputerUseConfig().cursor_overlay }, options);
	},

	async actBatch(requests: ActRequest[], options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<HelperActResult> {
		const cursorOverlay = getComputerUseConfig().cursor_overlay;
		return await macosHelper.command<HelperActResult>("actBatch", { actions: requests.map((request) => ({ ...helperAction(request), cursorOverlay })) }, options);
	},

	async readText(args: ReadTextRequest, options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<ReadTextResponse> {
		return await macosHelper.command("axReadText", { ...args }, options);
	},

	async waitFor(args: WaitForRequest, options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<WaitForResponse> {
		return await macosHelper.command("axWaitFor", { ...args }, options);
	},

	/** Release process-local helper resources when the current session is torn down. */
	shutdown(): void {
		macosHelper.dispose();
	},
};
