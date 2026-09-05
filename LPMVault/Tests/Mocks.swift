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
	var projectMetadataReadCount = 0
	var environmentReadCount = 0
	var failDataAccounts: Set<String> = []
	var failNextReadDataAccounts: Set<String> = []
	var dataReadCounts: [String: Int] = [:]
	var dataWriteCounts: [String: Int] = [:]
	var dataDeleteCounts: [String: Int] = [:]
	var failNextWriteDataAccounts: Set<String> = []
	var failNextDeleteDataAccounts: Set<String> = []
	var failDeleteDataAccounts: Set<String> = []
	var saveEnvironmentsCallCount = 0
	var updateEnvironmentsCallCount = 0
	var applyVaultTransactionCallCount = 0
	var onGetEnvironments: (() -> Void)?
	var onCreateEnvironments: (() -> Void)?
	var blockNextSaveEnvironments: (() -> Void)?
	var blockNextListProjects: (() -> Void)?
	var blockNextListProjectMetadata: (() -> Void)?
	var blockNextDeleteProject: (() -> Void)?
	var failWriteDataAccounts: Set<String> = []
	var failNextSaveEnvironments = false

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

	func listProjectMetadataResult() -> Result<[VaultProjectMetadata], KeychainError> {
		let failure = lock.withLock { () -> KeychainError? in
			guard failProjectReads else { return nil }
			return failureError
		}
		if let failure { return .failure(failure) }
		let blocker = lock.withLock { () -> (() -> Void)? in
			let blocker = blockNextListProjectMetadata
			blockNextListProjectMetadata = nil
			return blocker
		}
		blocker?()
		if let listProjectsDelay { Thread.sleep(forTimeInterval: listProjectsDelay.timeInterval) }
		return .success(lock.withLock {
			projectMetadataReadCount += envStorage.count
			return envStorage.map { vaultId, data in
				VaultProjectMetadata(
					id: vaultId,
					name: data.name,
					path: data.path,
					environmentSummaries: data.environments.map { name, secrets in
						VaultProjectEnvironmentSummary(name: name, keyCount: secrets.count)
					}.sorted { $0.name < $1.name }
				)
			}
		})
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

	func updateEnvironments(
		vaultId: String,
		environments: [String: [String: String]]
	) -> KeychainResult {
		updateEnvironmentsCallCount += 1
		guard let existing = envStorage[vaultId] else { return .failure(.itemNotFound) }
		return saveEnvironments(
			vaultId: vaultId,
			projectName: existing.name,
			projectPath: existing.path,
			environments: environments
		)
	}

	private func deleteProjectStorage(vaultId: String) -> Bool {
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

	func applyVaultTransaction(
		project: VaultProjectKeychainMutation?,
		data mutations: [VaultKeychainMutation]
	) -> KeychainResult {
		lock.lock()
		defer { lock.unlock() }
		applyVaultTransactionCallCount += 1
		let previousEnvironments = envStorage
		let previousData = dataStorage
		let projectResult: KeychainResult
		switch project {
		case .create(let project):
			projectResult = createEnvironments(
				vaultId: project.id,
				projectName: project.name,
				projectPath: project.path,
				environments: project.environments
			)
		case .upsert(let project):
			projectResult = saveEnvironments(
				vaultId: project.id,
				projectName: project.name,
				projectPath: project.path,
				environments: project.environments
			)
		case .update(let vaultId, let environments):
			projectResult = updateEnvironments(vaultId: vaultId, environments: environments)
		case .delete(let vaultId, _):
			projectResult = deleteProjectStorage(vaultId: vaultId)
				? .success : .failure(failureError)
		case nil:
			projectResult = .success
		}
		let projectSucceeded = switch projectResult {
		case .success, .successWithWarning: true
		case .failure: false
		}
		guard projectSucceeded else {
			return projectResult
		}
		for mutation in mutations {
			let succeeded = if let mutationData = mutation.data {
				writeData(account: mutation.account, data: mutationData)
			} else {
				deleteData(account: mutation.account)
			}
			guard succeeded else {
				envStorage = previousEnvironments
				dataStorage = previousData
				return .failure(failureError)
			}
		}
		return projectResult
	}

	func readData(account: String) -> Data? {
		dataStorage[account]
	}

	func readDataResult(account: String) -> Result<Data?, KeychainError> {
		dataReadCounts[account, default: 0] += 1
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
		dataWriteCounts[account, default: 0] += 1
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
		dataDeleteCounts[account, default: 0] += 1
		if failNextDeleteDataAccounts.remove(account) != nil { return false }
		if shouldFail || failDeleteDataAccounts.contains(account) { return false }
		dataStorage.removeValue(forKey: account)
		return true
	}
}

private struct MockPersistedSyncMetadataRecord: Codable {
	let schemaVersion: Int
	let vaultId: String
	let metadata: SyncMetadata
}

func mockSyncMetadataAccount(vaultId: String) -> String {
	let encoded = Data(vaultId.utf8).base64EncodedString()
		.replacingOccurrences(of: "+", with: "-")
		.replacingOccurrences(of: "/", with: "_")
		.replacingOccurrences(of: "=", with: "")
	return VaultKeychainRecordContract.syncMetadataRecordPrefix + encoded
}

func mockCurrentSyncMetadata(
	version: Int,
	principalID: String,
	scope: String,
	registryURL: String = "https://lpm.dev",
	action: String = "pull",
	isDirty: Bool = true
) -> SyncMetadata {
	SyncMetadata(
		lastSyncedAt: Date(timeIntervalSince1970: 1),
		lastAction: action,
		lastVersion: version,
		isDirty: isDirty,
		binding: SyncPrincipalBinding(
			registryURL: registryURL,
			principalID: principalID,
			scope: scope
		)
	)
}

extension MockKeychainService {
	@discardableResult
	func seedSyncMetadata(_ metadata: [String: SyncMetadata]) -> Bool {
		for (vaultId, item) in metadata {
			guard let data = try? JSONEncoder().encode(MockPersistedSyncMetadataRecord(
				schemaVersion: VaultKeychainRecordContract.syncMetadataSchemaVersion,
				vaultId: vaultId,
				metadata: item
			)) else { return false }
			dataStorage[mockSyncMetadataAccount(vaultId: vaultId)] = data
		}
		return true
	}

	func storedSyncMetadata(vaultId: String) -> SyncMetadata? {
		guard let data = dataStorage[mockSyncMetadataAccount(vaultId: vaultId)],
			let record = try? JSONDecoder().decode(MockPersistedSyncMetadataRecord.self, from: data),
			record.schemaVersion == VaultKeychainRecordContract.syncMetadataSchemaVersion,
			record.vaultId == vaultId
		else { return nil }
		return record.metadata
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
	private let lock = NSLock()
	var shouldSucceed = true
	var isAvailable = true
	var type: BiometricType = .touchID
	var authenticateHandlers: [@Sendable () async -> Bool] = []
	private var authenticationCalls = 0

	var authenticateCallCount: Int { lock.withLock { authenticationCalls } }

	func authenticate(reason: String) async -> Bool {
		_ = reason
		let response: ((@Sendable () async -> Bool)?, Bool) = lock.withLock {
			authenticationCalls += 1
			let handler = authenticateHandlers.isEmpty ? nil : authenticateHandlers.removeFirst()
			return (handler, shouldSucceed)
		}
		return await response.0?() ?? response.1
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
	var personalRevokeError: LPMAPIError?
	var orgRevokeError: LPMAPIError?
	var requestedOrgSlugs: [String] = []
	var receivedAuthTokens: [String] = []
	var currentUserFetchCount = 0
	var personalTokenFetchCount = 0
	var orgTokenFetchCount = 0
	var activeOrgRequests = 0
	var maximumActiveOrgRequests = 0
	var blockNextCurrentUserFetch: (@Sendable () async -> Void)?
	var blockNextPersonalTokenFetch: (@Sendable () async -> Void)?
	var blockNextPersonalRevoke: (@Sendable () async -> Void)?
	var blockNextOrgRevoke: (@Sendable () async -> Void)?
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
		let (response, blocker): (
			(delay: Duration?, tokens: [LPMToken]),
			(@Sendable () async -> Void)?
		) = lock.withLock {
			receivedAuthTokens.append(authToken)
			personalTokenFetchCount += 1
			let response = !personalTokenResponses.isEmpty
				? personalTokenResponses.removeFirst()
				: (personalTokensDelay, personalTokens)
			let blocker = blockNextPersonalTokenFetch
			blockNextPersonalTokenFetch = nil
			return (response, blocker)
		}
		await blocker?()
		if let delay = response.delay { try? await Task.sleep(for: delay) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		if let personalTokensError { return .failure(personalTokensError) }
		return .success(response.tokens)
	}

	func revokePersonalToken(id: String, authToken: String) async -> LPMAPIResult<Void> {
		let blocker = lock.withLock {
			receivedAuthTokens.append(authToken)
			revokedTokenIds.append(id)
			let blocker = blockNextPersonalRevoke
			blockNextPersonalRevoke = nil
			return blocker
		}
		onPersonalRevokeStart?()
		await blocker?()
		if let personalRevokeDelay { try? await Task.sleep(for: personalRevokeDelay) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		if let personalRevokeError { return .failure(personalRevokeError) }
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
		let blocker = lock.withLock {
			receivedAuthTokens.append(authToken)
			revokedTokenIds.append(id)
			let blocker = blockNextOrgRevoke
			blockNextOrgRevoke = nil
			return blocker
		}
		onOrgRevokeStart?()
		await blocker?()
		if let orgRevokeDelay { try? await Task.sleep(for: orgRevokeDelay) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		if let orgRevokeError { return .failure(orgRevokeError) }
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
	var authenticatedPublicKeyResponses: [
		SyncService.AuthenticatedResponse<SyncService.PublicKeyRecord>
	] = []
	var authenticatedPullResponses: [
		SyncService.AuthenticatedResponse<SyncService.SyncStatus>
	] = []
	var blockNextMemberKeyAccess: (@Sendable () async -> Void)?
	var blockNextPull: (@Sendable () async -> Void)?
	var blockNextPush: (@Sendable () async -> Void)?
	private var publicKeyCalls = 0
	private var memberKeyAccessCalls = 0
	private var pullCalls = 0
	private var pushCalls = 0

	var publicKeyCallCount: Int { lock.withLock { publicKeyCalls } }
	var memberKeyAccessCallCount: Int { lock.withLock { memberKeyAccessCalls } }
	var pullCallCount: Int { lock.withLock { pullCalls } }
	var pushCallCount: Int { lock.withLock { pushCalls } }

	func getMyPublicKey(
		authToken: String,
		expectedPrincipalId: String
	) async -> SyncService.PublicKeyRecord? {
		_ = authToken
		_ = expectedPrincipalId
		lock.withLock { publicKeyCalls += 1 }
		return publicKeyRecord
	}

	func getMyPublicKeyAuthenticated(
		authToken: String,
		expectedPrincipalId: String
	) async -> SyncService.AuthenticatedResponse<SyncService.PublicKeyRecord> {
		_ = authToken
		_ = expectedPrincipalId
		return lock.withLock {
			publicKeyCalls += 1
			guard !authenticatedPublicKeyResponses.isEmpty else {
				return .response(publicKeyRecord)
			}
			return authenticatedPublicKeyResponses.removeFirst()
		}
	}

	func getOrgMemberKeyAccess(
		authToken: String,
		expectedCallerUserID: String,
		orgSlug: String
	) async -> SyncService.MemberKeyAccess? {
		_ = authToken
		_ = expectedCallerUserID
		_ = orgSlug
		let blocker: (@Sendable () async -> Void)? = lock.withLock {
			memberKeyAccessCalls += 1
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
			pullCalls += 1
			let blocker = blockNextPull
			blockNextPull = nil
			return blocker
		}
		await blocker?()
		return pullResult
	}

	func pullOrgAuthenticated(
		authToken: String,
		orgSlug: String,
		vaultId: String
	) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus> {
		_ = authToken
		_ = orgSlug
		_ = vaultId
		let result: SyncService.AuthenticatedResponse<SyncService.SyncStatus> = lock.withLock {
			pullCalls += 1
			guard !authenticatedPullResponses.isEmpty else {
				return .response(pullResult)
			}
			return authenticatedPullResponses.removeFirst()
		}
		let blocker: (@Sendable () async -> Void)? = lock.withLock {
			let blocker = blockNextPull
			blockNextPull = nil
			return blocker
		}
		await blocker?()
		return result
	}

	func pushOrg(
		authToken: String,
		orgSlug: String,
		expectedOrganizationID: String,
		expectedCallerUserID: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKeys: [SyncService.WrappedMemberKey]?,
		expectedVersion: Int?,
		name: String?,
		schema: LPMJSONValue?
	) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = orgSlug
		_ = expectedOrganizationID
		_ = expectedCallerUserID
		_ = vaultId
		_ = encryptedBlob
		_ = wrappedKeys
		_ = expectedVersion
		_ = name
		_ = schema
		let blocker: (@Sendable () async -> Void)? = lock.withLock {
			pushCalls += 1
			let blocker = blockNextPush
			blockNextPush = nil
			return blocker
		}
		await blocker?()
		return pushResult
	}
}

final class MockPersonalSyncService: PersonalSyncServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	var pullHandlers: [@Sendable () async -> SyncService.SyncStatus?] = []
	var pushHandlers: [@Sendable () async -> SyncService.SyncStatus?] = []
	var versionPreflightHandlers: [
		@Sendable () async -> SyncService.AuthenticatedResponse<SyncService.VersionPreflight>
	] = []
	private var pullCalls = 0
	private var pushCalls = 0
	private var versionPreflightCalls = 0
	private var expectedVersions: [Int?] = []
	private var forceValues: [Bool] = []
	private var recreateMissingValues: [Bool] = []

	var pullCallCount: Int { lock.withLock { pullCalls } }
	var pushCallCount: Int { lock.withLock { pushCalls } }
	var versionPreflightCallCount: Int { lock.withLock { versionPreflightCalls } }
	var pushedExpectedVersions: [Int?] { lock.withLock { expectedVersions } }
	var pushedForceValues: [Bool] { lock.withLock { forceValues } }
	var pushedRecreateMissingValues: [Bool] { lock.withLock { recreateMissingValues } }

	func pull(authToken: String, vaultId: String) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = vaultId
		let handler: (@Sendable () async -> SyncService.SyncStatus?)? = lock.withLock {
			pullCalls += 1
			guard !pullHandlers.isEmpty else { return nil }
			return pullHandlers.removeFirst()
		}
		return await handler?()
	}

	func versionPreflightAuthenticated(
		authToken: String,
		vaultId: String
	) async -> SyncService.AuthenticatedResponse<SyncService.VersionPreflight> {
		_ = authToken
		_ = vaultId
		let handler: (
			@Sendable () async -> SyncService.AuthenticatedResponse<SyncService.VersionPreflight>
		)? = lock.withLock {
			versionPreflightCalls += 1
			guard !versionPreflightHandlers.isEmpty else { return nil }
			return versionPreflightHandlers.removeFirst()
		}
		return await handler?() ?? .response(.notFound)
	}

	func push(
		authToken: String,
		expectedPrincipalId: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int?,
		force: Bool,
		recreateMissing: Bool,
		name: String?,
		schema: LPMJSONValue?
	) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = expectedPrincipalId
		_ = vaultId
		_ = encryptedBlob
		_ = wrappedKey
		_ = expectedVersion
		_ = name
		_ = schema
		let handler: (@Sendable () async -> SyncService.SyncStatus?)? = lock.withLock {
			pushCalls += 1
			expectedVersions.append(expectedVersion)
			forceValues.append(force)
			recreateMissingValues.append(recreateMissing)
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
		vaultId: String,
		expectedCallerUserID: String
	) async throws -> RemoteEnvProjectPayload {
		_ = expectedCallerUserID
		return try organizationResult.get()
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
