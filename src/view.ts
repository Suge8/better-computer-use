import type { Change, ChangedFields } from "./contract.ts";
import type { Outline, OutlineNode } from "./outline.ts";
import { renderNodeBody, type ProjectedNode, type ProjectedState } from "./projection.ts";

function numericRef(ref: string): number {
	const match = /^@e(\d+)$/.exec(ref);
	return match ? Number(match[1]) : 0;
}

function rebuildIndexes(outline: Outline): void {
	outline.nodes = [];
	outline.refToWireRef = new Map();
	outline.wireRefToRef = new Map();
	const queue = [outline.root];
	while (queue.length > 0) {
		const node = queue.shift()!;
		outline.nodes.push(node);
		if (node.wireRef) {
			outline.refToWireRef.set(node.ref, node.wireRef);
			outline.wireRefToRef.set(node.wireRef, node.ref);
		}
		queue.push(...node.children);
	}
}

function structuralToken(node: OutlineNode): string {
	return [node.role, node.subrole, node.identifier, node.title, node.description].map((value) => value.trim().toLowerCase()).join("|");
}

function structuralKey(node: OutlineNode): string {
	const parts: string[] = [];
	let current: OutlineNode | undefined = node;
	while (current) {
		const token = structuralToken(current);
		const siblings = current.parent?.children ?? [current];
		const peers = siblings.filter((candidate) => structuralToken(candidate) === token);
		parts.unshift(`${token}#${Math.max(0, peers.indexOf(current))}`);
		current = current.parent;
	}
	return parts.join(">");
}

/** Preserve public refs only when native or structural identity is unambiguous. */
export function stabilizeRefs(base: Outline | undefined, next: Outline): Outline {
	if (!base) return next;
	const reserved = new Set<string>();
	const assigned = new Set<OutlineNode>();
	const byWireRef = new Map(base.nodes.filter((node) => node.wireRef).map((node) => [node.wireRef!, node.ref]));
	const structuralGroups = new Map<string, OutlineNode[]>();
	for (const node of base.nodes) {
		const key = structuralKey(node);
		structuralGroups.set(key, [...(structuralGroups.get(key) ?? []), node]);
	}
	let nextIndex = Math.max(0, ...base.nodes.map((node) => numericRef(node.ref))) + 1;
	for (const node of next.nodes) {
		const wireStable = node.wireRef ? byWireRef.get(node.wireRef) : undefined;
		const structuralMatches = structuralGroups.get(structuralKey(node)) ?? [];
		const stable = wireStable ?? (structuralMatches.length === 1 ? structuralMatches[0].ref : undefined);
		if (stable && !reserved.has(stable)) {
			node.ref = stable;
			reserved.add(stable);
			assigned.add(node);
		}
	}
	for (const node of next.nodes) {
		if (assigned.has(node)) continue;
		while (reserved.has(`@e${nextIndex}`)) nextIndex += 1;
		node.ref = `@e${nextIndex++}`;
		reserved.add(node.ref);
	}
	rebuildIndexes(next);
	return next;
}

export interface Transition {
	changes: Change[];
	/** True when the successor is too different to describe as a diff. */
	useFullView: boolean;
}

/** What a state word says when it turns on, and what it says when it turns off. */
const STATE_WORDS = {
	focused: ["focused", "unfocused"],
	offscreen: ["offscreen", "onscreen"],
	truncated: ["truncated", "complete"],
} as const;

/** Names every state word that moved, so a diff line never reads just "changed". */
function changedStateWords(before: ProjectedState | undefined, after: ProjectedState | undefined): string[] {
	const words: string[] = [];
	for (const [key, [on, off]] of Object.entries(STATE_WORDS)) {
		const was = Boolean(before?.[key as keyof typeof STATE_WORDS]);
		const is = Boolean(after?.[key as keyof typeof STATE_WORDS]);
		if (was !== is) words.push(is ? on : off);
	}
	const scroll = after?.scroll;
	if (JSON.stringify(before?.scroll) !== JSON.stringify(scroll)) words.push(scroll ? `scroll ${scroll.seen}/${scroll.total}` : "scroll end");
	return words;
}

function changedFields(before: ProjectedNode, after: ProjectedNode): ChangedFields {
	const fields: ChangedFields = {};
	if (before.role !== after.role) fields.role = after.role;
	if (before.name !== after.name) fields.name = after.name;
	if (before.value !== after.value) fields.value = after.value;
	if (before.caps.join(",") !== after.caps.join(",")) fields.caps = after.caps;
	const state = changedStateWords(before.state, after.state);
	if (state.length > 0) fields.state = state;
	return fields;
}

/** Scrolling in and out of sight is not news about a node the view does not show. */
function isInvisibleVisibilityFlip(fields: ChangedFields, ref: string, visible?: Set<string>): boolean {
	if (!visible || visible.has(ref)) return false;
	const keys = Object.keys(fields);
	return keys.length === 1 && keys[0] === "state" && fields.state!.every((word) => word === "onscreen" || word === "offscreen");
}

/** Compares two unfolded projections of the same root; `visible` is what the view will show. */
export function changesBetween(base: ProjectedNode[], next: ProjectedNode[], visible?: Set<string>): Transition {
	const before = new Map(base.map((node) => [node.ref, node]));
	const after = new Map(next.map((node) => [node.ref, node]));
	const changes: Change[] = [];
	for (const node of next) {
		const previous = before.get(node.ref);
		if (!previous) {
			changes.push({ type: "added", ref: node.ref, parent: node.parent, node });
			continue;
		}
		const fields = changedFields(previous, node);
		if (Object.keys(fields).length === 0 || isInvisibleVisibilityFlip(fields, node.ref, visible)) continue;
		changes.push({ type: "updated", ref: node.ref, fields });
	}
	for (const node of base) if (!after.has(node.ref)) changes.push({ type: "removed", ref: node.ref, parent: node.parent });

	const rootReplaced = base[0]?.ref !== next[0]?.ref || base[0]?.role !== next[0]?.role;
	const kept = next.filter((node) => before.has(node.ref)).length;
	const identityLow = next.length > 8 && kept / next.length < 0.4;
	const overBudget = changes.length > 40 || (changes.length > 20 && changes.length / Math.max(1, Math.max(base.length, next.length)) > 0.65);
	return { changes, useFullView: rootReplaced || identityLow || overBudget };
}

function renderFields(fields: ChangedFields): string {
	const parts = [
		fields.role,
		fields.name === undefined ? undefined : JSON.stringify(fields.name),
		fields.value === undefined ? undefined : `=${JSON.stringify(fields.value)}`,
		fields.caps === undefined ? undefined : `{${fields.caps.join(",")}}`,
		fields.state?.join(" "),
	].filter(Boolean);
	return parts.join(" ") || "changed";
}

export function renderChanges(changes: Change[]): string {
	return changes.map((change) => {
		if (change.type === "added") return `+ ${change.ref}${change.parent ? ` in ${change.parent}` : ""} ${renderNodeBody(change.node)}`;
		if (change.type === "removed") return `- ${change.ref}`;
		return `~ ${change.ref} ${renderFields(change.fields)}`;
	}).join("\n");
}
