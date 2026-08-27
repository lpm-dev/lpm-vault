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
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)

		// Pre-populate projects synchronously (the real loadProjects() uses
		// Task.detached for UI responsiveness, but tests need deterministic ordering)
		if !projects.isEmpty {
			store.projects =
				projects
				.map {
					VaultProject(
						id: $0.id, name: $0.name, path: $0.path,
						environments: ["default": $0.secrets])
				}
				.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		}

		return (store, keychain, biometric, api)
	}

	// MARK: - Load

	@Test("load projects from keychain")
	func loadProjects() async throws {
		let keychain = MockKeychainService()
		keychain.storage["id-1"] = (
			name: "api-server", path: "/tmp/api", secrets: ["DB_HOST": "localhost"]
		)
		keychain.storage["id-2"] = (
			name: "web-app", path: "/tmp/web", secrets: ["API_KEY": "sk-123"]
		)
		let store = VaultStore(
			keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService())

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
		await waitUntil { !store.projects.isEmpty }

		#expect(store.projects.count == 1)
		#expect(store.projects.first?.name == "new-project")
		#expect(store.projects.first?.path == "/tmp/new")
		#expect(store.projects.first?.secrets.isEmpty == true)
		#expect(store.selectedProjectId == store.projects.first?.id)
		#expect(keychain.storage.count == 1)
	}

	@Test("add project failure sets error")
	func addProjectFailure() async throws {
		let (store, keychain, _, _) = makeStore()
		keychain.shouldFail = true

		store.addProject(name: "failing-project", path: "/tmp/fail")
		await waitUntil { store.error != nil }

		#expect(store.projects.isEmpty)
		#expect(store.error != nil)
	}

	@Test("reserved Keychain accounts cannot be env project IDs")
	func reservedProjectIdsAreRejected() async {
		let (store, keychain, _, _) = makeStore()
		for id in [
			"__index__", "__sync_metadata__", "__org_associations__", "__x25519_private_key__",
		] {
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

	@Test("association failure restores the deleted vault and exact metadata snapshots")
	func localDeletionAssociationFailureRollsBack() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: ["TOKEN": "secret"])
		])
		let metadataData = try JSONEncoder().encode([
			"id-1": SyncMetadata(lastAction: "push", isDirty: true)
		])
		let associationData = try JSONEncoder().encode(["id-1": "example-org"])
		keychain.dataStorage["__sync_metadata__"] = metadataData
		keychain.dataStorage["__org_associations__"] = associationData
		keychain.failNextWriteDataAccounts.insert("__org_associations__")

		let deleted = await store.deleteLocalVault(store.projects[0])

		#expect(!deleted)
		#expect(keychain.storage["id-1"]?.secrets["TOKEN"] == "secret")
		#expect(keychain.dataStorage["__sync_metadata__"] == metadataData)
		#expect(keychain.dataStorage["__org_associations__"] == associationData)
		#expect(store.projects[0].secrets["TOKEN"] == "secret")
	}

	@Test("metadata failure restores the deleted vault and exact metadata snapshots")
	func localDeletionMetadataFailureRollsBack() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: ["TOKEN": "secret"])
		])
		let metadataData = try JSONEncoder().encode([
			"id-1": SyncMetadata(lastAction: "push", isDirty: true)
		])
		let associationData = try JSONEncoder().encode(["id-1": "example-org"])
		keychain.dataStorage["__sync_metadata__"] = metadataData
		keychain.dataStorage["__org_associations__"] = associationData
		keychain.failNextWriteDataAccounts.insert("__sync_metadata__")

		let deleted = await store.deleteLocalVault(store.projects[0])

		#expect(!deleted)
		#expect(keychain.storage["id-1"]?.secrets["TOKEN"] == "secret")
		#expect(keychain.dataStorage["__sync_metadata__"] == metadataData)
		#expect(keychain.dataStorage["__org_associations__"] == associationData)
		#expect(store.projects[0].secrets["TOKEN"] == "secret")
	}

	@Test("uncertain local deletion rollback locks and clears plaintext")
	func localDeletionRollbackFailureLocksVault() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: ["TOKEN": "secret"])
		])
		keychain.dataStorage["__sync_metadata__"] = try JSONEncoder().encode([
			"id-1": SyncMetadata(lastAction: "push", isDirty: true)
		])
		keychain.dataStorage["__org_associations__"] = try JSONEncoder().encode([
			"id-1": "example-org"
		])
		keychain.failNextWriteDataAccounts.insert("__org_associations__")
		keychain.failNextSaveEnvironments = true
		store.isUnlocked = true

		let deleted = await store.deleteLocalVault(store.projects[0])

		#expect(!deleted)
		#expect(!store.isUnlocked)
		#expect(keychain.storage["id-1"] == nil)
		#expect(store.projects[0].environments.values.allSatisfy { $0.isEmpty })
		#expect(store.error?.contains("could not be rolled back completely") == true)
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
		#expect(
			store.projects.allSatisfy { project in
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
	func logoutNormalizesOrganizationNavigation() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "org", name: "org", path: "", secrets: [:])
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org": "acme"]
		store.openProject(id: "org")

		await store.logout()

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

	@Test("local user activity restarts the auto-lock timer")
	func userActivityRestartsAutoLock() async {
		let sleeper = AutoLockSleeper()
		let clock = AutoLockClock()
		let keychain = MockKeychainService()
		keychain.storage["id-1"] = (name: "one", path: "", secrets: [:])
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) },
			autoLockNow: { clock.now }
		)

		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		clock.now = 30
		for _ in 0..<100 { store.recordUserActivity() }
		for _ in 0..<10 { await Task.yield() }
		#expect(await sleeper.count == 1)

		clock.now = 120
		await sleeper.resume(at: 0)
		while await sleeper.count < 2 { await Task.yield() }
		#expect(store.isUnlocked)

		clock.now = 150
		await sleeper.resume(at: 1)
		while store.isUnlocked { await Task.yield() }
		#expect(!store.isUnlocked)
	}

	@Test("user activity while locked does not schedule auto-lock")
	func lockedUserActivityDoesNotScheduleAutoLock() async {
		let sleeper = AutoLockSleeper()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) }
		)

		store.recordUserActivity()
		for _ in 0..<10 { await Task.yield() }

		#expect(await sleeper.count == 0)
	}

	@Test("activity at or after the idle deadline locks immediately")
	func expiredActivityCannotReviveSession() async {
		for expiredTime in [120.0, 121.0] {
			let sleeper = AutoLockSleeper()
			let clock = AutoLockClock()
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				autoLockSleep: { duration in try await sleeper.sleep(duration) },
				autoLockNow: { clock.now },
				autoLockDuration: 120
			)

			await store.unlock()
			while await sleeper.count < 1 { await Task.yield() }
			clock.now = expiredTime
			store.recordUserActivity()

			#expect(!store.isUnlocked)
			#expect(await sleeper.count == 1)
		}
	}

	@Test("an old idle sleeper cannot affect a newly unlocked session")
	func staleAutoLockSleeperCannotClearNewGeneration() async {
		let sleeper = AutoLockSleeper()
		let clock = AutoLockClock()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) },
			autoLockNow: { clock.now },
			autoLockDuration: 120
		)

		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		store.lock()
		clock.now = 10
		await store.unlock()
		while await sleeper.count < 2 { await Task.yield() }

		await sleeper.resume(at: 0)
		for _ in 0..<10 { await Task.yield() }
		#expect(store.isUnlocked)

		clock.now = 130
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
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "id-1",
			environment: "default",
			key: "DB_HOST",
			value: "localhost"
		)

		#expect(result == .success)
		#expect(store.projects[0].secrets["DB_HOST"] == "localhost")
		#expect(keychain.storage["id-1"]?.secrets["DB_HOST"] == "localhost")
	}

	@Test("add secret with empty key is rejected")
	func addSecretEmptyKey() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "id-1",
			environment: "default",
			key: "",
			value: "value"
		)

		#expect(result == .failure(.invalidName))
		#expect(store.projects[0].secrets.isEmpty)
	}

	@Test("a CLI mutation cannot interleave between coordinator read and write")
	func addSecretHoldsCrossProcessTransactionAcrossMutation() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["OLD": "value"])
		])
		let attempted = DispatchSemaphore(value: 0)
		let finished = DispatchSemaphore(value: 0)
		keychain.onGetEnvironments = {
			DispatchQueue.global().async {
				attempted.signal()
				keychain.simulateCLISet(
					vaultId: "id-1",
					environment: "default",
					key: "CLI_KEY",
					value: "cli-value"
				)
				finished.signal()
			}
			attempted.wait()
		}
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "id-1",
			environment: "default",
			key: "VAULT_KEY",
			value: "vault-value"
		)
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				finished.wait()
				continuation.resume()
			}
		}

		#expect(result == .success)
		#expect(
			keychain.storage["id-1"]?.secrets == [
				"OLD": "value",
				"VAULT_KEY": "vault-value",
				"CLI_KEY": "cli-value",
			])
	}

	@Test("add secret rejects names outside the Rust env contract")
	func addSecretInvalidNames() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])
		store.isUnlocked = true

		for key in ["1LEADING", "WITH-DASH", "WITH SPACE", "ÉNV"] {
			let result = await store.addSecret(
				to: "id-1",
				environment: "default",
				key: key,
				value: "value"
			)
			#expect(result == .failure(.invalidName))
		}

		#expect(store.projects[0].secrets.isEmpty)
	}

	@Test("add secret rejects exact and case-only duplicates")
	func addSecretRejectsPortableDuplicates() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["HEY": "value"])
		])
		store.isUnlocked = true

		let duplicate = await store.addSecret(
			to: "id-1", environment: "default", key: "HEY", value: "new"
		)
		let collision = await store.addSecret(
			to: "id-1", environment: "default", key: "Hey", value: "new"
		)

		#expect(duplicate == .failure(.duplicate))
		#expect(collision == .failure(.caseInsensitiveCollision(existingKey: "HEY")))
		#expect(store.projects[0].secrets == ["HEY": "value"])
	}

	@Test("add secret ignores unrelated global errors")
	func addSecretIgnoresStaleGlobalError() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])
		store.isUnlocked = true
		store.error = "Older unrelated error"

		let result = await store.addSecret(
			to: "id-1", environment: "default", key: "TOKEN", value: "secret"
		)

		#expect(result == .success)
		#expect(store.projects[0].secrets["TOKEN"] == "secret")
	}

	@Test("add secret does not publish when persistence fails")
	func addSecretRollsBackOnPersistenceFailure() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])
		store.isUnlocked = true
		keychain.shouldFail = true

		let result = await store.addSecret(
			to: "id-1", environment: "default", key: "TOKEN", value: "secret"
		)

		#expect(result == .failure(.persistence(KeychainError.accessDenied.description)))
		#expect(store.projects[0].secrets.isEmpty)
		#expect(keychain.storage["id-1"]?.secrets.isEmpty == true)
	}

	@Test("locking during add secret persistence never republishes plaintext")
	func lockDuringAddSecretKeepsMemoryCleared() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["OLD": "value"])
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		store.isUnlocked = true

		let task = Task {
			await store.addSecret(
				to: "id-1",
				environment: "default",
				key: "TOKEN",
				value: "secret"
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

		#expect(await task.value == .success)
		#expect(!store.isUnlocked)
		#expect(store.projects[0].environments.values.allSatisfy { $0.isEmpty })
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value", "TOKEN": "secret"])
		let metadata = keychain.dataStorage["__sync_metadata__"]
			.flatMap { try? JSONDecoder().decode([String: SyncMetadata].self, from: $0) }
		#expect(metadata?["id-1"]?.isDirty == true)
	}

	@Test("metadata failure restores add secret vault and metadata snapshots")
	func addSecretMetadataFailureRollsBackBothSnapshots() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["OLD": "value"])
		])
		let previousMetadata = [
			"id-1": SyncMetadata(
				lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
				lastAction: "pull",
				lastVersion: 7,
				isDirty: false
			)
		]
		let previousMetadataData = try JSONEncoder().encode(previousMetadata)
		keychain.dataStorage["__sync_metadata__"] = previousMetadataData
		keychain.failNextWriteDataAccounts = ["__sync_metadata__"]
		store.syncMetadata = previousMetadata
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "id-1",
			environment: "default",
			key: "TOKEN",
			value: "secret"
		)

		#expect(result == .failure(.persistence(KeychainError.unexpectedStatus(-1).description)))
		#expect(store.projects[0].secrets == ["OLD": "value"])
		#expect(store.syncMetadata["id-1"]?.lastVersion == 7)
		#expect(store.syncMetadata["id-1"]?.isDirty == false)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
		#expect(keychain.dataStorage["__sync_metadata__"] == previousMetadataData)
	}

	@Test("one-shot metadata read failure cannot overwrite the durable snapshot")
	func addSecretMetadataReadFailurePreservesDurableSnapshot() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["OLD": "value"])
		])
		let previousMetadata = [
			"existing-project": SyncMetadata(
				lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
				lastAction: "pull",
				lastVersion: 7,
				isDirty: false
			)
		]
		let previousMetadataData = try JSONEncoder().encode(previousMetadata)
		keychain.dataStorage["__sync_metadata__"] = previousMetadataData
		keychain.failNextReadDataAccounts = ["__sync_metadata__"]
		store.syncMetadata = previousMetadata
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "id-1",
			environment: "default",
			key: "TOKEN",
			value: "secret"
		)

		#expect(result == .failure(.persistence(KeychainError.accessDenied.description)))
		#expect(store.projects[0].secrets == ["OLD": "value"])
		#expect(store.syncMetadata["existing-project"]?.lastVersion == 7)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
		#expect(keychain.dataStorage["__sync_metadata__"] == previousMetadataData)
	}

	@Test("add secret rollback failure after lock never reloads plaintext")
	func addSecretRollbackFailureAfterLockKeepsMemoryCleared() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["OLD": "value"])
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		keychain.failNextWriteDataAccounts = ["__sync_metadata__"]
		keychain.failRestoreSaveEnvironments = true
		store.isUnlocked = true

		let task = Task {
			await store.addSecret(
				to: "id-1",
				environment: "default",
				key: "TOKEN",
				value: "secret"
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

		#expect(
			await task.value
				== .failure(
					.persistence(KeychainError.unexpectedStatus(-2).description)
				))
		#expect(!store.isUnlocked)
		#expect(store.projects[0].environments.values.allSatisfy { $0.isEmpty })
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value", "TOKEN": "secret"])
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

	@Test("new environment appears once in its saved order")
	func addEnvironmentKeepsUniqueOrder() async {
		let projectId = "environment-order-\(UUID().uuidString)"
		defer {
			UserDefaults.standard.removeObject(forKey: "lpm-vault-env-order-\(projectId)")
		}
		let (store, _, _, _) = makeStore(projects: [
			(id: projectId, name: "project", path: "/tmp/p", secrets: [:])
		])
		store.isUnlocked = true
		store.selectedProjectId = projectId

		let added = await store.addEnvironment(to: projectId, name: "local")

		#expect(added)
		#expect(store.environmentOrders[projectId] == ["default", "local"])
		#expect(store.orderedEnvironmentNames(for: store.projects[0]) == ["default", "local"])
	}

	@Test("environment order ignores duplicate saved names")
	func environmentOrderRepairsDuplicates() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])
		store.projects[0].environments["local"] = [:]
		store.environmentOrders["id-1"] = ["default", "local", "local"]

		#expect(store.orderedEnvironmentNames(for: store.projects[0]) == ["default", "local"])
	}

	@Test("copied environment appears once after its source")
	func duplicateEnvironmentKeepsUniqueOrder() async {
		let projectId = "copied-environment-order-\(UUID().uuidString)"
		defer {
			UserDefaults.standard.removeObject(forKey: "lpm-vault-env-order-\(projectId)")
		}
		let (store, keychain, _, _) = makeStore(projects: [
			(id: projectId, name: "project", path: "/tmp/p", secrets: [:])
		])
		store.projects[0].environments["local"] = ["KEY": "value"]
		keychain.envStorage[projectId]?.environments["local"] = ["KEY": "value"]
		store.environmentOrders[projectId] = ["default", "local"]
		store.isUnlocked = true

		store.duplicateEnvironment(in: projectId, from: "local", to: "staging")

		await waitUntil {
			store.projects[0].environments["staging"] != nil
				&& store.environmentOrders[projectId]?.contains("staging") == true
		}
		#expect(store.environmentOrders[projectId] == ["default", "local", "staging"])
		#expect(
			store.orderedEnvironmentNames(for: store.projects[0]) == [
				"default", "local", "staging",
			])
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
		await importer.resolve(
			"slow.env", with: .success(ImportedEnvFile(secrets: ["STALE": "secret"])))

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

		await importer.resolve(
			"newer.env", with: .success(ImportedEnvFile(secrets: ["KEY": "new"])))
		await importer.resolve(
			"older.env", with: .success(ImportedEnvFile(secrets: ["KEY": "old"])))

		#expect(await newer.value == .success(ImportedEnvFile(secrets: ["KEY": "new"])))
		#expect(await older.value == .failure(.cancelled))
		#expect(store.projects[0].secrets["KEY"] == "new")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
	}

	@Test("dotenv import rejects a case-only collision with an existing key")
	func localEnvImportRejectsCaseOnlyExistingCollision() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["HEY": "upper"])],
			envFileImportService: importer
		)
		store.selectedProjectId = "id-1"
		store.isUnlocked = true
		await importer.setImmediateResult(
			.success(ImportedEnvFile(secrets: ["Hey": "mixed"]))
		)

		let result = await store.importEnvFile(
			at: URL(fileURLWithPath: "/tmp/collision.env"),
			to: "id-1",
			environment: "default"
		)

		#expect(result == .failure(.caseInsensitiveCollisionWithExisting))
		#expect(store.projects[0].secrets == ["HEY": "upper"])
		#expect(keychain.storage["id-1"]?.secrets == ["HEY": "upper"])
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
		#expect(
			await newer.value
				== .success(
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
		await importer.resolve(
			"locked.env", with: .success(ImportedEnvFile(secrets: ["STALE": "secret"])))

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
	func addSecretNoProject() async {
		let (store, _, _, _) = makeStore()
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "nonexistent",
			environment: "default",
			key: "KEY",
			value: "VALUE"
		)

		#expect(result == .failure(.targetUnavailable))
		#expect(store.projects.isEmpty)
	}

	// MARK: - Update Secret

	@Test("update existing secret")
	func updateSecret() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")

		store.updateSecret(in: "id-1", key: "KEY", newValue: "new")

		await waitUntil { store.projects[0].secrets["KEY"] == "new" }
		#expect(store.projects[0].secrets["KEY"] == "new")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
	}

	@Test("update non-existent key is no-op")
	func updateNonExistentKey() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "val"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")

		store.updateSecret(in: "id-1", key: "MISSING", newValue: "new")

		#expect(store.projects[0].secrets["KEY"] == "val")
		#expect(store.projects[0].secrets["MISSING"] == nil)
	}

	@Test("update uses the captured environment instead of current navigation")
	func updateCapturedEnvironment() async {
		let (store, keychain, _, _) = makeStore()
		store.projects = [
			VaultProject(
				id: "id-1",
				name: "project",
				path: "/tmp/p",
				environments: [
					"default": ["KEY": "default"],
					"staging": ["KEY": "staging"],
				]
			)
		]
		keychain.envStorage["id-1"] = (
			name: "project",
			path: "/tmp/p",
			environments: store.projects[0].environments
		)
		store.isUnlocked = true
		store.selectProject("id-1")
		store.selectedEnvironment = "default"

		store.updateSecret(in: "id-1", environment: "staging", key: "KEY", newValue: "updated")

		await waitUntil { store.projects[0].environments["staging"]?["KEY"] == "updated" }
		#expect(store.projects[0].environments["default"]?["KEY"] == "default")
		#expect(store.projects[0].environments["staging"]?["KEY"] == "updated")
	}

	@Test("a stale Vault update preserves a disjoint CLI key")
	func updateSecretPreservesConcurrentCLIKey() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")
		keychain.simulateCLISet(
			vaultId: "id-1",
			environment: "default",
			key: "CLI_KEY",
			value: "cli-value"
		)

		store.updateSecret(in: "id-1", key: "KEY", newValue: "new")

		await waitUntil { store.projects[0].secrets["KEY"] == "new" }
		#expect(
			keychain.storage["id-1"]?.secrets == [
				"KEY": "new",
				"CLI_KEY": "cli-value",
			])
		#expect(
			store.projects[0].secrets == [
				"KEY": "new",
				"CLI_KEY": "cli-value",
			])
	}

	@Test("an overlapping CLI update fails without overwriting either snapshot")
	func updateSecretRejectsConcurrentCLIConflict() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")
		keychain.simulateCLISet(
			vaultId: "id-1",
			environment: "default",
			key: "KEY",
			value: "cli-value"
		)

		store.updateSecret(in: "id-1", key: "KEY", newValue: "vault-value")

		await waitUntil { store.error?.contains("changed in another LPM process") == true }
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "cli-value")
		#expect(store.projects[0].secrets["KEY"] == "cli-value")
	}

	@Test("failed update persistence leaves UI and Keychain unchanged")
	func updateSecretFailureDoesNotPublish() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		keychain.shouldFail = true
		store.isUnlocked = true
		store.selectProject("id-1")

		store.updateSecret(in: "id-1", key: "KEY", newValue: "new")

		await waitUntil { store.error != nil }
		#expect(store.projects[0].secrets["KEY"] == "old")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "old")
	}

	@Test("metadata failure rolls back a durable update before UI publication")
	func updateSecretMetadataFailureRollsBack() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		keychain.failNextWriteDataAccounts = ["__sync_metadata__"]
		store.isUnlocked = true
		store.selectProject("id-1")

		store.updateSecret(in: "id-1", key: "KEY", newValue: "new")

		await waitUntil { store.error != nil }
		#expect(store.projects[0].secrets["KEY"] == "old")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "old")
		#expect(keychain.dataStorage["__sync_metadata__"] == nil)
	}

	// MARK: - Delete Secret

	@Test("delete secret from project")
	func deleteSecret() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["A": "1", "B": "2"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")

		store.deleteSecret(from: "id-1", key: "A")

		await waitUntil { store.projects[0].secrets["A"] == nil }
		#expect(store.projects[0].secrets["A"] == nil)
		#expect(store.projects[0].secrets["B"] == "2")
		#expect(keychain.storage["id-1"]?.secrets["A"] == nil)
	}

	@Test("delete uses the captured environment instead of current navigation")
	func deleteCapturedEnvironment() async {
		let (store, keychain, _, _) = makeStore()
		store.projects = [
			VaultProject(
				id: "id-1",
				name: "project",
				path: "/tmp/p",
				environments: [
					"default": ["KEY": "default"],
					"staging": ["KEY": "staging"],
				]
			)
		]
		keychain.envStorage["id-1"] = (
			name: "project",
			path: "/tmp/p",
			environments: store.projects[0].environments
		)
		store.isUnlocked = true
		store.selectProject("id-1")
		store.selectedEnvironment = "default"

		store.deleteSecret(from: "id-1", environment: "staging", key: "KEY")

		await waitUntil { store.projects[0].environments["staging"]?["KEY"] == nil }
		#expect(store.projects[0].environments["default"]?["KEY"] == "default")
		#expect(store.projects[0].environments["staging"]?["KEY"] == nil)
	}

	@Test("captured secret mutations reject stale project navigation")
	func capturedMutationsRejectStaleProject() {
		let (store, _, _, _) = makeStore()
		store.projects = [
			VaultProject(
				id: "project-a", name: "A", path: "", environments: ["default": ["KEY": "a"]]),
			VaultProject(
				id: "project-b", name: "B", path: "", environments: ["default": ["KEY": "b"]]),
		]
		store.isUnlocked = true
		store.selectProject("project-b")

		store.updateSecret(in: "project-a", environment: "default", key: "KEY", newValue: "changed")
		store.deleteSecret(from: "project-a", environment: "default", key: "KEY")

		#expect(store.projects.first(where: { $0.id == "project-a" })?.secrets["KEY"] == "a")
		#expect(store.projects.first(where: { $0.id == "project-b" })?.secrets["KEY"] == "b")
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
		await store.logout()
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
			createdAt: nil,
			orgs: [LPMOrg(id: "o1", slug: "acme", name: "Acme", avatarUrl: nil, role: "owner")]
		)
		api.personalTokens = [
			LPMToken(
				id: "t1", name: "ci-deploy", scope: "publish", expiresAt: nil,
				lastUsedAt: nil, downloadCount: 5, createdAt: nil),
			LPMToken(
				id: "t2", name: "local-dev", scope: "read", expiresAt: nil,
				lastUsedAt: nil, downloadCount: 0, createdAt: nil),
		]
		api.orgTokensMap["acme"] = [
			LPMToken(
				id: "ot1", name: "prod-key", scope: "publish", expiresAt: nil,
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
				LPMOrg(
					id: "4", slug: "maintainer", name: "Maintainer", avatarUrl: nil,
					role: "maintainer"),
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
		await store.logout()
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
			#expect(
				Set(factory.urls) == [VaultConstants.apiBaseURL, VaultConstants.localAPIBaseURL])
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
			let succeeded = await login.value

			#expect(writes.values.isEmpty)
			#expect(!succeeded)
			#expect(store.appEnvironment == .development)
			#expect(!store.isLoggingIn)
		}

		@Test("login reports success only after validating and storing the session")
		func loginReportsValidatedSessionSuccess() async {
			let api = MockAPIService()
			api.user = testUserWithOrganizations(count: 0)
			let writes = StringRecorder()
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: api,
				authTokenProvider: { _, _ in "new-session-token" },
				loginProvider: { _, _ in testAuthCredentials(token: "new-session-token") },
				authSessionWriter: { _, registryURL in writes.append(registryURL) },
				authSessionClearer: { _ in }
			)
			store.appEnvironment = .production

			let succeeded = await store.login()

			#expect(succeeded)
			#expect(writes.values == [VaultConstants.apiBaseURL.absoluteString])
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
	func logoutIsEnvironmentScoped() async {
		let cleared = StringRecorder()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil },
			authSessionClearer: { cleared.append($0) }
		)
		store.appEnvironment = .production

		await store.logout()

		#expect(cleared.values == [VaultConstants.apiBaseURL.absoluteString])
	}

	@Test("logout keeps the visible session when shared storage cannot be cleared")
	func logoutStorageFailureIsVisible() async {
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in throw TestAuthClearError.failed }
		)
		store.currentUser = testUser(id: "current", username: "current")
		store.personalTokens = [testToken(id: "personal")]

		await store.logout()

		#expect(store.currentUser?.id == "current")
		#expect(store.personalTokens.map(\.id) == ["personal"])
		#expect(store.error?.contains("Could not clear the shared LPM session") == true)
	}

	@Test("token loading keeps the visible session when shared auth storage fails")
	func authTokenStorageFailureIsVisible() async {
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in throw TestAuthClearError.failed },
			authSessionClearer: { _ in }
		)
		store.currentUser = testUser(id: "current", username: "current")
		store.personalTokens = [testToken(id: "personal")]

		await store.loadTokens()

		#expect(store.currentUser?.id == "current")
		#expect(store.personalTokens.map(\.id) == ["personal"])
		#expect(store.error?.contains("Could not access the shared LPM session") == true)
	}

	@Test("a superseded auth read cannot publish a storage error")
	func supersededAuthStorageFailureIsDiscarded() async {
		let gate = AsyncGate()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in
				await gate.arriveAndWait()
				throw TestAuthClearError.failed
			},
			authSessionClearer: { _ in }
		)
		store.currentUser = testUser(id: "current", username: "current")
		let load = Task { await store.loadTokens() }
		await gate.waitUntilArrived()

		await store.logout()
		await gate.release()
		await load.value

		#expect(store.currentUser == nil)
		#expect(store.error == nil)
	}

	@Test("logout discards stale personal-revocation auth storage failures")
	func stalePersonalRevocationAuthFailuresAreDiscarded() async {
		for failureCall in [1, 2] {
			let provider = GatedAuthFailureProvider(failureCall: failureCall)
			let token = testToken(id: "personal-\(failureCall)")
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				authTokenProvider: { _, _ in try await provider.next() },
				authSessionClearer: { _ in }
			)
			store.personalTokens = [token]
			let revocation = Task { await store.revokePersonalToken(token) }
			await provider.waitUntilBlocked()

			await store.logout()
			await provider.release()
			await revocation.value

			#expect(store.error == nil)
		}
	}

	@Test("logout discards stale organization-revocation auth storage failures")
	func staleOrganizationRevocationAuthFailuresAreDiscarded() async {
		for failureCall in [1, 2] {
			let provider = GatedAuthFailureProvider(failureCall: failureCall)
			let token = testToken(id: "organization-\(failureCall)")
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				authTokenProvider: { _, _ in try await provider.next() },
				authSessionClearer: { _ in }
			)
			store.orgTokens = ["acme": [token]]
			let revocation = Task {
				await store.revokeOrgToken(token, orgSlug: "acme")
			}
			await provider.waitUntilBlocked()

			await store.logout()
			await provider.release()
			await revocation.value

			#expect(store.error == nil)
		}
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
			LPMToken(
				id: "t1", name: "expiring", scope: nil, expiresAt: soon,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
			LPMToken(
				id: "t2", name: "healthy", scope: nil, expiresAt: far,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
			LPMToken(
				id: "t3", name: "no-expiry", scope: nil, expiresAt: nil,
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
			LPMToken(
				id: "t1", name: "to-revoke", scope: nil, expiresAt: nil,
				lastUsedAt: nil, downloadCount: nil, createdAt: nil),
			LPMToken(
				id: "t2", name: "keep", scope: nil, expiresAt: nil,
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
			LPMToken(
				id: "ot1", name: "org-token", scope: nil, expiresAt: nil,
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
	func securityTransitionsDiscardPendingOrgAuthorization() async {
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
		await store.logout()
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
		sync.pullHandlers = [
			{
				await gate.arriveAndWait()
				return nil
			}
		]
		let projectId = "personal-pull"
		let keychain = MockKeychainService()
		keychain.envStorage[projectId] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			authTokenProvider: { _, _ in token.value }
		)
		store.projects = [
			VaultProject(
				id: projectId,
				name: "Personal",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)
		]
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

	@Test("project navigation suppresses a stale personal push conflict")
	func projectNavigationSuppressesStalePersonalPush() async {
		let gate = AsyncGate()
		let sync = MockPersonalSyncService()
		sync.pushHandlers = [
			{
				await gate.arriveAndWait()
				return SyncService.SyncStatus(
					vaultId: nil,
					version: nil,
					cryptoVersion: nil,
					contentKeyVersion: nil,
					recipientPublicKeyVersion: nil,
					recipientPublicKeyFingerprint: nil,
					status: nil,
					error: "version conflict",
					code: nil,
					serverVersion: nil,
					hint: nil,
					encryptedBlob: nil,
					wrappedKey: nil,
					updatedAt: nil
				)
			}
		]
		let keychain = MockKeychainService()
		keychain.envStorage["project-a"] = (
			name: "A", path: "", environments: ["default": ["TOKEN": "a"]]
		)
		keychain.envStorage["project-b"] = (
			name: "B", path: "", environments: ["default": ["TOKEN": "b"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _ in ("test-blob", "test-wrapped-key") },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [
			VaultProject(
				id: "project-a", name: "A", path: "", environments: ["default": ["TOKEN": "a"]]),
			VaultProject(
				id: "project-b", name: "B", path: "", environments: ["default": ["TOKEN": "b"]]),
		]
		store.isUnlocked = true
		store.selectProject("project-a")

		let push = Task { await store.pushToCloud() }
		await gate.waitUntilArrived()
		store.selectProject("project-b")
		await gate.release()
		await push.value

		#expect(store.selectedProjectId == "project-b")
		#expect(store.lastSyncStatus == nil)
		#expect(store.syncMetadata["project-a"] == nil)
		#expect(!store.isSyncing)
	}

	@Test("a CLI mutation during push remains dirty after server success")
	func personalPushPreservesDirtyStateForConcurrentCLIChange() async {
		let gate = AsyncGate()
		let sync = MockPersonalSyncService()
		sync.pushHandlers = [
			{
				await gate.arriveAndWait()
				return SyncService.SyncStatus(
					vaultId: "project-a",
					version: 2,
					cryptoVersion: 2,
					contentKeyVersion: nil,
					recipientPublicKeyVersion: nil,
					recipientPublicKeyFingerprint: nil,
					status: "ok",
					error: nil,
					code: nil,
					serverVersion: nil,
					hint: nil,
					encryptedBlob: nil,
					wrappedKey: nil,
					updatedAt: nil
				)
			}
		]
		let keychain = MockKeychainService()
		keychain.envStorage["project-a"] = (
			name: "A",
			path: "",
			environments: ["default": ["TOKEN": "a"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _ in ("test-blob", "test-wrapped-key") },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [
			VaultProject(
				id: "project-a",
				name: "A",
				path: "",
				environments: ["default": ["TOKEN": "a"]]
			)
		]
		store.isUnlocked = true
		store.selectProject("project-a")

		let push = Task { await store.pushToCloud() }
		await gate.waitUntilArrived()
		keychain.simulateCLISet(
			vaultId: "project-a",
			environment: "default",
			key: "CLI_KEY",
			value: "cli-value"
		)
		await gate.release()
		await push.value

		#expect(store.syncMetadata["project-a"]?.isDirty == true)
		#expect(store.projects[0].secrets["CLI_KEY"] == "cli-value")
		#expect(store.lastSyncStatus?.contains("local changes pending") == true)
		let storedMetadata = keychain.dataStorage["__sync_metadata__"]
			.flatMap { try? JSONDecoder().decode([String: SyncMetadata].self, from: $0) }
		#expect(storedMetadata?["project-a"]?.isDirty == true)
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
		let keychain = MockKeychainService()
		keychain.envStorage[projectId] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = userWithOrganization(slug: slug)
		store.projects = [
			VaultProject(
				id: projectId,
				name: "Organization",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)
		]
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
		let keychain = MockKeychainService()
		keychain.envStorage[projectId] = (
			name: "Overlapping",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [
			VaultProject(
				id: projectId,
				name: "Overlapping",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)
		]
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

	@Test("pull merges disjoint CLI changes from the latest durable snapshot")
	func pullPreservesDisjointCLIChange() async throws {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local", "CLI_KEY": "cli-value"]]
		)
		let baseline = VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let remotePayload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "cloud", "CLOUD_KEY": "cloud-value"]]
		])
		let coordinator = VaultPersistenceCoordinator(service: keychain)

		let result = await coordinator.commitPull(
			baseline: baseline,
			remotePayload: remotePayload,
			action: "pull",
			version: 3
		)

		guard case .success(let commit) = result else {
			Issue.record("Expected a successful pull commit, got \(result)")
			return
		}
		#expect(
			commit.project.secrets == [
				"TOKEN": "cloud",
				"CLI_KEY": "cli-value",
				"CLOUD_KEY": "cloud-value",
			])
		#expect(commit.isDirty)
		#expect(keychain.storage["project"]?.secrets == commit.project.secrets)
	}

	@Test("pull rejects an overlapping CLI change without overwriting it")
	func pullRejectsOverlappingCLIChange() async throws {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "cli-value"]]
		)
		let baseline = VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let remotePayload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "cloud"]]
		])
		let coordinator = VaultPersistenceCoordinator(service: keychain)

		let result = await coordinator.commitPull(
			baseline: baseline,
			remotePayload: remotePayload,
			action: "pull",
			version: 3
		)

		guard case .conflict(let latest, _) = result else {
			Issue.record("Expected a pull conflict, got \(result)")
			return
		}
		#expect(latest.secrets["TOKEN"] == "cli-value")
		#expect(keychain.storage["project"]?.secrets["TOKEN"] == "cli-value")
		#expect(keychain.dataStorage["__sync_metadata__"] == nil)
	}

	@Test("pull metadata failure restores the exact durable project")
	func pullMetadataFailureRollsBack() async throws {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		keychain.failNextWriteDataAccounts = ["__sync_metadata__"]
		let baseline = VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let remotePayload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "cloud"]]
		])
		let coordinator = VaultPersistenceCoordinator(service: keychain)

		let result = await coordinator.commitPull(
			baseline: baseline,
			remotePayload: remotePayload,
			action: "pull",
			version: 3
		)

		guard case .failure(.unexpectedStatus(-1)) = result else {
			Issue.record("Expected an atomic metadata failure, got \(result)")
			return
		}
		#expect(keychain.storage["project"]?.secrets["TOKEN"] == "local")
		#expect(keychain.dataStorage["__sync_metadata__"] == nil)
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

	@Test("cloud import reports shared auth storage failures")
	func cloudImportReportsAuthStorageFailure() async {
		let importService = MockEnvProjectImportService()
		let keychain = MockKeychainService()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			importServiceFactory: { _ in importService },
			authTokenProvider: { _, _ in throw TestAuthClearError.failed },
			authSessionClearer: { _ in }
		)

		let result = await store.importCloudProject(
			remoteProject(id: "auth-storage-failure", name: "cloud")
		)

		guard case .failure(.authStorage(let message)) = result else {
			Issue.record("Expected an auth-storage failure")
			return
		}
		#expect(message.contains("Could not access the shared LPM session"))
		#expect(keychain.storage.isEmpty)
		#expect(store.projects.isEmpty)
	}

	@Test("successful organization import publishes the final project once")
	func successfulOrganizationImportIsAtomic() async throws {
		let importService = MockEnvProjectImportService()
		importService.organizationResult = .success(
			RemoteEnvProjectPayload(
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
		importService.organizationResult = .success(
			RemoteEnvProjectPayload(
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
		importService.personalResult = .success(
			RemoteEnvProjectPayload(
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
		importService.personalResult = .success(
			RemoteEnvProjectPayload(
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
			orgs: [
				LPMOrg(
					id: "organization-\(slug)",
					slug: slug,
					name: slug.capitalized,
					avatarUrl: nil,
					role: "admin"
				)
			]
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
			members: [
				SyncService.MemberPublicKey(
					userId: "member",
					role: "admin",
					publicKey: keypair.publicKey.base64EncodedString(),
					publicKeyVersion: 1,
					publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
					hasPublicKey: true
				)
			],
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
		store.projects = [
			VaultProject(
				id: projectId,
				name: "Project",
				path: "",
				environments: ["default": ["TOKEN": "secret"]]
			)
		]
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
			await store.logout()
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

@MainActor
private func waitUntil(
	maximumYields: Int = 100_000,
	_ condition: @MainActor () -> Bool
) async {
	for _ in 0..<maximumYields {
		if condition() { return }
		await Task.yield()
	}
	Issue.record("Timed out while waiting for an asynchronous test condition.")
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

private final class AutoLockClock: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: TimeInterval = 0

	var now: TimeInterval {
		get { lock.withLock { storage } }
		set { lock.withLock { storage = newValue } }
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

private actor GatedAuthFailureProvider {
	private let failureCall: Int
	private let gate = AsyncGate()
	private var callCount = 0

	init(failureCall: Int) {
		self.failureCall = failureCall
	}

	func next() async throws -> String? {
		callCount += 1
		guard callCount == failureCall else { return "session-token" }
		await gate.arriveAndWait()
		throw TestAuthClearError.failed
	}

	func waitUntilBlocked() async {
		await gate.waitUntilArrived()
	}

	func release() async {
		await gate.release()
	}
}

private enum TestAuthClearError: Error {
	case failed
}

private func testAuthCredentials(token: String = "login-access") -> AuthSessionCredentials {
	AuthSessionCredentials(
		token: token,
		refreshToken: "login-refresh",
		expiresIn: 3_600,
		expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
	)
}
