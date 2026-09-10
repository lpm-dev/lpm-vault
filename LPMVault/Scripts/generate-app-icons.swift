#!/usr/bin/env swift
import AppKit
import Foundation

struct IconCatalog: Decodable {
	struct Icon: Decodable {
		let filename: String
		let size: String
		let scale: String
	}
	let images: [Icon]
}

enum IconGenerationError: Error {
	case invalidArtwork
	case invalidIconSize(String)
	case renderingFailed(Int)
	case iconutilFailed(Int32)
}

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = project.appendingPathComponent("Sources/Resources")
let catalogURL = project.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
let catalog = try JSONDecoder().decode(
	IconCatalog.self,
	from: Data(contentsOf: catalogURL.appendingPathComponent("Contents.json"))
)
guard let logo = NSImage(contentsOf: resources.appendingPathComponent("lpm-vault.svg")),
	logo.isValid, logo.size.width == logo.size.height
else { throw IconGenerationError.invalidArtwork }

let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporaryDirectory.appendingPathComponent("LPMVault.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

for icon in catalog.images {
	let dimensions = icon.size.split(separator: "x")
	guard dimensions.count == 2, dimensions[0] == dimensions[1],
		let points = Int(dimensions[0]), let scale = Int(icon.scale.dropLast()),
		icon.scale.hasSuffix("x"), points > 0, scale > 0
	else { throw IconGenerationError.invalidIconSize(icon.filename) }
	let pixels = points * scale
	guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
		let context = CGContext(
			data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
			space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)
	else { throw IconGenerationError.renderingFailed(pixels) }
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
	logo.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
	NSGraphicsContext.restoreGraphicsState()
	guard let image = context.makeImage(),
		let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
	else { throw IconGenerationError.renderingFailed(pixels) }
	try png.write(to: catalogURL.appendingPathComponent(icon.filename), options: .atomic)
	try png.write(to: iconset.appendingPathComponent(icon.filename), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("LPMVault.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { throw IconGenerationError.iconutilFailed(iconutil.terminationStatus) }
print("Generated \(catalog.images.count) app icons and LPMVault.icns from lpm-vault.svg")
