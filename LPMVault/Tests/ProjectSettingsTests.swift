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
		#expect(store.projectSettingsDrafts["demo"] == ProjectSettingsDraft(name: "demo-api-v2", icon: .automatic))
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
		#expect(store.projectIcons.choices["demo"] == .symbol("bolt.fill", .indigo))
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
		#expect(store.projectIcons.choices["demo"] == .emoji("🚀"))
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
		#expect(store.projectSettingsDrafts["demo"] == ProjectSettingsDraft(name: "renamed", icon: .emoji("🚀")))
		#expect(store.projectSettingsErrors["demo"] != nil)
		#expect(store.error == nil, "The page shows the reason; no alert")
		#expect(try project(store).name == "demo-api")
		#expect(store.projectIcons.choices["demo"] == nil)
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
		let choice = try #require(try? await store.projectIcons.importImage(at: outside.appending(path: "logo.png"), projectFolder: "/tmp/demo-api").get())
		guard case .storedImage(let file, _) = choice else { return }
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

	@Test("a rename the store can't make reports why instead of hanging")
	func unavailableRename() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		let project = try project(store)
		store.lock()
		#expect(await store.renameProject(project, to: "new") == .unavailable)
	}
}
