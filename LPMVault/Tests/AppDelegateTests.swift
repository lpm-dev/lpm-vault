import AppKit
import SwiftUI
import Testing
import Vision

@testable import LPMVault

@Suite("App lifecycle security")
@MainActor
struct AppDelegateTests {
	@Test("activity mask includes active input and excludes passive movement")
	func activityEventClassification() {
		let mask = AppDelegate.userActivityEvents

		for event in [
			NSEvent.EventType.keyDown,
			.leftMouseDown,
			.rightMouseDown,
			.otherMouseDown,
			.scrollWheel,
			.gesture,
			.magnify,
			.rotate,
			.swipe,
		] {
			#expect(mask.contains(NSEvent.EventTypeMask(rawValue: 1 << event.rawValue)))
		}
		#expect(!mask.contains(.mouseMoved))
		#expect(!mask.contains(.keyUp))
	}

	@Test("security state changes lock synchronously")
	func securityStateChangeLocksSynchronously() {
		let delegate = AppDelegate()
		var lockCount = 0
		delegate.lockVault = { lockCount += 1 }

		delegate.handleSecurityStateChange()

		#expect(lockCount == 1)
	}

	@Test("security state changes before wiring are applied when the lock handler arrives")
	func earlySecurityStateChangeIsNotLost() {
		let delegate = AppDelegate()
		var lockCount = 0

		delegate.handleSecurityStateChange()
		#expect(lockCount == 0)

		delegate.lockVault = { lockCount += 1 }
		#expect(lockCount == 1)
	}
}

@Suite("App branding")
@MainActor
struct AppBrandingTests {
	@Test("native app icon includes the logo at all macOS resolutions")
	func nativeIconContainsArtwork() throws {
		let fallbackSizes = Set(VaultBranding.appIcon.representations.map(\.pixelsWide))
		#expect(fallbackSizes == [16, 32, 64, 128, 256, 512, 1024])
		var icons = [VaultBranding.appIcon]
		#if !SWIFT_PACKAGE
		#expect(Bundle.main.infoDictionary?["CFBundleIconFile"] as? String == "AppIcon")
		// Xcode stores larger system icon renditions in Assets.car.
		let iconURL = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
		icons.append(try #require(NSImage(contentsOf: iconURL)))
		#endif
		for icon in icons {
			let representations = icon.representations.compactMap { $0 as? NSBitmapImageRep }
			#expect(!representations.isEmpty)
			for bitmap in representations {
				#expect(bitmap.pixelsWide == bitmap.pixelsHigh)
				try expectLogo(in: bitmap)
			}
		}
	}

	@Test("asset catalog icons preserve the artwork at their declared sizes")
	func catalogIconsContainArtwork() throws {
		struct Catalog: Decodable {
			struct Icon: Decodable {
				let filename: String
				let size: String
				let scale: String
			}
			let images: [Icon]
		}
		let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
		let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL.appendingPathComponent("Contents.json")))
		#expect(catalog.images.count == 10)
		for icon in catalog.images {
			let points = try #require(Int(icon.size.split(separator: "x")[0]))
			let scale = try #require(Int(icon.scale.dropLast()))
			let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: catalogURL.appendingPathComponent(icon.filename))))
			#expect(bitmap.pixelsWide == points * scale)
			#expect(bitmap.pixelsHigh == points * scale)
			try expectLogo(in: bitmap)
		}
	}

	@Test("title bar shows the full app name alongside the selected project")
	func titleBarShowsFullAppName() throws {
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil }
		)
		let project = VaultProject(id: "branding-test", name: "project-source", path: "/tmp/project-source", environments: ["default": [:]])
		store.projects = [project]
		store.selectedProjectId = project.id
		let image = try renderNative(VaultTitleBarView(
			store: store, mode: .matrix, onShowVaultID: {}, onPull: {}, onPush: {}
		).environment(\.colorScheme, .light), size: CGSize(width: 1100, height: VaultMetrics.titleBar))
		Attachment.record(image, named: "title-bar", as: .png)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		try VNImageRequestHandler(cgImage: image).perform([request])
		let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
		#expect(text.contains("LPM Vault"))
		#expect(text.contains("project-source"))
	}

	@Test("branded lock screen retains the authentication instructions")
	func lockScreenRetainsAuthenticationInstructions() throws {
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil }
		)
		let image = try renderNative(ContentView(store: store)
			.environment(\.colorScheme, .light), size: CGSize(width: 1040, height: 640))
		Attachment.record(image, named: "lock-screen", as: .png)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		try VNImageRequestHandler(cgImage: image).perform([request])
		let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
		#expect(text.contains("LPM Vault is Locked"))
		#expect(text.contains("Authenticate with Touch ID or your Mac password to unlock."))
	}

	@Test("app marks preserve the logo artwork and colors at every UI size", arguments: [16.0, 20.0, 42.0, 56.0])
	func appMarkRendersArtwork(size: Double) throws {
		let renderer = ImageRenderer(content: VaultAppMark(size: size).foregroundStyle(.red))
		renderer.scale = 2
		let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
		#expect(bitmap.pixelsWide == Int(size * 2))
		#expect(bitmap.pixelsHigh == Int(size * 2))
		try expectLogo(in: bitmap)
	}

	private func renderNative<V: View>(_ view: V, size: CGSize) throws -> CGImage {
		let hostingView = NSHostingView(rootView: view)
		hostingView.frame = NSRect(origin: .zero, size: size)
		hostingView.layoutSubtreeIfNeeded()
		let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
		hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
		return try #require(bitmap.cgImage)
	}

	private func expectLogo(in bitmap: NSBitmapImageRep) throws {
		let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
		#expect(abs(center.redComponent - 93.0 / 255) < 0.03)
		#expect(abs(center.greenComponent - 66.0 / 255) < 0.03)
		#expect(abs(center.blueComponent - 197.0 / 255) < 0.03)
		let frame = try #require(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * 0.23), y: bitmap.pixelsHigh / 2))
		#expect(frame.redComponent > 0.95)
		#expect(frame.greenComponent > 0.95)
		#expect(frame.blueComponent > 0.95)
		let corner = try #require(bitmap.colorAt(x: 0, y: 0))
		#expect(corner.alphaComponent == 0)
	}
}
