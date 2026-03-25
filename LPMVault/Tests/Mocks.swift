import Foundation

@testable import LPMVault

// MARK: - Mock Keychain Service

final class MockKeychainService: KeychainServiceProtocol {
	var storage: [String: (name: String, path: String, secrets: [String: String])] = [:]
	var shouldFail = false
	var failureError: KeychainError = .accessDenied

	func listProjects() -> [VaultProject] {
		storage.map { vaultId, data in
			VaultProject(
				id: vaultId,
				name: data.name,
				path: data.path,
				secrets: data.secrets
			)
		}
	}

	func getSecrets(vaultId: String) -> [String: String]? {
		storage[vaultId]?.secrets
	}

	func saveSecrets(
		vaultId: String,
		projectName: String,
		projectPath: String,
		secrets: [String: String]
	) -> KeychainResult {
		if shouldFail {
			return .failure(failureError)
		}

		// Simulate size check
		if let data = try? JSONEncoder().encode(secrets),
			data.count > VaultConstants.maxVaultSizeWarning
		{
			return .failure(.dataTooLarge(data.count))
		}

		storage[vaultId] = (name: projectName, path: projectPath, secrets: secrets)
		return .success
	}

	func deleteProject(vaultId: String) -> Bool {
		if shouldFail { return false }
		storage.removeValue(forKey: vaultId)
		return true
	}
}

// MARK: - Mock Biometric Service

final class MockBiometricService: BiometricServiceProtocol {
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

final class MockAPIService: LPMAPIServiceProtocol {
	var user: LPMUser?
	var personalTokens: [LPMToken] = []
	var orgTokensMap: [String: [LPMToken]] = [:]
	var revokedTokenIds: [String] = []

	func fetchCurrentUser() async -> LPMUser? {
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
