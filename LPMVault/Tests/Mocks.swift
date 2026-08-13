import Foundation

@testable import LPMVault

// MARK: - Mock Keychain Service

final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	var envStorage: [String: (name: String, path: String, environments: [String: [String: String]])] = [:]
	var dataStorage: [String: Data] = [:]
	var shouldFail = false
	var failureError: KeychainError = .accessDenied
	var listProjectsDelay: Duration?
	var failDataAccounts: Set<String> = []
	var saveEnvironmentsCallCount = 0
	var onCreateEnvironments: (() -> Void)?

	// Convenience for old tests that use flat secrets
	var storage: [String: (name: String, path: String, secrets: [String: String])] {
		get {
			envStorage.mapValues { (name: $0.name, path: $0.path, secrets: $0.environments["default"] ?? [:]) }
		}
		set {
			envStorage = newValue.mapValues { (name: $0.name, path: $0.path, environments: ["default": $0.secrets]) }
		}
	}

	func listProjects() -> [VaultProject] {
		if let listProjectsDelay { Thread.sleep(forTimeInterval: listProjectsDelay.timeInterval) }
		lock.lock()
		defer { lock.unlock() }
		return envStorage.map { vaultId, data in
			VaultProject(
				id: vaultId,
				name: data.name,
				path: data.path,
				environments: data.environments
			)
		}
	}

	func getEnvironments(vaultId: String) -> [String: [String: String]]? {
		envStorage[vaultId]?.environments
	}

	func saveEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult {
		saveEnvironmentsCallCount += 1
		if shouldFail { return .failure(failureError) }
		envStorage[vaultId] = (name: projectName, path: projectPath, environments: environments)
		return .success
	}

	func createEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult {
		onCreateEnvironments?()
		if envStorage[vaultId] != nil { return .failure(.duplicateItem) }
		return saveEnvironments(
			vaultId: vaultId,
			projectName: projectName,
			projectPath: projectPath,
			environments: environments
		)
	}

	func getSecrets(vaultId: String) -> [String: String]? {
		envStorage[vaultId]?.environments["default"]
	}

	func saveSecrets(
		vaultId: String,
		projectName: String,
		projectPath: String,
		secrets: [String: String]
	) -> KeychainResult {
		if shouldFail { return .failure(failureError) }
		var envs = envStorage[vaultId]?.environments ?? [:]
		envs["default"] = secrets
		envStorage[vaultId] = (name: projectName, path: projectPath, environments: envs)
		return .success
	}

	func deleteProject(vaultId: String) -> Bool {
		if shouldFail { return false }
		envStorage.removeValue(forKey: vaultId)
		return true
	}

	func removeFromSidebar(vaultId: String) -> Bool {
		if shouldFail { return false }
		// Only remove from listing, keep data (like real implementation)
		return true
	}

	func readData(account: String) -> Data? {
		dataStorage[account]
	}

	@discardableResult
	func writeData(account: String, data: Data) -> Bool {
		if shouldFail || failDataAccounts.contains(account) { return false }
		dataStorage[account] = data
		return true
	}

	@discardableResult
	func deleteData(account: String) -> Bool {
		if shouldFail { return false }
		dataStorage.removeValue(forKey: account)
		return true
	}
}

private extension Duration {
	var timeInterval: TimeInterval {
		let components = self.components
		return TimeInterval(components.seconds)
			+ TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
	}
}

// MARK: - Mock Biometric Service

final class MockBiometricService: BiometricServiceProtocol, @unchecked Sendable {
	var shouldSucceed = true
	var isAvailable = true
	var type: BiometricType = .touchID
	var authenticateCallCount = 0

	func authenticate(reason: String) async -> Bool {
		authenticateCallCount += 1
		return shouldSucceed
	}

	func isBiometricAvailable() -> Bool {
		isAvailable
	}

	func biometricType() -> BiometricType {
		type
	}

	func resetCache() {}
}

// MARK: - Mock API Service

final class MockAPIService: LPMAPIServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	var user: LPMUser?
	var userResponses: [(delay: Duration?, user: LPMUser?)] = []
	var personalTokens: [LPMToken] = []
	var orgTokensMap: [String: [LPMToken]] = [:]
	var revokedTokenIds: [String] = []
	var delay: Duration?
	var personalTokensDelay: Duration?
	var personalTokenResponses: [(delay: Duration?, tokens: [LPMToken])] = []

	func fetchCurrentUser() async -> LPMUser? {
		let response: (delay: Duration?, user: LPMUser?) = lock.withLock {
			if !userResponses.isEmpty { return userResponses.removeFirst() }
			return (delay, user)
		}
		if let delay = response.delay { try? await Task.sleep(for: delay) }
		return response.user
	}

	func fetchCurrentUser(authToken: String) async -> LPMUser? {
		user
	}

	func fetchPersonalTokens() async -> [LPMToken] {
		let response: (delay: Duration?, tokens: [LPMToken]) = lock.withLock {
			if !personalTokenResponses.isEmpty { return personalTokenResponses.removeFirst() }
			return (personalTokensDelay, personalTokens)
		}
		if let delay = response.delay { try? await Task.sleep(for: delay) }
		return response.tokens
	}

	func revokePersonalToken(id: String) async -> Bool {
		revokedTokenIds.append(id)
		return true
	}

	func fetchOrgTokens(orgSlug: String) async -> [LPMToken] {
		orgTokensMap[orgSlug] ?? []
	}

	func revokeOrgToken(orgSlug: String, id: String) async -> Bool {
		revokedTokenIds.append(id)
		return true
	}
}

// MARK: - Mock Import Service

final class MockEnvProjectImportService: EnvProjectImportServiceProtocol, @unchecked Sendable {
	var personalResult: Result<RemoteEnvProjectPayload, EnvProjectImportError> = .failure(.noResponse)
	var organizationResult: Result<RemoteEnvProjectPayload, EnvProjectImportError> = .failure(.noResponse)

	func loadPersonal(authToken: String, vaultId: String) async throws -> RemoteEnvProjectPayload {
		try personalResult.get()
	}

	func loadOrganization(
		authToken: String,
		orgSlug: String,
		vaultId: String
	) async throws -> RemoteEnvProjectPayload {
		try organizationResult.get()
	}
}
