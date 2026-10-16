import AppKit
import Foundation
import Testing

@testable import LPMVault

@Suite("Project settings", .serialized)
@MainActor
struct ProjectSettingsTests {
	private struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		let preferences: UserDefaults
		let domain: String
		let images: URL

		@MainActor func tearDown() {
			store.lock()
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: images)
		}
	}

	private func makeFixture() throws -> Fixture {
		let domain = "project-settings-\(UUID().uuidString)"
		let preferences = try #require(UserDefaults(suiteName: domain))
		let images = FileManager.default.temporaryDirectory.appending(path: "project-settings-images-\(UUID().uuidString)", directoryHint: .isDirectory)
		let keychain = MockKeychainService()
		keychain.envStorage["demo"] = (name: "demo-api", path: "/tmp/demo-api", environments: ["default": ["TOKEN": "x"]])
		keychain.envStorage["other"] = (name: "web", path: "/tmp/web", environments: ["default": [:]])
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			preferences: preferences, authTokenProvider: { _, _ in nil }, projectIconsDirectory: images)
		store.projects = [
			VaultProject(id: "demo", name: "demo-api", path: "/tmp/demo-api", environments: ["default": ["TOKEN": "x"]]),
			VaultProject(id: "other", name: "web", path: "/tmp/web", environments: ["default": [:]]),
		]
		store.isUnlocked = true
		store.selectedProjectId = "demo"
		return Fixture(store: store, keychain: keychain, preferences: preferences, domain: domain, images: images)
	}

	private func project(_ store: VaultStore, _ id: String = "demo") throws -> VaultProject {
		try #require(store.projects.first { $0.id == id })
	}

	@Test("an edit starts a draft, and editing back to what's saved ends it")
	func draftLifecycle() throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) { $0.name = "demo-api-v2" }
		#expect(store.projectSettingsDrafts["demo"] == ProjectSettingsDraft(name: .init(text: "demo-api-v2", base: "demo-api")))
		store.editProjectSettings(of: try project(store)) { $0.icon = .symbol("bolt.fill", .indigo) }
		store.editProjectSettings(of: try project(store)) { $0.name = "demo-api" }
		#expect(store.projectSettingsDrafts["demo"]?.icon == .symbol("bolt.fill", .indigo))
		store.editProjectSettings(of: try project(store)) { $0.icon = .automatic }
		#expect(store.projectSettingsDrafts["demo"] == nil)
		store.editProjectSettings(of: try project(store)) { $0.name = "x" }
		store.revertProjectSettings(of: "demo")
		#expect(store.projectSettingsDrafts["demo"] == nil)
	}

	@Test("Save renames the project in the shared index and keeps its folder and CLI link, then saves the icon")
	func saveRenamesAndSavesIcon() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		ProjectCLILink.rememberFolder("/tmp/demo-api", vaultId: "demo", defaults: fixture.preferences)
		store.editProjectSettings(of: try project(store)) {
			$0.name = "  demo-api-v2 "
			$0.icon = .symbol("bolt.fill", .indigo)
		}
		await store.saveProjectSettings(of: "demo")
		#expect(store.projectSettingsDrafts["demo"] == nil)
		#expect(store.projectSettingsErrors["demo"] == nil)
		#expect(try project(store).name == "demo-api-v2")
		#expect(try project(store).path == "/tmp/demo-api")
		#expect(fixture.keychain.envStorage["demo"]?.name == "demo-api-v2")
		#expect(fixture.keychain.envStorage["demo"]?.path == "/tmp/demo-api")
		#expect(ProjectCLILink.folder(vaultId: "demo", projectPath: "/tmp/demo-api", defaults: fixture.preferences) == "/tmp/demo-api")
		#expect(store.projectIcons.choice(for: "demo") == .symbol("bolt.fill", .indigo))
		#expect(fixture.preferences.data(forKey: ProjectIconStore.preferencePrefix + "demo") != nil)
	}

	@Test("an icon-only change saves without renaming")
	func iconOnlySave() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) { $0.icon = .emoji("🚀") }
		fixture.keychain.shouldFail = true
		await store.saveProjectSettings(of: "demo")
		#expect(store.projectIcons.choice(for: "demo") == .emoji("🚀"))
		#expect(store.projectSettingsDrafts["demo"] == nil)
	}

	@Test("when the rename can't be saved, nothing is, and the edits stay with the reason")
	func renameFailureKeepsEdits() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) {
			$0.name = "renamed"
			$0.icon = .emoji("🚀")
		}
		fixture.keychain.failNextSaveEnvironments = true
		await store.saveProjectSettings(of: "demo")
		#expect(store.projectSettingsDrafts["demo"] == ProjectSettingsDraft(name: .init(text: "renamed", base: "demo-api"), icon: .emoji("🚀")))
		#expect(store.projectSettingsErrors["demo"] != nil)
		#expect(store.error == nil, "The page shows the reason; no alert")
		#expect(try project(store).name == "demo-api")
		#expect(store.projectIcons.choice(for: "demo") == nil)
		#expect(!store.savingProjectSettings.contains("demo"))
		await store.saveProjectSettings(of: "demo")
		#expect(try project(store).name == "renamed")
		#expect(store.projectSettingsErrors["demo"] == nil)
	}

	@Test("an empty name isn't saved")
	func invalidName() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) { $0.name = "   " }
		await store.saveProjectSettings(of: "demo")
		#expect(store.projectSettingsErrors["demo"] == "Enter a name for the project.")
		#expect(fixture.keychain.envStorage["demo"]?.name == "demo-api")
	}

	@Test("locking, switching accounts and losing the project each end its unsaved settings and drop a copied image",
		arguments: ["lock", "account", "removed"])
	func draftsEnd(event: String) async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		let outside = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: outside) }
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "logo.png", in: outside)
		let choice = try #require(try? await store.projectIcons.importImage(at: outside.appending(path: "logo.png"), projectFolder: "/tmp/demo-api", for: "demo").get())
		guard case .storedImage(let file, _) = choice else {
			Issue.record("An image outside the folder is copied")
			return
		}
		store.editProjectSettings(of: try project(store)) { $0.icon = choice }
		switch event {
		case "lock": store.lock()
		case "account": store.selectedAccount = .org("acme")
		default: store.projects.removeAll { $0.id == "demo" }
		}
		#expect(store.projectSettingsDrafts.isEmpty)
		let copy = fixture.images.appending(path: file)
		let deadline = ContinuousClock.now + .seconds(5)
		while FileManager.default.fileExists(atPath: copy.path), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(!FileManager.default.fileExists(atPath: copy.path))
	}

	@Test("the header's … menu opens settings, offers the folder's actions only when there is one, and renames and deletes")
	func headerMenu() throws {
		// Menu items send their actions through the application.
		_ = NSApplication.shared
		var opened = 0, renamed = 0, deleted = 0
		let project = VaultProject(id: "demo", name: "demo-api", path: "/tmp/demo-api", environments: [:])
		let items = VaultProjectMenu.headerItems(for: project, folderExists: false,
			openSettings: { opened += 1 }, rename: { renamed += 1 }, delete: { deleted += 1 })
		#expect(items.map { $0.title ?? "—" } == ["Project Settings…", "—", "Show in Finder", "Copy folder path", "—", "Rename…", "Delete Locally…"])
		let menu = VaultMenuAnchor().menu(for: items)
		#expect(menu.items[0].keyEquivalent == "i" && menu.items[0].keyEquivalentModifierMask == .command)
		#expect(menu.items[1].isSeparatorItem && menu.items[4].isSeparatorItem)
		#expect(!menu.items[2].isEnabled, "Show in Finder needs the folder to be there")
		#expect(menu.items[3].isEnabled)
		menu.performActionForItem(at: 0)
		menu.performActionForItem(at: 5)
		menu.performActionForItem(at: 6)
		#expect(opened == 1 && renamed == 1 && deleted == 1)
		let unlinked = VaultProjectMenu.headerItems(for: VaultProject(id: "x", name: "x", path: "", environments: [:]), folderExists: true,
			openSettings: {}, rename: {}, delete: {})
		let unlinkedMenu = VaultMenuAnchor().menu(for: unlinked)
		#expect(!unlinkedMenu.items[2].isEnabled && !unlinkedMenu.items[3].isEnabled)
	}

	private func renameElsewhere(_ fixture: Fixture, to name: String) throws {
		fixture.keychain.envStorage["demo"]?.name = name
		var renamed = try project(fixture.store)
		renamed.name = name
		fixture.store.projects = fixture.store.projects.map { $0.id == "demo" ? renamed : $0 }
	}

	@Test("an icon-only save keeps a name the LPM CLI changed meanwhile")
	func iconOnlySaveKeepsExternalRename() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) { $0.icon = .emoji("🚀") }
		try renameElsewhere(fixture, to: "renamed-by-cli")
		#expect(store.projectSettings(for: try project(store)).name == "renamed-by-cli", "An untouched name follows the saved one")
		await store.saveProjectSettings(of: "demo")
		#expect(fixture.keychain.envStorage["demo"]?.name == "renamed-by-cli")
		#expect(store.projectIcons.choice(for: "demo") == .emoji("🚀"))
		#expect(store.projectSettingsDrafts["demo"] == nil)
	}

	@Test("a name typed over one the LPM CLI changed meanwhile isn't saved over it")
	func editedNameConflictsWithExternalRename() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) { $0.name = "mine" }
		try renameElsewhere(fixture, to: "theirs")
		#expect(store.projectSettings(for: try project(store)).name == "mine")
		await store.saveProjectSettings(of: "demo")
		#expect(fixture.keychain.envStorage["demo"]?.name == "theirs")
		#expect(store.projectSettingsErrors["demo"] != nil)
		#expect(store.projectSettingsDrafts["demo"] != nil, "The typed name stays to review")
	}

	@Test("an icon that can't be saved keeps the draft and says why")
	func unsavableIconKeepsDraft() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) { $0.icon = .symbol("not.a.symbol", .red) }
		await store.saveProjectSettings(of: "demo")
		#expect(store.projectSettingsDrafts["demo"] != nil)
		#expect(store.projectSettingsErrors["demo"] != nil)
		#expect(store.projectIcons.choice(for: "demo") == nil)
	}

	@Test("an edit refused while saving reports it, so a copied image can be dropped")
	func editRefusedWhileSaving() throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.savingProjectSettings.insert("demo")
		defer { store.savingProjectSettings.remove("demo") }
		#expect(!store.editProjectSettings(of: try project(store)) { $0.icon = .emoji("🚀") })
		#expect(store.projectSettingsDrafts["demo"] == nil)
	}

	@Test("switching accounts while a save runs still saves the icon with the name")
	func accountSwitchDuringSave() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		store.editProjectSettings(of: try project(store)) {
			$0.name = "renamed"
			$0.icon = .emoji("🚀")
		}
		let gate = DispatchSemaphore(value: 0)
		fixture.keychain.blockNextSaveEnvironments = { gate.wait() }
		let save = Task { await store.saveProjectSettings(of: "demo") }
		let deadline = ContinuousClock.now + .seconds(5)
		while fixture.keychain.saveEnvironmentsCallCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
		store.selectedAccount = .org("acme")
		gate.signal()
		await save.value
		#expect(fixture.keychain.envStorage["demo"]?.name == "renamed")
		#expect(store.projectIcons.choice(for: "demo") == .emoji("🚀"))
	}

	@Test("the icon row names each kind of icon, sets file and symbol names apart, and says when a chosen file can't show", arguments: [
		(ProjectIconChoice.automatic, ProjectIconDetection.searching, false, "Automatic", [String]()),
		(.automatic, .found("public/favicon.png"), false, "Automatic · public/favicon.png", ["public/favicon.png"]),
		(.automatic, .notFound, false, "Automatic · no icon found", []),
		(.automatic, .folderMissing, false, "Automatic · folder not found", []),
		(.symbol("cylinder.split.1x2", .indigo), .notFound, false, "Icon · cylinder.split.1x2 · Indigo", ["cylinder.split.1x2"]),
		(.emoji("🚀"), .notFound, false, "Emoji · 🚀", []),
		(.monogram("DA", .teal), .notFound, false, "Monogram · DA · Teal", []),
		(.projectFile("assets/icon.png"), .notFound, false, "Image · assets/icon.png", ["assets/icon.png"]),
		(.projectFile("assets/icon.png"), .notFound, true, "Image · assets/icon.png · can't be read, so the automatic icon shows", ["assets/icon.png"]),
		(.storedImage(file: "\(UUID().uuidString).png", name: "brand.png"), .notFound, false, "Image · brand.png", []),
		(.storedImage(file: "\(UUID().uuidString).png", name: "brand.png"), .notFound, true, "Image · brand.png · missing, so the automatic icon shows", []),
	])
	func iconCaption(sample: (ProjectIconChoice, ProjectIconDetection, Bool, String, [String])) {
		let parts = VaultProjectSettingsView.iconCaption(for: sample.0, detection: sample.1, fileFailed: sample.2)
		#expect(parts.map(\.text).joined() == sample.3)
		#expect(parts.filter(\.isPath).map(\.text) == sample.4)
	}

	@Test("a rename the store can't make reports why instead of hanging")
	func unavailableRename() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		let project = try project(store)
		store.lock()
		#expect(await store.renameProject(project, from: project.name, to: "new") == .unavailable)
	}
}
