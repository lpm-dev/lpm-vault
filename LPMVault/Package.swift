// swift-tools-version: 5.9

import PackageDescription

let package = Package(
	name: "LPMVault",
	platforms: [
		.macOS(.v14),
	],
	targets: [
		.executableTarget(
			name: "LPMVault",
			path: "Sources",
			resources: [
				.process("Assets.xcassets"),
				.copy("Resources"),
			]
		),
		.testTarget(
			name: "LPMVaultTests",
			dependencies: ["LPMVault"],
			path: "Tests"
		),
	]
)
