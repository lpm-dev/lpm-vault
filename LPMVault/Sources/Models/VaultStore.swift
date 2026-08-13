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
}

struct VaultSyncError: LocalizedError {
	let message: String

	init(_ message: String) {
		self.message = message
	}

	var errorDescription: String? { message }
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

enum AppEnvironment: String {
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

@Observable
@MainActor
final class VaultStore {
	// MARK: - State

	var projects: [VaultProject] = []
	var selectedProjectId: String?
	var isUnlocked: Bool = false
	var searchQuery: String = ""
	var error: String?

	// Auth state
	var currentUser: LPMUser?
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
	var vaultOrgAssociations: [String: String] = [:]  // vaultId → orgSlug

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
	private var autoLockTask: Task<Void, Never>?
	private let autoLockDuration: TimeInterval

	/// Returns the injected mock (for tests) or a live service for the active environment.
	private var apiService: LPMAPIServiceProtocol {
		injectedAPIService ?? LPMAPIService(baseURL: appEnvironment.baseURL)
	}

	// MARK: - Computed

	var selectedProject: VaultProject? {
		guard let id = selectedProjectId else { return nil }
		return projects.first { $0.id == id }
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

	// MARK: - Init

	init(
		keychainService: KeychainServiceProtocol = KeychainService(),
		biometricService: BiometricServiceProtocol = BiometricService(),
		apiService: LPMAPIServiceProtocol? = nil,
		autoLockDuration: TimeInterval = VaultConstants.biometricCacheDuration
	) {
		self.keychainService = keychainService
		self.persistence = VaultPersistenceCoordinator(service: keychainService)
		self.biometricService = biometricService
		self.injectedAPIService = apiService
		self.autoLockDuration = autoLockDuration

		#if DEBUG
		// Local-server selection is a debug-only developer convenience.
		if let saved = UserDefaults.standard.string(forKey: "lpm-vault-environment"),
		   let env = AppEnvironment(rawValue: saved) {
			self.appEnvironment = env
		}
		#endif

		// Load org associations from Keychain
		if let data = keychainService.readData(account: "__org_associations__"),
		   let saved = try? JSONDecoder().decode([String: String].self, from: data) {
			self.vaultOrgAssociations = saved
		}
	}

	#if DEBUG
	/// Switch between the production server and the local development server.
	/// Clears current session and reloads tokens for the new environment.
	func switchEnvironment(to env: AppEnvironment) {
		guard env != appEnvironment else { return }
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

	/// Load projects from Keychain. Runs Keychain access off the main thread
	/// to prevent UI freeze if macOS shows a Keychain access prompt.
	func loadProjects() {
		loadSyncMetadata()
		Task { [persistence] in
			let loaded = await persistence.listProjects()
				.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
			projects = loaded
			error = nil
			loadEnvironmentOrders()
		}
	}

	// MARK: - Project Operations

	/// Currently selected environment tab name
	var selectedEnvironment: String = "default"

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
				associateVaultWithOrg(vaultId: vaultId, orgSlug: slug)
				await pushToOrg(orgSlug: slug)
			}
		}
	}

	/// Associate a vault with an org (for column 2 filtering).
	func associateVaultWithOrg(vaultId: String, orgSlug: String) {
		vaultOrgAssociations[vaultId] = orgSlug
		saveOrgAssociations()
	}

	private func saveOrgAssociations() {
		if let data = try? JSONEncoder().encode(vaultOrgAssociations) {
			keychainService.writeData(account: "__org_associations__", data: data)
		}
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
			selectedProjectId = vaultId
			writeLpmJson(vaultId: vaultId, projectPath: path)
			return true
		case .failure(let err):
			error = err.description
			return false
		}
	}

	func addProject(name: String, path: String, environments: [String: [String: String]]? = nil) {
		let envs = environments ?? ["default": [:]]
		guard EnvValidation.areValidEnvironments(envs) else {
			error = "Environment names or variable names do not match the LPM env format."
			return
		}
		let existingVaultId = readVaultIdFromLpmJson(projectPath: path)

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
					selectedProjectId = project.id
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
		markDirty(project.id)
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
		// Update UI immediately
		projects.removeAll { $0.id == project.id }
		if selectedProjectId == project.id {
			selectedProjectId = projects.first?.id
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
		guard await persistence.deleteProject(vaultId: project.id) else {
			error = "Could not delete the local Keychain copy. The env project was kept."
			return false
		}

		projects.removeAll { $0.id == project.id }
		if selectedProjectId == project.id {
			selectedProjectId = projects.first?.id
		}
		vaultOrgAssociations.removeValue(forKey: project.id)
		syncMetadata.removeValue(forKey: project.id)
		environmentOrders.removeValue(forKey: project.id)
		UserDefaults.standard.removeObject(forKey: Self.envOrderPrefix + project.id)
		saveOrgAssociations()
		saveSyncMetadata()
		return true
	}

	/// Legacy alias — defaults to remove from sidebar (safe).
	func deleteProject(_ project: VaultProject) {
		removeFromSidebar(project)
	}

	// MARK: - Environment Operations

	/// Add a new environment tab to a project.
	func addEnvironment(to projectId: String, name: String, secrets: [String: String] = [:]) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard EnvValidation.isValidEnvironmentName(name),
			secrets.keys.allSatisfy(EnvValidation.isValidVariableName)
		else { return }
		guard project.environments[name] == nil else { return }
		project.environments[name] = secrets
		saveAndUpdate(project)
		markDirty(projectId)
		// Append new env to the stored order
		var order = orderedEnvironmentNames(for: project)
		order.append(name)
		saveEnvironmentOrder(for: projectId, order: order)
		selectedEnvironment = name
	}

	/// Delete an environment tab from a project. Cannot delete the last environment.
	func deleteEnvironment(from projectId: String, name: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard project.environments.count > 1 else { return }
		project.environments.removeValue(forKey: name)
		saveAndUpdate(project)
		markDirty(projectId)
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
		markDirty(projectId)
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
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard EnvValidation.isValidEnvironmentName(newName) else { return }
		guard project.environments[newName] == nil else { return }
		guard let secrets = project.environments[oldName] else { return }
		project.environments.removeValue(forKey: oldName)
		project.environments[newName] = secrets
		saveAndUpdate(project)
		markDirty(projectId)
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
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		project.environments[name] = [:]
		saveAndUpdate(project)
		markDirty(projectId)
	}

	// MARK: - Secret Operations (environment-aware)

	/// Import multiple secrets into the selected environment. Merges with existing — imported values win on conflict.
	func importSecrets(to projectId: String, secrets: [String: String]) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard !secrets.isEmpty,
			secrets.keys.allSatisfy(EnvValidation.isValidVariableName)
		else { return }

		var envSecrets = project.environments[selectedEnvironment] ?? [:]
		envSecrets.merge(secrets) { _, imported in imported }
		project.environments[selectedEnvironment] = envSecrets
		saveAndUpdate(project)
		markDirty(projectId)
	}

	func addSecret(to projectId: String, key: String, value: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard EnvValidation.isValidVariableName(key) else { return }

		var envSecrets = project.environments[selectedEnvironment] ?? [:]
		envSecrets[key] = value
		project.environments[selectedEnvironment] = envSecrets
		saveAndUpdate(project)
		markDirty(projectId)
	}

	func updateSecret(in projectId: String, key: String, newValue: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard project.environments[selectedEnvironment]?[key] != nil else { return }

		project.environments[selectedEnvironment]?[key] = newValue
		saveAndUpdate(project)
		markDirty(projectId)
	}

	func deleteSecret(from projectId: String, key: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }

		project.environments[selectedEnvironment]?.removeValue(forKey: key)
		saveAndUpdate(project)
		markDirty(projectId)
	}

	// MARK: - Token Operations

	func loadTokens() async {
		await MainActor.run { isLoadingTokens = true }

		let user = await apiService.fetchCurrentUser()
		let tokens = await apiService.fetchPersonalTokens()

		var orgTokensMap: [String: [LPMToken]] = [:]
		if let orgs = user?.orgs {
			for org in orgs {
				let orgToks = await apiService.fetchOrgTokens(orgSlug: org.slug)
				if !orgToks.isEmpty {
					orgTokensMap[org.slug] = orgToks
				}
			}
		}
		let resolvedOrgTokens = orgTokensMap

		await MainActor.run {
			currentUser = user
			personalTokens = tokens
			orgTokens = resolvedOrgTokens
			isLoadingTokens = false
		}
	}

	func revokePersonalToken(_ token: LPMToken) async {
		let success = await apiService.revokePersonalToken(id: token.id)
		if success {
			await MainActor.run {
				personalTokens.removeAll { $0.id == token.id }
			}
		}
	}

	func revokeOrgToken(_ token: LPMToken, orgSlug: String) async {
		let success = await apiService.revokeOrgToken(orgSlug: orgSlug, id: token.id)
		if success {
			await MainActor.run {
				orgTokens[orgSlug]?.removeAll { $0.id == token.id }
			}
		}
	}

	// MARK: - Auth (Login / Logout)

	/// Start the browser-based login flow — same UX as `lpm login`.
	/// Validates the token with the server before persisting it to Keychain.
	func login() async {
		await MainActor.run { isLoggingIn = true; error = nil }

		do {
			let credentials = try await LoginService.login(
				registryURL: appEnvironment.registryURL,
				baseURL: appEnvironment.baseURL
			)

			// Validate the token actually works before storing it
			let validationService = LPMAPIService(baseURL: appEnvironment.baseURL)
			let user = await validationService.fetchCurrentUser(authToken: credentials.token)
			guard user != nil else {
				await MainActor.run {
					error = "Login failed — server rejected the token."
					isLoggingIn = false
				}
				return
			}

			// Token is valid — persist to Keychain (shared with CLI)
			try LoginService.writeAuthSession(credentials, registryURL: appEnvironment.registryURL)

			// Load full user info + tokens
			await loadTokens()

			await MainActor.run { isLoggingIn = false }
		} catch {
			await MainActor.run {
				self.error = error.localizedDescription
				isLoggingIn = false
			}
		}
	}

	/// Sign out — clear token from Keychain and reset state.
	func logout() {
		LoginService.clearAuthSession(registryURL: appEnvironment.registryURL)
		currentUser = nil
		personalTokens = []
		orgTokens = [:]
		error = nil
		lastSyncStatus = nil
	}

	// MARK: - Auth (Biometric)

	func unlock() async {
		let success = await biometricService.authenticate(
			reason: "Unlock LPM Vault to view secrets"
		)
		await MainActor.run {
			isUnlocked = success
			if success {
				// Reload secrets from Keychain (they were cleared on lock)
				loadProjects()
				scheduleAutoLock()
			}
		}
	}

	func lock() {
		autoLockTask?.cancel()
		autoLockTask = nil
		isUnlocked = false
		biometricService.resetCache()
		// Clear decrypted secrets from memory to reduce exposure window
		for i in projects.indices {
			projects[i].environments = projects[i].environments.mapValues { _ in [:] }
		}
	}

	/// Reset the auto-lock timer (call on user interaction while unlocked)
	func resetAutoLock() {
		guard isUnlocked else { return }
		scheduleAutoLock()
	}

	private func scheduleAutoLock() {
		autoLockTask?.cancel()
		autoLockTask = Task { @MainActor in
			try? await Task.sleep(for: .seconds(autoLockDuration))
			if !Task.isCancelled {
				lock()
			}
		}
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
		guard let project = selectedProject else { return }
		guard let authToken = await currentAuthToken() else {
			await MainActor.run { error = "Not logged in. Run `lpm login` in terminal first." }
			return
		}

		await MainActor.run { isSyncing = true; lastSyncStatus = nil }

		// Always send expectedVersion for audit trail. The server uses the `force`
		// flag to decide whether to allow the override — not the absence of version.
		let expectedVersion = syncMetadata[project.id]?.lastVersion

		do {
			// Push ALL non-empty environments
			let nonEmptyEnvs = project.environments.filter { !$0.value.isEmpty }
			let payload = ["environments": nonEmptyEnvs]
			let secretsJSON = try JSONEncoder().encode(payload)
			guard let jsonString = String(data: secretsJSON, encoding: .utf8) else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let (blob, wrapped) = try VaultCrypto.encryptForStableSync(secretsJSON: jsonString)

			let syncService = SyncService(baseURL: appEnvironment.baseURL)
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

			await MainActor.run {
				isSyncing = false
				if let r = result, r.error == nil {
					lastSyncStatus = "Pushed (v\(r.version ?? 0))"
					markSynced(project.id, action: "push", version: r.version)
				} else {
					let errMsg = result?.displayError ?? "Push failed"
					if errMsg.contains("version conflict") || errMsg.contains("conflict") {
						lastSyncStatus = "conflict"
					} else {
						error = errMsg
						lastSyncStatus = "failed"
					}
				}
			}
		} catch {
			await MainActor.run {
				self.error = error.localizedDescription
				isSyncing = false
				lastSyncStatus = "failed"
			}
		}
	}

	/// Pull secrets from cloud and merge into the selected project.
	func pullFromCloud() async {
		guard let project = selectedProject else { return }
		guard let authToken = await currentAuthToken() else {
			await MainActor.run { error = "Not logged in. Run `lpm login` in terminal first." }
			return
		}

		await MainActor.run { isSyncing = true; lastSyncStatus = nil }

		let syncService = SyncService(baseURL: appEnvironment.baseURL)
		guard let result = await syncService.pull(authToken: authToken, vaultId: project.id) else {
			await MainActor.run {
				error = "Pull failed — no response from server"
				isSyncing = false
				lastSyncStatus = "failed"
			}
			return
		}

		guard let blob = result.encryptedBlob, let wrapped = result.wrappedKey else {
			await MainActor.run {
				error = result.error ?? "No env project data on cloud. Push first."
				isSyncing = false
				lastSyncStatus = "empty"
			}
			return
		}

		do {
			// Replay protection: reject version downgrades
			if let localVersion = syncMetadata[project.id]?.lastVersion,
			   let serverVersion = result.version,
			   serverVersion < localVersion {
				await MainActor.run {
					error = "Version downgrade rejected (local: v\(localVersion), server: v\(serverVersion))"
					isSyncing = false
					lastSyncStatus = "failed"
				}
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
					name: project.name,
					schema: syncSchema(for: project)
				)
				if migration?.error == nil, let migratedVersion = migration?.version {
					syncedVersion = migratedVersion
				}
			}

			let resolvedProject = updated
			let resolvedKeyCount = merge.keyCount
			let resolvedVersion = syncedVersion
			await MainActor.run {
				saveAndUpdate(resolvedProject)
				isSyncing = false
				lastSyncStatus = "Pulled (v\(resolvedVersion), \(resolvedKeyCount) keys)"
				markSynced(project.id, action: "pull", version: resolvedVersion)
			}
		} catch {
			await MainActor.run {
				self.error = "Decryption failed: \(error.localizedDescription)"
				isSyncing = false
				lastSyncStatus = "failed"
			}
		}
	}

	// MARK: - Org Sync

	/// Share (push) the selected project's vault with an org.
	/// If any member keys are new or changed, the push is blocked and
	/// `showKeyApprovalSheet` is set — the user must approve before continuing.
	func pushToOrg(orgSlug: String) async {
		guard let project = selectedProject else { return }
		guard let authToken = await currentAuthToken() else {
			await MainActor.run { error = "Not logged in." }
			return
		}

		await MainActor.run { isSyncing = true; lastSyncStatus = nil }

		do {
			let syncService = SyncService(baseURL: appEnvironment.baseURL)

			// 1. Require the server's registered sharing key to match this device.
			let (_, pubKey) = VaultCrypto.getOrCreateX25519Keypair()
			let pubB64 = pubKey.base64EncodedString()
			guard let serverKey = await syncService.getMyPublicKey(authToken: authToken) else {
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
			guard let memberAccess = await syncService.getOrgMemberKeyAccess(
				authToken: authToken,
				orgSlug: orgSlug
			) else {
				throw VaultSyncError("Could not fetch organization member keys.")
			}
			let members = memberAccess.members
			let membersWithKeys = members.filter { $0.hasPublicKey && $0.publicKey != nil }

			if membersWithKeys.isEmpty {
				await MainActor.run {
					error = "No org members have registered public keys yet."
					isSyncing = false
					lastSyncStatus = "failed"
				}
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
				await MainActor.run {
					self.pendingOrgPush = PendingOrgPush(
						orgSlug: orgSlug,
						projectId: project.id,
						allMembers: membersWithKeys,
						pendingApprovals: pendingApprovals,
						orgTrust: orgTrust,
						authToken: authToken,
						canReplaceWrappedKeys: memberAccess.canReplaceWrappedKeys
					)
					self.showKeyApprovalSheet = true
					self.isSyncing = false
					self.lastSyncStatus = "approval_required"
				}
				return
			}

			// All keys are trusted — proceed with push
			try await executeOrgPush(
				project: project,
				authToken: authToken,
				orgSlug: orgSlug,
				membersWithKeys: membersWithKeys,
				syncService: syncService,
				canReplaceWrappedKeys: memberAccess.canReplaceWrappedKeys
			)
		} catch {
			await MainActor.run {
				self.error = error.localizedDescription
				isSyncing = false
				lastSyncStatus = "failed"
			}
		}
	}

	/// Called from KeyApprovalSheet when user accepts all pending keys.
	func approveAndContinueOrgPush(approved: [PendingKeyApproval]) async {
		guard let pending = pendingOrgPush else { return }
		guard let project = projects.first(where: { $0.id == pending.projectId }) else { return }

		await MainActor.run {
			showKeyApprovalSheet = false
			isSyncing = true
			lastSyncStatus = nil
		}

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
			let syncService = SyncService(baseURL: appEnvironment.baseURL)
			try await executeOrgPush(
				project: project,
				authToken: pending.authToken,
				orgSlug: pending.orgSlug,
				membersWithKeys: trustedMembers,
				syncService: syncService,
				canReplaceWrappedKeys: pending.canReplaceWrappedKeys
			)
		} catch {
			await MainActor.run {
				self.error = error.localizedDescription
				isSyncing = false
				lastSyncStatus = "failed"
			}
		}

		await MainActor.run { pendingOrgPush = nil }
	}

	/// Called from KeyApprovalSheet when user rejects pending keys.
	func rejectPendingOrgPush() {
		showKeyApprovalSheet = false
		pendingOrgPush = nil
		lastSyncStatus = "rejected"
		error = "Org push cancelled — untrusted member keys were rejected."
	}

	/// Shared implementation: encrypt and push vault data to an org.
	/// Only called after all member keys have been verified/approved.
	private func executeOrgPush(
		project: VaultProject,
		authToken: String,
		orgSlug: String,
		membersWithKeys: [SyncService.MemberPublicKey],
		syncService: SyncService,
		canReplaceWrappedKeys: Bool
	) async throws {
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
			let (privateKey, publicKey) = VaultCrypto.getOrCreateX25519Keypair()
			guard let current = await syncService.pullOrg(
				authToken: authToken,
				orgSlug: orgSlug,
				vaultId: project.id
			),
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
		let result = await syncService.pushOrg(
			authToken: authToken,
			orgSlug: orgSlug,
			vaultId: project.id,
			encryptedBlob: blob,
			wrappedKeys: wrappedKeys,
			expectedVersion: expectedVersion,
			name: project.name,
			schema: syncSchema(for: project)
		)

		await MainActor.run {
			isSyncing = false
			if let r = result, r.error == nil {
				lastSyncStatus = "Shared with \(orgSlug) (v\(r.version ?? 0))"
				markSynced(project.id, action: "push", version: r.version)
			} else {
				self.error = result?.displayError ?? "Org push failed"
				lastSyncStatus = "failed"
			}
		}
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
		guard let project = selectedProject else { return }
		guard let authToken = await currentAuthToken() else {
			await MainActor.run { error = "Not logged in." }
			return
		}

		await MainActor.run { isSyncing = true; lastSyncStatus = nil }

		do {
			let syncService = SyncService(baseURL: appEnvironment.baseURL)

			// Ensure the local keypair matches the server before requesting a wrap.
			let (privKey, pubKey) = VaultCrypto.getOrCreateX25519Keypair()
			let pubB64 = pubKey.base64EncodedString()
			guard let serverKey = await syncService.getMyPublicKey(authToken: authToken),
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
			guard let result = await syncService.pullOrg(
				authToken: authToken, orgSlug: orgSlug, vaultId: project.id
			) else {
				await MainActor.run {
					error = "Pull failed — no response"
					isSyncing = false
					lastSyncStatus = "failed"
				}
				return
			}

			guard let blob = result.encryptedBlob else {
				await MainActor.run {
					error = result.error ?? "No env project data in this organization."
					isSyncing = false
					lastSyncStatus = "failed"
				}
				return
			}

			guard let wrapped = result.wrappedKey else {
				// Public key was just uploaded but no wrapped key exists yet
				await MainActor.run {
					error = "Your encryption key isn't registered for this env project yet. Your public key has been uploaded — ask an org admin to re-share the env project so it gets wrapped for you."
					isSyncing = false
					lastSyncStatus = "awaiting access"
				}
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
				await MainActor.run {
					error = "Version downgrade rejected (local: v\(localVersion), server: v\(serverVersion))"
					isSyncing = false
					lastSyncStatus = "failed"
				}
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
			await MainActor.run {
				saveAndUpdate(resolvedProject)
				isSyncing = false
				lastSyncStatus = "Pulled from \(orgSlug) (v\(version), \(resolvedKeyCount) keys)"
				markSynced(project.id, action: "pull", version: version)
			}
		} catch {
			await MainActor.run {
				self.error = "Org pull failed: \(error.localizedDescription)"
				isSyncing = false
				lastSyncStatus = "failed"
			}
		}
	}

	func currentAuthToken() async -> String? {
		await AuthSessionStore.currentAccessToken(
			registryURL: appEnvironment.registryURL,
			baseURL: appEnvironment.baseURL
		)
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
		// Update UI immediately (optimistic)
		updateProjectInPlace(project)

		// Write to Keychain off main thread
		let saveTask = Task { [persistence] in
			await persistence.save(project)
		}
		Task { [weak self] in
			let result = await saveTask.value
			guard let self else { return }
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

	func markDirty(_ vaultId: String) {
		var meta = syncMetadata[vaultId] ?? SyncMetadata()
		meta.isDirty = true
		syncMetadata[vaultId] = meta
		saveSyncMetadata()
	}

	private func markSynced(_ vaultId: String, action: String, version: Int?) {
		var meta = syncMetadata[vaultId] ?? SyncMetadata()
		meta.isDirty = false
		meta.lastSyncedAt = Date()
		meta.lastAction = action
		meta.lastVersion = version
		syncMetadata[vaultId] = meta
		saveSyncMetadata()
	}

	private func loadSyncMetadata() {
		if let data = keychainService.readData(account: "__sync_metadata__"),
		   let decoded = try? JSONDecoder().decode([String: SyncMetadata].self, from: data) {
			syncMetadata = decoded
		}
	}

	private func saveSyncMetadata() {
		if let data = try? JSONEncoder().encode(syncMetadata) {
			keychainService.writeData(account: "__sync_metadata__", data: data)
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
