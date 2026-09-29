// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "bcu",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "BCUCore", targets: ["BCUCore"]),
	],
	targets: [
		.target(name: "BCUCore"),
		.testTarget(name: "BCUCoreTests", dependencies: ["BCUCore"], exclude: ["Golden"]),
	]
)
