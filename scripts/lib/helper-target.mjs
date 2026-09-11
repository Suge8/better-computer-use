// Single source of truth for how the macOS helper is compiled and identified:
// build-native.mjs builds with it, check-native.mjs typechecks with it, and
// setup-helper.mjs stamps the installed bundle with it.
export const HELPER_BUNDLE_ID = "com.sugeh.bcu";
export const MACOS_DEPLOYMENT_TARGET = "14.0";
export const HELPER_FRAMEWORKS = ["ApplicationServices", "AppKit", "ScreenCaptureKit", "Foundation", "SwiftUI"];
export const HELPER_SOURCE_FILES = ["agent_cursor.swift", "agent_cursor_motion.swift", "bridge.swift"];

const ARCH_TRIPLES = {
	arm64: "arm64-apple-macosx",
	x64: "x86_64-apple-macosx",
};

export function helperTargetTriple(arch) {
	const prefix = ARCH_TRIPLES[arch];
	if (!prefix) throw new Error(`Unsupported architecture '${arch}'. Supported: ${Object.keys(ARCH_TRIPLES).join(", ")}.`);
	return `${prefix}${MACOS_DEPLOYMENT_TARGET}`;
}
