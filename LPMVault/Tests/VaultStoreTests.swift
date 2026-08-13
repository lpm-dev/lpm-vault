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
		apiService: MockAPIService? = nil
	) -> (VaultStore, MockKeychainService, MockBiometricService, MockAPIService) {
		let keychain = MockKeychainService()
		for p in projects {
			keychain.storage[p.id] = (name: p.name, path: p.path, secrets: p.secrets)
		}
		let biometric = MockBiometricService()
		biometric.shouldSucceed = biometricShouldSucceed
		let api = apiService ?? MockAPIService()
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: api)

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

		store.loadProjects()
		// loadProjects uses Task.detached — give it time to complete
		try await Task.sleep(for: .milliseconds(200))

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
	func addReservedEnvironment() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])

		store.addEnvironment(to: "id-1", name: "__index__")

		#expect(store.projects[0].environments["__index__"] == nil)
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
	func selectedProject() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: [:]),
			(id: "id-2", name: "project-b", path: "/tmp/b", secrets: [:]),
		])
		store.loadProjects()
		store.selectedProjectId = "id-2"

		#expect(store.selectedProject?.name == "project-b")
	}

	@Test("selectedProject returns nil when nothing selected")
	func noSelectedProject() {
		let (store, _, _, _) = makeStore()
		store.loadProjects()

		#expect(store.selectedProject == nil)
	}

	// MARK: - Token Operations

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
}
