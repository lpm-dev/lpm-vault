import Foundation
import Testing

@testable import LPMVault

@Suite("VaultStore")
@MainActor
struct VaultStoreTests {
	/// Create a VaultStore with mock dependencies.
	/// Projects are loaded synchronously into `store.projects` so tests
	/// don't need to await the async `loadProjects()` / `Task.detached` path.
	private func makeStore(
		projects: [(id: String, name: String, path: String, secrets: [String: String])] = [],
		biometricShouldSucceed: Bool = true,
		apiService: MockAPIService? = nil,
		envFileImportService: any EnvFileImportServiceProtocol = MockEnvFileImportService()
	) -> (VaultStore, MockKeychainService, MockBiometricService, MockAPIService) {
		let keychain = MockKeychainService()
		for p in projects {
			keychain.storage[p.id] = (name: p.name, path: p.path, secrets: p.secrets)
		}
		let biometric = MockBiometricService()
		biometric.shouldSucceed = biometricShouldSucceed
		let api = apiService ?? MockAPIService()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: biometric,
			apiService: api,
			envFileImportService: envFileImportService,
			authTokenProvider: { _, _ in "session-token" }
		)

		// Pre-populate projects synchronously (the real loadProjects() uses
		// Task.detached for UI responsiveness, but tests need deterministic ordering)
		if !projects.isEmpty {
			store.projects = projects
				.map { VaultProject(id: $0.id, name: $0.name, path: $0.path, environments: ["default": $0.secrets]) }
				.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		}

		return (store, keychain, biometric, api)
	}

	// MARK: - Load

	@Test("load projects from keychain")
	func loadProjects() async throws {
		let keychain = MockKeychainService()
		keychain.storage["id-1"] = (name: "api-server", path: "/tmp/api", secrets: ["DB_HOST": "localhost"])
		keychain.storage["id-2"] = (name: "web-app", path: "/tmp/web", secrets: ["API_KEY": "sk-123"])
		let store = VaultStore(
			keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())

		await store.loadProjects()

		#expect(store.projects.count == 2)
		// Should be sorted alphabetically
		#expect(store.projects[0].name == "api-server")
		#expect(store.projects[1].name == "web-app")
	}

	@Test("load projects from empty keychain")
	func loadEmpty() {
		let (store, _, _, _) = makeStore()
		// Empty store, projects pre-populated as empty
		#expect(store.projects.isEmpty)
	}

	@Test("lock cancels a pending project load")
	func lockCancelsProjectLoad() async throws {
		let keychain = MockKeychainService()
		keychain.storage["id-1"] = (name: "project", path: "", secrets: ["TOKEN": "secret"])
		keychain.listProjectsDelay = .milliseconds(150)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)

		let load = Task { await store.loadProjects() }
		try await Task.sleep(for: .milliseconds(20))
		store.lock()
		_ = await load.value

		#expect(store.projects.isEmpty)
		#expect(!store.isLoadingProjects)
	}

	@Test("unlock waits for the latest project snapshot")
	func unlockWaitsForProjectLoad() async throws {
		let keychain = MockKeychainService()
		keychain.storage["id-1"] = (name: "project", path: "", secrets: ["TOKEN": "secret"])
		keychain.listProjectsDelay = .milliseconds(100)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)

		let unlock = Task { await store.unlock() }
		try await Task.sleep(for: .milliseconds(20))
		#expect(!store.isUnlocked)
		#expect(store.isUnlocking)
		await unlock.value

		#expect(store.isUnlocked)
		#expect(store.projects.first?.secrets["TOKEN"] == "secret")
	}

	// MARK: - Add Project

	@Test("add project creates in keychain and selects it")
	func addProject() async throws {
		let (store, keychain, _, _) = makeStore()

		store.addProject(name: "new-project", path: "/tmp/new")
		// addProject uses Task.detached — give it time to complete
		try await Task.sleep(for: .milliseconds(200))

		#expect(store.projects.count == 1)
		#expect(store.projects[0].name == "new-project")
		#expect(store.projects[0].path == "/tmp/new")
		#expect(store.projects[0].secrets.isEmpty)
		#expect(store.selectedProjectId == store.projects[0].id)
		#expect(keychain.storage.count == 1)
	}

	@Test("add project failure sets error")
	func addProjectFailure() async throws {
		let (store, keychain, _, _) = makeStore()
		keychain.shouldFail = true

		store.addProject(name: "failing-project", path: "/tmp/fail")
		// addProject uses Task.detached — give it time to complete
		try await Task.sleep(for: .milliseconds(200))

		#expect(store.projects.isEmpty)
		#expect(store.error != nil)
	}

	@Test("reserved Keychain accounts cannot be env project IDs")
	func reservedProjectIdsAreRejected() async {
		let (store, keychain, _, _) = makeStore()
		for id in ["__index__", "__sync_metadata__", "__org_associations__", "__x25519_private_key__"] {
			let added = await store.addProjectWithVaultId(
				vaultId: id,
				name: "reserved",
				path: "",
				environments: ["default": [:]]
			)
			#expect(!added)
		}
		#expect(keychain.storage.isEmpty)
	}

	// MARK: - Delete Project

	@Test("delete project removes from list")
	func deleteProject() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: [:])
		])
		store.selectedProjectId = "id-1"

		store.deleteProject(store.projects[0])

		#expect(store.projects.isEmpty)
		#expect(store.selectedProjectId == nil)
	}

	@Test("failed local deletion keeps the env project visible")
	func failedLocalDeletion() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: ["TOKEN": "secret"])
		])
		keychain.shouldFail = true

		let deleted = await store.deleteLocalVault(store.projects[0])

		#expect(!deleted)
		#expect(store.projects.map(\.id) == ["id-1"])
		#expect(keychain.storage["id-1"]?.secrets["TOKEN"] == "secret")
		#expect(store.error != nil)
	}

	@Test("locking during local deletion never republishes decrypted secrets")
	func lockDuringLocalDeletionKeepsMemoryScrubbed() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "one", path: "", secrets: ["ONE": "secret"]),
			(id: "id-2", name: "two", path: "", secrets: ["TWO": "secret"]),
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextDeleteProject = {
			entered.signal()
			release.wait()
		}
		store.isUnlocked = true
		store.selectProject("id-1")

		let deletion = Task { await store.deleteLocalVault(store.projects[0]) }
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.lock()
		release.signal()

		#expect(await deletion.value)
		#expect(!store.isUnlocked)
		#expect(store.projects.allSatisfy { project in
			project.environments.values.allSatisfy(\.isEmpty)
		})
		#expect(keychain.storage["id-1"] == nil)
		#expect(keychain.storage["id-2"]?.secrets["TWO"] == "secret")
	}

	// MARK: - Navigation

	@Test("switching accounts clears an incompatible project but reselecting preserves it")
	func accountSelectionMaintainsNavigationInvariants() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "personal", name: "personal", path: "", secrets: [:]),
			(id: "org", name: "org", path: "", secrets: [:]),
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org": "acme"]
		store.selectProject("personal")
		store.showSettings()

		store.selectAccount(.personal)
		#expect(store.selectedProjectId == "personal")
		#expect(!store.showAuthStatus)

		store.selectAccount(.org("acme"))
		#expect(store.selectedProjectId == nil)
		#expect(store.selectedEnvironment == "default")
	}

	@Test("selected project never crosses the active account boundary")
	func selectedProjectIsAccountScoped() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "personal", name: "personal", path: "", secrets: [:]),
			(id: "org", name: "org", path: "", secrets: [:]),
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org": "acme"]
		store.selectedAccount = .org("acme")
		store.selectedProjectId = "personal"

		#expect(store.selectedProject == nil)
	}

	@Test("global project routing chooses its owning account and exits settings")
	func openProjectRoutesToOwningAccount() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "personal", name: "personal", path: "", secrets: [:]),
			(id: "org", name: "org", path: "", secrets: [:]),
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org": "acme"]

		store.showSettings()
		store.openProject(id: "org")
		#expect(store.selectedAccount == .org("acme"))
		#expect(store.selectedProjectId == "org")
		#expect(!store.showAuthStatus)

		store.openProject(id: "personal")
		#expect(store.selectedAccount == .personal)
		#expect(store.selectedProjectId == "personal")
	}

	@Test("project routing preserves a shared environment and repairs an invalid one")
	func projectSelectionNormalizesEnvironment() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "one", name: "one", path: "", secrets: [:]),
			(id: "two", name: "two", path: "", secrets: [:]),
		])
		store.projects[0].environments = ["default": [:], "staging": [:]]
		store.projects[1].environments = ["production": [:], "staging": [:]]

		store.selectProject("one")
		store.selectEnvironment("staging")
		store.selectProject("two")
		#expect(store.selectedEnvironment == "staging")

		store.selectEnvironment("production")
		store.selectProject("one")
		#expect(store.selectedEnvironment == "default")
	}

	@Test("removing an active project never selects another account")
	func removalFallbackIsAccountScoped() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "personal", name: "a-personal", path: "", secrets: [:]),
			(id: "org-one", name: "b-org", path: "", secrets: [:]),
			(id: "org-two", name: "c-org", path: "", secrets: [:]),
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org-one": "acme", "org-two": "acme"]
		store.openProject(id: "org-one")

		store.removeFromSidebar(store.projects.first { $0.id == "org-one" }!)

		#expect(store.selectedAccount == .org("acme"))
		#expect(store.selectedProjectId == "org-two")
		#expect(store.selectedProject?.id == "org-two")
	}

	@Test("account switching cancels pending dotenv work for the previous project")
	func accountSwitchCancelsPendingImport() async {
		let importer = MockEnvFileImportService()
		await importer.enableGate()
		let (store, _, _, _) = makeStore(
			projects: [
				(id: "personal", name: "personal", path: "", secrets: [:]),
				(id: "org", name: "org", path: "", secrets: [:]),
			],
			envFileImportService: importer
		)
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org": "acme"]
		store.isUnlocked = true
		store.selectProject("personal")

		let importTask = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/account-switch.env"),
				to: "personal",
				environment: "default"
			)
		}
		while !(await importer.hasStarted("account-switch.env")) { await Task.yield() }
		store.selectAccount(.org("acme"))
		await importer.resolve(
			"account-switch.env",
			with: .success(ImportedEnvFile(secrets: ["STALE": "secret"]))
		)

		#expect(await importTask.value == .failure(.cancelled))
		#expect(store.selectedProjectId == nil)
		#expect(store.projects.first { $0.id == "personal" }?.secrets.isEmpty == true)
	}

	@Test("logout removes an invalid organization route")
	func logoutNormalizesOrganizationNavigation() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "org", name: "org", path: "", secrets: [:])
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org": "acme"]
		store.openProject(id: "org")

		store.logout()

		#expect(store.selectedAccount == .personal)
		#expect(store.selectedProjectId == nil)
		#expect(store.selectedProject == nil)
	}

	@Test("successful deletion fallback stays in the current account")
	func deletionFallbackIsAccountScoped() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "personal", name: "a-personal", path: "", secrets: [:]),
			(id: "org-one", name: "b-org", path: "", secrets: [:]),
			(id: "org-two", name: "c-org", path: "", secrets: [:]),
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org-one": "acme", "org-two": "acme"]
		keychain.dataStorage["__org_associations__"] = try! JSONEncoder().encode(
			store.vaultOrgAssociations
		)
		store.isUnlocked = true
		store.openProject(id: "org-one")

		let deleted = await store.deleteLocalVault(store.projects.first { $0.id == "org-one" }!)

		#expect(deleted)
		#expect(store.selectedAccount == .org("acme"))
		#expect(store.selectedProjectId == "org-two")
		#expect(store.selectedProject?.id == "org-two")
	}

	@Test("only user navigation restarts the auto-lock timer")
	func navigationOwnsAutoLockReset() async {
		let sleeper = AutoLockSleeper()
		let keychain = MockKeychainService()
		keychain.storage["id-1"] = (name: "one", path: "", secrets: [:])
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) }
		)

		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		store.reconcileNavigationState()
		for _ in 0..<10 { await Task.yield() }
		#expect(await sleeper.count == 1)

		store.selectProject("id-1")
		while await sleeper.count < 2 { await Task.yield() }
		await sleeper.resume(at: 0)
		for _ in 0..<10 { await Task.yield() }
		#expect(store.isUnlocked)

		await sleeper.resume(at: 1)
		while store.isUnlocked { await Task.yield() }
		#expect(!store.isUnlocked)
	}

	// MARK: - Add Secret

	@Test("add secret to project")
	func addSecret() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])

		store.addSecret(to: "id-1", key: "DB_HOST", value: "localhost")

		// In-memory update is synchronous
		#expect(store.projects[0].secrets["DB_HOST"] == "localhost")
		// Keychain write is async (Task.detached in saveAndUpdate)
		try await Task.sleep(for: .milliseconds(200))
		#expect(keychain.storage["id-1"]?.secrets["DB_HOST"] == "localhost")
	}

	@Test("add secret with empty key is rejected")
	func addSecretEmptyKey() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])

		store.addSecret(to: "id-1", key: "", value: "value")

		#expect(store.projects[0].secrets.isEmpty)
	}

	@Test("add secret rejects names outside the Rust env contract")
	func addSecretInvalidNames() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])

		for key in ["1LEADING", "WITH-DASH", "WITH SPACE", "ÉNV"] {
			store.addSecret(to: "id-1", key: key, value: "value")
		}

		#expect(store.projects[0].secrets.isEmpty)
	}

	@Test("environment writes reject the reserved index name")
	func addReservedEnvironment() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])

		store.isUnlocked = true
		store.selectedProjectId = "id-1"
		await store.addEnvironment(to: "id-1", name: "__index__")

		#expect(store.projects[0].environments["__index__"] == nil)
	}

	@Test("local dotenv import persists into the captured environment before publishing")
	func localEnvImportCommitsCapturedEnvironment() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])],
			envFileImportService: importer
		)
		store.selectedProjectId = "id-1"
		store.selectedEnvironment = "default"
		store.isUnlocked = true

		let result = await store.importEnvFile(
			at: URL(fileURLWithPath: "/tmp/import.env"),
			to: "id-1",
			environment: "default"
		)

		#expect(result == .success(ImportedEnvFile(secrets: ["IMPORTED": "value"])))
		#expect(store.projects[0].secrets == ["OLD": "value", "IMPORTED": "value"])
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value", "IMPORTED": "value"])
	}

	@Test("tab changes cancel a pending dotenv import instead of redirecting it")
	func localEnvImportCannotFollowTabSelection() async {
		let importer = MockEnvFileImportService()
		await importer.enableGate()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])],
			envFileImportService: importer
		)
		store.projects[0].environments["staging"] = [:]
		keychain.envStorage["id-1"]?.environments["staging"] = [:]
		store.selectedProjectId = "id-1"
		store.selectedEnvironment = "default"
		store.isUnlocked = true

		let task = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/slow.env"),
				to: "id-1",
				environment: "default"
			)
		}
		while !(await importer.hasStarted("slow.env")) { await Task.yield() }
		store.selectedEnvironment = "staging"
		await importer.resolve("slow.env", with: .success(ImportedEnvFile(secrets: ["STALE": "secret"])))

		#expect(await task.value == .failure(.cancelled))
		#expect(store.projects[0].environments["default"] == ["OLD": "value"])
		#expect(store.projects[0].environments["staging"]?.isEmpty == true)
		#expect(keychain.envStorage["id-1"]?.environments["default"] == ["OLD": "value"])
	}

	@Test("a newer dotenv import supersedes an older request to the same destination")
	func newestLocalEnvImportWins() async {
		let importer = MockEnvFileImportService()
		await importer.enableGate()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: [:])],
			envFileImportService: importer
		)
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let older = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/older.env"),
				to: "id-1", environment: "default"
			)
		}
		while !(await importer.hasStarted("older.env")) { await Task.yield() }
		let newer = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/newer.env"),
				to: "id-1", environment: "default"
			)
		}
		while !(await importer.hasStarted("newer.env")) { await Task.yield() }

		await importer.resolve("newer.env", with: .success(ImportedEnvFile(secrets: ["KEY": "new"])))
		await importer.resolve("older.env", with: .success(ImportedEnvFile(secrets: ["KEY": "old"])))

		#expect(await newer.value == .success(ImportedEnvFile(secrets: ["KEY": "new"])))
		#expect(await older.value == .failure(.cancelled))
		#expect(store.projects[0].secrets["KEY"] == "new")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
	}

	@Test("superseding a dotenv import before its commit point leaves no stale durable keys")
	func supersededLocalEnvImportCannotCommit() async {
		let importer = MockEnvFileImportService()
		await importer.enableGate()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: [:])],
			envFileImportService: importer
		)
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextListProjects = {
			entered.signal()
			release.wait()
		}
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let older = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/stale.env"),
				to: "id-1", environment: "default"
			)
		}
		while !(await importer.hasStarted("stale.env")) { await Task.yield() }
		await importer.resolve(
			"stale.env",
			with: .success(ImportedEnvFile(secrets: ["STALE_ONLY": "old"]))
		)
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}

		let newer = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/fresh.env"),
				to: "id-1", environment: "default"
			)
		}
		while !(await importer.hasStarted("fresh.env")) { await Task.yield() }
		await importer.resolve(
			"fresh.env",
			with: .success(ImportedEnvFile(secrets: ["FRESH_ONLY": "new"]))
		)
		release.signal()

		#expect(await older.value == .failure(.cancelled))
		#expect(await newer.value == .success(
			ImportedEnvFile(secrets: ["FRESH_ONLY": "new"])
		))
		#expect(store.projects[0].secrets == ["FRESH_ONLY": "new"])
		#expect(keychain.storage["id-1"]?.secrets == ["FRESH_ONLY": "new"])
	}

	@Test("locking during dotenv parsing cannot republish decrypted values")
	func lockCancelsLocalEnvImport() async {
		let importer = MockEnvFileImportService()
		await importer.enableGate()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])],
			envFileImportService: importer
		)
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let task = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/locked.env"),
				to: "id-1", environment: "default"
			)
		}
		while !(await importer.hasStarted("locked.env")) { await Task.yield() }
		store.lock()
		await importer.resolve("locked.env", with: .success(ImportedEnvFile(secrets: ["STALE": "secret"])))

		#expect(await task.value == .failure(.cancelled))
		#expect(store.projects[0].secrets.isEmpty)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
	}

	@Test("rollback failure after lock never reloads plaintext into memory")
	func rollbackFailureAfterLockKeepsMemoryCleared() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])],
			envFileImportService: importer
		)
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		keychain.failWriteDataAccounts = ["__sync_metadata__"]
		keychain.failRestoreSaveEnvironments = true
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let task = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/rollback.env"),
				to: "id-1", environment: "default"
			)
		}
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.lock()
		release.signal()

		guard case .failure(.persistence) = await task.value else {
			Issue.record("Expected rollback persistence failure")
			return
		}
		#expect(!store.isUnlocked)
		#expect(store.projects[0].environments.values.allSatisfy { $0.isEmpty })
	}

	@Test("dotenv persistence failure preserves memory and Keychain snapshots")
	func localEnvImportRollsBackOnPersistenceFailure() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])],
			envFileImportService: importer
		)
		store.selectedProjectId = "id-1"
		store.isUnlocked = true
		keychain.shouldFail = true

		let result = await store.importEnvFile(
			at: URL(fileURLWithPath: "/tmp/failure.env"),
			to: "id-1", environment: "default"
		)

		guard case .failure(.persistence) = result else {
			Issue.record("Expected persistence failure")
			return
		}
		#expect(store.projects[0].secrets == ["OLD": "value"])
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
	}

	@Test("new-environment import rejects encoded Keychain overflow without publishing")
	func newEnvironmentImportHonorsEncodedLimit() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "", secrets: [:])
		])

		store.isUnlocked = true
		store.selectedProjectId = "id-1"
		let added = await store.addEnvironment(
			to: "id-1",
			name: "large",
			secrets: ["VALUE": String(repeating: "x", count: VaultConstants.maxVaultSizeWarning)]
		)

		#expect(!added)
		#expect(store.projects[0].environments["large"] == nil)
		#expect(keychain.envStorage["id-1"]?.environments["large"] == nil)
	}

	@Test("lock during new-environment persistence cannot republish preview secrets")
	func lockDuringNewEnvironmentCommit() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let creation = Task {
			await store.addEnvironment(
				to: "id-1", name: "staging", secrets: ["PREVIEW": "secret"]
			)
		}
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.lock()
		release.signal()

		#expect(await creation.value)
		#expect(!store.isUnlocked)
		#expect(store.projects[0].environments["staging"] == nil)
		#expect(store.projects[0].secrets.isEmpty)
		#expect(keychain.envStorage["id-1"]?.environments["staging"] == ["PREVIEW": "secret"])
	}

	@Test("project switch during new-environment persistence does not change current selection")
	func selectionChangeDuringNewEnvironmentCommit() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "one", path: "", secrets: [:]),
			(id: "id-2", name: "two", path: "", secrets: [:]),
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let creation = Task {
			await store.addEnvironment(
				to: "id-1", name: "staging", secrets: ["PREVIEW": "secret"]
			)
		}
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.selectedProjectId = "id-2"
		release.signal()

		#expect(await creation.value)
		#expect(store.selectedProjectId == "id-2")
		#expect(store.selectedEnvironment == "default")
		#expect(store.projects.first(where: { $0.id == "id-1" })?.environments["staging"] == nil)
		#expect(keychain.envStorage["id-1"]?.environments["staging"] == ["PREVIEW": "secret"])
	}

	@Test("sidebar removal during new-environment persistence does not reinsert the project")
	func removalDuringNewEnvironmentCommit() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "", secrets: [:])
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let creation = Task {
			await store.addEnvironment(
				to: "id-1", name: "staging", secrets: ["PREVIEW": "secret"]
			)
		}
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.removeFromSidebar(store.projects[0])
		release.signal()

		#expect(await creation.value)
		#expect(store.projects.isEmpty)
		#expect(keychain.envStorage["id-1"]?.environments["staging"] == ["PREVIEW": "secret"])
	}

	@Test("project switches cancel a pending new-environment preview")
	func projectSwitchCancelsEnvFilePreview() async {
		let importer = MockEnvFileImportService()
		await importer.enableGate()
		let (store, _, _, _) = makeStore(
			projects: [
				(id: "id-1", name: "one", path: "", secrets: [:]),
				(id: "id-2", name: "two", path: "", secrets: [:]),
			],
			envFileImportService: importer
		)
		store.selectedProjectId = "id-1"
		store.isUnlocked = true

		let preview = Task {
			await store.loadEnvFilePreview(
				at: URL(fileURLWithPath: "/tmp/project-one.env"),
				for: "id-1"
			)
		}
		while !(await importer.hasStarted("project-one.env")) { await Task.yield() }
		store.selectedProjectId = "id-2"
		await importer.resolve(
			"project-one.env",
			with: .success(ImportedEnvFile(secrets: ["PROJECT_ONE": "secret"]))
		)

		#expect(await preview.value == .failure(.cancelled))
		#expect(store.selectedProjectId == "id-2")
	}

	@Test("add secret to non-existent project is no-op")
	func addSecretNoProject() {
		let (store, _, _, _) = makeStore()

		store.addSecret(to: "nonexistent", key: "KEY", value: "VALUE")

		#expect(store.projects.isEmpty)
	}

	// MARK: - Update Secret

	@Test("update existing secret")
	func updateSecret() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])

		store.updateSecret(in: "id-1", key: "KEY", newValue: "new")

		#expect(store.projects[0].secrets["KEY"] == "new")
		try await Task.sleep(for: .milliseconds(200))
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
	}

	@Test("update non-existent key is no-op")
	func updateNonExistentKey() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "val"])
		])

		store.updateSecret(in: "id-1", key: "MISSING", newValue: "new")

		#expect(store.projects[0].secrets["KEY"] == "val")
		#expect(store.projects[0].secrets["MISSING"] == nil)
	}

	// MARK: - Delete Secret

	@Test("delete secret from project")
	func deleteSecret() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["A": "1", "B": "2"])
		])

		store.deleteSecret(from: "id-1", key: "A")

		#expect(store.projects[0].secrets["A"] == nil)
		#expect(store.projects[0].secrets["B"] == "2")
		try await Task.sleep(for: .milliseconds(200))
		#expect(keychain.storage["id-1"]?.secrets["A"] == nil)
	}

	// MARK: - Search

	@Test("search filters projects by name")
	func searchByName() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "api-server", path: "/tmp/api", secrets: [:]),
			(id: "id-2", name: "web-app", path: "/tmp/web", secrets: [:]),
		])

		store.searchQuery = "api"

		#expect(store.filteredVaults.count == 1)
		#expect(store.filteredVaults[0].name == "api-server")
	}

	@Test("search filters by secret key name")
	func searchBySecretKey() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: ["DATABASE_URL": "pg://..."]),
			(
				id: "id-2", name: "project-b", path: "/tmp/b",
				secrets: ["API_KEY": "sk-123"]
			),
		])

		store.searchQuery = "database"

		#expect(store.filteredVaults.count == 1)
		#expect(store.filteredVaults[0].name == "project-a")
	}

	@Test("empty search shows all projects")
	func emptySearch() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "a", path: "/tmp/a", secrets: [:]),
			(id: "id-2", name: "b", path: "/tmp/b", secrets: [:]),
		])

		store.searchQuery = ""

		#expect(store.filteredVaults.count == 2)
	}

	// MARK: - Auth

	@Test("unlock sets isUnlocked on success")
	func unlockSuccess() async {
		let (store, _, biometric, _) = makeStore(biometricShouldSucceed: true)

		await store.unlock()

		#expect(store.isUnlocked == true)
		#expect(biometric.authenticateCallCount == 1)
	}

	@Test("unlock stays locked on cancel")
	func unlockCancel() async {
		let (store, _, biometric, _) = makeStore(biometricShouldSucceed: false)

		await store.unlock()

		#expect(store.isUnlocked == false)
		#expect(biometric.authenticateCallCount == 1)
	}

	@Test("lock resets isUnlocked")
	func lock() async {
		let (store, _, _, _) = makeStore(biometricShouldSucceed: true)

		await store.unlock()
		#expect(store.isUnlocked == true)

		store.lock()
		#expect(store.isUnlocked == false)
	}

	// MARK: - Selected Project

	@Test("selectedProject returns correct project")
	func selectedProject() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: [:]),
			(id: "id-2", name: "project-b", path: "/tmp/b", secrets: [:]),
		])
		await store.loadProjects()
		store.selectedProjectId = "id-2"

		#expect(store.selectedProject?.name == "project-b")
	}

	@Test("selectedProject returns nil when nothing selected")
	func noSelectedProject() async {
		let (store, _, _, _) = makeStore()
		await store.loadProjects()

		#expect(store.selectedProject == nil)
	}

	// MARK: - Token Operations

	@Test("a newer token load wins and owns the loading flag")
	func newerTokenLoadWins() async throws {
		let api = MockAPIService()
		let oldLoadGate = AsyncGate()
		api.blockNextCurrentUserFetch = { await oldLoadGate.arriveAndWait() }
		api.userResponses = [
			(delay: nil, user: testUser(id: "old", username: "old")),
			(delay: nil, user: testUser(id: "new", username: "new")),
		]
		api.personalTokenResponses = [
			(delay: .milliseconds(150), tokens: []),
			(delay: .milliseconds(100), tokens: []),
		]
		let (store, _, _, _) = makeStore(apiService: api)

		let oldLoad = Task { await store.loadTokens() }
		await oldLoadGate.waitUntilArrived()
		let newLoad = Task { await store.loadTokens() }
		try await Task.sleep(for: .milliseconds(40))
		#expect(store.isLoadingTokens)
		await newLoad.value
		#expect(store.currentUser?.username == "new")
		#expect(!store.isLoadingTokens)
		await oldLoadGate.release()
		await oldLoad.value
		#expect(store.currentUser?.username == "new")
	}

	@Test("logout invalidates a pending token load")
	func logoutInvalidatesTokenLoad() async throws {
		let api = MockAPIService()
		api.user = testUser(id: "u1", username: "late")
		api.delay = .milliseconds(150)
		let (store, _, _, _) = makeStore(apiService: api)

		let load = Task { await store.loadTokens() }
		try await Task.sleep(for: .milliseconds(20))
		store.logout()
		await load.value

		#expect(store.currentUser == nil)
		#expect(store.personalTokens.isEmpty)
		#expect(!store.isLoadingTokens)
	}

	@Test("load tokens populates user and personal tokens")
	func loadTokens() async {
		let api = MockAPIService()
		api.user = LPMUser(
			id: "u1", username: "tolga", name: "Tolga",
			email: "t@lpm.dev", avatarUrl: nil, plan: "pro",
			createdAt: nil, orgs: [LPMOrg(id: "o1", slug: "acme", name: "Acme", avatarUrl: nil, role: "owner")]
		)
		api.personalTokens = [
			LPMToken(id: "t1", name: "ci-deploy", scope: "publish", expiresAt: nil,
				lastUsedAt: nil, downloadCount: 5, createdAt: nil),
			LPMToken(id: "t2", name: "local-dev", scope: "read", expiresAt: nil,
				lastUsedAt: nil, downloadCount: 0, createdAt: nil),
		]
		api.orgTokensMap["acme"] = [
			LPMToken(id: "ot1", name: "prod-key", scope: "publish", expiresAt: nil,
				lastUsedAt: nil, downloadCount: 10, createdAt: nil)
		]

		let (store, _, _, _) = makeStore(apiService: api)
		await store.loadTokens()

		#expect(store.isLoggedIn == true)
		#expect(store.currentUser?.username == "tolga")
		#expect(store.personalTokens.count == 2)
		#expect(store.userOrgs.count == 1)
		#expect(store.orgTokens["acme"]?.count == 1)
	}

	@Test("load tokens with no auth sets nil user")
	func loadTokensNoAuth() async {
		let api = MockAPIService()
		api.user = nil

		let (store, _, _, _) = makeStore(apiService: api)
		await store.loadTokens()

		#expect(store.isLoggedIn == false)
		#expect(store.personalTokens.isEmpty)
	}

	@Test("token inventory captures one bearer for every request")
	func tokenInventoryCapturesOneBearer() async {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 6)
		let keychain = MockKeychainService()
		let biometric = MockBiometricService()
		let providerCalls = LockedCounter()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: biometric,
			apiService: api,
			authTokenProvider: { _, _ in
				providerCalls.increment()
				return "captured-bearer"
			}
		)

		await store.loadTokens()

		// One acquisition starts the operation; one commit-time read verifies
		// that an external CLI login did not replace the session mid-load.
		#expect(providerCalls.value == 2)
		#expect(api.receivedAuthTokens.count == 8)
		#expect(Set(api.receivedAuthTokens) == ["captured-bearer"])
	}

	@Test("a replaced session cannot publish an old identity inventory")
	func replacedSessionCannotPublishInventory() async {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 1)
		api.orgTokensDelay = .milliseconds(30)
		let session = SequencedAuthTokenProvider(tokens: ["old-bearer", "new-bearer"])
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in session.next() }
		)
		store.currentUser = testUser(id: "previous", username: "previous")

		await store.loadTokens()

		#expect(Set(api.receivedAuthTokens) == ["old-bearer"])
		#expect(store.currentUser?.username == "previous")
		#expect(store.error?.contains("session changed") == true)
	}

	@Test("organization token inventory uses a four-request sliding window")
	func organizationTokenInventoryIsBounded() async {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 12)
		api.orgTokensDelay = .milliseconds(30)
		for index in 0..<12 {
			api.orgTokensMap["org-\(index)"] = [testToken(id: "token-\(index)")]
		}
		let (store, _, _, _) = makeStore(apiService: api)

		await store.loadTokens()

		#expect(api.maximumActiveOrgRequests == 4)
		#expect(api.requestedOrgSlugs.count == 12)
		#expect(store.orgTokens.count == 12)
		for index in 0..<12 {
			#expect(store.orgTokens["org-\(index)"]?.first?.id == "token-\(index)")
		}
	}

	@Test("token inventory skips organization roles rejected by the server")
	func tokenInventorySkipsUnauthorizedOrganizationRoles() async {
		let api = MockAPIService()
		api.user = LPMUser(
			id: "u1", username: "user", name: nil, email: nil,
			avatarUrl: nil, plan: nil, createdAt: nil,
			orgs: [
				LPMOrg(id: "1", slug: "owned", name: "Owned", avatarUrl: nil, role: "owner"),
				LPMOrg(id: "2", slug: "admin", name: "Admin", avatarUrl: nil, role: "admin"),
				LPMOrg(id: "3", slug: "member", name: "Member", avatarUrl: nil, role: "member"),
				LPMOrg(id: "4", slug: "maintainer", name: "Maintainer", avatarUrl: nil, role: "maintainer"),
			]
		)
		let (store, _, _, _) = makeStore(apiService: api)

		await store.loadTokens()

		#expect(Set(api.requestedOrgSlugs) == ["owned", "admin"])
		#expect(store.userOrgs.count == 4)
	}

	@Test("a failed organization request preserves the prior coherent inventory")
	func failedOrganizationInventoryPreservesPriorState() async {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 2)
		api.personalTokens = [testToken(id: "old-personal")]
		api.orgTokensMap["org-0"] = [testToken(id: "old-org")]
		let (store, _, _, _) = makeStore(apiService: api)
		await store.loadTokens()
		api.personalTokens = [testToken(id: "new-personal")]
		api.orgTokenErrors["org-1"] = .transport

		await store.loadTokens()

		#expect(store.personalTokens.first?.id == "old-personal")
		#expect(store.orgTokens["org-0"]?.first?.id == "old-org")
		#expect(store.error == LPMAPIError.transport.localizedDescription)
	}

	@Test("cancelling token inventory stops admitting organization requests")
	func cancellingInventoryStopsAdmission() async throws {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 1_000)
		api.orgTokensDelay = .seconds(1)
		let (store, _, _, _) = makeStore(apiService: api)

		let load = Task { await store.loadTokens() }
		try await Task.sleep(for: .milliseconds(30))
		store.logout()
		await load.value

		#expect(api.maximumActiveOrgRequests <= 4)
		#expect(api.requestedOrgSlugs.count <= 4)
		#expect(store.currentUser == nil)
		#expect(!store.isLoadingTokens)
	}

	@Test("API service factory retains one session per exact environment")
	func apiServiceFactoryIsEnvironmentScoped() async {
		let factory = MockAPIServiceFactory()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiServiceFactory: { factory.make(baseURL: $0) },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.appEnvironment = .production

		await store.loadTokens()
		await store.loadTokens()
		#expect(factory.count(for: VaultConstants.apiBaseURL) == 1)

		#if DEBUG
		store.switchEnvironment(to: .development)
		try? await Task.sleep(for: .milliseconds(20))
		await store.loadTokens()
		#expect(factory.count(for: VaultConstants.localAPIBaseURL) == 1)
		#expect(factory.count(for: VaultConstants.apiBaseURL) == 1)
		#expect(Set(factory.urls) == [VaultConstants.apiBaseURL, VaultConstants.localAPIBaseURL])
		#endif
	}

	#if DEBUG
	@Test("switching environment during login cannot persist the old session")
	func environmentSwitchInvalidatesLogin() async throws {
		let gate = AsyncGate()
		let writes = StringRecorder()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil },
			loginProvider: { registryURL, _ in
				#expect(registryURL == VaultConstants.apiBaseURL.absoluteString)
				await gate.arriveAndWait()
				return testAuthCredentials()
			},
			authSessionWriter: { _, registryURL in writes.append(registryURL) },
			authSessionClearer: { _ in }
		)
		store.appEnvironment = .production

		let login = Task { await store.login() }
		await gate.waitUntilArrived()
		store.switchEnvironment(to: .development)
		await gate.release()
		await login.value

		#expect(writes.values.isEmpty)
		#expect(store.appEnvironment == .development)
		#expect(!store.isLoggingIn)
	}

	@Test("environment switches discard personal and organization revocations")
	func environmentSwitchInvalidatesRevocations() async throws {
		let api = MockAPIService()
		api.personalRevokeDelay = .milliseconds(150)
		api.orgRevokeDelay = .milliseconds(150)
		let personalStarted = AsyncSignal()
		let organizationStarted = AsyncSignal()
		api.onPersonalRevokeStart = { Task { await personalStarted.send() } }
		api.onOrgRevokeStart = { Task { await organizationStarted.send() } }
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { registryURL, _ in registryURL },
			authSessionClearer: { _ in }
		)
		store.appEnvironment = .production
		let personal = testToken(id: "personal")
		let organization = testToken(id: "organization")
		store.personalTokens = [personal]
		store.orgTokens = ["acme": [organization]]

		let personalRevoke = Task { await store.revokePersonalToken(personal) }
		await personalStarted.wait()
		store.switchEnvironment(to: .development)
		try await Task.sleep(for: .milliseconds(20))
		store.personalTokens = [personal]
		await personalRevoke.value
		#expect(store.personalTokens.map(\.id) == [personal.id])

		store.switchEnvironment(to: .production)
		try await Task.sleep(for: .milliseconds(20))
		store.orgTokens = ["acme": [organization]]
		let organizationRevoke = Task {
			await store.revokeOrgToken(organization, orgSlug: "acme")
		}
		await organizationStarted.wait()
		store.switchEnvironment(to: .development)
		try await Task.sleep(for: .milliseconds(20))
		store.orgTokens = ["acme": [organization]]
		await organizationRevoke.value
		#expect(store.orgTokens["acme"]?.map(\.id) == [organization.id])
	}
	#endif

	@Test("logout clears only the active environment session")
	func logoutIsEnvironmentScoped() {
		let cleared = StringRecorder()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil },
			authSessionClearer: { cleared.append($0) }
		)
		store.appEnvironment = .production

		store.logout()

		#expect(cleared.values == [VaultConstants.apiBaseURL.absoluteString])
	}

	@Test("expiring tokens filters correctly")
	func expiringTokens() async {
		let api = MockAPIService()
		api.user = LPMUser(
			id: "u1", username: "test", name: nil, email: nil,
			avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)

		let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400))
		let far = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60 * 86400))

		api.personalTokens = [
			LPMToken(id: "t1", name: "expiring", scope: nil, expiresAt: soon,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
			LPMToken(id: "t2", name: "healthy", scope: nil, expiresAt: far,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
			LPMToken(id: "t3", name: "no-expiry", scope: nil, expiresAt: nil,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
		]

		let (store, _, _, _) = makeStore(apiService: api)
		await store.loadTokens()

		#expect(store.expiringTokens.count == 1)
		#expect(store.expiringTokens[0].name == "expiring")
	}

	@Test("revoke personal token removes from list")
	func revokePersonalToken() async {
		let api = MockAPIService()
		api.user = LPMUser(
			id: "u1", username: "test", name: nil, email: nil,
			avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
		api.personalTokens = [
			LPMToken(id: "t1", name: "to-revoke", scope: nil, expiresAt: nil,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
			LPMToken(id: "t2", name: "keep", scope: nil, expiresAt: nil,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
		]

		let (store, _, _, _) = makeStore(apiService: api)
		await store.loadTokens()
		#expect(store.personalTokens.count == 2)

		await store.revokePersonalToken(store.personalTokens[0])

		#expect(store.personalTokens.count == 1)
		#expect(store.personalTokens[0].name == "keep")
		#expect(api.revokedTokenIds.contains("t1"))
	}

	@Test("revoke personal token cannot be undone by an older inventory load")
	func revokePersonalTokenInvalidatesOlderInventory() async throws {
		let api = MockAPIService()
		api.user = testUser(id: "u1", username: "test")
		let revoked = testToken(id: "t1")
		api.personalTokenResponses = [(.milliseconds(100), [revoked])]
		let (store, _, _, _) = makeStore(apiService: api)
		store.personalTokens = [revoked]

		let load = Task { await store.loadTokens() }
		try await Task.sleep(for: .milliseconds(20))
		await store.revokePersonalToken(revoked)
		await load.value

		#expect(store.personalTokens.isEmpty)
		#expect(api.revokedTokenIds == ["t1"])
	}

	@Test("revoke org token removes from org list")
	func revokeOrgToken() async {
		let api = MockAPIService()
		api.user = LPMUser(
			id: "u1", username: "test", name: nil, email: nil,
			avatarUrl: nil, plan: nil, createdAt: nil,
			orgs: [LPMOrg(id: "o1", slug: "acme", name: "Acme", avatarUrl: nil, role: "admin")]
		)
		api.orgTokensMap["acme"] = [
			LPMToken(id: "ot1", name: "org-token", scope: nil, expiresAt: nil,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil)
		]

		let (store, _, _, _) = makeStore(apiService: api)
		await store.loadTokens()
		#expect(store.orgTokens["acme"]?.count == 1)

		await store.revokeOrgToken(store.orgTokens["acme"]![0], orgSlug: "acme")

		#expect(store.orgTokens["acme"]?.isEmpty == true)
		#expect(api.revokedTokenIds.contains("ot1"))
	}

	// MARK: - Org Key Trust (Strict Mode)

	@Test("reject pending org push clears state and sets error")
	func rejectPendingOrgPush() {
		let (store, _, _, _) = makeStore()
		store.pendingOrgPush = PendingOrgPush(
			orgSlug: "acme",
			projectId: "p1",
			allMembers: [],
			pendingApprovals: [],
			orgTrust: OrgKeyTrust(),
			authToken: "tok",
			canReplaceWrappedKeys: true
		)
		store.showKeyApprovalSheet = true

		store.rejectPendingOrgPush()

		#expect(store.pendingOrgPush == nil)
		#expect(store.showKeyApprovalSheet == false)
		#expect(store.lastSyncStatus == "rejected")
		#expect(store.error != nil)
	}

	@Test("security transitions discard pending organization authorization")
	func securityTransitionsDiscardPendingOrgAuthorization() {
		let (store, _, _, _) = makeStore()
		func seedApproval() {
			store.pendingOrgPush = PendingOrgPush(
				orgSlug: "acme",
				projectId: "p1",
				allMembers: [],
				pendingApprovals: [],
				orgTrust: OrgKeyTrust(),
				authToken: "retained-token",
				canReplaceWrappedKeys: true
			)
			store.showKeyApprovalSheet = true
		}

		seedApproval()
		store.logout()
		#expect(store.pendingOrgPush == nil)
		#expect(!store.showKeyApprovalSheet)

		seedApproval()
		store.lock()
		#expect(store.pendingOrgPush == nil)
		#expect(!store.showKeyApprovalSheet)

		#if DEBUG
		seedApproval()
		store.appEnvironment = .production
		store.switchEnvironment(to: .development)
		#expect(store.pendingOrgPush == nil)
		#expect(!store.showKeyApprovalSheet)
		#endif
	}

	@Test("lock invalidates organization sharing during member-key lookup")
	func lockInvalidatesInFlightOrganizationPush() async {
		await verifyInFlightOrgPushIsInvalidated(by: .lock)
	}

	@Test("logout invalidates organization sharing during member-key lookup")
	func logoutInvalidatesInFlightOrganizationPush() async {
		await verifyInFlightOrgPushIsInvalidated(by: .logout)
	}

	@Test("account changes invalidate organization sharing during member-key lookup")
	func accountChangeInvalidatesInFlightOrganizationPush() async {
		await verifyInFlightOrgPushIsInvalidated(by: .accountChange)
	}

	#if DEBUG
	@Test("server changes invalidate organization sharing during member-key lookup")
	func serverChangeInvalidatesInFlightOrganizationPush() async {
		await verifyInFlightOrgPushIsInvalidated(by: .serverChange)
	}
	#endif

	@Test("session replacement invalidates organization sharing during member-key lookup")
	func tokenReplacementInvalidatesInFlightOrganizationPush() async {
		await verifyInFlightOrgPushIsInvalidated(by: .tokenReplacement)
	}

	@Test("session replacement suppresses a stale personal pull")
	func tokenReplacementSuppressesStalePersonalPull() async {
		let gate = AsyncGate()
		let token = MutableString("session-token")
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [{
			await gate.arriveAndWait()
			return nil
		}]
		let projectId = "personal-pull"
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			authTokenProvider: { _, _ in token.value }
		)
		store.projects = [VaultProject(
			id: projectId,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.isUnlocked = true
		store.selectProject(projectId)

		let pull = Task { await store.pullFromCloud() }
		await gate.waitUntilArrived()
		token.value = "replacement-token"
		await gate.release()
		await pull.value

		#expect(store.projects.first?.secrets["TOKEN"] == "local")
		#expect(store.syncMetadata[projectId] == nil)
		#expect(store.lastSyncStatus == nil)
		#expect(!store.isSyncing)
	}

	@Test("account changes suppress a stale organization pull")
	func accountChangeSuppressesStaleOrganizationPull() async {
		let slug = "org-pull-\(UUID().uuidString.lowercased())"
		let projectId = "organization-pull"
		let keypair = VaultCrypto.generateX25519Keypair()
		let gate = AsyncGate()
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		sync.blockNextPull = { await gate.arriveAndWait() }
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = userWithOrganization(slug: slug)
		store.projects = [VaultProject(
			id: projectId,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.vaultOrgAssociations[projectId] = slug
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectId)

		let pull = Task { await store.pullFromOrg(orgSlug: slug) }
		await gate.waitUntilArrived()
		store.selectAccount(.personal)
		await gate.release()
		await pull.value

		#expect(store.projects.first?.secrets["TOKEN"] == "local")
		#expect(store.syncMetadata[projectId] == nil)
		#expect(store.lastSyncStatus == nil)
		#expect(!store.isSyncing)
	}

	@Test("an older pull cannot clear a newer pull's loading state")
	func olderPullCannotFinishNewerPull() async {
		let oldGate = AsyncGate()
		let newGate = AsyncGate()
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [
			{
				await oldGate.arriveAndWait()
				return nil
			},
			{
				await newGate.arriveAndWait()
				return nil
			},
		]
		let projectId = "overlapping-pulls"
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: projectId,
			name: "Overlapping",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.isUnlocked = true
		store.selectProject(projectId)

		let oldPull = Task { await store.pullFromCloud() }
		await oldGate.waitUntilArrived()
		let newPull = Task { await store.pullFromCloud() }
		await newGate.waitUntilArrived()
		await oldGate.release()
		await oldPull.value

		#expect(store.isSyncing)
		#expect(store.lastSyncStatus == nil)

		await newGate.release()
		await newPull.value
		#expect(!store.isSyncing)
		#expect(store.lastSyncStatus == "failed")
	}

	// MARK: - Transactional Imports

	@Test("failed personal import leaves no local state")
	func failedPersonalImportIsAtomic() async {
		let importService = MockEnvProjectImportService()
		importService.personalResult = .failure(.invalidPayload("Invalid encrypted payload."))
		let (store, keychain) = makeImportStore(importService: importService)

		let result = await store.importCloudProject(remoteProject(id: "cloud-1", name: "cloud"))

		#expect(result == .failure(.invalidPayload("Invalid encrypted payload.")))
		#expect(keychain.storage.isEmpty)
		#expect(keychain.dataStorage["__sync_metadata__"] == nil)
		#expect(store.projects.isEmpty)
		#expect(store.selectedProjectId == nil)
		#expect(store.syncMetadata.isEmpty)
	}

	@Test("successful organization import publishes the final project once")
	func successfulOrganizationImportIsAtomic() async throws {
		let importService = MockEnvProjectImportService()
		importService.organizationResult = .success(RemoteEnvProjectPayload(
			environments: ["production": ["TOKEN": "secret"]],
			version: 7,
			keyCount: 1
		))
		let (store, keychain) = makeImportStore(importService: importService)
		store.currentUser = userWithOrganization(slug: "acme")

		let result = await store.importOrganizationProject(
			remoteProject(id: "org-1", name: "production"),
			orgSlug: "acme"
		)

		#expect(result == .success(ImportedEnvProject(projectId: "org-1", version: 7, keyCount: 1)))
		#expect(keychain.saveEnvironmentsCallCount == 1)
		#expect(keychain.envStorage["org-1"]?.environments["production"]?["TOKEN"] == "secret")
		#expect(store.projects.first?.secrets(for: "production")["TOKEN"] == "secret")
		#expect(store.vaultOrgAssociations["org-1"] == "acme")
		#expect(store.syncMetadata["org-1"]?.lastVersion == 7)
		#expect(store.selectedProjectId == "org-1")
	}

	@Test("organization association failure rolls back the project")
	func organizationAssociationFailureRollsBack() async {
		let importService = MockEnvProjectImportService()
		importService.organizationResult = .success(RemoteEnvProjectPayload(
			environments: ["default": ["TOKEN": "secret"]],
			version: 3,
			keyCount: 1
		))
		let (store, keychain) = makeImportStore(importService: importService)
		keychain.failDataAccounts = ["__org_associations__"]

		let result = await store.importOrganizationProject(
			remoteProject(id: "org-fail", name: "failed"),
			orgSlug: "acme"
		)

		guard case .failure(.persistence) = result else {
			Issue.record("Expected persistence failure")
			return
		}
		#expect(keychain.storage["org-fail"] == nil)
		#expect(store.projects.isEmpty)
		#expect(store.vaultOrgAssociations["org-fail"] == nil)
		#expect(store.syncMetadata["org-fail"] == nil)
	}

	@Test("duplicate cloud import never overwrites local secrets")
	func duplicateImportDoesNotOverwrite() async {
		let importService = MockEnvProjectImportService()
		importService.personalResult = .success(RemoteEnvProjectPayload(
			environments: ["default": ["TOKEN": "remote"]],
			version: 2,
			keyCount: 1
		))
		let (store, keychain) = makeImportStore(importService: importService)
		keychain.storage["duplicate"] = (name: "local", path: "", secrets: ["TOKEN": "local"])

		let result = await store.importCloudProject(remoteProject(id: "duplicate", name: "remote"))

		#expect(result == .failure(.duplicate))
		#expect(keychain.storage["duplicate"]?.secrets["TOKEN"] == "local")
		#expect(keychain.saveEnvironmentsCallCount == 0)
	}

	@Test("a concurrent CLI create wins without being overwritten")
	func concurrentCreateDuringImportDoesNotOverwrite() async {
		let importService = MockEnvProjectImportService()
		importService.personalResult = .success(RemoteEnvProjectPayload(
			environments: ["default": ["TOKEN": "remote"]],
			version: 2,
			keyCount: 1
		))
		let (store, keychain) = makeImportStore(importService: importService)
		keychain.onCreateEnvironments = {
			keychain.envStorage["raced"] = (
				name: "cli",
				path: "",
				environments: ["default": ["TOKEN": "cli"]]
			)
		}

		let result = await store.importCloudProject(remoteProject(id: "raced", name: "remote"))

		#expect(result == .failure(.duplicate))
		#expect(keychain.envStorage["raced"]?.environments["default"]?["TOKEN"] == "cli")
		#expect(keychain.saveEnvironmentsCallCount == 0)
		#expect(store.projects.isEmpty)
	}

	private func makeImportStore(
		importService: MockEnvProjectImportService
	) -> (VaultStore, MockKeychainService) {
		let keychain = MockKeychainService()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			importServiceFactory: { _ in importService },
			authTokenProvider: { _, _ in "session-token" }
		)
		return (store, keychain)
	}

	private func remoteProject(id: String, name: String?) -> SyncService.RemoteProject {
		SyncService.RemoteProject(
			vaultId: id,
			name: name,
			version: 1,
			updatedAt: nil,
			updatedBy: nil
		)
	}

	private func testUser(id: String, username: String) -> LPMUser {
		LPMUser(
			id: id,
			username: username,
			name: nil,
			email: nil,
			avatarUrl: nil,
			plan: nil,
			createdAt: nil,
			orgs: nil
		)
	}

	private func userWithOrganization(slug: String) -> LPMUser {
		LPMUser(
			id: "u1",
			username: "user",
			name: nil,
			email: nil,
			avatarUrl: nil,
			plan: nil,
			createdAt: nil,
			orgs: [LPMOrg(
				id: "organization-\(slug)",
				slug: slug,
				name: slug.capitalized,
				avatarUrl: nil,
				role: "admin"
			)]
		)
	}

	private func testUserWithOrganizations(count: Int) -> LPMUser {
		LPMUser(
			id: "u1",
			username: "user",
			name: nil,
			email: nil,
			avatarUrl: nil,
			plan: nil,
			createdAt: nil,
			orgs: (0..<count).map { index in
				LPMOrg(
					id: "organization-\(index)",
					slug: "org-\(index)",
					name: "Organization \(index)",
					avatarUrl: nil,
					role: "admin"
				)
			}
		)
	}

	private func testToken(id: String) -> LPMToken {
		LPMToken(
			id: id, name: id, scope: nil, expiresAt: nil,
			lastUsedAt: nil, downloadCount: nil, createdAt: nil
		)
	}

	private enum OrgPushInvalidation {
		case lock
		case logout
		case accountChange
		#if DEBUG
		case serverChange
		#endif
		case tokenReplacement
	}

	private func verifyInFlightOrgPushIsInvalidated(by transition: OrgPushInvalidation) async {
		let slug = "org-\(UUID().uuidString.lowercased())"
		let projectId = "project-\(UUID().uuidString.lowercased())"
		let keypair = VaultCrypto.generateX25519Keypair()
		let gate = AsyncGate()
		let token = MutableString("session-token")
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			members: [SyncService.MemberPublicKey(
				userId: "member",
				role: "admin",
				publicKey: keypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
				hasPublicKey: true
			)],
			canReplaceWrappedKeys: true
		)
		sync.blockNextMemberKeyAccess = { await gate.arriveAndWait() }

		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in token.value },
			authSessionClearer: { _ in }
		)
		store.appEnvironment = .production
		store.currentUser = userWithOrganization(slug: slug)
		store.projects = [VaultProject(
			id: projectId,
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.vaultOrgAssociations[projectId] = slug
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectId)

		let push = Task { await store.pushToOrg(orgSlug: slug) }
		await gate.waitUntilArrived()
		switch transition {
		case .lock:
			store.lock()
		case .logout:
			store.logout()
		case .accountChange:
			store.selectAccount(.personal)
		#if DEBUG
		case .serverChange:
			store.switchEnvironment(to: .development)
		#endif
		case .tokenReplacement:
			token.value = "replacement-token"
		}
		await gate.release()
		await push.value

		#expect(store.pendingOrgPush == nil)
		#expect(!store.showKeyApprovalSheet)
		#expect(sync.pushCallCount == 0)
		#expect(!store.isSyncing)
	}
}

private final class LockedCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var storage = 0

	var value: Int { lock.withLock { storage } }

	func increment() {
		lock.withLock { storage += 1 }
	}
}

private actor AutoLockSleeper {
	private var continuations: [CheckedContinuation<Void, any Error>?] = []

	var count: Int { continuations.count }

	func sleep(_ duration: Duration) async throws {
		_ = duration
		try await withCheckedThrowingContinuation { continuation in
			continuations.append(continuation)
		}
	}

	func resume(at index: Int) {
		guard continuations.indices.contains(index), let continuation = continuations[index] else {
			return
		}
		continuations[index] = nil
		continuation.resume()
	}
}

private final class SequencedAuthTokenProvider: @unchecked Sendable {
	private let lock = NSLock()
	private var tokens: [String?]

	init(tokens: [String?]) {
		self.tokens = tokens
	}

	func next() -> String? {
		lock.withLock {
			guard !tokens.isEmpty else { return nil }
			return tokens.removeFirst()
		}
	}
}

private final class MutableString: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: String

	init(_ value: String) {
		storage = value
	}

	var value: String {
		get { lock.withLock { storage } }
		set { lock.withLock { storage = newValue } }
	}
}

private final class MockAPIServiceFactory: @unchecked Sendable {
	private let lock = NSLock()
	private var counts: [URL: Int] = [:]
	private var services: [URL: MockAPIService] = [:]

	var urls: [URL] { lock.withLock { Array(counts.keys) } }

	func make(baseURL: URL) -> MockAPIService {
		lock.withLock {
			counts[baseURL, default: 0] += 1
			if let service = services[baseURL] { return service }
			let service = MockAPIService()
			service.user = LPMUser(
				id: baseURL.absoluteString,
				username: baseURL.host ?? "local",
				name: nil,
				email: nil,
				avatarUrl: nil,
				plan: nil,
				createdAt: nil,
				orgs: nil
			)
			services[baseURL] = service
			return service
		}
	}

	func count(for baseURL: URL) -> Int {
		lock.withLock { counts[baseURL, default: 0] }
	}
}

private final class StringRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [String] = []

	var values: [String] { lock.withLock { storage } }

	func append(_ value: String) {
		lock.withLock { storage.append(value) }
	}
}

private actor AsyncGate {
	private var arrived = false
	private var released = false
	private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
	private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

	func waitUntilArrived() async {
		guard !arrived else { return }
		await withCheckedContinuation { arrivalWaiters.append($0) }
	}

	func arriveAndWait() async {
		arrived = true
		arrivalWaiters.forEach { $0.resume() }
		arrivalWaiters.removeAll()
		guard !released else { return }
		await withCheckedContinuation { releaseWaiters.append($0) }
	}

	func release() {
		released = true
		releaseWaiters.forEach { $0.resume() }
		releaseWaiters.removeAll()
	}
}

private actor AsyncSignal {
	private var signalled = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !signalled else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func send() {
		signalled = true
		waiters.forEach { $0.resume() }
		waiters.removeAll()
	}
}

private func testAuthCredentials() -> AuthSessionCredentials {
	AuthSessionCredentials(
		token: "login-access",
		refreshToken: "login-refresh",
		expiresIn: 3_600,
		expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
	)
}
