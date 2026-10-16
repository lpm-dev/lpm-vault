import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Quit protection rendering", .serialized)
	@MainActor
	struct QuitProtectionRenderingTests {
		private func makeStore() async throws -> (VaultStore, MockKeychainService) {
			let keychain = MockKeychainService()
			keychain.envStorage["demo"] = (name: "demo-api", path: "", environments: ["default": ["TOKEN": "one", "PORT": "80"]])
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			#expect(await store.loadProjects())
			store.isUnlocked = true
			#expect(await store.openProjectForSaving("demo"))
			return (store, keychain)
		}

		@Test("⌘Q's hint reads Press ⌘Q again to quit, or Hold ⌘Q to quit, and goes when hidden")
		func hud() async throws {
			RenderedText.requireUISuite()
			let controller = VaultQuitHUDController()
			controller.show(.pressAgain)
			let panel = try #require(controller.panel)
			#expect(panel.isVisible)
			#expect(panel.ignoresMouseEvents)
			try await Task.sleep(for: .milliseconds(300))
			let content = try #require(panel.contentView)
			let pressText = try await RenderedText.strings(in: try snapshot(content)).joined(separator: " ")
			#expect(OCRText(pressText).contains("again to quit"), "Read: \(pressText)")
			controller.show(.hold(1))
			try await Task.sleep(for: .milliseconds(300))
			let holdText = try await RenderedText.strings(in: try snapshot(content)).joined(separator: " ")
			#expect(OCRText(holdText).contains("to quit") && holdText.contains("Hold"), "Read: \(holdText)")
			controller.hide()
			#expect(!controller.isShowing)
			try await Task.sleep(for: .milliseconds(450))
			#expect(!panel.isVisible)
			controller.show(.pressAgain)
			controller.hide()
			try await Task.sleep(for: .milliseconds(50))
			#expect(!panel.isVisible, "A hint hidden before it appears never shows")
		}

		@Test("the quit sheet lists unsaved edits with Save and quit, and saving quits")
		func sheetSaves() async throws {
			let (store, keychain) = try await makeStore()
			defer { store.lock() }
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			var replies: [Bool] = []
			let coordinator = VaultQuitCoordinator(store: store, presenter: RecordingQuitPresenter(), reply: { replies.append($0) },
				terminate: { replies.append(true) })
			#expect(coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
			let host = SheetTestHost(VaultQuitSheet(coordinator: coordinator), size: NSSize(width: 480, height: 330))
			defer { host.window.close() }
			#expect(try await host.waitForText("Quit with unsaved changes?"))
			#expect(try await host.waitForText("demo-api"))
			#expect(try await host.waitForText("Discard all"))
			try await host.click("Save and quit")
			#expect(try await host.waitUntil { replies == [true] })
			#expect(keychain.envStorage["demo"]?.environments["default"]?["TOKEN"] == "two")
		}

		@Test("a failed save shows what wasn't saved, with Retry and Quit anyway")
		func sheetFailure() async throws {
			let (store, keychain) = try await makeStore()
			defer { store.lock() }
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			var replies: [Bool] = []
			let coordinator = VaultQuitCoordinator(store: store, presenter: RecordingQuitPresenter(), reply: { replies.append($0) },
				terminate: { replies.append(true) })
			#expect(coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
			let host = SheetTestHost(VaultQuitSheet(coordinator: coordinator), size: NSSize(width: 480, height: 400))
			defer { host.window.close() }
			#expect(try await host.waitForText("Save and quit"))
			keychain.failNextSaveEnvironments = true
			coordinator.saveAndQuit()
			#expect(try await host.waitUntil { coordinator.phase == .failed })
			#expect(try await host.waitForText("save failed"))
			#expect(try await host.waitForText("Not saved"))
			#expect(try await host.waitForText("Quit anyway"))
			// The button, not the callout that also says Retry.
			try await host.click("Retry", region: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.2))
			#expect(try await host.waitUntil { replies == [true] })
		}

		@Test("the sheet attaches to the app's window, or to a sheet already open on it")
		func presenterStacksOnSheets() async throws {
			let (store, _) = try await makeStore()
			defer { store.lock() }
			let host = SheetTestHost(Color.clear.frame(width: 600, height: 400), size: NSSize(width: 600, height: 400))
			defer { host.window.close() }
			host.window.orderFront(nil)
			let previous = VaultMainWindow.current
			VaultMainWindow.current = host.window
			defer { VaultMainWindow.current = previous }
			let presenter = VaultQuitSheetPresenter()
			let coordinator = VaultQuitCoordinator(store: store, presenter: presenter, terminate: {})
			#expect(presenter.present(coordinator))
			#expect(try await host.waitUntil { host.window.attachedSheet === presenter.sheet })
			presenter.dismiss()
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })

			let open = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
			host.window.beginSheet(open) { _ in }
			defer { host.window.endSheet(open) }
			#expect(presenter.present(coordinator))
			#expect(try await host.waitUntil { open.attachedSheet === presenter.sheet })
			presenter.dismiss()
		}

		@Test("Settings' General tab chooses the quit shortcut, Double press by default")
		func generalPane() async throws {
			let domain = "quit-settings-ui-\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let settings = VaultQuitSettings(defaults: defaults)
			let host = SheetTestHost(VaultGeneralSettingsPane().environment(settings),
				size: NSSize(width: 520, height: 120), keepsRequestedSize: true)
			defer { host.window.close() }
			// Recognition drops the ⌘ glyph.
			#expect(try await host.waitForText("Q twice."))
			let picker = try #require(segmentedControl(in: host.view))
			#expect((0..<picker.segmentCount).map { picker.label(forSegment: $0) } == ["Direct", "Double press", "Hold"])
			#expect(picker.selectedSegment == 1)
			picker.selectedSegment = 2
			#expect(picker.sendAction(picker.action, to: picker.target))
			#expect(settings.selection == .hold)
			#expect(VaultQuitShortcut.saved(in: defaults) == .hold)
			#expect(try await host.waitForText("or press it twice."))
		}

		@Test("the lock screen offers Settings, and the Account page points to it")
		func settingsEntryPoints() async throws {
			let (store, _) = try await makeStore()
			store.lock()
			let host = SheetTestHost(ContentView(store: store), size: NSSize(width: 1040, height: 640), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			let image = try host.snapshot(host.view)
			let scale = CGFloat(image.width) / host.view.bounds.width
			let gear = CGRect(x: host.view.bounds.width - 14 - 27, y: 14, width: 27, height: 27)
			#expect(try inkedPixels(in: image, rect: gear, scale: scale, flippedHeight: host.view.bounds.height) > 40,
				"The Settings button sits 14 points in from the lock screen's bottom-right corner")

			let account = SheetTestHost(AuthStatusView(store: store), size: NSSize(width: 700, height: 640), keepsRequestedSize: true)
			defer { account.window.close() }
			#expect(try await account.waitForText("Account"))
			#expect(try await account.waitForText("APP SETTINGS"))
			#expect(try await account.waitForText("Open Settings"))
		}

		private func snapshot(_ view: NSView) throws -> CGImage {
			view.layoutSubtreeIfNeeded()
			let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
			view.cacheDisplay(in: view.bounds, to: bitmap)
			return try #require(bitmap.cgImage)
		}

		private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
			if let control = view as? NSSegmentedControl { return control }
			return view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
		}

		/// Pixels in `rect`, in points from the bottom-left, that differ from the corner's background.
		private func inkedPixels(in image: CGImage, rect: CGRect, scale: CGFloat, flippedHeight: CGFloat) throws -> Int {
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
				bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let background = ((image.height - 2) * image.width + image.width - 2) * 4
			var count = 0
			for row in Int((flippedHeight - rect.maxY) * scale)..<Int((flippedHeight - rect.minY) * scale) {
				for column in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
					let pixel = (row * image.width + column) * 4
					if (0..<3).reduce(0, { $0 + abs(Int(pixels[pixel + $1]) - Int(pixels[background + $1])) }) > 30 { count += 1 }
				}
			}
			return count
		}
	}
}
