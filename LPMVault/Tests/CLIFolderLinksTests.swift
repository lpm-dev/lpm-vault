import Foundation
import Testing

@testable import LPMVault

@Suite("CLI folder links")
struct CLIFolderLinksTests {
	private func temporaryFolders(_ names: String...) throws -> (root: URL, folders: [String]) {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-links-\(UUID().uuidString)")
		var folders: [String] = []
		for name in names {
			let folder = root.appendingPathComponent(name, isDirectory: true)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			folders.append(CLIFolderLinks.realPath(folder.path))
		}
		return (root, folders)
	}

	private func project(_ vaultId: String = "vault", holdsValues: Bool, recordedFolder: String? = nil) -> CLIFolderLinkProject {
		CLIFolderLinkProject(vaultId: vaultId, holdsValues: { holdsValues }, recordedFolder: { recordedFolder })
	}

	// MARK: - The record

	@Test("a record reads and writes the CLI's JSON, and reads past a field it doesn't know")
	func recordMatchesTheCLI() throws {
		let record = try CLIFolderLinkRecord.decode(Data(#"{"schemaVersion":1,"folders":["/b","/a","/a"],"note":"x"}"#.utf8))
		#expect(record.folders == ["/a", "/b"])

		let encoded = String(decoding: try record.encoded(), as: UTF8.self)
		#expect(encoded == #"{"folders":["/a","/b"],"schemaVersion":1}"#)
	}

	@Test("a record from a later version isn't read, and one that can't be read is damaged")
	func unreadableRecords() {
		#expect(throws: CLIFolderLinkRecordError.newerVersion) {
			try CLIFolderLinkRecord.decode(Data(#"{"schemaVersion":2,"folders":[]}"#.utf8))
		}
		#expect(throws: CLIFolderLinkRecordError.damaged) {
			try CLIFolderLinkRecord.decode(Data("{not json".utf8))
		}
	}

	@Test("folders are told apart by their bytes, as the CLI tells them apart")
	func foldersCompareByBytes() {
		let composed = "/work/caf\u{E9}"
		let decomposed = "/work/cafe\u{301}"
		var record = CLIFolderLinkRecord(folders: [composed])

		#expect(!record.contains(decomposed))
		let inserted = record.insert(decomposed)
		#expect(inserted)
		#expect(record.folders.count == 2)
	}

	@Test("the links service follows the LPM home, as the CLI names it")
	func linksService() throws {
		let user = FileManager.default.temporaryDirectory.appendingPathComponent("links-home-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: user) }
		let custom = try #require(LPMHome.at(user.appendingPathComponent("tools/lpm"), userHome: user))
		let scope = try #require(custom.scope)

		#expect(KeychainCLIFolderLinks(home: LPMHome(defaultIn: user)).service == "dev.lpm.vault.links")
		#expect(KeychainCLIFolderLinks(home: custom).service == "dev.lpm.vault.links:\(scope)")
		#expect(LPMHomeMove.sharedServices.contains(VaultConstants.cliFolderLinksKeychainService))
	}

	// MARK: - The CLI's rule

	@Test("a folder the record names is linked and another isn't")
	func recordDecides() throws {
		let (root, folders) = try temporaryFolders("own", "other")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = MemoryCLIFolderLinks(["vault": CLIFolderLinkRecord(folders: [folders[0]])])

		#expect(try CLIFolderLinks.isLinked(folders[0], project: project(holdsValues: true), in: store))
		#expect(try !CLIFolderLinks.isLinked(
			folders[1], project: project(holdsValues: true, recordedFolder: folders[1]), in: store))
	}

	@Test("without a record, only the recorded folder of a project with values is linked")
	func projectFromBeforeLinks() throws {
		let (root, folders) = try temporaryFolders("own", "other")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = MemoryCLIFolderLinks()

		#expect(try CLIFolderLinks.isLinked(folders[1], project: project(holdsValues: false, recordedFolder: folders[0]), in: store))
		#expect(try CLIFolderLinks.isLinked(folders[0], project: project(holdsValues: true, recordedFolder: folders[0]), in: store))
		#expect(try !CLIFolderLinks.isLinked(folders[1], project: project(holdsValues: true, recordedFolder: folders[0]), in: store))
		#expect(try !CLIFolderLinks.isLinked(folders[1], project: project(holdsValues: true), in: store))
	}

	@Test("a project's first record keeps the folder its metadata records")
	func firstRecordKeepsRecordedFolder() throws {
		let (root, folders) = try temporaryFolders("recorded", "new")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = MemoryCLIFolderLinks()

		try CLIFolderLinks.link(
			folders[1], to: project(holdsValues: true, recordedFolder: folders[0]), unlinkingFrom: nil, in: store)

		#expect(try store.record(vaultId: "vault")?.folders == folders.sorted())
	}

	@Test("a record that can't be read is replaced by linking, and one from a later version isn't")
	func linkingReplacesADamagedRecord() throws {
		let store = MemoryCLIFolderLinks()
		store.setData(Data("{not json".utf8), vaultId: "vault")

		try CLIFolderLinks.link("/work/app", to: project(holdsValues: true), unlinkingFrom: nil, in: store)

		#expect(try store.record(vaultId: "vault")?.folders == ["/work/app"])
		let later = Data(#"{"schemaVersion":2,"folders":[]}"#.utf8)
		store.setData(later, vaultId: "vault")
		#expect(throws: CLIFolderLinkRecordError.newerVersion) {
			try CLIFolderLinks.link("/work/app", to: project(holdsValues: true), unlinkingFrom: nil, in: store)
		}
		#expect(try store.data(vaultId: "vault") == later)
	}

	// MARK: - Replacing a folder's vault ID

	@Test("replacing a folder's vault ID unlinks it from the project it named")
	func replacingUnlinksPrevious() throws {
		let store = MemoryCLIFolderLinks(["previous": CLIFolderLinkRecord(folders: ["/work/shared", "/work/kept"])])

		try CLIFolderLinks.link(
			"/work/shared", to: project(holdsValues: true),
			unlinkingFrom: project("previous", holdsValues: true), in: store)

		#expect(try store.record(vaultId: "previous")?.folders == ["/work/kept"])
		#expect(try store.record(vaultId: "vault")?.folders == ["/work/shared"])
	}

	@Test("replacing the vault ID of the folder a project from before links records keeps the CLI from linking it")
	func replacingUnlinksALegacyPrevious() throws {
		let store = MemoryCLIFolderLinks()
		let previous = project("previous", holdsValues: true, recordedFolder: "/work/app")

		try CLIFolderLinks.link("/work/app", to: project(holdsValues: false), unlinkingFrom: previous, in: store)

		#expect(try store.record(vaultId: "previous")?.folders == [])
		#expect(try !CLIFolderLinks.isLinked("/work/app", project: previous, in: store))
	}

	@Test("a failed unlink links nothing, and doing it again finishes the job")
	func failedUnlinkLinksNothing() throws {
		let store = MemoryCLIFolderLinks(["previous": CLIFolderLinkRecord(folders: ["/work/app"])])
		store.failWrites = true

		#expect(throws: KeychainStoreError.self) {
			try CLIFolderLinks.link(
				"/work/app", to: project(holdsValues: true),
				unlinkingFrom: project("previous", holdsValues: true), in: store)
		}
		#expect(try store.record(vaultId: "vault") == nil)

		store.failWrites = false
		try CLIFolderLinks.link(
			"/work/app", to: project(holdsValues: true),
			unlinkingFrom: project("previous", holdsValues: true), in: store)
		#expect(try store.record(vaultId: "previous")?.folders == [])
		#expect(try store.record(vaultId: "vault")?.folders == ["/work/app"])
	}

	// MARK: - The Keychain service

	private func service(links: any CLIFolderLinkStoring) -> KeychainService {
		KeychainService(
			testingService: "folder-links-\(UUID().uuidString)", backend: InMemoryKeychainBackend(), folderLinks: links)
	}

	private func create(_ vaultId: String, path: String, in service: KeychainService) throws {
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: path,
			environments: ["default": ["A": "1"]], source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
	}

	@Test("the service reads the recorded folder and stored values for a project without a record")
	func serviceAppliesTheRuleToStoredProjects() throws {
		let (root, folders) = try temporaryFolders("own", "other")
		defer { try? FileManager.default.removeItem(at: root) }
		let links = MemoryCLIFolderLinks()
		let service = service(links: links)
		try create("vault", path: folders[0], in: service)

		#expect(try service.isCLIFolderLinkedResult(folders[0], vaultId: "vault").get())
		#expect(try !service.isCLIFolderLinkedResult(folders[1], vaultId: "vault").get())
		#expect(try service.isCLIFolderLinkedResult(folders[1], vaultId: "absent").get(), "a project without values keeps no folder out")
	}

	@Test("the service stores the CLI's bytes under the links service, one item per vault ID")
	func serviceStoresTheCLIBytes() throws {
		let backend = InMemoryKeychainBackend()
		let home = LPMHome(defaultIn: FileManager.default.temporaryDirectory)
		let service = service(links: KeychainCLIFolderLinks(home: home, backend: backend))

		try service.linkCLIFolderResult("/work/app", vaultId: "vault", unlinkingFrom: nil).get()

		#expect(try backend.read(service: "dev.lpm.vault.links", account: "vault")
			== Data(#"{"folders":["/work/app"],"schemaVersion":1}"#.utf8))
	}

	@Test("replacing a vault ID the CLI can't use links the folder without unlinking anything")
	func replacingAnUnusableIdLinks() throws {
		let links = MemoryCLIFolderLinks()
		let service = service(links: links)

		try service.linkCLIFolderResult("/work/app", vaultId: "vault", unlinkingFrom: "a/b").get()

		#expect(try links.record(vaultId: "vault")?.folders == ["/work/app"])
	}

	@Test("a check of a record that can't be read fails instead of answering")
	func checkOfADamagedRecordFails() {
		let links = MemoryCLIFolderLinks()
		links.setData(Data("{not json".utf8), vaultId: "vault")

		#expect(throws: KeychainError.self) {
			try service(links: links).isCLIFolderLinkedResult("/work/app", vaultId: "vault").get()
		}
	}

	@Test("deleting a project deletes its folder links")
	func deletionRemovesLinks() throws {
		let links = MemoryCLIFolderLinks()
		let service = service(links: links)
		try create("vault", path: "/tmp/project", in: service)
		try service.linkCLIFolderResult("/tmp/project", vaultId: "vault", unlinkingFrom: nil).get()

		guard case .success = service.applyVaultTransaction(project: .delete(vaultId: "vault", deletePayload: true), data: [])
		else { Issue.record("the project wasn't deleted"); return }

		#expect(try links.record(vaultId: "vault") == nil)
	}

	// MARK: - The store

	@Test("the store links a folder before it writes lpm.json, and writes nothing when the link fails")
	@MainActor
	func storeLinksThenWrites() async throws {
		let (root, folders) = try temporaryFolders("project", "other")
		defer { try? FileManager.default.removeItem(at: root) }
		let keychain = MockKeychainService()
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())
		store.isUnlocked = true

		#expect(await store.linkProjectFolder(vaultId: "vault", folder: folders[0]) == nil)
		#expect(ProjectCLILink.status(vaultId: "vault", folder: folders[0]) == .linked)
		#expect(try keychain.cliFolderLinks.record(vaultId: "vault")?.folders == [folders[0]])
		#expect(await store.isCLIFolderLinkedOnThisMac(vaultId: "vault", folder: folders[0]) == true)

		keychain.failFolderLinks = true
		#expect(await store.linkProjectFolder(vaultId: "vault", folder: folders[1]) == .notLinkedOnThisMac)
		#expect(ProjectCLILink.status(vaultId: "vault", folder: folders[1]) == .notLinked)
		#expect(await store.isCLIFolderLinkedOnThisMac(vaultId: "vault", folder: folders[0]) == nil)
	}

	@Test("a locked vault links no folder")
	@MainActor
	func lockedVaultLinksNothing() async throws {
		let keychain = MockKeychainService()
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())
		store.isUnlocked = false

		#expect(await store.linkCLIFolderOnThisMac(vaultId: "vault", folder: "/work/app") == .interrupted)
		#expect(try keychain.cliFolderLinks.record(vaultId: "vault") == nil)
	}
}
