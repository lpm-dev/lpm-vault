import CryptoKit
import Foundation
import Testing
@testable import LPMVault

struct PlatformConnectionStoreTests {
	private let keychain = MockKeychainService()
	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }
	private let connectedAt = Date(timeIntervalSince1970: 1_760_000_000.123)

	private func grant(team: String? = "team_acme", token: String = "vca_token_1", installation: String = "icfg_1") -> VercelGrant {
		VercelGrant(accessToken: token, installationID: installation, teamID: team, userID: "u_tolga")!
	}

	@Test("a saved connection reads back without its token, and the token only by its ID")
	func savesAndReads() async throws {
		let store = store
		let saved = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: "acme"), at: connectedAt).get()
		#expect(saved.id == "vercel.team_acme" && saved.name == "Acme" && saved.platform == .vercel)
		#expect(try await store.connections().get() == [saved])
		#expect(try await store.accessToken(for: saved.id).get() == "vca_token_1")
		#expect(keychain.platformConnectionStorage.keys.sorted() == ["vercel.team_acme"])
		#expect(keychain.publishingStorage.isEmpty, "Tokens never share the publishing records' service")
	}

	@Test("connecting the same account again replaces it; a personal account is keyed by its user")
	func replacesSameAccount() async throws {
		let store = store
		_ = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: "acme"), at: connectedAt).get()
		let again = try await store.save(
			grant(token: "vca_token_2", installation: "icfg_2"), account: VercelAccount(name: "Acme Inc", slug: "acme"),
			at: connectedAt.addingTimeInterval(60)).get()
		let personal = try await store.save(grant(team: nil), account: VercelAccount(name: "Tolga", slug: "tolga"), at: connectedAt).get()
		#expect(personal.id == "vercel.u_tolga")
		#expect(try await store.connections().get().map(\.name) == ["Acme Inc", "Tolga"])
		#expect(try await store.accessToken(for: again.id).get() == "vca_token_2")
	}

	@Test("removing forgets the connection and its token")
	func removes() async throws {
		let store = store
		let saved = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: nil), at: connectedAt).get()
		_ = try await store.remove(saved.id).get()
		#expect(try await store.connections().get().isEmpty)
		#expect(await store.accessToken(for: saved.id) == .failure(.notFound))
		#expect(keychain.platformConnectionStorage.isEmpty)
	}

	@Test("a record filed under another account, damaged, or from a newer version isn't read, and isn't changed")
	func refusesUnreadableRecords() async throws {
		let store = store
		let saved = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: nil), at: connectedAt).get()
		let data = try #require(keychain.platformConnectionStorage[saved.id])
		keychain.platformConnectionStorage["vercel.team_other"] = data
		keychain.platformConnectionStorage["vercel.team_broken"] = Data("{".utf8)
		let newer = Data(#"{"version":2,"anything":"new"}"#.utf8)
		keychain.platformConnectionStorage["vercel.team_newer"] = newer
		#expect(try await store.connections().get().map(\.id) == [saved.id])
		#expect(await store.accessToken(for: "vercel.team_other") == .failure(.unreadable))
		#expect(await store.accessToken(for: "vercel.team_newer") == .failure(.newerVersion))
		#expect(keychain.platformConnectionStorage["vercel.team_newer"] == newer)
	}

	@Test("the stored record round-trips exactly, to the millisecond")
	func roundTrip() throws {
		let record = PlatformConnectionStore.Record(
			connection: PlatformConnection(
				account: .vercel(VercelConnectionAccount(installationID: "icfg_1", teamID: nil, userID: "u_1", name: "Tolga", slug: nil)),
				connectedAt: PublishTimestamp.normalized(connectedAt)),
			accessToken: "vca_x")
		let data = try #require(PlatformConnectionStore.encode(record))
		#expect(PlatformConnectionStore.decode(data, account: "vercel.u_1") == .success(record))
	}

	@Test("a Keychain failure is reported")
	func keychainFailure() async {
		keychain.failPlatformConnectionAccounts = ["*"]
		#expect(await store.connections() == .failure(.keychain(.accessDenied)))
	}
}

@MainActor
struct PlatformConnectionsModelTests {
	private let keychain = MockKeychainService()

	private func model(
		connect: @escaping @Sendable () async -> Result<(grant: VercelGrant, account: VercelAccount), VercelConnectError>,
		session: PlatformSession? = platformTestSession(URL(string: "https://lpm.dev")!)
	) -> PlatformConnections {
		PlatformConnections(
			store: PlatformConnectionStore(service: keychain),
			connect: { _, open in
				await open(URL(string: "https://vercel.com/integrations/lpm-vault/new")!)
				return await connect()
			},
			session: { session },
			openURL: { _ in },
			now: { Date(timeIntervalSince1970: 1_760_000_000) })
	}

	private func waitUntilIdle(_ model: PlatformConnections) async {
		for _ in 0..<500 where model.isConnecting || model.isLoading { try? await Task.sleep(for: .milliseconds(5)) }
	}

	private nonisolated static let acme = (
		grant: VercelGrant(accessToken: "vca_acme", installationID: "icfg_1", teamID: "team_acme", userID: "u_1")!,
		account: VercelAccount(name: "Acme", slug: "acme"))

	@Test("connecting saves the connection, lists it and says so")
	func connects() async throws {
		let model = model { .success(Self.acme) }
		model.connectVercel()
		await waitUntilIdle(model)
		#expect(model.connections.map(\.name) == ["Acme"])
		#expect(model.notice == .init(message: "Connected Acme on Vercel.", isError: false))
		#expect(keychain.platformConnectionStorage.keys.sorted() == ["vercel.team_acme"])
	}

	@Test("without an LPM session nothing starts, and the page says to sign in")
	func needsSession() async {
		let model = model(connect: { Issue.record("Started without a session"); return .failure(.cancelled) }, session: nil)
		model.connectVercel()
		await waitUntilIdle(model)
		#expect(model.notice == .init(message: VercelConnectError.signedOut.message, isError: true))
	}

	@Test("a failed connection shows why; a cancelled one shows nothing")
	func failures() async {
		let failed = model { .failure(.platform(.cancelledOnPlatform)) }
		failed.connectVercel()
		await waitUntilIdle(failed)
		#expect(failed.notice?.isError == true && failed.notice?.message == PlatformConnectFailure.cancelledOnPlatform.message)
		let cancelled = model { .failure(.cancelled) }
		cancelled.connectVercel()
		await waitUntilIdle(cancelled)
		#expect(cancelled.notice == nil)
	}

	@Test("locking mid-connection drops it, and a grant that arrives afterward isn't saved")
	func resetDropsLateGrant() async throws {
		let gate = AsyncGate()
		let model = model {
			await gate.wait()
			return .success(Self.acme)
		}
		model.connectVercel()
		try await Task.sleep(for: .milliseconds(30))
		#expect(model.isConnecting)
		model.reset()
		#expect(!model.isConnecting)
		await gate.open()
		try await Task.sleep(for: .milliseconds(50))
		#expect(model.connections.isEmpty && model.notice == nil)
		#expect(keychain.platformConnectionStorage.isEmpty)
	}

	@Test("disconnecting forgets the token and the row")
	func disconnects() async throws {
		let model = model { .success(Self.acme) }
		model.connectVercel()
		await waitUntilIdle(model)
		let connection = try #require(model.connections.first)
		model.disconnect(connection)
		for _ in 0..<200 where !model.disconnecting.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
		#expect(model.connections.isEmpty)
		#expect(keychain.platformConnectionStorage.isEmpty)
		#expect(model.notice?.isError == false)
	}

	@Test("loading reads what this Mac holds")
	func loads() async throws {
		_ = try await PlatformConnectionStore(service: keychain).save(
			Self.acme.grant, account: Self.acme.account, at: Date()).get()
		let model = model { .failure(.cancelled) }
		model.load()
		await waitUntilIdle(model)
		#expect(model.connections.map(\.id) == ["vercel.team_acme"])
	}
}

private actor AsyncGate {
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func open() {
		isOpen = true
		for waiter in waiters { waiter.resume() }
		waiters = []
	}
}

@MainActor
struct PlatformsPageStoreTests {
	private let keychain = MockKeychainService()

	private func makeStore(
		token: String? = "lpm_session",
		connect: PlatformConnections.Connect? = nil
	) -> VaultStore {
		keychain.envStorage["project"] = (name: "Project", path: "", environments: ["default": ["A": "1"]])
		let store = VaultStore(
			keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in token },
			platformConnect: connect,
			platformURLOpener: { _ in })
		store.projects = [VaultProject(id: "project", name: "Project", path: "", environments: ["default": ["A": "1"]])]
		store.isUnlocked = true
		store.currentUser = LPMUser(id: "lpm_user_1", username: "tolga", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
		return store
	}

	@Test("Platforms opens from the account menu in place of a project, and opening a project leaves it")
	func navigation() {
		let store = makeStore()
		store.showPlatforms()
		#expect(store.accountPage == .platforms && store.isShowingAccountPage)
		store.showSettings()
		#expect(store.accountPage == .settings)
		store.showPlatforms()
		store.openProject(id: "project")
		#expect(store.accountPage == nil)
	}

	@Test("a connection starts with the signed-in person's session for the server in use")
	func session() async throws {
		let store = makeStore()
		let session = try #require(await store.platformSession())
		#expect(session.token == "lpm_session" && session.principalID == "lpm_user_1")
		#expect(session.baseURL == store.appEnvironment.baseURL)
	}

	@Test("there's no session while signed out, locked, or without a token")
	func noSession() async {
		let signedOut = makeStore()
		signedOut.currentUser = nil
		#expect(await signedOut.platformSession() == nil)
		let locked = makeStore()
		locked.lock()
		#expect(await locked.platformSession() == nil)
		#expect(await makeStore(token: nil).platformSession() == nil)
	}

	@Test("locking stops a connection in progress and forgets the list in memory, not on this Mac")
	func lockResets() async throws {
		let store = makeStore(connect: { _, _ in
			try? await Task.sleep(for: .seconds(30))
			return .failure(.cancelled)
		})
		_ = try await PlatformConnectionStore(service: keychain).save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_a", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: nil), at: Date()).get()
		store.showPlatforms()
		for _ in 0..<200 where store.platforms.isLoading { try await Task.sleep(for: .milliseconds(5)) }
		#expect(store.platforms.connections.map(\.name) == ["Acme"])
		store.platforms.connectVercel()
		#expect(store.platforms.isConnecting)
		store.lock()
		#expect(!store.platforms.isConnecting && store.platforms.connections.isEmpty)
		#expect(keychain.platformConnectionStorage.keys.sorted() == ["vercel.team_a"])
	}

	@Test("unlocking onto the Platforms page lists the connections again")
	func unlockReloads() async throws {
		let store = makeStore()
		_ = try await PlatformConnectionStore(service: keychain).save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_a", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: nil), at: Date()).get()
		store.showPlatforms()
		store.lock()
		await store.unlock()
		#expect(store.isUnlocked && store.accountPage == .platforms)
		for _ in 0..<200 where store.platforms.connections.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
		#expect(store.platforms.connections.map(\.name) == ["Acme"])
	}
}

extension SheetInteractionTests {
	@Suite("Platforms page, rendered")
	@MainActor
	struct PlatformsPageRenderingTests {
		private let keychain = MockKeychainService()

		private let opened = OpenedURLs()

		/// The page's store never opens a real browser; `opened` records what it would open.
		private func page(signedIn: Bool = true, connect: PlatformConnections.Connect? = nil) async throws -> (VaultStore, SheetTestHost<PlatformsView>) {
			let opened = opened
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in "lpm_session" }, platformConnect: connect,
				platformURLOpener: { opened.append($0) })
			store.isUnlocked = true
			if signedIn {
				store.currentUser = LPMUser(id: "lpm_user_1", username: "tolga", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
			}
			store.showPlatforms()
			let host = SheetTestHost(PlatformsView(store: store), size: NSSize(width: 760, height: 560), keepsRequestedSize: true, usesHostingView: true)
			return (store, host)
		}

		@Test("a connected team shows with its slug, and Disconnect asks first, then forgets it on this Mac")
		func disconnects() async throws {
			_ = try await PlatformConnectionStore(service: keychain).save(
				VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_northwind", userID: "u_1")!,
				account: VercelAccount(name: "Northwind", slug: "northwind"), at: Date()).get()
			let (store, host) = try await page()
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Northwind"))
			#expect(try await host.waitForText("Team"))
			#expect(try await host.waitForText("northwind"))
			#expect(try await host.waitForText("Connect Vercel"))
			try await host.click("Disconnect")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Disconnecting asks first")
			#expect(keychain.platformConnectionStorage.count == 1)
			try host.clickAlertButton("Disconnect", in: try #require(host.window.sheets.first))
			#expect(try await host.waitUntil { keychain.platformConnectionStorage.isEmpty })
			#expect(try await host.waitForText("No Vercel accounts connected yet"))
		}

		@Test("connecting shows where to finish, and Cancel stops it")
		func connectsAndCancels() async throws {
			let (store, host) = try await page(connect: { _, open in
				await open(URL(string: "https://vercel.com/integrations/lpm-vault/new")!)
				try? await Task.sleep(for: .seconds(60))
				return .failure(.cancelled)
			})
			defer { host.window.close(); store.lock() }
			try await host.click("Connect Vercel")
			#expect(try await host.waitForText("Finish in your browser"))
			#expect(store.platforms.isConnecting)
			#expect(opened.urls == [URL(string: "https://vercel.com/integrations/lpm-vault/new")!])
			try await host.click("Cancel")
			#expect(try await host.waitUntil { !store.platforms.isConnecting })
			#expect(try await host.waitForTextToDisappear("Finish in your browser"))
		}

		@Test("signed out, the page says to sign in, and Connect does nothing")
		func signedOut() async throws {
			let (store, host) = try await page(signedIn: false)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Sign in to LPM to connect Vercel"))
			try await host.click("Connect Vercel")
			try await host.settle()
			#expect(!store.platforms.isConnecting)
		}
	}
}


private final class OpenedURLs: @unchecked Sendable {
	private let lock = NSLock()
	private var opened: [URL] = []

	var urls: [URL] { lock.withLock { opened } }
	func append(_ url: URL) { lock.withLock { opened.append(url) } }
}
