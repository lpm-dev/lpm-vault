import Foundation

/// Serializes Keychain mutations so older snapshots cannot finish after newer ones.
actor VaultPersistenceCoordinator {
	private let service: KeychainServiceProtocol

	init(service: KeychainServiceProtocol) {
		self.service = service
	}

	func listProjects() -> [VaultProject] {
		service.listProjects()
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

	func writeData(account: String, data: Data) {
		_ = service.writeData(account: account, data: data)
	}
}
