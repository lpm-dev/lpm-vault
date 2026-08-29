import Foundation

struct VaultPersistenceSnapshot: Sendable {
	let projects: [VaultProject]
	let syncMetadata: [String: SyncMetadata]
	let orgAssociations: [String: String]
}

enum DeleteProjectPersistenceResult: Sendable {
	case success(VaultPersistenceSnapshot)
	case failure(KeychainError)
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
	case caseInsensitiveCollision
	case cancelled
	case failure(KeychainError)
}

struct SecretPersistenceCommit: Sendable {
	let project: VaultProject
	let syncMetadata: [String: SyncMetadata]
	let warning: String?
}

enum SecretPersistenceResult: Sendable {
	case success(SecretPersistenceCommit)
	case targetUnavailable
	case failure(KeychainError)
}

enum VaultProjectMutation: Sendable {
	case renameProject(expectedName: String, replacement: String)
	case deleteEnvironment(name: String, expectedSecrets: [String: String])
	case duplicateEnvironment(
		source: String,
		expectedSecrets: [String: String],
		destination: String
	)
	case renameEnvironment(
		source: String,
		expectedSecrets: [String: String],
		destination: String
	)
	case clearEnvironment(name: String, expectedSecrets: [String: String])
	case updateSecret(
		environment: String,
		key: String,
		expectedValue: String,
		replacement: String
	)
	case deleteSecret(environment: String, key: String, expectedValue: String)
}

enum ProjectMutationPersistenceResult: Sendable {
	case success(SecretPersistenceCommit)
	case conflict(latest: VaultProject, metadata: [String: SyncMetadata])
	case targetUnavailable
	case failure(KeychainError)
}

struct SyncPersistenceSnapshot: Sendable {
	let project: VaultProject
	let metadata: SyncMetadata?
}

struct SyncPersistenceCommit: Sendable {
	let project: VaultProject
	let syncMetadata: [String: SyncMetadata]
	let isDirty: Bool
	let keyCount: Int
	let warning: String?
}

enum PullPersistenceResult: Sendable {
	case success(SyncPersistenceCommit)
	case conflict(latest: VaultProject, metadata: [String: SyncMetadata])
	case targetUnavailable
	case invalidPayload(String)
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

	func loadSnapshot() -> Result<VaultPersistenceSnapshot, KeychainError> {
		service.withKeychainTransaction {
			let loadedProjects: [VaultProject]
			switch service.listProjectsResult() {
			case .success(let projects): loadedProjects = projects
			case .failure(let error): return .failure(error)
			}
			let projects = loadedProjects.sorted {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
			let metadata: [String: SyncMetadata]
			switch loadSyncMetadataResult() {
			case .success(let value): metadata = value
			case .failure(let error): return .failure(error)
			}
			let associations: [String: String]
			switch loadOrgAssociationsResult() {
			case .success(let value): associations = value
			case .failure(let error): return .failure(error)
			}
			return .success(VaultPersistenceSnapshot(
				projects: projects,
				syncMetadata: metadata,
				orgAssociations: associations
			))
		}
		.flatMap { $0 }
	}

	func containsProject(vaultId: String) -> Result<Bool, KeychainError> {
		service.getProjectResult(vaultId: vaultId).map { $0 != nil }
	}

	func saveProject(_ project: VaultProject, markDirty: Bool) -> (
		result: KeychainResult,
		metadata: [String: SyncMetadata]
	) {
		switch service.withKeychainTransaction({
			saveProjectUnlocked(project, markDirty: markDirty)
		}) {
		case .success(let result): return result
		case .failure(let error): return (.failure(error), [:])
		}
	}

	private func saveProjectUnlocked(_ project: VaultProject, markDirty: Bool) -> (
		result: KeychainResult,
		metadata: [String: SyncMetadata]
	) {
		let previousMetadata: [String: SyncMetadata]
		switch loadSyncMetadataResult() {
		case .success(let metadata):
			previousMetadata = metadata
		case .failure(let error):
			return (.failure(error), [:])
		}
		guard markDirty else { return (save(project), previousMetadata) }
		let result = save(project)
		switch result {
		case .success, .successWithWarning:
			var metadata = previousMetadata
			var item = metadata[project.id] ?? SyncMetadata()
			item.isDirty = true
			metadata[project.id] = item
			guard writeSyncMetadata(metadata) else {
				return (.failure(.unexpectedStatus(-1)), previousMetadata)
			}
			return (result, metadata)
		case .failure:
			return (result, previousMetadata)
		}
	}

	/// Adds one secret to the latest durable snapshot. The in-memory store only
	/// publishes the returned project after both the vault and dirty metadata
	/// are durable. If metadata persistence fails, the prior vault is restored.
	func addSecret(
		projectId: String,
		projectName: String,
		projectPath: String,
		environment: String,
		key: String,
		value: String
	) -> SecretPersistenceResult {
		switch service.withKeychainTransaction({
			addSecretUnlocked(
				projectId: projectId,
				projectName: projectName,
				projectPath: projectPath,
				environment: environment,
				key: key,
				value: value
			)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func addSecretUnlocked(
		projectId: String,
		projectName: String,
		projectPath: String,
		environment: String,
		key: String,
		value: String
	) -> SecretPersistenceResult {
		let storedProject: VaultProject
		switch service.getProjectResult(vaultId: projectId) {
		case .success(let project?): storedProject = project
		case .success(nil): return .targetUnavailable
		case .failure(let error): return .failure(error)
		}
		guard
			storedProject.name == projectName,
			storedProject.path == projectPath,
			var environments = Optional(storedProject.environments),
			var secrets = environments[environment],
			secrets[key] == nil,
			EnvValidation.caseInsensitiveCollision(for: key, in: secrets.keys) == nil
		else { return .targetUnavailable }

		let previousEnvironments = environments
		let previousMetadata: Data?
		switch service.readDataResult(account: "__sync_metadata__") {
		case .success(let data):
			previousMetadata = data
		case .failure(let error):
			return .failure(error)
		}
		secrets[key] = value
		environments[environment] = secrets
		let project = VaultProject(
			id: projectId,
			name: projectName,
			path: projectPath,
			environments: environments
		)
		guard case .success(var metadata) = decodeDataResult(
			.success(previousMetadata), as: [String: SyncMetadata].self
		) else { return .failure(.encodingFailed) }
		var item = metadata[projectId] ?? SyncMetadata()
		item.isDirty = true
		metadata[projectId] = item
		guard let metadataData = try? JSONEncoder().encode(metadata) else {
			return .failure(.encodingFailed)
		}

		let saveResult = service.saveEnvironments(
			vaultId: projectId,
			projectName: projectName,
			projectPath: projectPath,
			environments: environments
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
				projectName: projectName,
				projectPath: projectPath,
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

		return .success(
			SecretPersistenceCommit(
				project: project,
				syncMetadata: metadata,
				warning: warning
			))
	}

	func mutateProject(
		projectId: String,
		expectedName: String,
		expectedPath: String,
		mutation: VaultProjectMutation
	) -> ProjectMutationPersistenceResult {
		switch service.withKeychainTransaction({
			mutateProjectUnlocked(
				projectId: projectId,
				expectedName: expectedName,
				expectedPath: expectedPath,
				mutation: mutation
			)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func mutateProjectUnlocked(
		projectId: String,
		expectedName: String,
		expectedPath: String,
		mutation: VaultProjectMutation
	) -> ProjectMutationPersistenceResult {
		var project: VaultProject
		switch service.getProjectResult(vaultId: projectId) {
		case .success(let stored?): project = stored
		case .success(nil): return .targetUnavailable
		case .failure(let error): return .failure(error)
		}
		let metadata: [String: SyncMetadata]
		switch loadSyncMetadataResult() {
		case .success(let value): metadata = value
		case .failure(let error): return .failure(error)
		}
		guard project.name == expectedName, project.path == expectedPath else {
			return .conflict(latest: project, metadata: metadata)
		}
		let previousProject = project

		let mutationApplies: Bool
		switch mutation {
		case .renameProject(let expectedName, let replacement):
			mutationApplies = project.name == expectedName
			if mutationApplies { project.name = replacement }
		case .deleteEnvironment(let name, let expectedSecrets):
			mutationApplies =
				project.environments.count > 1
				&& project.environments[name] == expectedSecrets
			if mutationApplies { project.environments.removeValue(forKey: name) }
		case .duplicateEnvironment(let source, let expectedSecrets, let destination):
			mutationApplies =
				project.environments[source] == expectedSecrets
				&& project.environments[destination] == nil
			if mutationApplies { project.environments[destination] = expectedSecrets }
		case .renameEnvironment(let source, let expectedSecrets, let destination):
			mutationApplies =
				project.environments[source] == expectedSecrets
				&& project.environments[destination] == nil
			if mutationApplies {
				project.environments.removeValue(forKey: source)
				project.environments[destination] = expectedSecrets
			}
		case .clearEnvironment(let name, let expectedSecrets):
			mutationApplies = project.environments[name] == expectedSecrets
			if mutationApplies { project.environments[name] = [:] }
		case .updateSecret(let environment, let key, let expectedValue, let replacement):
			mutationApplies = project.environments[environment]?[key] == expectedValue
			if mutationApplies { project.environments[environment]?[key] = replacement }
		case .deleteSecret(let environment, let key, let expectedValue):
			mutationApplies = project.environments[environment]?[key] == expectedValue
			if mutationApplies { project.environments[environment]?.removeValue(forKey: key) }
		}
		guard mutationApplies else {
			return .conflict(latest: project, metadata: metadata)
		}

		return persistMutation(
			project,
			previousProject: previousProject,
			previousMetadata: metadata
		)
	}

	private func persistMutation(
		_ project: VaultProject,
		previousProject: VaultProject,
		previousMetadata: [String: SyncMetadata]
	) -> ProjectMutationPersistenceResult {
		let previousMetadataData: Data?
		switch service.readDataResult(account: "__sync_metadata__") {
		case .success(let data): previousMetadataData = data
		case .failure(let error): return .failure(error)
		}

		var metadata = previousMetadata
		var item = metadata[project.id] ?? SyncMetadata()
		item.isDirty = true
		metadata[project.id] = item
		guard let metadataData = try? JSONEncoder().encode(metadata) else {
			return .failure(.encodingFailed)
		}

		let saveResult = save(project)
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
			let restoredProject = save(previousProject)
			let restoredMetadata = restoreData(
				account: "__sync_metadata__",
				snapshot: previousMetadataData
			)
			guard restoredProject.succeeded, restoredMetadata else {
				return .failure(.unexpectedStatus(-2))
			}
			return .failure(.unexpectedStatus(-1))
		}

		return .success(
			SecretPersistenceCommit(
				project: project,
				syncMetadata: metadata,
				warning: warning
			))
	}

	func syncSnapshot(vaultId: String) -> SyncPersistenceSnapshot? {
		guard
			case .success(let snapshot) = service.withKeychainTransaction({
				() -> SyncPersistenceSnapshot? in
				guard case .success(let loadedProject) = service.getProjectResult(vaultId: vaultId),
					let project = loadedProject,
					case .success(let metadata) = loadSyncMetadataResult()
				else { return nil }
				return SyncPersistenceSnapshot(project: project, metadata: metadata[vaultId])
			})
		else { return nil }
		return snapshot
	}

	func finishPush(
		pushedProject: VaultProject,
		action: String,
		version: Int?
	) -> SyncPersistenceCommit? {
		guard
			case .success(let result) = service.withKeychainTransaction({
				finishPushUnlocked(pushedProject: pushedProject, action: action, version: version)
			})
		else { return nil }
		return result
	}

	private func finishPushUnlocked(
		pushedProject: VaultProject,
		action: String,
		version: Int?
	) -> SyncPersistenceCommit? {
		guard
			case .success(let loadedProject) = service.getProjectResult(vaultId: pushedProject.id),
			let durableProject = loadedProject,
			case .success(var metadata) = loadSyncMetadataResult()
		else { return nil }
		let changedDuringPush = durableProject != pushedProject
		var item = metadata[pushedProject.id] ?? SyncMetadata()
		item.isDirty = changedDuringPush
		item.lastSyncedAt = Date()
		item.lastAction = action
		item.lastVersion = version
		metadata[pushedProject.id] = item
		guard writeSyncMetadata(metadata) else { return nil }
		return SyncPersistenceCommit(
			project: durableProject,
			syncMetadata: metadata,
			isDirty: changedDuringPush,
			keyCount: durableProject.environments.values.reduce(0) { $0 + $1.count },
			warning: nil
		)
	}

	func commitPull(
		baseline: VaultProject,
		remotePayload: Data,
		action: String,
		version: Int
	) -> PullPersistenceResult {
		switch service.withKeychainTransaction({
			commitPullUnlocked(
				baseline: baseline,
				remotePayload: remotePayload,
				action: action,
				version: version
			)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func commitPullUnlocked(
		baseline: VaultProject,
		remotePayload: Data,
		action: String,
		version: Int
	) -> PullPersistenceResult {
		let durableProject: VaultProject
		switch service.getProjectResult(vaultId: baseline.id) {
		case .success(let stored?): durableProject = stored
		case .success(nil): return .targetUnavailable
		case .failure(let error): return .failure(error)
		}
		let previousMetadataData: Data?
		switch service.readDataResult(account: "__sync_metadata__") {
		case .success(let data): previousMetadataData = data
		case .failure(let error): return .failure(error)
		}
		guard case .success(let previousMetadata) = decodeDataResult(
			.success(previousMetadataData), as: [String: SyncMetadata].self
		) else { return .failure(.encodingFailed) }

		let remoteEnvironments: [String: [String: String]]
		let merge: EnvValidation.MergeResult
		do {
			remoteEnvironments = try EnvValidation.decodeRemoteEnvironments(remotePayload)
			merge = try EnvValidation.mergeRemoteEnvironments(
				remoteEnvironments,
				into: durableProject.environments
			)
		} catch {
			return .invalidPayload(error.localizedDescription)
		}

		for (environment, remoteSecrets) in remoteEnvironments {
			for (key, remoteValue) in remoteSecrets {
				let baselineValue = baseline.environments[environment]?[key]
				let durableValue = durableProject.environments[environment]?[key]
				if durableValue != baselineValue, durableValue != remoteValue {
					return .conflict(latest: durableProject, metadata: previousMetadata)
				}
			}
		}

		var mergedProject = durableProject
		mergedProject.environments = merge.environments
		let cloudComparable = remoteEnvironments.filter { !$0.value.isEmpty }
		let localComparable = merge.environments.filter { !$0.value.isEmpty }
		let isDirty = localComparable != cloudComparable
		var metadata = previousMetadata
		var item = metadata[baseline.id] ?? SyncMetadata()
		item.isDirty = isDirty
		item.lastSyncedAt = Date()
		item.lastAction = action
		item.lastVersion = version
		metadata[baseline.id] = item
		guard let metadataData = try? JSONEncoder().encode(metadata) else {
			return .failure(.encodingFailed)
		}

		let saveResult = save(mergedProject)
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
			let restoredProject = save(durableProject)
			let restoredMetadata = restoreData(
				account: "__sync_metadata__",
				snapshot: previousMetadataData
			)
			guard restoredProject.succeeded, restoredMetadata else {
				return .failure(.unexpectedStatus(-2))
			}
			return .failure(.unexpectedStatus(-1))
		}

		return .success(
			SyncPersistenceCommit(
				project: mergedProject,
				syncMetadata: metadata,
				isDirty: isDirty,
				keyCount: merge.keyCount,
				warning: warning
			))
	}

	func associate(vaultId: String, orgSlug: String) -> [String: String]? {
		guard
			case .success(let result) = service.withKeychainTransaction({
				associateUnlocked(vaultId: vaultId, orgSlug: orgSlug)
			})
		else { return nil }
		return result
	}

	private func associateUnlocked(vaultId: String, orgSlug: String) -> [String: String]? {
		guard case .success(var associations) = loadOrgAssociationsResult() else { return nil }
		associations[vaultId] = orgSlug
		guard let data = try? JSONEncoder().encode(associations),
			service.writeData(account: "__org_associations__", data: data)
		else { return nil }
		return associations
	}

	func deleteProjectAndMetadata(vaultId: String) -> DeleteProjectPersistenceResult {
		switch service.withKeychainTransaction({
			deleteProjectAndMetadataUnlocked(vaultId: vaultId)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func deleteProjectAndMetadataUnlocked(vaultId: String) -> DeleteProjectPersistenceResult {
		let project: VaultProject
		switch service.getProjectResult(vaultId: vaultId) {
		case .success(let stored?): project = stored
		case .success(nil): return .failure(.itemNotFound)
		case .failure(let error): return .failure(error)
		}
		let previousMetadataData: Data?
		switch service.readDataResult(account: "__sync_metadata__") {
		case .success(let data): previousMetadataData = data
		case .failure(let error): return .failure(error)
		}
		let previousAssociationsData: Data?
		switch service.readDataResult(account: "__org_associations__") {
		case .success(let data): previousAssociationsData = data
		case .failure(let error): return .failure(error)
		}
		guard
			case .success(var metadata) = decodeDataResult(
				.success(previousMetadataData), as: [String: SyncMetadata].self),
			case .success(var associations) = decodeDataResult(
				.success(previousAssociationsData), as: [String: String].self)
		else { return .failure(.encodingFailed) }
		guard service.deleteProject(vaultId: vaultId) else { return .failure(.accessDenied) }
		metadata.removeValue(forKey: vaultId)
		associations.removeValue(forKey: vaultId)
		guard let associationData = try? JSONEncoder().encode(associations),
			let metadataData = try? JSONEncoder().encode(metadata)
		else { return restoreDeletedProject(
			project,
			metadata: previousMetadataData,
			associations: previousAssociationsData,
			originalError: .encodingFailed
		) }
		guard service.writeData(account: "__org_associations__", data: associationData),
			service.writeData(account: "__sync_metadata__", data: metadataData)
		else {
			return restoreDeletedProject(
				project,
				metadata: previousMetadataData,
				associations: previousAssociationsData,
				originalError: .unexpectedStatus(-1)
			)
		}
		let remainingProjects: [VaultProject]
		switch service.listProjectsResult() {
		case .success(let projects): remainingProjects = projects
		case .failure(let error): return .failure(error)
		}
		return .success(
			VaultPersistenceSnapshot(
				projects: remainingProjects.sorted {
					$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
				},
				syncMetadata: metadata,
				orgAssociations: associations
			)
		)
	}

	private func restoreDeletedProject(
		_ project: VaultProject,
		metadata: Data?,
		associations: Data?,
		originalError: KeychainError
	) -> DeleteProjectPersistenceResult {
		let restoredProject = save(project)
		let restoredMetadata = restoreData(account: "__sync_metadata__", snapshot: metadata)
		let restoredAssociations = restoreData(
			account: "__org_associations__",
			snapshot: associations
		)
		guard restoredProject.succeeded, restoredMetadata, restoredAssociations else {
			return .failure(.unexpectedStatus(-2))
		}
		return .failure(originalError)
	}

	/// Commits a fully resolved import as one logical transaction. The project
	/// is never indexed until its final decrypted contents are available.
	func importProject(
		_ project: VaultProject,
		orgSlug: String?,
		version: Int
	) -> ImportPersistenceResult {
		switch service.withKeychainTransaction({
			importProjectUnlocked(project, orgSlug: orgSlug, version: version)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func importProjectUnlocked(
		_ project: VaultProject,
		orgSlug: String?,
		version: Int
	) -> ImportPersistenceResult {
		switch containsProject(vaultId: project.id) {
		case .success(true): return .duplicate
		case .success(false): break
		case .failure(let error): return .failure(error)
		}

		let oldMetadata: Data?
		switch service.readDataResult(account: "__sync_metadata__") {
		case .success(let data): oldMetadata = data
		case .failure(let error): return .failure(error)
		}
		let oldAssociations: Data?
		switch service.readDataResult(account: "__org_associations__") {
		case .success(let data): oldAssociations = data
		case .failure(let error): return .failure(error)
		}
		guard case .success(var metadata) = decodeDataResult(
			.success(oldMetadata), as: [String: SyncMetadata].self
		) else { return .failure(.encodingFailed) }
		metadata[project.id] = SyncMetadata(
			lastSyncedAt: Date(),
			lastAction: "pull",
			lastVersion: version,
			isDirty: false
		)
		guard case .success(var associations) = decodeDataResult(
			.success(oldAssociations), as: [String: String].self
		) else { return .failure(.encodingFailed) }
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

		return .success(
			ImportPersistenceCommit(
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
		switch service.withKeychainTransaction({
			importSecretsUnlocked(
				projectId: projectId,
				projectName: projectName,
				projectPath: projectPath,
				environment: environment,
				secrets: secrets,
				requestId: requestId,
				authority: authority
			)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func importSecretsUnlocked(
		projectId: String,
		projectName: String,
		projectPath: String,
		environment: String,
		secrets: [String: String],
		requestId: UUID,
		authority: LocalEnvImportAuthority
	) -> LocalEnvImportPersistenceResult {
		let storedProject: VaultProject
		switch service.getProjectResult(vaultId: projectId) {
		case .success(let project?): storedProject = project
		case .success(nil): return .targetUnavailable
		case .failure(let error): return .failure(error)
		}
		guard
			storedProject.name == projectName,
			storedProject.path == projectPath,
			var environments = Optional(storedProject.environments),
			environments[environment] != nil
		else { return .targetUnavailable }

		let previousEnvironments = environments
		var importedEnvironment = environments[environment] ?? [:]
		var exactKeys = Set(importedEnvironment.keys)
		var foldedKeys = Set(importedEnvironment.keys.map { $0.lowercased() })
		for key in secrets.keys {
			if exactKeys.contains(key) { continue }
			let foldedKey = key.lowercased()
			guard foldedKeys.insert(foldedKey).inserted else {
				return .caseInsensitiveCollision
			}
			exactKeys.insert(key)
		}
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
		switch service.withKeychainTransaction({
			addEnvironmentUnlocked(
				projectId: projectId,
				projectName: projectName,
				projectPath: projectPath,
				environment: environment,
				secrets: secrets,
				requestId: requestId,
				authority: authority
			)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func addEnvironmentUnlocked(
		projectId: String,
		projectName: String,
		projectPath: String,
		environment: String,
		secrets: [String: String],
		requestId: UUID,
		authority: LocalEnvImportAuthority
	) -> LocalEnvImportPersistenceResult {
		let storedProject: VaultProject
		switch service.getProjectResult(vaultId: projectId) {
		case .success(let project?): storedProject = project
		case .success(nil): return .targetUnavailable
		case .failure(let error): return .failure(error)
		}
		guard
			storedProject.name == projectName,
			storedProject.path == projectPath,
			var environments = Optional(storedProject.environments),
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
		let previousMetadata: Data?
		switch service.readDataResult(account: "__sync_metadata__") {
		case .success(let data): previousMetadata = data
		case .failure(let error): return .failure(error)
		}
		guard case .success(var metadata) = decodeDataResult(
			.success(previousMetadata), as: [String: SyncMetadata].self
		) else { return .failure(.encodingFailed) }
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

		return .success(
			LocalEnvImportPersistenceCommit(
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
		switch service.withKeychainTransaction({
			saveUnlocked(
				vaultId: vaultId,
				name: name,
				path: path,
				environments: environments,
				mergeExisting: mergeExisting
			)
		}) {
		case .success(let result): return result
		case .failure(let error):
			return (
				VaultProject(id: vaultId, name: name, path: path, environments: environments),
				.failure(error)
			)
		}
	}

	private func saveUnlocked(
		vaultId: String,
		name: String,
		path: String,
		environments: [String: [String: String]],
		mergeExisting: Bool
	) -> (VaultProject, KeychainResult) {
		var resolvedEnvironments = environments
		if mergeExisting {
			switch service.getEnvironmentsResult(vaultId: vaultId) {
			case .failure(let error):
				return (
					VaultProject(id: vaultId, name: name, path: path, environments: environments),
					.failure(error)
				)
			case .success(let stored?):
				if !stored.isEmpty {
					for (environment, secrets) in stored {
						var merged = resolvedEnvironments[environment] ?? [:]
						merged.merge(secrets) { _, storedValue in storedValue }
						resolvedEnvironments[environment] = merged
					}
				}
			case .success(nil):
				break
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

	private func loadSyncMetadataResult() -> Result<[String: SyncMetadata], KeychainError> {
		decodeDataResult(
			service.readDataResult(account: "__sync_metadata__"),
			as: [String: SyncMetadata].self
		)
	}

	private func loadOrgAssociationsResult() -> Result<[String: String], KeychainError> {
		decodeDataResult(
			service.readDataResult(account: "__org_associations__"),
			as: [String: String].self
		)
	}

	private func decodeDataResult<Value: Decodable>(
		_ result: Result<Data?, KeychainError>,
		as type: Value.Type
	) -> Result<Value, KeychainError> where Value: ExpressibleByDictionaryLiteral {
		switch result {
		case .failure(let error):
			return .failure(error)
		case .success(nil):
			return .success([:])
		case .success(let data?):
			do {
				return .success(try JSONDecoder().decode(type, from: data))
			} catch {
				return .failure(.encodingFailed)
			}
		}
	}

	private func writeSyncMetadata(_ metadata: [String: SyncMetadata]) -> Bool {
		guard let data = try? JSONEncoder().encode(metadata) else { return false }
		return service.writeData(account: "__sync_metadata__", data: data)
	}
}

extension KeychainResult {
	fileprivate var succeeded: Bool {
		switch self {
		case .success, .successWithWarning: true
		case .failure: false
		}
	}
}
