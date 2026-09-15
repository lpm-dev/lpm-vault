// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "LPMVault",
	platforms: [
		.macOS(.v14),
	],
	dependencies: [
		.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
	],
	targets: [
		.executableTarget(
			name: "LPMVault",
			dependencies: [.product(name: "Sparkle", package: "Sparkle")],
			path: "Sources",
			resources: [
				.process("Assets.xcassets"),
				.copy("Resources"),
			]
		),
		.testTarget(
			name: "LPMVaultTests",
			dependencies: ["LPMVault"],
			path: "Tests",
			exclude: ["Fixtures"]
		),
	]
)
