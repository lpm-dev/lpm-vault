import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	/// The workspace's confirmations and name prompts: what each asks, what it
	/// names in its card, and which keys answer it.
	@Suite("Confirmation dialogs", .serialized)
	@MainActor
	struct ConfirmDialogTests {
		private struct Fixture {
			let store: VaultStore
			let keychain: MockKeychainService

			@MainActor func tearDown() {
				store.lock()
				store.clipboard.pasteboard.releaseGlobally()
			}
		}

		private func makeFixture() -> Fixture {
			let keychain = MockKeychainService()
			let environments = ["default": ["TOKEN": "a"], "staging": ["TOKEN": "b", "EXTRA": "c"]]
			let project = VaultProject(id: "demo", name: "demo-api", path: "/tmp/demo-api", environments: environments)
			keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil }, clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			return Fixture(store: store, keychain: keychain)
		}

		private func workspace(_ store: VaultStore) async throws -> SheetTestHost<some View> {
			let defaults = try #require(UserDefaults(suiteName: "confirm-dialogs"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1200, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["demo"] != nil })
			try await host.settle()
			return host
		}

		/// The context menu of the sidebar row saying `name`.
		private func rowMenu<V: View>(_ name: String, in host: SheetTestHost<V>) async throws -> NSMenu {
			let row = try await host.waitForElement(saying: name, region: CGRect(x: 0, y: 0, width: 0.26, height: 1))
			let point = AccessibilityTree.center(of: row, in: host.window)
			let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
				eventNumber: 0, clickCount: 1, pressure: 1))
			let target = try #require(host.view.hitTest(host.view.superview?.convert(point, from: nil) ?? point))
			return try #require(target.menu(for: event) ?? host.view.menu(for: event), "\(name) has a context menu")
		}

		private func choose<V: View>(_ title: String, fromRow row: String, in host: SheetTestHost<V>) async throws -> NSWindow {
			let menu = try await rowMenu(row, in: host)
			let index = try #require(menu.items.firstIndex { $0.title == title }, "Missing \(title)")
			menu.performActionForItem(at: index)
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "\(title) asks first")
			return try #require(host.window.sheets.first)
		}

		/// Presses `key` in `sheet` as its buttons' shortcuts hear it; returns whether one took it.
		private func press(_ key: String, code: UInt16, in sheet: NSWindow) throws -> Bool {
			let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
				characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
			return sheet.performKeyEquivalent(with: event)
		}

		private func pressReturn(in sheet: NSWindow) throws -> Bool { try press("\r", code: 36, in: sheet) }

		/// Presses Return in the field being edited, which submits it. The key goes
		/// to the field's editor as a key press does: macOS 15 submits a field only
		/// through the key's command, not when its editor inserts a newline directly.
		private func submitField(in sheet: NSWindow) throws {
			let editor = try #require(sheet.firstResponder as? NSTextView, "A field is being edited")
			let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
				characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
			editor.keyDown(with: event)
		}

		private func isEnabled(_ title: String, in sheet: NSWindow) -> Bool {
			guard let content = sheet.contentView else { return false }
			return AccessibilityTree.visibleElements(in: sheet, of: content).first { $0.role == .button && $0.says(title) }?.isEnabledNow == true
		}
		private func pressEscape(in sheet: NSWindow) throws -> Bool { try press("\u{1b}", code: 53, in: sheet) }

		@Test("Delete Locally asks a short question, names the project and its folder in a card, ignores Return, and deletes on its button")
		func deleteProjectLocally() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let sheet = try await choose("Delete Locally…", fromRow: "demo-api", in: host)
			#expect(try await host.waitForText("Delete this project locally?", exactly: true, in: sheet))
			#expect(try await host.waitForText("Its folder, its lpm.json and a synced cloud copy stay.", in: sheet))
			#expect(try await host.waitForText("demo-api", in: sheet))
			#expect(try await host.waitForText("/tmp/demo-api", in: sheet))
			_ = try pressReturn(in: sheet)
			try await host.settle()
			#expect(fixture.keychain.envStorage["demo"] != nil && host.window.sheets.first === sheet, "Return never deletes")
			try await host.click("Delete Locally", in: sheet)
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"] == nil })
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
		}

		@Test("Esc cancels a destructive question and leaves everything as it was")
		func escapeCancels() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let sheet = try await choose("Delete Environment", fromRow: ".env.staging", in: host)
			#expect(try await host.waitForText("Delete this environment?", exactly: true, in: sheet))
			#expect(try pressEscape(in: sheet))
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			try await host.settle()
			#expect(fixture.store.projects.first?.environments["staging"] != nil)
		}

		@Test("Delete Environment names the environment, its keys and its project, and deletes only it")
		func deleteEnvironment() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let sheet = try await choose("Delete Environment", fromRow: ".env.staging", in: host)
			#expect(try await host.waitForText(".env.staging", in: sheet))
			#expect(try await host.waitForText("2 keys · demo-api", in: sheet))
			try await host.click("Delete Environment", in: sheet)
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"]?.environments["staging"] == nil })
			#expect(fixture.keychain.envStorage["demo"]?.environments["default"] == ["TOKEN": "a"])
		}

		@Test("Clear All Secrets empties the environment and keeps it")
		func clearEnvironment() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let sheet = try await choose("Clear All Secrets", fromRow: ".env.staging", in: host)
			#expect(try await host.waitForText("Clear every key from this environment?", exactly: true, in: sheet))
			#expect(try await host.waitForText("the environment stays, empty", in: sheet))
			try await host.click("Clear All Secrets", in: sheet)
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"]?.environments["staging"] == [:] })
		}

		@Test("deleting a key from an environment names the key and where it is, and changes only that environment")
		func deleteKey() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			try await host.click(".env", region: CGRect(x: 0, y: 0, width: 0.26, height: 1))
			try await host.click("Delete from this environment")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Delete this key?", exactly: true, in: sheet))
			#expect(try await host.waitForText("TOKEN", in: sheet))
			#expect(try await host.waitForText(".env · demo-api", in: sheet))
			try await host.click("Delete Key", in: sheet)
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"]?.environments["default"]?["TOKEN"] == nil })
			#expect(fixture.keychain.envStorage["demo"]?.environments["staging"]?["TOKEN"] == "b")
		}

		@Test("Rename says why a taken name can't be used, keeps Rename off, and renames on Return once the name is free")
		func renameEnvironment() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let sheet = try await choose("Rename…", fromRow: ".env.staging", in: host)
			#expect(try await host.waitForText("Rename .env.staging", exactly: true, in: sheet))
			#expect(try await !host.text(in: sheet).contains("already exists"), "The environment's own name isn't taken")
			try host.typeText("default", placeholder: "Environment name", in: sheet)
			#expect(try await host.waitForText("That environment already exists.", in: sheet))
			#expect(try await !host.waitForElement(saying: "Rename", in: sheet).isEnabledNow)
			try host.typeText("qa", placeholder: "Environment name", in: sheet)
			#expect(try await host.waitUntil { isEnabled("Rename", in: sheet) })
			#expect(try await !host.text(in: sheet).contains("already exists"))
			try submitField(in: sheet)
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"]?.environments["qa"] == ["TOKEN": "b", "EXTRA": "c"] })
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
		}

		@Test("Duplicate copies the environment under the name typed")
		func duplicateEnvironment() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let sheet = try await choose("Duplicate…", fromRow: ".env.staging", in: host)
			#expect(try await host.waitForText("Duplicate .env.staging", exactly: true, in: sheet))
			try host.typeText("preview", placeholder: "New environment name", in: sheet)
			#expect(try await host.waitUntil { isEnabled("Duplicate", in: sheet) })
			try await host.click("Duplicate", in: sheet)
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"]?.environments["preview"] == ["TOKEN": "b", "EXTRA": "c"] })
			#expect(fixture.keychain.envStorage["demo"]?.environments["staging"] != nil)
		}

		@Test("an error shows as a warning that Return or Esc acknowledges")
		func errorWarning() async throws {
			let fixture = makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			for (key, code) in [("\r", UInt16(36)), ("\u{1b}", 53)] {
				fixture.store.error = "The Keychain couldn't be read."
				#expect(try await host.waitUntil { host.window.sheets.first != nil })
				let sheet = try #require(host.window.sheets.first)
				#expect(try await host.waitForText("LPM Vault couldn't finish that", exactly: true, in: sheet))
				#expect(try await host.waitForText("The Keychain couldn't be read.", in: sheet))
				#expect(try press(key, code: code, in: sheet))
				#expect(try await host.waitUntil { fixture.store.error == nil && host.window.sheets.isEmpty })
			}
		}
	}
}
