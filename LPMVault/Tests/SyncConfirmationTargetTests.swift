import Foundation
import Testing

@testable import LPMVault

@Suite("Sync confirmation targets")
@MainActor
struct SyncConfirmationTargetTests {
	@Test("stale project targets stop every sync direction before authorization")
	func staleTargetsStopBeforeAuthorization() async {
		let authorization = SyncAuthorizationProbe()
		let keychain = MockKeychainService()
		let first = VaultProject(id: "first", name: "First", path: "", environments: ["default": ["TOKEN": "first"]])
		let second = VaultProject(id: "second", name: "Second", path: "", environments: ["default": ["TOKEN": "second"]])
		for project in [first, second] {
			keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments)
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authTokenProvider: { _, _ in authorization.token() }
		)
		store.projects = [first, second]
		store.isUnlocked = true
		store.openProject(id: second.id)

		let personalTarget = VaultSyncTarget(projectId: first.id, account: .personal)
		await store.pushToCloud(target: personalTarget)
		#expect(await !store.pullFromCloud(target: personalTarget))

		let slug = "acme"
		store.vaultOrgAssociations = [first.id: slug, second.id: slug]
		store.selectAccount(.org(slug))
		store.openProject(id: second.id)
		let organizationTarget = VaultSyncTarget(projectId: first.id, account: .org(slug))
		await store.pushToOrg(orgSlug: slug, target: organizationTarget)
		await store.pullFromOrg(orgSlug: slug, target: organizationTarget)

		#expect(authorization.callCount == 0)
		store.lock()
	}
}

private final class SyncAuthorizationProbe: @unchecked Sendable {
	private let lock = NSLock()
	private var calls = 0

	var callCount: Int { lock.withLock { calls } }

	func token() -> String? {
		lock.withLock { calls += 1 }
		return nil
	}
}
