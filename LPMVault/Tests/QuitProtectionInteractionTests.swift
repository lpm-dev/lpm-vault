import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Quit protection rendering", .serialized)
	@MainActor
	struct QuitProtectionRenderingTests {
		@MainActor
		final class Outcome {
			var terminations = 0
			var replies: [Bool] = []
		}

		private func makeStore() async throws -> (VaultStore, MockKeychainService) {
			let keychain = MockKeychainService()
			keychain.envStorage["demo"] = (name: "demo-api", path: "", environments: ["default": ["TOKEN": "one", "PORT": "80"]])
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			#expect(await store.loadProjects())
			store.isUnlocked = true
			#expect(await store.openProjectForSaving("demo", timeout: testWaitLimit))
			return (store, keychain)
		}

		/// A window standing in for the app's, with the real presenter attaching the quit sheet to it.
		private func mainWindow() -> (SheetTestHost<some View>, restore: () -> Void) {
			let host = SheetTestHost(Color.clear.frame(width: 640, height: 480), size: NSSize(width: 640, height: 480), keepsRequestedSize: true)
			host.window.orderFront(nil)
			let previous = VaultMainWindow.current
			VaultMainWindow.current = host.window
			return (host, { VaultMainWindow.current = previous })
		}

		private func coordinator(_ store: VaultStore, presenter: some VaultQuitCoordinator.Presenter, outcome: Outcome) -> VaultQuitCoordinator {
			VaultQuitCoordinator(store: store, presenter: presenter, timing: .init(projectLoadLimit: testWaitLimit),
				reply: { outcome.replies.append($0) }, terminate: { outcome.terminations += 1 })
		}

		/// Waits for the presenter's sheet, which starts hidden while the app is
		/// inactive, as a test's always is, then shows it as the app's activation does.
		private func shownSheet(_ presenter: VaultQuitSheetPresenter, on host: SheetTestHost<some View>) async throws -> NSWindow {
			#expect(try await host.waitUntil { presenter.sheet?.sheetParent != nil })
			let sheet = try #require(presenter.sheet)
			#expect(try await host.waitForText("content hidden while the app is inactive", in: sheet))
			NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
			let content = try #require(sheet.contentView)
			#expect(try await host.waitUntil { !AccessibilityTree.text(in: content, root: sheet).contains("content hidden while the app is inactive") })
			return sheet
		}

		/// Sends a key to `window` as its key equivalents see it.
		@discardableResult
		private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) throws -> Bool {
			let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
				characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
			return window.performKeyEquivalent(with: event)
		}

		@Test("⌘Q's hint says Press ⌘Q again to quit once, or Hold ⌘Q to quit, and goes when hidden")
		func hud() async throws {
			UITestSuite.require()
			AccessibilityTree.activate()
			let controller = VaultQuitHUDController()
			controller.show(.pressAgain)
			let panel = try #require(controller.panel)
			let content = try #require(panel.contentView)
			#expect(panel.isVisible)
			#expect(panel.ignoresMouseEvents)
			func says(_ expected: [String]) async throws -> Bool {
				try await waitUntil { AccessibilityTree.strings(in: content) == expected }
			}
			#expect(try await says(["Press ⌘Q again to quit"]), "The keycap isn't read as well: \(AccessibilityTree.strings(in: content))")
			controller.show(.hold(1))
			#expect(try await says(["Hold ⌘Q to quit"]))
			controller.hide()
			#expect(!controller.isShowing)
			#expect(try await waitUntil { !panel.isVisible })
			controller.show(.pressAgain)
			controller.hide()
			try await quietPeriod()
			#expect(!panel.isVisible, "A hint hidden before it appears never shows")
		}

		@Test("the hold ring's track shows against the hint in light and dark", arguments: [NSAppearance.Name.aqua, .darkAqua])
		func holdRingShows(appearance: NSAppearance.Name) async throws {
			let hud = VaultQuitHUD(hint: .hold(60), visible: true)
			let host = SheetTestHost(hud, size: NSHostingView(rootView: hud).fittingSize, keepsRequestedSize: true)
			defer { host.window.close() }
			host.view.appearance = NSAppearance(named: appearance)
			try await host.settle()
			let image = try host.snapshot(host.view)
			let scale = CGFloat(image.width) / host.view.bounds.width
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
				space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			func color(atX x: CGFloat, y: CGFloat) -> [Int] {
				let column = Int(x * scale), row = Int((host.view.bounds.height - y) * scale)
				let pixel = (row * image.width + column) * 4
				return (0..<3).map { Int(pixels[pixel + $0]) }
			}
			// The ring is 16 points across, 12 points in from the hint's leading edge.
			let center = CGPoint(x: VaultQuitHUDController.shadowMargin + 12 + 8, y: host.view.bounds.height / 2)
			let fill = color(atX: center.x, y: center.y)
			let track = color(atX: center.x - 7, y: center.y)
			let contrast = zip(fill, track).reduce(0) { $0 + abs($1.0 - $1.1) }
			#expect(contrast > 40, "The ring's track is \(track), on \(fill)")
		}

		@Test("the quit sheet lists unsaved edits, Save and quit saves and quits, and its title reads as a heading")
		func sheetSaves() async throws {
			let (store, keychain) = try await makeStore()
			defer { store.lock() }
			let (host, restore) = mainWindow()
			defer { host.window.close(); restore() }
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			let outcome = Outcome()
			let presenter = VaultQuitSheetPresenter()
			let coordinator = coordinator(store, presenter: presenter, outcome: outcome)
			#expect(coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
			let sheet = try await shownSheet(presenter, on: host)
			#expect(host.window.attachedSheet === sheet)
			#expect(sheet.title == "Quit LPM Vault")
			#expect(try await host.waitForText("Quit with unsaved changes?", in: sheet))
			#expect(try await host.waitForElement(saying: "Quit with unsaved changes?", in: sheet).role?.rawValue == "AXHeading")
			#expect(try await host.waitForText("demo-api · 1 key", in: sheet))
			#expect(!(try await host.text(in: sheet).contains("folder")), "The row's symbol isn't read")
			#expect(try await host.waitForText("Discard all", in: sheet))
			try await host.click("Save and quit", in: sheet)
			#expect(try await host.waitUntil { outcome.terminations == 1 })
			#expect(keychain.envStorage["demo"]?.environments["default"]?["TOKEN"] == "two")
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
		}

		@Test("Return saves and quits, Escape cancels, and ⌘⌫ discards", arguments: ["return", "escape", "discard"])
		func keyboard(key name: String) async throws {
			let (store, keychain) = try await makeStore()
			defer { store.lock() }
			let (host, restore) = mainWindow()
			defer { host.window.close(); restore() }
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			let outcome = Outcome()
			let presenter = VaultQuitSheetPresenter()
			let coordinator = coordinator(store, presenter: presenter, outcome: outcome)
			_ = coordinator.shouldTerminate(sessionEnding: false)
			let sheet = try await shownSheet(presenter, on: host)
			#expect(try await host.waitForText("Save and quit", in: sheet))
			switch name {
			case "return": try key("\r", code: 36, to: sheet)
			case "escape": try key("\u{1b}", code: 53, to: sheet)
			default:
				// The Delete key's event as macOS makes it: U+007F, sent through the application.
				let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
					timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
					characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
				NSApp.sendEvent(event)
			}
			#expect(try await host.waitUntil { !coordinator.isQuitting })
			switch name {
			case "return":
				#expect(outcome.terminations == 1)
				#expect(keychain.envStorage["demo"]?.environments["default"]?["TOKEN"] == "two")
			case "escape":
				#expect(outcome.terminations == 0)
				#expect(store.keyDrafts.editedKeys(in: "demo") == ["TOKEN"], "Cancel keeps the edit")
			default:
				#expect(outcome.terminations == 1)
				#expect(keychain.envStorage["demo"]?.environments["default"]?["TOKEN"] == "one", "Discard all saves nothing")
			}
		}

		@Test("a failed save shows its real reason on its row, keeps the review warning, and Retry finishes")
		func failureWithReview() async throws {
			let (store, keychain) = try await makeStore()
			defer { store.lock() }
			let (host, restore) = mainWindow()
			defer { host.window.close(); restore() }
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			store.keyDrafts.edit(project, key: "PORT") { $0.setValue("81", in: "default") }
			var changed = project
			changed.environments["default"]?["PORT"] = "changed-by-cli"
			store.projects = store.projects.map { $0.id == project.id ? changed : $0 }
			let outcome = Outcome()
			let presenter = VaultQuitSheetPresenter()
			let coordinator = coordinator(store, presenter: presenter, outcome: outcome)
			_ = coordinator.shouldTerminate(sessionEnding: false)
			let sheet = try await shownSheet(presenter, on: host)
			#expect(try await host.waitForText("1 key needs review", in: sheet))
			keychain.nextVaultTransactionError = .unexpectedStatus(-25293)
			try await host.click("Save and quit", in: sheet)
			#expect(try await host.waitUntil { coordinator.phase == .failed })
			let reason = VaultKeyEditError.persistence(KeychainError.unexpectedStatus(-25293).description).localizedDescription
			#expect(try await host.waitForText("TOKEN couldn't be saved: \(reason)", in: sheet), "The row says the Keychain's reason")
			#expect(try await host.waitForText("One save failed", in: sheet))
			#expect(try await host.waitForText("Edits that need a review are discarded too.", in: sheet))
			#expect(!(try await host.text(in: sheet).contains("Your other edits are saved")))
			#expect(try await host.waitForText("0 of 1 saved.", in: sheet))
			try await host.click("Retry", in: sheet)
			#expect(try await host.waitUntil { outcome.terminations == 1 })
			#expect(keychain.envStorage["demo"]?.environments["default"]?["TOKEN"] == "two")
		}

		@Test("saving shows a progress bar, and rows not yet saved say they're waiting")
		func savingShowsProgress() async throws {
			let (store, keychain) = try await makeStore()
			defer { store.lock() }
			let (host, restore) = mainWindow()
			defer { host.window.close(); restore() }
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			let outcome = Outcome()
			let presenter = VaultQuitSheetPresenter()
			let coordinator = coordinator(store, presenter: presenter, outcome: outcome)
			_ = coordinator.shouldTerminate(sessionEnding: false)
			let sheet = try await shownSheet(presenter, on: host)
			let gate = KeychainWriteGate()
			gate.hold(keychain)
			try await host.click("Save and quit", in: sheet)
			#expect(try await host.waitUntil { gate.isHolding })
			let progress = try #require(AccessibilityTree.elements(in: sheet).first { $0.role == .progressIndicator }, "The bar reads as progress")
			#expect(progress.texts == ["Saving"])
			#expect(try await host.waitForText("Finishing 1 save before quitting.", in: sheet))
			gate.open()
			#expect(try await host.waitUntil { outcome.terminations == 1 })
		}

		@Test("a quit sheet on a sheet that closes moves to the window, instead of going with it")
		func presenterFollowsClosingParent() async throws {
			let (store, _) = try await makeStore()
			defer { store.lock() }
			let (host, restore) = mainWindow()
			defer { host.window.close(); restore() }
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			let open = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
			host.window.beginSheet(open) { _ in }
			let presenter = VaultQuitSheetPresenter()
			let coordinator = coordinator(store, presenter: presenter, outcome: Outcome())
			_ = coordinator.shouldTerminate(sessionEnding: false)
			#expect(try await host.waitUntil { open.attachedSheet === presenter.sheet && presenter.sheet != nil })
			host.window.endSheet(open)
			#expect(try await host.waitUntil { host.window.attachedSheet === presenter.sheet && presenter.sheet != nil },
				"The quit sheet is on the window once the sheet under it closes")
			#expect(coordinator.phase == .reviewing)
			coordinator.cancel()
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
		}

		@Test("a minimized window comes back to show the quit sheet, rather than its edits being discarded")
		func presenterBringsBackMinimizedWindow() async throws {
			let (store, _) = try await makeStore()
			defer { store.lock() }
			let (host, restore) = mainWindow()
			defer { host.window.close(); restore() }
			host.window.styleMask.insert(.miniaturizable)
			host.window.miniaturize(nil)
			#expect(try await host.waitUntil { host.window.isMiniaturized })
			let project = try #require(store.projects.first)
			store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") }
			let outcome = Outcome()
			let presenter = VaultQuitSheetPresenter()
			let coordinator = coordinator(store, presenter: presenter, outcome: outcome)
			_ = coordinator.shouldTerminate(sessionEnding: false)
			#expect(try await host.waitUntil { !host.window.isMiniaturized && host.window.attachedSheet === presenter.sheet && presenter.sheet != nil })
			#expect(coordinator.phase == .reviewing)
			#expect(outcome.terminations == 0)
			coordinator.cancel()
		}

		@Test("what's typed into Add variable is listed among what quitting would lose, until it's cleared or closed")
		func addVariableRegistersWork() async throws {
			let (store, _) = try await makeStore()
			defer { store.lock() }
			let host = SheetTestHost(AddVariableSheet(store: store, projectId: "demo", environment: "default"), size: NSSize(width: 560, height: 520))
			try await host.settle()
			#expect(store.openSheetWork.isEmpty, "Nothing typed, nothing to lose")
			try host.typeInFirstField("NEW_KEY")
			#expect(try await host.waitUntil { store.openSheetWork.values.map(\.detail) == ["NEW_KEY"] })
			#expect(store.openSheetWork.values.first?.title == "Add variable")
			#expect(!store.unsavedWork().isEmpty)
			try host.typeInFirstField("")
			#expect(try await host.waitUntil { store.openSheetWork.isEmpty })
			host.window.close()
		}

		@Test("Settings' General card chooses the quit shortcut, Double press by default, and its picker carries the explanation")
		func generalPane() async throws {
			let domain = "quit-settings-ui-\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let settings = VaultQuitSettings(defaults: defaults)
			let host = SheetTestHost(VaultGeneralSettingsSection().environment(settings),
				size: NSSize(width: 520, height: 120), keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitForText(VaultQuitShortcut.doublePress.explanation))
			let segments = AccessibilityTree.elements(in: host.window).filter { $0.role == .radioButton }.compactMap(\.texts.first)
			#expect(segments == ["Direct", "Double press", "Hold"])
			let group = try #require(AccessibilityTree.elements(in: host.window).first { $0.help == VaultQuitShortcut.doublePress.explanation },
				"The picker's hint is the explanation")
			#expect(group.role != .staticText)
			try await host.click("Hold")
			#expect(try await host.waitUntil { settings.selection == .hold })
			#expect(VaultQuitShortcut.saved(in: defaults) == .hold)
			#expect(try await host.waitForText(VaultQuitShortcut.hold.explanation))
		}

		@Test("Settings is a page behind the lock: the lock screen offers no way into it, and the page holds the quit shortcut")
		func settingsBehindTheLock() async throws {
			let (store, _) = try await makeStore()
			store.lock()
			let host = SheetTestHost(ContentView(store: store), size: NSSize(width: 1040, height: 640), keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitForText("Unlock"))
			#expect(!AccessibilityTree.visibleElements(in: host.window, of: host.view).contains { $0.role == .button && $0.says("Settings") })

			let domain = "quit-settings-page-\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let page = SheetTestHost(VaultSettingsPage(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: defaults))
				.environment(VaultQuitSettings(defaults: defaults)), size: NSSize(width: 700, height: 900), keepsRequestedSize: true)
			defer { page.window.close() }
			#expect(try await page.waitForText("Settings", exactly: true))
			#expect(try await page.waitForText("Quit shortcut"))
			#expect(try await !page.text().contains("Open Settings"))
		}

	}
}
