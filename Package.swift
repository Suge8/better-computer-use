// swift-tools-version: 6.2
import PackageDescription

// Targets and directory ownership follow docs/adr/0002-single-swift-process.md:
// BCUCore is pure logic, BCURuntime the daemon and client core without platform calls,
// BCUPlatform everything that touches AppKit, Accessibility, capture and input, and
// `bridge` the helper executable until the runtime switch folds it into `bcu`.
let package = Package(
	name: "bcu",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "BCUCore", targets: ["BCUCore"]),
		.executable(name: "bridge", targets: ["bridge"]),
	],
	targets: [
		.target(name: "BCUCore"),
		.target(name: "BCURuntime", dependencies: ["BCUCore"]),
		.target(name: "BCUPlatform", dependencies: ["BCUCore"]),
		.executableTarget(name: "bridge", dependencies: ["BCUPlatform"]),
		.testTarget(name: "BCUCoreTests", dependencies: ["BCUCore"], exclude: ["Golden"]),
		.testTarget(name: "BCURuntimeTests", dependencies: ["BCURuntime"]),
		.testTarget(name: "BCUPlatformTests", dependencies: ["BCUPlatform"]),
	]
)
