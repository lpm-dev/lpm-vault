import Foundation
import Testing

@testable import LPMVault

@Suite("VaultStore")
struct VaultStoreTests {
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
		return (store, keychain, biometric, api)
	}

	// MARK: - Load

	@Test("load projects from keychain")
	func loadProjects() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "api-server", path: "/tmp/api", secrets: ["DB_HOST": "localhost"]),
			(id: "id-2", name: "web-app", path: "/tmp/web", secrets: ["API_KEY": "sk-123"]),
		])

		store.loadProjects()

		#expect(store.projects.count == 2)
		// Should be sorted alphabetically
		#expect(store.projects[0].name == "api-server")
		#expect(store.projects[1].name == "web-app")
	}

	@Test("load projects from empty keychain")
	func loadEmpty() {
		let (store, _, _, _) = makeStore()
		store.loadProjects()
		#expect(store.projects.isEmpty)
	}

	// MARK: - Add Project

	@Test("add project creates in keychain and selects it")
	func addProject() {
		let (store, keychain, _, _) = makeStore()

		store.addProject(name: "new-project", path: "/tmp/new")

		#expect(store.projects.count == 1)
		#expect(store.projects[0].name == "new-project")
		#expect(store.projects[0].path == "/tmp/new")
		#expect(store.projects[0].secrets.isEmpty)
		#expect(store.selectedProjectId == store.projects[0].id)
		#expect(keychain.storage.count == 1)
	}

	@Test("add project failure sets error")
	func addProjectFailure() {
		let (store, keychain, _, _) = makeStore()
		keychain.shouldFail = true

		store.addProject(name: "failing-project", path: "/tmp/fail")

		#expect(store.projects.isEmpty)
		#expect(store.error != nil)
	}

	// MARK: - Delete Project

	@Test("delete project removes from list")
	func deleteProject() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project-a", path: "/tmp/a", secrets: [:])
		])
		store.loadProjects()
		store.selectedProjectId = "id-1"

		store.deleteProject(store.projects[0])

		#expect(store.projects.isEmpty)
		#expect(store.selectedProjectId == nil)
	}

	// MARK: - Add Secret

	@Test("add secret to project")
	func addSecret() {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])
		store.loadProjects()

		store.addSecret(to: "id-1", key: "DB_HOST", value: "localhost")

		#expect(store.projects[0].secrets["DB_HOST"] == "localhost")
		#expect(keychain.storage["id-1"]?.secrets["DB_HOST"] == "localhost")
	}

	@Test("add secret with empty key is rejected")
	func addSecretEmptyKey() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: [:])
		])
		store.loadProjects()

		store.addSecret(to: "id-1", key: "", value: "value")

		#expect(store.projects[0].secrets.isEmpty)
	}

	@Test("add secret to non-existent project is no-op")
	func addSecretNoProject() {
		let (store, _, _, _) = makeStore()
		store.loadProjects()

		store.addSecret(to: "nonexistent", key: "KEY", value: "VALUE")

		#expect(store.projects.isEmpty)
	}

	// MARK: - Update Secret

	@Test("update existing secret")
	func updateSecret() {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "old"])
		])
		store.loadProjects()

		store.updateSecret(in: "id-1", key: "KEY", newValue: "new")

		#expect(store.projects[0].secrets["KEY"] == "new")
		#expect(keychain.storage["id-1"]?.secrets["KEY"] == "new")
	}

	@Test("update non-existent key is no-op")
	func updateNonExistentKey() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["KEY": "val"])
		])
		store.loadProjects()

		store.updateSecret(in: "id-1", key: "MISSING", newValue: "new")

		#expect(store.projects[0].secrets["KEY"] == "val")
		#expect(store.projects[0].secrets["MISSING"] == nil)
	}

	// MARK: - Delete Secret

	@Test("delete secret from project")
	func deleteSecret() {
		let (store, keychain, _, _) = makeStore(projects: [
			(id: "id-1", name: "project", path: "/tmp/p", secrets: ["A": "1", "B": "2"])
		])
		store.loadProjects()

		store.deleteSecret(from: "id-1", key: "A")

		#expect(store.projects[0].secrets["A"] == nil)
		#expect(store.projects[0].secrets["B"] == "2")
		#expect(keychain.storage["id-1"]?.secrets["A"] == nil)
	}

	// MARK: - Search

	@Test("search filters projects by name")
	func searchByName() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "api-server", path: "/tmp/api", secrets: [:]),
			(id: "id-2", name: "web-app", path: "/tmp/web", secrets: [:]),
		])
		store.loadProjects()

		store.searchQuery = "api"

		#expect(store.filteredProjects.count == 1)
		#expect(store.filteredProjects[0].name == "api-server")
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
		store.loadProjects()

		store.searchQuery = "database"

		#expect(store.filteredProjects.count == 1)
		#expect(store.filteredProjects[0].name == "project-a")
	}

	@Test("empty search shows all projects")
	func emptySearch() {
		let (store, _, _, _) = makeStore(projects: [
			(id: "id-1", name: "a", path: "/tmp/a", secrets: [:]),
			(id: "id-2", name: "b", path: "/tmp/b", secrets: [:]),
		])
		store.loadProjects()

		store.searchQuery = ""

		#expect(store.filteredProjects.count == 2)
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
}
