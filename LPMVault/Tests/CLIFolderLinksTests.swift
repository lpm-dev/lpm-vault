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

	@Test("a record reads and writes the CLI's JSON")
	func recordMatchesTheCLI() throws {
		let record = try CLIFolderLinkRecord.decode(Data(#"{"schemaVersion":1,"folders":["/b","/a","/a"]}"#.utf8))
		#expect(record.folders == ["/a", "/b"])

		let encoded = String(decoding: try record.encoded(), as: UTF8.self)
		#expect(encoded == #"{"folders":["/a","/b"],"schemaVersion":1}"#)
	}

	@Test("a record of another schema version isn't read")
	func otherSchemaVersion() {
		#expect(throws: DecodingError.self) {
			try CLIFolderLinkRecord.decode(Data(#"{"schemaVersion":2,"folders":[]}"#.utf8))
		}
	}

	@Test("the links service follows the LPM home, as the CLI names it")
	func linksService() {
		let links = KeychainCLIFolderLinks(home: LPMHome(defaultIn: URL(fileURLWithPath: "/Users/example")))
		#expect(links.service == "dev.lpm.vault.links")
		#expect(LPMHomeMove.sharedServices.contains(VaultConstants.cliFolderLinksKeychainService))
	}

	@Test("a folder the record names is linked and another isn't")
	func recordDecides() throws {
		let (root, folders) = try temporaryFolders("own", "other")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = MemoryCLIFolderLinks(["vault": CLIFolderLinkRecord(folders: [folders[0]])])

		#expect(try CLIFolderLinks.isLinked(folders[0], vaultId: "vault", recordedFolder: nil, holdsValues: { true }, in: store))
		#expect(try !CLIFolderLinks.isLinked(folders[1], vaultId: "vault", recordedFolder: folders[1], holdsValues: { true }, in: store))
	}

	@Test("without a record, only the recorded folder of a project with values is linked")
	func projectFromBeforeLinks() throws {
		let (root, folders) = try temporaryFolders("own", "other")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = MemoryCLIFolderLinks()

		#expect(try CLIFolderLinks.isLinked(folders[1], vaultId: "vault", recordedFolder: folders[0], holdsValues: { false }, in: store))
		#expect(try CLIFolderLinks.isLinked(folders[0], vaultId: "vault", recordedFolder: folders[0], holdsValues: { true }, in: store))
		#expect(try !CLIFolderLinks.isLinked(folders[1], vaultId: "vault", recordedFolder: folders[0], holdsValues: { true }, in: store))
		#expect(try !CLIFolderLinks.isLinked(folders[1], vaultId: "vault", recordedFolder: nil, holdsValues: { true }, in: store))
	}

	@Test("a folder is linked at its real path, as the CLI keeps it")
	func realPath() throws {
		let (root, folders) = try temporaryFolders("own")
		defer { try? FileManager.default.removeItem(at: root) }
		let alias = root.appendingPathComponent("alias").path
		try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: folders[0])
		let store = MemoryCLIFolderLinks()

		try CLIFolderLinks.link(alias, vaultId: "vault", recordedFolder: nil, unlinkingFrom: nil, in: store)

		#expect(try store.record(vaultId: "vault")?.folders == [folders[0]])
		#expect(try CLIFolderLinks.isLinked(alias, vaultId: "vault", recordedFolder: nil, holdsValues: { true }, in: store))
	}

	@Test("a project's first record keeps the folder its metadata records")
	func firstRecordKeepsRecordedFolder() throws {
		let (root, folders) = try temporaryFolders("recorded", "new")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = MemoryCLIFolderLinks()

		try CLIFolderLinks.link(folders[1], vaultId: "vault", recordedFolder: folders[0], unlinkingFrom: nil, in: store)

		#expect(try store.record(vaultId: "vault")?.folders == folders.sorted())
		#expect(try CLIFolderLinks.isLinked(folders[0], vaultId: "vault", recordedFolder: folders[0], holdsValues: { true }, in: store))
	}

	@Test("replacing a folder's vault ID unlinks it from the project it named")
	func replacingUnlinksPrevious() throws {
		let (root, folders) = try temporaryFolders("shared", "kept")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = MemoryCLIFolderLinks(["previous": CLIFolderLinkRecord(folders: folders)])

		try CLIFolderLinks.link(folders[0], vaultId: "vault", recordedFolder: nil, unlinkingFrom: "previous", in: store)

		#expect(try store.record(vaultId: "previous")?.folders == [folders[1]])
		#expect(try store.record(vaultId: "vault")?.folders == [folders[0]])
	}

	@Test("deleting a project deletes its folder links")
	func deletionRemovesLinks() throws {
		let links = MemoryCLIFolderLinks()
		let service = KeychainService(
			testingService: "folder-links-\(UUID().uuidString)", backend: InMemoryKeychainBackend(), folderLinks: links)
		guard case .success = service.createEnvironments(
			vaultId: "vault", projectName: "Project", projectPath: "/tmp/project",
			environments: ["default": ["A": "1"]], source: VaultHistorySource(.set))
		else { Issue.record("the project wasn't created"); return }
		#expect(throws: Never.self) {
			try service.linkCLIFolderResult("/tmp/project", vaultId: "vault", recordedFolder: nil, unlinkingFrom: nil).get()
		}
		#expect(try links.record(vaultId: "vault") != nil)

		guard case .success = service.applyVaultTransaction(project: .delete(vaultId: "vault", deletePayload: true), data: [])
		else { Issue.record("the project wasn't deleted"); return }

		#expect(try links.record(vaultId: "vault") == nil)
	}

	@Test("the store links a folder after writing its lpm.json, and reports a link it couldn't make")
	@MainActor
	func storeLinksAfterWriting() async throws {
		let (root, folders) = try temporaryFolders("project")
		defer { try? FileManager.default.removeItem(at: root) }
		let keychain = MockKeychainService()
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())

		#expect(await store.linkProjectFolder(vaultId: "vault", folder: folders[0]) == nil)
		#expect(ProjectCLILink.status(vaultId: "vault", folder: folders[0]) == .linked)
		#expect(try keychain.cliFolderLinks.record(vaultId: "vault")?.folders == [folders[0]])
		#expect(await store.isCLIFolderLinkedOnThisMac(vaultId: "vault", folder: folders[0]) == true)

		keychain.failFolderLinks = true
		#expect(await store.linkCLIFolderOnThisMac(vaultId: "vault", folder: folders[0]) == .notLinkedOnThisMac)
		#expect(await store.isCLIFolderLinkedOnThisMac(vaultId: "vault", folder: folders[0]) == nil)
	}
}
