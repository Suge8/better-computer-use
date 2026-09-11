export interface OutlineRect {
	x: number;
	y: number;
	w: number;
	h: number;
}

export interface OutlineText {
	string: string;
	confidence: number;
	rect?: OutlineRect;
}

export interface OutlineScrollExtent {
	seen: number;
	total: number;
}

export interface OutlineNode {
	ref: string;
	wireRef?: string;
	role: string;
	subrole: string;
	identifier: string;
	title: string;
	description: string;
	value: string;
	actions: string[];
	canPress: boolean;
	canFocus: boolean;
	canSetValue: boolean;
	canScroll: boolean;
	canIncrement: boolean;
	canDecrement: boolean;
	isTextInput: boolean;
	rect?: OutlineRect;
	focused: boolean;
	offscreen: boolean;
	pictureOnly: boolean;
	truncated: boolean;
	scrollExtent?: OutlineScrollExtent;
	text: OutlineText[];
	children: OutlineNode[];
	parent?: OutlineNode;
}

export interface Outline {
	lookId: string;
	root: OutlineNode;
	nodes: OutlineNode[];
	refToWireRef: Map<string, string>;
	wireRefToRef: Map<string, string>;
}

export interface LookImage {
	jpegBase64?: string;
	mimeType?: "image/jpeg" | "image/png";
	width: number;
	height: number;
}

export interface LookWindow {
	windowId: number;
	rootRef?: string;
	kind?: string;
	framePoints: OutlineRect;
	scaleFactor: number;
	isModal: boolean;
	metadata?: Record<string, unknown>;
	role: string;
	subrole: string;
}

export interface LookResponse {
	lookId: string;
	capturedAt: number;
	window: LookWindow;
	image?: LookImage;
	outline: OutlineNode;
	timings: Record<string, number>;
	readText?: { requested?: "auto" | "always" | "never"; executed: boolean };
	parsedOutline?: Outline;
}

export type SerializedOutlineNode = Omit<OutlineNode, "parent" | "children"> & { children: SerializedOutlineNode[] };

export interface SerializedOutline {
	lookId: string;
	root: SerializedOutlineNode;
}


function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function toString(value: unknown): string {
	return typeof value === "string" ? value : "";
}

function toNumber(value: unknown, fallback = 0): number {
	if (typeof value === "number" && Number.isFinite(value)) return value;
	if (typeof value === "string") {
		const parsed = Number(value);
		if (Number.isFinite(parsed)) return parsed;
	}
	return fallback;
}

function toBoolean(value: unknown): boolean {
	return value === true;
}

function parseRect(raw: unknown): OutlineRect {
	const rect = isRecord(raw) ? raw : {};
	return {
		x: toNumber(rect.x),
		y: toNumber(rect.y),
		w: Math.max(0, toNumber(rect.w)),
		h: Math.max(0, toNumber(rect.h)),
	};
}

function parseText(raw: unknown): OutlineText[] {
	if (!Array.isArray(raw)) return [];
	return raw
		.map((item): OutlineText | undefined => {
			if (!isRecord(item)) return undefined;
			const string = toString(item.string);
			if (!string) return undefined;
			return {
				string,
				confidence: Math.max(0, Math.min(1, toNumber(item.confidence))),
				rect: parseRect(item.rect),
			};
		})
		.filter((item): item is OutlineText => Boolean(item));
}

function parseNode(raw: unknown, parent?: OutlineNode): OutlineNode {
	const record = isRecord(raw) ? raw : {};
	const wireRef = toString(record.ref) || undefined;
	const node: OutlineNode = {
		ref: "",
		wireRef,
		role: toString(record.role),
		subrole: toString(record.subrole),
		identifier: toString(record.identifier),
		title: toString(record.title),
		description: toString(record.description),
		value: toString(record.value),
		actions: Array.isArray(record.actions) ? record.actions.filter((value): value is string => typeof value === "string") : [],
		canPress: toBoolean(record.canPress),
		canFocus: toBoolean(record.canFocus),
		canSetValue: toBoolean(record.canSetValue),
		canScroll: toBoolean(record.canScroll),
		canIncrement: toBoolean(record.canIncrement),
		canDecrement: toBoolean(record.canDecrement),
		isTextInput: toBoolean(record.isTextInput),
		rect: parseRect(record.rect),
		focused: toBoolean(record.focused),
		offscreen: toBoolean(record.offscreen),
		pictureOnly: toBoolean(record.pictureOnly),
		truncated: toBoolean(record.truncated),
		scrollExtent: isRecord(record.scrollExtent)
			? { seen: Math.max(0, Math.trunc(toNumber(record.scrollExtent.seen))), total: Math.max(0, Math.trunc(toNumber(record.scrollExtent.total))) }
			: undefined,
		text: parseText(record.text),
		children: [],
		parent,
	};
	node.children = (Array.isArray(record.children) ? record.children : []).map((child) => parseNode(child, node));
	return node;
}

export function parseLookResponse(raw: unknown): LookResponse {
	const record = isRecord(raw) ? raw : {};
	const image = isRecord(record.image) ? record.image : undefined;
	const window = isRecord(record.window) ? record.window : {};
	const metadata = isRecord(window.metadata) ? window.metadata : undefined;
	const outline = buildOutline(toString(record.lookId), parseNode(record.outline));
	const readText = isRecord(record.readText) ? record.readText : undefined;
	const requestedReadText = readText?.requested === "auto" || readText?.requested === "always" || readText?.requested === "never" ? readText.requested : undefined;
	const look: LookResponse = {
		lookId: toString(record.lookId),
		capturedAt: toNumber(record.capturedAt, Date.now() / 1000),
		window: {
			windowId: Math.trunc(toNumber(window.windowId)),
			rootRef: toString(window.rootRef) || undefined,
			kind: toString(window.kind) || undefined,
			framePoints: parseRect(window.framePoints),
			scaleFactor: Math.max(1, toNumber(window.scaleFactor, 1)),
			isModal: toBoolean(window.isModal),
			metadata,
			role: toString(window.role),
			subrole: toString(window.subrole),
		},
		image: image ? {
			jpegBase64: toString(image.jpegBase64),
			mimeType: image.mimeType === "image/png" ? "image/png" : "image/jpeg",
			width: Math.max(1, Math.trunc(toNumber(image.width, 1))),
			height: Math.max(1, Math.trunc(toNumber(image.height, 1))),
		} : undefined,
		outline: outline.root,
		timings: isRecord(record.timings) ? Object.fromEntries(Object.entries(record.timings).map(([key, value]) => [key, toNumber(value)])) : {},
		readText: readText ? { requested: requestedReadText, executed: toBoolean(readText.executed) } : undefined,
		parsedOutline: outline,
	};
	if (!look.lookId) throw new Error("Helper returned a look without lookId.");
	return look;
}

function buildOutline(lookId: string, root: OutlineNode): Outline {
	const nodes: OutlineNode[] = [];
	const refToWireRef = new Map<string, string>();
	const wireRefToRef = new Map<string, string>();
	const queue = [root];
	let index = 0;
	while (index < queue.length) {
		const node = queue[index++];
		node.ref = `@e${nodes.length + 1}`;
		nodes.push(node);
		if (node.wireRef) {
			refToWireRef.set(node.ref, node.wireRef);
			wireRefToRef.set(node.wireRef, node.ref);
		}
		queue.push(...node.children);
	}
	return { lookId, root, nodes, refToWireRef, wireRefToRef };
}

export function nodeByRef(outline: Outline, ref: string): OutlineNode | undefined {
	return outline.nodes.find((node) => node.ref === ref || node.wireRef === ref);
}













function actionMatches(node: OutlineNode, action: string): boolean {
	const query = action.toLowerCase();
	if (query === "press" && node.canPress) return true;
	if (query === "focus" && node.canFocus) return true;
	if ((query === "setvalue" || query === "set_text" || query === "settext") && node.canSetValue) return true;
	if (query === "scroll" && node.canScroll) return true;
	if (query === "increment" && node.canIncrement) return true;
	if (query === "decrement" && node.canDecrement) return true;
	return node.actions.some((candidate) => candidate.toLowerCase().includes(query));
}

function normalizedSearchRole(value: string): string {
	return value.trim().toLowerCase().replace(/^ax/, "").replace(/[ _-]+/g, "");
}



/** Matches anywhere in the cached outline; role accepts short words as well as AX names. */
export function searchOutline(outline: Outline, text?: string, role?: string, action?: string): { matches: OutlineNode[]; total: number } {
	const query = text?.trim().toLowerCase();
	const roleQuery = role ? normalizedSearchRole(role) : undefined;
	const actionQuery = action?.trim();
	const matches: OutlineNode[] = [];
	for (const node of outline.nodes) {
		// outlineNodeLabel short-circuits (title || description || value), so
		// list the fields individually too or a titled node's value/description
		// can never match.
		const haystack = [node.role, node.subrole, node.identifier, node.title, node.description, node.value, ...node.text.map((item) => item.string)].join(" ").toLowerCase();
		if (query && !haystack.includes(query)) continue;
		if (roleQuery && normalizedSearchRole(node.role) !== roleQuery && normalizedSearchRole(node.subrole) !== roleQuery) continue;
		if (actionQuery && !actionMatches(node, actionQuery)) continue;
		matches.push(node);
	}
	return { matches, total: matches.length };
}


export function serializeOutline(outline: Outline): SerializedOutline {
	return { lookId: outline.lookId, root: serializeOutlineNode(outline.root) };
}

export function serializeOutlineNode(node: OutlineNode): SerializedOutlineNode {
	const { parent: _parent, children, ...rest } = node;
	return { ...rest, children: children.map(serializeOutlineNode) };
}

export function restoreOutline(serialized: SerializedOutline): Outline {
	const nodes: OutlineNode[] = [];
	const refToWireRef = new Map<string, string>();
	const wireRefToRef = new Map<string, string>();
	const restoreNode = (raw: SerializedOutlineNode, parent?: OutlineNode): OutlineNode => {
		const node: OutlineNode = { ...raw, children: [], parent };
		nodes.push(node);
		if (node.wireRef) {
			refToWireRef.set(node.ref, node.wireRef);
			wireRefToRef.set(node.wireRef, node.ref);
		}
		node.children = raw.children.map((child) => restoreNode(child, node));
		return node;
	};
	const root = restoreNode(serialized.root);
	return { lookId: serialized.lookId, root, nodes, refToWireRef, wireRefToRef };
}

function outlineRefNumber(ref: string): number {
	const match = /^@e(\d+)$/.exec(ref);
	return match ? Number(match[1]) : 0;
}

function clearScopedRects(node: OutlineNode): void {
	// Scoped look geometry is in the scoped image's pixel space, not the full look.
	// Until helper-side act carries stable look geometry, grafted nodes are AX-only
	// for ref actions; coordinate fallback must re-observe the full window.
	node.rect = undefined;
	for (const text of node.text) text.rect = undefined;
	for (const child of node.children) clearScopedRects(child);
}

function rebuildIndexes(outline: Outline): void {
	outline.nodes = [];
	outline.refToWireRef = new Map();
	outline.wireRefToRef = new Map();
	const queue = [outline.root];
	let index = 0;
	while (index < queue.length) {
		const node = queue[index++];
		outline.nodes.push(node);
		if (node.wireRef) {
			outline.refToWireRef.set(node.ref, node.wireRef);
			outline.wireRefToRef.set(node.wireRef, node.ref);
		}
		queue.push(...node.children);
	}
}

function copyNodeFields(target: OutlineNode, source: OutlineNode, preserveWireRef = false): void {
	if (!preserveWireRef) target.wireRef = source.wireRef;
	target.role = source.role;
	target.subrole = source.subrole;
	target.identifier = source.identifier;
	target.title = source.title;
	target.description = source.description;
	target.value = source.value;
	target.actions = [...source.actions];
	target.canPress = source.canPress;
	target.canFocus = source.canFocus;
	target.canSetValue = source.canSetValue;
	target.canScroll = source.canScroll;
	target.canIncrement = source.canIncrement;
	target.canDecrement = source.canDecrement;
	target.isTextInput = source.isTextInput;
	target.rect = source.rect;
	target.focused = source.focused;
	target.offscreen = source.offscreen;
	target.pictureOnly = source.pictureOnly;
	target.truncated = false;
	target.scrollExtent = source.scrollExtent ? { ...source.scrollExtent } : undefined;
	target.text = source.text.map((text) => ({ ...text, rect: text.rect ? { ...text.rect } : undefined }));
}

function preserveUnreused(node: OutlineNode, parent: OutlineNode, used: Set<OutlineNode>): OutlineNode | undefined {
	if (used.has(node)) return undefined;
	node.parent = parent;
	node.children = node.children
		.map((child) => preserveUnreused(child, node, used))
		.filter((child): child is OutlineNode => Boolean(child));
	return node;
}

function cloneForGraft(source: OutlineNode, parent: OutlineNode, nextRef: () => string, reusableByWireRef: Map<string, OutlineNode>, used: Set<OutlineNode>): OutlineNode {
	const existing = source.wireRef ? reusableByWireRef.get(source.wireRef) : undefined;
	if (existing) used.add(existing);
	const oldChildren = existing?.children ?? [];
	const node: OutlineNode = existing ?? {
		...source,
		ref: nextRef(),
		children: [],
		parent,
		text: [],
		actions: [],
		scrollExtent: undefined,
	};
	copyNodeFields(node, source, Boolean(existing));
	node.parent = parent;
	const graftedChildren = source.children.map((child) => cloneForGraft(child, node, nextRef, reusableByWireRef, used));
	const preservedChildren = oldChildren
		.map((child) => preserveUnreused(child, node, used))
		.filter((child): child is OutlineNode => Boolean(child));
	node.children = [...graftedChildren, ...preservedChildren];
	return node;
}

export function graftScopedOutline(outline: Outline, targetRef: string, scoped: Outline): OutlineNode {
	const target = nodeByRef(outline, targetRef);
	if (!target) throw new Error(`Cannot graft scoped outline: target ${targetRef} is not in the current outline.`);
	const targetRect = target.rect ? { ...target.rect } : undefined;
	const reusableByWireRef = new Map<string, OutlineNode>();
	const collect = (node: OutlineNode) => {
		if (node.wireRef) reusableByWireRef.set(node.wireRef, node);
		for (const child of node.children) collect(child);
	};
	collect(target);
	let nextNumber = Math.max(...outline.nodes.map((node) => outlineRefNumber(node.ref)), 0) + 1;
	const nextRef = () => `@e${nextNumber++}`;
	const oldChildren = target.children;
	const used = new Set<OutlineNode>([target]);
	copyNodeFields(target, scoped.root, true);
	target.ref = targetRef;
	target.rect = targetRect;
	const graftedChildren = scoped.root.children.map((child) => cloneForGraft(child, target, nextRef, reusableByWireRef, used));
	const preservedChildren = oldChildren
		.map((child) => preserveUnreused(child, target, used))
		.filter((child): child is OutlineNode => Boolean(child));
	target.children = [...graftedChildren, ...preservedChildren];
	for (const child of target.children) clearScopedRects(child);
	rebuildIndexes(outline);
	return target;
}
