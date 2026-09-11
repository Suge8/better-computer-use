import type { FramePoints } from "./macos/protocol.ts";
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

export function clearRootRefs(): void {
	records.clear();
	refByIdentity.clear();
	nextIndex = 1;
}
