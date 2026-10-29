import Foundation

@testable import LPMVault

// MARK: - Mock Keychain Service

final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
	var cliAccessPolicies: [String: VaultCliAccess] = [:]
	var cliAccessChangeCount = 0
	var failCliAccess = false
	/// Projects whose approval metadata can't be read, while the others' can.
	var unreadableCliAccess: Set<String> = []
	var afterCliAccessCommit: (@Sendable () -> Void)?
	var beforeCliAccessRead: (@Sendable () -> Void)?
	var failCliAccessChange = false
	var beforeKeychainTransaction: (@Sendable () -> Void)?
	/// Runs after a transaction's work, as a slow Keychain commit would.
	var afterKeychainTransaction: (@Sendable () -> Void)?

	func cliAccessResult(vaultId: String) -> Result<VaultCliAccess, KeychainError> {
		beforeCliAccessRead?()
		return lock.withLock {
			if shouldFail || failCliAccess || unreadableCliAccess.contains(vaultId) { return .failure(failureError) }
			return .success(cliAccessPolicies[vaultId] ?? .automatic)
		}
	}

	/// What each project's newer data allows, as the real store's listing reads it.
	var companionStates: [String: CompanionEngine.Assessment] {
		get { lock.withLock { storedCompanionStates } }
		set { lock.withLock { storedCompanionStates = newValue } }
	}
	private var storedCompanionStates: [String: CompanionEngine.Assessment] = [:]
	/// Why the gated calls refuse a project, as the real gate would.
	var companionRefusals: [String: CompanionRefusal] {
		get { lock.withLock { storedCompanionRefusals } }
		set { lock.withLock { storedCompanionRefusals = newValue } }
	}
	private var storedCompanionRefusals: [String: CompanionRefusal] = [:]
	/// Why each interrupted project's change couldn't be finished.
	var companionUnfinished: [String: String] {
		get { lock.withLock { storedCompanionUnfinished } }
		set { lock.withLock { storedCompanionUnfinished = newValue } }
	}
	private var storedCompanionUnfinished: [String: String] = [:]
	/// What resumes finished, which the next read of project states reports once.
	var pendingCompanionNotices: [String: CompanionEngine.Plan.Notice] {
		get { lock.withLock { storedCompanionNotices } }
		set { lock.withLock { storedCompanionNotices = newValue } }
	}
	private var storedCompanionNotices: [String: CompanionEngine.Plan.Notice] = [:]
	/// What a backup would say about projects' newer data.
	var backupCompanionNotes: VaultBackupCompanionNotes {
		get { lock.withLock { storedBackupCompanionNotes } }
		set { lock.withLock { storedBackupCompanionNotes = newValue } }
	}
	private var storedBackupCompanionNotes = VaultBackupCompanionNotes()
	/// Makes reading project states fail, as a Keychain error after a commit would.
	var failCompanionStates: Bool {
		get { lock.withLock { storedFailCompanionStates } }
		set { lock.withLock { storedFailCompanionStates = newValue } }
	}
	private var storedFailCompanionStates = false
	var companionRepairs: [(vaultId: String, reviewed: CompanionEngine.Assessment)] { lock.withLock { storedCompanionRepairs } }
	private var storedCompanionRepairs: [(vaultId: String, reviewed: CompanionEngine.Assessment)] = []
	var companionMaintenanceCount: Int { lock.withLock { storedCompanionMaintenanceCount } }
	private var storedCompanionMaintenanceCount = 0
	var valuesLeavingChecks: [String] { lock.withLock { storedValuesLeavingChecks } }
	private var storedValuesLeavingChecks: [String] = []

	func projectStatesResult(vaultIds: [String]) -> Result<VaultProjectStates, KeychainError> {
		// The real store reads every approval from one listing, which fails as a whole.
		if failCompanionStates || lock.withLock({ shouldFail || failCliAccess }) { return .failure(failureError) }
		return readableCliAccess(vaultIds: vaultIds).map { access in
			lock.withLock {
				let wanted = Set(vaultIds)
				defer { storedCompanionNotices = [:] }
				return VaultProjectStates(
					cliAccess: access,
					companion: storedCompanionStates.filter { wanted.contains($0.key) },
					unfinished: storedCompanionUnfinished.filter { wanted.contains($0.key) },
					resumed: storedCompanionNotices)
			}
		}
	}

	func repairCompanionData(vaultId: String, reviewed: CompanionEngine.Assessment) -> Result<CompanionRepairOutcome, KeychainError> {
		lock.withLock {
			if shouldFail { return .failure(failureError) }
			guard storedCompanionStates[vaultId] == reviewed else { return .failure(.companion(.changedSinceReview)) }
			storedCompanionRepairs.append((vaultId, reviewed))
			storedCompanionStates[vaultId] = nil
			storedCompanionRefusals[vaultId] = nil
			return .success(storedFailCompanionStates ? .repairedStateUnknown : .repaired(nil))
		}
	}

	func maintainCompanionStorage() -> Result<CompanionMaintenance, KeychainError> {
		lock.withLock {
			storedCompanionMaintenanceCount += 1
			return .success(CompanionMaintenance(orphanDeletions: 0, accessFixes: 0))
		}
	}

	func authorizeValuesLeaving(vaultId: String) -> Result<Void, KeychainError> {
		lock.withLock {
			storedValuesLeavingChecks.append(vaultId)
			if let refusal = storedCompanionRefusals[vaultId] { return .failure(.companion(refusal)) }
			return .success(())
		}
	}

	func backupCompanionNotesResult() -> Result<VaultBackupCompanionNotes, KeychainError> {
		.success(backupCompanionNotes)
	}

	func projectMetadataResult(vaultId: String) -> Result<VaultProjectMetadata?, KeychainError> {
		lock.withLock {
			if failProjectReads { return .failure(failureError) }
			return .success(envStorage[vaultId].map { project in
				VaultProjectMetadata(
					id: vaultId, name: project.name, path: project.path,
					environmentSummaries: project.environments.map { VaultProjectEnvironmentSummary(name: $0.key, keyCount: $0.value.count) }
						.sorted { $0.name < $1.name })
			})
		}
	}

	func setCliAccess(vaultId: String, access: VaultCliAccess) -> Result<VaultCliAccess, KeychainError> {
		lock.withLock {
			if shouldFail || failCliAccessChange { return .failure(failureError) }
			guard envStorage[vaultId] != nil else { return .failure(.itemNotFound) }
			cliAccessPolicies[vaultId] = access
			cliAccessChangeCount += 1
			afterCliAccessCommit?()
			return .success(access)
		}
	}
	private let lock = NSRecursiveLock()
	private var environments: [String: (name: String, path: String, environments: [String: [String: String]])] = [:]
	var envStorage: [String: (name: String, path: String, environments: [String: [String: String]])] {
		_read {
			lock.lock()
			defer { lock.unlock() }
			yield environments
		}
		_modify {
			lock.lock()
			defer { lock.unlock() }
			yield &environments
		}
	}
	private var records: [String: Data] = [:]
	var dataStorage: [String: Data] {
		_read {
			lock.lock()
			defer { lock.unlock() }
			yield records
		}
		_modify {
			lock.lock()
			defer { lock.unlock() }
			yield &records
		}
	}
	var shouldFail = false
	var failureError: KeychainError = .accessDenied
	var failProjectReads = false
	var projectReadCount = 0
	var projectMetadataReadCount = 0
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
	var nextVaultTransactionError: KeychainError?
	/// Commits the next vault transaction, then reports this error, as a Keychain whose commit outcome was lost would.
	var nextVaultTransactionErrorAfterCommit: KeychainError?
	var nextKeychainTransactionError: KeychainError?
	var onGetEnvironments: (() -> Void)?
	var onCreateEnvironments: (() -> Void)?
	var blockNextSaveEnvironments: (() -> Void)?
	var blockNextVaultTransaction: (() -> Void)?
	var blockNextListProjects: (() -> Void)?
	var blockNextListProjectMetadata: (() -> Void)?
	var blockNextDeleteProject: (() -> Void)?
	var failWriteDataAccounts: Set<String> = []
	var failNextSaveEnvironments = false

	func withKeychainTransaction<T>(_ operation: () -> T) -> Result<T, KeychainError> {
		beforeKeychainTransaction?()
		if let error = nextKeychainTransactionError { nextKeychainTransactionError = nil; return .failure(error) }
		let result = lock.withLock(operation)
		afterKeychainTransaction?()
		return .success(result)
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

		return lock.withLock {
			if failProjectReads { return .failure(failureError) }
			if let refusal = storedCompanionRefusals[vaultId] { return .failure(.companion(refusal)) }
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

	/// Projects whose values need an approval the unlock didn't give, which a
	/// read that can't ask fails on, as macOS refuses it.
	var projectsNeedingApproval: Set<String> {
		get { lock.withLock { storedProjectsNeedingApproval } }
		set { lock.withLock { storedProjectsNeedingApproval = newValue } }
	}
	private var storedProjectsNeedingApproval: Set<String> = []
	/// Why a read that can't ask fails for a project, as a Keychain error would.
	var unpromptedReadFailures: [String: KeychainError] {
		get { lock.withLock { storedUnpromptedReadFailures } }
		set { lock.withLock { storedUnpromptedReadFailures = newValue } }
	}
	private var storedUnpromptedReadFailures: [String: KeychainError] = [:]
	/// Each project a read that can't ask read, in order.
	var unpromptedProjectReads: [String] { lock.withLock { storedUnpromptedProjectReads } }
	private var storedUnpromptedProjectReads: [String] = []
	/// Runs before each read that can't ask, outside the lock, with the
	/// project it reads, as a slow Keychain would.
	var beforeUnpromptedProjectRead: (@Sendable (String) -> Void)? {
		get { lock.withLock { storedBeforeUnpromptedProjectRead } }
		set { lock.withLock { storedBeforeUnpromptedProjectRead = newValue } }
	}
	private var storedBeforeUnpromptedProjectRead: (@Sendable (String) -> Void)?

	func getProjectResultWithoutPrompting(vaultId: String) -> Result<VaultProject?, KeychainError> {
		let hook = lock.withLock {
			storedUnpromptedProjectReads.append(vaultId)
			return storedBeforeUnpromptedProjectRead
		}
		hook?(vaultId)
		let failure = lock.withLock {
			storedProjectsNeedingApproval.contains(vaultId) ? KeychainError.keychainLocked : storedUnpromptedReadFailures[vaultId]
		}
		if let failure { return .failure(failure) }
		return getProjectResult(vaultId: vaultId)
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

	private(set) var existingVaultPayloadsCallCount = 0
	private var existingVaultPayloadsPause: (entered: DispatchSemaphore, gate: DispatchSemaphore)?

	/// Makes the next existence check signal `entered` once it has its
	/// answer, then wait for `gate` before returning it.
	func pauseNextExistenceCheck(entered: DispatchSemaphore, gate: DispatchSemaphore) {
		lock.withLock { existingVaultPayloadsPause = (entered, gate) }
	}

	func existingVaultPayloads(vaultIds: [String]) -> Result<Set<String>, KeychainError> {
		let (result, pause) = lock.withLock { () -> (Result<Set<String>, KeychainError>, (entered: DispatchSemaphore, gate: DispatchSemaphore)?) in
			existingVaultPayloadsCallCount += 1
			defer { existingVaultPayloadsPause = nil }
			if shouldFail || failProjectReads { return (.failure(failureError), existingVaultPayloadsPause) }
			return (.success(Set(vaultIds.filter { environments[$0] != nil })), existingVaultPayloadsPause)
		}
		if let pause {
			pause.entered.signal()
			pause.gate.wait()
		}
		return result
	}

	func removeFromSidebar(vaultId: String) -> Bool {
		if shouldFail { return false }
		// Only remove from listing, keep data (like real implementation)
		return true
	}

	/// Payloads of projects removed from the sidebar, which only a backup reads.
	var hiddenPayloads: [String: [String: [String: String]]] = [:]
	var failBackupInventory = false
	var backupInventoryReadCount = 0

	var failRestoreWrites = false
	func storedVaultIdsResult() -> Result<Set<String>, KeychainError> {
		lock.withLock {
			if shouldFail { return .failure(failureError) }
			return .success(Set(envStorage.keys).union(hiddenPayloads.keys))
		}
	}

	/// Runs as a restored project is about to be written.
	var beforeRestoredProjectWrite: (@Sendable (VaultProject) -> Void)?

	func createRestoredProjectResult(_ project: VaultProject, listed: Bool) -> KeychainResult {
		beforeRestoredProjectWrite?(project)
		return lock.withLock {
			if shouldFail || failRestoreWrites { return .failure(failureError) }
			guard envStorage[project.id] == nil, hiddenPayloads[project.id] == nil else { return .failure(.duplicateItem) }
			let environments = project.environments.isEmpty ? ["default": [:]] : project.environments
			if listed {
				envStorage[project.id] = (name: project.name, path: project.path, environments: environments)
			} else {
				hiddenPayloads[project.id] = environments
			}
			cliAccessPolicies[project.id] = .requireApproval
			return .success
		}
	}

	func mergeRestoredProjectResult(
		vaultId: String,
		expected: [String: [String: String]],
		merged: [String: [String: String]],
		additionalMutations: [VaultKeychainMutation]
	) -> VaultRestoreWriteResult {
		lock.withLock {
			if shouldFail || failRestoreWrites { return .failure(failureError) }
			if let listed = envStorage[vaultId] {
				guard listed.environments == expected else { return .changedSinceReview }
				envStorage[vaultId]?.environments = merged
			} else if let hidden = hiddenPayloads[vaultId] {
				guard hidden == expected else { return .changedSinceReview }
				hiddenPayloads[vaultId] = merged
			} else {
				return .failure(.itemNotFound)
			}
			for mutation in additionalMutations { dataStorage[mutation.account] = mutation.data }
			return .written(warning: nil)
		}
	}

	func backupInventoryResult() -> Result<VaultBackupInventory, KeychainError> {
		lock.withLock {
			backupInventoryReadCount += 1
			if shouldFail || failBackupInventory { return .failure(failureError) }
			let listed = envStorage.map { vaultId, project in
				VaultBackupProject(
					vaultId: vaultId,
					listing: .init(name: project.name, folder: project.path),
					environments: project.environments,
					cliAccess: cliAccessPolicies[vaultId] ?? .automatic
				)
			}
			let hidden = hiddenPayloads.map { vaultId, environments in
				VaultBackupProject(vaultId: vaultId, listing: nil, environments: environments, cliAccess: cliAccessPolicies[vaultId] ?? .automatic)
			}
			return .success(VaultBackupInventory(projects: (listed + hidden).sorted { $0.vaultId < $1.vaultId }, unusableItems: 0))
		}
	}

	func applyVaultTransaction(
		project: VaultProjectKeychainMutation?,
		data mutations: [VaultKeychainMutation]
	) -> KeychainResult {
		lock.lock()
		let blocker = blockNextVaultTransaction
		blockNextVaultTransaction = nil
		lock.unlock()
		blocker?()
		lock.lock()
		defer { lock.unlock() }
		applyVaultTransactionCallCount += 1
		if let error = nextVaultTransactionError { nextVaultTransactionError = nil; return .failure(error) }
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
		case .rename(let vaultId, let name):
			if envStorage[vaultId] != nil {
				envStorage[vaultId]?.name = name
				projectResult = .success
			} else {
				projectResult = .failure(.itemNotFound)
			}
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
		if let error = nextVaultTransactionErrorAfterCommit {
			nextVaultTransactionErrorAfterCommit = nil
			return .failure(error)
		}
		return projectResult
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

	private var appItems: [AppKeychainStore: [String: Data]] = [:]
	private var failingAppItems: [AppKeychainStore: Set<String>] = [:]
	private var appItemListCounts: [AppKeychainStore: Int] = [:]
	private var appItemReadCounts: [AppKeychainStore: Int] = [:]
	private var readFailures: Set<String> = []
	private var writeFailures: Set<String> = []

	/// How many times the store's app items were listed.
	func appItemListCount(_ store: AppKeychainStore) -> Int { lock.withLock { appItemListCounts[store] ?? 0 } }
	/// How many app items of the store were read.
	func appItemReadCount(_ store: AppKeychainStore) -> Int { lock.withLock { appItemReadCounts[store] ?? 0 } }
	/// Accounts whose reads fail, while writing and deleting them work.
	var failAppItemReads: Set<String> {
		get { lock.withLock { readFailures } }
		set { lock.withLock { readFailures = newValue } }
	}
	/// Accounts whose writes fail, while reading and deleting them work.
	var failAppItemWrites: Set<String> {
		get { lock.withLock { writeFailures } }
		set { lock.withLock { writeFailures = newValue } }
	}

	var publishingStorage: [String: Data] {
		get { lock.withLock { appItems[.publishing] ?? [:] } }
		set { lock.withLock { appItems[.publishing] = newValue } }
	}
	/// Accounts whose operations fail; "*" also fails the listing.
	var failPublishingAccounts: Set<String> {
		get { lock.withLock { failingAppItems[.publishing] ?? [] } }
		set { lock.withLock { failingAppItems[.publishing] = newValue } }
	}
	var publishingAccountsCallCount: Int { lock.withLock { appItemListCounts[.publishing] ?? 0 } }

	var platformConnectionStorage: [String: Data] {
		get { lock.withLock { appItems[.platformConnections] ?? [:] } }
		set { lock.withLock { appItems[.platformConnections] = newValue } }
	}
	/// Accounts whose operations fail; "*" also fails the listing.
	var failPlatformConnectionAccounts: Set<String> {
		get { lock.withLock { failingAppItems[.platformConnections] ?? [] } }
		set { lock.withLock { failingAppItems[.platformConnections] = newValue } }
	}

	var platformCleanupStorage: [String: Data] {
		get { lock.withLock { appItems[.platformCleanup] ?? [:] } }
		set { lock.withLock { appItems[.platformCleanup] = newValue } }
	}
	/// Accounts whose operations fail; "*" also fails the listing.
	var failPlatformCleanupAccounts: Set<String> {
		get { lock.withLock { failingAppItems[.platformCleanup] ?? [] } }
		set { lock.withLock { failingAppItems[.platformCleanup] = newValue } }
	}

	/// Runs before each app item read, outside the mock's lock, so a test can hold a chosen read there.
	var beforeAppItemRead: (@Sendable (AppKeychainStore, String) -> Void)? {
		get { lock.withLock { readHook } }
		set { lock.withLock { readHook = newValue } }
	}
	private var readHook: (@Sendable (AppKeychainStore, String) -> Void)?

	func readAppItem(_ store: AppKeychainStore, account: String) -> Result<Data?, KeychainError> {
		lock.withLock { readHook }?(store, account)
		return lock.withLock {
			appItemReadCounts[store, default: 0] += 1
			if failingAppItems[store]?.contains(account) == true || readFailures.contains(account) { return .failure(failureError) }
			return .success(appItems[store]?[account])
		}
	}

	/// Runs before each app item write, outside the mock's lock, so a test can hold the caller there.
	var beforeAppItemWrite: (@Sendable () -> Void)? {
		get { lock.withLock { writeHook } }
		set { lock.withLock { writeHook = newValue } }
	}
	private var writeHook: (@Sendable () -> Void)?

	func writeAppItem(_ store: AppKeychainStore, account: String, data: Data) -> Result<Void, KeychainError> {
		lock.withLock { writeHook }?()
		return lock.withLock {
			if failingAppItems[store]?.contains(account) == true || writeFailures.contains(account) { return .failure(failureError) }
			appItems[store, default: [:]][account] = data
			return .success(())
		}
	}

	func insertAppItem(_ store: AppKeychainStore, account: String, data: Data) -> Result<Bool, KeychainError> {
		lock.withLock {
			if failingAppItems[store]?.contains(account) == true { return .failure(failureError) }
			guard appItems[store]?[account] == nil else { return .success(false) }
			appItems[store, default: [:]][account] = data
			return .success(true)
		}
	}

	/// Accounts whose deletion fails, while reading and writing them work.
	var failAppItemDeletes: Set<String> {
		get { lock.withLock { deleteFailures } }
		set { lock.withLock { deleteFailures = newValue } }
	}
	private var deleteFailures: Set<String> = []

	func deleteAppItem(_ store: AppKeychainStore, account: String) -> Result<Void, KeychainError> {
		lock.withLock {
			if failingAppItems[store]?.contains(account) == true || deleteFailures.contains(account) { return .failure(failureError) }
			appItems[store]?.removeValue(forKey: account)
			return .success(())
		}
	}

	/// Runs before each app item listing, outside the mock's lock, so a test can hold the caller there.
	var beforeAppItemListing: (@Sendable () -> Void)? {
		get { lock.withLock { listingHook } }
		set { lock.withLock { listingHook = newValue } }
	}
	private var listingHook: (@Sendable () -> Void)?

	func appItemAccounts(_ store: AppKeychainStore) -> Result<[String], KeychainError> {
		lock.withLock { listingHook }?()
		return lock.withLock {
			appItemListCounts[store, default: 0] += 1
			if failingAppItems[store]?.contains("*") == true { return .failure(failureError) }
			return .success(Array((appItems[store] ?? [:]).keys))
		}
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

// MARK: - Mock Biometric Service

final class MockBiometricService: BiometricServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	var shouldSucceed = true
	/// What an unsuccessful attempt reports; a dismissed prompt by default.
	var failureOutcome: AuthenticationOutcome = .cancelled
	var isAvailable = true
	var type: BiometricType = .touchID
	var authenticateHandlers: [@Sendable () async -> Bool] = []
	private var authenticationCalls = 0
	private var reasons: [String] = []
	private var confirmations: [String] = []

	var authenticateCallCount: Int { lock.withLock { authenticationCalls } }
	/// The prompt reason of each authentication request, in order.
	var authenticationReasons: [String] { lock.withLock { reasons } }
	/// The reason of each confirmation that couldn't reuse an earlier approval, in order.
	var confirmationReasons: [String] { lock.withLock { confirmations } }

	func confirm(reason: String) async -> AuthenticationOutcome {
		lock.withLock { confirmations.append(reason) }
		return await authenticate(reason: reason)
	}

	func authenticate(reason: String) async -> AuthenticationOutcome {
		let response: ((@Sendable () async -> Bool)?, Bool, AuthenticationOutcome) = lock.withLock {
			authenticationCalls += 1
			reasons.append(reason)
			let handler = authenticateHandlers.isEmpty ? nil : authenticateHandlers.removeFirst()
			return (handler, shouldSucceed, failureOutcome)
		}
		let succeeded = await response.0?() ?? response.1
		return succeeded ? .authenticated : response.2
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
	var userResponses: [LPMUser?] = []
	var personalTokens: [LPMToken] = []
	var orgTokensMap: [String: [LPMToken]] = [:]
	var orgTokenErrors: [String: LPMAPIError] = [:]
	var revokedTokenIds: [String] = []
	var personalTokenResponses: [[LPMToken]] = []
	var orgTokensDelay: Duration?
	var personalTokensError: LPMAPIError?
	var personalRevokeError: LPMAPIError?
	var orgRevokeError: LPMAPIError?
	var requestedOrgSlugs: [String] = []
	var receivedAuthTokens: [String] = []
	var currentUserFetchCount = 0
	var personalTokenFetchCount = 0
	var orgTokenFetchCount = 0
	var activeOrgRequests = 0
	/// The organization token reads under way now.
	var inFlightOrgRequests: Int { lock.withLock { activeOrgRequests } }
	var maximumActiveOrgRequests = 0
	var blockNextCurrentUserFetch: (@Sendable () async -> Void)?
	/// Runs in every organization token read, while it counts as under way.
	var duringOrgTokenFetch: (@Sendable () async -> Void)?
	var blockNextPersonalTokenFetch: (@Sendable () async -> Void)?
	var blockNextPersonalRevoke: (@Sendable () async -> Void)?
	var blockNextOrgRevoke: (@Sendable () async -> Void)?

	func fetchCurrentUser(authToken: String) async -> LPMAPIResult<LPMUser> {
		let (response, blocker): (LPMUser?, (@Sendable () async -> Void)?) = lock.withLock {
			receivedAuthTokens.append(authToken)
			currentUserFetchCount += 1
			let response = !userResponses.isEmpty ? userResponses.removeFirst() : user
			let blocker = blockNextCurrentUserFetch
			blockNextCurrentUserFetch = nil
			return (response, blocker)
		}
		await blocker?()
		guard !Task.isCancelled else { return .failure(.cancelled) }
		return response.map(LPMAPIResult.success) ?? .failure(.unauthorized)
	}

	func fetchPersonalTokens(authToken: String) async -> LPMAPIResult<[LPMToken]> {
		let (tokens, blocker): ([LPMToken], (@Sendable () async -> Void)?) = lock.withLock {
			receivedAuthTokens.append(authToken)
			personalTokenFetchCount += 1
			let tokens = !personalTokenResponses.isEmpty ? personalTokenResponses.removeFirst() : personalTokens
			let blocker = blockNextPersonalTokenFetch
			blockNextPersonalTokenFetch = nil
			return (tokens, blocker)
		}
		await blocker?()
		guard !Task.isCancelled else { return .failure(.cancelled) }
		if let personalTokensError { return .failure(personalTokensError) }
		return .success(tokens)
	}

	func revokePersonalToken(id: String, authToken: String) async -> LPMAPIResult<Void> {
		let blocker = lock.withLock {
			receivedAuthTokens.append(authToken)
			revokedTokenIds.append(id)
			let blocker = blockNextPersonalRevoke
			blockNextPersonalRevoke = nil
			return blocker
		}
		await blocker?()
		guard !Task.isCancelled else { return .failure(.cancelled) }
		if let personalRevokeError { return .failure(personalRevokeError) }
		return .success(())
	}

	func fetchOrgTokens(orgSlug: String, authToken: String) async -> LPMAPIResult<[LPMToken]> {
		let response: (delay: Duration?, result: LPMAPIResult<[LPMToken]>, hold: (@Sendable () async -> Void)?) = lock.withLock {
			receivedAuthTokens.append(authToken)
			orgTokenFetchCount += 1
			requestedOrgSlugs.append(orgSlug)
			activeOrgRequests += 1
			maximumActiveOrgRequests = max(maximumActiveOrgRequests, activeOrgRequests)
			let result = orgTokenErrors[orgSlug].map(LPMAPIResult.failure)
				?? .success(orgTokensMap[orgSlug] ?? [])
			return (orgTokensDelay, result, duringOrgTokenFetch)
		}
		await response.hold?()
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
		await blocker?()
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
	var blockNextPushPreparation: (@Sendable () async -> Void)?
	var blockNextPush: (@Sendable () async -> Void)?
	private var publicKeyCalls = 0
	private var memberKeyAccessCalls = 0
	private var pullCalls = 0
	private var pushCalls = 0
	private var lastPush: (blob: String, wrappedKeys: [SyncService.WrappedMemberKey]?)?
	var capturedPush: (blob: String, wrappedKeys: [SyncService.WrappedMemberKey]?)? { lock.withLock { lastPush } }

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

	func preparePushOrgAuthenticated(
		authToken: String, orgSlug: String, expectedOrganizationID: String,
		expectedCallerUserID: String, vaultId: String, encryptedBlob: String,
		wrappedKeys: [SyncService.WrappedMemberKey]?, expectedVersion: Int?,
		name: String?, schema: LPMJSONValue?
	) async -> PreparedRemoteOperation<SyncService.AuthenticatedResponse<SyncService.SyncStatus>> {
		let blocker = lock.withLock {
			let blocker = blockNextPushPreparation
			blockNextPushPreparation = nil
			return blocker
		}
		await blocker?()
		return PreparedRemoteOperation {
			.run {
				await self.pushOrgAuthenticated(authToken: authToken, orgSlug: orgSlug,
					expectedOrganizationID: expectedOrganizationID, expectedCallerUserID: expectedCallerUserID,
					vaultId: vaultId, encryptedBlob: encryptedBlob, wrappedKeys: wrappedKeys,
					expectedVersion: expectedVersion, name: name, schema: schema)
			}
		}
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
			lastPush = (encryptedBlob, wrappedKeys)
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

	/// A file is known by its name, and pasted text as "pasted text".
	func load(_ input: EnvImportInput) async throws -> ImportedEnvFile {
		let key = switch input {
		case .file(let url): url.lastPathComponent
		case .text: "pasted text"
		}
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

/// Whether the caller runs on a thread of Swift's cooperative pool, which
/// blocking work must never hold: every other task needs those threads.
func isOnCooperativePool() -> Bool {
	String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative")
}

/// Where blocking work ran, each time a test recorded it.
final class PoolObservation: @unchecked Sendable {
	private let lock = NSLock()
	private var observations: [(onPool: Bool, onMain: Bool)] = []

	func record() {
		let observation = (onPool: isOnCooperativePool(), onMain: pthread_main_np() != 0)
		lock.withLock { observations.append(observation) }
	}

	/// Recorded at least once, and never on the cooperative pool.
	var stayedOffPool: Bool { lock.withLock { !observations.isEmpty && !observations.contains { $0.onPool } } }

	/// Recorded at least once, and never on the main thread or the cooperative pool.
	var stayedOffMainAndPool: Bool {
		lock.withLock { !observations.isEmpty && !observations.contains { $0.onPool || $0.onMain } }
	}
}

/// Keychain items in memory, by service and account, for stores a test builds.
final class InMemoryKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
	private let lock = NSLock()
	private var items: [String: [String: Data]] = [:]

	func read(service: String, account: String) throws -> Data? {
		lock.withLock { items[service]?[account] }
	}

	func write(service: String, account: String, data: Data) throws {
		lock.withLock { items[service, default: [:]][account] = data }
	}

	func add(service: String, account: String, data: Data) throws {
		try lock.withLock {
			guard items[service]?[account] == nil else {
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			items[service, default: [:]][account] = data
		}
	}

	@discardableResult
	func delete(service: String, account: String) throws -> Bool {
		lock.withLock { items[service]?.removeValue(forKey: account) != nil }
	}

	func accounts(service: String) throws -> [String: VaultCliAccess] {
		lock.withLock { (items[service] ?? [:]).mapValues { _ in .automatic } }
	}
}

extension BackupKeyStore {
	static let testRootService = "test.env-personal-root-v2"
	static let testSharingService = "test.vault"
	static let testWrappingService = "test.vault-key"

	/// Key stores in `backend`, with key floors in `home`.
	static func inMemory(_ backend: InMemoryKeychainBackend, home: LPMHome) -> BackupKeyStore {
		BackupKeyStore(
			roots: SharedKeychainStore(service: testRootService, backend: backend),
			sharing: SharedKeychainStore(service: testSharingService, backend: backend),
			wrapping: SharedKeychainStore(service: testWrappingService, backend: backend),
			home: home)
	}
}

/// An LPM home in `folder`, its directory owner-only as the CLI makes it.
func testLPMHome(in folder: URL) throws -> LPMHome {
	let home = LPMHome(defaultIn: folder)
	try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
	return home
}
