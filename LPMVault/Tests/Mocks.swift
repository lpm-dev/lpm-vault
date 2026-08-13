import Foundation

@testable import LPMVault

// MARK: - Mock Keychain Service

final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
	var envStorage: [String: (name: String, path: String, environments: [String: [String: String]])] = [:]
	var dataStorage: [String: Data] = [:]
	var shouldFail = false
	var failureError: KeychainError = .accessDenied

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
		envStorage.map { vaultId, data in
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
		if shouldFail { return .failure(failureError) }
		envStorage[vaultId] = (name: projectName, path: projectPath, environments: environments)
		return .success
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
		if shouldFail { return false }
		dataStorage[account] = data
		return true
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
	var user: LPMUser?
	var personalTokens: [LPMToken] = []
	var orgTokensMap: [String: [LPMToken]] = [:]
	var revokedTokenIds: [String] = []

	func fetchCurrentUser() async -> LPMUser? {
		user
	}

	func fetchCurrentUser(authToken: String) async -> LPMUser? {
		user
	}

	func fetchPersonalTokens() async -> [LPMToken] {
		personalTokens
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
