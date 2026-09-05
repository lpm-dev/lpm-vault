import SwiftUI
import Testing
import Vision

@testable import LPMVault

@Suite("Existing organization project imports")
@MainActor
struct OrganizationProjectImportTests {
	private let local = VaultProject(
		id: "shared-existing", name: "Local", path: "/tmp/local",
		environments: ["default": ["TOKEN": "local", "LOCAL_ONLY": "keep"]]
	)
	private let binding = SyncPrincipalBinding(
		registryURL: "https://lpm.dev", principalID: "organization-id", scope: "organization"
	)
	private var remote: VaultProject {
		VaultProject(id: local.id, name: "Remote", path: "", environments: ["default": ["TOKEN": "cloud"]])
	}

	@Test("moving an existing project rejects concurrent value or organization changes")
	func concurrentChangesPreventMove() async throws {
		for changeAssociation in [false, true] {
			let keychain = MockKeychainService()
			let coordinator = VaultPersistenceCoordinator(service: keychain)
			_ = await coordinator.createProject(local, orgSlug: nil)
			let baseline = try await coordinator.loadProjectCreationRecord(vaultId: local.id).get()
			if changeAssociation {
				_ = await coordinator.associate(vaultId: local.id, orgSlug: "other-org")
			} else {
				var edited = local
				edited.environments["default"]?["TOKEN"] = "new-local"
				_ = await coordinator.saveProject(edited, markDirty: true)
			}
			let before = keychain.dataStorage
			let result = await coordinator.importProject(remote, orgSlug: "acme", version: 2, binding: binding, existing: baseline)
			guard case .conflict = result else { Issue.record("Concurrent change was accepted"); continue }
			#expect(keychain.dataStorage == before)
			let saved = try await coordinator.loadProject(vaultId: local.id).get()
			#expect(saved?.environments["default"]?["TOKEN"] == (changeAssociation ? "local" : "new-local"))
		}
	}

	@Test("failed organization moves restore existing values, association, and sync history")
	func failedMoveRestoresExistingState() async throws {
		for account in ["__org_associations__", mockSyncMetadataAccount(vaultId: local.id)] {
			let keychain = MockKeychainService()
			let coordinator = VaultPersistenceCoordinator(service: keychain)
			_ = await coordinator.createProject(local, orgSlug: "previous-org")
			let baseline = try await coordinator.loadProjectCreationRecord(vaultId: local.id).get()
			let before = keychain.dataStorage
			keychain.failNextWriteDataAccounts = [account]
			let result = await coordinator.importProject(remote, orgSlug: "acme", version: 2, binding: binding, existing: baseline)
			guard case .failure = result else { Issue.record("Expected persistence failure"); continue }
			#expect(keychain.dataStorage == before)
			#expect(try await coordinator.loadProject(vaultId: local.id).get() == local)
		}
	}

	@Test("moving a project preserves the organization revision floor")
	func moveRejectsOlderOrganizationRevision() async throws {
		let keychain = MockKeychainService()
		let coordinator = VaultPersistenceCoordinator(service: keychain)
		_ = await coordinator.createProject(local, orgSlug: nil)
		_ = await coordinator.finishPush(pushedProject: local, action: "push", version: 5, binding: binding)
		let baseline = try await coordinator.loadProjectCreationRecord(vaultId: local.id).get()
		let before = keychain.dataStorage
		let result = await coordinator.importProject(remote, orgSlug: "acme", version: 2, binding: binding, existing: baseline)
		guard case .staleVersion = result else { Issue.record("Older organization revision was accepted"); return }
		#expect(keychain.dataStorage == before)
		#expect(try await coordinator.loadProject(vaultId: local.id).get() == local)
	}

	@Test("organization move confirmation explains local relocation and cloud merge precedence")
	func moveConfirmationExplainsConsequences() throws {
		let renderer = ImageRenderer(content: OrgProjectMoveConfirmation(
			projectName: "test-project", onConfirm: {}, onCancel: {}
		).background(Color.white).environment(\.colorScheme, .light))
		renderer.scale = 3
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		try VNImageRequestHandler(cgImage: #require(renderer.cgImage)).perform([request])
		let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
		#expect(text.contains("Cloud values replace conflicting local values."))
		#expect(text.contains("Nothing is uploaded."))
		#expect(text.contains("Move and merge"))
	}
}
