import Foundation

@Observable
final class VaultStore {
	// MARK: - State

	var projects: [VaultProject] = []
	var selectedProjectId: String?
	var isUnlocked: Bool = false
	var searchQuery: String = ""
	var error: String?

	// MARK: - Dependencies

	private let keychainService: KeychainServiceProtocol
	private let biometricService: BiometricServiceProtocol
	private var autoLockTask: Task<Void, Never>?
	private let autoLockDuration: TimeInterval

	// MARK: - Computed

	var selectedProject: VaultProject? {
		guard let id = selectedProjectId else { return nil }
		return projects.first { $0.id == id }
	}

	var filteredProjects: [VaultProject] {
		guard !searchQuery.isEmpty else { return projects }
		let query = searchQuery.lowercased()
		return projects.filter { project in
			project.name.lowercased().contains(query)
				|| project.secrets.keys.contains { $0.lowercased().contains(query) }
		}
	}

	// MARK: - Init

	init(
		keychainService: KeychainServiceProtocol = KeychainService(),
		biometricService: BiometricServiceProtocol = BiometricService(),
		autoLockDuration: TimeInterval = VaultConstants.biometricCacheDuration
	) {
		self.keychainService = keychainService
		self.biometricService = biometricService
		self.autoLockDuration = autoLockDuration
	}

	// MARK: - Load

	func loadProjects() {
		projects = keychainService.listProjects()
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		error = nil
	}

	// MARK: - Project Operations

	func addProject(name: String, path: String) {
		let vaultId = UUID().uuidString.lowercased()
		let project = VaultProject(id: vaultId, name: name, path: path, secrets: [:])

		let result = keychainService.saveSecrets(
			vaultId: vaultId,
			projectName: name,
			projectPath: path,
			secrets: [:]
		)

		switch result {
		case .success, .successWithWarning:
			projects.append(project)
			projects.sort {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
			selectedProjectId = vaultId
		case .failure(let err):
			error = err.description
		}
	}

	func deleteProject(_ project: VaultProject) {
		if keychainService.deleteProject(vaultId: project.id) {
			projects.removeAll { $0.id == project.id }
			if selectedProjectId == project.id {
				selectedProjectId = projects.first?.id
			}
		}
	}

	// MARK: - Secret Operations

	func addSecret(to projectId: String, key: String, value: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard !key.isEmpty else { return }

		project.secrets[key] = value
		saveAndUpdate(project)
	}

	func updateSecret(in projectId: String, key: String, newValue: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard project.secrets[key] != nil else { return }

		project.secrets[key] = newValue
		saveAndUpdate(project)
	}

	func deleteSecret(from projectId: String, key: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }

		project.secrets.removeValue(forKey: key)
		saveAndUpdate(project)
	}

	// MARK: - Auth

	func unlock() async {
		let success = await biometricService.authenticate(
			reason: "Unlock LPM Vault to view secrets"
		)
		await MainActor.run {
			isUnlocked = success
			if success {
				scheduleAutoLock()
			}
		}
	}

	func lock() {
		autoLockTask?.cancel()
		autoLockTask = nil
		isUnlocked = false
	}

	/// Reset the auto-lock timer (call on user interaction while unlocked)
	func resetAutoLock() {
		guard isUnlocked else { return }
		scheduleAutoLock()
	}

	private func scheduleAutoLock() {
		autoLockTask?.cancel()
		autoLockTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: UInt64(autoLockDuration * 1_000_000_000))
			if !Task.isCancelled {
				isUnlocked = false
			}
		}
	}

	// MARK: - Private

	private func saveAndUpdate(_ project: VaultProject) {
		let result = keychainService.saveSecrets(
			vaultId: project.id,
			projectName: project.name,
			projectPath: project.path,
			secrets: project.secrets
		)

		switch result {
		case .success:
			updateProjectInPlace(project)
		case .successWithWarning(let warning):
			updateProjectInPlace(project)
			error = warning
		case .failure(let err):
			error = err.description
		}
	}

	private func updateProjectInPlace(_ project: VaultProject) {
		if let index = projects.firstIndex(where: { $0.id == project.id }) {
			projects[index] = project
		}
	}
}
