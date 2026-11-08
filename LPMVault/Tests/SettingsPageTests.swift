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

	@Test("Settings opens over the window's workspace")
	func showsPage() {
		let store = makeStore()
		store.showSettings()
		#expect(store.accountPage == .settings && store.isShowingAccountPage)
	}

	@Test("the Settings panel sits clear of the title bar with even margins above and below, centered, and no wider than its menu and cards")
	func overlayGeometry() {
		let regular = VaultSettingsOverlay.panelFrame(in: CGSize(width: 1280, height: 800))
		#expect(regular.minY == VaultMetrics.titleBar + 40 && regular.maxY == 800 - 40, "40 points below the title bar and above the bottom")
		#expect(regular.width == 977 && abs(regular.midX - 640) < 0.5,
			"Centered, at its widest: a 200-point menu, its hairline, and 720 points of cards inset 28 on each side")
		#expect(VaultSettingsOverlay.panelFrame(in: CGSize(width: 1280, height: 800), scrollBar: 15).width == 992,
			"Where scroll bars always show, wider by one, so the cards keep their width")
		let small = VaultSettingsOverlay.panelFrame(in: CGSize(width: 1040, height: 640))
		#expect(small.minX == 40 && small.maxX == 1000, "At least 40 points on each side")
		#expect(small.minY == VaultMetrics.titleBar + 40 && small.maxY == 600)
	}

	@Test("Settings opens where it was left; Platforms is its own page, and closing leaves the workspace's project as it was")
	func categories() {
		let store = makeStore()
		#expect(store.shownSettingsCategory == nil)
		store.showSettings()
		#expect(store.shownSettingsCategory == .general, "First, General")
		store.showSettings(.cli)
		#expect(store.accountPage == .settings && store.shownSettingsCategory == .cli)
		store.showSettings(.platforms)
		#expect(store.accountPage == .platforms && store.shownSettingsCategory == .platforms)
		store.closeAccountPage()
		#expect(store.shownSettingsCategory == nil && !store.isShowingAccountPage)
		store.showSettings()
		#expect(store.shownSettingsCategory == .cli, "Where it was left, as Platforms is a page of its own")
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

	@Test("an account's avatar shows the first letter of its name, as Settings does")
	func avatarInitial() {
		#expect(VaultInitialsAvatar.initial(of: "Acme Inc") == "A")
		#expect(VaultInitialsAvatar.initial(of: "tolga") == "T")
		#expect(VaultInitialsAvatar.initial(of: "@neo") == "N")
		#expect(VaultInitialsAvatar.initial(of: "Personal vault") == "P")
		#expect(VaultInitialsAvatar.initial(of: "") == "L")
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

		private func menu(_ store: VaultStore, isPresented: Binding<Bool> = .constant(true), onSignOut: @escaping () -> Void = {},
			onImport: @escaping () -> Void = {}) -> SheetTestHost<some View> {
			SheetTestHost(VaultAccountSwitcher(store: store, isPresented: isPresented, onSignOut: onSignOut, onImport: onImport).frame(width: 264),
				size: NSSize(width: 264, height: 360), keepsRequestedSize: true, usesHostingView: true)
		}

		@Test("signed in, the menu imports projects from lpm.dev, closing as the import opens; signed out, there's nothing there to import")
		func importsFromLpmDev() async throws {
			var imported = false
			var shown = true
			let signedIn = store(signedIn: true)
			let host = menu(signedIn, isPresented: Binding(get: { shown }, set: { shown = $0 }), onImport: { imported = true })
			defer { host.window.close() }
			let row = try await host.drawnFrame(saying: "Import from lpm.dev…")
			#expect(row.height < 18, "One line, as every menu row: \(row)")
			try await host.click("Import from lpm.dev…")
			#expect(try await host.waitUntil { imported && !shown })

			let signedOut = menu(store(signedIn: false))
			defer { signedOut.window.close() }
			#expect(try await signedOut.waitForText("Sign In…"))
			#expect(try await !signedOut.text().contains("Import from"))
		}

		@Test("the menu lists the person's own vault, then their organizations', then importing, the account on lpm.dev and signing out")
		func signedInLayout() async throws {
			let store = store(signedIn: true)
			let host = menu(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("Manage Account on lpm.dev"))
			let order = host.lines().map(\.text)
			let positions = ["PERSONAL", "tolga", "ORGANIZATIONS", "Acme", "Import from lpm.dev…", "Manage Account on lpm.dev", "Sign Out…"].map { name in
				order.firstIndex { $0.contains(name) }
			}
			#expect(positions.allSatisfy { $0 != nil } && positions == positions.sorted { ($0 ?? 0) < ($1 ?? 0) }, "\(order)")
			let personal = try await host.waitForElement(saying: "tolga")
			#expect(personal.isSelected, "The open vault is the checked one")
		}

		@Test("the vault in use stays checked while Settings shows over it")
		func checkedOverSettings() async throws {
			let store = store(signedIn: true)
			store.showSettings()
			let host = menu(store)
			defer { host.window.close() }
			let personal = try await host.waitForElement(saying: "tolga")
			#expect(personal.isSelected)
			#expect(try await !host.waitForElement(saying: "Acme").isSelected)
		}

		@Test("choosing an organization opens its vault and closes the menu")
		func choosesOrganization() async throws {
			let store = store(signedIn: true)
			var shown = true
			let host = menu(store, isPresented: Binding(get: { shown }, set: { shown = $0 }))
			defer { host.window.close() }
			try await host.click("Acme")
			#expect(try await host.waitUntil { store.selectedAccount == .org("acme") })
			#expect(!shown)
		}

		@Test("Sign Out… closes the menu and asks the workspace to confirm, signing out nothing yet")
		func signOutAsks() async throws {
			let store = store(signedIn: true)
			var shown = true
			var asked = 0
			let host = menu(store, isPresented: Binding(get: { shown }, set: { shown = $0 }), onSignOut: { asked += 1 })
			defer { host.window.close() }
			try await host.click("Sign Out…")
			#expect(try await host.waitUntil { asked == 1 })
			#expect(!shown)
			#expect(store.isLoggedIn, "Signing out waits for the confirmation")
		}

		@Test("signed out, the menu offers the local vault and Sign In, which opens Settings at Account & Sync, where signing in is")
		func signedOut() async throws {
			let store = store(signedIn: false)
			let host = menu(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("Personal vault"))
			#expect(try await !host.text().contains("ORGANIZATIONS"))
			try await host.click("Sign In…")
			#expect(try await host.waitUntil { store.shownSettingsCategory == .account })
		}
	}
}
