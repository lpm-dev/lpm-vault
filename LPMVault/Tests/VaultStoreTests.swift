import CryptoKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import LPMVault

private struct PersistedOrgKeyTrustFixture: Codable {
	let schemaVersion: Int
	let scope: OrgTrustScope
	let trust: OrgKeyTrust
}

@Suite("VaultStore", .serialized)
@MainActor
struct VaultStoreTests {
	private let organizationID = "00000000-0000-4000-8000-000000000001"

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
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextListProjectMetadata = {
			entered.signal()
			release.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)

		let load = Task { await store.loadProjects() }
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.lock()
		release.signal()
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
		#expect(store.projects.first?.id == "id-1")
		#expect(store.projects.first?.hasLoadedEnvironments == false)
		#expect(store.projects.first?.secretCount(for: "default") == 1)
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

	@Test("remove from sidebar removes the project from the list")
	func removeFromSidebar() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: [:])
		])
		store.selectedProjectId = "id-1"

		store.removeFromSidebar(store.projects[0])
		await waitUntil { store.projects.isEmpty }

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
		#expect(keychain.seedSyncMetadata([
			"id-1": SyncMetadata(isDirty: true)
		]))
		let metadataAccount = mockSyncMetadataAccount(vaultId: "id-1")
		let metadataData = try #require(keychain.dataStorage[metadataAccount])
		let associationData = try JSONEncoder().encode(["id-1": "example-org"])
		keychain.dataStorage["__org_associations__"] = associationData
		keychain.failNextWriteDataAccounts.insert("__org_associations__")

		let deleted = await store.deleteLocalVault(store.projects[0])

		#expect(!deleted)
		#expect(keychain.storage["id-1"]?.secrets["TOKEN"] == "secret")
		#expect(keychain.dataStorage[metadataAccount] == metadataData)
		#expect(keychain.dataStorage["__org_associations__"] == associationData)
		#expect(store.projects[0].secrets(for: "default")["TOKEN"] == "secret")
		#expect(keychain.applyVaultTransactionCallCount == 1)
	}

	@Test("metadata failure restores the deleted vault and exact metadata snapshots")
	func localDeletionMetadataFailureRollsBack() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: ["TOKEN": "secret"])
		])
		#expect(keychain.seedSyncMetadata([
			"id-1": SyncMetadata(isDirty: true)
		]))
		let metadataAccount = mockSyncMetadataAccount(vaultId: "id-1")
		let metadataData = try #require(keychain.dataStorage[metadataAccount])
		let associationData = try JSONEncoder().encode(["id-1": "example-org"])
		keychain.dataStorage["__org_associations__"] = associationData
		keychain.failNextDeleteDataAccounts.insert(metadataAccount)

		let deleted = await store.deleteLocalVault(store.projects[0])

		#expect(!deleted)
		#expect(keychain.storage["id-1"]?.secrets["TOKEN"] == "secret")
		#expect(keychain.dataStorage[metadataAccount] == metadataData)
		#expect(keychain.dataStorage["__org_associations__"] == associationData)
		#expect(store.projects[0].secrets(for: "default")["TOKEN"] == "secret")
	}

	@Test("a read failure after the deletion commit cannot report a false failure")
	func committedLocalDeletionDoesNotDependOnFinalReload() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "", secrets: ["TOKEN": "secret"]),
			(id: "id-2", name: "project-b", path: "", secrets: ["OTHER": "value"]),
		])
		store.isUnlocked = true
		keychain.blockNextDeleteProject = { keychain.failProjectReads = true }

		let deleted = await store.deleteLocalVault(store.projects[0])

		#expect(deleted)
		#expect(keychain.storage["id-1"] == nil)
		#expect(store.projects.map(\.id) == ["id-2"])
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

	@Test("deleting another project reloads the selected survivor")
	func localDeletionPreservesNewerSelection() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "alpha", path: "", secrets: ["ONE": "secret"]),
			(id: "id-2", name: "bravo", path: "", secrets: ["TWO": "secret"]),
			(id: "id-3", name: "charlie", path: "", secrets: ["THREE": "secret"]),
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextDeleteProject = {
			entered.signal()
			release.wait()
		}
		store.isUnlocked = true
		store.selectProject("id-3")
		let deletedProject = store.projects.first { $0.id == "id-1" }!

		let deletion = Task { await store.deleteLocalVault(deletedProject) }
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		release.signal()

		#expect(await deletion.value)
		#expect(store.selectedProjectId == "id-3")
		await waitUntil {
			store.projects.first(where: { $0.id == "id-3" })?
				.secrets(for: "default")["THREE"] == "secret"
		}
		#expect(
			store.projects.first(where: { $0.id == "id-3" })?
				.secrets(for: "default")["THREE"] == "secret"
		)
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
	func removalFallbackIsAccountScoped() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "personal", name: "a-personal", path: "", secrets: [:]),
			(id: "org-one", name: "b-org", path: "", secrets: [:]),
			(id: "org-two", name: "c-org", path: "", secrets: [:]),
		])
		store.currentUser = userWithOrganization(slug: "acme")
		store.vaultOrgAssociations = ["org-one": "acme", "org-two": "acme"]
		store.openProject(id: "org-one")

		store.removeFromSidebar(store.projects.first { $0.id == "org-one" }!)
		await waitUntil { store.projects.allSatisfy { $0.id != "org-one" } }

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
		#expect(
			store.projects.first(where: { $0.id == "personal" })?
				.secrets(for: "default").isEmpty == true
		)
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

	@Test("idle timer wakes when the final thirty seconds begin")
	func autoLockSchedulesCountdownWakeup() async {
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
		#expect(await sleeper.durations == [.seconds(90)])
		store.lock()
		await sleeper.resume(at: 0)
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

	@Test("auto-lock counts down every final second and locks at the deadline")
	func autoLockCountdownTracksFinalThirtySeconds() async throws {
		let sleeper = AutoLockSleeper()
		let clock = AutoLockClock()
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) },
			autoLockNow: { clock.now }, autoLockDuration: 120
		)
		defer { store.lock() }
		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == nil)

		for seconds in stride(from: 30, through: 1, by: -1) {
			clock.now = Double(120 - seconds)
			await sleeper.resume(at: 30 - seconds)
			while await sleeper.count < 32 - seconds { await Task.yield() }
			#expect(store.isUnlocked)
			#expect(store.autoLockCountdownSeconds == seconds)
			if seconds == 30 || seconds == 1 {
				try expectRenderedLockTitle(store: store, seconds: seconds)
			}
		}
		#expect(await sleeper.durations == [.seconds(90)] + Array(repeating: .seconds(1), count: 30))
		clock.now = 120
		await sleeper.resume(at: 30)
		while store.isUnlocked { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == nil)
	}

	@Test("user activity clears and postpones the auto-lock countdown")
	func autoLockCountdownResetsWithActivity() async {
		let sleeper = AutoLockSleeper()
		let clock = AutoLockClock()
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) },
			autoLockNow: { clock.now }, autoLockDuration: 120
		)
		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		clock.now = 90
		await sleeper.resume(at: 0)
		while await sleeper.count < 2 { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == 30)

		clock.now = 90.25
		for _ in 0..<100 { store.recordUserActivity() }
		#expect(store.autoLockCountdownSeconds == nil)
		#expect(await sleeper.count == 2)
		clock.now = 91
		await sleeper.resume(at: 1)
		while await sleeper.count < 3 { await Task.yield() }
		#expect(store.isUnlocked)
		#expect(store.autoLockCountdownSeconds == nil)
		#expect(await sleeper.durations.last == .seconds(89.25))

		clock.now = 180.25
		await sleeper.resume(at: 2)
		while await sleeper.count < 4 { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == 30)
		store.lock()
		#expect(store.autoLockCountdownSeconds == nil)
		await sleeper.resume(at: 3)
	}

	@Test("late countdown ticks round up without extending the lock deadline")
	func autoLockCountdownUsesRemainingDeadline() async {
		let sleeper = AutoLockSleeper()
		let clock = AutoLockClock()
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) },
			autoLockNow: { clock.now }, autoLockDuration: 120
		)
		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		clock.now = 91.25
		await sleeper.resume(at: 0)
		while await sleeper.count < 2 { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == 29)
		clock.now = 119.75
		await sleeper.resume(at: 1)
		while await sleeper.count < 3 { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == 1)
		#expect(await sleeper.durations.last == .seconds(0.25))
		clock.now = 121
		await sleeper.resume(at: 2)
		while store.isUnlocked { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == nil)
	}

	@Test("short idle intervals show a countdown immediately")
	func autoLockCountdownSupportsShortIdleIntervals() async {
		let sleeper = AutoLockSleeper()
		let clock = AutoLockClock()
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) },
			autoLockNow: { clock.now }, autoLockDuration: 20
		)
		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == 20)
		#expect(await sleeper.durations == [.seconds(1)])
		clock.now = 20
		store.recordUserActivity()
		#expect(!store.isUnlocked)
		#expect(store.autoLockCountdownSeconds == nil)
		await sleeper.resume(at: 0)
	}

	@Test("a cancelled idle task cannot clear a new session's countdown")
	func staleAutoLockTaskPreservesNewCountdown() async {
		let sleeper = AutoLockSleeper()
		let clock = AutoLockClock()
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			autoLockSleep: { duration in try await sleeper.sleep(duration) },
			autoLockNow: { clock.now }, autoLockDuration: 120
		)
		await store.unlock()
		while await sleeper.count < 1 { await Task.yield() }
		store.lock()
		clock.now = 10
		await store.unlock()
		while await sleeper.count < 2 { await Task.yield() }
		clock.now = 100
		await sleeper.resume(at: 1)
		while await sleeper.count < 3 { await Task.yield() }
		#expect(store.autoLockCountdownSeconds == 30)

		await sleeper.resume(at: 0)
		for _ in 0..<10 { await Task.yield() }
		#expect(store.isUnlocked)
		#expect(store.autoLockCountdownSeconds == 30)
		#expect(await sleeper.count == 3)
		store.lock()
		await sleeper.resume(at: 2)
	}

	private func expectRenderedLockTitle(store: VaultStore, seconds: Int) throws {
		let view = NSHostingView(rootView: VaultTitleBarView(
			store: store, mode: .matrix, onShowVaultID: {}, onPull: {}, onPush: {}
		).environment(\.colorScheme, .light))
		view.frame = NSRect(x: 0, y: 0, width: 1040, height: VaultMetrics.titleBar)
		view.layoutSubtreeIfNeeded()
		let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
		view.cacheDisplay(in: view.bounds, to: bitmap)
		let image = try #require(bitmap.cgImage)
		let data = try #require(bitmap.representation(using: .png, properties: [:]))
		Attachment.record(data, named: "lock-countdown-\(seconds).png")
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		try VNImageRequestHandler(cgImage: image).perform([request])
		let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
		#expect(text.contains("Lock \(seconds)s"))
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
		#expect(store.projects[0].secrets(for: "default")["DB_HOST"] == "localhost")
		#expect(keychain.storage["id-1"]?.secrets["DB_HOST"] == "localhost")
		#expect(keychain.updateEnvironmentsCallCount == 1)
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
		#expect(store.projects[0].secrets(for: "default").isEmpty)
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

		#expect(store.projects[0].secrets(for: "default").isEmpty)
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
		#expect(store.projects[0].secrets(for: "default") == ["HEY": "value"])
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
		#expect(store.projects[0].secrets(for: "default")["TOKEN"] == "secret")
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
		#expect(store.projects[0].secrets(for: "default").isEmpty)
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
		#expect(keychain.storedSyncMetadata(vaultId: "id-1")?.isDirty == true)
	}

	@Test("metadata failure restores add secret vault and metadata snapshots")
	func addSecretMetadataFailureRollsBackBothSnapshots() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["OLD": "value"])
		])
		let previousMetadata = [
			"id-1": mockCurrentSyncMetadata(
				version: 7,
				principalID: "user-1",
				scope: "personal",
				isDirty: false
			)
		]
		#expect(keychain.seedSyncMetadata(previousMetadata))
		let metadataAccount = mockSyncMetadataAccount(vaultId: "id-1")
		let previousMetadataData = try #require(keychain.dataStorage[metadataAccount])
		keychain.failNextWriteDataAccounts = [metadataAccount]
		keychain.failureError = .unexpectedStatus(-1)
		store.syncMetadata = previousMetadata
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "id-1",
			environment: "default",
			key: "TOKEN",
			value: "secret"
		)

		#expect(result == .failure(.persistence(KeychainError.unexpectedStatus(-1).description)))
		#expect(store.projects[0].secrets(for: "default") == ["OLD": "value"])
		#expect(store.syncMetadata["id-1"]?.lastVersion == 7)
		#expect(store.syncMetadata["id-1"]?.isDirty == false)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
		#expect(keychain.dataStorage[metadataAccount] == previousMetadataData)
	}

	@Test("one-shot metadata read failure cannot overwrite the durable snapshot")
	func addSecretMetadataReadFailurePreservesDurableSnapshot() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["OLD": "value"])
		])
		let previousMetadata = SyncMetadata(isDirty: true)
		#expect(keychain.seedSyncMetadata(["id-1": previousMetadata]))
		let metadataAccount = mockSyncMetadataAccount(vaultId: "id-1")
		let previousMetadataData = try #require(keychain.dataStorage[metadataAccount])
		keychain.failNextReadDataAccounts = [metadataAccount]
		store.syncMetadata = ["id-1": previousMetadata]
		store.isUnlocked = true

		let result = await store.addSecret(
			to: "id-1",
			environment: "default",
			key: "TOKEN",
			value: "secret"
		)

		#expect(result == .failure(.persistence(KeychainError.accessDenied.description)))
		#expect(store.projects[0].secrets(for: "default") == ["OLD": "value"])
		#expect(store.syncMetadata["id-1"]?.isDirty == true)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
		#expect(keychain.dataStorage[metadataAccount] == previousMetadataData)
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
		store.isUnlocked = true
		store.selectProject("id-1")
		store.selectedEnvironment = "default"

		let result = await store.importEnvFile(
			at: URL(fileURLWithPath: "/tmp/import.env"),
			to: "id-1",
			environment: "default"
		)

		#expect(result == .success(ImportedEnvFile(secrets: ["IMPORTED": "value"])))
		#expect(
			store.projects[0].secrets(for: "default") == [
				"OLD": "value", "IMPORTED": "value",
			]
		)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value", "IMPORTED": "value"])
		#expect(keychain.updateEnvironmentsCallCount == 1)
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
		store.isUnlocked = true
		store.selectProject("id-1")
		store.selectedEnvironment = "default"

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
		store.isUnlocked = true
		store.selectProject("id-1")

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
		#expect(store.projects[0].secrets(for: "default")["KEY"] == "new")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
	}

	@Test("dotenv import rejects a case-only collision with an existing key")
	func localEnvImportRejectsCaseOnlyExistingCollision() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["HEY": "upper"])],
			envFileImportService: importer
		)
		store.isUnlocked = true
		store.selectProject("id-1")
		await importer.setImmediateResult(
			.success(ImportedEnvFile(secrets: ["Hey": "mixed"]))
		)

		let result = await store.importEnvFile(
			at: URL(fileURLWithPath: "/tmp/collision.env"),
			to: "id-1",
			environment: "default"
		)

		#expect(result == .failure(.caseInsensitiveCollisionWithExisting))
		#expect(store.projects[0].secrets(for: "default") == ["HEY": "upper"])
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
		store.isUnlocked = true
		store.selectProject("id-1")

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
		#expect(store.projects[0].secrets(for: "default") == ["FRESH_ONLY": "new"])
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
		store.isUnlocked = true
		store.selectProject("id-1")

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
		#expect(store.projects[0].secrets(for: "default").isEmpty)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
	}

	@Test("dotenv persistence failure preserves memory and Keychain snapshots")
	func localEnvImportRollsBackOnPersistenceFailure() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])],
			envFileImportService: importer
		)
		store.isUnlocked = true
		store.selectProject("id-1")
		keychain.shouldFail = true

		let result = await store.importEnvFile(
			at: URL(fileURLWithPath: "/tmp/failure.env"),
			to: "id-1", environment: "default"
		)

		guard case .failure(.persistence) = result else {
			Issue.record("Expected persistence failure")
			return
		}
		#expect(store.projects[0].secrets(for: "default") == ["OLD": "value"])
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
	}

	@Test("dotenv vault and dirty metadata persist in one atomic transaction")
	func localEnvImportUsesOneAtomicTransaction() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [(id: "id-1", name: "project", path: "", secrets: ["OLD": "value"])],
			envFileImportService: importer
		)
		keychain.failNextWriteDataAccounts = [mockSyncMetadataAccount(vaultId: "id-1")]
		store.isUnlocked = true
		store.selectProject("id-1")

		let result = await store.importEnvFile(
			at: URL(fileURLWithPath: "/tmp/atomic.env"),
			to: "id-1",
			environment: "default"
		)

		guard case .failure(.persistence) = result else {
			Issue.record("Expected persistence failure")
			return
		}
		#expect(keychain.applyVaultTransactionCallCount == 1)
		#expect(keychain.storage["id-1"]?.secrets == ["OLD": "value"])
		#expect(keychain.storedSyncMetadata(vaultId: "id-1") == nil)
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
		store.isUnlocked = true
		store.selectProject("id-1")

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
		#expect(store.projects[0].secrets(for: "default").isEmpty)
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
		store.isUnlocked = true
		store.selectProject("id-1")

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
		#expect(
			store.projects.first(where: { $0.id == "id-1" })?.environments["staging"]
				== ["PREVIEW": "secret"]
		)
		#expect(keychain.envStorage["id-1"]?.environments["staging"] == ["PREVIEW": "secret"])
	}

	@Test("project switch after dotenv commit preserves the durable project in memory")
	func selectionChangeAfterDotenvCommitPublishesProject() async {
		let importer = MockEnvFileImportService()
		let (store, keychain, _, _) = makeStore(
			projects: [
				(id: "id-1", name: "one", path: "", secrets: [:]),
				(id: "id-2", name: "two", path: "", secrets: [:]),
			],
			envFileImportService: importer
		)
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		store.isUnlocked = true
		store.selectProject("id-1")

		let importOperation = Task {
			await store.importEnvFile(
				at: URL(fileURLWithPath: "/tmp/committed.env"),
				to: "id-1",
				environment: "default"
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

		guard case .success = await importOperation.value else {
			Issue.record("The committed dotenv import did not report success.")
			return
		}
		#expect(store.selectedProjectId == "id-2")
		#expect(
			store.projects.first(where: { $0.id == "id-1" })?
				.secrets(for: "default")["IMPORTED"]
				== "value"
		)
		#expect(keychain.storage["id-1"]?.secrets["IMPORTED"] == "value")
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
		store.isUnlocked = true
		store.selectProject("id-1")

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

	@Test("sidebar removal publishes only after the index update succeeds")
	func failedSidebarRemovalKeepsProjectVisible() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "", secrets: ["TOKEN": "secret"])
		])
		store.selectedProjectId = "id-1"
		keychain.shouldFail = true

		store.removeFromSidebar(store.projects[0])
		await waitUntil { store.error != nil }

		#expect(store.projects.map(\.id) == ["id-1"])
		#expect(store.selectedProjectId == "id-1")
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
		store.isUnlocked = true
		store.selectProject("id-1")

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

		await waitUntil { store.projects[0].secrets(for: "default")["KEY"] == "new" }
		#expect(store.projects[0].secrets(for: "default")["KEY"] == "new")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
	}

	@Test("duplicate editor save activation persists once without a false conflict")
	func duplicateEditorSaveActivationIsSingleFlight() async throws {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")
		var editor = VaultSecretEditDraft(value: "old")
		editor.draft = "new"

		guard let first = editor.beginSave() else {
			Issue.record("The edited draft did not start its first save")
			return
		}
		let duplicate = editor.beginSave()
		let succeeded = await store.updateSecretAndWait(
			in: "id-1",
			environment: "default",
			key: "KEY",
			expectedValue: "old",
			newValue: first
		)
		editor.finishSave(succeeded: succeeded)

		#expect(duplicate == nil)
		#expect(succeeded)
		#expect(keychain.saveEnvironmentsCallCount == 1)
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
		#expect(store.projects[0].secrets(for: "default")["KEY"] == "new")
		#expect(store.syncMetadata["id-1"]?.isDirty == true)
		#expect(store.error == nil)
		#expect(!editor.isDirty)
		#expect(!editor.hasExternalConflict)
	}

	@Test("editor save remains bound to the submitted baseline")
	func editorSaveRejectsAnUpdatePublishedBeforeItsTaskRuns() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")
		var editor = VaultSecretEditDraft(value: "old")
		editor.draft = "submitted"
		guard let submitted = editor.beginSave() else {
			Issue.record("The edited draft did not start its save")
			return
		}
		let expectedValue = editor.baseline

		keychain.simulateCLISet(
			vaultId: "id-1",
			environment: "default",
			key: "KEY",
			value: "external"
		)
		store.projects[0].environments["default"]?["KEY"] = "external"
		editor.receiveExternalValue("external")
		let succeeded = await store.updateSecretAndWait(
			in: "id-1",
			environment: "default",
			key: "KEY",
			expectedValue: expectedValue,
			newValue: submitted
		)
		editor.finishSave(succeeded: succeeded)

		#expect(!succeeded)
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "external")
		#expect(store.projects[0].secrets(for: "default")["KEY"] == "external")
		#expect(editor.hasExternalConflict)
		#expect(editor.isDirty)
	}

	@Test("update non-existent key is no-op")
	func updateNonExistentKey() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "val"])
		])
		store.isUnlocked = true
		store.selectProject("id-1")

		store.updateSecret(in: "id-1", key: "MISSING", newValue: "new")

		#expect(store.projects[0].secrets(for: "default")["KEY"] == "val")
		#expect(store.projects[0].secrets(for: "default")["MISSING"] == nil)
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

		await waitUntil { store.projects[0].secrets(for: "default")["KEY"] == "new" }
		#expect(
			keychain.storage["id-1"]?.secrets == [
				"KEY": "new",
				"CLI_KEY": "cli-value",
			])
		#expect(
			store.projects[0].secrets(for: "default") == [
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
		#expect(store.projects[0].secrets(for: "default")["KEY"] == "cli-value")
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
		#expect(store.projects[0].secrets(for: "default")["KEY"] == "old")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "old")
	}

	@Test("metadata failure rolls back a durable update before UI publication")
	func updateSecretMetadataFailureRollsBack() async {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		keychain.failNextWriteDataAccounts = [mockSyncMetadataAccount(vaultId: "id-1")]
		store.isUnlocked = true
		store.selectProject("id-1")

		store.updateSecret(in: "id-1", key: "KEY", newValue: "new")

		await waitUntil { store.error != nil }
		#expect(store.projects[0].secrets(for: "default")["KEY"] == "old")
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

		await waitUntil { store.projects[0].secrets(for: "default")["A"] == nil }
		#expect(store.projects[0].secrets(for: "default")["A"] == nil)
		#expect(store.projects[0].secrets(for: "default")["B"] == "2")
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
		let (store, keychain, _, _) = makeStore()
		keychain.envStorage = [
			"project-a": (name: "A", path: "", environments: ["default": ["KEY": "a"]]),
			"project-b": (name: "B", path: "", environments: ["default": ["KEY": "b"]]),
		]
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

		#expect(keychain.envStorage["project-a"]?.environments["default"]?["KEY"] == "a")
		#expect(
			store.projects.first(where: { $0.id == "project-a" })?.hasLoadedEnvironments == false
		)
		#expect(store.projects.first(where: { $0.id == "project-a" })?.secretCount == 1)
		#expect(
			store.projects.first(where: { $0.id == "project-b" })?
				.secrets(for: "default")["KEY"] == "b"
		)
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
	func searchBySecretKey() async {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: ["DATABASE_URL": "pg://..."]),
			(
				id: "id-2", name: "project-b", path: "/tmp/b",
				secrets: ["API_KEY": "sk-123"]
			),
		])
		await waitForWorkspaceSnapshots(store, count: 2)

		store.searchQuery = "database"

		#expect(store.filteredVaults.count == 1)
		#expect(store.filteredVaults[0].name == "project-a")
	}

	@Test("search includes keys from every environment")
	func searchAcrossAllEnvironments() async {
		let (store, _, _, _) = makeStore()
		store.projects = [
			VaultProject(
				id: "id-1",
				name: "project",
				path: "",
				environments: [
					"default": ["API_KEY": "value"],
					"production": ["DATABASE_URL": "secret"],
				]
			)
		]
		await waitForWorkspaceSnapshots(store, count: 1)
		store.searchQuery = "database"

		#expect(store.filteredVaults.map(\.id) == ["id-1"])
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

	@Test("startup identity load performs one user request and no token inventory requests")
	func startupIdentityLoadSkipsTokenInventory() async {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 8)
		let authReads = LockedCounter()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in
				authReads.increment()
				return "startup-session"
			}
		)

		await store.loadAccount()

		#expect(authReads.value == 2)
		#expect(api.currentUserFetchCount == 1)
		#expect(api.personalTokenFetchCount == 0)
		#expect(api.orgTokenFetchCount == 0)
		#expect(api.requestedOrgSlugs.isEmpty)
		#expect(store.currentUser?.id == api.user?.id)
	}

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

	@Test("an unauthorized identity response clears stale authenticated state")
	func unauthorizedIdentityClearsPriorState() async {
		let api = MockAPIService()
		let (store, _, _, _) = makeStore(apiService: api)
		store.currentUser = testUser(id: "old", username: "old")
		store.personalTokens = [testToken(id: "old-token")]

		await store.loadTokens()

		#expect(store.currentUser == nil)
		#expect(store.personalTokens.isEmpty)
		#expect(store.orgTokens.isEmpty)
	}

	@Test("organization vault creation rolls back if association persistence fails")
	func organizationVaultCreationIsTransactional() async {
		let (store, keychain, _, _) = makeStore()
		keychain.failWriteDataAccounts.insert("__org_associations__")
		store.isUnlocked = true
		store.selectedAccount = .org("acme")

		let created = await store.createVault(name: "org-vault", orgSlug: "acme")

		#expect(created == .failed)
		#expect(keychain.envStorage.isEmpty)
		#expect(store.projects.isEmpty)
		#expect(store.vaultOrgAssociations.isEmpty)
	}

	@Test("organization creation reports sharing failure and retries the same project")
	func organizationVaultCreationReusesProjectAfterSharingFailure() async throws {
		let (store, _, _, _) = makeStore()
		store.isUnlocked = true
		store.selectedAccount = .org("acme")
		let creationVaultId = "11111111-1111-4111-8111-111111111111"

		let created = await store.createVault(
			name: "org-vault", orgSlug: "acme", vaultId: creationVaultId
		)
		let original = try #require(store.projects.first)
		let retried = await store.createVault(
			name: "org-vault", orgSlug: "acme", vaultId: creationVaultId
		)

		#expect(created == .failed)
		#expect(retried == .failed)
		#expect(store.projects.count == 1)
		#expect(store.projects.first?.id == original.id)
	}

	@Test("organization creation recovers a durable project missing from memory")
	func organizationVaultCreationRecoversPersistedProjectBeforeRetry() async throws {
		let vaultId = "22222222-2222-4222-8222-222222222222"
		let keychain = MockKeychainService()
		keychain.envStorage[vaultId] = (
			name: "org-vault", path: "", environments: ["default": [:]]
		)
		keychain.dataStorage["__org_associations__"] = try JSONEncoder().encode([
			vaultId: "acme"
		])
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)
		store.isUnlocked = true
		store.selectedAccount = .org("acme")

		let result = await store.createVault(
			name: "org-vault", orgSlug: "acme", vaultId: vaultId
		)

		#expect(result == .failed)
		#expect(store.projects.map(\.id) == [vaultId])
		#expect(keychain.saveEnvironmentsCallCount == 0)
	}

	@Test("superseded organization creation does not publish durable recovery")
	func supersededOrganizationVaultCreationDoesNotChangeNavigation() async throws {
		let vaultId = "33333333-3333-4333-8333-333333333333"
		let keychain = MockKeychainService()
		keychain.envStorage[vaultId] = (
			name: "org-vault", path: "", environments: ["default": [:]]
		)
		keychain.dataStorage["__org_associations__"] = try JSONEncoder().encode([
			vaultId: "acme"
		])
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextListProjects = {
			entered.signal()
			release.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)
		store.isUnlocked = true
		store.selectedAccount = .org("acme")
		let creation = Task {
			await store.createVault(name: "org-vault", orgSlug: "acme", vaultId: vaultId)
		}
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.selectedAccount = .personal
		release.signal()

		let result = await creation.value

		#expect(result == .failed)
		#expect(store.projects.isEmpty)
		#expect(store.selectedAccount == .personal)
		#expect(store.selectedProjectId == nil)
	}

	@Test("superseded first organization creation does not change navigation")
	func supersededFirstOrganizationVaultCreationDoesNotChangeNavigation() async {
		let vaultId = "44444444-4444-4444-8444-444444444444"
		let keychain = MockKeychainService()
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)
		store.isUnlocked = true
		store.selectedAccount = .org("acme")
		let creation = Task {
			await store.createVault(name: "org-vault", orgSlug: "acme", vaultId: vaultId)
		}
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.selectAccount(.personal)
		release.signal()

		let result = await creation.value

		#expect(result == .failed)
		#expect(keychain.envStorage[vaultId] != nil)
		#expect(store.projects.isEmpty)
		#expect(store.selectedAccount == .personal)
		#expect(store.selectedProjectId == nil)
	}

	@Test("superseded organization creation record failure does not publish an error")
	func supersededOrganizationVaultCreationRecordFailureDoesNotPublishError() async {
		let keychain = MockKeychainService()
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextListProjects = {
			entered.signal()
			release.wait()
		}
		keychain.failProjectReads = true
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)
		store.isUnlocked = true
		store.selectedAccount = .org("acme")
		let creation = Task {
			await store.createVault(name: "org-vault", orgSlug: "acme")
		}
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				entered.wait()
				continuation.resume()
			}
		}
		store.selectAccount(.personal)
		release.signal()

		let result = await creation.value

		#expect(result == .failed)
		#expect(store.error == nil)
		#expect(store.selectedAccount == .personal)
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
		#expect(store.currentUser == nil)
		#expect(store.personalTokens.isEmpty)
		#expect(store.orgTokens.isEmpty)
		#expect(store.error?.contains("session changed") == true)
	}

	@Test("a revoked session with cleanup failure clears stale identity and org routing")
	func revokedSessionCleanupFailureClearsIdentity() async {
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authAuthorizationProvider: { _, _ in
				throw AuthSessionCoordinatorError.sessionRevokedWithCleanupFailure(
					"Keychain cleanup failed."
				)
			},
			authSessionClearer: { _ in }
		)
		store.currentUser = userWithOrganization(slug: "old-org")
		store.personalTokens = [testToken(id: "old-personal")]
		store.orgTokens = ["old-org": [testToken(id: "old-org-token")]]
		store.selectedAccount = .org("old-org")

		await store.loadAccount()

		#expect(store.currentUser == nil)
		#expect(store.personalTokens.isEmpty)
		#expect(store.orgTokens.isEmpty)
		#expect(store.selectedAccount == .personal)
		#expect(store.error?.contains("cleanup failed") == true)
	}

	@Test("aggregate token inventory rejects excessive organization payloads")
	func aggregateOrganizationTokenInventoryIsBounded() async {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 12)
		let largeName = String(repeating: "x", count: 1_500_000)
		for index in 0..<12 {
			api.orgTokensMap["org-\(index)"] = [LPMToken(
				id: "token-\(index)",
				name: largeName,
				scope: nil,
				expiresAt: nil,
				lastUsedAt: nil,
				downloadCount: nil,
				createdAt: nil,
				orgSlug: "org-\(index)"
			)]
		}
		let (store, _, _, _) = makeStore(apiService: api)

		await store.loadTokens()

		#expect(store.orgTokens.isEmpty)
		#expect(store.error == LPMAPIError.invalidResponse.localizedDescription)
		#expect(api.maximumActiveOrgRequests <= 4)
		#expect(api.requestedOrgSlugs.count < 12)
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

	@Test("oversized organization inventory is rejected before token requests")
	func oversizedOrganizationInventoryIsRejectedBeforeFetch() async {
		let api = MockAPIService()
		api.user = testUserWithOrganizations(count: 257)
		let (store, _, _, _) = makeStore(apiService: api)

		await store.loadTokens()

		#expect(api.requestedOrgSlugs.isEmpty)
		#expect(store.orgTokens.isEmpty)
		#expect(store.error == LPMAPIError.invalidResponse.localizedDescription)
	}

	@Test("malformed identity responses do not replace a coherent account")
	func malformedIdentityResponsesAreRejectedBeforePublication() async {
		let coherent = userWithOrganization(slug: "retained")
		let invalidOrganizations: [[LPMOrg]] = [
			[
				LPMOrg(id: "same", slug: "first", name: "First", avatarUrl: nil, role: "admin"),
				LPMOrg(id: "same", slug: "second", name: "Second", avatarUrl: nil, role: "admin"),
			],
			[
				LPMOrg(id: "first", slug: "same", name: "First", avatarUrl: nil, role: "admin"),
				LPMOrg(id: "second", slug: "same", name: "Second", avatarUrl: nil, role: "admin"),
			],
			[
				LPMOrg(id: "unsafe", slug: "../unsafe", name: "Unsafe", avatarUrl: nil, role: "admin")
			],
			[
				LPMOrg(id: "", slug: "empty-id", name: "Empty", avatarUrl: nil, role: "admin")
			],
			[
				LPMOrg(id: "   ", slug: "blank-id", name: "Blank", avatarUrl: nil, role: "admin")
			],
		]

		for organizations in invalidOrganizations {
			let api = MockAPIService()
			api.user = LPMUser(
				id: "new-user",
				username: "new-user",
				name: nil,
				email: nil,
				avatarUrl: nil,
				plan: nil,
				createdAt: nil,
				orgs: organizations
			)
			let (store, _, _, _) = makeStore(apiService: api)
			store.currentUser = coherent
			store.selectedAccount = .org("retained")

			await store.loadAccount()

			#expect(store.currentUser?.id == coherent.id)
			#expect(store.currentUser?.orgs?.first?.slug == "retained")
			#expect(store.selectedAccount == .org("retained"))
			#expect(store.error == LPMAPIError.invalidResponse.localizedDescription)
		}

		for (id, username) in [("   ", "new-user"), ("new-user", "\t\n")] {
			let api = MockAPIService()
			api.user = LPMUser(
				id: id,
				username: username,
				name: nil,
				email: nil,
				avatarUrl: nil,
				plan: nil,
				createdAt: nil,
				orgs: []
			)
			let (store, _, _, _) = makeStore(apiService: api)
			store.currentUser = coherent
			store.selectedAccount = .org("retained")

			await store.loadAccount()

			#expect(store.currentUser?.id == coherent.id)
			#expect(store.selectedAccount == .org("retained"))
			#expect(store.error == LPMAPIError.invalidResponse.localizedDescription)
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

		@Test("logout cannot be overtaken by a suspended login session write")
		func logoutWinsAgainstSuspendedLoginWrite() async {
			let api = MockAPIService()
			api.user = testUserWithOrganizations(count: 0)
			let writerGate = AsyncGate()
			let session = MutableOptionalString()
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: api,
				authTokenProvider: { _, _ in session.value },
				loginProvider: { _, _ in testAuthCredentials(token: "stale-login-token") },
				authSessionWriter: { credentials, _ in
					await writerGate.arriveAndWait()
					session.value = credentials.token
				},
				authSessionClearer: { _ in session.value = nil }
			)
			store.appEnvironment = .production

			let login = Task { await store.login() }
			await writerGate.waitUntilArrived()
			let logout = Task { await store.logout() }
			await waitUntil { !store.isLoggingIn }
			await writerGate.release()
			await logout.value
			let succeeded = await login.value

			#expect(!succeeded)
			#expect(session.value == nil)
			#expect(store.currentUser == nil)
			#expect(store.personalTokens.isEmpty)
			#expect(store.orgTokens.isEmpty)
			#expect(!store.isLoggingIn)
		}

		#if DEBUG
			@Test("an old-environment logout cannot clear the new environment identity")
			func environmentSwitchWinsAgainstSuspendedLogout() async {
				let clearerGate = AsyncGate()
				let api = MockAPIService()
				api.user = LPMUser(
					id: "development-user",
					username: "development-user",
					name: nil,
					email: nil,
					avatarUrl: nil,
					plan: nil,
					createdAt: nil,
					orgs: nil
				)
				let store = VaultStore(
					keychainService: MockKeychainService(),
					biometricService: MockBiometricService(),
					apiService: api,
					authTokenProvider: { _, _ in "development-session" },
					authSessionClearer: { _ in await clearerGate.arriveAndWait() }
				)
				store.appEnvironment = .production
				store.currentUser = testUserWithOrganizations(count: 0)

				let logout = Task { await store.logout() }
				await clearerGate.waitUntilArrived()
				store.switchEnvironment(to: .development)
				await waitUntil { store.currentUser?.id == "development-user" }
				await clearerGate.release()
				await logout.value

				#expect(store.appEnvironment == .development)
				#expect(store.currentUser?.id == "development-user")
			}
		#endif

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

	@Test("push confirmation counts keys in every environment")
	func pushConfirmationCountsAllEnvironments() throws {
		let (store, _, _, _) = makeStore()
		store.projects = [VaultProject(
			id: "multi-environment",
			name: "Multi-environment",
			path: "",
			environments: [
				"default": ["DEFAULT_KEY": "one"],
				"production": [
					"API_KEY": "two",
					"DATABASE_URL": "three",
					"REDIS_URL": "four",
					"SIGNING_KEY": "five",
				],
			]
		)]
		store.selectProject("multi-environment")

		let confirmation = try #require(store.preparePushConfirmation())

		#expect(confirmation.localKeyCount == 5)
		#expect(confirmation.localKeyCount == store.selectedProject?.secretCount)
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
			ownPublicKey: nil,
			allMembers: [],
			pendingApprovals: [],
			orgTrust: OrgKeyTrust(),
			trustScope: OrgTrustScope(
				registryURL: "https://lpm.dev",
				organizationID: organizationID,
				organizationSlug: "acme"
			)!,
			authToken: "tok",
			callerUserID: "user-1",
			canReplaceWrappedKeys: true
		)
		store.showKeyApprovalSheet = true

		store.rejectPendingOrgPush()

		#expect(store.pendingOrgPush == nil)
		#expect(store.showKeyApprovalSheet == false)
		#expect(store.lastSyncStatus == "rejected")
		#expect(store.error != nil)
	}

	@Test("organization trust read failures stop sharing instead of appearing untrusted")
	func organizationTrustReadFailureStopsPush() async {
		let fixture = makeOrgTrustFixture()
		fixture.keychain.failDataAccounts.insert(fixture.trustAccount)

		await fixture.store.pushToOrg(orgSlug: fixture.slug)

		#expect(fixture.store.pendingOrgPush == nil)
		#expect(!fixture.store.showKeyApprovalSheet)
		#expect(fixture.sync.pushCallCount == 0)
		#expect(fixture.store.lastSyncStatus == "failed")
	}

	@Test("protocol revision ceiling stops organization encryption and push")
	func protocolRevisionCeilingStopsOrganizationPush() async throws {
		let fixture = makeOrgTrustFixture()
		let projectID = try #require(fixture.store.selectedProjectId)
		let metadata = mockCurrentSyncMetadata(
			version: Int(Int32.max),
			principalID: organizationID,
			scope: "organization"
		)
		fixture.store.syncMetadata = [projectID: metadata]
		#expect(fixture.keychain.seedSyncMetadata([projectID: metadata]))
		let binding = SyncPrincipalBinding(
			registryURL: fixture.store.appEnvironment.registryURL,
			principalID: organizationID,
			scope: "organization"
		)
		#expect(fixture.keychain.storedSyncMetadata(vaultId: projectID)?.binding == binding)
		let snapshot = await VaultPersistenceCoordinator(service: fixture.keychain)
			.syncSnapshot(vaultId: projectID, binding: binding)
		#expect(snapshot?.metadata?.version(boundTo: binding) == Int(Int32.max))

		await fixture.store.pushToOrg(orgSlug: fixture.slug)
		let approvals = try #require(fixture.store.pendingOrgPush?.pendingApprovals)
		await fixture.store.approveAndContinueOrgPush(approved: approvals)

		#expect(fixture.sync.pushCallCount == 0)
		#expect(fixture.store.lastSyncStatus == "failed")
		#expect(fixture.store.syncMetadata[projectID]?.lastVersion == Int(Int32.max))
	}

	@Test("organization approval never pushes before trust is durable")
	func organizationTrustWriteFailureStopsApprovedPush() async throws {
		let fixture = makeOrgTrustFixture()
		await fixture.store.pushToOrg(orgSlug: fixture.slug)
		let approvals = try #require(fixture.store.pendingOrgPush?.pendingApprovals)
		fixture.keychain.failWriteDataAccounts.insert(fixture.trustAccount)

		await fixture.store.approveAndContinueOrgPush(approved: approvals)

		#expect(fixture.sync.pushCallCount == 0)
		#expect(fixture.store.lastSyncStatus == "failed")
		#expect(fixture.store.error?.contains("trust") == true)
	}

	@Test("duplicate organization approval activation cannot cancel the claimed push")
	func duplicateOrganizationApprovalActivationIsIgnored() async throws {
		let fixture = makeOrgTrustFixture()
		await fixture.store.pushToOrg(orgSlug: fixture.slug)
		let approvals = try #require(fixture.store.pendingOrgPush?.pendingApprovals)
		let gate = AsyncGate()
		fixture.sync.blockNextMemberKeyAccess = { await gate.arriveAndWait() }
		let projectID = try #require(fixture.store.selectedProjectId)
		fixture.sync.pushResult = SyncService.SyncStatus(
			vaultId: projectID,
			version: 1,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: organizationID
		)

		let claimedPush = Task {
			await fixture.store.approveAndContinueOrgPush(approved: approvals)
		}
		await gate.waitUntilArrived()
		await fixture.store.approveAndContinueOrgPush(approved: approvals)
		await gate.release()
		await claimedPush.value

		#expect(fixture.sync.pushCallCount == 1)
		#expect(fixture.store.syncMetadata[projectID]?.lastVersion == 1)
		#expect(fixture.store.pendingOrgPush == nil)
		#expect(!fixture.store.isSyncing)
	}

	@Test("transient auth failure after organization approval is actionable")
	func organizationApprovalReportsTransientAuthFailure() async throws {
		let tokenProvider = FailableAuthTokenProvider()
		let fixture = makeOrgTrustFixture(authTokenResolver: {
			try tokenProvider.resolve()
		})
		await fixture.store.pushToOrg(orgSlug: fixture.slug)
		let approvals = try #require(fixture.store.pendingOrgPush?.pendingApprovals)
		tokenProvider.shouldFail = true

		await fixture.store.approveAndContinueOrgPush(approved: approvals)

		#expect(fixture.sync.memberKeyAccessCallCount == 1)
		#expect(fixture.sync.pushCallCount == 0)
		#expect(fixture.store.pendingOrgPush == nil)
		#expect(!fixture.store.showKeyApprovalSheet)
		#expect(!fixture.store.isSyncing)
		#expect(fixture.store.lastSyncStatus == "failed")
		#expect(fixture.store.error?.contains("Could not access the shared LPM session") == true)
	}

	@Test("definitive credential loss during organization approval clears account state")
	func organizationApprovalCredentialLossClearsAccountState() async throws {
		let token = MutableOptionalString("session-token")
		let fixture = makeOrgTrustFixture(authToken: token)
		fixture.store.personalTokens = [testToken(id: "personal-token")]
		await fixture.store.pushToOrg(orgSlug: fixture.slug)
		let approvals = try #require(fixture.store.pendingOrgPush?.pendingApprovals)

		token.value = nil
		await fixture.store.approveAndContinueOrgPush(approved: approvals)

		#expect(fixture.sync.pushCallCount == 0)
		#expect(fixture.store.pendingOrgPush == nil)
		#expect(fixture.store.currentUser == nil)
		#expect(fixture.store.personalTokens.isEmpty)
		#expect(fixture.store.selectedAccount == .personal)
	}

	@Test("organization sharing key lookup executes away from the main thread")
	func organizationKeypairLookupIsBackground() async {
		let recorder = MainThreadRecorder()
		let fixture = makeOrgTrustFixture { recorder.capture() }

		await fixture.store.pushToOrg(orgSlug: fixture.slug)

		#expect(recorder.value == false)
	}

	@Test("security transitions discard pending organization authorization")
	func securityTransitionsDiscardPendingOrgAuthorization() async {
		let (store, _, _, _) = makeStore()
		func seedApproval() {
			store.pendingOrgPush = PendingOrgPush(
				orgSlug: "acme",
				projectId: "p1",
				ownPublicKey: nil,
				allMembers: [],
				pendingApprovals: [],
				orgTrust: OrgKeyTrust(),
				trustScope: OrgTrustScope(
					registryURL: "https://lpm.dev",
					organizationID: organizationID,
					organizationSlug: "acme"
				)!,
				authToken: "retained-token",
				callerUserID: "user-1",
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

	@Test("organization approval refetch rejects every changed authorization binding")
	func organizationApprovalRefetchRejectsChangedAuthorization() async throws {
		for change in [
			"caller", "member removal", "member key", "member role", "capability", "own key",
			"own version",
		] {
			let slug = "approval-\(UUID().uuidString.lowercased())"
			let projectID = "project-\(UUID().uuidString.lowercased())"
			let localKeypair = VaultCrypto.generateX25519Keypair()
			let memberKeypair = VaultCrypto.generateX25519Keypair()
			let currentMember = SyncService.MemberPublicKey(
				userId: "u1",
				role: "admin",
				publicKey: localKeypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey),
				hasPublicKey: true
			)
			let member = SyncService.MemberPublicKey(
				userId: "member",
				role: "admin",
				publicKey: memberKeypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(memberKeypair.publicKey),
				hasPublicKey: true
			)
			let sync = MockOrgSyncService()
			sync.publicKeyRecord = SyncService.PublicKeyRecord(
				publicKey: localKeypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey)
			)
			sync.memberKeyAccess = SyncService.MemberKeyAccess(
				organizationID: organizationID,
				callerUserID: "u1",
				members: [currentMember, member],
				canReplaceWrappedKeys: true
			)
			let keychain = MockKeychainService()
			keychain.envStorage[projectID] = (
				name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
			)
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				orgSyncServiceFactory: { _ in sync },
				sharingKeypairProvider: { localKeypair },
				authTokenProvider: { _, _ in "session-token" }
			)
			store.currentUser = userWithOrganization(slug: slug)
			store.projects = [
				VaultProject(
					id: projectID,
					name: "Project",
					path: "",
					environments: ["default": ["TOKEN": "secret"]]
				)
			]
			store.vaultOrgAssociations[projectID] = slug
			store.isUnlocked = true
			store.selectAccount(.org(slug))
			store.selectProject(projectID)

			await store.pushToOrg(orgSlug: slug)
			let approval = try #require(store.pendingOrgPush?.pendingApprovals)
			#expect(approval.count == 2)

			switch change {
			case "caller":
				sync.memberKeyAccess = SyncService.MemberKeyAccess(
					organizationID: organizationID,
					callerUserID: "u2",
					members: [currentMember, member],
					canReplaceWrappedKeys: true
				)
			case "member removal":
				sync.memberKeyAccess = SyncService.MemberKeyAccess(
					organizationID: organizationID,
					callerUserID: "u1",
					members: [currentMember], canReplaceWrappedKeys: true)
			case "member key":
				let rotated = VaultCrypto.generateX25519Keypair().publicKey
				sync.memberKeyAccess = SyncService.MemberKeyAccess(
					organizationID: organizationID,
					callerUserID: "u1",
					members: [
						currentMember,
						SyncService.MemberPublicKey(
							userId: member.userId,
							role: member.role,
							publicKey: rotated.base64EncodedString(),
							publicKeyVersion: 2,
							publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(rotated),
							hasPublicKey: true
						),
					],
					canReplaceWrappedKeys: true
				)
			case "member role":
				sync.memberKeyAccess = SyncService.MemberKeyAccess(
					organizationID: organizationID,
					callerUserID: "u1",
					members: [
						currentMember,
						SyncService.MemberPublicKey(
							userId: member.userId,
							role: "member",
							publicKey: member.publicKey,
							publicKeyVersion: member.publicKeyVersion,
							publicKeyFingerprint: member.publicKeyFingerprint,
							hasPublicKey: true
						),
					],
					canReplaceWrappedKeys: true
				)
			case "capability":
				sync.memberKeyAccess = SyncService.MemberKeyAccess(
					organizationID: organizationID,
					callerUserID: "u1",
					members: [currentMember, member], canReplaceWrappedKeys: false)
			case "own key":
				let rotated = VaultCrypto.generateX25519Keypair().publicKey
				sync.memberKeyAccess = SyncService.MemberKeyAccess(
					organizationID: organizationID,
					callerUserID: "u1",
					members: [
						SyncService.MemberPublicKey(
							userId: currentMember.userId,
							role: currentMember.role,
							publicKey: rotated.base64EncodedString(),
							publicKeyVersion: 2,
							publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(rotated),
							hasPublicKey: true
						),
						member,
					],
					canReplaceWrappedKeys: true
				)
			case "own version":
				sync.memberKeyAccess = SyncService.MemberKeyAccess(
					organizationID: organizationID,
					callerUserID: "u1",
					members: [
						SyncService.MemberPublicKey(
							userId: currentMember.userId,
							role: currentMember.role,
							publicKey: currentMember.publicKey,
							publicKeyVersion: 2,
							publicKeyFingerprint: currentMember.publicKeyFingerprint,
							hasPublicKey: true
						),
						member,
					],
					canReplaceWrappedKeys: true
				)
			default:
				Issue.record("Unknown authorization-change fixture")
			}

			await store.approveAndContinueOrgPush(approved: approval)

			#expect(sync.pushCallCount == 0, "Unexpected push after \(change)")
			#expect(store.lastSyncStatus == "failed", "Unexpected status after \(change)")
			#expect(store.error != nil, "Missing error after \(change)")
			#expect(store.pendingOrgPush == nil)
			#expect(sync.publicKeyCallCount == 0)
		}
	}

	@Test("maintainer push rejects an unbound sharing-key response")
	func maintainerPushRejectsUnboundSharingKeyResponse() async throws {
		let projectID = "maintainer-project"
		let slug = "acme"
		let keypair = VaultCrypto.generateX25519Keypair()
		let contentKey = VaultCrypto.generateAESKey()
		let wrappedKey = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)
		let fingerprint = VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		let member = SyncService.MemberPublicKey(
			userId: "u1",
			role: "admin",
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: fingerprint,
			hasPublicKey: true
		)
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: fingerprint
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: organizationID,
			callerUserID: "u1",
			members: [member],
			canReplaceWrappedKeys: false
		)
		sync.pullResult = SyncService.SyncStatus(
			vaultId: projectID,
			version: 4,
			cryptoVersion: nil,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: fingerprint,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: "ciphertext",
			wrappedKey: wrappedKey,
			updatedAt: nil,
			principalId: organizationID,
			callerUserId: "u1",
			organizationId: organizationID
		)
		sync.pushResult = SyncService.SyncStatus(
			vaultId: projectID,
			version: 5,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: fingerprint,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: organizationID
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Maintainer",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let metadata = mockCurrentSyncMetadata(
			version: 4,
			principalID: organizationID,
			scope: "organization"
		)
		#expect(keychain.seedSyncMetadata([projectID: metadata]))
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.appEnvironment = .production
		store.currentUser = userWithOrganization(slug: slug)
		let trustScope = try #require(
			OrgTrustScope(
				registryURL: store.appEnvironment.registryURL,
				organizationID: organizationID,
				organizationSlug: slug
			)
		)
		let persistedTrust = PersistedOrgKeyTrustFixture(
			schemaVersion: 3,
			scope: trustScope,
			trust: OrgKeyTrust(trustedFingerprints: [member.userId: fingerprint])
		)
		keychain.dataStorage[trustScope.storageAccount] = try JSONEncoder().encode(persistedTrust)
		store.projects = [VaultProject(
			id: projectID,
			name: "Maintainer",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.syncMetadata = [projectID: metadata]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		await store.pushToOrg(orgSlug: slug)

		#expect(sync.pushCallCount == 0)
		#expect(store.lastSyncStatus == "failed")
		#expect(store.error?.contains("invalid sharing-key binding") == true)
	}

	@Test("maintainer push authenticates the current ciphertext before reusing its key")
	func maintainerPushAuthenticatesCurrentCiphertextBeforeKeyReuse() async throws {
		let fixture = makeOrgTrustFixture()
		let store = fixture.store
		let sync = fixture.sync
		let projectID = try #require(store.selectedProject?.id)
		let member = try #require(sync.memberKeyAccess?.members.first)
		let memberPublicKeyBase64 = try #require(member.publicKey)
		let memberPublicKey = try #require(Data(base64Encoded: memberPublicKeyBase64))
		let memberFingerprint = try #require(member.publicKeyFingerprint)
		let contentKey = VaultCrypto.generateAESKey()
		let wrappedKey = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: memberPublicKey
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: organizationID,
			callerUserID: "u1",
			members: [member],
			canReplaceWrappedKeys: false
		)
		let metadata = mockCurrentSyncMetadata(
			version: 4,
			principalID: organizationID,
			scope: "organization"
		)
		#expect(fixture.keychain.seedSyncMetadata([projectID: metadata]))
		store.syncMetadata = [projectID: metadata]
		let trustScope = try #require(
			OrgTrustScope(
				registryURL: store.appEnvironment.registryURL,
				organizationID: organizationID,
				organizationSlug: fixture.slug
			)
		)
		fixture.keychain.dataStorage[fixture.trustAccount] = try JSONEncoder().encode(
			PersistedOrgKeyTrustFixture(
				schemaVersion: 3,
				scope: trustScope,
				trust: OrgKeyTrust(trustedFingerprints: [member.userId: memberFingerprint])
			)
		)
		sync.pullResult = SyncService.SyncStatus(
			vaultId: projectID,
			version: 4,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: member.publicKeyVersion,
			recipientPublicKeyFingerprint: memberFingerprint,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: "invalid-current-ciphertext",
			wrappedKey: wrappedKey,
			updatedAt: nil,
			principalId: organizationID,
			callerUserId: "u1",
			organizationId: organizationID
		)
		sync.pushResult = SyncService.SyncStatus(
			vaultId: projectID,
			version: 5,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: member.publicKeyVersion,
			recipientPublicKeyFingerprint: memberFingerprint,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: organizationID
		)

		await store.pushToOrg(orgSlug: fixture.slug)

		#expect(sync.pushCallCount == 0)
		#expect(store.lastSyncStatus == "failed")
		#expect(store.error?.contains("current organization env project") == true)
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
		store.currentUser = testUser(id: "account-1", username: "user")
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
		_ = await pull.value

		#expect(store.projects.first?.secrets(for: "default")["TOKEN"] == "local")
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
			stableSyncEncryptor: { _, _, _, _ in ("test-blob", "test-wrapped-key") },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = testUser(id: "account-1", username: "user")
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
		_ = await push.value

		#expect(store.selectedProjectId == "project-b")
		#expect(store.lastSyncStatus == nil)
		#expect(store.syncMetadata["project-a"] == nil)
		#expect(!store.isSyncing)
	}

	@Test("project navigation preserves a successful remote push acknowledgement")
	func projectNavigationPreservesPersonalPushAcknowledgement() async {
		let gate = AsyncGate()
		let sync = MockPersonalSyncService()
		sync.pushHandlers = [
			{
				await gate.arriveAndWait()
				return SyncService.SyncStatus(
					vaultId: "project-a",
					version: 1,
					cryptoVersion: VaultCrypto.currentCryptoVersion,
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
					updatedAt: nil,
					principalId: "account-1"
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
			stableSyncEncryptor: { _, _, _, _ in ("test-blob", "test-wrapped-key") },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = testUser(id: "account-1", username: "user")
		store.projects = [
			VaultProject(
				id: "project-a", name: "A", path: "",
				environments: ["default": ["TOKEN": "a"]]),
			VaultProject(
				id: "project-b", name: "B", path: "",
				environments: ["default": ["TOKEN": "b"]]),
		]
		store.isUnlocked = true
		store.selectProject("project-a")

		let push = Task { await store.pushToCloud() }
		await gate.waitUntilArrived()
		store.selectProject("project-b")
		await gate.release()
		await push.value

		#expect(store.selectedProjectId == "project-b")
		#expect(store.syncMetadata["project-a"]?.lastVersion == 1)
		#expect(store.lastSyncStatus == nil)
		#expect(keychain.storedSyncMetadata(vaultId: "project-a")?.lastVersion == 1)
	}

	@Test("a stale approval continuation preserves a newer pending organization push")
	func staleApprovalPreservesNewerPendingPush() async throws {
		let slug = "approval-race"
		let localKeypair = VaultCrypto.generateX25519Keypair()
		let memberKeypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: localKeypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey)
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: organizationID,
			callerUserID: "u1",
			members: [
				SyncService.MemberPublicKey(
					userId: "u1",
					role: "admin",
					publicKey: localKeypair.publicKey.base64EncodedString(),
					publicKeyVersion: 1,
					publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey),
					hasPublicKey: true
				),
				SyncService.MemberPublicKey(
					userId: "member",
					role: "admin",
					publicKey: memberKeypair.publicKey.base64EncodedString(),
					publicKeyVersion: 1,
					publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(memberKeypair.publicKey),
					hasPublicKey: true
				),
			],
			canReplaceWrappedKeys: true
		)
		let staleResolutionGate = AsyncGate()
		let tokenProvider = GatedTokenProvider(token: "session-token")
		let keychain = MockKeychainService()
		for projectID in ["project-a", "project-b"] {
			keychain.envStorage[projectID] = (
				name: projectID,
				path: "",
				environments: ["default": ["TOKEN": projectID]]
			)
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { localKeypair },
			authTokenProvider: { _, _ in await tokenProvider.resolve() }
		)
		store.currentUser = userWithOrganization(slug: slug)
		store.projects = [
			VaultProject(
				id: "project-a",
				name: "A",
				path: "",
				environments: ["default": ["TOKEN": "a"]]
			),
			VaultProject(
				id: "project-b",
				name: "B",
				path: "",
				environments: ["default": ["TOKEN": "b"]]
			),
		]
		store.vaultOrgAssociations = ["project-a": slug, "project-b": slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject("project-a")

		await store.pushToOrg(orgSlug: slug)
		let staleApprovals = try #require(store.pendingOrgPush?.pendingApprovals)
		await tokenProvider.setGate(staleResolutionGate)
		let staleApproval = Task {
			await store.approveAndContinueOrgPush(approved: staleApprovals)
		}
		await staleResolutionGate.waitUntilArrived()

		await tokenProvider.setGate(nil)
		store.selectProject("project-b")
		await store.pushToOrg(orgSlug: slug)
		let newerApprovals = try #require(store.pendingOrgPush?.pendingApprovals)
		#expect(store.pendingOrgPush?.projectId == "project-b")
		#expect(!newerApprovals.isEmpty)

		await staleResolutionGate.release()
		await staleApproval.value

		#expect(store.pendingOrgPush?.projectId == "project-b")
		#expect(PendingKeyApproval.exactlyMatches(
			store.pendingOrgPush?.pendingApprovals ?? [],
			pending: newerApprovals
		))
		#expect(store.showKeyApprovalSheet)
	}

	@Test("project navigation preserves a successful organization push acknowledgement")
	func projectNavigationPreservesOrganizationPushAcknowledgement() async throws {
		let slug = "acme"
		let gate = AsyncGate()
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: organizationID,
			callerUserID: "u1",
			members: [
				SyncService.MemberPublicKey(
					userId: "u1",
					role: "owner",
					publicKey: keypair.publicKey.base64EncodedString(),
					publicKeyVersion: 1,
					publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
					hasPublicKey: true
				)
			],
			canReplaceWrappedKeys: true
		)
		sync.pushResult = SyncService.SyncStatus(
			vaultId: "project-a",
			version: 1,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: organizationID
		)
		sync.blockNextPush = { await gate.arriveAndWait() }
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
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = userWithOrganization(slug: slug)
		store.projects = [
			VaultProject(
				id: "project-a", name: "A", path: "",
				environments: ["default": ["TOKEN": "a"]]),
			VaultProject(
				id: "project-b", name: "B", path: "",
				environments: ["default": ["TOKEN": "b"]]),
		]
		store.vaultOrgAssociations = ["project-a": slug, "project-b": slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject("project-a")

		await store.pushToOrg(orgSlug: slug)
		let approvals = try #require(store.pendingOrgPush?.pendingApprovals)
		let push = Task { await store.approveAndContinueOrgPush(approved: approvals) }
		await gate.waitUntilArrived()
		store.selectProject("project-b")
		await gate.release()
		await push.value

		#expect(store.selectedProjectId == "project-b")
		#expect(store.syncMetadata["project-a"]?.lastVersion == 1)
		#expect(store.lastSyncStatus == nil)
		#expect(store.pendingOrgPush == nil)
		#expect(keychain.storedSyncMetadata(vaultId: "project-a")?.lastVersion == 1)
	}

	@Test("network protocol v1 personal pulls are rejected without migration")
	func networkProtocolV1PersonalPullIsRejectedWithoutMigration() async throws {
		let token = "legacy-session-token"
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "remote"]]
		])
		let contentKey = VaultCrypto.generateAESKey()
		let encryptedBlob = try VaultCrypto.encrypt(key: contentKey, plaintext: payload)
		let wrappedKey = try VaultCrypto.wrapKey(
			wrappingKey: VaultCrypto.generateAESKey(),
			aesKey: contentKey
		)
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [{
			SyncService.SyncStatus(
				vaultId: "project-a",
				version: 1,
				cryptoVersion: 1,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: encryptedBlob,
				wrappedKey: wrappedKey,
				updatedAt: nil,
				principalId: "account-1"
			)
		}]
		sync.pushHandlers = [{
			SyncService.SyncStatus(
				vaultId: "project-a",
				version: 2,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
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
				updatedAt: nil,
				principalId: "account-1"
			)
		}]
		let migratedRevisionMatches = LockedCounter()
		let decryptions = LockedCounter()
		let keychain = MockKeychainService()
		keychain.envStorage["project-a"] = (
			name: "A",
			path: "",
			environments: ["default": ["TOKEN": "local", "LOCAL_ONLY": "pending"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, revision in
				if revision == 2 { migratedRevisionMatches.increment() }
				return ("v3-ciphertext", "stable-wrapped-key")
			},
			stableSyncDecryptor: { blob, wrapped, principalID, vaultID, revision, version in
				decryptions.increment()
				return Data(try VaultCrypto.decryptStableSync(
					encryptedBlob: blob,
					wrappedKey: wrapped,
					principalId: principalID,
					vaultId: vaultID,
					revision: revision,
					cryptoVersion: version,
					wrappingKey: VaultCrypto.generateAESKey()
				).utf8)
			},
			authTokenProvider: { _, _ in token }
		)
		store.currentUser = testUser(id: "account-1", username: "user")
		store.projects = [VaultProject(
			id: "project-a", name: "A", path: "",
			environments: ["default": ["TOKEN": "local", "LOCAL_ONLY": "pending"]]
		)]
		store.isUnlocked = true
		store.selectProject("project-a")

		await store.pullFromCloud()

		#expect(keychain.envStorage["project-a"]?.environments["default"]?["TOKEN"] == "local")
		#expect(keychain.envStorage["project-a"]?.environments["default"]?["LOCAL_ONLY"] == "pending")
		#expect(store.projects[0].secrets(for: "default")["TOKEN"] == "local")
		#expect(store.syncMetadata["project-a"] == nil)
		#expect(sync.pushCallCount == 0)
		#expect(sync.pushedExpectedVersions.isEmpty)
		#expect(migratedRevisionMatches.value == 0)
		#expect(decryptions.value == 0)
		#expect(store.lastSyncStatus == "failed")
		#expect(store.error == "The cloud response uses an unsupported encryption version.")
	}

	@Test("network protocol v2 personal pulls are rejected without migration")
	func networkProtocolV2PersonalPullIsRejectedWithoutMigration() async throws {
		let projectID = "vault-v2"
		let wrappingKey = VaultCrypto.generateAESKey()
		let contentKey = SymmetricKey(data: Data(repeating: 0x07, count: 32))
		let wrappedKey = try VaultCrypto.wrapKey(
			wrappingKey: wrappingKey,
			aesKey: contentKey
		)
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [{
			SyncService.SyncStatus(
				vaultId: projectID,
				version: 42,
				cryptoVersion: 2,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: "AAECAwQFBgcICQoL:Y6OMHmtgqyYZ34DylitOwJoe0ut+AwJdYuxZwayDIk6bIWTYtaNUmpWGupsqxZdOiU3roLYywwVsmTsvH1+umdml",
				wrappedKey: wrappedKey,
				updatedAt: nil,
				principalId: "account-1"
			)
		}]
		sync.pushHandlers = [{
			SyncService.SyncStatus(
				vaultId: projectID,
				version: 43,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
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
				updatedAt: nil,
				principalId: "account-1"
			)
		}]
		let keychain = MockKeychainService()
		let decryptions = LockedCounter()
		keychain.envStorage[projectID] = (
			name: "V2",
			path: "",
			environments: ["default": [:]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in ("v3-ciphertext", "v3-wrapped") },
			stableSyncDecryptor: { blob, wrapped, principalID, vaultID, revision, version in
				decryptions.increment()
				return Data(try VaultCrypto.decryptStableSync(
					encryptedBlob: blob,
					wrappedKey: wrapped,
					principalId: principalID,
					vaultId: vaultID,
					revision: revision,
					cryptoVersion: version,
					wrappingKey: wrappingKey
				).utf8)
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = testUser(id: "account-1", username: "user")
		store.projects = [VaultProject(
			id: projectID,
			name: "V2",
			path: "",
			environments: ["default": [:]]
		)]
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pullFromCloud()

		#expect(store.projects[0].secrets(for: "default")["TOKEN"] == nil)
		#expect(store.syncMetadata[projectID] == nil)
		#expect(sync.pushedExpectedVersions.isEmpty)
		#expect(decryptions.value == 0)
		#expect(store.lastSyncStatus == "failed")
		#expect(store.error == "The cloud response uses an unsupported encryption version.")
	}

	@Test("network protocol v2 organization pulls are rejected atomically")
	func networkProtocolV2OrganizationPullIsRejectedAtomically() async throws {
		let projectID = "vault-v2"
		let slug = "acme"
		let keypair = VaultCrypto.generateX25519Keypair()
		let contentKey = SymmetricKey(data: Data(repeating: 0x07, count: 32))
		let wrappedKey = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		sync.pullResult = SyncService.SyncStatus(
			vaultId: projectID,
			version: 42,
			cryptoVersion: 2,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: "AAECAwQFBgcICQoL:Y6OMHmtgqyYZ34DylitOwJoe0ut+AwJdYuxZwayDIk6bIWTYtaNUmpWGupsqxZdOiU3ZMTOOaeQzofBq2J70KYi7",
			wrappedKey: wrappedKey,
			updatedAt: nil,
			principalId: "org-1",
			callerUserId: "user-1",
			organizationId: "org-1"
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "V2 Org",
			path: "",
			environments: ["default": [:]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = LPMUser(
			id: "user-1",
			username: "user",
			name: nil,
			email: nil,
			avatarUrl: nil,
			plan: nil,
			createdAt: nil,
			orgs: [LPMOrg(
				id: "org-1",
				slug: slug,
				name: "Acme",
				avatarUrl: nil,
				role: "owner"
			)]
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "V2 Org",
			path: "",
			environments: ["default": [:]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		await store.pullFromOrg(orgSlug: slug)

		#expect(store.projects[0].secrets(for: "default")["TOKEN"] == nil)
		#expect(store.syncMetadata[projectID] == nil)
		#expect(store.lastSyncStatus == "failed")
		#expect(
			store.error
				== "Org pull failed: The organization response has an invalid sharing-key binding."
		)
		#expect(sync.pullCallCount == 1)
		#expect(sync.publicKeyCallCount == 0)
	}

	@Test("member rewrap with the registered local key asks an administrator to share again")
	func memberRewrapWithRegisteredLocalKeyAsksAdministratorToShareAgain() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.pullResult = memberRewrapStatus(vaultId: "rewrap")
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
			principalId: "user-1"
		)
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(
			store.error
				== "Org pull failed: Your registered sharing key does not have access to this env project yet. Ask an organization admin to share it again."
		)
		#expect(sync.publicKeyCallCount == 1)
	}

	@Test("member rewrap without a registered key keeps the registration guidance")
	func memberRewrapWithoutRegisteredKeyKeepsRegistrationGuidance() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.pullResult = memberRewrapStatus(vaultId: "rewrap")
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(
			store.error
				== "Org pull failed: Your sharing key is not registered. Run `lpm env share --org acme` once, then retry."
		)
		#expect(sync.publicKeyCallCount == 1)
	}

	@Test("member rewrap with a different registered key keeps the device rejection")
	func memberRewrapWithDifferentRegisteredKeyKeepsDeviceRejection() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let registered = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.pullResult = memberRewrapStatus(vaultId: "rewrap")
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: registered.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(registered.publicKey),
			principalId: "user-1"
		)
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(
			store.error
				== "Org pull failed: This device does not hold the sharing key registered for your account."
		)
		#expect(sync.publicKeyCallCount == 1)
	}

	@Test("organization pull rejects a substituted authenticated caller before key lookup")
	func organizationPullRejectsSubstitutedCallerBeforeKeyLookup() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.pullResult = SyncService.SyncStatus(
			vaultId: "rewrap",
			version: 1,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: 1,
			hint: nil,
			encryptedBlob: "ciphertext",
			wrappedKey: "wrapped",
			updatedAt: nil,
			principalId: organizationID,
			callerUserId: "other-user",
			organizationId: organizationID
		)
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(
			store.error
				== "Org pull failed: The organization pull response did not match this env project or contain a valid version."
		)
		#expect(sync.publicKeyCallCount == 0)
	}

	@Test("member rewrap rejects a substituted authenticated caller before key lookup")
	func memberRewrapRejectsSubstitutedCallerBeforeKeyLookup() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.pullResult = memberRewrapStatus(vaultId: "rewrap", callerUserID: "other-user")
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(
			store.error
				== "Org pull failed: The organization access response did not match the authenticated account."
		)
		#expect(sync.publicKeyCallCount == 0)
	}

	@Test("other organization pull errors do not fetch the public key")
	func otherOrganizationPullErrorsDoNotFetchPublicKey() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.pullResult = SyncService.SyncStatus(
			vaultId: "rewrap",
			version: 1,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "error",
			error: "Access denied",
			code: "vault_access_denied",
			serverVersion: nil,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: organizationID,
			callerUserId: "user-1",
			organizationId: organizationID
		)
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(store.error == "Access denied")
		#expect(sync.publicKeyCallCount == 0)
	}

	@Test("unauthorized organization pulls do not fetch the public key")
	func unauthorizedOrganizationPullsDoNotFetchPublicKey() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.authenticatedPullResponses = [.unauthorized]
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(sync.publicKeyCallCount == 0)
	}

	@Test("malformed organization pull responses do not fetch the public key")
	func malformedOrganizationPullResponsesDoNotFetchPublicKey() async {
		let keypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.authenticatedPullResponses = [.response(nil)]
		let store = makeOrganizationPullStore(sync: sync, keypair: keypair)

		await store.pullFromOrg(orgSlug: "acme")

		#expect(sync.publicKeyCallCount == 0)
	}

	@Test("network protocol v2 imports are rejected before decryption")
	func networkProtocolV2ImportsAreRejectedBeforeDecryption() async throws {
		let projectID = "vault-v2"
		let wrappingKey = VaultCrypto.generateAESKey()
		let contentKey = SymmetricKey(data: Data(repeating: 0x07, count: 32))
		let personalWrappedKey = try VaultCrypto.wrapKey(
			wrappingKey: wrappingKey,
			aesKey: contentKey
		)
		let personalSync = MockPersonalSyncService()
		let personalDecryptions = LockedCounter()
		personalSync.pullHandlers = [{
			SyncService.SyncStatus(
				vaultId: projectID,
				version: 42,
				cryptoVersion: 2,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: "AAECAwQFBgcICQoL:Y6OMHmtgqyYZ34DylitOwJoe0ut+AwJdYuxZwayDIk6bIWTYtaNUmpWGupsqxZdOiU3roLYywwVsmTsvH1+umdml",
				wrappedKey: personalWrappedKey,
				updatedAt: nil
			)
		}]
		let personalImporter = EnvProjectImportService(
			personalSyncService: personalSync,
			organizationSyncService: MockOrgSyncService(),
			sharingKeypairProvider: VaultCrypto.generateX25519Keypair,
			personalDecryptor: { blob, wrapped, principalID, vaultID, revision, version in
				personalDecryptions.increment()
				return Data(try VaultCrypto.decryptStableSync(
					encryptedBlob: blob,
					wrappedKey: wrapped,
					principalId: principalID,
					vaultId: vaultID,
					revision: revision,
					cryptoVersion: version,
					wrappingKey: wrappingKey
				).utf8)
			}
		)
		await #expect(throws: EnvProjectImportError.invalidPayload(
			"The cloud response uses an unsupported encryption version."
		)) {
			try await personalImporter.loadPersonal(
				authToken: "session-token",
				vaultId: projectID
			)
		}
		#expect(personalDecryptions.value == 0)

		let keypair = VaultCrypto.generateX25519Keypair()
		let organizationWrappedKey = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)
		let organizationSync = MockOrgSyncService()
		organizationSync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		organizationSync.pullResult = SyncService.SyncStatus(
			vaultId: projectID,
			version: 42,
			cryptoVersion: 2,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: "AAECAwQFBgcICQoL:Y6OMHmtgqyYZ34DylitOwJoe0ut+AwJdYuxZwayDIk6bIWTYtaNUmpWGupsqxZdOiU3ZMTOOaeQzofBq2J70KYi7",
			wrappedKey: organizationWrappedKey,
			updatedAt: nil,
			callerUserId: "user-1"
		)
		let organizationImporter = EnvProjectImportService(
			personalSyncService: MockPersonalSyncService(),
			organizationSyncService: organizationSync,
			sharingKeypairProvider: { keypair }
		)
		await #expect(throws: EnvProjectImportError.invalidPayload(
			"The organization response uses an unsupported encryption version."
		)) {
			try await organizationImporter.loadOrganization(
				authToken: "session-token",
				orgSlug: "acme",
				vaultId: projectID,
				expectedCallerUserID: "user-1"
			)
		}
		#expect(organizationSync.pullCallCount == 1)
		#expect(organizationSync.publicKeyCallCount == 0)
	}

	@Test("protocol revision ceiling stops personal encryption and push")
	func protocolRevisionCeilingStopsPersonalPush() async throws {
		for force in [false, true] {
			let projectID = "personal-revision-limit-\(force)"
			let sync = MockPersonalSyncService()
			let preflight = SyncService.SyncStatus(
				vaultId: projectID,
				version: Int(Int32.max),
				cryptoVersion: VaultCrypto.currentCryptoVersion,
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
				updatedAt: nil,
				principalId: "account-1"
			)
			sync.versionPreflightHandlers = [{ .response(.found(preflight)) }]
			let encryptionCalls = LockedCounter()
			let keychain = MockKeychainService()
			keychain.envStorage[projectID] = (
				name: "Limit",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)
			let metadata = mockCurrentSyncMetadata(
				version: Int(Int32.max),
				principalID: "account-1",
				scope: "personal"
			)
			#expect(keychain.seedSyncMetadata([projectID: metadata]))
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				personalSyncServiceFactory: { _ in sync },
				stableSyncEncryptor: { _, _, _, _ in
					encryptionCalls.increment()
					return ("ciphertext", "wrapped")
				},
				authTokenProvider: { _, _ in "session-token" }
			)
			store.appEnvironment = .production
			store.currentUser = testUser(id: "account-1", username: "user")
			store.projects = [VaultProject(
				id: projectID,
				name: "Limit",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)]
			store.syncMetadata = [projectID: metadata]
			store.isUnlocked = true
			store.selectProject(projectID)
			let binding = SyncPrincipalBinding(
				registryURL: store.appEnvironment.registryURL,
				principalID: "account-1",
				scope: "personal"
			)
			#expect(keychain.storedSyncMetadata(vaultId: projectID)?.binding == binding)
			let snapshot = await VaultPersistenceCoordinator(service: keychain)
				.syncSnapshot(vaultId: projectID, binding: binding)
			#expect(snapshot?.metadata?.version(boundTo: binding) == Int(Int32.max))

			await store.pushToCloud(force: force)

			#expect(encryptionCalls.value == 0)
			#expect(sync.pushCallCount == 0)
			#expect(store.lastSyncStatus == "failed")
		}
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
					version: 1,
					cryptoVersion: VaultCrypto.currentCryptoVersion,
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
					updatedAt: nil,
					principalId: "account-1"
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
			stableSyncEncryptor: { _, _, _, _ in ("test-blob", "test-wrapped-key") },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = testUser(id: "account-1", username: "user")
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
		#expect(store.projects[0].secrets(for: "default")["CLI_KEY"] == "cli-value")
		#expect(store.lastSyncStatus?.contains("local changes pending") == true)
		#expect(keychain.storedSyncMetadata(vaultId: "project-a")?.isDirty == true)
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

		#expect(keychain.envStorage[projectId]?.environments["default"]?["TOKEN"] == "local")
		#expect(store.projects.first?.hasLoadedEnvironments == false)
		#expect(store.projects.first?.secretCount == 1)
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
		store.currentUser = testUser(id: "account-1", username: "user")
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
		_ = await oldPull.value

		#expect(store.isSyncing)
		#expect(store.lastSyncStatus == nil)

		await newGate.release()
		_ = await newPull.value
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
			version: 3,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "user-1",
				scope: "personal"
			)
		)

		guard case .success(let commit) = result else {
			Issue.record("Expected a successful pull commit, got \(result)")
			return
		}
		#expect(
			commit.project.secrets(for: "default") == [
				"TOKEN": "cloud",
				"CLI_KEY": "cli-value",
				"CLOUD_KEY": "cloud-value",
			])
		#expect(commit.isDirty)
		#expect(
			keychain.storage["project"]?.secrets
				== commit.project.secrets(for: "default")
		)
		#expect(keychain.updateEnvironmentsCallCount == 1)
	}

	@Test("pull keeps a local-only empty environment dirty")
	func pullKeepsLocalOnlyEmptyEnvironmentDirty() async throws {
		let environments: [String: [String: String]] = [
			"default": [:],
			"staging": [:],
		]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: environments
		)
		let result = await VaultPersistenceCoordinator(service: keychain).commitPull(
			baseline: VaultProject(
				id: "project",
				name: "Project",
				path: "",
				environments: environments
			),
			remotePayload: Data(#"{"environments":{"default":{}}}"#.utf8),
			action: "pull",
			version: 1,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "user-1",
				scope: "personal"
			)
		)

		guard case .success(let commit) = result else {
			Issue.record("Expected a successful pull commit, got \(result)")
			return
		}
		#expect(commit.project.environments == environments)
		#expect(commit.isDirty)
	}

	@Test("pull keeps identical named empty environments clean")
	func pullKeepsIdenticalNamedEmptyEnvironmentsClean() async throws {
		let environments: [String: [String: String]] = [
			"default": [:],
			"staging": [:],
		]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: environments
		)
		let result = await VaultPersistenceCoordinator(service: keychain).commitPull(
			baseline: VaultProject(
				id: "project",
				name: "Project",
				path: "",
				environments: environments
			),
			remotePayload: Data(
				#"{"environments":{"default":{},"staging":{}}}"#.utf8
			),
			action: "pull",
			version: 1,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "user-1",
				scope: "personal"
			)
		)

		guard case .success(let commit) = result else {
			Issue.record("Expected a successful pull commit, got \(result)")
			return
		}
		#expect(commit.project.environments == environments)
		#expect(!commit.isDirty)
	}

	@Test("pull normalizes a completely empty current wrapper")
	func pullNormalizesEmptyCurrentWrapper() async throws {
		let environments: [String: [String: String]] = ["default": [:]]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: environments
		)
		let result = await VaultPersistenceCoordinator(service: keychain).commitPull(
			baseline: VaultProject(
				id: "project",
				name: "Project",
				path: "",
				environments: environments
			),
			remotePayload: Data(#"{"environments":{}}"#.utf8),
			action: "pull",
			version: 1,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "user-1",
				scope: "personal"
			)
		)

		guard case .success(let commit) = result else {
			Issue.record("Expected a successful pull commit, got \(result)")
			return
		}
		#expect(commit.project.environments == environments)
		#expect(!commit.isDirty)
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
			version: 3,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "user-1",
				scope: "personal"
			)
		)

		guard case .conflict(let latest, _) = result else {
			Issue.record("Expected a pull conflict, got \(result)")
			return
		}
		#expect(latest.secrets(for: "default")["TOKEN"] == "cli-value")
		#expect(keychain.storage["project"]?.secrets["TOKEN"] == "cli-value")
		#expect(keychain.dataStorage["__sync_metadata__"] == nil)
	}

	@Test("pull rejects resurrection of an empty environment deleted locally")
	func pullRejectsDeletedEmptyEnvironmentResurrection() async throws {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": [:]]
		)
		let baseline = VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": [:], "staging": [:]]
		)
		let remoteEnvironments: [String: [String: String]] = [
			"default": [:], "staging": [:],
		]
		let remotePayload = try JSONEncoder().encode([
			"environments": remoteEnvironments
		])
		let coordinator = VaultPersistenceCoordinator(service: keychain)

		let result = await coordinator.commitPull(
			baseline: baseline,
			remotePayload: remotePayload,
			action: "pull",
			version: 3,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "user-1",
				scope: "personal"
			)
		)

		guard case .conflict(let latest, _) = result else {
			Issue.record("Expected an environment-level pull conflict, got \(result)")
			return
		}
		#expect(latest.environments["staging"] == nil)
		#expect(keychain.envStorage["project"]?.environments["staging"] == nil)
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
		keychain.failNextWriteDataAccounts = [mockSyncMetadataAccount(vaultId: "project")]
		keychain.failureError = .unexpectedStatus(-1)
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
			version: 3,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "user-1",
				scope: "personal"
			)
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

	@Test("cloud imports reject invalid listings, downgraded payloads, and mismatched identities")
	func cloudImportVersionAndIdentityBinding() async {
		for listedVersion in [nil, 0, -1] as [Int?] {
			let importService = MockEnvProjectImportService()
			importService.personalResult = .success(RemoteEnvProjectPayload(
				vaultId: "invalid-listing",
				environments: ["default": ["TOKEN": "remote"]],
				version: 2,
				keyCount: 1,
				principalID: "user-1"
			))
			let (store, keychain) = makeImportStore(importService: importService)
			let result = await store.importCloudProject(
				remoteProject(id: "invalid-listing", name: "remote", version: listedVersion)
			)
			guard case .failure(.invalidPayload(let message)) = result else {
				Issue.record("Accepted invalid listing version \(String(describing: listedVersion))")
				continue
			}
			#expect(message.contains("listing") && message.contains("version"))
			#expect(keychain.saveEnvironmentsCallCount == 0)
		}

		for payload in [
			RemoteEnvProjectPayload(
				vaultId: "other",
				environments: ["default": ["TOKEN": "remote"]],
				version: 5,
				keyCount: 1,
				principalID: "user-1"
			),
			RemoteEnvProjectPayload(
				vaultId: "bound",
				environments: ["default": ["TOKEN": "remote"]],
				version: 0,
				keyCount: 1,
				principalID: "user-1"
			),
			RemoteEnvProjectPayload(
				vaultId: "bound",
				environments: ["default": ["TOKEN": "remote"]],
				version: 4,
				keyCount: 1,
				principalID: "user-1"
			),
		] {
			let importService = MockEnvProjectImportService()
			importService.personalResult = .success(payload)
			let (store, keychain) = makeImportStore(importService: importService)
			let result = await store.importCloudProject(
				remoteProject(id: "bound", name: "remote", version: 5)
			)
			guard case .failure(.invalidPayload) = result else {
				Issue.record("Accepted invalid payload binding: \(payload)")
				continue
			}
			#expect(keychain.saveEnvironmentsCallCount == 0)
			#expect(store.projects.isEmpty)
		}

		let importService = MockEnvProjectImportService()
		importService.personalResult = .success(RemoteEnvProjectPayload(
			vaultId: "bound",
			environments: ["default": ["TOKEN": "remote"]],
			version: 5,
			keyCount: 1,
			principalID: "other-user"
		))
		let (store, keychain) = makeImportStore(importService: importService)
		let result = await store.importCloudProject(
			remoteProject(id: "bound", name: "remote", version: 5)
		)
		guard case .failure(.invalidPayload(let message)) = result else {
			Issue.record("Accepted a payload bound to another account")
			return
		}
		#expect(message.contains("different account"))
		#expect(keychain.saveEnvironmentsCallCount == 0)
		#expect(store.projects.isEmpty)
	}

	@Test("cloud imports reject project names outside the canonical contract")
	func cloudImportRejectsInvalidProjectNames() async {
		let invalidNames = [
			"release\u{0085}secrets",
			String(repeating: "😀", count: 101),
		]

		for (index, name) in invalidNames.enumerated() {
			let projectID = "invalid-name-\(index)"
			let importService = MockEnvProjectImportService()
			importService.personalResult = .success(RemoteEnvProjectPayload(
				vaultId: projectID,
				environments: ["default": ["TOKEN": "remote"]],
				version: 1,
				keyCount: 1,
				principalID: "user-1"
			))
			let (store, keychain) = makeImportStore(importService: importService)

			let result = await store.importCloudProject(
				remoteProject(id: projectID, name: name)
			)

			guard case .failure(.invalidPayload(let message)) = result else {
				Issue.record("Accepted invalid cloud project name at index \(index)")
				continue
			}
			#expect(message.contains("name"))
			#expect(keychain.saveEnvironmentsCallCount == 0)
			#expect(keychain.envStorage[projectID] == nil)
			#expect(store.projects.isEmpty)
		}
	}

	@Test("organization import reuses a personal project and preserves local values and checkpoints")
	func organizationImportReusesPersonalProjectWithoutLosingLocalState() async throws {
		let importService = MockEnvProjectImportService()
		importService.organizationResult = .success(RemoteEnvProjectPayload(
			vaultId: "shared-existing",
			environments: ["default": ["TOKEN": "cloud"]],
			version: 2,
			keyCount: 1,
			principalID: organizationID
		))
		let (store, keychain) = makeImportStore(importService: importService)
		let local = VaultProject(
			id: "shared-existing", name: "Local name", path: "/tmp/local-project",
			environments: ["default": ["TOKEN": "local", "LOCAL_ONLY": "keep"]]
		)
		let coordinator = VaultPersistenceCoordinator(service: keychain)
		_ = await coordinator.createProject(local, orgSlug: nil)
		let personalBinding = SyncPrincipalBinding(
			registryURL: "https://lpm.dev", principalID: "user-1", scope: "personal"
		)
		_ = await coordinator.finishPush(
			pushedProject: local, action: "push", version: 9, binding: personalBinding
		)
		store.currentUser = userWithOrganization(slug: "acme")
		store.isUnlocked = true
		_ = await store.loadProjects()
		store.selectAccount(.org("acme"))

		let result = await store.importOrganizationProject(
			remoteProject(id: local.id, name: "Cloud name", version: 2), orgSlug: "acme"
		)

		#expect(result == .success(ImportedEnvProject(projectId: local.id, version: 2, keyCount: 2)))
		#expect(store.projects.count == 1)
		#expect(store.selectedProjectId == local.id)
		#expect(store.vaultOrgAssociations[local.id] == "acme")
		let snapshot = try #require(await coordinator.syncSnapshot(vaultId: local.id, binding: personalBinding))
		#expect(snapshot.project.name == local.name)
		#expect(snapshot.project.path == local.path)
		#expect(snapshot.project.environments == ["default": ["TOKEN": "cloud", "LOCAL_ONLY": "keep"]])
		#expect(snapshot.metadata?.lastVersion == 9)
		#expect(store.syncMetadata[local.id]?.isDirty == true)
	}

	@Test("successful organization import publishes the final project once")
	func successfulOrganizationImportIsAtomic() async throws {
		let importService = MockEnvProjectImportService()
		importService.organizationResult = .success(
			RemoteEnvProjectPayload(
				vaultId: "org-1",
				environments: ["production": ["TOKEN": "secret"]],
				version: 7,
				keyCount: 1,
				principalID: organizationID
			))
		let (store, keychain) = makeImportStore(importService: importService)
		store.currentUser = userWithOrganization(slug: "acme")
		store.isUnlocked = true
		store.selectAccount(.org("acme"))

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

	@Test("cancellation after a durable cloud import still publishes the committed snapshot")
	func postCommitImportCancellationAcknowledgesCommit() async {
		let importService = MockEnvProjectImportService()
		importService.personalResult = .success(
			RemoteEnvProjectPayload(
				vaultId: "committed",
				environments: ["default": ["TOKEN": "secret"]],
				version: 2,
				keyCount: 1,
				principalID: "user-1"
			)
		)
		let (store, keychain) = makeImportStore(importService: importService)
		var operation: Task<Result<ImportedEnvProject, EnvProjectImportError>, Never>?
		keychain.onCreateEnvironments = { operation?.cancel() }
		operation = Task {
			await store.importCloudProject(remoteProject(id: "committed", name: "remote"))
		}

		let result = await operation?.value

		#expect(result == .success(
			ImportedEnvProject(projectId: "committed", version: 2, keyCount: 1)
		))
		#expect(keychain.storage["committed"]?.secrets["TOKEN"] == "secret")
		#expect(store.projects.first?.id == "committed")
	}

	@Test("organization association failure rolls back the project")
	func organizationAssociationFailureRollsBack() async {
		let importService = MockEnvProjectImportService()
		importService.organizationResult = .success(
			RemoteEnvProjectPayload(
				vaultId: "org-fail",
				environments: ["default": ["TOKEN": "secret"]],
				version: 3,
				keyCount: 1,
				principalID: organizationID
			))
		let (store, keychain) = makeImportStore(importService: importService)
		store.currentUser = userWithOrganization(slug: "acme")
		store.selectAccount(.org("acme"))
		keychain.failNextWriteDataAccounts = ["__org_associations__"]

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
		#expect(keychain.applyVaultTransactionCallCount == 1)
	}

	@Test("duplicate cloud import never overwrites local secrets")
	func duplicateImportDoesNotOverwrite() async {
		let importService = MockEnvProjectImportService()
		importService.personalResult = .success(
			RemoteEnvProjectPayload(
				vaultId: "duplicate",
				environments: ["default": ["TOKEN": "remote"]],
				version: 2,
				keyCount: 1,
				principalID: "user-1"
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
				vaultId: "raced",
				environments: ["default": ["TOKEN": "remote"]],
				version: 2,
				keyCount: 1,
				principalID: "user-1"
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
		store.currentUser = testUser(id: "user-1", username: "user")
		return (store, keychain)
	}

	private func remoteProject(
		id: String,
		name: String?,
		version: Int? = 1
	) -> SyncService.RemoteProject {
		SyncService.RemoteProject(
			vaultId: id,
			name: name,
			version: version,
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

	private func memberRewrapStatus(
		vaultId: String,
		callerUserID: String = "user-1"
	) -> SyncService.SyncStatus {
		SyncService.SyncStatus(
			vaultId: vaultId,
			version: nil,
			cryptoVersion: nil,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "error",
			error: "You do not have a wrapped key for this organization env project",
			code: "vault_member_needs_rewrap",
			serverVersion: nil,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: nil,
			callerUserId: callerUserID,
			organizationId: organizationID
		)
	}

	private func makeOrganizationPullStore(
		sync: MockOrgSyncService,
		keypair: (privateKey: Data, publicKey: Data)
	) -> VaultStore {
		let keychain = MockKeychainService()
		keychain.envStorage["rewrap"] = (
			name: "Rewrap",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)
		store.currentUser = LPMUser(
			id: "user-1",
			username: "user",
			name: nil,
			email: nil,
			avatarUrl: nil,
			plan: nil,
			createdAt: nil,
			orgs: [
				LPMOrg(
					id: organizationID,
					slug: "acme",
					name: "Acme",
					avatarUrl: nil,
					role: "owner"
				)
			]
		)
		store.projects = [
			VaultProject(
				id: "rewrap",
				name: "Rewrap",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)
		]
		store.vaultOrgAssociations = ["rewrap": "acme"]
		store.isUnlocked = true
		store.selectAccount(.org("acme"))
		store.selectProject("rewrap")
		return store
	}

	private func waitForWorkspaceSnapshots(_ store: VaultStore, count: Int) async {
		for _ in 0..<1_000 {
			if store.workspaceSnapshots.count == count { return }
			try? await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Workspace snapshots did not reach count \(count)")
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
					id: organizationID,
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

	private func makeOrgTrustFixture(
		onKeypair: @escaping @Sendable () -> Void = {},
		authToken: MutableOptionalString? = nil,
		authTokenResolver: (@Sendable () async throws -> String?)? = nil
	) -> (
		store: VaultStore,
		keychain: MockKeychainService,
		sync: MockOrgSyncService,
		slug: String,
		trustAccount: String
	) {
		let slug = "trust-\(UUID().uuidString.lowercased())"
		let projectId = "project-\(UUID().uuidString.lowercased())"
		let localKeypair = VaultCrypto.generateX25519Keypair()
		let memberKeypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: localKeypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey)
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: organizationID,
			callerUserID: "u1",
			members: [
				SyncService.MemberPublicKey(
					userId: "u1",
					role: "admin",
					publicKey: localKeypair.publicKey.base64EncodedString(),
					publicKeyVersion: 1,
					publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey),
					hasPublicKey: true
				),
				SyncService.MemberPublicKey(
					userId: "member",
					role: "admin",
					publicKey: memberKeypair.publicKey.base64EncodedString(),
					publicKeyVersion: 1,
					publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(memberKeypair.publicKey),
					hasPublicKey: true
				),
			],
			canReplaceWrappedKeys: true
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectId] = (
			name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: {
				onKeypair()
				return localKeypair
			},
			authTokenProvider: { _, _ in
				if let authTokenResolver { return try await authTokenResolver() }
				if let authToken { return authToken.value }
				return "session-token"
			}
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
		let trustScope = OrgTrustScope(
			registryURL: store.appEnvironment.registryURL,
			organizationID: organizationID,
			organizationSlug: slug
		)!
		return (store, keychain, sync, slug, trustScope.storageAccount)
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
			organizationID: organizationID,
			callerUserID: "u1",
			members: [
				SyncService.MemberPublicKey(
					userId: "u1",
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
		_ = await push.value

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

private final class MainThreadRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: Bool?

	var value: Bool? { lock.withLock { storage } }

	func capture() { lock.withLock { storage = Thread.isMainThread } }
}

private actor GatedTokenProvider {
	private let token: String
	private var gate: AsyncGate?

	init(token: String) {
		self.token = token
	}

	func setGate(_ gate: AsyncGate?) {
		self.gate = gate
	}

	func resolve() async -> String? {
		let currentGate = gate
		await currentGate?.arriveAndWait()
		return token
	}
}

private actor AutoLockSleeper {
	private var continuations: [CheckedContinuation<Void, any Error>?] = []
	private(set) var durations: [Duration] = []

	var count: Int { continuations.count }

	func sleep(_ duration: Duration) async throws {
		durations.append(duration)
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

private final class MutableOptionalString: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: String?

	init(_ value: String? = nil) {
		storage = value
	}

	var value: String? {
		get { lock.withLock { storage } }
		set { lock.withLock { storage = newValue } }
	}
}

private final class FailableAuthTokenProvider: @unchecked Sendable {
	private let lock = NSLock()
	private var failureEnabled = false

	var shouldFail: Bool {
		get { lock.withLock { failureEnabled } }
		set { lock.withLock { failureEnabled = newValue } }
	}

	func resolve() throws -> String? {
		if shouldFail { throw TestAuthClearError.failed }
		return "session-token"
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
