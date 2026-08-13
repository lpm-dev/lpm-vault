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

struct LocalEnvImportPersistenceCommit: Sendable {
	let project: VaultProject
	let syncMetadata: [String: SyncMetadata]
	let warning: String?
}

enum LocalEnvImportPersistenceResult: Sendable {
	case success(LocalEnvImportPersistenceCommit)
	case targetUnavailable
	case cancelled
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

	/// Merges a local dotenv result into the latest stored environment and
	/// publishes nothing until both the vault and dirty metadata are durable.
	/// If metadata persistence fails, the prior vault snapshot is restored.
	func importSecrets(
		projectId: String,
		projectName: String,
		projectPath: String,
		environment: String,
		secrets: [String: String],
		requestId: UUID,
		authority: LocalEnvImportAuthority
	) -> LocalEnvImportPersistenceResult {
		guard let storedProject = service.listProjects().first(where: { $0.id == projectId }),
			storedProject.name == projectName,
			storedProject.path == projectPath,
			var environments = service.getEnvironments(vaultId: projectId),
			environments[environment] != nil
		else { return .targetUnavailable }

		let previousEnvironments = environments
		var importedEnvironment = environments[environment] ?? [:]
		importedEnvironment.merge(secrets) { _, imported in imported }
		environments[environment] = importedEnvironment

		let project = VaultProject(
			id: projectId,
			name: projectName,
			path: projectPath,
			environments: environments
		)
		return persistLocalImport(
			project,
			previousEnvironments: previousEnvironments,
			target: LocalEnvImportTarget(projectId: projectId, environment: environment),
			requestId: requestId,
			authority: authority
		)
	}

	func addEnvironment(
		projectId: String,
		projectName: String,
		projectPath: String,
		environment: String,
		secrets: [String: String],
		requestId: UUID,
		authority: LocalEnvImportAuthority
	) -> LocalEnvImportPersistenceResult {
		guard let storedProject = service.listProjects().first(where: { $0.id == projectId }),
			storedProject.name == projectName,
			storedProject.path == projectPath,
			var environments = service.getEnvironments(vaultId: projectId),
			environments[environment] == nil
		else { return .targetUnavailable }
		let previousEnvironments = environments
		environments[environment] = secrets
		let project = VaultProject(
			id: projectId,
			name: projectName,
			path: projectPath,
			environments: environments
		)
		return persistLocalImport(
			project,
			previousEnvironments: previousEnvironments,
			target: LocalEnvImportTarget(projectId: projectId, environment: environment),
			requestId: requestId,
			authority: authority
		)
	}

	private func persistLocalImport(
		_ project: VaultProject,
		previousEnvironments: [String: [String: String]],
		target: LocalEnvImportTarget,
		requestId: UUID,
		authority: LocalEnvImportAuthority
	) -> LocalEnvImportPersistenceResult {
		let projectId = project.id
		let previousMetadata = service.readData(account: "__sync_metadata__")
		var metadata = previousMetadata
			.flatMap { try? JSONDecoder().decode([String: SyncMetadata].self, from: $0) } ?? [:]
		var item = metadata[projectId] ?? SyncMetadata()
		item.isDirty = true
		metadata[projectId] = item
		guard let metadataData = try? JSONEncoder().encode(metadata) else {
			return .failure(.encodingFailed)
		}
		guard authority.beginCommit(target, requestId: requestId) else {
			return .cancelled
		}

		// No suspension follows this atomic commit point. Cancellation after it
		// observes durable success and only suppresses stale UI publication.
		let saveResult = service.saveEnvironments(
			vaultId: projectId,
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
		case .failure(let error):
			return .failure(error)
		}

		guard service.writeData(account: "__sync_metadata__", data: metadataData) else {
			let restoredVault = service.saveEnvironments(
				vaultId: projectId,
				projectName: project.name,
				projectPath: project.path,
				environments: previousEnvironments
			)
			let restoredMetadata = restoreData(
				account: "__sync_metadata__",
				snapshot: previousMetadata
			)
			guard restoredMetadata, restoredVault.succeeded else {
				return .failure(.unexpectedStatus(-2))
			}
			return .failure(.unexpectedStatus(-1))
		}

		return .success(LocalEnvImportPersistenceCommit(
			project: project,
			syncMetadata: metadata,
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

private extension KeychainResult {
	var succeeded: Bool {
		switch self {
		case .success, .successWithWarning: true
		case .failure: false
		}
	}
}
