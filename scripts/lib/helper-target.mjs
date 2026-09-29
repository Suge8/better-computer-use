// How the macOS helper is identified and where its build lands: build-native.mjs builds the
// SwiftPM `bridge` product into prebuiltHelperPath, and setup-helper.mjs installs it as the
// bundle stamped with these values. The deployment target mirrors `platforms` in Package.swift.
import path from "node:path";

export const HELPER_BUNDLE_ID = "com.sugeh.bcu";
export const MACOS_DEPLOYMENT_TARGET = "14.0";
/** Node's architecture name → SwiftPM's. */
export const SWIFT_ARCHS = { arm64: "arm64", x64: "x86_64" };

export function prebuiltHelperPath(rootDir, arch) {
	return path.join(rootDir, "prebuilt", "macos", arch, "bridge");
}
