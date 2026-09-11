import type { Outline, OutlineNode } from "./outline.ts";

/** The only capability words an agent ever sees; anything else stays inside the outline. */
export const CAPABILITIES = [
	"press",
	"toggle",
	"setText",
	"typeText",
	"menu",
	"open",
	"expand",
	"scroll",
	"increment",
	"decrement",
	"raise",
] as const;

export type Capability = typeof CAPABILITIES[number];

export interface ProjectedState {
	focused?: true;
	offscreen?: true;
	truncated?: true;
	scroll?: { seen: number; total: number };
}

export interface ProjectedNode {
	ref: string;
	parent?: string;
	depth: number;
	role: string;
	name: string;
	value?: string;
	caps: Capability[];
	/** Capabilities this node inherited from a merged descendant, and the ref that performs them. */
	owners?: Partial<Record<Capability, string>>;
	state?: ProjectedState;
	/** Descendants the render budget folded away; they stay expandable through expand-ui. */
	hidden?: { count: number; roles: Record<string, number> };
}

export interface Projection {
	nodes: ProjectedNode[];
	shown: number;
	total: number;
	truncated: boolean;
	/** Outline ref → the projected node that speaks for it. Dropped nodes are absent. */
	represents: Map<string, string>;
}

export interface ProjectOptions {
	maxDepth?: number;
	maxNodes?: number;
	unfold?: string[];
	/** Projects this subtree instead of the whole root. */
	from?: OutlineNode;
}

export interface ObservationView {
	stateId: string;
	root: { ref?: string; app: string; title: string };
	nodes: ProjectedNode[];
	shown: number;
	total: number;
}

const MAX_NODES = 150;
/** The first view grows one level at a time while it still fits this many bytes. */
const VIEW_BYTE_BUDGET = 900;
const MAX_AUTO_DEPTH = 8;
const MAX_NAME_CHARS = 120;
const MAX_VALUE_CHARS = 160;

/** Subrole words that are less useful than the role they specialize. */
const ROLE_ALIASES: Record<string, string> = {
	statictext: "text",
	popupbutton: "popup",
	radiobutton: "radio",
	standardwindow: "window",
	systemdialog: "dialog",
	floatingwindow: "window",
	systemfloatingwindow: "window",
	dialogwindow: "dialog",
	outlinerow: "row",
	tablerow: "row",
	menubaritem: "menuitem",
	sortbutton: "button",
	textattachment: "image",
};

const ACTION_CAPABILITIES: Record<string, Capability> = {
	axpress: "press",
	axopen: "open",
	axshowmenu: "menu",
	axpick: "menu",
	axexpand: "expand",
	axdisclose: "expand",
	axincrement: "increment",
	axdecrement: "decrement",
	axraise: "raise",
	axscrollupbypage: "scroll",
	axscrolldownbypage: "scroll",
	axscrollleftbypage: "scroll",
	axscrollrightbypage: "scroll",
};

/** Scrollbars and their arrows are never an agent's target; the scroll capability replaces them. */
const DROPPED_ROLES = new Set(["scrollbar"]);

const STRUCTURAL_ROLES = new Set([
	"group",
	"splitgroup",
	"scrollarea",
	"cell",
	"column",
	"splitter",
	"scrollbar",
	"layoutarea",
	"layoutitem",
	"unknown",
	"matte",
]);

/** Roles that speak through the content they wrap; a window or a list never does. */
const ABSORBING_ROLES = new Set([...STRUCTURAL_ROLES, "row", "listitem", "tab", "link", "menuitem", "button", "checkbox", "radio"]);
const TEXT_ROLES = new Set(["textfield", "textarea", "combobox", "searchfield"]);
/** Role words whose press flips a value. The helper judges the same family by AX role and subrole. */
const TOGGLE_ROLES = new Set(["checkbox", "radio", "switch", "disclosuretriangle", "togglebutton", "segment"]);

interface ProjectedTree extends Omit<ProjectedNode, "depth" | "parent" | "hidden" | "owners"> {
	children: ProjectedTree[];
	owners: Partial<Record<Capability, string>>;
	/** Outline refs this node speaks for: itself plus everything merged into it. */
	refs: string[];
}

function word(value: string): string {
	return value.trim().replace(/^AX/, "").toLowerCase();
}

function roleWord(node: OutlineNode): string {
	const main = ROLE_ALIASES[word(node.role)] ?? word(node.role);
	const sub = word(node.subrole);
	if (!sub) return main || "unknown";
	const specific = ROLE_ALIASES[sub] ?? sub;
	return specific === main ? main : specific;
}

function clean(value: string, limit: number): string {
	const normalized = value.replace(/\s+/g, " ").trim();
	return normalized.length > limit ? `${normalized.slice(0, limit)}…` : normalized;
}

/** AppKit leaks internal identifiers through titles; they are never a name an agent can use. */
function isInternalIdentifier(value: string): boolean {
	return /^_+[A-Za-z]+[:.]/.test(value) || /Identifier(\.\d+)?$/.test(value);
}

function nameOf(node: OutlineNode): string {
	for (const candidate of [node.title, node.description]) {
		const text = clean(candidate, MAX_NAME_CHARS);
		if (text) return text;
	}
	return "";
}

/** Last-resort name: a developer identifier is better than nothing, unless it is AppKit noise. */
function identifierName(node: OutlineNode): string {
	const text = clean(node.identifier, MAX_NAME_CHARS);
	return text && !isInternalIdentifier(text) ? text : "";
}

function capabilitiesOf(node: OutlineNode, role: string): Capability[] {
	const found = new Set<Capability>();
	for (const action of node.actions) {
		const capability = ACTION_CAPABILITIES[action.trim().toLowerCase()];
		if (capability) found.add(capability);
	}
	if (node.canPress) found.add("press");
	if (node.canScroll) found.add("scroll");
	if (node.canIncrement) found.add("increment");
	if (node.canDecrement) found.add("decrement");
	if (node.isTextInput || TEXT_ROLES.has(role)) {
		if (node.canSetValue) found.add("setText");
		if (node.isTextInput) found.add("typeText");
	}
	if (TOGGLE_ROLES.has(role) && (found.delete("press") || node.canSetValue)) found.add("toggle");
	return CAPABILITIES.filter((capability) => found.has(capability));
}

function stateOf(node: OutlineNode): ProjectedState | undefined {
	const state: ProjectedState = {};
	if (node.focused) state.focused = true;
	if (node.offscreen) state.offscreen = true;
	if (node.truncated) state.truncated = true;
	if (node.scrollExtent && node.scrollExtent.seen < node.scrollExtent.total) state.scroll = { ...node.scrollExtent };
	return Object.keys(state).length > 0 ? state : undefined;
}

function mergeCapabilities(...groups: Capability[][]): Capability[] {
	const found = new Set(groups.flat());
	return CAPABILITIES.filter((capability) => found.has(capability));
}

/** Records who actually performs the capabilities a node inherits from a merged node. */
function delegate(target: ProjectedTree, sources: ProjectedTree[]): Partial<Record<Capability, string>> {
	const owners = { ...target.owners };
	for (const source of sources) {
		for (const capability of source.caps) {
			if (target.caps.includes(capability) || owners[capability]) continue;
			owners[capability] = source.owners[capability] ?? source.ref;
		}
	}
	return owners;
}

function isTextLeaf(tree: ProjectedTree): boolean {
	return tree.children.length === 0 && (tree.role === "text" || tree.role === "image");
}

function buildTrees(node: OutlineNode): ProjectedTree[] {
	const role = roleWord(node);
	if (DROPPED_ROLES.has(role)) return [];
	const children = node.children.flatMap(buildTrees);
	const caps = capabilitiesOf(node, role);
	const state = stateOf(node);
	const value = clean(node.value, MAX_VALUE_CHARS);
	let name = nameOf(node) || (role === "text" ? value : "");
	// A node with no name, no capability and no state says nothing an agent can use.
	// Structural wrappers hand their children up; everything else disappears.
	if (!name && !caps.length && !state && (children.length === 0 || STRUCTURAL_ROLES.has(role) || role === "image")) return children;
	// An unnamed, childless menu item is a separator: it answers AXPress but does nothing.
	if (!name && role === "menuitem" && children.length === 0) return [];

	let tree: ProjectedTree = {
		ref: node.ref,
		role,
		name,
		value: value && value !== name && role !== "text" ? value : undefined,
		caps,
		state,
		children,
		refs: [node.ref],
		owners: {},
	};
	if (!name && ABSORBING_ROLES.has(role)) {
		// An unnamed wrapper speaks through the text it wraps, and through the one
		// structural child that carries the real capability.
		const absorbed = children.filter(isTextLeaf);
		if (absorbed.length > 0) {
			name = absorbed.map((child) => child.name).filter(Boolean).join(" ");
			tree = {
				...tree,
				name,
				caps: mergeCapabilities(tree.caps, ...absorbed.map((child) => child.caps)),
				owners: delegate(tree, absorbed),
				children: children.filter((child) => !isTextLeaf(child)),
				refs: [...tree.refs, ...absorbed.flatMap((child) => child.refs)],
			};
		}
		// An unnamed wrapper and its only child are one thing to an agent. The node that
		// is not a structural wrapper keeps its ref, role and name; the other lends caps.
		if (!tree.name && tree.children.length === 1) {
			const only = tree.children[0];
			const caps = mergeCapabilities(tree.caps, only.caps);
			const refs = [...tree.refs, ...only.refs];
			if (STRUCTURAL_ROLES.has(only.role)) tree = { ...tree, name: only.name, value: tree.value ?? only.value, caps, owners: delegate(tree, [only]), children: only.children, refs };
			else if (STRUCTURAL_ROLES.has(tree.role)) tree = { ...only, caps, owners: delegate(only, [tree]), refs };
		}
	}
	if (!tree.name) tree = { ...tree, name: identifierName(node) };
	return [tree];
}

function descendantRoles(tree: ProjectedTree): { count: number; roles: Record<string, number> } {
	const roles: Record<string, number> = {};
	let count = 0;
	const visit = (current: ProjectedTree) => {
		for (const child of current.children) {
			count += 1;
			roles[child.role] = (roles[child.role] ?? 0) + 1;
			visit(child);
		}
	};
	visit(tree);
	return { count, roles };
}

function pathRefs(node: OutlineNode): string[] {
	const refs: string[] = [];
	let current: OutlineNode | undefined = node;
	while (current) {
		refs.unshift(current.ref);
		current = current.parent;
	}
	return refs;
}

// Always-open paths: the live focus and modal roots. A subtree the helper cut short
// keeps its `truncated` state word instead, so one deep frontier cannot blow up the view.
function defaultUnfolded(outline: Outline, requested: string[]): Set<string> {
	const refs = new Set<string>(requested);
	for (const node of outline.nodes) {
		if ((node.focused && node.canFocus) || node.role === "AXSheet" || node.role === "AXDialog") {
			for (const ref of pathRefs(node)) refs.add(ref);
		}
	}
	return refs;
}

function representationOf(trees: ProjectedTree[]): Map<string, string> {
	const represents = new Map<string, string>();
	const visit = (tree: ProjectedTree) => {
		for (const ref of tree.refs) represents.set(ref, tree.ref);
		for (const child of tree.children) visit(child);
	};
	for (const tree of trees) visit(tree);
	return represents;
}

function foldAtDepth(trees: ProjectedTree[], total: number, maxDepth: number, maxNodes: number, unfolded: Set<string>): Omit<Projection, "represents"> {
	const nodes: ProjectedNode[] = [];
	let truncated = false;
	const emit = (tree: ProjectedTree, depth: number, parent?: string) => {
		if (nodes.length >= maxNodes) {
			truncated = true;
			return;
		}
		const fold = tree.children.length > 0 && depth >= maxDepth && !unfolded.has(tree.ref);
		const { children: _children, refs: _refs, owners, ...fields } = tree;
		nodes.push({ ...fields, owners: Object.keys(owners).length > 0 ? owners : undefined, depth, parent, hidden: fold ? descendantRoles(tree) : undefined });
		if (fold) return;
		for (const child of tree.children) emit(child, depth + 1, tree.ref);
	};
	for (const tree of trees) emit(tree, 0);
	return { nodes, shown: nodes.length, total, truncated };
}

function subtreeSize(node: OutlineNode): number {
	return 1 + node.children.reduce((total, child) => total + subtreeSize(child), 0);
}

export function project(outline: Outline, options: ProjectOptions = {}): Projection {
	const start = options.from ?? outline.root;
	const trees = buildTrees(start);
	const total = start === outline.root ? outline.nodes.length : subtreeSize(start);
	const maxNodes = options.maxNodes ?? MAX_NODES;
	const unfolded = defaultUnfolded(outline, options.unfold ?? []);
	const represents = representationOf(trees);
	if (options.maxDepth !== undefined) return { ...foldAtDepth(trees, total, options.maxDepth, maxNodes, unfolded), represents };

	// Show as much structure as a bounded first view can carry: the focused region is
	// always open, and everything else opens one level at a time while the view fits.
	let best = foldAtDepth(trees, total, 1, maxNodes, unfolded);
	for (let depth = 2; depth <= MAX_AUTO_DEPTH; depth += 1) {
		const candidate = foldAtDepth(trees, total, depth, maxNodes, unfolded);
		if (candidate.shown === best.shown) break;
		if (Buffer.byteLength(renderNodes(candidate.nodes)) > VIEW_BYTE_BUDGET) break;
		best = candidate;
	}
	return { ...best, represents };
}

function stateWords(state: ProjectedState | undefined): string {
	if (!state) return "";
	const words = [
		state.focused ? "focused" : undefined,
		state.offscreen ? "offscreen" : undefined,
		state.truncated ? "truncated" : undefined,
		state.scroll ? `scroll ${state.scroll.seen}/${state.scroll.total}` : undefined,
	].filter(Boolean);
	return words.length ? ` ${words.join(" ")}` : "";
}

function hiddenSummary(hidden: ProjectedNode["hidden"]): string {
	if (!hidden) return "";
	const roles = Object.entries(hidden.roles)
		.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
		.slice(0, 4)
		.map(([role, count]) => `${role}×${count}`)
		.join(" ");
	return ` ▸ ${hidden.count} hidden: ${roles}`;
}

/** One node without its indent or ref, for diff lines. */
export function renderNodeBody(node: ProjectedNode): string {
	const name = node.name ? ` ${JSON.stringify(node.name)}` : "";
	const value = node.value === undefined ? "" : ` =${JSON.stringify(node.value)}`;
	const caps = node.caps.length ? ` {${node.caps.join(",")}}` : "";
	return `${node.role}${name}${value}${caps}${stateWords(node.state)}${hiddenSummary(node.hidden)}`;
}

export function renderNode(node: ProjectedNode): string {
	return `${"  ".repeat(node.depth)}${node.ref} ${renderNodeBody(node)}`;
}

export function renderNodes(nodes: ProjectedNode[]): string {
	return nodes.map(renderNode).join("\n");
}

export function renderObservation(view: ObservationView): string {
	const header = `${view.root.ref ? `${view.root.ref} ` : ""}${view.root.app} — ${view.root.title} · state ${view.stateId} · ${view.total} nodes, ${view.shown} shown`;
	return [header, renderNodes(view.nodes)].filter(Boolean).join("\n");
}
