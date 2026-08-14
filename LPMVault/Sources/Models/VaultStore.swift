import CryptoKit
import Foundation

// MARK: - Strict Key Trust for Org Members

/// A member key that requires explicit user approval before the vault
/// is encrypted for them. Covers both new members (never seen) and
/// existing members whose key changed (rotation or compromise).
struct PendingKeyApproval: Identifiable {
	let id = UUID()
	let memberId: String
	let fingerprint: String
	/// true = first-time member, false = existing member whose key changed
	let isNewMember: Bool
	/// Previous fingerprint (nil for new members)
	let oldFingerprint: String?
}

/// Holds all context needed to resume an org push after the user
/// approves pending member keys in the KeyApprovalSheet.
struct PendingOrgPush {
	let orgSlug: String
	let projectId: String
	let allMembers: [SyncService.MemberPublicKey]
	let pendingApprovals: [PendingKeyApproval]
	var orgTrust: OrgKeyTrust
	let authToken: String
	let canReplaceWrappedKeys: Bool
	var environment: AppEnvironment = .production
	var authGeneration: Int = 0
	var sessionGeneration: Int = 0
	var operationGeneration: Int = 0
}

struct VaultSyncError: LocalizedError {
	let message: String

	init(_ message: String) {
		self.message = message
	}

	var errorDescription: String? { message }
}

private struct SyncAuthority: Sendable {
	let projectId: String
	let account: SelectedAccount
	let environment: AppEnvironment
	let authGeneration: Int
	let sessionGeneration: Int
	let operationGeneration: Int
	let authToken: String
}

struct ImportedEnvProject: Sendable, Equatable {
	let projectId: String
	let version: Int
	let keyCount: Int
}

private struct TokenInventory: Sendable {
	let user: LPMUser
	let personalTokens: [LPMToken]
	let organizationTokens: [String: [LPMToken]]
}

private struct OrganizationTokenResult: Sendable {
	let slug: String
	let result: LPMAPIResult<[LPMToken]>
}

struct LocalEnvImportTarget: Hashable, Sendable {
	let projectId: String
	let environment: String
}

/// Synchronous commit authority shared with the persistence actor. A UI
/// invalidation that wins this lock prevents a queued transaction from
/// crossing its durable commit point.
final class LocalEnvImportAuthority: @unchecked Sendable {
	private enum State {
		case pending
		case committing
	}

	private struct Request {
		let id: UUID
		var state: State
	}

	private let lock = NSLock()
	private var requests: [LocalEnvImportTarget: Request] = [:]

	func begin(_ target: LocalEnvImportTarget, requestId: UUID) {
		lock.withLock { requests[target] = Request(id: requestId, state: .pending) }
	}

	/// Establishes the commit point with one atomic state transition. If
	/// cancellation wins first, persistence is rejected. Once commit wins,
	/// later cancellation cannot turn durable success into a cancelled result.
	func beginCommit(_ target: LocalEnvImportTarget, requestId: UUID) -> Bool {
		lock.withLock {
			guard var request = requests[target], request.id == requestId,
				request.state == .pending
			else { return false }
			request.state = .committing
			requests[target] = request
			return true
		}
	}

	func cancel(_ target: LocalEnvImportTarget, requestId: UUID? = nil) {
		lock.withLock {
			guard let request = requests[target],
				(requestId == nil || request.id == requestId),
				request.state == .pending
			else { return }
			requests.removeValue(forKey: target)
		}
	}

	func complete(_ target: LocalEnvImportTarget, requestId: UUID) {
		lock.withLock {
			guard requests[target]?.id == requestId else { return }
			requests.removeValue(forKey: target)
		}
	}
}

private enum TokenInventoryLoader {
	static let maximumConcurrentOrganizations = 4

	static func load(
		user: LPMUser,
		authToken: String,
		service: any LPMAPIServiceProtocol
	) async -> LPMAPIResult<TokenInventory> {
		async let personalResult = service.fetchPersonalTokens(authToken: authToken)
		let organizationResult = await loadOrganizations(
			user.orgs ?? [],
			authToken: authToken,
			service: service
		)
		let resolvedPersonal = await personalResult
		guard !Task.isCancelled else { return .failure(.cancelled) }

		switch (resolvedPersonal, organizationResult) {
		case (.success(let personal), .success(let organizations)):
			return .success(TokenInventory(
				user: user,
				personalTokens: personal,
				organizationTokens: organizations
			))
		case (.failure(let error), _):
			return .failure(error)
		case (_, .failure(let error)):
			return .failure(error)
		}
	}

	private static func loadOrganizations(
		_ organizations: [LPMOrg],
		authToken: String,
		service: any LPMAPIServiceProtocol
	) async -> LPMAPIResult<[String: [LPMToken]]> {
		let eligible = organizations
			.filter { organization in
				guard let role = organization.role?.lowercased() else { return false }
				return role == "owner" || role == "admin"
			}
			.sorted { $0.slug < $1.slug }
		guard !eligible.isEmpty else { return .success([:]) }

		return await withTaskGroup(of: OrganizationTokenResult.self) { group in
			var iterator = eligible.makeIterator()
			var results: [String: [LPMToken]] = [:]

			func addNext() -> Bool {
				guard !Task.isCancelled, let organization = iterator.next() else { return false }
				group.addTask {
					OrganizationTokenResult(
						slug: organization.slug,
						result: await service.fetchOrgTokens(
							orgSlug: organization.slug,
							authToken: authToken
						)
					)
				}
				return true
			}

			for _ in 0..<min(maximumConcurrentOrganizations, eligible.count) {
				_ = addNext()
			}

			while let next = await group.next() {
				guard !Task.isCancelled else {
					group.cancelAll()
					return .failure(.cancelled)
				}
				switch next.result {
				case .success(let tokens):
					// Keep successful empty inventories distinct from request failure.
					results[next.slug] = tokens
				case .failure(let error):
					group.cancelAll()
					return .failure(error)
				}
				_ = addNext()
			}

			return .success(results)
		}
	}
}

enum EnvProjectImportError: LocalizedError, Sendable, Equatable {
	case cancelled
	case duplicate
	case notAuthenticated
	case noResponse
	case noData(String)
	case invalidSharingKey(String)
	case invalidPayload(String)
	case persistence(String)

	var errorDescription: String? {
		switch self {
		case .cancelled: "Import cancelled."
		case .duplicate: "This env project is already available locally."
		case .notAuthenticated: "Sign in to lpm.dev, then retry."
		case .noResponse: "The server request failed. Check your connection and try again."
		case .noData(let message), .invalidSharingKey(let message),
			.invalidPayload(let message), .persistence(let message): message
		}
	}
}

struct OrgKeyTrust: Codable {
	/// member_id → SHA256 hex fingerprint of their public key
	var trustedFingerprints: [String: String]

	init(trustedFingerprints: [String: String] = [:]) {
		self.trustedFingerprints = trustedFingerprints
	}

	/// Verify member public keys against trusted fingerprints (strict mode).
	/// - New members are NOT auto-trusted — they produce pending approvals.
	/// - Changed keys for existing members also produce pending approvals.
	/// - Returns empty array only when every member key is already trusted and unchanged.
	/// - Does NOT mutate trustedFingerprints — caller must explicitly approve via `approve(_:)`.
	func verify(members: [(id: String, publicKey: Data)]) -> [PendingKeyApproval] {
		var pending: [PendingKeyApproval] = []

		for member in members {
			let fingerprint = SHA256.hash(data: member.publicKey)
				.map { String(format: "%02x", $0) }.joined()

			if let existing = trustedFingerprints[member.id] {
				if existing != fingerprint {
					pending.append(PendingKeyApproval(
						memberId: member.id,
						fingerprint: fingerprint,
						isNewMember: false,
						oldFingerprint: existing
					))
				}
				// Same key — trusted, no action needed
			} else {
				// New member — requires explicit approval (strict mode)
				pending.append(PendingKeyApproval(
					memberId: member.id,
					fingerprint: fingerprint,
					isNewMember: true,
					oldFingerprint: nil
				))
			}
		}

		return pending
	}

	/// Mark approved members as trusted. Call only after the user explicitly
	/// accepts each key in the KeyApprovalSheet.
	mutating func approve(_ approvals: [PendingKeyApproval]) {
		for approval in approvals {
			trustedFingerprints[approval.memberId] = approval.fingerprint
		}
	}

	// MARK: - Keychain Persistence

	private static let service = VaultConstants.keychainService

	/// Load trusted fingerprints for an org from Keychain.
	static func load(orgSlug: String) -> OrgKeyTrust {
		let account = "__org_keys__\(orgSlug)"
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)

		guard status == errSecSuccess,
			  let data = result as? Data,
			  let trust = try? JSONDecoder().decode(OrgKeyTrust.self, from: data)
		else {
			return OrgKeyTrust()
		}
		return trust
	}

	/// Save trusted fingerprints for an org to Keychain.
	func save(orgSlug: String) {
		let account = "__org_keys__\(orgSlug)"
		guard let data = try? JSONEncoder().encode(self) else { return }

		let searchQuery: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: Self.service,
			kSecAttrAccount as String: account,
		]

		let updateAttrs: [String: Any] = [
			kSecValueData as String: data,
		]

		let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
		if updateStatus == errSecItemNotFound {
			let addQuery: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: Self.service,
				kSecAttrAccount as String: account,
				kSecValueData as String: data,
				kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
			]
			SecItemAdd(addQuery as CFDictionary, nil)
		}
	}
}

// MARK: - App Environment

enum AppEnvironment: String, Sendable {
	case production
	#if DEBUG
	case development
	#endif

	var baseURL: URL {
		switch self {
		case .production: VaultConstants.apiBaseURL
		#if DEBUG
		case .development: VaultConstants.localAPIBaseURL
		#endif
		}
	}

	var registryURL: String {
		AuthSessionStore.registryURL(for: baseURL)
	}

	var label: String {
		switch self {
		case .production: "Live"
		#if DEBUG
		case .development: "Local"
		#endif
		}
	}
}

// MARK: - Sync Types

struct SyncMetadata: Codable {
	var lastSyncedAt: Date?
	var lastAction: String?  // "push" or "pull"
	var lastVersion: Int?
	var isDirty: Bool = false
}

enum ProjectSyncStatus {
	case neverSynced
	case synced
	case localChanges
}

enum AddSecretError: LocalizedError, Sendable, Equatable {
	case vaultLocked
	case targetUnavailable
	case invalidName
	case duplicate
	case caseInsensitiveCollision(existingKey: String)
	case persistence(String)

	var errorDescription: String? {
		switch self {
		case .vaultLocked:
			"Unlock LPM Vault before adding a secret."
		case .targetUnavailable:
			"The target env project or environment changed before the secret was saved."
		case .invalidName:
			"Use letters, numbers, and underscores; the first character cannot be a number."
		case .duplicate:
			"A secret with this key already exists."
		case .caseInsensitiveCollision(let existingKey):
			"A key named \(existingKey) already exists. Rename one key for Windows compatibility."
		case .persistence(let message):
			"Could not save the secret. \(message)"
		}
	}
}

enum AddSecretResult: Sendable, Equatable {
	case success
	case failure(AddSecretError)
}

@Observable
@MainActor
final class VaultStore {
	// MARK: - State

	var projects: [VaultProject] = []
	var selectedProjectId: String? {
		didSet {
			guard oldValue != selectedProjectId else { return }
			if let oldValue { cancelLocalEnvImports(projectId: oldValue) }
			cancelLocalEnvPreviews()
			invalidatePendingOrgPush()
		}
	}
	var isUnlocked: Bool = false
	var searchQuery: String = ""
	var error: String?
	var isLoadingProjects: Bool = false
	var isUnlocking: Bool = false

	// Auth state
	var currentUser: LPMUser? {
		didSet { reconcileNavigationState() }
	}
	var personalTokens: [LPMToken] = []
	var orgTokens: [String: [LPMToken]] = [:]  // orgSlug → tokens
	var isLoadingTokens: Bool = false
	var isLoggingIn: Bool = false

	// Navigation state
	var selectedAccount: SelectedAccount = .personal
	var showAuthStatus: Bool = false

	// Sync state
	var isSyncing: Bool = false
	var lastSyncStatus: String?

	// Sync metadata (persisted across launches)
	var syncMetadata: [String: SyncMetadata] = [:]

	// Vault → org associations (persisted in Keychain)
	var vaultOrgAssociations: [String: String] = [:] {  // vaultId → orgSlug
		didSet { reconcileNavigationState() }
	}

	// SECURITY NOTE: Environment tab ordering is stored in UserDefaults (not Keychain).
	// This is intentional — it contains only the display order of environment names
	// (e.g., ["default", "staging", "production"]), not secret values.
	// Moving to Keychain would add unnecessary complexity for non-sensitive UI state.
	var environmentOrders: [String: [String]] = [:]

	// App environment (dev vs live)
	var appEnvironment: AppEnvironment = .production

	// Strict key approval — blocks org push until user approves pending keys
	var pendingOrgPush: PendingOrgPush?
	var showKeyApprovalSheet: Bool = false

	// MARK: - Dependencies

	private let keychainService: KeychainServiceProtocol
	private let persistence: VaultPersistenceCoordinator
	private let biometricService: BiometricServiceProtocol
	private let injectedAPIService: LPMAPIServiceProtocol?
	private let apiServiceFactory: @Sendable (URL) -> any LPMAPIServiceProtocol
	private let importServiceFactory: @Sendable (URL) -> any EnvProjectImportServiceProtocol
	private let orgSyncServiceFactory: @Sendable (URL) -> any OrgSyncServiceProtocol
	private let personalSyncServiceFactory: @Sendable (URL) -> any PersonalSyncServiceProtocol
	private let envFileImportService: any EnvFileImportServiceProtocol
	private let sharingKeypairProvider: @Sendable () -> (privateKey: Data, publicKey: Data)
	private let authTokenProvider: @Sendable (String, URL) async -> String?
	private let loginProvider: @Sendable (String, URL) async throws -> AuthSessionCredentials
	private let authSessionWriter: @Sendable (AuthSessionCredentials, String) throws -> Void
	private let authSessionClearer: @Sendable (String) -> Void
	private let autoLockSleep: @Sendable (Duration) async throws -> Void
	private let autoLockNow: @Sendable () -> TimeInterval
	private var autoLockTask: Task<Void, Never>?
	private var autoLockDeadline: TimeInterval?
	private var autoLockTaskGeneration = 0
	private var projectLoadTask: Task<Void, Never>?
	private var projectLoadGeneration = 0
	private var tokenLoadTask: Task<Void, Never>?
	private var tokenLoadGeneration = 0
	private var authOperationGeneration = 0
	private var syncOperationGeneration = 0
	private var retainedAPIServices: [URL: any LPMAPIServiceProtocol] = [:]
	private var unlockGeneration = 0
	private var vaultSessionGeneration = 0
	private var activeImportIds: Set<String> = []
	private var localEnvImportTasks: [LocalEnvImportTarget: Task<ImportedEnvFile, Error>] = [:]
	private var localEnvImportRequests: [LocalEnvImportTarget: UUID] = [:]
	private var localEnvCreationRequests: [LocalEnvImportTarget: UUID] = [:]
	private var localEnvPreviewTasks: [UUID: Task<ImportedEnvFile, Error>] = [:]
	private let localEnvImportAuthority = LocalEnvImportAuthority()
	private let autoLockDuration: TimeInterval

	/// Retains one connection pool for each exact API base URL. Production and
	/// the debug-only local server can never share a session.
	private func apiService(for environment: AppEnvironment) -> any LPMAPIServiceProtocol {
		if let injectedAPIService { return injectedAPIService }
		let baseURL = environment.baseURL
		if let retained = retainedAPIServices[baseURL] { return retained }
		let service = apiServiceFactory(baseURL)
		retainedAPIServices[baseURL] = service
		return service
	}

	// MARK: - Computed

	var selectedProject: VaultProject? {
		guard let id = selectedProjectId else { return nil }
		// Account membership is a security boundary for sync routing. Never
		// return a project that belongs to a different account context.
		return activeVaults.first { $0.id == id }
	}

	var isLoggedIn: Bool { currentUser != nil }

	var userOrgs: [LPMOrg] { currentUser?.orgs ?? [] }

	var expiringTokens: [LPMToken] {
		let allTokens = personalTokens + orgTokens.values.flatMap { $0 }
		return allTokens.filter { token in
			guard let days = token.daysUntilExpiry else { return false }
			return days >= 0 && days <= 7
		}
	}

	/// Vaults for the currently selected account context.
	var activeVaults: [VaultProject] {
		switch selectedAccount {
		case .personal:
			projects.filter { vaultOrgAssociations[$0.id] == nil }
		case .org(let slug):
			projects.filter { vaultOrgAssociations[$0.id] == slug }
		}
	}

	/// Filtered vaults for search.
	var filteredVaults: [VaultProject] {
		guard !searchQuery.isEmpty else { return activeVaults }
		let query = searchQuery.lowercased()
		return activeVaults.filter { project in
			project.name.lowercased().contains(query)
				|| project.secrets.keys.contains { $0.lowercased().contains(query) }
		}
	}

	// MARK: - Navigation

	/// Selects an account as one user action. Switching accounts clears the
	/// incompatible project; reselecting the current account leaves it intact.
	func selectAccount(_ account: SelectedAccount) {
		let resolvedAccount = validatedAccount(account)
		if selectedAccount != resolvedAccount {
			selectedProjectId = nil
			selectedEnvironment = "default"
			searchQuery = ""
			selectedAccount = resolvedAccount
		} else {
			reconcileNavigationState()
		}
		showAuthStatus = false
		resetAutoLock()
	}

	/// Selects only a project visible in the current account and repairs the
	/// shared environment selection for the persistent detail column.
	func selectProject(_ projectId: String?) {
		guard let projectId else {
			selectedProjectId = nil
			selectedEnvironment = "default"
			resetAutoLock()
			return
		}
		guard activeVaults.contains(where: { $0.id == projectId }) else {
			reconcileNavigationState()
			return
		}
		selectedProjectId = projectId
		normalizeSelectedEnvironment()
		resetAutoLock()
	}

	func selectEnvironment(_ environment: String) {
		guard let selectedProject,
			selectedProject.environments.keys.contains(environment)
		else { return }
		selectedEnvironment = environment
		resetAutoLock()
	}

	/// Routes menu-bar and other global navigation to the project's owning
	/// account before selecting it, and always leaves Settings.
	func openProject(id projectId: String) {
		guard projects.contains(where: { $0.id == projectId }) else {
			reconcileNavigationState()
			return
		}
		let account: SelectedAccount
		if let orgSlug = vaultOrgAssociations[projectId] {
			guard userOrgs.contains(where: { $0.slug == orgSlug }) else {
				selectedProjectId = nil
				selectedAccount = .personal
				showAuthStatus = false
				resetAutoLock()
				return
			}
			account = .org(orgSlug)
		} else {
			account = .personal
		}
		if selectedAccount != account {
			selectedProjectId = nil
			selectedAccount = account
		}
		showAuthStatus = false
		selectedProjectId = projectId
		normalizeSelectedEnvironment()
		resetAutoLock()
	}

	func showSettings() {
		showAuthStatus = true
		resetAutoLock()
	}

	/// Repairs restored/background state without extending the auto-lock timer.
	func reconcileNavigationState() {
		let account = validatedAccount(selectedAccount)
		if selectedAccount != account {
			selectedProjectId = nil
			selectedEnvironment = "default"
			selectedAccount = account
		}
		guard let selectedProjectId,
			activeVaults.contains(where: { $0.id == selectedProjectId })
		else {
			self.selectedProjectId = nil
			selectedEnvironment = "default"
			return
		}
		normalizeSelectedEnvironment()
	}

	private func validatedAccount(_ account: SelectedAccount) -> SelectedAccount {
		guard case .org(let slug) = account else { return .personal }
		return userOrgs.contains(where: { $0.slug == slug }) ? account : .personal
	}

	private func normalizeSelectedEnvironment() {
		guard let selectedProject else {
			selectedEnvironment = "default"
			return
		}
		let names = orderedEnvironmentNames(for: selectedProject)
		if !names.contains(selectedEnvironment) {
			selectedEnvironment = names.first ?? "default"
		}
	}

	// MARK: - Init

	init(
		keychainService: KeychainServiceProtocol = KeychainService(),
		biometricService: BiometricServiceProtocol = BiometricService(),
		apiService: LPMAPIServiceProtocol? = nil,
		apiServiceFactory: @escaping @Sendable (URL) -> any LPMAPIServiceProtocol = {
			LPMAPIService(baseURL: $0)
		},
		importServiceFactory: @escaping @Sendable (URL) -> any EnvProjectImportServiceProtocol = {
			EnvProjectImportService(baseURL: $0)
		},
		orgSyncServiceFactory: @escaping @Sendable (URL) -> any OrgSyncServiceProtocol = {
			SyncService(baseURL: $0)
		},
		personalSyncServiceFactory: @escaping @Sendable (URL) -> any PersonalSyncServiceProtocol = {
			SyncService(baseURL: $0)
		},
		envFileImportService: any EnvFileImportServiceProtocol = EnvFileImportService.shared,
		sharingKeypairProvider: @escaping @Sendable () -> (privateKey: Data, publicKey: Data) = {
			VaultCrypto.getOrCreateX25519Keypair()
		},
		authTokenProvider: @escaping @Sendable (String, URL) async -> String? = { registryURL, baseURL in
			await AuthSessionStore.currentAccessToken(registryURL: registryURL, baseURL: baseURL)
		},
		loginProvider: @escaping @Sendable (String, URL) async throws -> AuthSessionCredentials = {
			try await LoginService.login(registryURL: $0, baseURL: $1)
		},
		authSessionWriter: @escaping @Sendable (AuthSessionCredentials, String) throws -> Void = {
			try LoginService.writeAuthSession($0, registryURL: $1)
		},
		authSessionClearer: @escaping @Sendable (String) -> Void = {
			LoginService.clearAuthSession(registryURL: $0)
		},
		autoLockSleep: @escaping @Sendable (Duration) async throws -> Void = {
			try await Task.sleep(for: $0)
		},
		autoLockNow: @escaping @Sendable () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		autoLockDuration: TimeInterval = VaultConstants.vaultAutoLockDuration
	) {
		self.keychainService = keychainService
		self.persistence = VaultPersistenceCoordinator(service: keychainService)
		self.biometricService = biometricService
		self.injectedAPIService = apiService
		self.apiServiceFactory = apiServiceFactory
		self.importServiceFactory = importServiceFactory
		self.orgSyncServiceFactory = orgSyncServiceFactory
		self.personalSyncServiceFactory = personalSyncServiceFactory
		self.envFileImportService = envFileImportService
		self.sharingKeypairProvider = sharingKeypairProvider
		self.authTokenProvider = authTokenProvider
		self.loginProvider = loginProvider
		self.authSessionWriter = authSessionWriter
		self.authSessionClearer = authSessionClearer
		self.autoLockSleep = autoLockSleep
		self.autoLockNow = autoLockNow
		self.autoLockDuration = autoLockDuration

		#if DEBUG
		// Local-server selection is a debug-only developer convenience.
		if let saved = UserDefaults.standard.string(forKey: "lpm-vault-environment"),
		   let env = AppEnvironment(rawValue: saved) {
			self.appEnvironment = env
		}
		#endif

	}

	#if DEBUG
	/// Switch between the production server and the local development server.
	/// Clears current session and reloads tokens for the new environment.
	func switchEnvironment(to env: AppEnvironment) {
		guard env != appEnvironment else { return }
		authOperationGeneration &+= 1
		isLoggingIn = false
		invalidateTokenLoad()
		invalidatePendingOrgPush()
		appEnvironment = env
		UserDefaults.standard.set(env.rawValue, forKey: "lpm-vault-environment")
		// Reset auth state for new environment
		currentUser = nil
		personalTokens = []
		orgTokens = [:]
		// Reload tokens from the new environment's keychain entry
		Task { await loadTokens() }
	}
	#endif

	// MARK: - Load

	/// Load a coherent Keychain snapshot. A newer load, lock, or mutation
	/// invalidates this generation before it can publish decrypted state.
	@discardableResult
	func loadProjects() async -> Bool {
		projectLoadGeneration &+= 1
		let generation = projectLoadGeneration
		projectLoadTask?.cancel()
		isLoadingProjects = true

		let task = Task { [weak self, persistence] in
			let snapshot = await persistence.loadSnapshot()
			guard !Task.isCancelled, let self,
				generation == self.projectLoadGeneration
			else { return }
			self.projects = snapshot.projects
			self.syncMetadata = snapshot.syncMetadata
			self.vaultOrgAssociations = snapshot.orgAssociations
			self.error = nil
			self.loadEnvironmentOrders()
			self.reconcileNavigationState()
			self.isLoadingProjects = false
			self.projectLoadTask = nil
		}
		projectLoadTask = task
		await task.value
		return generation == projectLoadGeneration && !isLoadingProjects
	}

	// MARK: - Transactional Cloud Imports

	func importCloudProject(
		_ remote: SyncService.RemoteProject
	) async -> Result<ImportedEnvProject, EnvProjectImportError> {
		await importRemoteProject(remote, orgSlug: nil)
	}

	func importOrganizationProject(
		_ remote: SyncService.RemoteProject,
		orgSlug: String
	) async -> Result<ImportedEnvProject, EnvProjectImportError> {
		guard EnvValidation.isSafeOrgSlug(orgSlug) else {
			return .failure(.invalidPayload("The organization identifier is invalid."))
		}
		return await importRemoteProject(remote, orgSlug: orgSlug)
	}

	private func importRemoteProject(
		_ remote: SyncService.RemoteProject,
		orgSlug: String?
	) async -> Result<ImportedEnvProject, EnvProjectImportError> {
		let sessionGeneration = vaultSessionGeneration
		let environment = appEnvironment
		let baseURL = environment.baseURL
		guard EnvValidation.isSafeVaultId(remote.vaultId) else {
			return .failure(.invalidPayload("The server returned an unsafe env project identifier."))
		}
		guard !projects.contains(where: { $0.id == remote.vaultId }),
			activeImportIds.insert(remote.vaultId).inserted
		else { return .failure(.duplicate) }
		defer { activeImportIds.remove(remote.vaultId) }

		guard !(await persistence.containsProject(vaultId: remote.vaultId)) else {
			return .failure(.duplicate)
		}
		guard let authToken = await authTokenProvider(environment.registryURL, baseURL) else {
			return .failure(.notAuthenticated)
		}
		guard sessionGeneration == vaultSessionGeneration, environment == appEnvironment else {
			return .failure(.cancelled)
		}

		do {
			let service = importServiceFactory(baseURL)
			let payload: RemoteEnvProjectPayload
			if let orgSlug {
				payload = try await service.loadOrganization(
					authToken: authToken,
					orgSlug: orgSlug,
					vaultId: remote.vaultId
				)
			} else {
				payload = try await service.loadPersonal(
					authToken: authToken,
					vaultId: remote.vaultId
				)
			}
			try Task.checkCancellation()

			let project = VaultProject(
				id: remote.vaultId,
				name: importProjectName(remote.name, vaultId: remote.vaultId, isOrganization: orgSlug != nil),
				path: "",
				environments: payload.environments
			)
			guard EnvValidation.areValidEnvironments(project.environments) else {
				return .failure(.invalidPayload("The env project contains invalid environment or variable names."))
			}

			// Any older project snapshot must not overwrite this commit afterward.
			guard sessionGeneration == vaultSessionGeneration,
				environment == appEnvironment
			else { return .failure(.cancelled) }
			invalidateProjectLoad()
			try Task.checkCancellation()
			let commit = await persistence.importProject(
				project,
				orgSlug: orgSlug,
				version: payload.version
			)

			switch commit {
			case .success(let committed):
				if Task.isCancelled {
					return .failure(.cancelled)
				}
				// A lock that raced the non-cancellable commit must not put
				// decrypted values back into memory. Unlock will reload them.
				guard sessionGeneration == vaultSessionGeneration else {
					return .success(ImportedEnvProject(
						projectId: project.id,
						version: payload.version,
						keyCount: payload.keyCount
					))
				}
				projects.append(project)
				projects.sort {
					$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
				}
				syncMetadata = committed.syncMetadata
				vaultOrgAssociations = committed.orgAssociations
				openProject(id: project.id)
				error = committed.warning
				return .success(ImportedEnvProject(
					projectId: project.id,
					version: payload.version,
					keyCount: payload.keyCount
				))
			case .duplicate:
				return .failure(.duplicate)
			case .failure(let persistenceError):
				if case .unexpectedStatus(-2) = persistenceError {
					if sessionGeneration == vaultSessionGeneration, isUnlocked {
						_ = await loadProjects()
					}
					return .failure(.persistence(
						isUnlocked
							? "The import could not be rolled back completely. Local state was reloaded from Keychain."
							: "The import could not be rolled back completely. Unlock to reload local state from Keychain."
					))
				}
				return .failure(.persistence(persistenceError.description))
			}
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch let importError as EnvProjectImportError {
			return .failure(importError)
		} catch {
			return .failure(.invalidPayload(error.localizedDescription))
		}
	}

	private func importProjectName(
		_ name: String?,
		vaultId: String,
		isOrganization: Bool
	) -> String {
		let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
		let prefix = isOrganization ? "org-env" : "env"
		return "\(prefix)-\(vaultId.prefix(8))"
	}

	// MARK: - Project Operations

	/// Currently selected environment tab name
	var selectedEnvironment: String = "default" {
		didSet {
			if oldValue != selectedEnvironment, let selectedProjectId {
				cancelLocalEnvImport(projectId: selectedProjectId, environment: oldValue)
			}
		}
	}

	/// Create a new vault with just a name (no folder needed).
	/// If orgSlug is provided, immediately shares with that org.
	func createVault(name: String, orgSlug: String? = nil) {
		let vaultId = UUID().uuidString.lowercased()
		let environments: [String: [String: String]] = ["default": [:]]

		Task { [weak self] in
			guard let self,
				await addProjectWithVaultId(
					vaultId: vaultId,
					name: name,
					path: "",
					environments: environments
				)
			else { return }

			if let slug = orgSlug {
				guard await associateVaultWithOrg(vaultId: vaultId, orgSlug: slug) else { return }
				openProject(id: vaultId)
				await pushToOrg(orgSlug: slug)
			}
		}
	}

	/// Associate a vault with an org (for column 2 filtering).
	@discardableResult
	func associateVaultWithOrg(vaultId: String, orgSlug: String) async -> Bool {
		guard let associations = await persistence.associate(vaultId: vaultId, orgSlug: orgSlug) else {
			error = "Could not save the organization association."
			return false
		}
		vaultOrgAssociations = associations
		reconcileNavigationState()
		return true
	}

	/// Add a project with a specific vault ID (for re-adding existing vaults).
	/// Returns only after the Keychain write and in-memory selection are complete.
	@discardableResult
	func addProjectWithVaultId(
		vaultId: String,
		name: String,
		path: String,
		environments: [String: [String: String]]
	) async -> Bool {
		invalidateProjectLoad()
		guard EnvValidation.isSafeVaultId(vaultId) else {
			error = "The env project identifier is invalid."
			return false
		}
		guard EnvValidation.areValidEnvironments(environments) else {
			error = "Environment names or variable names do not match the LPM env format."
			return false
		}
		let project = VaultProject(id: vaultId, name: name, path: path, environments: environments)

		// Run Keychain write off main thread to prevent UI freeze
		let result = await persistence.save(project)
		switch result {
		case .success, .successWithWarning:
			projects.append(project)
			projects.sort {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
			openProject(id: vaultId)
			writeLpmJson(vaultId: vaultId, projectPath: path)
			return true
		case .failure(let err):
			error = err.description
			return false
		}
	}

	func addProject(name: String, path: String, environments: [String: [String: String]]? = nil) {
		invalidateProjectLoad()
		let envs = environments ?? ["default": [:]]
		guard EnvValidation.areValidEnvironments(envs) else {
			error = "Environment names or variable names do not match the LPM env format."
			return
		}
		let existingVaultId = readVaultIdFromLpmJson(projectPath: path)
		if let existingVaultId, !EnvValidation.isSafeVaultId(existingVaultId) {
			error = "The lpm.json env project identifier is invalid."
			return
		}

		// Run all Keychain operations off main thread
		let saveTask = Task { [persistence] in
			let vaultId = existingVaultId ?? UUID().uuidString.lowercased()
			return await persistence.save(
				vaultId: vaultId,
				name: name,
				path: path,
				environments: envs,
				mergeExisting: existingVaultId != nil
			)
		}
		Task { [weak self] in
			let (project, result) = await saveTask.value
			guard let self else { return }
			switch result {
				case .success, .successWithWarning:
					projects.append(project)
					projects.sort {
						$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
					}
					openProject(id: project.id)
					writeLpmJson(vaultId: project.id, projectPath: path)
				case .failure(let err):
					error = err.description
				}
		}
	}

	func renameProject(_ project: VaultProject, to name: String) {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.count <= 120,
			var updated = projects.first(where: { $0.id == project.id })
		else { return }
		updated.name = trimmed
		saveAndUpdate(updated)
	}

	// MARK: - lpm.json Integration

	/// Read vault ID from lpm.json in the project directory.
	private func readVaultIdFromLpmJson(projectPath: String) -> String? {
		let url = URL(fileURLWithPath: projectPath).appendingPathComponent("lpm.json")
		guard let data = try? Data(contentsOf: url),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let vaultId = json["vault"] as? String else {
			return nil
		}
		return vaultId
	}

	/// Write or update vault ID in lpm.json.
	/// Preserves existing keys (runtime, env, tasks, tools, services).
	private func writeLpmJson(vaultId: String, projectPath: String) {
		guard !projectPath.isEmpty else { return }
		let url = URL(fileURLWithPath: projectPath).appendingPathComponent("lpm.json")

		var json: [String: Any] = [:]

		// Read existing lpm.json if present
		if let data = try? Data(contentsOf: url),
		   let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			json = existing
		}

		// Only write if vault ID is different or missing
		if json["vault"] as? String == vaultId { return }

		json["vault"] = vaultId

		if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
			try? data.write(to: url)
		}
	}

	/// Remove from sidebar only — Keychain data stays.
	/// Re-adding the same folder will restore the project.
	func removeFromSidebar(_ project: VaultProject) {
		cancelLocalEnvImports(projectId: project.id)
		invalidateProjectLoad()
		// Update UI immediately
		projects.removeAll { $0.id == project.id }
		if selectedProjectId == project.id {
			selectedProjectId = activeVaults.first?.id
			normalizeSelectedEnvironment()
		}
		// Keychain update off main thread
		Task { [persistence] in
			await persistence.removeFromSidebar(vaultId: project.id)
		}
	}

	/// Delete local vault data (Keychain) but keep cloud copy.
	/// Can be recovered via `lpm env pull`.
	@discardableResult
	func deleteLocalVault(_ project: VaultProject) async -> Bool {
		cancelLocalEnvImports(projectId: project.id)
		invalidateProjectLoad()
		let sessionGeneration = vaultSessionGeneration
		let wasSelected = selectedProjectId == project.id
		guard let snapshot = await persistence.deleteProjectAndMetadata(vaultId: project.id) else {
			error = "Could not delete the local Keychain copy. The env project was kept."
			return false
		}

		environmentOrders.removeValue(forKey: project.id)
		UserDefaults.standard.removeObject(forKey: Self.envOrderPrefix + project.id)
		// Durable deletion remains successful if locking won the race. Unlocking
		// will load the new snapshot; never republish its plaintext while locked.
		guard sessionGeneration == vaultSessionGeneration, isUnlocked else { return true }
		projects = snapshot.projects
		syncMetadata = snapshot.syncMetadata
		vaultOrgAssociations = snapshot.orgAssociations
		if wasSelected {
			selectedProjectId = activeVaults.first?.id
		}
		reconcileNavigationState()
		return true
	}

	/// Legacy alias — defaults to remove from sidebar (safe).
	func deleteProject(_ project: VaultProject) {
		removeFromSidebar(project)
	}

	// MARK: - Environment Operations

	/// Adds a new environment after persistence succeeds. The async boundary
	/// keeps a rejected Keychain write from appearing as a successful import.
	@discardableResult
	func addEnvironment(
		to projectId: String,
		name: String,
		secrets: [String: String] = [:]
	) async -> Bool {
		guard isUnlocked else {
			error = EnvFileImportError.vaultLocked.localizedDescription
			return false
		}
		let sessionGeneration = vaultSessionGeneration
		guard selectedProjectId == projectId,
			var project = projects.first(where: { $0.id == projectId })
		else { return false }
		let target = LocalEnvImportTarget(projectId: projectId, environment: name)
		let requestId = UUID()
		localEnvCreationRequests[target] = requestId
		localEnvImportAuthority.begin(target, requestId: requestId)
		defer {
			if localEnvCreationRequests[target] == requestId {
				localEnvCreationRequests.removeValue(forKey: target)
			}
			localEnvImportAuthority.complete(target, requestId: requestId)
		}
		guard EnvValidation.isValidEnvironmentName(name),
			secrets.keys.allSatisfy(EnvValidation.isValidVariableName)
		else { return false }
		guard project.environments[name] == nil else { return false }
		project.environments[name] = secrets
		guard let encodedSize = EnvValidation.encodedVaultSize(project.environments) else {
			error = KeychainError.encodingFailed.description
			return false
		}
		guard encodedSize <= VaultConstants.maxVaultSizeWarning else {
			error = KeychainError.dataTooLarge(encodedSize).description
			return false
		}
		invalidateProjectLoad()
		let commit = await withTaskCancellationHandler {
			await persistence.addEnvironment(
				projectId: projectId,
				projectName: project.name,
				projectPath: project.path,
				environment: name,
				secrets: secrets,
				requestId: requestId,
				authority: localEnvImportAuthority
			)
		} onCancel: { [localEnvImportAuthority] in
			localEnvImportAuthority.cancel(target, requestId: requestId)
		}
		guard case .success(let persisted) = commit else {
			switch commit {
			case .failure(let persistenceError):
				error = persistenceError.description
			case .targetUnavailable:
				error = EnvFileImportError.targetUnavailable.localizedDescription
			case .caseInsensitiveCollision:
				error = EnvFileImportError.caseInsensitiveCollisionWithExisting.localizedDescription
			case .cancelled:
				return false
			case .success:
				break
			}
			return false
		}
		guard localEnvCreationRequests[target] == requestId,
			sessionGeneration == vaultSessionGeneration, isUnlocked,
			selectedProjectId == projectId,
			!Task.isCancelled,
			projects.contains(where: { $0.id == projectId }),
			projects.first(where: { $0.id == projectId })?.environments[name] == nil
		else {
			// Persistence is intentionally non-cancellable. Report its durable
			// success without republishing plaintext into stale or locked UI.
			return true
		}
		updateProjectInPlace(persisted.project)
		syncMetadata = persisted.syncMetadata
		error = persisted.warning
		// Append new env to the stored order
		var order = orderedEnvironmentNames(for: persisted.project)
		order.append(name)
		saveEnvironmentOrder(for: projectId, order: order)
		selectedEnvironment = name
		return true
	}

	/// Delete an environment tab from a project. Cannot delete the last environment.
	func deleteEnvironment(from projectId: String, name: String) {
		cancelLocalEnvImport(projectId: projectId, environment: name)
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard project.environments.count > 1 else { return }
		project.environments.removeValue(forKey: name)
		saveAndUpdate(project)
		// Remove from stored order
		var order = orderedEnvironmentNames(for: project)
		order.removeAll { $0 == name }
		saveEnvironmentOrder(for: projectId, order: order)
		if selectedEnvironment == name {
			selectedEnvironment = project.environments.keys.sorted().first ?? "default"
		}
	}

	/// Duplicate an environment's secrets to a new tab.
	func duplicateEnvironment(in projectId: String, from source: String, to newName: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard EnvValidation.isValidEnvironmentName(newName) else { return }
		guard project.environments[newName] == nil else { return }
		guard let sourceSecrets = project.environments[source] else { return }
		project.environments[newName] = sourceSecrets
		saveAndUpdate(project)
		var order = orderedEnvironmentNames(for: project)
		if let sourceIdx = order.firstIndex(of: source) {
			order.insert(newName, at: sourceIdx + 1)
		} else {
			order.append(newName)
		}
		saveEnvironmentOrder(for: projectId, order: order)
		selectedEnvironment = newName
	}

	/// Rename an environment tab.
	func renameEnvironment(in projectId: String, from oldName: String, to newName: String) {
		cancelLocalEnvImport(projectId: projectId, environment: oldName)
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard EnvValidation.isValidEnvironmentName(newName) else { return }
		guard project.environments[newName] == nil else { return }
		guard let secrets = project.environments[oldName] else { return }
		project.environments.removeValue(forKey: oldName)
		project.environments[newName] = secrets
		saveAndUpdate(project)
		// Update stored order
		var order = orderedEnvironmentNames(for: project)
		if let idx = order.firstIndex(of: oldName) {
			order[idx] = newName
		}
		saveEnvironmentOrder(for: projectId, order: order)
		if selectedEnvironment == oldName {
			selectedEnvironment = newName
		}
	}

	/// Clear all secrets from an environment (keeps the tab).
	func clearEnvironment(in projectId: String, name: String) {
		cancelLocalEnvImport(projectId: projectId, environment: name)
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		project.environments[name] = [:]
		saveAndUpdate(project)
	}

	// MARK: - Secret Operations (environment-aware)

	// MARK: - Bounded Local Dotenv Imports

	/// Reads and parses off the main actor, then persists the exact captured
	/// destination before publishing. A newer import to the same destination
	/// cancels and supersedes the older request.
	func importEnvFile(
		at url: URL,
		to projectId: String,
		environment: String
	) async -> Result<ImportedEnvFile, EnvFileImportError> {
		guard isUnlocked else { return .failure(.vaultLocked) }
		guard selectedProjectId == projectId, selectedEnvironment == environment,
			let project = projects.first(where: { $0.id == projectId }),
			project.environments[environment] != nil
		else { return .failure(.targetUnavailable) }

		let target = LocalEnvImportTarget(projectId: projectId, environment: environment)
		let requestId = UUID()
		let sessionGeneration = vaultSessionGeneration
		localEnvImportTasks[target]?.cancel()
		localEnvImportRequests[target] = requestId
		localEnvImportAuthority.begin(target, requestId: requestId)

		let task = Task { [envFileImportService] in
			try await envFileImportService.load(at: url)
		}
		localEnvImportTasks[target] = task
		defer {
			if localEnvImportRequests[target] == requestId {
				localEnvImportTasks.removeValue(forKey: target)
				localEnvImportRequests.removeValue(forKey: target)
			}
			localEnvImportAuthority.complete(target, requestId: requestId)
		}

		do {
			let imported = try await withTaskCancellationHandler {
				try await task.value
			} onCancel: {
				task.cancel()
			}
			try Task.checkCancellation()
			guard localEnvImportRequests[target] == requestId,
				sessionGeneration == vaultSessionGeneration,
				isUnlocked,
				selectedProjectId == projectId,
				selectedEnvironment == environment,
				let currentProject = projects.first(where: { $0.id == projectId }),
				currentProject.environments[environment] != nil
			else { return .failure(.cancelled) }

			invalidateProjectLoad()
			let commit = await withTaskCancellationHandler {
				await persistence.importSecrets(
					projectId: projectId,
					projectName: currentProject.name,
					projectPath: currentProject.path,
					environment: environment,
					secrets: imported.secrets,
					requestId: requestId,
					authority: localEnvImportAuthority
				)
			} onCancel: { [localEnvImportAuthority] in
				localEnvImportAuthority.cancel(target, requestId: requestId)
			}

			switch commit {
			case .success(let persisted):
				guard localEnvImportRequests[target] == requestId,
					sessionGeneration == vaultSessionGeneration,
					isUnlocked,
					selectedProjectId == projectId,
					selectedEnvironment == environment,
					projects.contains(where: { $0.id == projectId })
				else {
					// The transaction crossed its synchronous commit point. Keep
					// locked/stale UI clear, but report the durable success.
					return .success(imported)
				}
				updateProjectInPlace(persisted.project)
				syncMetadata = persisted.syncMetadata
				error = persisted.warning
				return .success(imported)
			case .targetUnavailable:
				return .failure(.targetUnavailable)
			case .caseInsensitiveCollision:
				return .failure(.caseInsensitiveCollisionWithExisting)
			case .cancelled:
				return .failure(.cancelled)
			case .failure(let persistenceError):
				if case .unexpectedStatus(-2) = persistenceError {
					if sessionGeneration == vaultSessionGeneration, isUnlocked,
						selectedProjectId == projectId,
						selectedEnvironment == environment
					{
						_ = await loadProjects()
					}
				}
				return .failure(.persistence(persistenceError.description))
			}
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch let importError as EnvFileImportError {
			return .failure(importError)
		} catch {
			return .failure(.readFailed)
		}
	}

	func loadEnvFilePreview(
		at url: URL,
		for projectId: String
	) async -> Result<ImportedEnvFile, EnvFileImportError> {
		guard isUnlocked else { return .failure(.vaultLocked) }
		guard selectedProjectId == projectId,
			projects.contains(where: { $0.id == projectId })
		else { return .failure(.targetUnavailable) }
		let requestId = UUID()
		let sessionGeneration = vaultSessionGeneration
		let task = Task { [envFileImportService] in
			let imported = try await envFileImportService.load(at: url)
			try Task.checkCancellation()
			return imported
		}
		localEnvPreviewTasks[requestId] = task
		defer { localEnvPreviewTasks.removeValue(forKey: requestId) }
		do {
			let imported = try await withTaskCancellationHandler {
				try await task.value
			} onCancel: {
				task.cancel()
			}
			guard sessionGeneration == vaultSessionGeneration, isUnlocked,
				selectedProjectId == projectId,
				projects.contains(where: { $0.id == projectId })
			else {
				return .failure(.cancelled)
			}
			return .success(imported)
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch let importError as EnvFileImportError {
			return .failure(importError)
		} catch {
			return .failure(.readFailed)
		}
	}

	private func cancelLocalEnvImport(projectId: String, environment: String) {
		let target = LocalEnvImportTarget(projectId: projectId, environment: environment)
		localEnvImportTasks.removeValue(forKey: target)?.cancel()
		localEnvImportRequests.removeValue(forKey: target)
		localEnvCreationRequests.removeValue(forKey: target)
		localEnvImportAuthority.cancel(target)
	}

	private func cancelLocalEnvImports(projectId: String? = nil) {
		let targets = Set(localEnvImportTasks.keys)
			.union(localEnvImportRequests.keys)
			.union(localEnvCreationRequests.keys)
			.filter { projectId == nil || $0.projectId == projectId }
		for target in targets {
			localEnvImportTasks.removeValue(forKey: target)?.cancel()
			localEnvImportRequests.removeValue(forKey: target)
			localEnvCreationRequests.removeValue(forKey: target)
			localEnvImportAuthority.cancel(target)
		}
	}

	private func cancelLocalEnvPreviews() {
		for task in localEnvPreviewTasks.values { task.cancel() }
		localEnvPreviewTasks.removeAll()
	}

	func addSecret(
		to projectId: String,
		environment: String,
		key: String,
		value: String
	) async -> AddSecretResult {
		guard isUnlocked else { return .failure(.vaultLocked) }
		guard EnvValidation.isValidVariableName(key) else { return .failure(.invalidName) }
		let sessionGeneration = vaultSessionGeneration
		guard let project = projects.first(where: { $0.id == projectId }),
			let secrets = project.environments[environment]
		else { return .failure(.targetUnavailable) }
		guard secrets[key] == nil else { return .failure(.duplicate) }
		if let existingKey = EnvValidation.caseInsensitiveCollision(for: key, in: secrets.keys) {
			return .failure(.caseInsensitiveCollision(existingKey: existingKey))
		}

		invalidateProjectLoad()
		let commit = await persistence.addSecret(
			projectId: projectId,
			projectName: project.name,
			projectPath: project.path,
			environment: environment,
			key: key,
			value: value
		)
		switch commit {
		case .success(let persisted):
			guard sessionGeneration == vaultSessionGeneration, isUnlocked else {
				// Durable success raced a lock. Do not republish plaintext until unlock.
				return .success
			}
			updateProjectInPlace(persisted.project)
			syncMetadata = persisted.syncMetadata
			error = persisted.warning
			return .success
		case .targetUnavailable:
			return .failure(.targetUnavailable)
		case .failure(let persistenceError):
			if case .unexpectedStatus(-2) = persistenceError,
				sessionGeneration == vaultSessionGeneration, isUnlocked
			{
				_ = await loadProjects()
			}
			return .failure(.persistence(persistenceError.description))
		}
	}

	func updateSecret(in projectId: String, key: String, newValue: String) {
		updateSecret(
			in: projectId,
			environment: selectedEnvironment,
			key: key,
			newValue: newValue
		)
	}

	func updateSecret(in projectId: String, environment: String, key: String, newValue: String) {
		guard isUnlocked,
			selectedProjectId == projectId,
			var project = selectedProject
		else { return }
		guard project.environments[environment]?[key] != nil else { return }

		project.environments[environment]?[key] = newValue
		saveAndUpdate(project)
	}

	func deleteSecret(from projectId: String, key: String) {
		deleteSecret(from: projectId, environment: selectedEnvironment, key: key)
	}

	func deleteSecret(from projectId: String, environment: String, key: String) {
		guard isUnlocked,
			selectedProjectId == projectId,
			var project = selectedProject,
			project.environments[environment]?[key] != nil
		else { return }

		project.environments[environment]?.removeValue(forKey: key)
		saveAndUpdate(project)
	}

	// MARK: - Token Operations

	func loadTokens() async {
		tokenLoadGeneration &+= 1
		let generation = tokenLoadGeneration
		let environment = appEnvironment
		let service = apiService(for: environment)
		tokenLoadTask?.cancel()
		isLoadingTokens = true

		let task = Task { [weak self] in
			guard let self else { return }
			guard let authToken = await self.authTokenProvider(
				environment.registryURL,
				environment.baseURL
			) else {
				guard !Task.isCancelled,
					generation == self.tokenLoadGeneration,
					environment == self.appEnvironment
				else { return }
				self.currentUser = nil
				self.personalTokens = []
				self.orgTokens = [:]
				self.error = nil
				self.isLoadingTokens = false
				self.tokenLoadTask = nil
				return
			}
			guard !Task.isCancelled else { return }

			let userResult = await service.fetchCurrentUser(authToken: authToken)
			let inventoryResult: LPMAPIResult<TokenInventory>
			switch userResult {
			case .success(let user):
				inventoryResult = await TokenInventoryLoader.load(
					user: user, authToken: authToken, service: service)
			case .failure(let loadError):
				inventoryResult = .failure(loadError)
			}

			guard !Task.isCancelled,
				generation == self.tokenLoadGeneration,
				environment == self.appEnvironment
			else { return }
			let currentAuthToken = await self.authTokenProvider(
				environment.registryURL,
				environment.baseURL
			)
			guard !Task.isCancelled,
				generation == self.tokenLoadGeneration,
				environment == self.appEnvironment
			else { return }
			guard currentAuthToken == authToken else {
				self.error = "The active lpm.dev session changed while tokens were loading. Reload to use the new session."
				self.isLoadingTokens = false
				self.tokenLoadTask = nil
				return
			}

			switch inventoryResult {
			case .success(let inventory):
				self.currentUser = inventory.user
				self.personalTokens = inventory.personalTokens
				self.orgTokens = inventory.organizationTokens
				self.error = nil
			case .failure(.cancelled):
				break
			case .failure(let loadError):
				// Keep the prior coherent inventory visible on transient or
				// per-organization failure; never publish a partial snapshot.
				self.error = loadError.localizedDescription
			}
			self.isLoadingTokens = false
			self.tokenLoadTask = nil
		}
		tokenLoadTask = task
		await task.value
	}

	func revokePersonalToken(_ token: LPMToken) async {
		let generation = authOperationGeneration
		let environment = appEnvironment
		guard let authToken = await authTokenProvider(environment.registryURL, environment.baseURL) else {
			error = "Sign in to lpm.dev, then retry."
			return
		}
		let result = await apiService(for: environment).revokePersonalToken(
			id: token.id,
			authToken: authToken
		)
		guard generation == authOperationGeneration, environment == appEnvironment else { return }
		guard await authTokenProvider(environment.registryURL, environment.baseURL) == authToken,
			generation == authOperationGeneration,
			environment == appEnvironment
		else {
			error = "The active lpm.dev session changed before revocation completed. Reload and retry."
			return
		}
		switch result {
		case .success:
			// A load that started before the revocation may still contain this
			// token. Invalidate it before committing the newer server state.
			invalidateTokenLoad()
			personalTokens.removeAll { $0.id == token.id }
		case .failure(let revokeError):
			error = revokeError.localizedDescription
		}
	}

	func revokeOrgToken(_ token: LPMToken, orgSlug: String) async {
		let generation = authOperationGeneration
		let environment = appEnvironment
		guard let authToken = await authTokenProvider(environment.registryURL, environment.baseURL) else {
			error = "Sign in to lpm.dev, then retry."
			return
		}
		let result = await apiService(for: environment).revokeOrgToken(
			orgSlug: orgSlug,
			id: token.id,
			authToken: authToken
		)
		guard generation == authOperationGeneration, environment == appEnvironment else { return }
		guard await authTokenProvider(environment.registryURL, environment.baseURL) == authToken,
			generation == authOperationGeneration,
			environment == appEnvironment
		else {
			error = "The active lpm.dev session changed before revocation completed. Reload and retry."
			return
		}
		switch result {
		case .success:
			invalidateTokenLoad()
			orgTokens[orgSlug]?.removeAll { $0.id == token.id }
		case .failure(let revokeError):
			error = revokeError.localizedDescription
		}
	}

	// MARK: - Auth (Login / Logout)

	/// Start the browser-based login flow — same UX as `lpm login`.
	/// Validates the token with the server before persisting it to Keychain.
	func login() async {
		authOperationGeneration &+= 1
		let generation = authOperationGeneration
		let environment = appEnvironment
		isLoggingIn = true
		error = nil

		do {
			let credentials = try await loginProvider(environment.registryURL, environment.baseURL)
			guard generation == authOperationGeneration, environment == appEnvironment else { return }

			// Validate the token actually works before storing it
			let user = await apiService(for: environment).fetchCurrentUser(authToken: credentials.token)
			guard generation == authOperationGeneration, environment == appEnvironment else { return }
			guard case .success = user else {
				error = "Login failed — server rejected the token."
				isLoggingIn = false
				return
			}

			// Token is valid — persist to Keychain (shared with CLI)
			try authSessionWriter(credentials, environment.registryURL)

			// Load full user info + tokens
			await loadTokens()

			guard generation == authOperationGeneration, environment == appEnvironment else { return }
			isLoggingIn = false
		} catch {
			guard generation == authOperationGeneration, environment == appEnvironment else { return }
			self.error = error.localizedDescription
			isLoggingIn = false
		}
	}

	/// Sign out — clear token from Keychain and reset state.
	func logout() {
		authOperationGeneration &+= 1
		isLoggingIn = false
		invalidateTokenLoad()
		invalidatePendingOrgPush()
		authSessionClearer(appEnvironment.registryURL)
		currentUser = nil
		personalTokens = []
		orgTokens = [:]
		error = nil
		lastSyncStatus = nil
	}

	// MARK: - Auth (Biometric)

	func unlock() async {
		guard !isUnlocking else { return }
		unlockGeneration &+= 1
		let generation = unlockGeneration
		isUnlocking = true
		let success = await biometricService.authenticate(
			reason: "Unlock LPM Vault to view secrets"
		)
		guard success, generation == unlockGeneration else {
			isUnlocking = false
			return
		}
		// Do not expose the unlocked UI until the latest snapshot is present.
		let loaded = await loadProjects()
		guard loaded, generation == unlockGeneration else {
			isUnlocking = false
			return
		}
		isUnlocked = true
		isUnlocking = false
		scheduleAutoLock()
	}

	func authenticateForSensitiveAction(reason: String) async -> Bool {
		guard isUnlocked else { return false }
		let sessionGeneration = vaultSessionGeneration
		let success = await biometricService.authenticate(reason: reason)
		return !Task.isCancelled
			&& success
			&& isUnlocked
			&& sessionGeneration == vaultSessionGeneration
	}

	func lock() {
		unlockGeneration &+= 1
		vaultSessionGeneration &+= 1
		cancelLocalEnvImports()
		cancelLocalEnvPreviews()
		invalidatePendingOrgPush()
		isUnlocking = false
		invalidateProjectLoad()
		autoLockTask?.cancel()
		autoLockTask = nil
		autoLockDeadline = nil
		autoLockTaskGeneration &+= 1
		isUnlocked = false
		biometricService.resetCache()
		ClipboardManager.shared.clearClipboard()
		// Clear decrypted secrets from memory to reduce exposure window
		for i in projects.indices {
			projects[i].environments = projects[i].environments.mapValues { _ in [:] }
		}
	}

	/// Records local keyboard, click, scroll, or gesture input while unlocked.
	func recordUserActivity() {
		guard isUnlocked else { return }
		scheduleAutoLock()
	}

	/// Navigation actions are user activity too.
	private func resetAutoLock() {
		recordUserActivity()
	}

	private func scheduleAutoLock() {
		let now = autoLockNow()
		if let autoLockDeadline, now >= autoLockDeadline {
			lock()
			return
		}
		autoLockDeadline = now + autoLockDuration
		guard autoLockTask == nil else { return }
		autoLockTaskGeneration &+= 1
		let generation = autoLockTaskGeneration
		autoLockTask = Task { @MainActor [weak self] in
			guard let self else { return }
			do {
				while isUnlocked, generation == autoLockTaskGeneration {
					try Task.checkCancellation()
					guard let autoLockDeadline else { break }
					let remaining = autoLockDeadline - autoLockNow()
					if remaining <= 0 {
						lock()
						return
					}
					try await autoLockSleep(.seconds(remaining))
				}
			} catch {}
			if generation == autoLockTaskGeneration {
				autoLockTask = nil
			}
		}
	}

	private func invalidatePendingOrgPush() {
		syncOperationGeneration &+= 1
		pendingOrgPush = nil
		showKeyApprovalSheet = false
		if lastSyncStatus == "approval_required" { lastSyncStatus = nil }
		isSyncing = false
	}

	private func invalidateProjectLoad() {
		projectLoadGeneration &+= 1
		projectLoadTask?.cancel()
		projectLoadTask = nil
		isLoadingProjects = false
	}

	private func invalidateTokenLoad() {
		tokenLoadGeneration &+= 1
		tokenLoadTask?.cancel()
		tokenLoadTask = nil
		isLoadingTokens = false
	}

	// MARK: - Cloud Sync

	/// Info shown in the push/pull confirmation dialog.
	struct SyncConfirmation {
		let action: String  // "push" or "pull"
		let projectName: String
		let localKeyCount: Int
		let cloudVersion: Int?
	}

	/// Prepare info for push confirmation. Returns nil if no project selected.
	func preparePushConfirmation() -> SyncConfirmation? {
		guard let project = selectedProject else { return nil }
		return SyncConfirmation(
			action: "push",
			projectName: project.name,
			localKeyCount: project.secrets.count,
			cloudVersion: nil
		)
	}

	/// Push the selected project's secrets to cloud.
	/// Pushes ALL environments (default, live, local, etc.), not just the selected one.
	func pushToCloud(force: Bool = false) async {
		guard isUnlocked, selectedAccount == .personal, let project = selectedProject else { return }
		syncOperationGeneration &+= 1
		let operationGeneration = syncOperationGeneration
		let sessionGeneration = vaultSessionGeneration
		let environment = appEnvironment
		let authGeneration = authOperationGeneration
		guard let authToken = await authTokenProvider(environment.registryURL, environment.baseURL) else {
			guard operationGeneration == syncOperationGeneration,
				environment == appEnvironment,
				authGeneration == authOperationGeneration,
				sessionGeneration == vaultSessionGeneration,
				isUnlocked,
				selectedAccount == .personal,
				selectedProject?.id == project.id
			else { return }
			error = "Not logged in. Run `lpm login` in terminal first."
			return
		}
		let authority = SyncAuthority(
			projectId: project.id,
			account: .personal,
			environment: environment,
			authGeneration: authGeneration,
			sessionGeneration: sessionGeneration,
			operationGeneration: operationGeneration,
			authToken: authToken
		)
		guard isCurrentSync(authority) else { return }

		isSyncing = true
		lastSyncStatus = nil

		// Always send expectedVersion for audit trail. The server uses the `force`
		// flag to decide whether to allow the override — not the absence of version.
		let expectedVersion = syncMetadata[project.id]?.lastVersion

		do {
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			// Push ALL non-empty environments
			let nonEmptyEnvs = project.environments.filter { !$0.value.isEmpty }
			let payload = ["environments": nonEmptyEnvs]
			let secretsJSON = try JSONEncoder().encode(payload)
			guard let jsonString = String(data: secretsJSON, encoding: .utf8) else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let (blob, wrapped) = try VaultCrypto.encryptForStableSync(secretsJSON: jsonString)

			let syncService = personalSyncServiceFactory(environment.baseURL)
			let result = await syncService.push(
				authToken: authToken,
				vaultId: project.id,
				encryptedBlob: blob,
				wrappedKey: wrapped,
				expectedVersion: expectedVersion,
				force: force,
				name: project.name,
				schema: syncSchema(for: project)
			)
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}

			finishSyncIfOwned(authority)
			if let result, result.error == nil {
				lastSyncStatus = "Pushed (v\(result.version ?? 0))"
				markSynced(project.id, action: "push", version: result.version)
			} else {
				let message = result?.displayError ?? "Push failed"
				if message.contains("version conflict") || message.contains("conflict") {
					lastSyncStatus = "conflict"
				} else {
					error = message
					lastSyncStatus = "failed"
				}
			}
		} catch {
			guard isCurrentSync(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			self.error = error.localizedDescription
			finishSyncIfOwned(authority)
			lastSyncStatus = "failed"
		}
	}

	/// Pull secrets from cloud and merge into the selected project.
	func pullFromCloud() async {
		guard isUnlocked, selectedAccount == .personal, let project = selectedProject else { return }
		syncOperationGeneration &+= 1
		let operationGeneration = syncOperationGeneration
		let sessionGeneration = vaultSessionGeneration
		let environment = appEnvironment
		let authGeneration = authOperationGeneration
		guard let authToken = await authTokenProvider(environment.registryURL, environment.baseURL) else {
			guard operationGeneration == syncOperationGeneration,
				environment == appEnvironment,
				authGeneration == authOperationGeneration,
				sessionGeneration == vaultSessionGeneration
			else { return }
			error = "Not logged in. Run `lpm login` in terminal first."
			return
		}
		let authority = SyncAuthority(
			projectId: project.id,
			account: .personal,
			environment: environment,
			authGeneration: authGeneration,
			sessionGeneration: sessionGeneration,
			operationGeneration: operationGeneration,
			authToken: authToken
		)
		guard isCurrentSync(authority) else { return }

		isSyncing = true
		lastSyncStatus = nil

		guard await hasCurrentSyncAuth(authority) else {
			finishSyncIfOwned(authority)
			return
		}
		let syncService = personalSyncServiceFactory(environment.baseURL)
		let result = await syncService.pull(authToken: authToken, vaultId: project.id)
		guard await hasCurrentSyncAuth(authority) else {
			finishSyncIfOwned(authority)
			return
		}
		guard let result else {
			error = "Pull failed — no response from server"
			finishSyncIfOwned(authority)
			lastSyncStatus = "failed"
			return
		}

		guard let blob = result.encryptedBlob, let wrapped = result.wrappedKey else {
			error = result.error ?? "No env project data on cloud. Push first."
			finishSyncIfOwned(authority)
			lastSyncStatus = "empty"
			return
		}

		do {
			// Replay protection: reject version downgrades
			if let localVersion = syncMetadata[project.id]?.lastVersion,
			   let serverVersion = result.version,
			   serverVersion < localVersion {
				error = "Version downgrade rejected (local: v\(localVersion), server: v\(serverVersion))"
				finishSyncIfOwned(authority)
				lastSyncStatus = "failed"
				return
			}

			let decrypted = try VaultCrypto.decryptStableSync(
				authToken: authToken,
				encryptedBlob: blob,
				wrappedKey: wrapped
			)
			let jsonString = decrypted.plaintext

			guard let jsonData = jsonString.data(using: .utf8) else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let merge = try EnvValidation.mergeRemotePayload(
				jsonData,
				into: project.environments
			)
			var updated = project
			updated.environments = merge.environments

			let version = result.version ?? 0
			var syncedVersion = version
			if decrypted.usedLegacyKey {
				let (migratedBlob, migratedWrapped) = try VaultCrypto.encryptForStableSync(
					secretsJSON: jsonString
				)
				let migration = await syncService.push(
					authToken: authToken,
					vaultId: project.id,
					encryptedBlob: migratedBlob,
					wrappedKey: migratedWrapped,
					expectedVersion: version,
					force: false,
					name: project.name,
					schema: syncSchema(for: project)
				)
				guard await hasCurrentSyncAuth(authority) else {
					finishSyncIfOwned(authority)
					return
				}
				if migration?.error == nil, let migratedVersion = migration?.version {
					syncedVersion = migratedVersion
				}
			}

			let resolvedProject = updated
			let resolvedKeyCount = merge.keyCount
			let resolvedVersion = syncedVersion
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			saveAndUpdate(resolvedProject)
			finishSyncIfOwned(authority)
			lastSyncStatus = "Pulled (v\(resolvedVersion), \(resolvedKeyCount) keys)"
			markSynced(project.id, action: "pull", version: resolvedVersion)
		} catch {
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			self.error = "Decryption failed: \(error.localizedDescription)"
			finishSyncIfOwned(authority)
			lastSyncStatus = "failed"
		}
	}

	// MARK: - Org Sync

	/// Share (push) the selected project's vault with an org.
	/// If any member keys are new or changed, the push is blocked and
	/// `showKeyApprovalSheet` is set — the user must approve before continuing.
	func pushToOrg(orgSlug: String) async {
		guard isUnlocked, selectedAccount == .org(orgSlug), let project = selectedProject else { return }
		syncOperationGeneration &+= 1
		let operationGeneration = syncOperationGeneration
		let environment = appEnvironment
		let authGeneration = authOperationGeneration
		let sessionGeneration = vaultSessionGeneration
		guard let authToken = await authTokenProvider(environment.registryURL, environment.baseURL) else {
			guard operationGeneration == syncOperationGeneration,
				environment == appEnvironment,
				authGeneration == authOperationGeneration,
				sessionGeneration == vaultSessionGeneration
			else { return }
			error = "Not logged in."
			return
		}
		let authority = SyncAuthority(
			projectId: project.id,
			account: .org(orgSlug),
			environment: environment,
			authGeneration: authGeneration,
			sessionGeneration: sessionGeneration,
			operationGeneration: operationGeneration,
			authToken: authToken
		)
		guard isCurrentSync(authority) else { return }

		isSyncing = true
		lastSyncStatus = nil

		do {
			let syncService = orgSyncServiceFactory(environment.baseURL)
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}

			// 1. Require the server's registered sharing key to match this device.
			let (_, pubKey) = sharingKeypairProvider()
			let pubB64 = pubKey.base64EncodedString()
			let serverKey = await syncService.getMyPublicKey(authToken: authToken)
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			guard let serverKey else {
				throw VaultSyncError("Could not verify your registered sharing key.")
			}
			guard let registeredKey = serverKey.publicKey else {
				throw VaultSyncError(
					"Your sharing key is not registered yet. Run `lpm env share --org \(orgSlug)` once to complete secure step-up registration, then retry."
				)
			}
			guard registeredKey == pubB64 else {
				throw VaultSyncError(
					"This device's sharing key differs from the account key. Run `lpm env rotate-sharing-key` or restore the matching key before sharing."
				)
			}

			// 2. Get all org members' public keys
			let memberAccess = await syncService.getOrgMemberKeyAccess(
				authToken: authToken,
				orgSlug: orgSlug
			)
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			guard let memberAccess else {
				throw VaultSyncError("Could not fetch organization member keys.")
			}
			let members = memberAccess.members
			let membersWithKeys = members.filter { $0.hasPublicKey && $0.publicKey != nil }

			if membersWithKeys.isEmpty {
				error = "No org members have registered public keys yet."
				finishSyncIfOwned(authority)
				lastSyncStatus = "failed"
				return
			}

			// 2b. Strict key verification — block on new or changed keys
			let orgTrust = OrgKeyTrust.load(orgSlug: orgSlug)
			let membersForVerification: [(id: String, publicKey: Data)] = membersWithKeys.compactMap { member in
				guard let pubKeyB64 = member.publicKey,
					  let pubKeyData = Data(base64Encoded: pubKeyB64) else { return nil }
				return (id: member.userId, publicKey: pubKeyData)
			}
			let pendingApprovals = orgTrust.verify(members: membersForVerification)

			// If any keys need approval, block the push and show the approval sheet
			if !pendingApprovals.isEmpty {
				guard await hasCurrentSyncAuth(authority) else {
					finishSyncIfOwned(authority)
					return
				}
				pendingOrgPush = PendingOrgPush(
					orgSlug: orgSlug,
					projectId: project.id,
					allMembers: membersWithKeys,
					pendingApprovals: pendingApprovals,
					orgTrust: orgTrust,
					authToken: authToken,
					canReplaceWrappedKeys: memberAccess.canReplaceWrappedKeys,
					environment: environment,
					authGeneration: authGeneration,
					sessionGeneration: sessionGeneration,
					operationGeneration: operationGeneration
				)
				showKeyApprovalSheet = true
				finishSyncIfOwned(authority)
				lastSyncStatus = "approval_required"
				return
			}

			// All keys are trusted — proceed with push
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			_ = try await executeOrgPush(
				project: project,
				membersWithKeys: membersWithKeys,
				syncService: syncService,
				canReplaceWrappedKeys: memberAccess.canReplaceWrappedKeys,
				authority: authority
			)
		} catch {
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			self.error = error.localizedDescription
			finishSyncIfOwned(authority)
			lastSyncStatus = "failed"
		}
	}

	/// Called from KeyApprovalSheet when user accepts all pending keys.
	func approveAndContinueOrgPush(approved: [PendingKeyApproval]) async {
		guard let pending = pendingOrgPush else { return }
		guard pending.environment == appEnvironment,
			pending.authGeneration == authOperationGeneration,
			pending.sessionGeneration == vaultSessionGeneration,
			pending.operationGeneration == syncOperationGeneration,
			isUnlocked,
			selectedAccount == .org(pending.orgSlug),
			let project = selectedProject,
			project.id == pending.projectId
		else {
			invalidatePendingOrgPush()
			return
		}
		let currentToken = await authTokenProvider(
			pending.environment.registryURL,
			pending.environment.baseURL
		)
		guard currentToken == pending.authToken,
			pending.environment == appEnvironment,
			pending.authGeneration == authOperationGeneration,
			pending.sessionGeneration == vaultSessionGeneration,
			pending.operationGeneration == syncOperationGeneration,
			isUnlocked,
			pendingOrgPush?.projectId == pending.projectId,
			pendingOrgPush?.authToken == pending.authToken
		else {
			invalidatePendingOrgPush()
			return
		}

		syncOperationGeneration &+= 1
		let authority = SyncAuthority(
			projectId: pending.projectId,
			account: .org(pending.orgSlug),
			environment: pending.environment,
			authGeneration: pending.authGeneration,
			sessionGeneration: pending.sessionGeneration,
			operationGeneration: syncOperationGeneration,
			authToken: pending.authToken
		)
		showKeyApprovalSheet = false
		isSyncing = true
		lastSyncStatus = nil

		// Persist the approved fingerprints
		var orgTrust = pending.orgTrust
		orgTrust.approve(approved)
		orgTrust.save(orgSlug: pending.orgSlug)

		// Only wrap keys for members that are now trusted
		let approvedMemberIds = Set(approved.map(\.memberId))
		let trustedMemberIds = Set(orgTrust.trustedFingerprints.keys)
		let allTrustedIds = trustedMemberIds.union(approvedMemberIds)
		let trustedMembers = pending.allMembers.filter { allTrustedIds.contains($0.userId) }

		do {
			let syncService = orgSyncServiceFactory(pending.environment.baseURL)
			_ = try await executeOrgPush(
				project: project,
				membersWithKeys: trustedMembers,
				syncService: syncService,
				canReplaceWrappedKeys: pending.canReplaceWrappedKeys,
				authority: authority
			)
		} catch {
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			self.error = error.localizedDescription
			finishSyncIfOwned(authority)
			lastSyncStatus = "failed"
		}

		if isCurrentSync(authority) { pendingOrgPush = nil }
	}

	/// Called from KeyApprovalSheet when user rejects pending keys.
	func rejectPendingOrgPush() {
		invalidatePendingOrgPush()
		lastSyncStatus = "rejected"
		error = "Org push cancelled — untrusted member keys were rejected."
	}

	/// Shared implementation: encrypt and push vault data to an org.
	/// Only called after all member keys have been verified/approved.
	private func executeOrgPush(
		project: VaultProject,
		membersWithKeys: [SyncService.MemberPublicKey],
		syncService: any OrgSyncServiceProtocol,
		canReplaceWrappedKeys: Bool,
		authority: SyncAuthority
	) async throws -> Bool {
		guard await hasCurrentSyncAuth(authority) else {
			finishSyncIfOwned(authority)
			return false
		}
		// Encrypt secrets with random AES key
		let nonEmptyEnvs = project.environments.filter { !$0.value.isEmpty }
		let payload = ["environments": nonEmptyEnvs]
		let secretsJSON = try JSONEncoder().encode(payload)
		guard let jsonString = String(data: secretsJSON, encoding: .utf8) else {
			throw VaultCrypto.CryptoError.invalidUTF8
		}

		let aesKey: SymmetricKey
		let wrappedKeys: [SyncService.WrappedMemberKey]?
		let expectedVersion = syncMetadata[project.id]?.lastVersion
		if canReplaceWrappedKeys {
			aesKey = VaultCrypto.generateAESKey()
			wrappedKeys = try wrapContentKey(aesKey, for: membersWithKeys)
		} else {
			guard let expectedVersion else {
				throw VaultSyncError("Organization maintainers must pull the current env project before updating it.")
			}
			let (privateKey, publicKey) = sharingKeypairProvider()
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return false
			}
			let current = await syncService.pullOrg(
				authToken: authority.authToken,
				orgSlug: orgSlug(for: authority),
				vaultId: project.id
			)
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return false
			}
			guard let current,
				current.version == expectedVersion,
				let wrappedKey = current.wrappedKey,
				current.recipientPublicKeyFingerprint == VaultCrypto.publicKeyFingerprint(publicKey)
			else {
				throw VaultSyncError("The organization env project changed. Pull it and retry.")
			}
			aesKey = try VaultCrypto.unwrapKeyFromSender(wrapped: wrappedKey, privateKey: privateKey)
			wrappedKeys = nil
		}
		let blob = try VaultCrypto.encrypt(key: aesKey, plaintext: Data(jsonString.utf8))

		// Push to org
		guard await hasCurrentSyncAuth(authority) else {
			finishSyncIfOwned(authority)
			return false
		}
		let result = await syncService.pushOrg(
			authToken: authority.authToken,
			orgSlug: orgSlug(for: authority),
			vaultId: project.id,
			encryptedBlob: blob,
			wrappedKeys: wrappedKeys,
			expectedVersion: expectedVersion,
			name: project.name,
			schema: syncSchema(for: project)
		)

		guard await hasCurrentSyncAuth(authority) else {
			finishSyncIfOwned(authority)
			return false
		}
		finishSyncIfOwned(authority)
		if let r = result, r.error == nil {
			lastSyncStatus = "Shared with \(orgSlug(for: authority)) (v\(r.version ?? 0))"
			markSynced(project.id, action: "push", version: r.version)
		} else {
			self.error = result?.displayError ?? "Org push failed"
			lastSyncStatus = "failed"
		}
		return true
	}

	private func isCurrentSync(_ authority: SyncAuthority) -> Bool {
		authority.operationGeneration == syncOperationGeneration
			&& authority.sessionGeneration == vaultSessionGeneration
			&& authority.authGeneration == authOperationGeneration
			&& authority.environment == appEnvironment
			&& isUnlocked
			&& selectedAccount == authority.account
			&& selectedProject?.id == authority.projectId
	}

	private func hasCurrentSyncAuth(_ authority: SyncAuthority) async -> Bool {
		guard isCurrentSync(authority) else { return false }
		let currentToken = await authTokenProvider(
			authority.environment.registryURL,
			authority.environment.baseURL
		)
		return isCurrentSync(authority) && currentToken == authority.authToken
	}

	private func finishSyncIfOwned(_ authority: SyncAuthority) {
		guard authority.operationGeneration == syncOperationGeneration else { return }
		isSyncing = false
	}

	private func orgSlug(for authority: SyncAuthority) -> String {
		guard case .org(let slug) = authority.account else { return "" }
		return slug
	}

	private func wrapContentKey(
		_ aesKey: SymmetricKey,
		for members: [SyncService.MemberPublicKey]
	) throws -> [SyncService.WrappedMemberKey] {
		var wrappedKeys: [SyncService.WrappedMemberKey] = []
		wrappedKeys.reserveCapacity(members.count)
		for member in members {
			guard let publicKeyBase64 = member.publicKey,
				let publicKey = Data(base64Encoded: publicKeyBase64),
				publicKey.count == 32,
				let publicKeyVersion = member.publicKeyVersion,
				publicKeyVersion > 0,
				let publicKeyFingerprint = member.publicKeyFingerprint,
				publicKeyFingerprint == VaultCrypto.publicKeyFingerprint(publicKey)
			else {
				throw VaultSyncError("Organization member \(member.userId) has an invalid sharing-key binding.")
			}

			let wrapped = try VaultCrypto.wrapKeyForRecipient(
				aesKey: aesKey,
				recipientPublicKey: publicKey
			)
			wrappedKeys.append(SyncService.WrappedMemberKey(
				userId: member.userId,
				wrappedKey: wrapped,
				publicKeyVersion: publicKeyVersion,
				publicKeyFingerprint: publicKeyFingerprint
			))
		}
		guard !wrappedKeys.isEmpty else {
			throw VaultSyncError("No organization members have complete registered sharing keys.")
		}
		return wrappedKeys
	}

	/// Pull a vault from an org using X25519 decryption.
	func pullFromOrg(orgSlug: String) async {
		guard isUnlocked, selectedAccount == .org(orgSlug), let project = selectedProject else { return }
		syncOperationGeneration &+= 1
		let operationGeneration = syncOperationGeneration
		let sessionGeneration = vaultSessionGeneration
		let environment = appEnvironment
		let authGeneration = authOperationGeneration
		guard let authToken = await authTokenProvider(environment.registryURL, environment.baseURL) else {
			guard operationGeneration == syncOperationGeneration,
				environment == appEnvironment,
				authGeneration == authOperationGeneration,
				sessionGeneration == vaultSessionGeneration
			else { return }
			error = "Not logged in."
			return
		}
		let authority = SyncAuthority(
			projectId: project.id,
			account: .org(orgSlug),
			environment: environment,
			authGeneration: authGeneration,
			sessionGeneration: sessionGeneration,
			operationGeneration: operationGeneration,
			authToken: authToken
		)
		guard isCurrentSync(authority) else { return }

		isSyncing = true
		lastSyncStatus = nil

		do {
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			let syncService = orgSyncServiceFactory(environment.baseURL)

			// Ensure the local keypair matches the server before requesting a wrap.
			let (privKey, pubKey) = sharingKeypairProvider()
			let pubB64 = pubKey.base64EncodedString()
			let serverKey = await syncService.getMyPublicKey(authToken: authToken)
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			guard let serverKey,
				let registeredKey = serverKey.publicKey
			else {
				throw VaultSyncError(
					"Your sharing key is not registered. Run `lpm env share --org \(orgSlug)` once, then retry."
				)
			}
			guard registeredKey == pubB64 else {
				throw VaultSyncError(
					"This device does not hold the sharing key registered for your account."
				)
			}

			// Pull
			let result = await syncService.pullOrg(
				authToken: authToken, orgSlug: orgSlug, vaultId: project.id
			)
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			guard let result else {
				error = "Pull failed — no response"
				finishSyncIfOwned(authority)
				lastSyncStatus = "failed"
				return
			}

			guard let blob = result.encryptedBlob else {
				error = result.error ?? "No env project data in this organization."
				finishSyncIfOwned(authority)
				lastSyncStatus = "failed"
				return
			}

			guard let wrapped = result.wrappedKey else {
				// Public key was just uploaded but no wrapped key exists yet
				error = "Your encryption key isn't registered for this env project yet. Your public key has been uploaded — ask an org admin to re-share the env project so it gets wrapped for you."
				finishSyncIfOwned(authority)
				lastSyncStatus = "awaiting access"
				return
			}
			guard let contentKeyVersion = result.contentKeyVersion,
				contentKeyVersion > 0,
				let recipientKeyVersion = result.recipientPublicKeyVersion,
				recipientKeyVersion > 0,
				result.recipientPublicKeyFingerprint == VaultCrypto.publicKeyFingerprint(pubKey)
			else {
				throw VaultSyncError("The organization response has an invalid sharing-key binding.")
			}

			// Replay protection: reject version downgrades
			if let localVersion = syncMetadata[project.id]?.lastVersion,
			   let serverVersion = result.version,
			   serverVersion < localVersion {
				error = "Version downgrade rejected (local: v\(localVersion), server: v\(serverVersion))"
				finishSyncIfOwned(authority)
				lastSyncStatus = "failed"
				return
			}

			// Unwrap AES key with our X25519 private key
			let aesKey = try VaultCrypto.unwrapKeyFromSender(wrapped: wrapped, privateKey: privKey)
			let plaintext = try VaultCrypto.decrypt(key: aesKey, encoded: blob)

			guard let jsonString = String(data: plaintext, encoding: .utf8),
				  let jsonData = jsonString.data(using: .utf8) else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let merge = try EnvValidation.mergeRemotePayload(
				jsonData,
				into: project.environments
			)
			var updated = project
			updated.environments = merge.environments

			let version = result.version ?? 0

			let resolvedProject = updated
			let resolvedKeyCount = merge.keyCount
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			saveAndUpdate(resolvedProject)
			finishSyncIfOwned(authority)
			lastSyncStatus = "Pulled from \(orgSlug) (v\(version), \(resolvedKeyCount) keys)"
			markSynced(project.id, action: "pull", version: version)
		} catch {
			guard await hasCurrentSyncAuth(authority) else {
				finishSyncIfOwned(authority)
				return
			}
			self.error = "Org pull failed: \(error.localizedDescription)"
			finishSyncIfOwned(authority)
			lastSyncStatus = "failed"
		}
	}

	func currentAuthToken() async -> String? {
		await authTokenProvider(appEnvironment.registryURL, appEnvironment.baseURL)
	}

	private func syncSchema(for project: VaultProject) -> Data? {
		guard !project.path.isEmpty else { return nil }
		let configURL = URL(fileURLWithPath: project.path).appendingPathComponent("lpm.json")
		guard let data = try? Data(contentsOf: configURL),
			let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }

		var schema: [String: Any] = ["version": 2]
		if let envSchema = root["envSchema"] as? [String: Any] {
			schema["envSchema"] = envSchema["vars"] ?? envSchema
		}
		if let environments = root["environments"] as? [String: Any] {
			schema["environments"] = environments
		}
		if let env = root["env"] as? [String: String] {
			var envConfig: [String: [String: String]] = [:]
			for (alias, path) in env {
				guard path.hasPrefix(".env."), path.count > ".env.".count else { continue }
				envConfig[alias] = [
					"canonical": String(path.dropFirst(".env.".count)),
					"file": path,
				]
			}
			if !envConfig.isEmpty { schema["envConfig"] = envConfig }
		}
		return try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
	}

	// MARK: - Private

	private func saveAndUpdate(_ project: VaultProject) {
		cancelLocalEnvImports(projectId: project.id)
		invalidateProjectLoad()
		var metadata = syncMetadata[project.id] ?? SyncMetadata()
		metadata.isDirty = true
		syncMetadata[project.id] = metadata
		// Update UI immediately (optimistic)
		updateProjectInPlace(project)

		// Serialize the project and dirty metadata write in the coordinator.
		let saveTask = Task { [persistence] in
			await persistence.saveProject(project, markDirty: true)
		}
		Task { [weak self] in
			let (result, persistedMetadata) = await saveTask.value
			guard let self else { return }
			syncMetadata = persistedMetadata
			switch result {
				case .success, .successWithWarning:
					break // Already updated above
				case .failure(let err):
					error = err.description
				}
		}
	}

	private func updateProjectInPlace(_ project: VaultProject) {
		if let index = projects.firstIndex(where: { $0.id == project.id }) {
			projects[index] = project
		}
	}

	// MARK: - Sync Metadata

	private static let syncMetadataKey = "lpm-vault-sync-metadata"

	func syncStatus(for vaultId: String) -> ProjectSyncStatus {
		guard let meta = syncMetadata[vaultId] else { return .neverSynced }
		if meta.isDirty { return .localChanges }
		if meta.lastSyncedAt != nil { return .synced }
		return .neverSynced
	}

	func lastSyncInfo(for vaultId: String) -> (date: Date, action: String, version: Int?)? {
		guard let meta = syncMetadata[vaultId],
			  let date = meta.lastSyncedAt,
			  let action = meta.lastAction else { return nil }
		return (date, action, meta.lastVersion)
	}

	private func markSynced(_ vaultId: String, action: String, version: Int?) {
		var meta = syncMetadata[vaultId] ?? SyncMetadata()
		meta.isDirty = false
		meta.lastSyncedAt = Date()
		meta.lastAction = action
		meta.lastVersion = version
		syncMetadata[vaultId] = meta
		Task { [weak self, persistence] in
			guard let persisted = await persistence.markSynced(
				vaultId: vaultId,
				action: action,
				version: version
			) else {
				self?.error = "Could not save sync metadata."
				return
			}
			self?.syncMetadata = persisted
		}
	}

	// MARK: - Environment Ordering

	private static let envOrderPrefix = "lpm-vault-env-order-"

	func orderedEnvironmentNames(for project: VaultProject) -> [String] {
		if let saved = environmentOrders[project.id], !saved.isEmpty {
			let validSaved = saved.filter { project.environments.keys.contains($0) }
			let remaining = project.environmentNames.filter { !validSaved.contains($0) }
			return validSaved + remaining
		}
		return project.environmentNames
	}

	func saveEnvironmentOrder(for projectId: String, order: [String]) {
		environmentOrders[projectId] = order
		UserDefaults.standard.set(order, forKey: Self.envOrderPrefix + projectId)
	}

	private func loadEnvironmentOrders() {
		for project in projects {
			let key = Self.envOrderPrefix + project.id
			if let saved = UserDefaults.standard.stringArray(forKey: key) {
				environmentOrders[project.id] = saved
			}
		}
	}
}
