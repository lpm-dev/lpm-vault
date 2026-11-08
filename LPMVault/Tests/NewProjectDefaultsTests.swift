import Foundation
import Testing

@testable import LPMVault

@Suite("What a new project starts with")
struct NewProjectDefaultsTests {
	private func makeService() -> (KeychainService, InMemoryKeychainBackend, String) {
		let backend = InMemoryKeychainBackend()
		let name = "dev.lpm.vault.new-project.\(UUID().uuidString)"
		return (KeychainService(testingService: name, backend: backend), backend, name)
	}

	private let binding = SyncPrincipalBinding(registryURL: "https://lpm.dev", principalID: "user-1", scope: "personal")

	@Test("by default a new project lets the CLI read it without asking and keeps local history, as before")
	func standardDefaults() async throws {
		let (service, _, _) = makeService()
		let project = VaultProject(id: "standard-new", name: "Standard", path: "", environments: ["default": [:]])
		guard case .success(let commit) = await VaultPersistenceCoordinator(service: service).createProject(project, orgSlug: nil)
		else { throw KeychainError.encodingFailed }
		#expect(commit.cliAccess == .automatic)
		#expect(try service.historyStateResult(vaultId: project.id).get().history != "off")
		#expect(commit.warning == nil)
	}

	@Test("a project created with Settings' defaults asks before the CLI reads it and keeps no history")
	func createdWithDefaults() async throws {
		let (service, _, _) = makeService()
		let project = VaultProject(id: "guarded-new", name: "Guarded", path: "", environments: ["default": [:]])
		guard case .success(let commit) = await VaultPersistenceCoordinator(service: service).createProject(
			project, orgSlug: nil, defaults: NewProjectDefaults(asksBeforeCLIReads: true, keepsHistory: false))
		else { throw KeychainError.encodingFailed }
		#expect(commit.cliAccess == .requireApproval)
		#expect(try service.cliAccessResult(vaultId: project.id).get() == .requireApproval)
		#expect(try service.historyStateResult(vaultId: project.id).get().history == "off")
		#expect(commit.warning == nil)
	}

	@Test("an imported project's values are never recorded when new projects keep no history, and the CLI asks first")
	func importedWithDefaults() async throws {
		let (service, backend, name) = makeService()
		let remote = VaultProject(id: "imported-new", name: "Imported", path: "", environments: ["default": ["TOKEN": "remote"]])
		let result = await VaultPersistenceCoordinator(service: service).importProject(
			remote, orgSlug: nil, version: 1, binding: binding,
			defaults: NewProjectDefaults(asksBeforeCLIReads: true, keepsHistory: false))
		guard case .success(let commit) = result else { throw KeychainError.encodingFailed }
		#expect(commit.cliAccess == .requireApproval)
		#expect(try service.historyStateResult(vaultId: remote.id).get().history == "off")
		#expect(service.takeHistoryOutcomes()[remote.id] == .off)
		#expect(try backend.read(service: name, account: HistoryRecorder.account("history-head", remote.id)) == nil)
		#expect(try service.getProjectResult(vaultId: remote.id).get()?.environments == remote.environments)
	}

	@Test("an import merged into a project already here keeps that project's own settings")
	func mergedImportKeepsItsSettings() async throws {
		let (service, _, _) = makeService()
		let coordinator = VaultPersistenceCoordinator(service: service)
		let local = VaultProject(id: "merged", name: "Merged", path: "", environments: ["default": ["TOKEN": "local"]])
		_ = await coordinator.createProject(local, orgSlug: nil)
		let baseline = try await coordinator.loadProjectCreationRecord(vaultId: local.id).get()
		let remote = VaultProject(id: local.id, name: local.name, path: "", environments: ["default": ["OTHER": "remote"]])
		let result = await coordinator.importProject(
			remote, orgSlug: "acme", version: 2, binding: binding, existing: baseline,
			defaults: NewProjectDefaults(asksBeforeCLIReads: true, keepsHistory: false))
		guard case .success(let commit) = result else { throw KeychainError.encodingFailed }
		#expect(commit.cliAccess == .automatic)
		#expect(try service.historyStateResult(vaultId: local.id).get().history != "off")
	}
}
