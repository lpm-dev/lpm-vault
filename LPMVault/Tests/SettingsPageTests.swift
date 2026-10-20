import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@MainActor
struct SettingsPageStoreTests {
	private func makeStore(biometric: MockBiometricService = MockBiometricService()) -> VaultStore {
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: biometric,
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		return store
	}

	@Test("Settings opens on the page in the window, in place of a project")
	func showsPage() {
		let store = makeStore()
		store.showSettings()
		#expect(store.accountPage == .settings && store.isShowingAccountPage)
	}

	@Test("⌘, while locked unlocks first, then shows Settings")
	func unlocksFirst() async {
		let biometric = MockBiometricService()
		let store = makeStore(biometric: biometric)
		store.lock()
		await store.showSettingsUnlockingFirst()
		#expect(biometric.authenticateCallCount == 1)
		#expect(store.isUnlocked && store.accountPage == .settings)
	}

	@Test("a declined unlock leaves the vault locked and Settings unopened")
	func declinedUnlock() async {
		let biometric = MockBiometricService()
		let store = makeStore(biometric: biometric)
		store.lock()
		biometric.shouldSucceed = false
		await store.showSettingsUnlockingFirst()
		#expect(!store.isUnlocked && store.accountPage == nil)
	}

	@Test("⌘, while unlocked opens Settings without asking again")
	func unlockedOpensAtOnce() async {
		let biometric = MockBiometricService()
		let store = makeStore(biometric: biometric)
		await store.showSettingsUnlockingFirst()
		#expect(biometric.authenticateCallCount == 0 && store.accountPage == .settings)
	}

	@Test("the account is managed on the server in use")
	func managementURL() {
		let store = makeStore()
		store.appEnvironment = .production
		#expect(store.accountManagementURL?.path == "/dashboard/settings")
		#expect(store.accountManagementURL?.host == AppEnvironment.production.baseURL.host)
	}

	@Test("a vault row says what kind of vault it is, and an organization's the person's role, when lpm.dev sends one")
	func vaultDetails() {
		#expect(VaultAccountSwitcher.personalDetail(signedIn: true, projects: 6) == "Personal · 6 projects")
		#expect(VaultAccountSwitcher.personalDetail(signedIn: false, projects: nil) == "Local only")
		#expect(VaultAccountSwitcher.organizationDetail(role: "owner", projects: 1) == "Organization · Owner · 1 project")
		#expect(VaultAccountSwitcher.organizationDetail(role: nil, projects: nil) == "Organization")
		#expect(VaultAccountSwitcher.organizationDetail(role: "  ", projects: nil) == "Organization")
	}
}

extension SheetInteractionTests {
	@Suite("Account menu", .serialized)
	@MainActor
	struct AccountMenuTests {
		private func store(signedIn: Bool) -> VaultStore {
			let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			if signedIn {
				store.currentUser = LPMUser(id: "u1", username: "tolga", name: "Tolga Ergin", email: "tolga@example.com", avatarUrl: nil,
					plan: nil, createdAt: nil, orgs: [LPMOrg(id: "o1", slug: "acme", name: "Acme", avatarUrl: nil, role: "owner")])
			}
			return store
		}

		private func menu(_ store: VaultStore, isPresented: Binding<Bool> = .constant(true)) -> SheetTestHost<some View> {
			SheetTestHost(VaultAccountSwitcher(store: store, isPresented: isPresented).frame(width: 264),
				size: NSSize(width: 264, height: 420), keepsRequestedSize: true, usesHostingView: true)
		}

		@Test("the menu starts with who's signed in and their account, then the vaults, then Settings and Platforms, then Lock")
		func signedInLayout() async throws {
			let store = store(signedIn: true)
			let host = menu(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("Tolga Ergin"))
			#expect(try await host.waitForText("tolga@example.com"))
			let manage = try await host.waitForElement(saying: "Manage account")
			#expect(manage.role == .button && manage.help == "Manage your account on lpm.dev")
			#expect(try await host.waitForText("Personal · 0 projects"))
			#expect(try await host.waitForText("Organization · Owner"))
			let order = host.lines().map(\.text)
			let positions = ["Tolga Ergin", "VAULTS", "Personal vault", "Acme", "Settings…", "Platforms", "Lock vault"].map { name in
				order.firstIndex { $0.contains(name) }
			}
			#expect(positions.allSatisfy { $0 != nil } && positions == positions.sorted { ($0 ?? 0) < ($1 ?? 0) }, "\(order)")
			#expect(!order.contains { $0 == "Account" }, "The identity header replaces the Account row")
		}

		@Test("Settings… opens the Settings page in the window and closes the menu")
		func settingsOpensPage() async throws {
			let store = store(signedIn: true)
			var shown = true
			let host = menu(store, isPresented: Binding(get: { shown }, set: { shown = $0 }))
			defer { host.window.close() }
			try await host.click("Settings…")
			#expect(try await host.waitUntil { store.accountPage == .settings })
			#expect(!shown)
		}

		@Test("signed out, the menu says so and Sign In opens Settings, where signing in is")
		func signedOut() async throws {
			let store = store(signedIn: false)
			let host = menu(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("Not signed in"))
			#expect(try await host.waitForText("Local only · 0 projects"))
			try await host.click("Sign In…")
			#expect(try await host.waitUntil { store.accountPage == .settings })
		}
	}
}
