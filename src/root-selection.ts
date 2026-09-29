import type { HelperRoot } from "./macos/protocol.ts";

type RankedRoot = Pick<HelperRoot,
	"windowId" | "rootRef" | "isModal" | "isFocused" | "isMain" | "isMinimized" | "isOnscreen" | "zOrder" | "title"
>;

export function scoreWindow(window: RankedRoot): number {
	let score = 0;
	if (window.isModal) score += 180;
	if (window.isFocused) score += 100;
	if (window.isMain) score += 80;
	if (!window.isMinimized) score += 40;
	if (window.isOnscreen) score += 20;
	if (window.windowId && window.windowId > 0) score += 10;
	if (window.title.trim().length > 0) score += 2;
	return score;
}
