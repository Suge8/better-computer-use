import type { FindParams, RootSelector, ToolResult } from "./contract.ts";
import { macosBackend } from "./macos/backend.ts";
import type { FramePoints, FrontmostResult, HelperApp, HelperRoot, HelperTarget } from "./macos/protocol.ts";
import { rootRefRecord, storeRootRef } from "./root-refs.ts";
import { scoreWindow, shouldPreferForegroundModalWindow } from "./root-selection.ts";
import { CURRENT_TARGET_GONE_ERROR, currentTargetOrThrow, makeToolExecutor, operationState } from "./session.ts";
import type { CurrentTarget } from "./state.ts";
import { normalizeText, trimOrUndefined } from "./text.ts";

export interface ResolvedTarget extends CurrentTarget {
	framePoints: FramePoints;
	scaleFactor: number;
	isMinimized: boolean;
	isOnscreen: boolean;
	isMain: boolean;
	isFocused: boolean;
}

interface RootDetail {
	app: string;
	bundleId?: string;
	pid: number;
	kind: string;
	windowTitle: string;
	windowId?: number;
	windowRef: string;
	nativeWindowRef?: string;
	framePoints: FramePoints;
	scaleFactor: number;
	isMinimized: boolean;
	isOnscreen: boolean;
	isMain: boolean;
	isFocused: boolean;
	isModal: boolean;
	sheetCount?: number;
	role?: string;
	subrole?: string;
	pairing?: { confidence: "exact" | "high" | "low"; score: number };
	zOrder: number;
	score: number;
}

interface FindRootsDetails {
	tool: "find_roots";
	query: FindParams;
	windows: RootDetail[];
}

/** Score gap that makes one candidate an unambiguous winner. */
const DECISIVE_SCORE_GAP = 25;

export async function listApps(signal?: AbortSignal): Promise<HelperApp[]> {
	return await macosBackend.listApps(signal);
}

export async function listWindows(pid: number, signal?: AbortSignal): Promise<HelperRoot[]> {
	return await macosBackend.listRoots({ pid }, signal);
}

async function listWindowsByTitle(title: string, signal?: AbortSignal): Promise<HelperRoot[]> {
	return await macosBackend.listRoots({ title }, signal);
}

export function nativeWindowRequest(target: Pick<CurrentTarget, "pid" | "windowId" | "nativeWindowRef">): HelperTarget {
	return { pid: target.pid, windowId: target.windowId, windowRef: target.nativeWindowRef };
}

export function sameRootIdentity(a: CurrentTarget, b: CurrentTarget): boolean {
	if (a.pid !== b.pid) return false;
	if (a.windowId > 0 && b.windowId > 0) return a.windowId === b.windowId;
	if (a.nativeWindowRef && b.nativeWindowRef) return a.nativeWindowRef === b.nativeWindowRef;
	return normalizeText(a.windowTitle) === normalizeText(b.windowTitle);
}

function appNames(app: Pick<HelperApp, "appName" | "bundleId">): string[] {
	const bundleId = normalizeText(app.bundleId);
	return [normalizeText(app.appName), bundleId, bundleId.split(".").at(-1) ?? ""].filter(Boolean);
}

function appMatchesName(app: Pick<HelperApp, "appName" | "bundleId">, query: string, exact = false): boolean {
	const normalizedQuery = normalizeText(query);
	return appNames(app).some((name) => exact ? name === normalizedQuery : name.includes(normalizedQuery));
}

function appMatchesWindowQuery(app: HelperApp, query: FindParams): boolean {
	const appQuery = trimOrUndefined(query.app);
	const bundleQuery = trimOrUndefined(query.bundleId);
	const pidQuery = Number.isFinite(query.pid) ? Math.trunc(query.pid!) : undefined;

	if (pidQuery !== undefined && app.pid !== pidQuery) return false;
	if (bundleQuery && normalizeText(app.bundleId ?? "") !== normalizeText(bundleQuery)) return false;
	if (appQuery && !appMatchesName(app, appQuery)) return false;
	return true;
}

function rootSheetCount(root: Pick<HelperRoot, "metadata">): number | undefined {
	const value = root.metadata?.sheetCount;
	return typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : undefined;
}

function rootPairing(root: Pick<HelperRoot, "metadata">): { confidence: "exact" | "high" | "low"; score: number } | undefined {
	const value = root.metadata?.pairing;
	if (!value || typeof value !== "object") return undefined;
	const pairing = value as { confidence?: unknown; score?: unknown };
	if (pairing.confidence !== "exact" && pairing.confidence !== "high" && pairing.confidence !== "low") return undefined;
	return { confidence: pairing.confidence, score: typeof pairing.score === "number" && Number.isFinite(pairing.score) ? pairing.score : Number.NEGATIVE_INFINITY };
}

function formatRootLine(window: RootDetail): string {
	const flags = [
		window.isFocused ? "focused" : undefined,
		window.isMain ? "main" : undefined,
		window.isModal ? "modal" : undefined,
		window.sheetCount ? `sheets=${window.sheetCount}` : undefined,
		window.isOnscreen ? "onscreen" : undefined,
		window.isMinimized ? "minimized" : undefined,
	]
		.filter(Boolean)
		.join(", ");
	const frame = `${Math.round(window.framePoints.x)},${Math.round(window.framePoints.y)} ${Math.round(window.framePoints.w)}x${Math.round(window.framePoints.h)}`;
	const id = window.windowId ? `windowId ${window.windowId}` : window.nativeWindowRef ? `nativeRootRef ${window.nativeWindowRef}` : "unstable root id";
	const pairing = window.pairing ? `, pairing ${window.pairing.confidence}/${Math.round(window.pairing.score)}` : "";
	return `- ${window.windowRef} ${window.kind} ${window.app} pid ${window.pid} — ${window.windowTitle || "(untitled)"} (z ${window.zOrder}, ${id}, frame ${frame}${pairing}${flags ? `, ${flags}` : ""})`;
}

function storeRootRefForAppWindow(app: HelperApp, window: HelperRoot) {
	return storeRootRef({
		appName: app.appName,
		bundleId: app.bundleId,
		pid: app.pid,
		windowTitle: window.title || "(untitled)",
		windowId: window.windowId,
		nativeWindowRef: window.windowRef,
		framePoints: window.framePoints,
		scaleFactor: window.scaleFactor,
		isMinimized: window.isMinimized,
		isOnscreen: window.isOnscreen,
		isMain: window.isMain,
		isFocused: window.isFocused,
	});
}

function toResolvedTarget(app: HelperApp, window: HelperRoot): ResolvedTarget {
	return {
		appName: app.appName,
		bundleId: app.bundleId,
		pid: app.pid,
		windowTitle: window.title || "(untitled)",
		windowId: typeof window.windowId === "number" ? window.windowId : 0,
		nativeWindowRef: window.windowRef,
		framePoints: window.framePoints,
		scaleFactor: window.scaleFactor,
		isMinimized: window.isMinimized,
		isOnscreen: window.isOnscreen,
		isMain: window.isMain,
		isFocused: window.isFocused,
		windowRef: storeRootRefForAppWindow(app, window).ref,
	};
}

export function setCurrentTarget(target: ResolvedTarget): void {
	const windowRef = target.windowRef ?? storeRootRef({
		appName: target.appName,
		bundleId: target.bundleId,
		pid: target.pid,
		windowTitle: target.windowTitle,
		windowId: target.windowId > 0 ? target.windowId : undefined,
		framePoints: target.framePoints,
		scaleFactor: target.scaleFactor,
		isMinimized: target.isMinimized,
		isOnscreen: target.isOnscreen,
		isMain: target.isMain,
		isFocused: target.isFocused,
	}).ref;
	operationState().currentTarget = {
		appName: target.appName,
		bundleId: target.bundleId,
		pid: target.pid,
		windowTitle: target.windowTitle,
		windowId: target.windowId,
		windowRef,
		nativeWindowRef: target.nativeWindowRef,
	};
}

function choosePreferredWindow(windows: HelperRoot[], appName: string): HelperRoot {
	if (!windows.length) throw new Error(`No controllable root was found in app '${appName}'.`);
	return [...windows].sort((a, b) => scoreWindow(b) - scoreWindow(a))[0];
}

function summarizeWindowCandidate(window: HelperRoot): string {
	const flags = [
		window.isFocused ? "focused" : undefined,
		window.isMain ? "main" : undefined,
		window.isOnscreen ? "onscreen" : undefined,
		window.isMinimized ? "minimized" : undefined,
	]
		.filter(Boolean)
		.join(",");
	return `${window.title || "(untitled)"} [score=${scoreWindow(window)}${flags ? `, ${flags}` : ""}]`;
}

function summarizeWindowCandidates(windows: HelperRoot[], limit = 6): string {
	return [...windows]
		.sort((a, b) => scoreWindow(b) - scoreWindow(a))
		.slice(0, limit)
		.map(summarizeWindowCandidate)
		.join("; ");
}

function chooseRankedWindowOrUndefined(windows: HelperRoot[]): HelperRoot | undefined {
	if (windows.length === 0) return undefined;
	const ranked = [...windows].sort((a, b) => scoreWindow(b) - scoreWindow(a));
	if (ranked.length === 1) return ranked[0];
	return scoreWindow(ranked[0]) >= scoreWindow(ranked[1]) + DECISIVE_SCORE_GAP ? ranked[0] : undefined;
}

function chooseAppByQuery(apps: HelperApp[], appQuery: string): HelperApp {
	const exactMatches = apps.filter((app) => appMatchesName(app, appQuery, true));
	if (exactMatches.length === 1) return exactMatches[0];
	if (exactMatches.length > 1) return exactMatches.find((app) => app.isFrontmost) ?? exactMatches[0];

	const partialMatches = apps.filter((app) => appMatchesName(app, appQuery));
	if (partialMatches.length === 0) {
		const running = apps.slice(0, 12).map((app) => app.appName).join(", ");
		throw new Error(`App '${appQuery}' is not running. Running apps: ${running || "none"}.`);
	}
	if (partialMatches.length === 1) return partialMatches[0];

	const candidates = partialMatches.map((app) => app.appName).join(", ");
	throw new Error(`App name '${appQuery}' is ambiguous (${candidates}). Use a more specific app name.`);
}

function chooseWindowByTitle(windows: HelperRoot[], windowTitle: string, appName: string): HelperRoot {
	const query = normalizeText(windowTitle);
	const exactMatches = windows.filter((window) => normalizeText(window.title) === query);
	if (exactMatches.length === 1) return exactMatches[0];
	if (exactMatches.length > 1) {
		const clearWinner = chooseRankedWindowOrUndefined(exactMatches);
		if (clearWinner) return clearWinner;
		throw new Error(
			`Window title '${windowTitle}' is ambiguous in app '${appName}'. Candidates: ${summarizeWindowCandidates(exactMatches)}.`,
		);
	}

	const partialMatches = windows.filter((window) => normalizeText(window.title).includes(query));
	if (partialMatches.length === 0) {
		throw new Error(
			`Window '${windowTitle}' was not found in app '${appName}'. Available windows: ${summarizeWindowCandidates(windows)}.`,
		);
	}
	if (partialMatches.length === 1) return partialMatches[0];
	const clearWinner = chooseRankedWindowOrUndefined(partialMatches);
	if (clearWinner) return clearWinner;

	throw new Error(
		`Window title '${windowTitle}' is ambiguous in app '${appName}'. Candidates: ${summarizeWindowCandidates(partialMatches)}.`,
	);
}

export function normalizeWindowSelector(selector: RootSelector | undefined): string | undefined {
	if (typeof selector === "number" && Number.isFinite(selector)) return String(Math.trunc(selector));
	if (typeof selector === "string") return trimOrUndefined(selector);
	return undefined;
}

export async function resolveTargetByWindowSelector(selector: RootSelector, signal?: AbortSignal): Promise<ResolvedTarget> {
	const normalized = normalizeWindowSelector(selector);
	if (!normalized) throw new Error("root target must be a non-empty @r ref or numeric windowId.");

	const current = operationState().currentTarget;
	if (current?.windowRef === normalized) return await resolveCurrentTarget(signal);

	const fromRef = rootRefRecord(normalized);
	if (fromRef) {
		const app: HelperApp = { appName: fromRef.appName, bundleId: fromRef.bundleId, pid: fromRef.pid };
		const windows = await listWindows(fromRef.pid, signal);
		const match =
			(fromRef.windowId ? windows.find((window) => window.windowId === fromRef.windowId) : undefined) ??
			(fromRef.nativeWindowRef ? windows.find((window) => window.windowRef === fromRef.nativeWindowRef) : undefined) ??
			windows.find((window) => normalizeText(window.title || "(untitled)") === normalizeText(fromRef.windowTitle));
		if (!match) throw new Error(`Root ref '${normalized}' is stale. Call find-roots again and choose a current window.`);
		const resolved = toResolvedTarget(app, match);
		setCurrentTarget(resolved);
		return resolved;
	}

	const numericWindowId = Number(normalized);
	if (Number.isInteger(numericWindowId) && numericWindowId > 0) {
		for (const app of await listApps(signal)) {
			const match = (await listWindows(app.pid, signal)).find((window) => window.windowId === numericWindowId);
			if (match) {
				const resolved = toResolvedTarget(app, match);
				setCurrentTarget(resolved);
				return resolved;
			}
		}
		throw new Error(`Window id '${numericWindowId}' was not found. Call find-roots again and choose a current window.`);
	}

	if (normalized.startsWith("@r")) {
		throw new Error(`Root ref '${normalized}' is not available in this session. Call find-roots first.`);
	}

	const candidates = await collectWindowDetails(await listApps(signal), signal);
	const query = normalizeText(normalized);
	const exact = candidates.filter((candidate) => normalizeText(candidate.app) === query || normalizeText(candidate.windowTitle) === query);
	const fuzzy = exact.length > 0 ? exact : candidates.filter((candidate) => `${normalizeText(candidate.app)} ${normalizeText(candidate.windowTitle)}`.includes(query));
	const match = fuzzy.sort((a, b) => Number(b.isFocused) - Number(a.isFocused) || a.zOrder - b.zOrder)[0];
	if (!match) throw new Error(`Root query '${normalized}' did not match any current root. Call find-roots to inspect roots.`);
	const app: HelperApp = { appName: match.app, bundleId: match.bundleId, pid: match.pid };
	const roots = await listWindows(match.pid, signal);
	const helperRoot = roots.find((root) => root.rootRef === match.nativeWindowRef || root.windowRef === match.nativeWindowRef || root.windowId === match.windowId) ?? roots[0];
	const resolved = toResolvedTarget(app, helperRoot);
	setCurrentTarget(resolved);
	return resolved;
}

export async function resolveCurrentTarget(signal?: AbortSignal): Promise<ResolvedTarget> {
	const current = currentTargetOrThrow();
	const windows = await listWindows(current.pid, signal);
	if (!windows.length) throw new Error(CURRENT_TARGET_GONE_ERROR);

	const hadStableWindowId = current.windowId > 0;
	const titleQuery = normalizeText(current.windowTitle);
	let match = current.nativeWindowRef ? windows.find((window) => window.windowRef === current.nativeWindowRef || window.rootRef === current.nativeWindowRef) : undefined;
	match ??= hadStableWindowId ? windows.find((window) => window.windowId !== undefined && window.windowId === current.windowId) : undefined;
	if (!match) {
		const exactTitleMatches = titleQuery && titleQuery !== "(untitled)" ? windows.filter((window) => normalizeText(window.title) === titleQuery) : [];
		if (exactTitleMatches.length === 1) {
			match = exactTitleMatches[0];
		} else if (exactTitleMatches.length > 1) {
			match = chooseRankedWindowOrUndefined(exactTitleMatches);
			if (!match) {
				throw new Error(
					`${CURRENT_TARGET_GONE_ERROR} Multiple windows now match '${current.windowTitle}': ${summarizeWindowCandidates(exactTitleMatches)}.`,
				);
			}
		}
	}

	if (!match && !hadStableWindowId) match = chooseRankedWindowOrUndefined(windows);
	if (!match) throw new Error(CURRENT_TARGET_GONE_ERROR);

	const modal = windows
		.filter((window) => shouldPreferForegroundModalWindow(match!, window))
		.sort((a, b) => scoreWindow(b) - scoreWindow(a))[0];
	if (modal) match = modal;

	const resolved = toResolvedTarget({ appName: current.appName, bundleId: current.bundleId, pid: current.pid }, match);
	setCurrentTarget(resolved);
	return resolved;
}

async function resolveFrontmostTarget(signal?: AbortSignal): Promise<ResolvedTarget> {
	const frontmost: FrontmostResult = await macosBackend.getFrontmost(signal);
	const apps = await listApps(signal);
	const app = apps.find((candidate) => candidate.pid === frontmost.pid) ?? {
		appName: frontmost.appName,
		bundleId: frontmost.bundleId,
		pid: frontmost.pid,
	};

	const windows = await listWindows(frontmost.pid, signal);
	if (!windows.length) throw new Error("No frontmost controllable root was found. Open an app window and call observe-ui again.");

	let selected = windows.find((window) => window.windowId !== undefined && window.windowId === frontmost.windowId);
	if (!selected && frontmost.windowTitle) {
		selected = windows.find((window) => normalizeText(window.title) === normalizeText(frontmost.windowTitle));
	}
	selected ??= choosePreferredWindow(windows, app.appName);

	const resolved = toResolvedTarget(app, selected);
	setCurrentTarget(resolved);
	return resolved;
}

export interface TargetSelection {
	app?: string;
	windowTitle?: string;
	root?: string;
}

export function matchesTargetSelection(target: ResolvedTarget, selection: TargetSelection): boolean {
	const windowQuery = normalizeWindowSelector(selection.root);
	if (windowQuery) {
		if (target.windowRef === windowQuery) return true;
		const numeric = Number(windowQuery);
		return Number.isInteger(numeric) && numeric > 0 && target.windowId === numeric;
	}
	const appQuery = trimOrUndefined(selection.app);
	const windowTitleQuery = trimOrUndefined(selection.windowTitle);
	if (appQuery && !normalizeText(target.appName).includes(normalizeText(appQuery))) return false;
	if (windowTitleQuery && normalizeText(target.windowTitle) !== normalizeText(windowTitleQuery)) return false;
	return true;
}

async function resolveTargetByTitleAcrossApps(query: string, signal?: AbortSignal): Promise<ResolvedTarget> {
	const exactMatches: Array<{ app: HelperApp; window: HelperRoot }> = [];
	const partialMatches: Array<{ app: HelperApp; window: HelperRoot }> = [];
	const collect = (app: HelperApp, window: HelperRoot) => {
		const title = normalizeText(window.title);
		if (!title) return;
		if (title === normalizeText(query)) exactMatches.push({ app, window });
		else if (title.includes(normalizeText(query))) partialMatches.push({ app, window });
	};

	for (const window of await listWindowsByTitle(query, signal)) {
		if (!window.pid) continue;
		collect({ appName: window.appName ?? "Unknown App", bundleId: window.bundleId, pid: window.pid }, window);
	}
	// Some freshly created or off-Space windows are absent from WindowServer's
	// title index for a short period. Preserve complete discovery as a cold-path
	// fallback instead of turning that presentation lag into a false miss.
	if (exactMatches.length === 0 && partialMatches.length === 0) {
		for (const app of await listApps(signal)) {
			for (const window of await listWindows(app.pid, signal)) collect(app, window);
		}
	}

	const matches = exactMatches.length > 0 ? exactMatches : partialMatches;
	if (matches.length === 0) throw new Error(`Window '${query}' was not found in any running app.`);
	const ranked = [...matches].sort((a, b) => scoreWindow(b.window) - scoreWindow(a.window));
	if (ranked.length > 1 && scoreWindow(ranked[0].window) < scoreWindow(ranked[1].window) + DECISIVE_SCORE_GAP) {
		const options = ranked
			.slice(0, 6)
			.map((match) => `${match.app.appName} — ${summarizeWindowCandidate(match.window)}`)
			.join(", ");
		throw new Error(`Window title '${query}' is ambiguous (${options}). Specify app as well.`);
	}

	const resolved = toResolvedTarget(ranked[0].app, ranked[0].window);
	setCurrentTarget(resolved);
	return resolved;
}

export async function resolveTargetForObserve(selection: TargetSelection, signal?: AbortSignal): Promise<ResolvedTarget> {
	const appQuery = trimOrUndefined(selection.app);
	const windowTitleQuery = trimOrUndefined(selection.windowTitle);

	if (!appQuery && !windowTitleQuery) {
		if (operationState().currentTarget) return await resolveCurrentTarget(signal);
		return await resolveFrontmostTarget(signal);
	}

	if (appQuery) {
		const app = chooseAppByQuery(await listApps(signal), appQuery);
		const windows = await listWindows(app.pid, signal);
		if (!windows.length) throw new Error(`No controllable root was found in app '${app.appName}'.`);
		const window = windowTitleQuery
			? chooseWindowByTitle(windows, windowTitleQuery, app.appName)
			: choosePreferredWindow(windows, app.appName);
		const resolved = toResolvedTarget(app, window);
		setCurrentTarget(resolved);
		return resolved;
	}

	return await resolveTargetByTitleAcrossApps(windowTitleQuery!, signal);
}

export async function ensureTargetWindowId(target: ResolvedTarget, signal?: AbortSignal): Promise<ResolvedTarget> {
	if (target.windowId > 0 || target.nativeWindowRef) return target;
	const refreshed = await resolveCurrentTarget(signal);
	if (refreshed.windowId <= 0 && !refreshed.nativeWindowRef) throw new Error(CURRENT_TARGET_GONE_ERROR);
	return refreshed;
}

// Side effect: stores stable @r refs for discovered roots.
function rootDetail(app: HelperApp, window: HelperRoot): RootDetail {
	return {
		app: app.appName,
		bundleId: app.bundleId,
		pid: app.pid,
		kind: window.kind,
		windowTitle: window.title || "(untitled)",
		windowId: window.windowId,
		windowRef: storeRootRefForAppWindow(app, window).ref,
		nativeWindowRef: window.windowRef,
		framePoints: window.framePoints,
		scaleFactor: window.scaleFactor,
		isMinimized: window.isMinimized,
		isOnscreen: window.isOnscreen,
		isMain: window.isMain,
		isFocused: window.isFocused,
		isModal: window.isModal,
		sheetCount: rootSheetCount(window),
		role: window.role,
		subrole: window.subrole,
		pairing: rootPairing(window),
		zOrder: window.zOrder,
		score: scoreWindow(window),
	};
}

function sortRootDetails(windows: RootDetail[]): RootDetail[] {
	return windows.sort((a, b) => b.score - a.score || a.app.localeCompare(b.app) || a.windowTitle.localeCompare(b.windowTitle));
}

async function collectWindowDetails(apps: HelperApp[], signal?: AbortSignal): Promise<RootDetail[]> {
	const windows: RootDetail[] = [];
	for (const app of apps) {
		for (const window of await listWindows(app.pid, signal)) windows.push(rootDetail(app, window));
	}
	return sortRootDetails(windows);
}

// Broad discovery uses one helper listRoots call instead of per-app round trips.
async function collectBroadWindowDetails(signal?: AbortSignal): Promise<RootDetail[]> {
	const roots = await macosBackend.listRoots({}, signal);
	return sortRootDetails(roots
		.filter((root) => Number.isFinite(root.pid) && root.pid! > 0)
		.map((root) => rootDetail({ appName: root.appName ?? "Unknown App", bundleId: root.bundleId, pid: root.pid! }, root)));
}

async function performFindRoots(params: FindParams, signal?: AbortSignal): Promise<ToolResult<FindRootsDetails>> {
	const rawParams = params ?? {};
	const query: FindParams = {
		query: trimOrUndefined(rawParams.query),
		app: trimOrUndefined(rawParams.app),
		bundleId: trimOrUndefined(rawParams.bundleId),
		pid: Number.isFinite(rawParams.pid) ? Math.trunc(rawParams.pid!) : undefined,
		kind: rawParams.kind,
	};
	const broad = !query.app && !query.bundleId && !Number.isFinite(query.pid);
	const discovered = broad
		? await collectBroadWindowDetails(signal)
		: await collectWindowDetails((await listApps(signal)).filter((app) => appMatchesWindowQuery(app, query)), signal);
	const forest = discovered.filter((root) => !query.kind || root.kind === query.kind);
	const normalizedQuery = normalizeText(query.query ?? "");
	const exact = normalizedQuery ? forest.filter((root) => normalizeText(root.app) === normalizedQuery || normalizeText(root.windowTitle) === normalizedQuery) : [];
	const fuzzy = normalizedQuery && exact.length === 0
		? forest.filter((root) => `${normalizeText(root.app)} ${normalizeText(root.windowTitle)}`.includes(normalizedQuery))
		: [];
	const windows = (exact.length > 0 ? exact : fuzzy.length > 0 ? fuzzy : forest)
		.sort((a, b) => Number(b.isFocused) - Number(a.isFocused) || a.zOrder - b.zOrder || a.app.localeCompare(b.app));
	const lines = windows.map(formatRootLine);
	const text = lines.length
		? `Found ${lines.length} root${lines.length === 1 ? "" : "s"}${query.query ? ` for ${JSON.stringify(query.query)}` : ""}. Use @r refs with observe-ui.\n${lines.join("\n")}`
		: `No roots are currently visible to bcu.`;
	return { text, details: { tool: "find_roots", query, windows } };
}

export const executeFind = makeToolExecutor(performFindRoots);
