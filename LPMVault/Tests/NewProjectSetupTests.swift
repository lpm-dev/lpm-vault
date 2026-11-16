import Foundation
import Testing

@testable import LPMVault

@Suite("New project setup")
@MainActor
struct NewProjectSetupTests {
	private struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		let preferences: UserDefaults
		let domain: String
		let images: URL
		let root: URL

		/// A folder under the fixture's root, created, as its real path.
		func folder(_ name: String, files: [String: Data] = [:]) throws -> String {
			let url = root.appending(path: name, directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
			for (path, data) in files { try ProjectIconFixture.write(data, to: path, in: url) }
			return try #require(Self.realPath(url.path))
		}

		static func realPath(_ path: String) -> String? {
			guard let resolved = realpath(path, nil) else { return nil }
			defer { free(resolved) }
			return String(cString: resolved)
		}

		func storedImages() -> [String] {
			(try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
		}

		@MainActor func tearDown() {
			store.lock()
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: images)
			try? FileManager.default.removeItem(at: root)
		}
	}

	private func makeFixture() throws -> Fixture {
		let domain = "new-project-setup-\(UUID().uuidString)"
		let preferences = try #require(UserDefaults(suiteName: domain))
		let images = FileManager.default.temporaryDirectory.appending(path: "new-project-images-\(UUID().uuidString)", directoryHint: .isDirectory)
		let root = FileManager.default.temporaryDirectory.appending(path: "new-project-folders-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let keychain = MockKeychainService()
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			preferences: preferences, authTokenProvider: { _, _ in nil }, projectIconsDirectory: images)
		store.isUnlocked = true
		return Fixture(store: store, keychain: keychain, preferences: preferences, domain: domain, images: images, root: root)
	}

	private func lpmJSON(in folder: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(contentsOf: ProjectCLILink.configURL(inFolder: folder)), rejectDuplicateKeys: true)
	}

	// MARK: - Creating

	@Test("a project created in a folder keeps it as its folder and links the folder's lpm.json to it, keeping its other settings")
	func createdInFolder() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let folder = try fixture.folder("api", files: ["lpm.json": Data(#"{"name":"api","tasks":{}}"#.utf8)])
		let result = await fixture.store.createVault(name: "api", vaultId: "with-folder", setup: NewProjectSetup(folder: folder))
		#expect(result == .completed)
		#expect(fixture.keychain.storage["with-folder"]?.path == folder)
		#expect(fixture.store.projects.first { $0.id == "with-folder" }?.path == folder)
		#expect(ProjectCLILink.status(vaultId: "with-folder", folder: folder) == .linked)
		let config = try lpmJSON(in: folder)
		#expect(config["name"] == .string("api"))
		#expect(config["tasks"] != nil)
		#expect(fixture.store.error == nil)
	}

	@Test("a project created without a folder writes no lpm.json anywhere and has no folder")
	func createdWithoutFolder() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		#expect(await fixture.store.createVault(name: "floating", vaultId: "floating") == .completed)
		#expect(fixture.keychain.storage["floating"]?.path == "")
		#expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
	}

	@Test("the sheet's CLI approval and local history choices win over Settings' defaults for new projects",
		arguments: [false, true])
	func choicesOverrideSettings(chosen: Bool) async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		fixture.store.settings.newProjectsAskBeforeCLIReads = !chosen
		fixture.store.settings.newProjectsKeepHistory = !chosen
		let setup = NewProjectSetup(defaults: NewProjectDefaults(asksBeforeCLIReads: chosen, keepsHistory: chosen))
		#expect(await fixture.store.createVault(name: "chosen", vaultId: "chosen", setup: setup) == .completed)
		#expect(fixture.store.projectCliAccess["chosen"] == (chosen ? .requireApproval : .automatic))
		#expect(fixture.keychain.cliAccessPolicies["chosen"] == (chosen ? .requireApproval : nil))
		#expect(try fixture.keychain.historyStateResult(vaultId: "chosen").get().history == (chosen ? "default" : "off"))
	}

	@Test("a project created without choices takes Settings' defaults for new projects")
	func noChoicesTakeSettings() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		fixture.store.settings.newProjectsAskBeforeCLIReads = false
		fixture.store.settings.newProjectsKeepHistory = false
		#expect(await fixture.store.createVault(name: "settings", vaultId: "settings") == .completed)
		#expect(fixture.store.projectCliAccess["settings"] == .automatic)
		#expect(try fixture.keychain.historyStateResult(vaultId: "settings").get().history == "off")
	}

	@Test("a chosen icon is the project's icon once it exists")
	func iconSaved() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let setup = NewProjectSetup(icon: .monogram("AP", .teal))
		#expect(await fixture.store.createVault(name: "api", vaultId: "iconic", setup: setup) == .completed)
		#expect(fixture.store.projectIcons.choice(for: "iconic") == .monogram("AP", .teal))
		#expect(fixture.store.projectIcons.savedChoices(for: ["iconic"]) == ["iconic": .monogram("AP", .teal)])
	}

	@Test("a folder whose lpm.json can't be linked still gets its project, and the error says so and how to link it later")
	func unlinkableFolder() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let original = Data("not json".utf8)
		let folder = try fixture.folder("broken", files: ["lpm.json": original])
		let result = await fixture.store.createVault(name: "broken", vaultId: "broken", setup: NewProjectSetup(folder: folder))
		#expect(result == .completed)
		#expect(fixture.keychain.storage["broken"]?.path == folder)
		#expect(try Data(contentsOf: ProjectCLILink.configURL(inFolder: folder)) == original)
		let error = try #require(fixture.store.error)
		#expect(error.contains("broken was created, but LPM Vault couldn’t link its folder"), "\(error)")
		#expect(error.contains("Connect CLI"), "\(error)")
	}

	@Test("a creation saved before it could finish is finished again for the same folder, and refused for another")
	func retriedCreationMatchesFolder() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let folder = try fixture.folder("saved")
		let other = try fixture.folder("other")
		fixture.keychain.storage["saved"] = ("saved", folder, [:])
		#expect(await fixture.store.createVault(name: "saved", vaultId: "saved", setup: NewProjectSetup(folder: other)) == .failed)
		#expect(ProjectCLILink.status(vaultId: "saved", folder: other) == .notLinked)
		#expect(await fixture.store.createVault(name: "saved", vaultId: "saved", setup: NewProjectSetup(folder: folder)) == .completed)
		#expect(ProjectCLILink.status(vaultId: "saved", folder: folder) == .linked)
	}

	@Test("a creation tried again, after the project was saved and shown, keeps the icon chosen for the new try")
	func retriedCreationKeepsNewIcon() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		#expect(await fixture.store.createVault(name: "again", vaultId: "again", setup: NewProjectSetup(icon: .emoji("🚀"))) == .completed)
		#expect(fixture.store.projects.contains { $0.id == "again" })
		let retried = await fixture.store.createVault(name: "again", vaultId: "again", setup: NewProjectSetup(icon: .monogram("AG", .blue)))
		#expect(retried == .completed)
		#expect(fixture.store.projectIcons.savedChoices(for: ["again"]) == ["again": .monogram("AG", .blue)])
		#expect(await fixture.store.createVault(name: "again", vaultId: "again") == .completed)
		#expect(fixture.store.projectIcons.savedChoices(for: ["again"]).isEmpty, "Automatic, chosen again, replaces it")
	}

	// MARK: - The sheet's draft

	@Test("a draft starts with Settings' defaults for new projects", arguments: [false, true])
	func draftStartsWithSettings(on: Bool) throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		fixture.store.settings.newProjectsAskBeforeCLIReads = on
		fixture.store.settings.newProjectsKeepHistory = !on
		let draft = NewProjectDraft(store: fixture.store)
		#expect(draft.asksBeforeCLIReads == on)
		#expect(draft.keepsHistory == !on)
		#expect(draft.icon == .automatic)
		#expect(draft.folder == nil)
		#expect(draft.setup == NewProjectSetup(defaults: NewProjectDefaults(asksBeforeCLIReads: on, keepsHistory: !on)))
	}

	@Test("choosing a folder inside a project takes the project around it, as the LPM CLI does")
	func folderInsideProject() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let project = try fixture.folder("web", files: ["package.json": Data("{}".utf8)])
		let source = try fixture.folder("web/src/components")
		let draft = NewProjectDraft(store: fixture.store)
		await draft.chooseFolder(URL(fileURLWithPath: source, isDirectory: true))
		let chosen = try #require(draft.folder)
		#expect(chosen.path == project)
		#expect(chosen.chosenInside == source)
		#expect(chosen.status == .notLinked)
		#expect(draft.folderBlocksCreation == false)
		#expect(draft.setup.folder == project)
	}

	@Test("a folder whose lpm.json links another project, or can't be read, can't be the new project's", arguments: [
		#"{"vault":"billing-vault"}"#, "{ not json",
	])
	func blockedFolder(config: String) async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let original = Data(config.utf8)
		let folder = try fixture.folder("taken", files: ["lpm.json": original])
		let draft = NewProjectDraft(store: fixture.store)
		await draft.chooseFolder(URL(fileURLWithPath: folder, isDirectory: true))
		#expect(draft.folder?.path == folder)
		#expect(draft.folderBlocksCreation)
		#expect(draft.folder?.status == (config.contains("billing") ? .linkedToOtherVault("billing-vault") : .unreadable))
		#expect(try Data(contentsOf: ProjectCLILink.configURL(inFolder: folder)) == original)
	}

	@Test("the folder whose .lpm is the LPM home is refused, and no folder is kept")
	func lpmHomeFolderRefused() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let user = try fixture.folder("user")
		fixture.store.lpmHome = LPMHome(defaultIn: URL(fileURLWithPath: user, isDirectory: true))
		let draft = NewProjectDraft(store: fixture.store)
		await draft.chooseFolder(URL(fileURLWithPath: user, isDirectory: true))
		#expect(draft.folder == nil)
		#expect(draft.folderError == .folderIsLPMHome)
		#expect(draft.setup.folder == "")
		#expect(try FileManager.default.contentsOfDirectory(atPath: user).isEmpty)
	}

	@Test("a folder's automatic icon shows before the project exists")
	func automaticIconFromFolder() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let folder = try fixture.folder("site", files: ["public/favicon.png": try ProjectIconFixture.png(red: 0, green: 0, blue: 255)])
		let draft = NewProjectDraft(store: fixture.store)
		#expect(draft.appearance == .folder)
		await draft.chooseFolder(URL(fileURLWithPath: folder, isDirectory: true))
		#expect(draft.automaticIcon?.detection == .found("public/favicon.png"))
		guard case .image = draft.appearance else {
			Issue.record("The folder's favicon shows, not \(draft.appearance)")
			return
		}
		await draft.clearFolder()
		#expect(draft.appearance == .folder)
		#expect(draft.automaticIcon == nil)
	}

	@Test("an image in the chosen folder is followed there, and is copied in once the folder changes")
	func imageFollowsFolder() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let folder = try fixture.folder("app", files: ["assets/logo.png": try ProjectIconFixture.png(red: 255, green: 0, blue: 0)])
		let draft = NewProjectDraft(store: fixture.store)
		await draft.chooseFolder(URL(fileURLWithPath: folder, isDirectory: true))
		await draft.chooseIconFile(URL(fileURLWithPath: folder).appending(path: "assets/logo.png"))
		#expect(draft.icon == .projectFile("assets/logo.png"))
		#expect(fixture.storedImages().isEmpty)
		await draft.clearFolder()
		guard case .storedImage = draft.icon else {
			Issue.record("The image is copied in once the folder is gone, not \(draft.icon)")
			return
		}
		#expect(fixture.storedImages().count == 1)
		guard case .image = draft.appearance else {
			Issue.record("The copied image shows, not \(draft.appearance)")
			return
		}
	}

	@Test("a copied image the draft replaces, or leaves unused when it's discarded, is deleted; a saved one stays")
	func copiedImagesCleanedUp() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let outside = try fixture.folder("downloads", files: [
			"one.png": try ProjectIconFixture.png(red: 255, green: 0, blue: 0),
			"two.png": try ProjectIconFixture.png(red: 0, green: 255, blue: 0),
		])
		let draft = NewProjectDraft(store: fixture.store)
		await draft.chooseIconFile(URL(fileURLWithPath: outside).appending(path: "one.png"))
		#expect(fixture.storedImages().count == 1)
		await draft.chooseIconFile(URL(fileURLWithPath: outside).appending(path: "two.png"))
		await fixture.store.projectIcons.waitForFileWork()
		#expect(fixture.storedImages().count == 1, "The first copy is gone once the second replaces it")
		draft.useIcon(.emoji("🚀"))
		await fixture.store.projectIcons.waitForFileWork()
		#expect(fixture.storedImages().isEmpty)

		await draft.chooseIconFile(URL(fileURLWithPath: outside).appending(path: "one.png"))
		draft.discard()
		await fixture.store.projectIcons.waitForFileWork()
		#expect(fixture.storedImages().isEmpty, "Cancelling the sheet deletes its copy")

		let kept = NewProjectDraft(store: fixture.store)
		kept.name = "kept"
		await kept.chooseIconFile(URL(fileURLWithPath: outside).appending(path: "two.png"))
		#expect(await fixture.store.createVault(name: "kept", vaultId: kept.vaultId, setup: kept.setup) == .completed)
		kept.discard()
		await fixture.store.projectIcons.waitForFileWork()
		#expect(fixture.storedImages().count == 1, "The created project's copy stays")
		guard case .storedImage? = fixture.store.projectIcons.choice(for: kept.vaultId) else {
			Issue.record("The created project keeps its image")
			return
		}
	}

	@Test("a draft's name must be one a project can have, and a blocked folder holds creation back")
	func canCreate() async throws {
		let fixture = try makeFixture()
		defer { fixture.tearDown() }
		let draft = NewProjectDraft(store: fixture.store)
		#expect(!draft.canCreate)
		draft.name = "  api  "
		#expect(draft.canCreate)
		#expect(draft.normalizedName == "api")
		let taken = try fixture.folder("taken", files: ["lpm.json": Data(#"{"vault":"other"}"#.utf8)])
		await draft.chooseFolder(URL(fileURLWithPath: taken, isDirectory: true))
		#expect(!draft.canCreate)
		await draft.clearFolder()
		#expect(draft.canCreate)
	}
}
