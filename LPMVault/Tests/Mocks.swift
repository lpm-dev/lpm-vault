import Foundation

@testable import LPMVault

// MARK: - Mock Keychain Service

final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
	private let lock = NSRecursiveLock()
	var envStorage: [String: (name: String, path: String, environments: [String: [String: String]])] = [:]
	var dataStorage: [String: Data] = [:]
	var shouldFail = false
	var failureError: KeychainError = .accessDenied
	var listProjectsDelay: Duration?
	var failProjectReads = false
	var projectReadCount = 0
	var environmentReadCount = 0
	var failDataAccounts: Set<String> = []
	var failNextReadDataAccounts: Set<String> = []
	var failNextWriteDataAccounts: Set<String> = []
	var saveEnvironmentsCallCount = 0
	var onGetEnvironments: (() -> Void)?
	var onCreateEnvironments: (() -> Void)?
	var blockNextSaveEnvironments: (() -> Void)?
	var blockNextListProjects: (() -> Void)?
	var blockNextDeleteProject: (() -> Void)?
	var failWriteDataAccounts: Set<String> = []
	var failRestoreSaveEnvironments = false
	var failNextSaveEnvironments = false
	private var successfulSaveEnvironmentsCallCount = 0

	func withKeychainTransaction<T>(_ operation: () -> T) -> Result<T, KeychainError> {
		.success(lock.withLock(operation))
	}

	// Convenience for old tests that use flat secrets
	var storage: [String: (name: String, path: String, secrets: [String: String])] {
		get {
			lock.withLock {
				envStorage.mapValues {
					(name: $0.name, path: $0.path, secrets: $0.environments["default"] ?? [:])
				}
			}
		}
		set {
			lock.withLock {
				envStorage = newValue.mapValues {
					(name: $0.name, path: $0.path, environments: ["default": $0.secrets])
				}
			}
		}
	}

	func listProjects() -> [VaultProject] {
		lock.lock()
		let blocker = blockNextListProjects
		blockNextListProjects = nil
		lock.unlock()
		blocker?()
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

	func listProjectsResult() -> Result<[VaultProject], KeychainError> {
		let failure = lock.withLock { () -> KeychainError? in
			guard failProjectReads else { return nil }
			return failureError
		}
		if let failure { return .failure(failure) }
		lock.withLock { projectReadCount += envStorage.count }
		return .success(listProjects())
	}

	func getProjectResult(vaultId: String) -> Result<VaultProject?, KeychainError> {
		let blocker = lock.withLock { () -> (() -> Void)? in
			let blocker = blockNextListProjects
			blockNextListProjects = nil
			return blocker
		}
		blocker?()
		if let listProjectsDelay { Thread.sleep(forTimeInterval: listProjectsDelay.timeInterval) }

		return lock.withLock {
			if failProjectReads { return .failure(failureError) }
			projectReadCount += 1
			let hook = onGetEnvironments
			onGetEnvironments = nil
			hook?()
			guard let data = envStorage[vaultId] else { return .success(nil) }
			return .success(VaultProject(
				id: vaultId,
				name: data.name,
				path: data.path,
				environments: data.environments
			))
		}
	}

	func getEnvironments(vaultId: String) -> [String: [String: String]]? {
		lock.withLock {
			let hook = onGetEnvironments
			onGetEnvironments = nil
			hook?()
			return envStorage[vaultId]?.environments
		}
	}

	func getEnvironmentsResult(
		vaultId: String
	) -> Result<[String: [String: String]]?, KeychainError> {
		let failure = lock.withLock { () -> KeychainError? in
			guard failProjectReads else { return nil }
			return failureError
		}
		if let failure { return .failure(failure) }
		lock.withLock { environmentReadCount += 1 }
		return .success(getEnvironments(vaultId: vaultId))
	}

	func simulateCLISet(
		vaultId: String,
		environment: String,
		key: String,
		value: String
	) {
		lock.withLock {
			guard var project = envStorage[vaultId] else { return }
			var secrets = project.environments[environment] ?? [:]
			secrets[key] = value
			project.environments[environment] = secrets
			envStorage[vaultId] = project
		}
	}

	func saveEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult {
		saveEnvironmentsCallCount += 1
		lock.lock()
		let blocker = blockNextSaveEnvironments
		blockNextSaveEnvironments = nil
		lock.unlock()
		blocker?()
		if shouldFail { return .failure(failureError) }
		if failNextSaveEnvironments {
			failNextSaveEnvironments = false
			return .failure(.unexpectedStatus(-98))
		}
		if failRestoreSaveEnvironments, successfulSaveEnvironmentsCallCount > 0 {
			return .failure(.unexpectedStatus(-99))
		}
		guard let encodedSize = EnvValidation.encodedVaultSize(environments) else {
			return .failure(.encodingFailed)
		}
		guard encodedSize <= VaultConstants.maxVaultSizeWarning else {
			return .failure(.dataTooLarge(encodedSize))
		}
		lock.withLock {
			envStorage[vaultId] = (
				name: projectName,
				path: projectPath,
				environments: environments
			)
			successfulSaveEnvironmentsCallCount += 1
		}
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
		lock.lock()
		let blocker = blockNextDeleteProject
		blockNextDeleteProject = nil
		lock.unlock()
		blocker?()
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

	func readDataResult(account: String) -> Result<Data?, KeychainError> {
		if failNextReadDataAccounts.remove(account) != nil {
			return .failure(failureError)
		}
		if shouldFail || failDataAccounts.contains(account) {
			return .failure(failureError)
		}
		return .success(dataStorage[account])
	}

	@discardableResult
	func writeData(account: String, data: Data) -> Bool {
		if failNextWriteDataAccounts.remove(account) != nil {
			return false
		}
		if shouldFail || failDataAccounts.contains(account) || failWriteDataAccounts.contains(account) {
			return false
		}
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
	var orgTokenErrors: [String: LPMAPIError] = [:]
	var revokedTokenIds: [String] = []
	var delay: Duration?
	var personalTokensDelay: Duration?
	var personalTokenResponses: [(delay: Duration?, tokens: [LPMToken])] = []
	var orgTokensDelay: Duration?
	var personalTokensError: LPMAPIError?
	var personalRevokeDelay: Duration?
	var orgRevokeDelay: Duration?
	var requestedOrgSlugs: [String] = []
	var receivedAuthTokens: [String] = []
	var currentUserFetchCount = 0
	var personalTokenFetchCount = 0
	var orgTokenFetchCount = 0
	var activeOrgRequests = 0
	var maximumActiveOrgRequests = 0
	var blockNextCurrentUserFetch: (@Sendable () async -> Void)?
	var onPersonalRevokeStart: (() -> Void)?
	var onOrgRevokeStart: (() -> Void)?

	func fetchCurrentUser(authToken: String) async -> LPMAPIResult<LPMUser> {
		let (response, blocker): (
			(delay: Duration?, user: LPMUser?),
			(@Sendable () async -> Void)?
		) = lock.withLock {
			receivedAuthTokens.append(authToken)
			currentUserFetchCount += 1
			let response = !userResponses.isEmpty ? userResponses.removeFirst() : (delay, user)
			let blocker = blockNextCurrentUserFetch
			blockNextCurrentUserFetch = nil
			return (response, blocker)
		}
		await blocker?()
		if let delay = response.delay { try? await Task.sleep(for: delay) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		return response.user.map(LPMAPIResult.success) ?? .failure(.unauthorized)
	}

	func fetchPersonalTokens(authToken: String) async -> LPMAPIResult<[LPMToken]> {
		let response: (delay: Duration?, tokens: [LPMToken]) = lock.withLock {
			receivedAuthTokens.append(authToken)
			personalTokenFetchCount += 1
			if !personalTokenResponses.isEmpty { return personalTokenResponses.removeFirst() }
			return (personalTokensDelay, personalTokens)
		}
		if let delay = response.delay { try? await Task.sleep(for: delay) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		if let personalTokensError { return .failure(personalTokensError) }
		return .success(response.tokens)
	}

	func revokePersonalToken(id: String, authToken: String) async -> LPMAPIResult<Void> {
		lock.withLock {
			receivedAuthTokens.append(authToken)
			revokedTokenIds.append(id)
		}
		onPersonalRevokeStart?()
		if let personalRevokeDelay { try? await Task.sleep(for: personalRevokeDelay) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		return .success(())
	}

	func fetchOrgTokens(orgSlug: String, authToken: String) async -> LPMAPIResult<[LPMToken]> {
		let response: (delay: Duration?, result: LPMAPIResult<[LPMToken]>) = lock.withLock {
			receivedAuthTokens.append(authToken)
			orgTokenFetchCount += 1
			requestedOrgSlugs.append(orgSlug)
			activeOrgRequests += 1
			maximumActiveOrgRequests = max(maximumActiveOrgRequests, activeOrgRequests)
			let result = orgTokenErrors[orgSlug].map(LPMAPIResult.failure)
				?? .success(orgTokensMap[orgSlug] ?? [])
			return (orgTokensDelay, result)
		}
		if let delay = response.delay { try? await Task.sleep(for: delay) }
		lock.withLock { activeOrgRequests -= 1 }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		return response.result
	}

	func revokeOrgToken(orgSlug: String, id: String, authToken: String) async -> LPMAPIResult<Void> {
		lock.withLock {
			receivedAuthTokens.append(authToken)
			revokedTokenIds.append(id)
		}
		onOrgRevokeStart?()
		if let orgRevokeDelay { try? await Task.sleep(for: orgRevokeDelay) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		return .success(())
	}
}

// MARK: - Mock Organization Sync Service

final class MockOrgSyncService: OrgSyncServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	var publicKeyRecord: SyncService.PublicKeyRecord?
	var memberKeyAccess: SyncService.MemberKeyAccess?
	var pullResult: SyncService.SyncStatus?
	var pushResult: SyncService.SyncStatus?
	var blockNextMemberKeyAccess: (@Sendable () async -> Void)?
	var blockNextPull: (@Sendable () async -> Void)?
	private var pushCalls = 0

	var pushCallCount: Int { lock.withLock { pushCalls } }

	func getMyPublicKey(authToken: String) async -> SyncService.PublicKeyRecord? {
		_ = authToken
		return publicKeyRecord
	}

	func getOrgMemberKeyAccess(
		authToken: String,
		orgSlug: String
	) async -> SyncService.MemberKeyAccess? {
		_ = authToken
		_ = orgSlug
		let blocker: (@Sendable () async -> Void)? = lock.withLock {
			let blocker = blockNextMemberKeyAccess
			blockNextMemberKeyAccess = nil
			return blocker
		}
		await blocker?()
		return memberKeyAccess
	}

	func pullOrg(
		authToken: String,
		orgSlug: String,
		vaultId: String
	) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = orgSlug
		_ = vaultId
		let blocker: (@Sendable () async -> Void)? = lock.withLock {
			let blocker = blockNextPull
			blockNextPull = nil
			return blocker
		}
		await blocker?()
		return pullResult
	}

	func pushOrg(
		authToken: String,
		orgSlug: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKeys: [SyncService.WrappedMemberKey]?,
		expectedVersion: Int?,
		name: String?,
		schema: Data?
	) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = orgSlug
		_ = vaultId
		_ = encryptedBlob
		_ = wrappedKeys
		_ = expectedVersion
		_ = name
		_ = schema
		lock.withLock { pushCalls += 1 }
		return pushResult
	}
}

final class MockPersonalSyncService: PersonalSyncServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	var pullHandlers: [@Sendable () async -> SyncService.SyncStatus?] = []
	var pushHandlers: [@Sendable () async -> SyncService.SyncStatus?] = []

	func pull(authToken: String, vaultId: String) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = vaultId
		let handler: (@Sendable () async -> SyncService.SyncStatus?)? = lock.withLock {
			guard !pullHandlers.isEmpty else { return nil }
			return pullHandlers.removeFirst()
		}
		return await handler?()
	}

	func push(
		authToken: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int?,
		force: Bool,
		name: String?,
		schema: Data?
	) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = vaultId
		_ = encryptedBlob
		_ = wrappedKey
		_ = expectedVersion
		_ = force
		_ = name
		_ = schema
		let handler: (@Sendable () async -> SyncService.SyncStatus?)? = lock.withLock {
			guard !pushHandlers.isEmpty else { return nil }
			return pushHandlers.removeFirst()
		}
		return await handler?()
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

actor MockEnvFileImportService: EnvFileImportServiceProtocol {
	private var results: [String: Result<ImportedEnvFile, EnvFileImportError>] = [:]
	private var continuations: [String: CheckedContinuation<ImportedEnvFile, Error>] = [:]
	private var started: Set<String> = []
	var immediateResult: Result<ImportedEnvFile, EnvFileImportError> = .success(
		ImportedEnvFile(secrets: ["IMPORTED": "value"])
	)
	var usesGate = false

	func load(at url: URL) async throws -> ImportedEnvFile {
		let key = url.lastPathComponent
		if !usesGate { return try immediateResult.get() }
		started.insert(key)
		return try await withCheckedThrowingContinuation { continuation in
			if let result = results.removeValue(forKey: key) {
				continuation.resume(with: result.mapError { $0 as Error })
			} else {
				continuations[key] = continuation
			}
		}
	}

	func enableGate() { usesGate = true }

	func setImmediateResult(_ result: Result<ImportedEnvFile, EnvFileImportError>) {
		immediateResult = result
	}

	func hasStarted(_ key: String) -> Bool { started.contains(key) }

	func resolve(
		_ key: String,
		with result: Result<ImportedEnvFile, EnvFileImportError>
	) {
		if let continuation = continuations.removeValue(forKey: key) {
			continuation.resume(with: result.mapError { $0 as Error })
		} else {
			results[key] = result
		}
	}
}
