// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "kumiko",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "KumikoApp", targets: ["KumikoApp"]),
		.executable(name: "kumiko", targets: ["KumikoCLI"]),
	],
	dependencies: [
		.package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
	],
	targets: [
		.target(
			name: "KumikoCore",
			dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
		),
		.target(
			name: "KumikoWM",
			dependencies: ["KumikoCore"]
		),
		.target(
			name: "KumikoHotkeys",
			dependencies: ["KumikoCore"]
		),
		.target(
			name: "KumikoBorders",
			dependencies: ["KumikoCore"]
		),
		.executableTarget(
			name: "KumikoApp",
			dependencies: ["KumikoCore", "KumikoWM", "KumikoHotkeys", "KumikoBorders"]
		),
		// The product is called `kumiko`, the target is not: macOS file systems are case-insensitive,
		// so a `kumiko` target next to `KumikoApp`'s module would fight over the same build paths.
		.executableTarget(
			name: "KumikoCLI",
			dependencies: ["KumikoCore"]
		),
		.testTarget(
			name: "KumikoCoreTests",
			dependencies: ["KumikoCore"]
		),
		.testTarget(
			name: "KumikoWMTests",
			dependencies: ["KumikoWM"]
		),
		.testTarget(
			name: "KumikoHotkeysTests",
			dependencies: ["KumikoHotkeys"]
		),
	]
)
