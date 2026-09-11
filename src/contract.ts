import type { SerializedOutlineNode } from "./outline.ts";
import type { Capability, ProjectedNode } from "./projection.ts";

export type RootSelector = string | number;
export type ImageMode = "never" | "always";
export type ObserveMode = "semantic" | "fused";
export type ReadTextMode = "auto" | "always" | "never";
export type MouseButtonName = "left" | "right" | "middle";
export type RootKindName = "window" | "menubar" | "menu" | "sheet" | "popover" | "dialog";

export interface Frame {
	x: number;
	y: number;
	w: number;
	h: number;
}

/** Raw image bytes as the helper returns them; never part of a public result. */
export interface ToolImage {
	data: string;
	mimeType: "image/jpeg" | "image/png";
	width: number;
	height: number;
}

export interface ImageInfo {
	path: string;
	mime: ToolImage["mimeType"];
	width: number;
	height: number;
}

export interface FindParams {
	query?: string;
	app?: string;
	bundleId?: string;
	pid?: number;
	/** Filters on the helper's best-effort presentation hint; only window vs transient is guaranteed. */
	kind?: RootKindName;
}

export interface ObserveParams {
	app?: string;
	windowTitle?: string;
	root?: RootSelector;
	mode?: ObserveMode;
	image?: ImageMode;
	readText?: ReadTextMode;
}

export interface StateTargetParams {
	stateId?: string;
}

export interface SearchUiParams extends StateTargetParams {
	text?: string;
	role?: string;
	action?: string;
	limit?: number;
}

export interface ExpandUiParams extends StateTargetParams {
	ref: string;
	depth?: number;
}

export interface InspectUiParams extends StateTargetParams {
	ref: string;
}

export interface UiAction {
	action: "press" | "click" | "doubleClick" | "setText" | "typeText" | "keypress" | "scroll" | "drag" | "moveMouse" | "wait";
	ref?: string;
	x?: number;
	y?: number;
	text?: string;
	keys?: string[];
	scrollX?: number;
	scrollY?: number;
	path?: Array<{ x: number; y: number } | [number, number]>;
	button?: MouseButtonName;
	clickCount?: number;
	ms?: number;
}

/**
 * Why the helper called an action landed: the element fact that moved, the root
 * forest changing, or the pointer reaching an element that then held focus.
 */
export interface ActEvidence {
	source: "ax" | "root" | "focus";
	field?: "value" | "selected" | "focused" | "selection" | "selectedText" | "scroll";
	from?: string;
	to?: string;
}

/** Semantic postcondition; `scope` limits it to one element subtree. */
export interface Expectation {
	text?: string;
	role?: string;
	value?: string;
	scope?: string;
	gone?: boolean;
	timeoutMs?: number;
}

export interface ActParams extends StateTargetParams {
	actions: UiAction[];
	/** Prohibits foreground fallback when true. Background is always attempted first. */
	headless?: boolean;
	image?: ImageMode;
	expect?: Expectation;
}

export interface ReadTextParams extends StateTargetParams {
	ref: string;
	offset?: number;
	limit?: number;
}

export interface WaitForParams extends StateTargetParams {
	text?: string;
	role?: string;
	scope?: string;
	gone?: boolean;
	timeoutMs?: number;
}

export interface RootInfo {
	ref: string;
	app: string;
	bundleId?: string;
	pid: number;
	title: string;
	windowId?: number;
	kind: RootKindName;
	frame: Frame;
	focused: boolean;
	main: boolean;
	onscreen: boolean;
	minimized: boolean;
	modal: boolean;
	pairing?: "exact" | "high" | "low";
}

export interface FindRootsResult {
	roots: RootInfo[];
}

/** A root an action brought into existence, ready to observe by `ref`. */
export interface RootAppearance {
	ref: string;
	kind: RootKindName;
	app: string;
	title: string;
}

export interface RootSummary {
	ref?: string;
	app: string;
	pid: number;
	title: string;
	windowId?: number;
	frame: Frame;
	scale: number;
}

export interface ObserveResult {
	stateId: string;
	root: RootSummary;
	nodes: ProjectedNode[];
	shown: number;
	total: number;
	image?: ImageInfo;
}

export interface SearchMatch extends ProjectedNode {
	path: string[];
}

export interface SearchResult {
	stateId: string;
	matches: SearchMatch[];
	total: number;
}

export interface ExpandResult {
	stateId: string;
	ref: string;
	nodes: ProjectedNode[];
}

export interface InspectResult {
	stateId: string;
	node: SerializedOutlineNode;
	/** Capabilities this ref advertises that another element performs. */
	owners?: Partial<Record<Capability, string>>;
}

export interface ReadTextResult {
	stateId: string;
	ref: string;
	offset: number;
	limit: number;
	total: number;
	text: string;
}

export type ChangedFields = Partial<Pick<ProjectedNode, "role" | "name" | "value" | "caps" | "state">>;

export type Change =
	| { type: "added"; ref: string; parent?: string; node: ProjectedNode }
	| { type: "updated"; ref: string; fields: ChangedFields }
	| { type: "removed"; ref: string; parent?: string };

export interface WaitForResult {
	stateId: string;
	found: boolean;
	gone?: boolean;
	changes?: Change[];
	nodes?: ProjectedNode[];
}

export interface Verification {
	status: "verified" | "none";
	text?: string;
	role?: string;
	value?: string;
	scope?: string;
	gone?: boolean;
	timeoutMs?: number;
	/** True when the expectation already held before the transaction ran. */
	preexisting?: boolean;
	/** The helper's own reason for the outcome, independent of any expectation. */
	evidence?: ActEvidence;
}

export interface ActResult {
	stateId: string;
	baseStateId: string;
	outcome: "worked";
	verification: Verification;
	delivery: string;
	/** Roots the transaction opened: menus, sheets, dialogs and new windows. */
	roots?: RootAppearance[];
	changes?: Change[];
	nodes?: ProjectedNode[];
	shown?: number;
	total?: number;
	image?: ImageInfo;
}

export interface CliCommandParams {
	"find-roots": FindParams;
	"observe-ui": ObserveParams;
	"search-ui": SearchUiParams;
	"expand-ui": ExpandUiParams;
	"inspect-ui": InspectUiParams;
	"act-ui": ActParams;
	"read-text": ReadTextParams;
	"wait-for": WaitForParams;
}

export interface CliCommandResults {
	"find-roots": FindRootsResult;
	"observe-ui": ObserveResult;
	"search-ui": SearchResult;
	"expand-ui": ExpandResult;
	"inspect-ui": InspectResult;
	"act-ui": ActResult;
	"read-text": ReadTextResult;
	"wait-for": WaitForResult;
}

export const CLI_COMMAND_NAMES = [
	"find-roots",
	"observe-ui",
	"search-ui",
	"expand-ui",
	"inspect-ui",
	"act-ui",
	"read-text",
	"wait-for",
] as const satisfies readonly (keyof CliCommandParams)[];
export type CliCommandName = typeof CLI_COMMAND_NAMES[number];
export type CliCommandExecutor<Name extends CliCommandName> = (
	params: CliCommandParams[Name],
	signal?: AbortSignal,
) => Promise<CliCommandResults[Name]>;
