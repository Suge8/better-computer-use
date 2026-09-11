import { randomUUID } from "node:crypto";
import { getComputerUseConfig, isHeadlessMode, type ComputerUseConfig } from "./config.ts";
import type { ExpandUiParams, ImageMode, InspectUiParams, ObserveParams, ReadTextParams, SearchUiParams, ToolResult, WaitForParams } from "./contract.ts";
import { macosBackend } from "./macos/backend.ts";
import { toFiniteNumber, type ActOutcome, type FramePoints, type HelperActPerformed, type HelperActResult, type HelperDiagnostics, type NativeInputDelivery } from "./macos/protocol.ts";
import { noteFromLook, noteRegionKeyForRef, renderNote, type WindowNote } from "./note.ts";
import { foldToBudget, graftScopedOutline, nodeByRef, outlineNodeLabel, outlineNodePath, searchOutline, serializeOutline, serializeOutlineNode, type LookResponse, type Outline, type OutlineChange, type OutlineNode, type OutlineSearchMatch, type SerializedOutline, type SerializedOutlineNode } from "./outline.ts";
import { rootRefForDelta } from "./root-refs.ts";
import { ensureTargetWindowId, nativeWindowRequest, matchesTargetSelection, normalizeWindowSelector, resolveCurrentTarget, resolveTargetByWindowSelector, resolveTargetForObserve, sameRootIdentity, setCurrentTarget, type ResolvedTarget } from "./roots.ts";
import { COMMAND_TIMEOUT_MS, currentOutlineOrThrow, currentResourceOrThrow, desktopResourceKey, helperDiagnostics, makeToolExecutor, operationState, persistOperation, resourceScheduler, validateStateId } from "./session.ts";
import type { CurrentCapture, CurrentTarget } from "./state.ts";
import { normalizeText, trimOrUndefined } from "./text.ts";
import { changesBetween, renderChanges, stabilizeRefs } from "./view.ts";

const LOOK_TIMEOUT_MS = 33_000;
export const AUTO_IMAGE_MAX_DIMENSION = 900;
export const EXPLICIT_IMAGE_MAX_DIMENSION = 1_600;

type ExecutionVariant = "stealth" | "default";
type ActionDelivery = "ax" | NativeInputDelivery;
type DeliveryPolicy = "ax_only" | "background" | "default" | "foreground";

export interface ExecutionTrace {
	strategy: "look" | "act" | "wait";
	runtimeMode?: ExecutionVariant;
	variant?: ExecutionVariant;
	stealthCompatible?: boolean;
	delivery?: ActionDelivery;
	deliveryPolicy?: DeliveryPolicy;
	outcome?: ActOutcome;
	performed?: HelperActPerformed;
	evidence?: Record<string, unknown>;
	error?: HelperActResult["error"];
	rootDelta?: HelperActResult["rootDelta"];
	steps?: ExecutionTrace[];
	actionCount?: number;
	stoppedAt?: number;
	backgroundFirst?: boolean;
	escalatedToForeground?: boolean;
	escalationReason?: string;
	backgroundAttempt?: { outcome: "foreground_required" | "didnt"; reason: string };
	verification?: {
		status: "verified" | "preexisting" | "failed";
		text?: string;
		role?: string;
		value?: string;
		gone?: boolean;
		timeoutMs: number;
	};
}

interface ActivationFlags {
	activated: boolean;
	unminimized: boolean;
	raised: boolean;
}

export interface ComputerUseDetails {
	tool: string;
	target: {
		app: string;
		bundleId?: string;
		pid: number;
		windowTitle: string;
		windowId: number;
		windowRef?: string;
		nativeWindowRef?: string;
	};
	capture: {
		stateId: string;
		width: number;
		height: number;
		scaleFactor: number;
		timestamp: number;
		coordinateSpace: "window-relative-screenshot-pixels";
	};
	lookId?: string;
	view: "full" | "diff";
	baseStateId?: string;
	changes?: OutlineChange[];
	viewReason?: "root_replaced" | "change_budget_exceeded" | "identity_confidence_low";
	renderedOutline?: string;
	outline?: SerializedOutline;
	note?: WindowNote;
	activation: ActivationFlags;
	execution: ExecutionTrace;
	config?: ComputerUseConfig;
	helper?: HelperDiagnostics;
	status?: "ok";
	imageReason?: "fallback_recovery" | "sparse_ax_targets" | "unlabeled_ax_targets";
}

interface ReadTextDetails {
	tool: "read_text";
	ref: string;
	offset: number;
	limit: number;
	totalChars: number;
	hasMore: boolean;
	text: string;
}

interface WaitForDetails {
	tool: "wait_for";
	stateId: string;
	baseStateId?: string;
	view: "full" | "diff";
	changes?: OutlineChange[];
	found: boolean;
	gone?: boolean;
	timedOut?: boolean;
	target?: Omit<OutlineSearchMatch, "node"> & { node?: SerializedOutlineNode };
	nodeCount?: number;
	text?: string;
	role?: string;
	outline: SerializedOutline;
	renderedOutline: string;
}

interface OutlineToolDetails {
	tool: "search_ui" | "expand_ui" | "inspect_ui";
	stateId?: string;
	lookId?: string;
	outline?: SerializedOutline;
	renderedOutline?: string;
	matches?: Array<Omit<OutlineSearchMatch, "node"> & { node?: SerializedOutlineNode }>;
	target?: SerializedOutlineNode;
	raw?: unknown;
	note?: WindowNote;
}

export interface CaptureResult {
	target: ResolvedTarget;
	capture: CurrentCapture;
	look: LookResponse;
	outline: Outline;
	activation: ActivationFlags;
}

export function executionTrace(
	strategy: ExecutionTrace["strategy"],
	variant: ExecutionVariant,
	metadata: Omit<ExecutionTrace, "strategy" | "runtimeMode" | "variant" | "stealthCompatible"> = {},
): ExecutionTrace {
	return {
		strategy,
		runtimeMode: isHeadlessMode() ? "stealth" : "default",
		variant,
		stealthCompatible: variant === "stealth",
		...metadata,
	};
}

export function rootDeltaLines(execution: ExecutionTrace): string[] {
	return (execution.rootDelta ?? []).map((delta) => {
		const quotedTitle = delta.title ? ` ${JSON.stringify(delta.title)}` : "";
		const ref = delta.ref ? ` (${delta.ref.startsWith("@") ? delta.ref : `@${delta.ref}`})` : "";
		const sheetCount = typeof delta.metadata?.sheetCount === "number" && Number.isFinite(delta.metadata.sheetCount) ? Math.max(0, Math.trunc(delta.metadata.sheetCount)) : undefined;
		const flags = [delta.isModal ? "modal" : undefined, sheetCount ? `sheets=${sheetCount}` : undefined].filter(Boolean).join(", ");
		const suffix = `${quotedTitle}${flags ? ` (${flags})` : ""}${ref}`;
		if (delta.change === "appeared") return `New root: ${delta.kind}${suffix}`;
		if (delta.change === "closed") return `Root closed: ${delta.kind}${suffix}`;
		return `Root focused: ${delta.kind}${suffix}`;
	});
}

export function modelRefForRootDelta(delta: NonNullable<HelperActResult["rootDelta"]>[number]): string | undefined {
	const current = operationState().currentTarget;
	return rootRefForDelta(delta, current ? { pid: current.pid, appName: current.appName, bundleId: current.bundleId } : undefined);
}

export function normalizeImageMode(value: unknown): ImageMode {
	return value === "always" || value === "never" ? value : "auto";
}

export function normalizeWaitTimeoutMs(value: unknown): number {
	return Math.max(100, Math.min(60_000, Math.trunc(toFiniteNumber(value, 10_000))));
}

export function outlineNodeByRef(ref: string): OutlineNode {
	const state = operationState();
	const outline = state.currentOutline;
	const node = outline ? nodeByRef(outline, ref) : undefined;
	if (!node) {
		const windowHint = state.currentTarget?.windowRef ? ` --root ${state.currentTarget.windowRef}` : "";
		throw new Error(`Outline ref '${ref}' is stale or not available for the latest state. Call observe-ui${windowHint} again and choose a current @e ref.`);
	}
	return node;
}

export function wireRefForNode(node: OutlineNode): string {
	if (node.pictureOnly || !node.wireRef) {
		throw new Error(`Outline ref '${node.ref}' is pictureOnly and has no semantic element. It can be clicked by coordinates, but semantic-only actions are not available.`);
	}
	return node.wireRef;
}

export function outlineNodeCenter(node: OutlineNode): { x: number; y: number } {
	if (!node.rect) {
		throw new Error(`Outline ref '${node.ref}' has no full-look coordinates after scoped expansion. Re-observe for coordinates.`);
	}
	return { x: node.rect.x + node.rect.w / 2, y: node.rect.y + node.rect.h / 2 };
}

export function ensurePointIsInLookImage(x: number, y: number, look: LookResponse, errorPrefix = "Coordinates"): void {
	if (!look.image) {
		throw new Error(`${errorPrefix} require an image-bearing root. This look is outline-only; use an @e ref with a semantic action or observe an image-bearing root.`);
	}
	if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`${errorPrefix} must be finite numbers.`);
	if (x < 0 || y < 0 || x >= look.image.width || y >= look.image.height) {
		throw new Error(`${errorPrefix} (${Math.round(x)},${Math.round(y)}) are outside the latest look image bounds (${look.image.width}x${look.image.height}). Call observe-ui again and retry.`);
	}
}

function formatOutlineNodeLabel(node: OutlineNode): string {
	const label = outlineNodeLabel(node) || "(unlabeled)";
	const identifier = node.identifier ? ` id=${JSON.stringify(node.identifier)}` : "";
	const capabilities = [
		node.canSetValue ? "setValue" : undefined,
		node.canPress ? "press" : undefined,
		node.canFocus ? "focus" : undefined,
		node.canScroll ? "scroll" : undefined,
		node.canIncrement || node.canDecrement ? "adjust" : undefined,
		node.pictureOnly ? "pictureOnly" : undefined,
	].filter((item): item is string => Boolean(item));
	return `${node.ref} ${node.role}${node.subrole ? `/${node.subrole}` : ""}${identifier} ${JSON.stringify(label)}${capabilities.length ? ` [${capabilities.join(",")}]` : ""}`;
}

function imageFallbackReason(
	result: CaptureResult,
	imageMode: ImageMode,
): { reason: NonNullable<ComputerUseDetails["imageReason"]>; message: string } | undefined {
	if (imageMode === "never") return undefined;
	if (imageMode === "always") return { reason: "fallback_recovery", message: "An image was requested explicitly for visual verification." };
	const outline = result.outline;
	const labeled = outline.nodes.filter((node) => outlineNodeLabel(node)).length;
	if (outline.nodes.length < 3) {
		return { reason: "sparse_ax_targets", message: "Only a few outline nodes were found, so the look image is attached for context." };
	}
	if (labeled * 3 < outline.nodes.length) {
		return { reason: "unlabeled_ax_targets", message: "Most outline nodes are unlabeled, so the look image is attached for context." };
	}
	return undefined;
}

function captureForLook(look: LookResponse): CurrentCapture {
	return {
		stateId: randomUUID(),
		width: look.image?.width ?? 0,
		height: look.image?.height ?? 0,
		scaleFactor: look.window.scaleFactor,
		timestamp: Date.now(),
	};
}

async function performLook(
	target: ResolvedTarget,
	options: { readText: "auto" | "always" | "never"; baseLookId?: string; scopeRef?: string; maxDimension?: number; includeImage?: boolean },
	signal?: AbortSignal,
): Promise<LookResponse> {
	if (!target.nativeWindowRef) {
		throw new Error(`bcu requires a helper root reference to observe '${target.windowTitle}'. Call find-roots and select a current root.`);
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

export function noteWindowForTarget(target: ResolvedTarget | CurrentTarget, look?: LookResponse) {
	const pairing = look?.window.metadata?.pairing;
	const record = pairing && typeof pairing === "object" ? pairing as { confidence?: "exact" | "high" | "low"; score?: number } : undefined;
	return {
		windowRef: target.windowRef,
		title: target.windowTitle,
		pairing: record?.confidence,
		pairingScore: record?.score,
	};
}

/** Side effects: adopts the fresh look as the operation's current target, capture, look, outline and note. */
export async function captureCurrentTarget(
	signal?: AbortSignal,
	readText: "auto" | "always" | "never" = "auto",
	maxDimension = AUTO_IMAGE_MAX_DIMENSION,
	targetOverride?: ResolvedTarget,
	includeImage = true,
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
	const capture = captureForLook(look);

	setCurrentTarget(target);
	state.currentCapture = capture;
	state.currentStateTarget = { pid: target.pid, windowId: target.windowId, windowRef: target.windowRef };
	state.currentLook = look;
	state.currentOutline = outline;
	state.currentNote = noteFromLook(state.currentNote, outline, noteWindowForTarget(target, look));
	state.resourceKey = desktopResourceKey(target);
	state.epoch ??= resourceScheduler.epoch(state.resourceKey);

	return { target, capture, look, outline, activation: { activated: false, unminimized: false, raised: false } };
}

export function buildToolResult(
	tool: string,
	summary: string,
	result: CaptureResult,
	execution: ExecutionTrace,
	imageMode: ImageMode = operationState().currentImageMode ?? "auto",
	base?: { stateId: string; outline: Outline },
): ToolResult<ComputerUseDetails> {
	const state = operationState();
	const fallbackReason = imageFallbackReason(result, imageMode);
	const transition = base ? changesBetween(base.outline, result.outline) : undefined;
	const useDiff = Boolean(transition && !transition.useFullView);
	const folded = foldToBudget(result.outline);
	const renderedNote = renderNote(state.currentNote);

	const details: ComputerUseDetails = {
		tool,
		target: {
			app: result.target.appName,
			bundleId: result.target.bundleId,
			pid: result.target.pid,
			windowTitle: result.target.windowTitle,
			windowId: result.target.windowId,
			windowRef: result.target.windowRef ?? state.currentTarget?.windowRef,
			nativeWindowRef: result.target.nativeWindowRef ?? state.currentTarget?.nativeWindowRef,
		},
		capture: {
			stateId: result.capture.stateId,
			width: result.capture.width,
			height: result.capture.height,
			scaleFactor: result.capture.scaleFactor,
			timestamp: result.capture.timestamp,
			coordinateSpace: "window-relative-screenshot-pixels",
		},
		lookId: result.look.lookId,
		view: useDiff ? "diff" : "full",
		baseStateId: transition ? base?.stateId : undefined,
		changes: useDiff ? transition?.changes : undefined,
		viewReason: transition?.useFullView ? transition.reason : undefined,
		renderedOutline: folded.text,
		outline: serializeOutline(result.outline),
		note: state.currentNote,
		activation: result.activation,
		execution,
		status: "ok",
		config: getComputerUseConfig(),
		helper: helperDiagnostics(),
		imageReason: fallbackReason?.reason,
	};

	const noteText = renderedNote ? `\n\n${renderedNote}` : "";
	// The model must echo capture.stateId into follow-up tools. Exposing only the
	// helper-internal lookId here makes a plausible but invalid stateId easy to use.
	const renderedChanges = useDiff ? renderChanges(transition!.changes) : "";
	const outlineText = useDiff
		? `\n\nChanges (${transition!.changedNodeCount}, ${base!.stateId} → ${result.capture.stateId}):\n${renderedChanges || "(no element changes)"}\nUse stateId ${result.capture.stateId} for subsequent actions and queries.`
		: `\n\nOutline (${folded.nodeCount} nodes, stateId ${result.capture.stateId}${transition?.reason ? `, full view: ${transition.reason}` : ""}${folded.truncated ? ", folded output truncated" : ""}):\n${folded.text}`;
	const fallbackText = fallbackReason ? `\n\n${fallbackReason.message}` : "";
	const deltaText = rootDeltaLines(execution).join("\n");
	const text = `${summary}${deltaText ? `\n${deltaText}` : ""}${noteText}${outlineText}${fallbackText}`;
	const image = fallbackReason && result.look.image?.jpegBase64
		? { data: result.look.image.jpegBase64, mimeType: result.look.image.mimeType ?? "image/jpeg" as const }
		: undefined;
	return { text, details, image };
}

/** Side effects: captures/updates current target, capture state, look, and parsed outline. */
async function performObserve(params: ObserveParams, signal?: AbortSignal): Promise<ToolResult<ComputerUseDetails>> {
	const state = operationState();
	const mode = params.mode ?? "fused";
	const image = params.image ?? (mode === "semantic" ? "never" : mode === "visual" ? "always" : "auto");
	const readText = params.readText ?? (mode === "semantic" ? "never" : mode === "visual" ? "always" : "auto");
	const imageMode = normalizeImageMode(image);
	state.currentImageMode = imageMode;
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
		state.resourceKey = resourceKey;
		state.epoch = epoch;
		return await captureCurrentTarget(signal, readText, imageMode === "always" ? EXPLICIT_IMAGE_MAX_DIMENSION : AUTO_IMAGE_MAX_DIMENSION, requestedTarget, imageMode !== "never");
	});
	const captureResult = scheduled.value;
	// Model @r refs are re-minted on re-resolution, so ref string equality
	// alone false-positives as drift for the same root; compare stable
	// identity against the resolved request too.
	if (!matchesTargetSelection(captureResult.target, selection) && !sameRootIdentity(captureResult.target, requestedTarget)) {
		throw new Error(
			`Observation target drifted from the requested selection. Requested ${requestedTarget.appName} — ${requestedTarget.windowTitle}, captured ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Call observe-ui again or specify a more exact window title.`,
		);
	}
	const summary = `Observed ${mode} ${captureResult.target.windowRef ? `${captureResult.target.windowRef} ` : ""}${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest outline state.`;
	return buildToolResult("observe_ui", summary, captureResult, executionTrace("look", "stealth"), imageMode);
}

function matchIsNonActionableStatic(match: OutlineSearchMatch): boolean {
	const node = match.node;
	return !node.canPress && !node.canFocus && !node.canSetValue && node.actions.length === 0 && !node.pictureOnly;
}

/** Pure cached-outline query, except for a one-time OCR escalation when the cache has no usable match. */
async function performSearchUi(params: SearchUiParams, signal?: AbortSignal): Promise<ToolResult<OutlineToolDetails>> {
	const state = operationState();
	let outline = currentOutlineOrThrow(params.stateId);
	const text = trimOrUndefined(params.text);
	const role = trimOrUndefined(params.role);
	const action = trimOrUndefined(params.action);
	const limit = Math.max(1, Math.min(50, Math.trunc(toFiniteNumber(params.limit, 12))));
	let matches = searchOutline(outline, text, role, action, limit);
	let escalatedOCR = false;
	const look = state.currentLook;
	const shouldEscalate = matches.length === 0 || matches.every(matchIsNonActionableStatic);
	if (shouldEscalate && look && look.readText?.requested !== "never" && !look.readText?.executed && state.lastSearchOcrEscalatedLookId !== look.lookId) {
		state.lastSearchOcrEscalatedLookId = look.lookId;
		const currentTarget = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
		// captureCurrentTarget adopts the new look/outline/capture into the
		// operation state, so refs in these matches stay actable. Keep the image
		// payload: OCR-only matches are clicked by coordinate, and coordinate
		// acts require the current look to be image-bearing.
		const resource = currentResourceOrThrow();
		const captureResult = (await resourceScheduler.readAt(resource.resourceKey, resource.epoch, async () => await captureCurrentTarget(signal, "always", AUTO_IMAGE_MAX_DIMENSION, currentTarget))).value;
		outline = captureResult.outline;
		matches = searchOutline(outline, text, role, action, limit);
		escalatedOCR = true;
	}
	const detailMatches = matches.map((match) => ({ ...match, node: serializeOutlineNode(match.node) }));
	const details: OutlineToolDetails = { tool: "search_ui", stateId: state.currentCapture?.stateId, lookId: outline.lookId, outline: serializeOutline(outline), matches: detailMatches, note: state.currentNote };
	const lines = matches.map((match) => `${match.ref} ${match.role || "Unknown"} ${JSON.stringify(match.label || "(unlabeled)")}\n  path: ${match.path}`);
	const noteHeader = renderNote(state.currentNote);
	const noteText = noteHeader ? `${noteHeader}\n\n` : "";
	const escalationText = escalatedOCR ? " OCR text was escalated for this search after the cached outline had no matches." : "";
	return { text: `${noteText}Found ${matches.length} outline match${matches.length === 1 ? "" : "es"}.${escalationText}\n${lines.join("\n")}`, details };
}

/** Reads the cached outline; truncated or changed refs trigger a scoped look. */
async function performExpandUi(params: ExpandUiParams, signal?: AbortSignal): Promise<ToolResult<OutlineToolDetails>> {
	const state = operationState();
	const outline = currentOutlineOrThrow(params.stateId);
	const ref = trimOrUndefined(params.ref);
	if (!ref) throw new Error("expand-ui --ref is required.");
	const initialTarget = nodeByRef(outline, ref);
	if (!initialTarget) throw new Error(`Outline ref '${ref}' is not available in the current outline.`);
	let target: OutlineNode = initialTarget;
	const depth = Math.max(1, Math.min(8, Math.trunc(toFiniteNumber(params.depth, 3))));
	const regionKey = noteRegionKeyForRef(outline, ref);
	const regionChanged = Boolean(regionKey && state.currentNote?.regions.some((region) => region.key === regionKey && region.status === "changed"));
	if (target.truncated || regionChanged) {
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
	const folded = foldToBudget(outline, { maxDepth: depth, maxNodes: 150 }, [target.ref]);
	const details: OutlineToolDetails = { tool: "expand_ui", stateId: state.currentCapture?.stateId, lookId: outline.lookId, outline: serializeOutline(outline), target: serializeOutlineNode(target), renderedOutline: folded.text, note: state.currentNote };
	return { text: `${formatOutlineNodeLabel(target)}\npath: ${outlineNodePath(target)}\n\n${folded.text}`, details };
}

/** Pure cached-outline inspection. */
async function performInspectUi(params: InspectUiParams): Promise<ToolResult<OutlineToolDetails>> {
	const state = operationState();
	const outline = currentOutlineOrThrow(params.stateId);
	const ref = trimOrUndefined(params.ref);
	if (!ref) throw new Error("inspect-ui --ref is required.");
	const target = nodeByRef(outline, ref);
	if (!target) throw new Error(`Outline ref '${ref}' is not available in the current outline.`);
	const details: OutlineToolDetails = { tool: "inspect_ui", stateId: state.currentCapture?.stateId, lookId: outline.lookId, outline: serializeOutline(outline), target: serializeOutlineNode(target), raw: params.includeRaw ? serializeOutlineNode(target) : undefined, note: state.currentNote };
	const fields = [
		formatOutlineNodeLabel(target),
		`path: ${outlineNodePath(target)}`,
		`rect: ${JSON.stringify(target.rect)}`,
		`actions: ${target.actions.join(",") || "none"}`,
		`capabilities: ${[
			target.canPress ? "press" : undefined,
			target.canFocus ? "focus" : undefined,
			target.canSetValue ? "setValue" : undefined,
			target.canScroll ? "scroll" : undefined,
			target.canIncrement ? "increment" : undefined,
			target.canDecrement ? "decrement" : undefined,
			target.isTextInput ? "textInput" : undefined,
		].filter(Boolean).join(",") || "none"}`,
		`annotations: ${[
			target.offscreen ? "offscreen" : undefined,
			target.pictureOnly ? "pictureOnly" : undefined,
			target.truncated ? "truncated" : undefined,
			target.scrollExtent ? `scrollable ${target.scrollExtent.seen}/${target.scrollExtent.total}` : undefined,
		].filter(Boolean).join(",") || "none"}`,
	];
	return { text: fields.join("\n"), details };
}

async function performReadText(params: ReadTextParams, signal?: AbortSignal): Promise<ToolResult<ReadTextDetails>> {
	validateStateId(params.stateId);
	const ref = trimOrUndefined(params.ref);
	if (!ref) throw new Error("read-text requires --ref. Call observe-ui or inspect-ui and use a text-bearing outline ref.");
	const node = outlineNodeByRef(ref);
	const state = operationState();
	const resource = currentResourceOrThrow();
	const raw = (await resourceScheduler.readAt(resource.resourceKey, resource.epoch, async () => await macosBackend.readText({
		lookId: state.currentOutline!.lookId,
		elementRef: wireRefForNode(node),
		offset: Math.max(0, Math.trunc(toFiniteNumber(params.offset, 0))),
		limit: Math.max(1, Math.min(100_000, Math.trunc(toFiniteNumber(params.limit, 4_000)))),
	}, { signal, timeoutMs: COMMAND_TIMEOUT_MS }))).value;
	const details: ReadTextDetails = {
		tool: "read_text",
		ref,
		offset: raw.offset,
		limit: raw.limit,
		totalChars: raw.totalChars,
		hasMore: raw.hasMore,
		text: raw.text,
	};
	return { text: raw.text || "(empty text slice)", details };
}

async function performWaitFor(params: WaitForParams, signal?: AbortSignal): Promise<ToolResult<WaitForDetails>> {
	const text = trimOrUndefined(params.text);
	const role = trimOrUndefined(params.role);
	const timeoutMs = normalizeWaitTimeoutMs(params.timeoutMs);
	if (!text && !role) throw new Error("wait-for requires text or role.");

	const state = operationState();
	const baseView = { stateId: validateStateId(params.stateId).stateId, outline: state.currentOutline! };
	const target = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
	const raw = await macosBackend.waitFor({
		...nativeWindowRequest(target),
		text,
		role,
		gone: params.gone === true,
		timeoutMs,
	}, { signal, timeoutMs: timeoutMs + 2_000 });
	const resource = currentResourceOrThrow();
	const refreshed = (await resourceScheduler.readAt(resource.resourceKey, resource.epoch, async () => await captureCurrentTarget(signal, "auto"))).value;
	const transition = changesBetween(baseView.outline, refreshed.outline);
	const useDiff = !transition.useFullView;
	const foundTarget = searchOutline(refreshed.outline, text, role, undefined, 1)[0];
	const details: WaitForDetails = {
		tool: "wait_for",
		stateId: refreshed.capture.stateId,
		baseStateId: baseView.stateId,
		view: useDiff ? "diff" : "full",
		changes: useDiff ? transition.changes : undefined,
		found: raw.found,
		gone: raw.gone || undefined,
		timedOut: raw.timedOut || undefined,
		target: foundTarget ? { ...foundTarget, node: serializeOutlineNode(foundTarget.node) } : undefined,
		nodeCount: Number.isFinite(raw.nodeCount) ? Number(raw.nodeCount) : refreshed.outline.nodes.length,
		text,
		role,
		outline: serializeOutline(refreshed.outline),
		renderedOutline: foldToBudget(refreshed.outline).text,
	};
	const message = details.found ? (details.gone ? "Condition disappeared." : "Condition appeared.") : `Timed out after ${timeoutMs}ms waiting for condition.`;
	const viewText = useDiff ? `${renderChanges(transition.changes) || "(no element changes)"}\nUse stateId ${refreshed.capture.stateId} for subsequent actions and queries.` : details.renderedOutline;
	return { text: `${message}\n${viewText}`, details };
}

export const executeObserve = makeToolExecutor(performObserve);
export const executeSearchUi = makeToolExecutor(performSearchUi);
export const executeExpandUi = makeToolExecutor(performExpandUi);
export const executeInspectUi = makeToolExecutor(performInspectUi);
export const executeReadText = makeToolExecutor(performReadText);
export const executeWaitFor = makeToolExecutor(performWaitFor);
