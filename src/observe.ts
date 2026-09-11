import { randomUUID } from "node:crypto";
import { saveScreenshot } from "./artifacts.ts";
import { isHeadlessMode } from "./config.ts";
import type { Change, ExpandResult, ExpandUiParams, ImageInfo, ImageMode, InspectResult, InspectUiParams, ObserveParams, ObserveResult, ReadTextParams, ReadTextResult, RootSummary, SearchMatch, SearchResult, SearchUiParams, WaitForParams, WaitForResult } from "./contract.ts";
import { BcuError } from "./errors.ts";
import { macosBackend } from "./macos/backend.ts";
import { toFiniteNumber, type ActOutcome, type HelperActPerformed, type HelperActResult, type NativeInputDelivery } from "./macos/protocol.ts";
import { graftScopedOutline, nodeByRef, searchOutline, serializeOutlineNode, type LookResponse, type Outline, type OutlineNode } from "./outline.ts";
import { project, type ProjectedNode } from "./projection.ts";
import { ensureTargetWindowId, nativeWindowRequest, matchesTargetSelection, normalizeWindowSelector, resolveCurrentTarget, resolveTargetByWindowSelector, resolveTargetForObserve, sameRootIdentity, setCurrentTarget, type ResolvedTarget } from "./roots.ts";
import { COMMAND_TIMEOUT_MS, currentOutlineOrThrow, currentResourceOrThrow, desktopResourceKey, makeToolExecutor, operationState, persistOperation, resourceScheduler, validateStateId } from "./session.ts";
import type { CurrentCapture } from "./state.ts";
import { trimOrUndefined } from "./text.ts";
import { changesBetween, stabilizeRefs } from "./view.ts";

const LOOK_TIMEOUT_MS = 33_000;
export const AUTO_IMAGE_MAX_DIMENSION = 900;
export const EXPLICIT_IMAGE_MAX_DIMENSION = 1_600;
/** Diffs compare complete projections; only the rendered view is folded. */
export const UNFOLDED = { maxDepth: Number.MAX_SAFE_INTEGER, maxNodes: Number.MAX_SAFE_INTEGER };

type ExecutionVariant = "stealth" | "default";
type ActionDelivery = "ax" | NativeInputDelivery;
type DeliveryPolicy = "ax_only" | "background" | "default" | "foreground";

export interface ExecutionTrace {
	strategy: "look" | "act" | "wait";
	variant?: ExecutionVariant;
	delivery?: ActionDelivery;
	deliveryPolicy?: DeliveryPolicy;
	outcome?: ActOutcome;
	performed?: HelperActPerformed;
	error?: HelperActResult["error"];
	steps?: ExecutionTrace[];
	actionCount?: number;
	stoppedAt?: number;
	escalatedToForeground?: boolean;
	escalationReason?: string;
	verified?: boolean;
	preexisting?: boolean;
}

export interface CaptureResult {
	target: ResolvedTarget;
	capture: CurrentCapture;
	look: LookResponse;
	outline: Outline;
}

export function executionTrace(
	strategy: ExecutionTrace["strategy"],
	variant: ExecutionVariant,
	metadata: Omit<ExecutionTrace, "strategy" | "variant"> = {},
): ExecutionTrace {
	return { strategy, variant: isHeadlessMode() ? "stealth" : variant, ...metadata };
}

export function normalizeImageMode(value: unknown): ImageMode {
	return value === "always" ? "always" : "never";
}

export function normalizeWaitTimeoutMs(value: unknown): number {
	return Math.max(100, Math.min(60_000, Math.trunc(toFiniteNumber(value, 10_000))));
}

export function outlineNodeByRef(ref: string): OutlineNode {
	const outline = operationState().currentOutline;
	const node = outline ? nodeByRef(outline, ref) : undefined;
	if (!node) throw new BcuError("element_not_found", `Ref '${ref}' does not belong to the current state. Observe the root again and use a ref from the new state.`);
	return node;
}

export function wireRefForNode(node: OutlineNode): string {
	if (node.pictureOnly || !node.wireRef) {
		throw new BcuError("element_not_found", `Ref '${node.ref}' has no accessibility element; it can only be clicked by coordinates.`);
	}
	return node.wireRef;
}

export function outlineNodeCenter(node: OutlineNode): { x: number; y: number } {
	if (!node.rect) throw new BcuError("element_not_found", `Ref '${node.ref}' has no coordinates in the current state. Observe the root again.`);
	return { x: node.rect.x + node.rect.w / 2, y: node.rect.y + node.rect.h / 2 };
}

export function ensurePointIsInLookImage(x: number, y: number, look: LookResponse, errorPrefix = "Coordinates"): void {
	if (!look.image) {
		throw new BcuError("invalid_arguments", `${errorPrefix} require an image-bearing state. Observe with --image always, or act on a ref.`);
	}
	if (!Number.isFinite(x) || !Number.isFinite(y)) throw new BcuError("invalid_arguments", `${errorPrefix} must be finite numbers.`);
	if (x < 0 || y < 0 || x >= look.image.width || y >= look.image.height) {
		throw new BcuError("invalid_arguments", `${errorPrefix} (${Math.round(x)},${Math.round(y)}) are outside the image bounds (${look.image.width}x${look.image.height}).`);
	}
}

/** Resolves an @e ref to the helper element ref a scoped condition needs. */
export function scopeWireRef(scope: string | undefined): string | undefined {
	const ref = trimOrUndefined(scope);
	return ref ? wireRefForNode(outlineNodeByRef(ref)) : undefined;
}

export function rootSummary(result: CaptureResult): RootSummary {
	return {
		ref: result.target.windowRef,
		app: result.target.appName,
		pid: result.target.pid,
		title: result.target.windowTitle,
		windowId: result.target.windowId > 0 ? result.target.windowId : undefined,
		frame: result.look.window.framePoints,
		scale: result.look.window.scaleFactor,
	};
}

export async function imageInfo(result: CaptureResult, mode: ImageMode): Promise<ImageInfo | undefined> {
	const image = result.look.image;
	if (mode !== "always" || !image?.jpegBase64) return undefined;
	return await saveScreenshot(result.capture.stateId, {
		data: image.jpegBase64,
		mimeType: image.mimeType ?? "image/jpeg",
		width: image.width,
		height: image.height,
	});
}

async function performLook(
	target: ResolvedTarget,
	options: { readText: "auto" | "always" | "never"; baseLookId?: string; scopeRef?: string; maxDimension?: number; includeImage?: boolean },
	signal?: AbortSignal,
): Promise<LookResponse> {
	if (!target.nativeWindowRef) {
		throw new BcuError("window_stale", `Root '${target.windowTitle}' has no helper root reference. Run find-roots and select a current root.`);
	}
	return await macosBackend.observe({
		rootRef: target.nativeWindowRef,
		windowId: target.windowId > 0 ? target.windowId : undefined,
		baseLookId: options.baseLookId,
		readText: options.readText,
		scopeRef: options.scopeRef,
		maxDimension: options.maxDimension,
		includeImage: options.includeImage,
	}, { signal, timeoutMs: LOOK_TIMEOUT_MS });
}

/** Side effects: adopts the fresh look as the operation's current target, capture, look and outline. */
export async function captureCurrentTarget(
	signal?: AbortSignal,
	readText: "auto" | "always" | "never" = "never",
	maxDimension = AUTO_IMAGE_MAX_DIMENSION,
	targetOverride?: ResolvedTarget,
	includeImage = false,
): Promise<CaptureResult> {
	const state = operationState();
	const baseOutline = state.currentOutline;
	const baseTarget = state.currentTarget;
	let target = targetOverride ?? await resolveCurrentTarget(signal);
	target = await ensureTargetWindowId(target, signal);
	const look = await performLook(target, { maxDimension, readText, includeImage }, signal);
	const outline = stabilizeRefs(baseTarget && sameRootIdentity(baseTarget, target) ? baseOutline : undefined, look.parsedOutline!);
	look.parsedOutline = outline;
	look.outline = outline.root;
	const capture: CurrentCapture = { stateId: randomUUID(), timestamp: Date.now() };

	setCurrentTarget(target);
	state.currentCapture = capture;
	state.currentStateTarget = { pid: target.pid, windowId: target.windowId, windowRef: target.windowRef };
	state.currentLook = look;
	state.currentOutline = outline;
	state.resourceKey = desktopResourceKey(target);
	state.epoch ??= resourceScheduler.epoch(state.resourceKey);

	return { target, capture, look, outline };
}

export function observeResult(result: CaptureResult, image?: ImageInfo): ObserveResult {
	const projection = project(result.outline);
	return {
		stateId: result.capture.stateId,
		root: rootSummary(result),
		nodes: projection.nodes,
		shown: projection.shown,
		total: projection.total,
		image,
	};
}

/** Side effects: captures/updates current target, capture state, look, and parsed outline. */
async function performObserve(params: ObserveParams, signal?: AbortSignal): Promise<ObserveResult> {
	const mode = params.mode ?? "semantic";
	const imageMode = normalizeImageMode(params.image ?? (mode === "fused" ? "always" : "never"));
	const readText = params.readText ?? (mode === "fused" ? "auto" : "never");
	const selection = {
		app: trimOrUndefined(params.app),
		windowTitle: trimOrUndefined(params.windowTitle),
		root: normalizeWindowSelector(params.root),
	};
	const requestedTarget = selection.root
		? await resolveTargetByWindowSelector(params.root!, signal)
		: await resolveTargetForObserve(selection, signal);
	const resourceKey = desktopResourceKey(requestedTarget);
	const scheduled = await resourceScheduler.read(resourceKey, async (epoch) => {
		const state = operationState();
		state.resourceKey = resourceKey;
		state.epoch = epoch;
		return await captureCurrentTarget(signal, readText, imageMode === "always" ? EXPLICIT_IMAGE_MAX_DIMENSION : AUTO_IMAGE_MAX_DIMENSION, requestedTarget, imageMode === "always");
	});
	const captureResult = scheduled.value;
	// Model @r refs are re-minted on re-resolution, so ref string equality
	// alone false-positives as drift for the same root; compare stable
	// identity against the resolved request too.
	if (!matchesTargetSelection(captureResult.target, selection) && !sameRootIdentity(captureResult.target, requestedTarget)) {
		throw new BcuError(
			"window_stale",
			`Observation drifted from the requested root: asked for ${requestedTarget.appName} — ${requestedTarget.windowTitle}, captured ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Retry with an exact --root.`,
		);
	}
	return observeResult(captureResult, await imageInfo(captureResult, imageMode));
}

/** Maps outline hits onto the nodes the agent actually sees, with their projected ancestry. */
function projectedMatches(outline: Outline, hits: OutlineNode[]): SearchMatch[] {
	const projection = project(outline, UNFOLDED);
	const projected = new Map(projection.nodes.map((node) => [node.ref, node]));
	const matches: SearchMatch[] = [];
	const seen = new Set<string>();
	for (const hit of hits) {
		// A hit the projection dropped is noise the agent cannot act on; only a
		// node that speaks for the hit may stand in for it.
		const node = projected.get(projection.represents.get(hit.ref) ?? "");
		if (!node || seen.has(node.ref)) continue;
		seen.add(node.ref);
		const path: string[] = [];
		for (let parent = node.parent; parent; parent = projected.get(parent)?.parent) path.unshift(parent);
		matches.push({ ...node, depth: 0, path });
	}
	return matches;
}

/** Pure cached-outline query, except for a one-time OCR escalation when the cache has no usable match. */
async function performSearchUi(params: SearchUiParams, signal?: AbortSignal): Promise<SearchResult> {
	const state = operationState();
	let outline = currentOutlineOrThrow(params.stateId);
	const text = trimOrUndefined(params.text);
	const role = trimOrUndefined(params.role);
	const action = trimOrUndefined(params.action);
	const limit = Math.max(1, Math.min(50, Math.trunc(toFiniteNumber(params.limit, 12))));
	let found = searchOutline(outline, text, role, action);
	const look = state.currentLook;
	const shouldEscalate = found.matches.every((match) => !match.canPress && !match.canFocus && !match.canSetValue && match.actions.length === 0 && !match.pictureOnly);
	if (shouldEscalate && look && look.readText?.requested !== "never" && !look.readText?.executed && state.lastSearchOcrEscalatedLookId !== look.lookId) {
		state.lastSearchOcrEscalatedLookId = look.lookId;
		const currentTarget = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
		// captureCurrentTarget adopts the new look/outline/capture into the
		// operation state, so refs in these matches stay actable. Keep the image
		// payload: OCR-only matches are clicked by coordinate, and coordinate
		// acts require the current look to be image-bearing.
		const resource = currentResourceOrThrow();
		const captureResult = (await resourceScheduler.readAt(resource.resourceKey, resource.epoch, async () => await captureCurrentTarget(signal, "always", AUTO_IMAGE_MAX_DIMENSION, currentTarget, true))).value;
		outline = captureResult.outline;
		found = searchOutline(outline, text, role, action);
	}
	const matches = projectedMatches(outline, found.matches);
	return { stateId: state.currentCapture!.stateId, matches: matches.slice(0, limit), total: matches.length };
}

/** Reads the cached outline; truncated refs trigger a scoped look. */
async function performExpandUi(params: ExpandUiParams, signal?: AbortSignal): Promise<ExpandResult> {
	const state = operationState();
	const outline = currentOutlineOrThrow(params.stateId);
	const ref = trimOrUndefined(params.ref);
	if (!ref) throw new BcuError("invalid_arguments", "expand-ui requires --ref.");
	const initial = nodeByRef(outline, ref);
	if (!initial) throw new BcuError("element_not_found", `Ref '${ref}' is not in the current state.`);
	let target: OutlineNode = initial;
	const depth = Math.max(1, Math.min(8, Math.trunc(toFiniteNumber(params.depth, 3))));
	if (target.truncated) {
		const currentTarget = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
		const targetWireRef = wireRefForNode(target);
		const resource = currentResourceOrThrow();
		const scoped = (await resourceScheduler.readAt(resource.resourceKey, resource.epoch, async () => await performLook(currentTarget, {
			readText: "auto",
			baseLookId: outline.lookId,
			scopeRef: targetWireRef,
			maxDimension: 1,
			includeImage: false,
		}, signal))).value;
		target = graftScopedOutline(outline, target.ref, scoped.parsedOutline!);
		outline.lookId = scoped.lookId;
		state.currentOutline = outline;
		state.currentLook = { ...scoped, image: state.currentLook?.image, outline: outline.root, parsedOutline: outline };
		persistOperation(state);
	}
	const projection = project(outline, { maxDepth: depth, from: target });
	return { stateId: state.currentCapture!.stateId, ref: target.ref, nodes: projection.nodes };
}

/** Pure cached-outline inspection: every raw field the projection hides. */
async function performInspectUi(params: InspectUiParams): Promise<InspectResult> {
	const outline = currentOutlineOrThrow(params.stateId);
	const ref = trimOrUndefined(params.ref);
	if (!ref) throw new BcuError("invalid_arguments", "inspect-ui requires --ref.");
	const target = nodeByRef(outline, ref);
	if (!target) throw new BcuError("element_not_found", `Ref '${ref}' is not in the current state.`);
	const projected = project(outline, UNFOLDED).nodes.find((node) => node.ref === target.ref);
	return {
		stateId: operationState().currentCapture!.stateId,
		node: { ...serializeOutlineNode(target), children: [] },
		owners: projected?.owners,
	};
}

async function performReadText(params: ReadTextParams, signal?: AbortSignal): Promise<ReadTextResult> {
	validateStateId(params.stateId);
	const ref = trimOrUndefined(params.ref);
	if (!ref) throw new BcuError("invalid_arguments", "read-text requires --ref.");
	const node = outlineNodeByRef(ref);
	const state = operationState();
	const resource = currentResourceOrThrow();
	const raw = (await resourceScheduler.readAt(resource.resourceKey, resource.epoch, async () => await macosBackend.readText({
		lookId: state.currentOutline!.lookId,
		elementRef: wireRefForNode(node),
		offset: Math.max(0, Math.trunc(toFiniteNumber(params.offset, 0))),
		limit: Math.max(1, Math.min(100_000, Math.trunc(toFiniteNumber(params.limit, 4_000)))),
	}, { signal, timeoutMs: COMMAND_TIMEOUT_MS }))).value;
	return {
		stateId: state.currentCapture!.stateId,
		ref,
		offset: raw.offset,
		limit: raw.limit,
		total: raw.totalChars,
		text: raw.text,
	};
}

/** Successor view of a state transition: a diff when identity holds, the full view otherwise. */
export function successorView(base: ProjectedNode[], next: Outline): { changes?: Change[]; nodes?: ProjectedNode[]; shown?: number; total?: number } {
	const transition = changesBetween(base, project(next, UNFOLDED).nodes);
	if (!transition.useFullView) return { changes: transition.changes };
	const folded = project(next);
	return { nodes: folded.nodes, shown: folded.shown, total: folded.total };
}

async function performWaitFor(params: WaitForParams, signal?: AbortSignal): Promise<WaitForResult> {
	const text = trimOrUndefined(params.text);
	const role = trimOrUndefined(params.role);
	const timeoutMs = normalizeWaitTimeoutMs(params.timeoutMs);
	if (!text && !role) throw new BcuError("invalid_arguments", "wait-for requires --text or --role.");

	const state = operationState();
	validateStateId(params.stateId);
	const baseNodes = project(state.currentOutline!, UNFOLDED).nodes;
	const scopeRef = scopeWireRef(params.scope);
	const target = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
	const raw = await macosBackend.waitFor({
		...nativeWindowRequest(target),
		text,
		role,
		scopeRef,
		gone: params.gone === true,
		timeoutMs,
	}, { signal, timeoutMs: timeoutMs + 2_000 });
	if (!raw.found) {
		throw new BcuError(
			"action_timeout",
			`The condition ${params.gone === true ? "still held" : "did not appear"} within ${timeoutMs}ms${params.scope ? ` inside ${params.scope}` : ""}.`,
		);
	}
	const resource = currentResourceOrThrow();
	const refreshed = (await resourceScheduler.readAt(resource.resourceKey, resource.epoch, async () => await captureCurrentTarget(signal))).value;
	return {
		stateId: refreshed.capture.stateId,
		found: true,
		gone: raw.gone || undefined,
		...successorView(baseNodes, refreshed.outline),
	};
}

export const executeObserve = makeToolExecutor(performObserve);
export const executeSearchUi = makeToolExecutor(performSearchUi);
export const executeExpandUi = makeToolExecutor(performExpandUi);
export const executeInspectUi = makeToolExecutor(performInspectUi);
export const executeReadText = makeToolExecutor(performReadText);
export const executeWaitFor = makeToolExecutor(performWaitFor);
