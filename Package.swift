// swift-tools-version: 6.0

import PackageDescription

/// Built by scripts/libvim.sh from the libvim submodule; SwiftPM only links it.
let libvimDirectory = Context.packageDirectory + "/Vendor/build"

let package = Package(
	name: "kumiko",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "KumikoApp", targets: ["KumikoApp"]),
		.executable(name: "kumiko", targets: ["KumikoCLI"]),
	],
	dependencies: [
		.package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
		.package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.30.0"),
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
		.target(
			name: "CLibvim",
			linkerSettings: [
				.unsafeFlags(["-L\(libvimDirectory)"]),
				.linkedLibrary("vim"),
				.linkedLibrary("ncurses"),
				.linkedLibrary("iconv"),
				.linkedFramework("Carbon"),
				.linkedFramework("Cocoa"),
			]
		),
		.target(
			name: "KumikoVim",
			dependencies: ["KumikoCore", "CLibvim"]
		),
		.target(
			name: "KumikoMenuBar",
			dependencies: ["KumikoCore"]
		),
		.target(
			name: "KumikoBar",
			dependencies: ["KumikoCore", "KumikoWM"]
		),
		.executableTarget(
			name: "KumikoApp",
			dependencies: [
				"KumikoCore", "KumikoWM", "KumikoHotkeys", "KumikoBorders", "KumikoBar", "KumikoMenuBar", "KumikoVim",
				.product(name: "Sentry", package: "sentry-cocoa"),
			]
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
		.testTarget(
			name: "KumikoVimTests",
			dependencies: ["KumikoVim"]
		),
	]
)
