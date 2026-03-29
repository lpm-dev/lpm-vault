import Foundation

// MARK: - App Environment

enum AppEnvironment: String {
	case production
	case development

	var baseURL: URL {
		switch self {
		case .production: VaultConstants.apiBaseURL
		case .development: VaultConstants.apiDevBaseURL
		}
	}

	var registryURL: String {
		switch self {
		case .production: "https://lpm.dev"
		case .development: "http://localhost:3000"
		}
	}

	var keychainAccount: String {
		"auth-token:\(registryURL)"
	}

	var label: String {
		switch self {
		case .production: "Live"
		case .development: "Dev"
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

	// Environment tab ordering (persisted across launches)
	var environmentOrders: [String: [String]] = [:]

	// App environment (dev vs live)
	var appEnvironment: AppEnvironment = .production

	// MARK: - Dependencies

	private let keychainService: KeychainServiceProtocol
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
		self.biometricService = biometricService
		self.injectedAPIService = apiService
		self.autoLockDuration = autoLockDuration

		// Load persisted environment
		if let saved = UserDefaults.standard.string(forKey: "lpm-vault-environment"),
		   let env = AppEnvironment(rawValue: saved) {
			self.appEnvironment = env
		}

		// Load org associations from Keychain
		if let data = keychainService.readData(account: "__org_associations__"),
		   let saved = try? JSONDecoder().decode([String: String].self, from: data) {
			self.vaultOrgAssociations = saved
		}
	}

	/// Switch between production and development servers.
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

	// MARK: - Load

	/// Load projects from Keychain. Runs Keychain access off the main thread
	/// to prevent UI freeze if macOS shows a Keychain access prompt.
	func loadProjects() {
		loadSyncMetadata()
		Task.detached { [keychainService] in
			let loaded = keychainService.listProjects()
				.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
			await MainActor.run { [weak self] in
				self?.projects = loaded
				self?.error = nil
				self?.loadEnvironmentOrders()
			}
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

		addProjectWithVaultId(vaultId: vaultId, name: name, path: "", environments: environments)

		if let slug = orgSlug {
			associateVaultWithOrg(vaultId: vaultId, orgSlug: slug)
			// Share with org after creation
			Task.detached { [weak self] in
				try? await Task.sleep(nanoseconds: 500_000_000)
				await self?.pushToOrg(orgSlug: slug)
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
	/// When `pullAfterAdd` is true, automatically pulls from cloud after the project is saved to Keychain and added to the store.
	func addProjectWithVaultId(vaultId: String, name: String, path: String, environments: [String: [String: String]], pullAfterAdd: Bool = false) {
		#if DEBUG
		print("[DEBUG] addProjectWithVaultId: \(name) vaultId=\(vaultId) envs=\(environments.keys.sorted()) pullAfterAdd=\(pullAfterAdd)")
		#endif
		let project = VaultProject(id: vaultId, name: name, path: path, environments: environments)

		// Run Keychain write off main thread to prevent UI freeze
		Task.detached { [keychainService, weak self] in
			#if DEBUG
			print("[DEBUG] Task.detached started for saveEnvironments")
			#endif
			let result = keychainService.saveEnvironments(
				vaultId: vaultId,
				projectName: name,
				projectPath: path,
				environments: environments
			)

			#if DEBUG
			print("[DEBUG] saveEnvironments returned: \(result)")
			#endif
			await MainActor.run {
				switch result {
				case .success, .successWithWarning:
					#if DEBUG
					print("[DEBUG] Keychain save success, updating UI")
					#endif
					self?.projects.append(project)
					self?.projects.sort {
						$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
					}
					self?.selectedProjectId = vaultId
					// selectedProjectId already set above
					self?.writeLpmJson(vaultId: vaultId, projectPath: path)
					#if DEBUG
					print("[DEBUG] Project added to sidebar: \(name)")
					#endif
				case .failure(let err):
					#if DEBUG
					print("[DEBUG] Keychain save FAILED: \(err)")
					#endif
					self?.error = err.description
				}
			}

			// Pull from cloud AFTER project is fully added to the store
			if pullAfterAdd {
				#if DEBUG
				print("[DEBUG] Starting cloud pull after project add")
				#endif
				await self?.pullFromCloud()
			}
		}
	}

	func addProject(name: String, path: String, environments: [String: [String: String]]? = nil) {
		#if DEBUG
		print("[DEBUG] addProject: \(name) path=\(path)")
		#endif
		let envs = environments ?? ["default": [:]]

		// Run all Keychain operations off main thread
		Task.detached { [keychainService, weak self] in
			// Check if lpm.json already has a vault ID for this path
			let existingVaultId = await MainActor.run { self?.readVaultIdFromLpmJson(projectPath: path) }
			let vaultId = existingVaultId ?? UUID().uuidString.lowercased()

			// If re-using existing vault ID, check if Keychain already has data
			var finalEnvs = envs
			if existingVaultId != nil {
				if let keychainEnvs = keychainService.getEnvironments(vaultId: vaultId), !keychainEnvs.isEmpty {
					var merged = envs
					for (envName, secrets) in keychainEnvs {
						var env = merged[envName] ?? [:]
						env.merge(secrets) { _, kc in kc }
						merged[envName] = env
					}
					finalEnvs = merged
				}
			}

			let project = VaultProject(id: vaultId, name: name, path: path, environments: finalEnvs)

			let result = keychainService.saveEnvironments(
				vaultId: vaultId,
				projectName: name,
				projectPath: path,
				environments: finalEnvs
			)

			await MainActor.run {
				switch result {
				case .success, .successWithWarning:
					self?.projects.append(project)
					self?.projects.sort {
						$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
					}
					self?.selectedProjectId = vaultId
					// selectedProjectId already set above
					self?.writeLpmJson(vaultId: vaultId, projectPath: path)
				case .failure(let err):
					self?.error = err.description
				}
			}
		}
	}

	/// Run a `security` CLI command safely (no waitUntilExit deadlock).
	private func runSecurityCLI(args: [String], timeout: TimeInterval = 10) -> (Int32, String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		process.arguments = args

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		let sem = DispatchSemaphore(value: 0)
		var exitCode: Int32 = -1

		process.terminationHandler = { p in
			exitCode = p.terminationStatus
			sem.signal()
		}

		do {
			try process.run()
		} catch {
			return (-1, "")
		}

		let result = sem.wait(timeout: .now() + timeout)
		if result == .timedOut {
			process.terminate()
			return (-1, "")
		}

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return (exitCode, output)
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
		Task.detached { [keychainService] in
			_ = keychainService.removeFromSidebar(vaultId: project.id)
		}
	}

	/// Delete local vault data (Keychain) but keep cloud copy.
	/// Can be recovered via `lpm env vars pull`.
	func deleteLocalVault(_ project: VaultProject) {
		// Update UI immediately
		projects.removeAll { $0.id == project.id }
		if selectedProjectId == project.id {
			selectedProjectId = projects.first?.id
		}
		// Keychain delete off main thread
		Task.detached { [keychainService] in
			_ = keychainService.deleteProject(vaultId: project.id)
		}
	}

	/// Delete vault data everywhere — local Keychain + cloud.
	/// This is irreversible.
	func deleteEverywhere(_ project: VaultProject) async {
		// Delete cloud first
		if let authToken = readCLIAuthToken() {
			let syncService = SyncService(baseURL: appEnvironment.baseURL)
			// Push empty vault to "delete" cloud data
			let emptyJSON = "{}"
			if let (blob, wrapped) = try? VaultCrypto.encryptForSync(authToken: authToken, secretsJSON: emptyJSON) {
				_ = await syncService.push(
					authToken: authToken,
					vaultId: project.id,
					encryptedBlob: blob,
					wrappedKey: wrapped,
					force: true
				)
			}
		}

		// Then delete local
		deleteLocalVault(project)
	}

	/// Legacy alias — defaults to remove from sidebar (safe).
	func deleteProject(_ project: VaultProject) {
		removeFromSidebar(project)
	}

	// MARK: - Environment Operations

	/// Add a new environment tab to a project.
	func addEnvironment(to projectId: String, name: String, secrets: [String: String] = [:]) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard !name.isEmpty else { return }
		guard name.count <= 64 else { return }
		guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else { return }
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
		guard !newName.isEmpty else { return }
		guard newName.count <= 64 else { return }
		guard newName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else { return }
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
		guard !newName.isEmpty else { return }
		guard newName.count <= 64 else { return }
		guard newName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else { return }
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
		guard !secrets.isEmpty else { return }

		var envSecrets = project.environments[selectedEnvironment] ?? [:]
		envSecrets.merge(secrets) { _, imported in imported }
		project.environments[selectedEnvironment] = envSecrets
		saveAndUpdate(project)
		markDirty(projectId)
	}

	func addSecret(to projectId: String, key: String, value: String) {
		guard var project = projects.first(where: { $0.id == projectId }) else { return }
		guard !key.isEmpty else { return }
		guard key.count <= 256 else { return }
		guard key.allSatisfy({ !$0.isNewline && $0 != "\0" }) else { return }

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
	func login() async {
		await MainActor.run { isLoggingIn = true; error = nil }

		do {
			let token = try await LoginService.login(registryURL: appEnvironment.registryURL)

			// Store token in Keychain (shared with CLI)
			LoginService.writeAuthToken(token, registryURL: appEnvironment.registryURL)

			// Reload user info to verify the token works
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
		LoginService.clearAuthToken(registryURL: appEnvironment.registryURL)
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
			try? await Task.sleep(nanoseconds: UInt64(autoLockDuration * 1_000_000_000))
			if !Task.isCancelled {
				isUnlocked = false
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
		guard let authToken = readCLIAuthToken() else {
			await MainActor.run { error = "Not logged in. Run `lpm login` in terminal first." }
			return
		}

		await MainActor.run { isSyncing = true; lastSyncStatus = nil }

		// Pass local expectedVersion to server for optimistic concurrency control
		// force allows overwriting server data but the server still increments version
		let expectedVersion = syncMetadata[project.id]?.lastVersion

		do {
			// Push ALL non-empty environments
			let nonEmptyEnvs = project.environments.filter { !$0.value.isEmpty }
			let payload = ["environments": nonEmptyEnvs]
			let secretsJSON = try JSONEncoder().encode(payload)
			guard let jsonString = String(data: secretsJSON, encoding: .utf8) else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let (blob, wrapped) = try VaultCrypto.encryptForSync(
				authToken: authToken,
				secretsJSON: jsonString
			)

			let syncService = SyncService(baseURL: appEnvironment.baseURL)
			let result = await syncService.push(
				authToken: authToken,
				vaultId: project.id,
				encryptedBlob: blob,
				wrappedKey: wrapped,
				expectedVersion: force ? nil : expectedVersion,
				force: force
			)

			await MainActor.run {
				isSyncing = false
				if let r = result, r.error == nil {
					lastSyncStatus = "Pushed (v\(r.version ?? 0))"
					markSynced(project.id, action: "push", version: r.version)
				} else {
					let errMsg = result?.error ?? "Push failed"
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
		guard let authToken = readCLIAuthToken() else {
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
				error = result.error ?? "No vault data on cloud. Push first."
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

			let jsonString = try VaultCrypto.decryptFromSync(
				authToken: authToken,
				encryptedBlob: blob,
				wrappedKey: wrapped
			)

			guard let jsonData = jsonString.data(using: .utf8) else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			var updated = project
			var totalKeys = 0

			// Try new format: {"environments": {"default": {...}, "live": {...}}}
			if let wrapper = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: jsonData),
			   let remoteEnvs = wrapper["environments"] {
				// Merge each environment: remote wins on conflicts
				var mergedEnvs = project.environments
				for (envName, remoteSecrets) in remoteEnvs {
					var envSecrets = mergedEnvs[envName] ?? [:]
					envSecrets.merge(remoteSecrets) { _, remote in remote }
					mergedEnvs[envName] = envSecrets
					totalKeys += envSecrets.count
				}
				updated.environments = mergedEnvs
			}
			// Fall back to old flat format: {"KEY": "VALUE"} → merge into "default"
			else if let remoteSecrets = try? JSONDecoder().decode([String: String].self, from: jsonData) {
				var merged = project.secrets
				merged.merge(remoteSecrets) { _, remote in remote }
				updated.secrets = merged
				totalKeys = merged.count
			} else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let version = result.version ?? 0

			await MainActor.run {
				saveAndUpdate(updated)
				isSyncing = false
				lastSyncStatus = "Pulled (v\(version), \(totalKeys) keys)"
				markSynced(project.id, action: "pull", version: version)
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
	func pushToOrg(orgSlug: String) async {
		guard let project = selectedProject else { return }
		guard let authToken = readCLIAuthToken() else {
			await MainActor.run { error = "Not logged in." }
			return
		}

		await MainActor.run { isSyncing = true; lastSyncStatus = nil }

		do {
			let syncService = SyncService(baseURL: appEnvironment.baseURL)

			// 1. Ensure our public key is uploaded
			let (privKey, pubKey) = VaultCrypto.getOrCreateX25519Keypair()
			let pubB64 = pubKey.base64EncodedString()
			_ = await syncService.uploadPublicKey(authToken: authToken, publicKey: pubB64)

			// 2. Get all org members' public keys
			let members = await syncService.getOrgMemberKeys(authToken: authToken, orgSlug: orgSlug)
			let membersWithKeys = members.filter { $0.hasPublicKey && $0.publicKey != nil }

			if membersWithKeys.isEmpty {
				await MainActor.run {
					error = "No org members have registered public keys yet."
					isSyncing = false
					lastSyncStatus = "failed"
				}
				return
			}

			// 3. Encrypt secrets with random AES key
			let nonEmptyEnvs = project.environments.filter { !$0.value.isEmpty }
			let payload = ["environments": nonEmptyEnvs]
			let secretsJSON = try JSONEncoder().encode(payload)
			guard let jsonString = String(data: secretsJSON, encoding: .utf8) else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let aesKey = VaultCrypto.generateAESKey()
			let blob = try VaultCrypto.encrypt(key: aesKey, plaintext: Data(jsonString.utf8))

			// 4. Wrap AES key for each member
			var wrappedKeys: [[String: String]] = []
			for member in membersWithKeys {
				guard let pubKeyB64 = member.publicKey,
					  let pubKeyData = Data(base64Encoded: pubKeyB64),
					  pubKeyData.count == 32 else { continue }

				let wrapped = try VaultCrypto.wrapKeyForRecipient(aesKey: aesKey, recipientPublicKey: pubKeyData)
				wrappedKeys.append(["userId": member.userId, "wrappedKey": wrapped])
			}

			// 5. Push to org
			let result = await syncService.pushOrg(
				authToken: authToken,
				orgSlug: orgSlug,
				vaultId: project.id,
				encryptedBlob: blob,
				wrappedKeys: wrappedKeys
			)

			await MainActor.run {
				isSyncing = false
				if let r = result, r.error == nil {
					lastSyncStatus = "Shared with \(orgSlug) (v\(r.version ?? 0))"
					markSynced(project.id, action: "push", version: r.version)
				} else {
					self.error = result?.error ?? "Org push failed"
					lastSyncStatus = "failed"
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

	/// Pull a vault from an org using X25519 decryption.
	func pullFromOrg(orgSlug: String) async {
		guard let project = selectedProject else { return }
		guard let authToken = readCLIAuthToken() else {
			await MainActor.run { error = "Not logged in." }
			return
		}

		await MainActor.run { isSyncing = true; lastSyncStatus = nil }

		do {
			let syncService = SyncService(baseURL: appEnvironment.baseURL)

			// Ensure we have a keypair
			let (privKey, pubKey) = VaultCrypto.getOrCreateX25519Keypair()
			let pubB64 = pubKey.base64EncodedString()
			_ = await syncService.uploadPublicKey(authToken: authToken, publicKey: pubB64)

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
					error = result.error ?? "No vault data on this org."
					isSyncing = false
					lastSyncStatus = "failed"
				}
				return
			}

			guard let wrapped = result.wrappedKey else {
				// Public key was just uploaded but no wrapped key exists yet
				await MainActor.run {
					error = "Your encryption key isn't registered for this vault yet. Your public key has been uploaded — ask an org admin to re-share the vault so it gets wrapped for you."
					isSyncing = false
					lastSyncStatus = "awaiting access"
				}
				return
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

			var updated = project
			var totalKeys = 0

			if let wrapper = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: jsonData),
			   let remoteEnvs = wrapper["environments"] {
				var mergedEnvs = project.environments
				for (envName, remoteSecrets) in remoteEnvs {
					var envSecrets = mergedEnvs[envName] ?? [:]
					envSecrets.merge(remoteSecrets) { _, remote in remote }
					mergedEnvs[envName] = envSecrets
					totalKeys += envSecrets.count
				}
				updated.environments = mergedEnvs
			} else if let remoteSecrets = try? JSONDecoder().decode([String: String].self, from: jsonData) {
				var merged = project.secrets
				merged.merge(remoteSecrets) { _, remote in remote }
				updated.secrets = merged
				totalKeys = merged.count
			} else {
				throw VaultCrypto.CryptoError.invalidUTF8
			}

			let version = result.version ?? 0

			await MainActor.run {
				saveAndUpdate(updated)
				isSyncing = false
				lastSyncStatus = "Pulled from \(orgSlug) (v\(version), \(totalKeys) keys)"
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

	/// Public accessor for the CLI auth token (used by AddProjectSheet).
	func readCLIAuthTokenPublic() -> String? { readCLIAuthToken() }

	/// Read the CLI auth token from Keychain (shared with Rust CLI).
	/// Prioritizes the active environment's token.
	private func readCLIAuthToken() -> String? {
		// Check active environment first, then fallback
		let primary = appEnvironment.keychainAccount
		let fallback = appEnvironment == .production
			? "auth-token:http://localhost:3000"
			: "auth-token:https://lpm.dev"
		let accounts = [primary, fallback]
		for account in accounts {
			let (code, output) = runSecurityCLI(args: [
				"find-generic-password", "-s", VaultConstants.cliAuthService, "-a", account, "-w",
			])
			if code == 0, !output.isEmpty {
				return output
			}
		}
		return nil
	}

	// MARK: - Private

	private func saveAndUpdate(_ project: VaultProject) {
		// Update UI immediately (optimistic)
		updateProjectInPlace(project)

		// Write to Keychain off main thread
		Task.detached { [keychainService, weak self] in
			let result = keychainService.saveEnvironments(
				vaultId: project.id,
				projectName: project.name,
				projectPath: project.path,
				environments: project.environments
			)

			await MainActor.run {
				switch result {
				case .success, .successWithWarning:
					break // Already updated above
				case .failure(let err):
					self?.error = err.description
				}
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
