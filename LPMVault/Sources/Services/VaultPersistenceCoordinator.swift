import Foundation

private struct PersistedOrgKeyTrust: Codable {
	let schemaVersion: Int
	let scope: OrgTrustScope
	let trust: OrgKeyTrust
}

private struct PersistedSyncMetadataRecord: Codable {
	let schemaVersion: Int
	let vaultId: String
	let metadata: SyncMetadata
}

private struct SyncMetadataRecordSnapshot {
	let account: String
	let data: Data?
	let metadata: SyncMetadata?
}

struct VaultPersistenceSnapshot: Sendable {
	let projects: [VaultProject]
	let syncMetadata: [String: SyncMetadata]
	let orgAssociations: [String: String]
}

struct ProjectCreationRecord: Sendable {
	let project: VaultProject?
	let orgAssociations: [String: String]
}

enum DeleteProjectPersistenceResult: Sendable {
	case success(VaultPersistenceSnapshot)
	case failure(KeychainError)
}

struct ImportPersistenceCommit: Sendable {
	let project: VaultProject
	let syncMetadata: SyncMetadata?
	let orgAssociations: [String: String]
	let warning: String?
}

enum ImportPersistenceResult: Sendable {
	case success(ImportPersistenceCommit)
	case duplicate
	case conflict
	case staleVersion
	case cancelled
	case failure(KeychainError)
}

struct ProjectCreationPersistenceCommit: Sendable {
	let orgAssociations: [String: String]
	let warning: String?
}

enum ProjectCreationPersistenceResult: Sendable {
	case success(ProjectCreationPersistenceCommit)
	case failure(KeychainError)
}

struct LocalEnvImportPersistenceCommit: Sendable {
	let project: VaultProject
	let syncMetadata: SyncMetadata?
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
	let syncMetadata: SyncMetadata?
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
	case conflict(latest: VaultProject, metadata: SyncMetadata?)
	case targetUnavailable
	case failure(KeychainError)
}

struct SyncPersistenceSnapshot: Sendable {
	let project: VaultProject
	let metadata: SyncMetadata?
	let bindingConflict: Bool
}

struct SyncPersistenceCommit: Sendable {
	let project: VaultProject
	let syncMetadata: SyncMetadata?
	let isDirty: Bool
	let keyCount: Int
	let warning: String?
}

enum PullPersistenceResult: Sendable {
	case success(SyncPersistenceCommit)
	case conflict(latest: VaultProject, metadata: SyncMetadata?)
	case staleVersion(latest: VaultProject, metadata: SyncMetadata?)
	case targetUnavailable
	case invalidPayload(String)
	case cancelled
	case failure(KeychainError)
}

/// Serializes Keychain mutations so older snapshots cannot finish after newer ones.
actor VaultPersistenceCoordinator {
	private static let syncMetadataRecordPrefix = VaultKeychainRecordContract.syncMetadataRecordPrefix
	private static let syncMetadataSchemaVersion = VaultKeychainRecordContract.syncMetadataSchemaVersion

	private let service: KeychainServiceProtocol

	init(service: KeychainServiceProtocol) {
		self.service = service
	}

	func listProjects() -> [VaultProject] {
		service.listProjects()
	}

	func loadSnapshot() -> Result<VaultPersistenceSnapshot, KeychainError> {
		service.withKeychainTransaction {
			let loadedMetadata: [VaultProjectMetadata]
			switch service.listProjectMetadataResult() {
			case .success(let metadata): loadedMetadata = metadata
			case .failure(let error): return .failure(error)
			}
			let projects = loadedMetadata.map(VaultProject.init(metadata:)).sorted {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
			let metadata: [String: SyncMetadata]
			switch loadSyncMetadataResult(projectIds: projects.map(\.id)) {
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

	func loadProject(vaultId: String) -> Result<VaultProject?, KeychainError> {
		service.getProjectResult(vaultId: vaultId)
	}

	func loadProjectCreationRecord(
		vaultId: String
	) -> Result<ProjectCreationRecord, KeychainError> {
		service.withKeychainTransaction {
			let project: VaultProject?
			switch service.getProjectResult(vaultId: vaultId) {
			case .success(let loaded): project = loaded
			case .failure(let error): return .failure(error)
			}
			let associations: [String: String]
			switch loadOrgAssociationsResult() {
			case .success(let loaded): associations = loaded
			case .failure(let error): return .failure(error)
			}
			return .success(ProjectCreationRecord(
				project: project,
				orgAssociations: associations
			))
		}
		.flatMap { $0 }
	}

	func containsProject(vaultId: String) -> Result<Bool, KeychainError> {
		service.getProjectResult(vaultId: vaultId).map { $0 != nil }
	}

	func loadOrgTrust(scope: OrgTrustScope) -> Result<OrgKeyTrust, KeychainError> {
		switch service.readDataResult(account: scope.storageAccount) {
		case .success(nil): return .success(OrgKeyTrust())
		case .success(let data?):
			guard let persisted = try? JSONDecoder().decode(PersistedOrgKeyTrust.self, from: data),
				persisted.schemaVersion == OrgTrustRecordContract.schemaVersion,
				persisted.scope == scope
			else {
				return .failure(.encodingFailed)
			}
			return .success(persisted.trust)
		case .failure(let error): return .failure(error)
		}
	}

	func saveOrgTrust(_ trust: OrgKeyTrust, scope: OrgTrustScope) -> Bool {
		let persisted = PersistedOrgKeyTrust(
			schemaVersion: OrgTrustRecordContract.schemaVersion,
			scope: scope,
			trust: trust
		)
		guard let data = try? JSONEncoder().encode(persisted) else { return false }
		return service.writeData(account: scope.storageAccount, data: data)
	}

	func createProject(
		_ project: VaultProject,
		orgSlug: String?
	) -> ProjectCreationPersistenceResult {
		switch service.withKeychainTransaction({
			createProjectUnlocked(project, orgSlug: orgSlug)
		}) {
		case .success(let result): result
		case .failure(let error): .failure(error)
		}
	}

	private func createProjectUnlocked(
		_ project: VaultProject,
		orgSlug: String?
	) -> ProjectCreationPersistenceResult {
		guard case .success(var associations) = loadOrgAssociationsResult()
		else { return .failure(.encodingFailed) }
		if let orgSlug { associations[project.id] = orgSlug }
		var mutations: [VaultKeychainMutation] = []
		if orgSlug != nil {
			guard let data = try? JSONEncoder().encode(associations) else {
				return .failure(.encodingFailed)
			}
			mutations.append(.write(account: "__org_associations__", data: data))
		}
		let saveResult = service.applyVaultTransaction(
			project: .create(project),
			data: mutations
		)
		let warning: String?
		switch saveResult {
		case .success: warning = nil
		case .successWithWarning(let message): warning = message
		case .failure(let error): return .failure(error)
		}

		return .success(ProjectCreationPersistenceCommit(
			orgAssociations: associations,
			warning: warning
		))
	}

	func saveProject(_ project: VaultProject, markDirty: Bool) -> (
		result: KeychainResult,
		metadata: SyncMetadata?
	) {
		switch service.withKeychainTransaction({
			saveProjectUnlocked(project, markDirty: markDirty)
		}) {
		case .success(let result): return result
		case .failure(let error): return (.failure(error), nil)
		}
	}

	private func saveProjectUnlocked(_ project: VaultProject, markDirty: Bool) -> (
		result: KeychainResult,
		metadata: SyncMetadata?
	) {
		let previousMetadata: SyncMetadataRecordSnapshot
		switch loadSyncMetadataRecordSnapshotResult(vaultId: project.id) {
		case .success(let snapshot):
			previousMetadata = snapshot
		case .failure(let error):
			return (.failure(error), nil)
		}
		guard markDirty else { return (save(project), previousMetadata.metadata) }
		var item = previousMetadata.metadata ?? SyncMetadata()
		item.isDirty = true
		guard let mutation = syncMetadataMutation(item, vaultId: project.id) else {
			return (.failure(.encodingFailed), previousMetadata.metadata)
		}
		let result = service.applyVaultTransaction(project: .upsert(project), data: [mutation])
		return (result, result.succeeded ? item : previousMetadata.metadata)
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

		let previousMetadata: SyncMetadataRecordSnapshot
		switch loadSyncMetadataRecordSnapshotResult(vaultId: projectId) {
		case .success(let snapshot):
			previousMetadata = snapshot
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
		var item = previousMetadata.metadata ?? SyncMetadata()
		item.isDirty = true

		guard let metadataMutation = syncMetadataMutation(item, vaultId: projectId) else {
			return .failure(.encodingFailed)
		}
		let saveResult = service.applyVaultTransaction(
			project: .update(vaultId: projectId, environments: environments),
			data: [metadataMutation]
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

		return .success(
			SecretPersistenceCommit(
				project: project,
				syncMetadata: item,
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
		let metadata: SyncMetadataRecordSnapshot
		switch loadSyncMetadataRecordSnapshotResult(vaultId: projectId) {
		case .success(let snapshot):
			metadata = snapshot
		case .failure(let error): return .failure(error)
		}
		guard project.name == expectedName, project.path == expectedPath else {
			return .conflict(latest: project, metadata: metadata.metadata)
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
			return .conflict(latest: project, metadata: metadata.metadata)
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
		previousMetadata: SyncMetadataRecordSnapshot
	) -> ProjectMutationPersistenceResult {
		var item = previousMetadata.metadata ?? SyncMetadata()
		item.isDirty = true

		guard let metadataMutation = syncMetadataMutation(item, vaultId: project.id) else {
			return .failure(.encodingFailed)
		}
		let projectMutation: VaultProjectKeychainMutation =
			project.name == previousProject.name && project.path == previousProject.path
			? .update(vaultId: project.id, environments: project.environments)
			: .upsert(project)
		let saveResult = service.applyVaultTransaction(
			project: projectMutation,
			data: [metadataMutation]
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

		return .success(
			SecretPersistenceCommit(
				project: project,
				syncMetadata: item,
				warning: warning
			))
	}

	func syncSnapshot(
		vaultId: String,
		binding: SyncPrincipalBinding
	) -> SyncPersistenceSnapshot? {
		guard
			case .success(let snapshot) = service.withKeychainTransaction({
				() -> SyncPersistenceSnapshot? in
				guard case .success(let loadedProject) = service.getProjectResult(vaultId: vaultId),
					let project = loadedProject,
					case .success(let metadata) = loadSyncMetadataRecordSnapshotResult(
						vaultId: vaultId
					)
				else { return nil }
				let storedMetadata = metadata.metadata
				let scopedMetadata = storedMetadata?.scoped(to: binding)
				return SyncPersistenceSnapshot(
					project: project,
					metadata: scopedMetadata,
					bindingConflict: storedMetadata?.conflicts(with: binding) ?? false
				)
			})
		else { return nil }
		return snapshot
	}

	func finishPush(
		pushedProject: VaultProject,
		action: String,
		version: Int?,
		binding: SyncPrincipalBinding
	) -> SyncPersistenceCommit? {
		guard
			case .success(let result) = service.withKeychainTransaction({
				finishPushUnlocked(
					pushedProject: pushedProject,
					action: action,
					version: version,
					binding: binding
				)
			})
		else { return nil }
		return result
	}

	private func finishPushUnlocked(
		pushedProject: VaultProject,
		action: String,
		version: Int?,
		binding: SyncPrincipalBinding
	) -> SyncPersistenceCommit? {
		guard
			case .success(let loadedProject) = service.getProjectResult(vaultId: pushedProject.id),
			let durableProject = loadedProject,
			case .success(let metadata) = loadSyncMetadataRecordSnapshotResult(
				vaultId: pushedProject.id
			)
		else { return nil }
		let changedDuringPush = durableProject != pushedProject
		var item = metadata.metadata ?? SyncMetadata()
		guard let version else { return nil }
		do {
			try item.record(
				binding: binding,
				version: version,
				action: action,
				date: Date(),
				isDirty: changedDuringPush
			)
		} catch {
			return nil
		}
		guard writeSyncMetadata(item, vaultId: pushedProject.id) else { return nil }
		return SyncPersistenceCommit(
			project: durableProject,
			syncMetadata: item,
			isDirty: changedDuringPush,
			keyCount: durableProject.environments.values.reduce(0) { $0 + $1.count },
			warning: nil
		)
	}

	func commitPull(
		baseline: VaultProject,
		remotePayload: Data,
		action: String,
		version: Int,
		binding: SyncPrincipalBinding
	) -> PullPersistenceResult {
		switch service.withKeychainTransaction({
			commitPullUnlocked(
				baseline: baseline,
				remotePayload: remotePayload,
				action: action,
				version: version,
				binding: binding
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
		version: Int,
		binding: SyncPrincipalBinding
	) -> PullPersistenceResult {
		let durableProject: VaultProject
		switch service.getProjectResult(vaultId: baseline.id) {
		case .success(let stored?): durableProject = stored
		case .success(nil): return .targetUnavailable
		case .failure(let error): return .failure(error)
		}
		let previousMetadata: SyncMetadataRecordSnapshot
		switch loadSyncMetadataRecordSnapshotResult(vaultId: baseline.id) {
		case .success(let snapshot): previousMetadata = snapshot
		case .failure(let error): return .failure(error)
		}
		if let currentVersion = previousMetadata.metadata?.version(boundTo: binding),
			version < currentVersion
		{
			return .staleVersion(latest: durableProject, metadata: previousMetadata.metadata)
		}

		let remote: EnvValidation.ValidatedRemoteEnvironments
		let merge: EnvValidation.MergeResult
		do {
			remote = try EnvValidation.decodeRemoteEnvironments(remotePayload)
			merge = try EnvValidation.mergeRemoteEnvironments(
				remote,
				into: durableProject.environments
			)
		} catch {
			return .invalidPayload(error.localizedDescription)
		}

		for (environment, remoteSecrets) in remote.environments {
			if baseline.environments[environment] != nil,
				durableProject.environments[environment] == nil
			{
				return .conflict(latest: durableProject, metadata: previousMetadata.metadata)
			}
			for (key, remoteValue) in remoteSecrets {
				let baselineValue = baseline.environments[environment]?[key]
				let durableValue = durableProject.environments[environment]?[key]
				if durableValue != baselineValue, durableValue != remoteValue {
					return .conflict(latest: durableProject, metadata: previousMetadata.metadata)
				}
			}
		}

		var mergedProject = durableProject
		mergedProject.environments = merge.environments
		let isDirty = merge.environments != remote.environments
		var item = previousMetadata.metadata ?? SyncMetadata()
		do {
			try item.record(
				binding: binding,
				version: version,
				action: action,
				date: Date(),
				isDirty: isDirty
			)
		} catch SyncCheckpointError.rollback {
			return .staleVersion(latest: durableProject, metadata: previousMetadata.metadata)
		} catch {
			return .failure(.syncCheckpointCapacity)
		}

		guard let metadataMutation = syncMetadataMutation(item, vaultId: baseline.id) else {
			return .failure(.encodingFailed)
		}
		let saveResult = service.applyVaultTransaction(
			project: .update(
				vaultId: mergedProject.id,
				environments: mergedProject.environments
			),
			data: [metadataMutation]
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
		return .success(
			SyncPersistenceCommit(
				project: mergedProject,
				syncMetadata: item,
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
		let projectMetadata: [VaultProjectMetadata]
		switch service.listProjectMetadataResult() {
		case .success(let stored): projectMetadata = stored
		case .failure(let error): return .failure(error)
		}
		guard projectMetadata.contains(where: { $0.id == vaultId }) else {
			return .failure(.itemNotFound)
		}
		switch service.getProjectResult(vaultId: vaultId) {
		case .success(.some): break
		case .success(nil): return .failure(.itemNotFound)
		case .failure(let error): return .failure(error)
		}
		let metadata: [String: SyncMetadata]
		switch loadSyncMetadataResult(projectIds: projectMetadata.map(\.id)) {
		case .success(let value): metadata = value
		case .failure(let error): return .failure(error)
		}
		let previousMetadata: SyncMetadataRecordSnapshot
		switch loadSyncMetadataRecordSnapshotResult(vaultId: vaultId) {
		case .success(let snapshot): previousMetadata = snapshot
		case .failure(let error): return .failure(error)
		}
		guard case .success(var associations) = loadOrgAssociationsResult()
		else { return .failure(.encodingFailed) }
		var remainingMetadata = metadata
		remainingMetadata.removeValue(forKey: vaultId)
		associations.removeValue(forKey: vaultId)
		guard let associationData = try? JSONEncoder().encode(associations)
		else { return .failure(.encodingFailed) }
		var mutations = [
			VaultKeychainMutation.write(
				account: "__org_associations__",
				data: associationData
			)
		]
		if previousMetadata.data != nil {
			mutations.append(.delete(account: previousMetadata.account))
		}
		switch service.applyVaultTransaction(
		project: .delete(vaultId: vaultId, deletePayload: true),
		data: mutations
	) {
		case .success, .successWithWarning:
			break
		case .failure(let error):
			return .failure(error)
		}
		let remainingProjects = projectMetadata
			.filter { $0.id != vaultId }
			.map(VaultProject.init(metadata:))
		return .success(
			VaultPersistenceSnapshot(
				projects: remainingProjects.sorted {
					$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
				},
				syncMetadata: remainingMetadata,
				orgAssociations: associations
			)
		)
	}

	/// Commits a fully resolved import as one logical transaction. The project
	/// is never indexed until its final decrypted contents are available.
	func importProject(
		_ project: VaultProject,
		orgSlug: String?,
		version: Int,
		binding: SyncPrincipalBinding,
		existing: ProjectCreationRecord? = nil
	) -> ImportPersistenceResult {
		switch service.withKeychainTransaction({
			importProjectUnlocked(
				project,
				orgSlug: orgSlug,
				version: version,
				binding: binding,
				existing: existing
			)
		}) {
		case .success(let result): return result
		case .failure(let error): return .failure(error)
		}
	}

	private func importProjectUnlocked(
		_ project: VaultProject,
		orgSlug: String?,
		version: Int,
		binding: SyncPrincipalBinding,
		existing: ProjectCreationRecord?
	) -> ImportPersistenceResult {
		guard case .success(var associations) = loadOrgAssociationsResult()
		else { return .failure(.encodingFailed) }
		var importedProject = project
		var metadata = SyncMetadata()
		if let existing {
			guard let baseline = existing.project, orgSlug != nil, baseline.id == project.id,
				associations[project.id] == existing.orgAssociations[project.id]
			else { return .conflict }
			switch service.getProjectResult(vaultId: project.id) {
			case .success(let durable) where durable == baseline: break
			case .success: return .conflict
			case .failure(let error): return .failure(error)
			}
			switch loadSyncMetadataRecordSnapshotResult(vaultId: project.id) {
			case .success(let snapshot): metadata = snapshot.metadata ?? SyncMetadata()
			case .failure(let error): return .failure(error)
			}
			let remote = EnvValidation.ValidatedRemoteEnvironments(
				environments: project.environments,
				keyCount: project.environments.values.reduce(0) { $0 + $1.count }
			)
			guard let merged = try? EnvValidation.mergeRemoteEnvironments(remote, into: baseline.environments)
			else { return .failure(.encodingFailed) }
			importedProject = baseline
			importedProject.environments = merged.environments
		} else {
			switch containsProject(vaultId: project.id) {
			case .success(true): return .duplicate
			case .success(false): break
			case .failure(let error): return .failure(error)
			}
		}
		do {
			try metadata.record(
				binding: binding, version: version, action: "pull", date: Date(),
				isDirty: importedProject.environments != project.environments
			)
		} catch SyncCheckpointError.rollback {
			return .staleVersion
		} catch {
			return .failure(.syncCheckpointCapacity)
		}
		if let orgSlug { associations[project.id] = orgSlug }

		guard let associationData = try? JSONEncoder().encode(associations)
		else { return .failure(.encodingFailed) }
		guard let metadataMutation = syncMetadataMutation(metadata, vaultId: project.id)
		else { return .failure(.encodingFailed) }
		var mutations = [metadataMutation]
		if orgSlug != nil {
			mutations.append(.write(account: "__org_associations__", data: associationData))
		}
		let saveResult = service.applyVaultTransaction(
			project: existing == nil ? .create(importedProject) : .update(
				vaultId: importedProject.id, environments: importedProject.environments
			),
			data: mutations
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

		return .success(
			ImportPersistenceCommit(
				project: importedProject,
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
		environments[environment] = secrets
		let project = VaultProject(
			id: projectId,
			name: projectName,
			path: projectPath,
			environments: environments
		)
		return persistLocalImport(
			project,
			target: LocalEnvImportTarget(projectId: projectId, environment: environment),
			requestId: requestId,
			authority: authority
		)
	}

	private func persistLocalImport(
		_ project: VaultProject,
		target: LocalEnvImportTarget,
		requestId: UUID,
		authority: LocalEnvImportAuthority
	) -> LocalEnvImportPersistenceResult {
		let projectId = project.id
		let currentMetadata: SyncMetadataRecordSnapshot
		switch loadSyncMetadataRecordSnapshotResult(vaultId: projectId) {
		case .success(let snapshot): currentMetadata = snapshot
		case .failure(let error): return .failure(error)
		}
		var item = currentMetadata.metadata ?? SyncMetadata()
		item.isDirty = true
		guard authority.beginCommit(target, requestId: requestId) else {
			return .cancelled
		}
		guard let metadataMutation = syncMetadataMutation(item, vaultId: projectId)
		else { return .failure(.encodingFailed) }
		let saveResult = service.applyVaultTransaction(
			project: .update(vaultId: projectId, environments: project.environments),
			data: [metadataMutation]
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
		return .success(
			LocalEnvImportPersistenceCommit(
				project: project,
				syncMetadata: item,
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

	private func saveMutationProject(
		_ project: VaultProject,
		previousProject: VaultProject
	) -> KeychainResult {
		guard project.name == previousProject.name,
			project.path == previousProject.path
		else { return save(project) }
		return service.updateEnvironments(
			vaultId: project.id,
			environments: project.environments
		)
	}

	func removeFromSidebar(vaultId: String) -> Bool {
		service.removeFromSidebar(vaultId: vaultId)
	}

	func readData(account: String) -> Data? {
		service.readData(account: account)
	}

	func writeData(account: String, data: Data) -> Bool {
		service.writeData(account: account, data: data)
	}

	private func syncMetadataAccount(vaultId: String) -> String {
		let encoded = Data(vaultId.utf8).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return Self.syncMetadataRecordPrefix + encoded
	}

	private func loadSyncMetadataResult(
		projectIds: [String]
	) -> Result<[String: SyncMetadata], KeychainError> {
		var metadata: [String: SyncMetadata] = [:]
		metadata.reserveCapacity(projectIds.count)
		for vaultId in Set(projectIds).sorted() {
			switch readSyncMetadataRecordSnapshotResult(vaultId: vaultId) {
			case .success(let record):
				if let item = record.metadata { metadata[vaultId] = item }
			case .failure(let error): return .failure(error)
			}
		}
		return .success(metadata)
	}

	private func loadSyncMetadataRecordSnapshotResult(
		vaultId: String
	) -> Result<SyncMetadataRecordSnapshot, KeychainError> {
		readSyncMetadataRecordSnapshotResult(vaultId: vaultId)
	}

	private func readSyncMetadataRecordSnapshotResult(
		vaultId: String
	) -> Result<SyncMetadataRecordSnapshot, KeychainError> {
		let account = syncMetadataAccount(vaultId: vaultId)
		switch service.readDataResult(account: account) {
		case .failure(let error):
			return .failure(error)
		case .success(nil):
			return .success(SyncMetadataRecordSnapshot(
				account: account,
				data: nil,
				metadata: nil
			))
		case .success(let data?):
			guard let record = try? JSONDecoder().decode(
				PersistedSyncMetadataRecord.self,
				from: data
			), record.schemaVersion == Self.syncMetadataSchemaVersion,
				record.vaultId == vaultId
			else { return .failure(.encodingFailed) }
			return .success(SyncMetadataRecordSnapshot(
				account: account,
				data: data,
				metadata: record.metadata
			))
		}
	}

	private func writeSyncMetadata(_ metadata: SyncMetadata, vaultId: String) -> Bool {
		writeSyncMetadata(
			metadata,
			account: syncMetadataAccount(vaultId: vaultId),
			vaultId: vaultId
		)
	}

	private func syncMetadataMutation(
		_ metadata: SyncMetadata,
		vaultId: String
	) -> VaultKeychainMutation? {
		guard let data = try? JSONEncoder().encode(PersistedSyncMetadataRecord(
			schemaVersion: Self.syncMetadataSchemaVersion,
			vaultId: vaultId,
			metadata: metadata
		)) else { return nil }
		return .write(account: syncMetadataAccount(vaultId: vaultId), data: data)
	}

	private func writeSyncMetadata(
		_ metadata: SyncMetadata,
		account: String,
		vaultId: String
	) -> Bool {
		guard let data = try? JSONEncoder().encode(PersistedSyncMetadataRecord(
			schemaVersion: Self.syncMetadataSchemaVersion,
			vaultId: vaultId,
			metadata: metadata
		)) else { return false }
		return service.writeData(account: account, data: data)
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
}

extension KeychainResult {
	fileprivate var succeeded: Bool {
		switch self {
		case .success, .successWithWarning: true
		case .failure: false
		}
	}
}
