import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Project settings rendering", .serialized)
	@MainActor
	struct ProjectSettingsRenderingTests {
		private struct Fixture {
			let store: VaultStore
			let keychain: MockKeychainService
			let preferences: UserDefaults
			let domain: String
			let images: URL

			@MainActor func tearDown() {
				store.lock()
				store.clipboard.pasteboard.releaseGlobally()
				preferences.removePersistentDomain(forName: domain)
				try? FileManager.default.removeItem(at: images)
			}
		}

		private func makeFixture(path: String, otherProject: Bool = false) throws -> Fixture {
			let domain = "project-settings-ui-\(UUID().uuidString)"
			let preferences = try #require(UserDefaults(suiteName: domain))
			let images = FileManager.default.temporaryDirectory.appending(path: "project-settings-ui-images-\(UUID().uuidString)", directoryHint: .isDirectory)
			let keychain = MockKeychainService()
			keychain.envStorage["demo"] = (name: "demo-api", path: path, environments: ["default": ["TOKEN": "x"]])
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				preferences: preferences, authTokenProvider: { _, _ in nil }, projectIconsDirectory: images,
				clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			store.projects = [VaultProject(id: "demo", name: "demo-api", path: path, environments: ["default": ["TOKEN": "x"]])]
			if otherProject {
				keychain.envStorage["other"] = (name: "web-dashboard", path: "", environments: ["default": [:]])
				store.projects.append(VaultProject(id: "other", name: "web-dashboard", path: "", environments: ["default": [:]]))
			}
			store.isUnlocked = true
			store.selectedProjectId = "demo"
			return Fixture(store: store, keychain: keychain, preferences: preferences, domain: domain, images: images)
		}

		@Test("Project Settings, opened by the request its ⌘I command posts, shows the detected icon, folder, CLI approval and Delete Locally, and Save renames the project")
		func pageOpensAndSaves() async throws {
			let folder = try ProjectIconFixture.folder()
			defer { try? FileManager.default.removeItem(at: folder) }
			try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "public/favicon.png", in: folder)
			let fixture = try makeFixture(path: folder.path)
			defer { fixture.tearDown() }
			let host = SheetTestHost(ContentView(store: fixture.store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: fixture.preferences)),
				size: NSSize(width: 1100, height: 720), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			NotificationCenter.default.post(name: .showProjectSettings, object: nil)
			#expect(try await host.waitForText("Project Settings"))
			#expect(try await host.waitForText("public/favicon.png"))
			#expect(try await host.waitForText("CLI approval"))
			#expect(try await host.waitForText("Delete Locally"))
			#expect(try await !host.text().contains("Unsaved changes"))
			try host.enterText("renamed-project", placeholder: "Project name")
			#expect(try await host.waitForText("Unsaved changes"))
			try await host.click("Save")
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"]?.name == "renamed-project" })
			#expect(try await host.waitUntil { fixture.store.projectSettingsDrafts.isEmpty })
			#expect(try await host.waitForTextToDisappear("Unsaved changes"))
			try await host.click("All variables")
			#expect(try await host.waitForText("New key", exactly: true))
		}

		@Test("the folder row copies the project's folder path")
		func copiesFolderPath() async throws {
			let folder = try ProjectIconFixture.folder()
			defer { try? FileManager.default.removeItem(at: folder) }
			let fixture = try makeFixture(path: folder.path)
			defer { fixture.tearDown() }
			let host = try await workspace(fixture)
			defer { host.window.close() }
			NotificationCenter.default.post(name: .showProjectSettings, object: nil)
			try await host.click("Copy Path")
			#expect(try await host.waitUntil { fixture.store.clipboard.pasteboard.string(forType: .string) == folder.path })
		}

		private func workspace(_ fixture: Fixture) async throws -> SheetTestHost<some View> {
			let host = SheetTestHost(ContentView(store: fixture.store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: fixture.preferences)),
				size: NSSize(width: 1100, height: 720), keepsRequestedSize: true)
			try await host.settle()
			return host
		}

		/// The context menu of the sidebar row showing `name`.
		private func rowMenu<V: View>(_ name: String, in host: SheetTestHost<V>) async throws -> NSMenu {
			let row = try await host.waitForElement(saying: name, region: CGRect(x: 0, y: 0, width: 0.26, height: 1))
			let point = AccessibilityTree.center(of: row, in: host.window)
			let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
				eventNumber: 0, clickCount: 1, pressure: 1))
			let target = try #require(host.view.hitTest(host.view.superview?.convert(point, from: nil) ?? point))
			return try #require(target.menu(for: event) ?? host.view.menu(for: event), "\(name) has a context menu")
		}

		private func perform(_ title: String, in menu: NSMenu) throws {
			let index = try #require(menu.items.firstIndex { $0.title == title }, "Missing \(title)")
			menu.performActionForItem(at: index)
		}

		private func editingName<V: View>(in host: SheetTestHost<V>) -> Bool {
			((host.window.firstResponder as? NSText)?.delegate as? NSTextField)?.placeholderString == "Project name"
		}

		@Test("only Rename focuses the name; Project Settings opened afterwards doesn't")
		func renameFocusDoesntStick() async throws {
			let fixture = try makeFixture(path: "")
			defer { fixture.tearDown() }
			let host = try await workspace(fixture)
			defer { host.window.close() }
			try perform("Rename…", in: try await rowMenu("demo-api", in: host))
			#expect(try await host.waitUntilRendered { editingName(in: host) })
			try await host.click("All variables")
			#expect(try await host.waitForText("New key", exactly: true))
			host.window.makeFirstResponder(nil)
			NotificationCenter.default.post(name: .showProjectSettings, object: nil)
			#expect(try await host.waitForText("Project Settings"))
			try await host.settle()
			#expect(!editingName(in: host))
		}

		@Test("Project Settings for a project that isn't selected selects it and opens on it")
		func settingsForAnotherProject() async throws {
			let fixture = try makeFixture(path: "", otherProject: true)
			defer { fixture.tearDown() }
			let host = try await workspace(fixture)
			defer { host.window.close() }
			try perform("Project Settings…", in: try await rowMenu("web-dashboard", in: host))
			#expect(try await host.waitUntil { fixture.store.selectedProjectId == "other" })
			#expect(try await host.waitUntil { host.textField(placeholder: "Project name")?.stringValue == "web-dashboard" },
				"The page opens on the project chosen, not the one that was selected")
		}

		@Test("Delete Locally on the page asks to delete its project")
		func pageDeletes() async throws {
			let fixture = try makeFixture(path: "")
			defer { fixture.tearDown() }
			let project = try #require(fixture.store.projects.first)
			var deletes = 0
			let host = SheetTestHost(VaultProjectSettingsView(store: fixture.store, project: project, onBack: {}, onDelete: { deletes += 1 }),
				size: NSSize(width: 820, height: 680), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.click("Delete Locally…")
			#expect(try await host.waitUntil { deletes == 1 })
		}

		@Test("Project Settings for a project that's gone does nothing")
		func settingsForRemovedProject() async throws {
			let fixture = try makeFixture(path: "", otherProject: true)
			defer { fixture.tearDown() }
			let host = try await workspace(fixture)
			defer { host.window.close() }
			let menu = try await rowMenu("web-dashboard", in: host)
			fixture.store.projects.removeAll { $0.id == "other" }
			try perform("Project Settings…", in: menu)
			try await host.settle()
			#expect(fixture.store.selectedProjectId == "demo")
			#expect(try await host.waitForText("New key", exactly: true))
			#expect(try await !host.text().contains("Delete Locally"), "The page didn't open")
		}

		@Test("Revert ends the edits, and Reset shows only while an icon is chosen")
		func revertAndReset() async throws {
			let fixture = try makeFixture(path: "")
			defer { fixture.tearDown() }
			let project = try #require(fixture.store.projects.first)
			let host = SheetTestHost(VaultProjectSettingsView(store: fixture.store, project: project, onBack: {}, onDelete: {}),
				size: NSSize(width: 820, height: 640), keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitForText("Choose icon"))
			#expect(try await !host.text().contains("Reset"))
			fixture.store.editProjectSettings(of: project) {
				$0.name = "renamed"
				$0.icon = .symbol("bolt.fill", .indigo)
			}
			#expect(try await host.waitForText("Unsaved changes"))
			#expect(try await host.waitForText("Reset"))
			#expect(try await host.waitForText("bolt.fill"))
			try await host.click("Revert")
			#expect(try await host.waitUntil { fixture.store.projectSettingsDrafts.isEmpty })
			#expect(try await host.waitForTextToDisappear("Unsaved changes"))
		}

		@Test("a policy that can't be read and a folder that's gone are each said plainly")
		func unreadablePolicyAndMissingFolder() async throws {
			let fixture = try makeFixture(path: "/nonexistent/demo-api")
			defer { fixture.tearDown() }
			let project = try #require(fixture.store.projects.first)
			let host = SheetTestHost(VaultProjectSettingsView(store: fixture.store, project: project, onBack: {}, onDelete: {}),
				size: NSSize(width: 820, height: 680), keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitForText("policy can't be read"))
			#expect(try await host.waitForText("can't be found"))
		}

		@Test("the CLI approval switch can't be changed while the policy can't be read, and can once it can")
		func cliSwitchFollowsPolicy() async throws {
			let fixture = try makeFixture(path: "")
			defer { fixture.tearDown() }
			let project = try #require(fixture.store.projects.first)
			let host = SheetTestHost(VaultProjectSettingsView(store: fixture.store, project: project, onBack: {}, onDelete: {}),
				size: NSSize(width: 820, height: 680), keepsRequestedSize: true)
			defer { host.window.close() }
			func switches(in view: NSView) -> [NSSwitch] {
				((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap { switches(in: $0) }
			}
			func cliSwitch() -> AccessibilityTree.Element? {
				AccessibilityTree.visibleElements(in: host.window, of: host.view).first { $0.role == .checkBox }
			}
			#expect(try await host.waitUntil { switches(in: host.view).count == 1 })
			#expect(fixture.store.projectCliAccess["demo"] == nil)
			#expect(switches(in: host.view).allSatisfy { !$0.isEnabled }, "An unreadable policy can't be changed from here")
			#expect(try await host.waitUntil { cliSwitch().map { ($0.label ?? $0.title) == "CLI approval" && $0.value == "Unavailable" } ?? false })
			fixture.keychain.cliAccessPolicies["demo"] = .requireApproval
			#expect(await fixture.store.loadProjects())
			fixture.store.isUnlocked = true
			#expect(try await host.waitUntil { switches(in: host.view).first?.isEnabled == true })
			#expect(switches(in: host.view).first?.state == .on)
			#expect(try await host.waitUntil { cliSwitch()?.value == "Required" })
		}

		@Test("Return in the picker's search uses its first match, once, and Cancel uses nothing")
		func pickerReturnAndCancel() async throws {
			var chosen: [ProjectIconChoice] = []
			let host = SheetTestHost(VaultIconPickerPresenter { chosen.append($0) }, size: NSSize(width: 700, height: 640))
			defer { host.window.close() }
			let sheet = try #require(try await host.waitUntil { host.window.attachedSheet != nil } ? host.window.attachedSheet : nil)
			#expect(try await host.waitForText("Search symbols", in: sheet))
			try host.typeText("database", placeholder: "Search symbols", in: sheet)
			sheet.makeKey()
			try host.key("\r", code: 36, in: sheet)
			#expect(try await host.waitUntil { chosen == [.symbol("cylinder.split.1x2", .indigo)] }, "Chose \(chosen)")
			try await host.settle()
			#expect(chosen.count == 1)

			let cancelled = SheetTestHost(VaultIconPickerPresenter { chosen.append($0) }, size: NSSize(width: 700, height: 640))
			defer { cancelled.window.close() }
			let other = try #require(try await cancelled.waitUntil { cancelled.window.attachedSheet != nil } ? cancelled.window.attachedSheet : nil)
			try await cancelled.click("Cancel", in: other)
			#expect(try await cancelled.waitUntil { cancelled.window.attachedSheet == nil })
			#expect(chosen.count == 1)
		}

		@Test("the picker's search has focus from the start, Down moves into the grid, arrows move the selection, and Return uses it")
		func pickerKeyboard() async throws {
			var chosen: [ProjectIconChoice] = []
			let host = SheetTestHost(VaultIconPickerPresenter { chosen.append($0) }, size: NSSize(width: 700, height: 640))
			defer { host.window.close() }
			let sheet = try #require(try await host.waitUntil { host.window.attachedSheet != nil } ? host.window.attachedSheet : nil)
			sheet.makeKey()
			#expect(try await host.waitUntil { (sheet.firstResponder as? NSText)?.delegate is NSTextField }, "The search field has focus")
			for (character, code) in [("g", UInt16(5)), ("e", 14), ("a", 0), ("r", 15)] { try host.key(character, code: code, in: sheet) }
			#expect(try await host.waitUntil { (sheet.firstResponder as? NSTextView)?.string == "gear" }, "Typing goes to the search without a click")
			for _ in 0..<4 { try host.key("\u{7F}", code: 51, in: sheet) }
			#expect(try await host.waitUntil { (sheet.firstResponder as? NSTextView)?.string == "" })
			let arrows: [(String, UInt16)] = [("\u{F701}", 125), ("\u{F703}", 124), ("\u{F701}", 125)]
			for (character, code) in arrows {
				try host.key(character, code: code, modifiers: [.numericPad, .function], in: sheet)
				try await host.settle()
			}
			try host.key("\r", code: 36, in: sheet)
			#expect(try await host.waitUntil { !chosen.isEmpty })
			#expect(chosen == [.symbol(ProjectIconCatalog.symbols[1 + VaultProjectIconPicker.columns].value, .indigo)],
				"Down enters the grid at Folder, Right moves to the next symbol and Down a row below it")
		}

		@Test("Esc closes the picker without choosing anything")
		func pickerEscape() async throws {
			var chosen: [ProjectIconChoice] = []
			let host = SheetTestHost(VaultIconPickerPresenter { chosen.append($0) }, size: NSSize(width: 700, height: 640))
			defer { host.window.close() }
			let sheet = try #require(try await host.waitUntil { host.window.attachedSheet != nil } ? host.window.attachedSheet : nil)
			sheet.makeKey()
			try host.key("\u{1b}", code: 53, in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(chosen.isEmpty)
		}

		@Test("Rename opens Project Settings with the name being edited")
		func renameFocusesName() async throws {
			let fixture = try makeFixture(path: "")
			defer { fixture.tearDown() }
			let project = try #require(fixture.store.projects.first)
			let host = SheetTestHost(VaultProjectSettingsView(store: fixture.store, project: project, nameFocusRequest: UUID(), onBack: {}, onDelete: {}),
				size: NSSize(width: 820, height: 640), keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitUntilRendered {
				((host.window.firstResponder as? NSText)?.delegate as? NSTextField)?.placeholderString == "Project name"
			})
			#expect(try await host.waitForText("This project isn't linked to a folder."))
		}

		@Test("the icon picker chooses an emoji by its search, and a monogram from its letters and color")
		func iconPicker() async throws {
			var chosen: [ProjectIconChoice] = []
			let host = SheetTestHost(VaultProjectIconPicker(projectName: "demo-api", initial: .automatic) { chosen.append($0) },
				size: NSSize(width: 560, height: 560))
			defer { host.window.close() }
			#expect(try await host.waitForText("Choose project icon"))
			#expect(try await host.waitForText("Search symbols"))
			try await host.click("Emoji")
			#expect(try await host.waitForText("Search emoji"))
			try host.typeText("rocket", placeholder: "Search emoji")
			try host.pressWhileEditing("\r", code: 36)
			#expect(chosen == [.emoji("🚀")], "Return uses the search's first match")
			try await host.click("Use Icon")
			#expect(chosen == [.emoji("🚀")], "A picker chooses once")

			let monogram = SheetTestHost(VaultProjectIconPicker(projectName: "demo-api", initial: .monogram("DA", .teal)) { chosen.append($0) },
				size: NSSize(width: 560, height: 560))
			defer { monogram.window.close() }
			#expect(try await monogram.waitForText("letters or digits"))
			try monogram.enterText("xy", at: 0)
			try await monogram.click("Use Icon")
			#expect(chosen.last == .monogram("XY", .teal))
		}
	}
}


/// The icon picker presented as a sheet, as Project Settings presents it.
private struct VaultIconPickerPresenter: View {
	let onUse: (ProjectIconChoice) -> Void
	@State private var presented = true

	var body: some View {
		Color.clear
			.frame(width: 700, height: 640)
			.sheet(isPresented: $presented) {
				VaultProjectIconPicker(projectName: "demo-api", initial: .automatic, onUse: onUse)
			}
	}
}
