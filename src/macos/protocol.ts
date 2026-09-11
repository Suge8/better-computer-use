import type { PermissionStatus } from "../permissions.ts";

export const HELPER_ARCHITECTURE_VERSION = 1;
export const REQUIRED_HELPER_INVARIANTS = [
	"state-scoped-observations",
	"bounded-observation-history",
	"multi-root-forest",
	"progressive-disclosure",
	"atomic-physical-input",
	"concurrent-requests",
	"transactional-batching",
] as const;

export type NativeInputDelivery = "hid" | "pid";
export type ActOutcome = "worked" | "didnt" | "unknown";
/**
 * Presentation hint for a root. Only the `window` vs transient distinction is a
 * behavioral fact; specific transient kinds are display hints.
 */
export type RootKind = "window" | "menu" | "sheet" | "popover" | "dialog";

export interface HelperDiagnostics {
	protocolVersion: number;
	architectureVersion?: number;
	invariants?: string[];
	pid: number;
	parentPid?: number;
	parentAppName?: string;
	parentBundleId?: string;
	parentPath?: string;
	executablePath?: string;
	os?: string;
	arch?: string;
	accessibility?: boolean;
	screenRecording?: boolean;
}

export interface HelperReadyState {
	permissionStatus?: PermissionStatus;
	lastPermissionCheckAt: number;
	helperDiagnostics?: HelperDiagnostics;
}

export interface RootQuery {
	pid?: number;
	title?: string;
}

export interface HelperApp {
	appName: string;
	bundleId?: string;
	pid: number;
	isFrontmost?: boolean;
}

export interface FramePoints {
	x: number;
	y: number;
	w: number;
	h: number;
}

export interface HelperRoot {
	kind: RootKind;
	rootRef?: string;
	windowRef?: string;
	windowId?: number;
	pid?: number;
	appName?: string;
	bundleId?: string;
	title: string;
	role?: string;
	subrole?: string;
	zOrder: number;
	framePoints: FramePoints;
	scaleFactor: number;
	isOnscreen: boolean;
	isFocused: boolean;
	isMinimized: boolean;
	isMain: boolean;
	/** AX modality fact, including modal/dialog/sheet signals. */
	isModal: boolean;
	metadata?: Record<string, unknown>;
}

export interface FrontmostResult {
	appName: string;
	bundleId?: string;
	pid: number;
	windowTitle?: string;
	windowId?: number;
	rootRef?: string;
}

export interface FocusWindowResult {
	focused: boolean;
	alreadyFocused?: boolean;
	reason?: string;
}

export interface HelperActPerformed {
	grounding?: "description" | "coordinates" | "keyboard-events";
	delivery?: "ax" | NativeInputDelivery;
	refound?: boolean;
	/** Free-form diagnostic naming the helper's delta mechanism. */
	deltaSource?: string;
	selectionGrounding?: "ax" | "keyboard";
	transaction?: boolean;
	actionCount?: number;
	activated?: boolean;
	raised?: boolean;
	focused?: boolean;
}

export interface RootDelta {
	change: "appeared" | "closed" | "focused";
	kind: string;
	ref?: string;
	title?: string;
	pid: number;
	isModal?: boolean;
	metadata?: Record<string, unknown>;
}

export interface HelperActResult {
	outcome: ActOutcome;
	performed?: HelperActPerformed;
	evidence?: Record<string, unknown>;
	error?: { code?: string; message?: string; whatIsThere?: unknown };
	rootDelta?: RootDelta[];
	steps?: HelperActResult[];
	stoppedAt?: number;
}

export interface HelperTarget {
	pid?: number;
	windowId?: number;
	windowRef?: string;
}

export interface ObserveRequest {
	/** `look` targets and captures by stable window id. */
	windowId: number;
	/** Existing immutable look whose untouched refs/coordinate geometry survive a scoped refresh. */
	baseLookId?: string;
	readText: "auto" | "always" | "never";
	scopeRef?: string;
	maxDimension?: number;
	includeImage?: boolean;
}

export type ActTarget = { ref: string } | { x: number; y: number } | { focus: Point };
export type DeliveryPolicy = "ax_only" | "background" | "default" | "foreground";
export type MouseButton = "left" | "right" | "middle";
export type Point = { x: number; y: number };
type ActDeliveryParam = { delivery?: NativeInputDelivery };

export interface ActRequestBase {
	lookId: string;
	pid?: number;
	target: ActTarget;
	policy: DeliveryPolicy;
}

export type ActRequest = ActRequestBase & (
	| { action: "press" | "click"; params: { button?: MouseButton; clickCount?: number } & ActDeliveryParam }
	| { action: "setText"; params: { text: string } & ActDeliveryParam }
	| { action: "typeText"; params: { text: string } & ActDeliveryParam }
	| { action: "keypress"; params: { keys: string[] } & ActDeliveryParam }
	| { action: "scroll"; params: { scrollX: number; scrollY: number } & ActDeliveryParam }
	| { action: "drag"; params: { path: Point[] } & ActDeliveryParam }
	| { action: "moveMouse"; params: ActDeliveryParam }
);

export interface ReadTextRequest {
	/** Observation that owns the element ref. The helper must not resolve across observations. */
	lookId: string;
	elementRef: string;
	offset: number;
	limit: number;
}

export interface ReadTextResponse {
	text: string;
	offset: number;
	limit: number;
	totalChars: number;
	hasMore: boolean;
}

export interface WaitForRequest extends HelperTarget {
	lookId?: string;
	text?: string;
	role?: string;
	value?: string;
	scopeRef?: string;
	scopeExact?: boolean;
	gone: boolean;
	timeoutMs: number;
}

export interface WaitForResponse {
	found: boolean;
	gone?: boolean;
	timedOut?: boolean;
	nodeCount?: number;
}

export function toBoolean(value: unknown): boolean {
	return value === true || value === "true" || value === 1;
}

export function toFiniteNumber(value: unknown, fallback: number): number {
	if (typeof value === "number" && Number.isFinite(value)) return value;
	if (typeof value === "string") {
		const parsed = Number(value);
		if (Number.isFinite(parsed)) return parsed;
	}
	return fallback;
}

export function toOptionalString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function assertHelperArchitecture(diagnostics: HelperDiagnostics): void {
	if (diagnostics.architectureVersion !== HELPER_ARCHITECTURE_VERSION) {
		throw new Error(`macOS helper architecture mismatch: expected ${HELPER_ARCHITECTURE_VERSION}, got ${diagnostics.architectureVersion ?? "unknown"}. Rebuild and restart the helper.`);
	}
	const reported = new Set(diagnostics.invariants ?? []);
	const missing = REQUIRED_HELPER_INVARIANTS.filter((invariant) => !reported.has(invariant));
	if (missing.length > 0) {
		throw new Error(`macOS helper does not satisfy the computer-use contract: ${missing.join(", ")}.`);
	}
}
