import type { FramePoints, RootDelta } from "./macos/protocol.ts";
import { normalizeText } from "./text.ts";

/**
 * Stable `@r` identity for roots discovered during a session. Refs survive
 * re-discovery of the same window so agents can keep using an earlier ref.
 */
export interface RootRefRecord {
	ref: string;
	appName: string;
	bundleId?: string;
	pid: number;
	windowTitle: string;
	windowId?: number;
	nativeWindowRef?: string;
	framePoints: FramePoints;
	scaleFactor: number;
	isMinimized: boolean;
	isOnscreen: boolean;
	isMain: boolean;
	isFocused: boolean;
}

const records = new Map<string, RootRefRecord>();
const refByIdentity = new Map<string, string>();
let nextIndex = 1;

function identity(record: Pick<RootRefRecord, "pid" | "windowId" | "nativeWindowRef" | "windowTitle" | "framePoints">): string {
	if (record.windowId && record.windowId > 0) return `pid:${record.pid}|id:${record.windowId}`;
	if (record.nativeWindowRef) return `pid:${record.pid}|ref:${record.nativeWindowRef}`;
	const { x, y, w, h } = record.framePoints;
	return `pid:${record.pid}|title:${normalizeText(record.windowTitle)}|frame:${Math.round(x)},${Math.round(y)},${Math.round(w)},${Math.round(h)}`;
}

export function storeRootRef(record: Omit<RootRefRecord, "ref">): RootRefRecord {
	const key = identity(record);
	const existingRef = refByIdentity.get(key);
	if (existingRef && records.has(existingRef)) {
		const updated = { ...record, ref: existingRef };
		records.set(existingRef, updated);
		return updated;
	}
	const ref = `@r${nextIndex++}`;
	const stored = { ...record, ref };
	refByIdentity.set(key, ref);
	records.set(ref, stored);
	return stored;
}

export function rootRefRecord(ref: string): RootRefRecord | undefined {
	return records.get(ref);
}

/** Maps a helper root delta onto a model-visible `@r`, minting one when the root is new. */
export function rootRefForDelta(delta: RootDelta, owner?: { pid: number; appName: string; bundleId?: string }): string | undefined {
	if (!delta.ref) return undefined;
	if (delta.ref.startsWith("@r")) return delta.ref;
	for (const record of records.values()) {
		if (record.nativeWindowRef === delta.ref || record.ref === delta.ref) return record.ref;
	}
	const matchesOwner = owner?.pid === delta.pid;
	return storeRootRef({
		appName: matchesOwner ? owner.appName : "Unknown App",
		bundleId: matchesOwner ? owner.bundleId : undefined,
		pid: delta.pid,
		windowTitle: delta.title ?? "(untitled)",
		nativeWindowRef: delta.ref,
		framePoints: { x: 0, y: 0, w: 1, h: 1 },
		scaleFactor: 1,
		isMinimized: false,
		isOnscreen: true,
		isMain: false,
		isFocused: delta.change === "focused",
	}).ref;
}

export function clearRootRefs(): void {
	records.clear();
	refByIdentity.clear();
	nextIndex = 1;
}
