import CryptoKit
import Foundation
import os
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

	private func coolify(team: String = "0", name: String = "Root Team", origin: String = "https://coolify.example.com") -> PlatformConnection.Account {
		.coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: origin)!, teamID: team, teamName: name))
	}

	@Test("a Coolify team is saved by its instance and team, beside Vercel accounts")
	func savesCoolify() async throws {
		let store = store
		let saved = try await store.save(coolify(), accessToken: "3|coolify", at: connectedAt).get()
		#expect(saved.id == "coolify.0.https://coolify.example.com" && saved.platform == .coolify && saved.name == "Root Team")
		let elsewhere = try await store.save(coolify(origin: "https://coolify.example.dev"), accessToken: "4|other", at: connectedAt).get()
		let otherTeam = try await store.save(coolify(team: "12", name: "Northwind"), accessToken: "5|team", at: connectedAt).get()
		#expect(Set([saved.id, elsewhere.id, otherTeam.id]).count == 3)
		_ = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: "acme"), at: connectedAt).get()
		#expect(try await store.connections().get().map(\.name) == ["Acme", "Northwind", "Root Team", "Root Team"])
		#expect(try await store.accessToken(for: saved.id).get() == "3|coolify")
		let again = try await store.save(coolify(name: "Root"), accessToken: "6|new", at: connectedAt).get()
		#expect(again.id == saved.id)
		#expect(try await store.accessToken(for: saved.id).get() == "6|new")
	}

	@Test("a Coolify record round-trips exactly; one with an unknown field or a changed address isn't read")
	func coolifyRecords() throws {
		let record = PlatformConnectionStore.Record(
			connection: PlatformConnection(account: coolify(), connectedAt: PublishTimestamp.normalized(connectedAt)),
			accessToken: "3|coolify")
		let id = record.connection.id
		let data = try #require(PlatformConnectionStore.encode(record))
		#expect(PlatformConnectionStore.decode(data, account: id) == .success(record))

		func altered(_ change: (inout [String: Any]) -> Void) throws -> Data {
			var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
			change(&object)
			return try JSONSerialization.data(withJSONObject: object)
		}
		#expect(PlatformConnectionStore.decode(try altered { $0["extra"] = 1 }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["instance"] = "https://Coolify.example.com" }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["teamId"] = "0x" }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["accessToken"] = "has space" }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(data, account: "coolify.1.https://coolify.example.com") == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["platform"] = "netlify" }, account: id) == .failure(.newerVersion))
	}

	@Test("a Coolify connection that couldn't be read back isn't stored")
	func refusesUnstorableCoolify() {
		let connection = PlatformConnection(account: coolify(), connectedAt: connectedAt)
		#expect(PlatformConnectionStore.encode(.init(connection: connection, accessToken: "3|a b")) == nil)
		let badTeam = PlatformConnection(account: coolify(team: "-1"), connectedAt: connectedAt)
		#expect(PlatformConnectionStore.encode(.init(connection: badTeam, accessToken: "3|ok")) == nil)
		let badName = PlatformConnection(account: coolify(name: " Root"), connectedAt: connectedAt)
		#expect(PlatformConnectionStore.encode(.init(connection: badName, accessToken: "3|ok")) == nil)
	}

	@Test("the store's Keychain calls run off the cooperative pool, so one that blocks never holds up other work")
	func runsOffThePool() async {
		let labels = OSAllocatedUnfairLock<[String]>(initialState: [])
		keychain.beforeAppItemListing = {
			let label = String(cString: __dispatch_queue_get_label(nil))
			labels.withLock { $0.append(label) }
		}
		_ = await store.connections()
		#expect(labels.withLock { $0 }.count == 1)
		#expect(labels.withLock { $0 }.allSatisfy { !$0.contains("cooperative") }, "\(labels.withLock { $0 })")
	}

	@Test("names stored before they were escaped read back with their direction controls escaped")
	func escapesStoredNames() async throws {
		let store = store
		let saved = try await store.save(coolify(name: "Root"), accessToken: "3|coolify", at: connectedAt).get()
		let data = try #require(keychain.platformConnectionStorage[saved.id])
		var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		object["teamName"] = "Root\u{202E}maeT\u{2066}"
		keychain.platformConnectionStorage[saved.id] = try JSONSerialization.data(withJSONObject: object)
		#expect(try await store.connections().get().first?.name == #"Root\u{202e}maeT\u{2066}"#)
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
		store: PlatformConnectionStore? = nil,
		connect: @escaping @Sendable () async -> Result<(grant: VercelGrant, account: VercelAccount), VercelConnectError> = { .failure(.cancelled) },
		connectCoolify: @escaping PlatformConnections.ConnectCoolify = { _, _ in .failure(.cancelled) },
		session: PlatformSession? = platformTestSession(URL(string: "https://lpm.dev")!)
	) -> PlatformConnections {
		PlatformConnections(
			store: store ?? PlatformConnectionStore(service: keychain),
			connect: { _, open in
				await open(URL(string: "https://vercel.com/integrations/lpm-vault/new")!)
				return await connect()
			},
			connectCoolify: connectCoolify,
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

	private nonisolated static let rootTeam = CoolifyConnection(
		instance: CoolifyInstance(origin: "https://coolify.example.com")!, team: CoolifyTeam(id: "0", name: "Root Team"), token: "3|coolify")

	@Test("connecting Coolify needs no LPM sign-in, and saves the team, lists it and says so")
	func connectsCoolify() async throws {
		let model = model(connectCoolify: { address, token in
			#expect(address == "coolify.example.com" && token == "3|coolify")
			return .success(Self.rootTeam)
		}, session: nil)
		let outcome = await model.connectCoolify(address: "coolify.example.com", token: "3|coolify")
		let connection = try #require(model.connections.first)
		#expect(outcome == .connected(connection) && connection.name == "Root Team" && connection.platform == .coolify)
		#expect(model.notice == .init(message: "Connected Root Team on Coolify.", isError: false))
		#expect(keychain.platformConnectionStorage.keys.sorted() == ["coolify.0.https://coolify.example.com"])
		#expect(try await PlatformConnectionStore(service: keychain).accessToken(for: connection.id).get() == "3|coolify")
	}

	@Test("a refused Coolify token is explained, and nothing is saved")
	func coolifyRefused() async {
		let model = model(connectCoolify: { _, _ in .failure(.apiDisabled) })
		#expect(await model.connectCoolify(address: "coolify.example.com", token: "3|coolify") == .failed(CoolifyConnectError.apiDisabled.message))
		#expect(model.connections.isEmpty && keychain.platformConnectionStorage.isEmpty)
	}

	@Test("locking while Coolify checks the token drops the connection unsaved")
	func coolifyDroppedOnLock() async throws {
		let gate = AsyncGate()
		let model = model(connectCoolify: { _, _ in
			await gate.wait()
			return .success(Self.rootTeam)
		})
		let outcome = Task { await model.connectCoolify(address: "coolify.example.com", token: "3|coolify") }
		try await Task.sleep(for: .milliseconds(30))
		model.reset()
		await gate.open()
		#expect(await outcome.value == .dropped)
		#expect(model.connections.isEmpty && model.notice == nil)
		#expect(keychain.platformConnectionStorage.isEmpty)
	}

	/// Holds `store` inside a Keychain listing until `release` is called, so
	/// a save sent meanwhile waits behind it.
	private func holdStore(_ store: PlatformConnectionStore) async -> @Sendable () -> Void {
		let entered = DispatchSemaphore(value: 0)
		let held = DispatchSemaphore(value: 0)
		keychain.beforeAppItemListing = {
			entered.signal()
			_ = held.wait(timeout: .now() + 30)
		}
		Task.detached { _ = await store.connections() }
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + 30)
				continuation.resume()
			}
		}
		keychain.beforeAppItemListing = nil
		return { held.signal() }
	}

	@Test("locking or cancelling while Coolify's token waits to be saved leaves nothing in the Keychain", arguments: [true, false])
	func coolifyLateSaveDropped(locks: Bool) async throws {
		let store = PlatformConnectionStore(service: keychain)
		let model = model(store: store, connectCoolify: { _, _ in .success(Self.rootTeam) })
		let release = await holdStore(store)
		let outcome = Task { await model.connectCoolify(address: "coolify.example.com", token: "3|coolify") }
		try await Task.sleep(for: .milliseconds(50))
		if locks { model.reset() } else { outcome.cancel() }
		release()
		#expect(await outcome.value == .dropped)
		_ = await store.connections()
		#expect(keychain.platformConnectionStorage.isEmpty)
		#expect(model.connections.isEmpty)
	}

	@Test("cancelling while Vercel's grant waits to be saved leaves nothing in the Keychain, and no notice")
	func vercelLateSaveDropped() async throws {
		let store = PlatformConnectionStore(service: keychain)
		let model = model(store: store, connect: { .success(Self.acme) })
		let release = await holdStore(store)
		model.connectVercel()
		try await Task.sleep(for: .milliseconds(50))
		model.cancelConnecting()
		release()
		await waitUntilIdle(model)
		_ = await store.connections()
		#expect(keychain.platformConnectionStorage.isEmpty)
		#expect(model.notice == nil && model.connections.isEmpty)
	}

	@Test("a grant that arrives after Cancel is never saved")
	func vercelSuccessAfterCancel() async throws {
		let gate = AsyncGate()
		let model = model(connect: {
			await gate.wait()
			return .success(Self.acme)
		})
		model.connectVercel()
		try await Task.sleep(for: .milliseconds(30))
		model.cancelConnecting()
		await gate.open()
		await waitUntilIdle(model)
		#expect(keychain.platformConnectionStorage.isEmpty)
		#expect(model.notice == nil && model.connections.isEmpty)
	}

	@Test("locking while the Keychain writes a token takes it back, leaving any earlier token as it was", arguments: [false, true])
	func lockDuringWrite(hadToken: Bool) async throws {
		let store = PlatformConnectionStore(service: keychain)
		if hadToken {
			_ = try await store.save(Self.acme.grant, account: Self.acme.account, at: Date()).get()
		}
		let earlier = keychain.platformConnectionStorage
		let entered = DispatchSemaphore(value: 0)
		let held = DispatchSemaphore(value: 0)
		keychain.beforeAppItemWrite = {
			entered.signal()
			_ = held.wait(timeout: .now() + 30)
		}
		let replacement = (
			grant: VercelGrant(accessToken: "vca_replacement", installationID: "icfg_2", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"))
		let model = model(store: store, connect: { .success(replacement) })
		model.connectVercel()
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + 30)
				continuation.resume()
			}
		}
		keychain.beforeAppItemWrite = nil
		model.reset()
		held.signal()
		_ = await store.connections()
		#expect(keychain.platformConnectionStorage == earlier)
	}

	@Test("a connection reset before Vercel's page opens never opens it")
	func resetBeforeOpen() async throws {
		let gate = AsyncGate()
		let opened = OpenedLinks()
		let model = PlatformConnections(
			store: PlatformConnectionStore(service: keychain),
			connect: { _, open in
				await gate.wait()
				await open(URL(string: "https://vercel.com/integrations/lpm-vault/new")!)
				return .failure(.cancelled)
			},
			session: { platformTestSession(URL(string: "https://lpm.dev")!) },
			openURL: { opened.append($0) },
			now: { Date() })
		model.connectVercel()
		try await Task.sleep(for: .milliseconds(30))
		model.reset()
		await gate.open()
		try await Task.sleep(for: .milliseconds(50))
		#expect(opened.urls.isEmpty && model.phase == .idle)
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

private final class OpenedLinks: @unchecked Sendable {
	private let lock = NSLock()
	private var opened: [URL] = []
	var urls: [URL] { lock.withLock { opened } }
	func append(_ url: URL) { lock.withLock { opened.append(url) } }
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

		@Test("a connected Coolify team shows with its instance, and Connect Coolify opens the sheet")
		func coolifySection() async throws {
			_ = try await PlatformConnectionStore(service: keychain).save(
				.coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: "https://coolify.northwind.dev")!, teamID: "0", teamName: "Northwind")),
				accessToken: "3|coolify", at: Date()).get()
			let (store, host) = try await page()
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Northwind"))
			#expect(try await host.waitForText("coolify.northwind.dev"))
			#expect(try await host.waitForText("No Vercel accounts connected yet"))
			try await host.click("Connect Coolify")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Connect Coolify opens its sheet")
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Turn on API access", in: sheet))
		}
	}

	@Suite("Connect Coolify sheet, rendered")
	@MainActor
	struct ConnectCoolifySheetRenderingTests {
		private let keychain = MockKeychainService()

		private final class Answers: @unchecked Sendable {
			private let lock = NSLock()
			private var pending: [Result<CoolifyConnection, CoolifyConnectError>]
			private var received: [(address: String, token: String)] = []

			init(_ answers: [Result<CoolifyConnection, CoolifyConnectError>]) { pending = answers }

			var calls: [(address: String, token: String)] { lock.withLock { received } }

			func next(_ address: String, _ token: String) -> Result<CoolifyConnection, CoolifyConnectError> {
				lock.withLock {
					received.append((address, token))
					return pending.isEmpty ? .failure(.cancelled) : pending.removeFirst()
				}
			}
		}

		private func sheet(_ answers: Answers) -> (PlatformConnections, SheetTestHost<ConnectCoolifySheet>) {
			let platforms = PlatformConnections(
				store: PlatformConnectionStore(service: keychain),
				connect: { _, _ in .failure(.cancelled) },
				connectCoolify: { answers.next($0, $1) },
				session: { nil },
				openURL: { _ in })
			let host = SheetTestHost(ConnectCoolifySheet(platforms: platforms), size: NSSize(width: 520, height: 520), keepsRequestedSize: true, usesHostingView: true)
			return (platforms, host)
		}

		/// The sheet's own Connect button, in its footer, not the title above it.
		private let footer = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.2)

		@Test("Connect waits for both fields, explains a refusal, then saves the team Coolify names")
		func connects() async throws {
			let northwind = CoolifyConnection(
				instance: CoolifyInstance(origin: "https://coolify.northwind.dev")!, team: CoolifyTeam(id: "4", name: "Northwind"), token: "3|coolify")
			let answers = Answers([.failure(.apiDisabled), .success(northwind)])
			let (platforms, host) = sheet(answers)
			defer { host.window.close() }
			#expect(try await host.waitForText("Read and Write permissions"))
			try await host.click("Connect", region: footer)
			try await host.settle()
			#expect(answers.calls.isEmpty, "Nothing is checked until both fields are filled")

			try host.enterText("coolify.northwind.dev", at: 0)
			try host.enterValue("3|coolify")
			try await host.click("Connect", region: footer)
			#expect(try await host.waitForText("API is turned off"))
			#expect(platforms.connections.isEmpty && keychain.platformConnectionStorage.isEmpty)

			try await host.click("Connect", region: footer)
			#expect(try await host.waitUntil { !platforms.connections.isEmpty })
			#expect(answers.calls.map(\.address) == ["coolify.northwind.dev", "coolify.northwind.dev"])
			#expect(answers.calls.map(\.token) == ["3|coolify", "3|coolify"])
			#expect(platforms.connections.map(\.name) == ["Northwind"])
			#expect(keychain.platformConnectionStorage.keys.sorted() == ["coolify.4.https://coolify.northwind.dev"])
		}
	}
}


private final class OpenedURLs: @unchecked Sendable {
	private let lock = NSLock()
	private var opened: [URL] = []

	var urls: [URL] { lock.withLock { opened } }
	func append(_ url: URL) { lock.withLock { opened.append(url) } }
}
