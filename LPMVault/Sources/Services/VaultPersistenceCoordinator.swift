import Foundation

struct VaultPersistenceSnapshot: Sendable {
	let projects: [VaultProject]
	let syncMetadata: [String: SyncMetadata]
	let orgAssociations: [String: String]
}

struct ImportPersistenceCommit: Sendable {
	let syncMetadata: [String: SyncMetadata]
	let orgAssociations: [String: String]
	let warning: String?
}

enum ImportPersistenceResult: Sendable {
	case success(ImportPersistenceCommit)
	case duplicate
	case failure(KeychainError)
}

/// Serializes Keychain mutations so older snapshots cannot finish after newer ones.
actor VaultPersistenceCoordinator {
	private let service: KeychainServiceProtocol

	init(service: KeychainServiceProtocol) {
		self.service = service
	}

	func listProjects() -> [VaultProject] {
		service.listProjects()
	}

	func loadSnapshot() -> VaultPersistenceSnapshot {
		let projects = service.listProjects().sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
		let metadata = service.readData(account: "__sync_metadata__")
			.flatMap { try? JSONDecoder().decode([String: SyncMetadata].self, from: $0) } ?? [:]
		let associations = service.readData(account: "__org_associations__")
			.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
		return VaultPersistenceSnapshot(
			projects: projects,
			syncMetadata: metadata,
			orgAssociations: associations
		)
	}

	func containsProject(vaultId: String) -> Bool {
		service.getEnvironments(vaultId: vaultId) != nil
			|| service.listProjects().contains { $0.id == vaultId }
	}

	func saveProject(_ project: VaultProject, markDirty: Bool) -> (
		result: KeychainResult,
		metadata: [String: SyncMetadata]
	) {
		let result = save(project)
		guard markDirty else { return (result, loadSyncMetadata()) }
		switch result {
		case .success, .successWithWarning:
			var metadata = loadSyncMetadata()
			var item = metadata[project.id] ?? SyncMetadata()
			item.isDirty = true
			metadata[project.id] = item
			guard writeSyncMetadata(metadata) else {
				return (.failure(.unexpectedStatus(-1)), loadSyncMetadata())
			}
			return (result, metadata)
		case .failure:
			return (result, loadSyncMetadata())
		}
	}

	func markSynced(vaultId: String, action: String, version: Int?) -> [String: SyncMetadata]? {
		var metadata = loadSyncMetadata()
		var item = metadata[vaultId] ?? SyncMetadata()
		item.isDirty = false
		item.lastSyncedAt = Date()
		item.lastAction = action
		item.lastVersion = version
		metadata[vaultId] = item
		return writeSyncMetadata(metadata) ? metadata : nil
	}

	func associate(vaultId: String, orgSlug: String) -> [String: String]? {
		var associations = loadOrgAssociations()
		associations[vaultId] = orgSlug
		guard let data = try? JSONEncoder().encode(associations),
			service.writeData(account: "__org_associations__", data: data)
		else { return nil }
		return associations
	}

	func deleteProjectAndMetadata(vaultId: String) -> VaultPersistenceSnapshot? {
		guard service.deleteProject(vaultId: vaultId) else { return nil }
		var metadata = loadSyncMetadata()
		metadata.removeValue(forKey: vaultId)
		var associations = loadOrgAssociations()
		associations.removeValue(forKey: vaultId)
		guard let associationData = try? JSONEncoder().encode(associations),
			service.writeData(account: "__org_associations__", data: associationData),
			writeSyncMetadata(metadata)
		else { return nil }
		return VaultPersistenceSnapshot(
			projects: service.listProjects().sorted {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			},
			syncMetadata: metadata,
			orgAssociations: associations
		)
	}

	/// Commits a fully resolved import as one logical transaction. The project
	/// is never indexed until its final decrypted contents are available.
	func importProject(
		_ project: VaultProject,
		orgSlug: String?,
		version: Int
	) -> ImportPersistenceResult {
		guard !containsProject(vaultId: project.id) else { return .duplicate }

		let oldMetadata = service.readData(account: "__sync_metadata__")
		let oldAssociations = service.readData(account: "__org_associations__")
		var metadata = oldMetadata
			.flatMap { try? JSONDecoder().decode([String: SyncMetadata].self, from: $0) } ?? [:]
		metadata[project.id] = SyncMetadata(
			lastSyncedAt: Date(),
			lastAction: "pull",
			lastVersion: version,
			isDirty: false
		)
		var associations = oldAssociations
			.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
		if let orgSlug { associations[project.id] = orgSlug }

		guard let metadataData = try? JSONEncoder().encode(metadata),
			let associationData = try? JSONEncoder().encode(associations)
		else { return .failure(.encodingFailed) }

		let saveResult = service.createEnvironments(
			vaultId: project.id,
			projectName: project.name,
			projectPath: project.path,
			environments: project.environments
		)

		let warning: String?
		switch saveResult {
		case .success:
			warning = nil
		case .successWithWarning(let message):
			warning = message
		case .failure(.duplicateItem):
			return .duplicate
		case .failure(let error):
			return .failure(error)
		}

		if orgSlug != nil,
			!service.writeData(account: "__org_associations__", data: associationData)
		{
			guard service.deleteProject(vaultId: project.id) else {
				return .failure(.unexpectedStatus(-2))
			}
			return .failure(.unexpectedStatus(-1))
		}

		guard service.writeData(account: "__sync_metadata__", data: metadataData) else {
			var associationRestored = true
			if orgSlug != nil {
				associationRestored = restoreData(
					account: "__org_associations__",
					snapshot: oldAssociations
				)
			}
			let deleted = service.deleteProject(vaultId: project.id)
			let metadataRestored = restoreData(account: "__sync_metadata__", snapshot: oldMetadata)
			guard associationRestored, deleted, metadataRestored else {
				return .failure(.unexpectedStatus(-2))
			}
			return .failure(.unexpectedStatus(-1))
		}

		return .success(ImportPersistenceCommit(
			syncMetadata: metadata,
			orgAssociations: associations,
			warning: warning
		))
	}

	func save(_ project: VaultProject) -> KeychainResult {
		service.saveEnvironments(
			vaultId: project.id,
			projectName: project.name,
			projectPath: project.path,
			environments: project.environments
		)
	}

	func save(
		vaultId: String,
		name: String,
		path: String,
		environments: [String: [String: String]],
		mergeExisting: Bool
	) -> (VaultProject, KeychainResult) {
		var resolvedEnvironments = environments
		if mergeExisting,
			let stored = service.getEnvironments(vaultId: vaultId),
			!stored.isEmpty
		{
			for (environment, secrets) in stored {
				var merged = resolvedEnvironments[environment] ?? [:]
				merged.merge(secrets) { _, storedValue in storedValue }
				resolvedEnvironments[environment] = merged
			}
		}
		let project = VaultProject(
			id: vaultId,
			name: name,
			path: path,
			environments: resolvedEnvironments
		)
		return (project, save(project))
	}

	func removeFromSidebar(vaultId: String) {
		_ = service.removeFromSidebar(vaultId: vaultId)
	}

	func deleteProject(vaultId: String) -> Bool {
		service.deleteProject(vaultId: vaultId)
	}

	func readData(account: String) -> Data? {
		service.readData(account: account)
	}

	func writeData(account: String, data: Data) -> Bool {
		service.writeData(account: account, data: data)
	}

	private func restoreData(account: String, snapshot: Data?) -> Bool {
		if let snapshot {
			return service.writeData(account: account, data: snapshot)
		}
		return service.deleteData(account: account)
	}

	private func loadSyncMetadata() -> [String: SyncMetadata] {
		service.readData(account: "__sync_metadata__")
			.flatMap { try? JSONDecoder().decode([String: SyncMetadata].self, from: $0) } ?? [:]
	}

	private func loadOrgAssociations() -> [String: String] {
		service.readData(account: "__org_associations__")
			.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
	}

	private func writeSyncMetadata(_ metadata: [String: SyncMetadata]) -> Bool {
		guard let data = try? JSONEncoder().encode(metadata) else { return false }
		return service.writeData(account: "__sync_metadata__", data: data)
	}
}
