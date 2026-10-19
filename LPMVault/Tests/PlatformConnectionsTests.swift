import CryptoKit
import Foundation
import os
import SwiftUI
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
		#expect(try await store.record(for: saved.id).map(\.accessToken).get() == "vca_token_1")
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
		#expect(try await store.record(for: again.id).map(\.accessToken).get() == "vca_token_2")
	}

	@Test("removing forgets the connection and its token")
	func removes() async throws {
		let store = store
		let saved = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: nil), at: connectedAt).get()
		_ = try await store.remove(saved.id).get()
		#expect(try await store.connections().get().isEmpty)
		#expect(await store.record(for: saved.id).map(\.accessToken) == .failure(.notFound))
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
		#expect(await store.record(for: "vercel.team_other").map(\.accessToken) == .failure(.unreadable))
		#expect(await store.record(for: "vercel.team_newer").map(\.accessToken) == .failure(.newerVersion))
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
		#expect(try await store.record(for: saved.id).map(\.accessToken).get() == "3|coolify")
		let again = try await store.save(coolify(name: "Root"), accessToken: "6|new", at: connectedAt).get()
		#expect(again.id == saved.id)
		#expect(try await store.record(for: saved.id).map(\.accessToken).get() == "6|new")
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
		#expect(PlatformConnectionStore.decode(try altered { $0["platform"] = "render" }, account: id) == .failure(.newerVersion))
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
		// The cleanup entries are listed first, as they decide which connections are retired.
		#expect(labels.withLock { $0 }.count == 2)
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

	@Test("a token is saved even when the Keychain can't read the one it replaces")
	func savesOverUnreadable() async throws {
		let store = store
		keychain.failAppItemReads = ["vercel.team_acme"]
		let saved = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: "acme"), at: connectedAt).get()
		keychain.failAppItemReads = []
		#expect(try await store.record(for: saved.id).map(\.accessToken).get() == "vca_token_1")
	}

	@Test("a save cancelled while it writes, whose earlier token can't be written back, keeps no token")
	func failedRollbackDeletes() async throws {
		let store = store
		_ = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: "acme"), at: connectedAt).get()
		let entered = DispatchSemaphore(value: 0)
		let held = DispatchSemaphore(value: 0)
		let writes = OSAllocatedUnfairLock(initialState: 0)
		keychain.beforeAppItemWrite = { [keychain] in
			if writes.withLock({ $0 += 1; return $0 }) == 1 {
				entered.signal()
				_ = held.wait(timeout: .now() + testWaitSeconds)
			} else {
				keychain.failAppItemWrites = ["vercel.team_acme"]
			}
		}
		let save = Task { await store.save(grant(token: "vca_token_2"), account: VercelAccount(name: "Acme", slug: "acme"), at: connectedAt) }
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + testWaitSeconds)
				continuation.resume()
			}
		}
		save.cancel()
		held.signal()
		#expect(await save.value == .failure(.cancelled))
		keychain.beforeAppItemWrite = nil
		keychain.failAppItemWrites = []
		#expect(keychain.platformConnectionStorage["vercel.team_acme"] == nil)
	}

	@Test("a connection record never prints its token")
	func recordRedacted() {
		let record = PlatformConnectionStore.Record(
			connection: PlatformConnection(
				account: .coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: "0", teamName: "Root")),
				connectedAt: connectedAt),
			accessToken: "3|secret-token")
		var dumped = ""
		dump(record, to: &dumped)
		for text in [String(describing: record), String(reflecting: record), dumped] {
			#expect(!text.contains("secret-token"))
		}
	}

	@Test("connections with one name are told apart: personal Vercel accounts by username or user, Coolify teams by team")
	@MainActor
	func sameNamesTellApart() {
		func personal(_ user: String, slug: String?) -> PlatformConnection {
			PlatformConnection(
				account: .vercel(VercelConnectionAccount(installationID: "icfg_\(user)", teamID: nil, userID: user, name: "Personal account", slug: slug)),
				connectedAt: connectedAt)
		}
		let personals = [personal("u_1", slug: nil), personal("u_2", slug: nil), personal("u_3", slug: "tolga")]
		#expect(Set(personals.map(PublishSheet.connectionLabel)).count == personals.count)
		#expect(personals.allSatisfy { $0.detail.contains("personal") })
		let instance = CoolifyInstance(origin: "https://coolify.example.com")!
		let teams = ["0", "1"].map {
			PlatformConnection(account: .coolify(CoolifyConnectionAccount(instance: instance, teamID: $0, teamName: "Team")), connectedAt: connectedAt)
		}
		#expect(PublishSheet.connectionLabel(teams[0]) != PublishSheet.connectionLabel(teams[1]))
	}

	private func netlify(user: String = "5f1a2b3c4d5e6f7a8b9c0d1e", name: String = "Tolga Ergin", email: String? = "tolga@example.com") -> PlatformConnection.Account {
		.netlify(NetlifyConnectionAccount(userID: user, name: name, email: email))
	}

	@Test("a Netlify user is saved by its user, beside other platforms' accounts, and connecting again replaces it")
	func savesNetlify() async throws {
		let store = store
		let saved = try await store.save(netlify(), accessToken: "nfo_first", at: connectedAt).get()
		#expect(saved.id == "netlify.5f1a2b3c4d5e6f7a8b9c0d1e" && saved.platform == .netlify && saved.name == "Tolga Ergin")
		#expect(saved.detail == "tolga@example.com")
		_ = try await store.save(grant(), account: VercelAccount(name: "Acme", slug: "acme"), at: connectedAt).get()
		let again = try await store.save(netlify(name: "Tolga"), accessToken: "nfo_second", at: connectedAt).get()
		#expect(again.id == saved.id)
		#expect(try await store.connections().get().map(\.name) == ["Acme", "Tolga"])
		#expect(try await store.record(for: saved.id).map(\.accessToken).get() == "nfo_second")
	}

	@Test("a Netlify record round-trips exactly, with or without an email; one with an unknown field, an unsafe user or token isn't read")
	func netlifyRecords() throws {
		for account in [netlify(), netlify(email: nil)] {
			let record = PlatformConnectionStore.Record(
				connection: PlatformConnection(account: account, connectedAt: PublishTimestamp.normalized(connectedAt)),
				accessToken: "nfo_token")
			let data = try #require(PlatformConnectionStore.encode(record))
			#expect(PlatformConnectionStore.decode(data, account: record.connection.id) == .success(record))
		}
		let record = PlatformConnectionStore.Record(
			connection: PlatformConnection(account: netlify(), connectedAt: connectedAt), accessToken: "nfo_token")
		let id = record.connection.id
		let data = try #require(PlatformConnectionStore.encode(record))
		func altered(_ change: (inout [String: Any]) -> Void) throws -> Data {
			var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
			change(&object)
			return try JSONSerialization.data(withJSONObject: object)
		}
		#expect(PlatformConnectionStore.decode(try altered { $0["extra"] = 1 }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0.removeValue(forKey: "email") }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["email"] = 1 }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["accessToken"] = "has space" }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["userId"] = "../u" }, account: "netlify.../u") == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(data, account: "netlify.someone_else") == .failure(.unreadable))
		#expect(PlatformConnectionStore.encode(.init(connection: PlatformConnection(account: netlify(name: " Tolga"), connectedAt: connectedAt), accessToken: "nfo")) == nil)
		#expect(PlatformConnectionStore.encode(.init(connection: PlatformConnection(account: netlify(), connectedAt: connectedAt), accessToken: "nfo x")) == nil)
	}

	@Test("a Netlify name and email stored before they were escaped read back escaped")
	func escapesStoredNetlifyNames() async throws {
		let store = store
		let saved = try await store.save(netlify(), accessToken: "nfo_token", at: connectedAt).get()
		let data = try #require(keychain.platformConnectionStorage[saved.id])
		var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		object["name"] = "Tolga\u{202E}"
		object["email"] = "a\u{2066}@example.com"
		keychain.platformConnectionStorage[saved.id] = try JSONSerialization.data(withJSONObject: object)
		let connection = try #require(try await store.connections().get().first)
		#expect(connection.name == #"Tolga\u{202e}"# && connection.detail == #"a\u{2066}@example.com"#)
	}

	@Test("a Keychain failure is reported")
	func keychainFailure() async {
		keychain.failPlatformConnectionAccounts = ["*"]
		#expect(await store.connections() == .failure(.keychain(.accessDenied)))
	}

	private func github(name: String? = "The Octocat", login: String = "octocat") -> PlatformConnection.Account {
		.github(GitHubConnectionAccount(userID: "583231", login: login, name: name, appSlug: "lpm-vault"))
	}

	private func renewal() -> PlatformTokenRefresh {
		PlatformTokenRefresh(
			token: "ghr_refresh", accessTokenExpiresAt: connectedAt.addingTimeInterval(28_800),
			expiresAt: connectedAt.addingTimeInterval(15_897_600), obtainedAt: connectedAt, principalID: platformTestPrincipal)
	}

	@Test("a GitHub user is saved by its numeric ID with how its token renews, listed by name or else login, and told apart by login")
	func savesGitHub() async throws {
		let store = store
		let saved = try await store.save(github(), accessToken: "ghu_access", refresh: renewal(), at: connectedAt).get()
		#expect(saved.id == "github.583231" && saved.platform == .github && saved.name == "The Octocat" && saved.detail == "@octocat")
		let record = try await store.record(for: saved.id).get()
		#expect(record.accessToken == "ghu_access" && record.refresh == renewal())
		let renamed = try await store.save(github(name: nil, login: "octo-renamed"), accessToken: "ghu_again", at: connectedAt).get()
		#expect(renamed.id == saved.id && renamed.name == "octo-renamed")
		#expect(try await store.record(for: saved.id).get().refresh == nil, "Connecting again replaces how the token renewed")
	}

	@Test("a GitHub record round-trips exactly; one with an unknown field, an unsafe ID, login or slug isn't read")
	func gitHubRecords() throws {
		for account in [github(), github(name: nil)] {
			let record = PlatformConnectionStore.Record(
				connection: PlatformConnection(account: account, connectedAt: PublishTimestamp.normalized(connectedAt)),
				accessToken: "ghu_token", refresh: renewal())
			let data = try #require(PlatformConnectionStore.encode(record))
			#expect(PlatformConnectionStore.decode(data, account: record.connection.id) == .success(record))
		}
		let record = PlatformConnectionStore.Record(
			connection: PlatformConnection(account: github(), connectedAt: connectedAt), accessToken: "ghu_token")
		let id = record.connection.id
		let data = try #require(PlatformConnectionStore.encode(record))
		func altered(_ change: (inout [String: Any]) -> Void) throws -> Data {
			var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
			change(&object)
			return try JSONSerialization.data(withJSONObject: object)
		}
		#expect(PlatformConnectionStore.decode(try altered { $0["extra"] = 1 }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0.removeValue(forKey: "appSlug") }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["appSlug"] = "LPM Vault" }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["login"] = "octo cat" }, account: id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["userId"] = "0583231" }, account: "github.0583231") == .failure(.unreadable))
		#expect(PlatformConnectionStore.encode(.init(connection: PlatformConnection(account: github(), connectedAt: connectedAt), accessToken: "ghu x")) == nil)
	}

	@Test("the listing names connections whose token can't be renewed any more")
	func listsExpired() async throws {
		let store = store
		let current = try await store.save(github(), accessToken: "ghu_current", refresh: renewal(), at: connectedAt).get()
		var refused = renewal()
		refused.isRejected = true
		let other = try await store.save(
			.github(GitHubConnectionAccount(userID: "1", login: "other", name: nil, appSlug: "lpm-vault")),
			accessToken: "ghu_other", refresh: refused, at: connectedAt).get()
		let lasting = try await store.save(netlify(), accessToken: "nfo_lasting", at: connectedAt).get()
		let listing = try await store.listing(at: connectedAt).get()
		#expect(Set(listing.connections.map(\.id)) == [current.id, other.id, lasting.id])
		#expect(listing.expired == [other.id])
		#expect(try await store.listing(at: connectedAt.addingTimeInterval(15_897_600)).get().expired == [current.id, other.id])
	}
}

@MainActor
struct PlatformConnectionsModelTests {
	private let keychain = MockKeychainService()

	private func model(
		store: PlatformConnectionStore? = nil,
		connect: @escaping @Sendable () async -> Result<(grant: VercelGrant, account: VercelAccount), BrowserConnectError> = { .failure(.cancelled) },
		connectCoolify: @escaping PlatformConnections.ConnectCoolify = { _, _ in .failure(.cancelled) },
		connectNetlify: @escaping @Sendable () async -> Result<NetlifyConnection, BrowserConnectError> = { .failure(.cancelled) },
		connectGitHub: @escaping @Sendable (PlatformSession) async -> Result<GitHubConnection, BrowserConnectError> = { _ in .failure(.cancelled) },
		opened: OpenedLinks? = nil,
		session: PlatformSession? = platformTestSession(URL(string: "https://lpm.dev")!)
	) -> PlatformConnections {
		PlatformConnections(
			store: store ?? PlatformConnectionStore(service: keychain),
			connect: { _, open in
				await open(URL(string: "https://vercel.com/integrations/lpm-vault/new")!)
				return await connect()
			},
			connectCoolify: connectCoolify,
			connectNetlify: { _, open in
				await open(Self.netlifyAuthorizePage)
				return await connectNetlify()
			},
			connectGitHub: { session, open in
				await open(Self.githubAuthorizePage)
				return await connectGitHub(session)
			},
			session: { session },
			openURL: { opened?.append($0) },
			now: { Date(timeIntervalSince1970: 1_760_000_000) })
	}

	private nonisolated static let netlifyAuthorizePage = URL(string: "https://app.netlify.com/authorize?client_id=lpm_vault&response_type=code")!
	private nonisolated static let githubAuthorizePage = URL(string: "https://github.com/login/oauth/authorize?client_id=Iv23li")!

	private func waitUntilIdle(_ model: PlatformConnections) async throws {
		#expect(try await waitUntil { !model.isConnecting && !model.isLoading }, "The connection or the listing ended")
	}

	private nonisolated static let acme = (
		grant: VercelGrant(accessToken: "vca_acme", installationID: "icfg_1", teamID: "team_acme", userID: "u_1")!,
		account: VercelAccount(name: "Acme", slug: "acme"))

	@Test("connecting saves the connection, lists it and says so")
	func connects() async throws {
		let model = model { .success(Self.acme) }
		model.connectVercel()
		try await waitUntilIdle(model)
		#expect(model.connections.map(\.name) == ["Acme"])
		#expect(model.notice == .init(message: "Connected Acme on Vercel.", isError: false))
		#expect(keychain.platformConnectionStorage.keys.sorted() == ["vercel.team_acme"])
	}

	@Test("without an LPM session nothing starts, and the page says to sign in")
	func needsSession() async throws {
		let model = model(connect: { Issue.record("Started without a session"); return .failure(.cancelled) }, session: nil)
		model.connectVercel()
		try await waitUntilIdle(model)
		#expect(model.notice == .init(message: "Sign in to LPM to connect Vercel.", isError: true))
	}

	@Test("a failed connection shows why; a cancelled one shows nothing")
	func failures() async throws {
		let failed = model { .failure(.platform(.cancelledOnPlatform)) }
		failed.connectVercel()
		try await waitUntilIdle(failed)
		#expect(failed.notice?.isError == true && failed.notice?.message == "The connection was cancelled on Vercel.")
		let cancelled = model { .failure(.cancelled) }
		cancelled.connectVercel()
		try await waitUntilIdle(cancelled)
		#expect(cancelled.notice == nil)
	}

	@Test("locking mid-connection drops it, and a grant that arrives afterward isn't saved")
	func resetDropsLateGrant() async throws {
		let gate = AsyncGate()
		let connecting = AsyncGate()
		let model = model {
			await connecting.open()
			await gate.wait()
			return .success(Self.acme)
		}
		model.connectVercel()
		await connecting.wait()
		#expect(model.isConnecting)
		model.reset()
		#expect(!model.isConnecting)
		await gate.open()
		try await quietPeriod()
		#expect(model.connections.isEmpty && model.notice == nil)
		#expect(keychain.platformConnectionStorage.isEmpty)
	}

	@Test("disconnecting forgets the token and the row")
	func disconnects() async throws {
		let model = model { .success(Self.acme) }
		model.connectVercel()
		try await waitUntilIdle(model)
		let connection = try #require(model.connections.first)
		model.disconnect(connection)
		#expect(try await waitUntil { model.disconnecting.isEmpty })
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
		#expect(try await PlatformConnectionStore(service: keychain).record(for: connection.id).map(\.accessToken).get() == "3|coolify")
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
		let checking = AsyncGate()
		let model = model(connectCoolify: { _, _ in
			await checking.open()
			await gate.wait()
			return .success(Self.rootTeam)
		})
		let outcome = Task { await model.connectCoolify(address: "coolify.example.com", token: "3|coolify") }
		await checking.wait()
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
			_ = held.wait(timeout: .now() + testWaitSeconds)
		}
		Task.detached { _ = await store.connections() }
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + testWaitSeconds)
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
		try await letStartedWorkGetAhead()
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
		try await letStartedWorkGetAhead()
		model.cancelConnecting()
		release()
		try await waitUntilIdle(model)
		_ = await store.connections()
		#expect(keychain.platformConnectionStorage.isEmpty)
		#expect(model.notice == nil && model.connections.isEmpty)
	}

	@Test("a grant that arrives after Cancel is never saved")
	func vercelSuccessAfterCancel() async throws {
		let gate = AsyncGate()
		let connecting = AsyncGate()
		let model = model(connect: {
			await connecting.open()
			await gate.wait()
			return .success(Self.acme)
		})
		model.connectVercel()
		await connecting.wait()
		model.cancelConnecting()
		await gate.open()
		try await waitUntilIdle(model)
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
			_ = held.wait(timeout: .now() + testWaitSeconds)
		}
		let replacement = (
			grant: VercelGrant(accessToken: "vca_replacement", installationID: "icfg_2", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"))
		let model = model(store: store, connect: { .success(replacement) })
		model.connectVercel()
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + testWaitSeconds)
				continuation.resume()
			}
		}
		keychain.beforeAppItemWrite = nil
		model.reset()
		held.signal()
		#expect(try await waitUntil { keychain.platformConnectionStorage == earlier }, "The token written is taken back")
	}

	@Test("a token saved just before the vault locks is taken back, though the save itself had finished")
	func lockAfterSave() async throws {
		let store = PlatformConnectionStore(service: keychain)
		_ = try await store.save(Self.acme.grant, account: Self.acme.account, at: Date()).get()
		let earlier = keychain.platformConnectionStorage
		let entered = DispatchSemaphore(value: 0)
		let held = DispatchSemaphore(value: 0)
		keychain.beforeAppItemWrite = {
			entered.signal()
			_ = held.wait(timeout: .now() + testWaitSeconds)
		}
		let replacement = (
			grant: VercelGrant(accessToken: "vca_replacement", installationID: "icfg_2", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"))
		let model = model(store: store, connect: { .success(replacement) })
		model.connectVercel()
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + testWaitSeconds)
				continuation.resume()
			}
		}
		keychain.beforeAppItemWrite = nil
		held.signal()
		// Holding the main actor until the token is written lets the save finish before the lock, and the lock land
		// before the caller resumes, which it does on the main actor. It's held a moment at most, since every other
		// test on the main actor waits meanwhile; under load the lock may then land while the save runs, which
		// takes the token back too.
		let holdEnds = ContinuousClock.now + .milliseconds(200)
		while keychain.platformConnectionStorage == earlier, ContinuousClock.now < holdEnds { usleep(1_000) }
		model.reset()
		#expect(try await waitUntil { keychain.platformConnectionStorage == earlier }, "The token written is taken back")
		#expect(model.connections.isEmpty && model.notice == nil)
	}

	@Test("Vercel's page opens on the main actor, in the turn that checked the connection is still current")
	func opensWhileCurrent() async throws {
		let opened = OpenedLinks()
		let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
		let current = CurrentModel()
		let model = PlatformConnections(
			store: PlatformConnectionStore(service: keychain),
			connect: { _, open in
				await open(URL(string: "https://vercel.com/integrations/lpm-vault/new")!)
				return .failure(.cancelled)
			},
			session: { platformTestSession(URL(string: "https://lpm.dev")!) },
			openURL: { url in
				onMain.withLock { $0 = isMainThread() }
				#expect(current.model?.phase == .waitingForBrowser && current.model?.isConnecting == true)
				opened.append(url)
			},
			now: { Date() })
		current.model = model
		model.connectVercel()
		try await waitUntilIdle(model)
		#expect(opened.urls.count == 1)
		#expect(onMain.withLock { $0 } == true)
	}

	@Test("a connection reset before Vercel's page opens never opens it")
	func resetBeforeOpen() async throws {
		let gate = AsyncGate()
		let connecting = AsyncGate()
		let asked = AsyncGate()
		let opened = OpenedLinks()
		let model = PlatformConnections(
			store: PlatformConnectionStore(service: keychain),
			connect: { _, open in
				await connecting.open()
				await gate.wait()
				await open(URL(string: "https://vercel.com/integrations/lpm-vault/new")!)
				await asked.open()
				return .failure(.cancelled)
			},
			session: { platformTestSession(URL(string: "https://lpm.dev")!) },
			openURL: { opened.append($0) },
			now: { Date() })
		model.connectVercel()
		await connecting.wait()
		model.reset()
		await gate.open()
		await asked.wait()
		#expect(opened.urls.isEmpty && model.phase == .idle)
	}

	private nonisolated static let tolga = NetlifyConnection(
		user: NetlifyUser(id: "5f1a2b3c4d5e6f7a8b9c0d1e", name: "Tolga Ergin", email: "tolga@example.com"), token: "nfo_tolga")

	@Test("connecting Netlify with the LPM session opens its page, and saves the user, lists it and says so")
	func connectsNetlify() async throws {
		let opened = OpenedLinks()
		let model = model(connectNetlify: { .success(Self.tolga) }, opened: opened)
		model.connectNetlify()
		#expect(model.connecting == .netlify)
		try await waitUntilIdle(model)
		#expect(opened.urls == [Self.netlifyAuthorizePage])
		let connection = try #require(model.connections.first)
		#expect(connection.id == "netlify.5f1a2b3c4d5e6f7a8b9c0d1e" && connection.name == "Tolga Ergin" && connection.detail == "tolga@example.com")
		#expect(model.notice == .init(message: "Connected Tolga Ergin on Netlify.", isError: false))
		#expect(model.connecting == nil && model.phase == .idle)
		#expect(try await PlatformConnectionStore(service: keychain).record(for: connection.id).map(\.accessToken).get() == "nfo_tolga")
	}

	private nonisolated static let octocat = GitHubConnection(
		user: GitHubUser(id: "583231", login: "octocat", name: "The Octocat"),
		tokens: PlatformTokens(accessToken: "ghu_octocat", expiry: .init(accessTokenLifetime: 28_800, refreshToken: "ghr_octocat", refreshTokenLifetime: 15_897_600))!,
		appSlug: "lpm-vault",
		receivedAt: Date(timeIntervalSince1970: 1_760_000_050))

	@Test("connecting GitHub saves the user with how its token renews, for the LPM account that connected it")
	func connectsGitHub() async throws {
		let opened = OpenedLinks()
		let model = model(connectGitHub: { session in
			#expect(session.principalID == platformTestPrincipal)
			return .success(Self.octocat)
		}, opened: opened)
		model.connectGitHub()
		#expect(model.connecting == .github)
		try await waitUntilIdle(model)
		#expect(opened.urls == [Self.githubAuthorizePage])
		let connection = try #require(model.connections.first)
		#expect(connection.id == "github.583231" && connection.name == "The Octocat" && connection.detail == "@octocat")
		#expect(model.notice == .init(message: "Connected The Octocat on GitHub.", isError: false))
		let record = try await PlatformConnectionStore(service: keychain).record(for: connection.id).get()
		#expect(record.accessToken == "ghu_octocat")
		#expect(record.refresh == PlatformTokenRefresh(
			token: "ghr_octocat", accessTokenExpiresAt: Self.octocat.receivedAt.addingTimeInterval(28_800),
			expiresAt: Self.octocat.receivedAt.addingTimeInterval(15_897_600), obtainedAt: Self.octocat.receivedAt,
			principalID: platformTestPrincipal))
		#expect(model.expired.isEmpty)
	}

	@Test("loading names expired connections, and connecting one again clears it")
	func expiredConnections() async throws {
		var refused = PlatformTokenRefresh(
			token: "ghr_old", accessTokenExpiresAt: Date(timeIntervalSince1970: 1_760_000_000),
			expiresAt: Date(timeIntervalSince1970: 1_770_000_000), obtainedAt: Date(timeIntervalSince1970: 1_759_990_000),
			principalID: platformTestPrincipal)
		refused.isRejected = true
		_ = try await PlatformConnectionStore(service: keychain).save(
			.github(GitHubConnectionAccount(userID: "583231", login: "octocat", name: nil, appSlug: "lpm-vault")),
			accessToken: "ghu_old", refresh: refused, at: Date(timeIntervalSince1970: 1_759_990_000)).get()
		let model = model(connectGitHub: { _ in .success(Self.octocat) })
		model.load()
		try await waitUntilIdle(model)
		#expect(model.expired == ["github.583231"])
		model.connectGitHub()
		try await waitUntilIdle(model)
		#expect(model.expired.isEmpty)
	}

	@Test("without an LPM session Netlify doesn't start, no page opens, and the page says to sign in")
	func netlifyNeedsSession() async throws {
		let opened = OpenedLinks()
		let model = model(connectNetlify: { Issue.record("Started without a session"); return .failure(.cancelled) }, opened: opened, session: nil)
		model.connectNetlify()
		try await waitUntilIdle(model)
		#expect(opened.urls.isEmpty)
		#expect(model.notice == .init(message: "Sign in to LPM to connect Netlify.", isError: true))
	}

	@Test("a Netlify user without a name is listed by email, or else as a Netlify account")
	func namesNetlifyUser() async throws {
		let unnamed = NetlifyConnection(user: NetlifyUser(id: "u1", name: nil, email: "tolga@example.com"), token: "nfo_1")
		let anonymous = NetlifyConnection(user: NetlifyUser(id: "u2", name: nil, email: nil), token: "nfo_2")
		for (connection, name, detail) in [(unnamed, "tolga@example.com", "tolga@example.com"), (anonymous, "Netlify account", "user u2")] {
			let model = model(connectNetlify: { .success(connection) })
			model.connectNetlify()
			try await waitUntilIdle(model)
			let saved = try #require(model.connections.first { $0.id == "netlify.\(connection.user.id)" })
			#expect(saved.name == name && saved.detail == detail)
		}
	}

	@Test("a refused Netlify connection shows why, and a cancelled one shows nothing")
	func netlifyFailures() async throws {
		let failed = model(connectNetlify: { .failure(.platform(.cancelledOnPlatform)) })
		failed.connectNetlify()
		try await waitUntilIdle(failed)
		#expect(failed.notice == .init(message: "The connection was cancelled on Netlify.", isError: true))
		let cancelled = model(connectNetlify: { .failure(.cancelled) })
		cancelled.connectNetlify()
		try await waitUntilIdle(cancelled)
		#expect(cancelled.notice == nil && keychain.platformConnectionStorage.isEmpty)
	}

	@Test("one browser connection runs at a time, so Vercel doesn't start while Netlify connects")
	func oneBrowserConnection() async throws {
		let gate = AsyncGate()
		let netlifyConnecting = AsyncGate()
		let vercelStarted = OSAllocatedUnfairLock(initialState: false)
		let model = model(
			connect: {
				vercelStarted.withLock { $0 = true }
				return .failure(.cancelled)
			},
			connectNetlify: {
				await netlifyConnecting.open()
				await gate.wait()
				return .failure(.cancelled)
			})
		model.connectNetlify()
		await netlifyConnecting.wait()
		model.connectVercel()
		try await quietPeriod()
		#expect(model.connecting == .netlify && !vercelStarted.withLock { $0 })
		await gate.open()
		try await waitUntilIdle(model)
		model.connectVercel()
		try await waitUntilIdle(model)
		#expect(vercelStarted.withLock { $0 })
	}

	@Test("locking while Netlify connects drops it, and a token that arrives afterward isn't saved")
	func netlifyDroppedOnLock() async throws {
		let gate = AsyncGate()
		let connecting = AsyncGate()
		let model = model(connectNetlify: {
			await connecting.open()
			await gate.wait()
			return .success(Self.tolga)
		})
		model.connectNetlify()
		await connecting.wait()
		model.reset()
		#expect(!model.isConnecting && model.connecting == nil)
		await gate.open()
		try await quietPeriod()
		#expect(model.connections.isEmpty && model.notice == nil)
		#expect(keychain.platformConnectionStorage.isEmpty)
	}

	@Test("cancelling while Netlify's token waits to be saved leaves nothing in the Keychain, and no notice")
	func netlifyLateSaveDropped() async throws {
		let store = PlatformConnectionStore(service: keychain)
		let model = model(store: store, connectNetlify: { .success(Self.tolga) })
		let release = await holdStore(store)
		model.connectNetlify()
		try await letStartedWorkGetAhead()
		model.cancelConnecting()
		release()
		try await waitUntilIdle(model)
		_ = await store.connections()
		#expect(keychain.platformConnectionStorage.isEmpty)
		#expect(model.notice == nil && model.connections.isEmpty)
	}

	@Test("loading reads what this Mac holds")
	func loads() async throws {
		_ = try await PlatformConnectionStore(service: keychain).save(
			Self.acme.grant, account: Self.acme.account, at: Date()).get()
		let model = model { .failure(.cancelled) }
		model.load()
		try await waitUntilIdle(model)
		#expect(model.connections.map(\.id) == ["vercel.team_acme"])
	}
}

private final class OpenedLinks: @unchecked Sendable {
	private let lock = NSLock()
	private var opened: [URL] = []
	var urls: [URL] { lock.withLock { opened } }
	func append(_ url: URL) { lock.withLock { opened.append(url) } }
}

private func isMainThread() -> Bool { Thread.isMainThread }

@MainActor
private final class CurrentModel {
	weak var model: PlatformConnections?
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
		store.showAccount()
		#expect(store.accountPage == .account)
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
		#expect(try await waitUntil { !store.platforms.isLoading })
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
		#expect(try await waitUntil { !store.platforms.connections.isEmpty })
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
		private func page(
			signedIn: Bool = true,
			connect: PlatformConnections.Connect? = nil,
			connectNetlify: PlatformConnections.ConnectNetlify? = nil
		) async throws -> (VaultStore, SheetTestHost<PlatformsView>) {
			let opened = opened
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in "lpm_session" }, platformConnect: connect, netlifyConnect: connectNetlify,
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
			#expect(try await host.waitForText("No Vercel accounts connected yet"))
			#expect(try await host.waitUntil { !store.platforms.isLoading && store.platforms.connections.count == 1 })
			try host.scrollToEnd()
			#expect(try await host.waitForText("Northwind"))
			#expect(try await host.waitForText("coolify.northwind.dev"))
			try await host.click("Connect Coolify")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Connect Coolify opens its sheet")
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Turn on API access", in: sheet))
		}
	}

	@Suite("Platforms page Netlify section, rendered")
	@MainActor
	struct NetlifySectionRenderingTests {
		private let keychain = MockKeychainService()
		private let opened = OpenedURLs()

		private func page(
			signedIn: Bool = true,
			connectNetlify: @escaping PlatformConnections.ConnectNetlify
		) -> (VaultStore, SheetTestHost<PlatformsView>) {
			let opened = opened
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in signedIn ? "lpm_session" : nil }, netlifyConnect: connectNetlify,
				platformURLOpener: { opened.append($0) })
			store.isUnlocked = true
			if signedIn {
				store.currentUser = LPMUser(id: "lpm_user_1", username: "tolga", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
			}
			store.showPlatforms()
			let host = SheetTestHost(PlatformsView(store: store), size: NSSize(width: 760, height: 720), keepsRequestedSize: true, usesHostingView: true)
			return (store, host)
		}

		@Test("Connect Netlify opens Netlify's page with the LPM session, says where to finish, and Cancel stops it")
		func connectsAndCancels() async throws {
			let authorize = URL(string: "https://app.netlify.com/authorize?client_id=lpm_vault&response_type=code")!
			let (store, host) = page(connectNetlify: { session, open in
				#expect(session.principalID == "lpm_user_1")
				await open(authorize)
				try? await Task.sleep(for: .seconds(60))
				return .failure(.cancelled)
			})
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("No Netlify accounts connected yet"))
			try await host.click("Connect Netlify")
			#expect(try await host.waitForText("authorize LPM Vault on Netlify"))
			#expect(store.platforms.connecting == .netlify)
			#expect(opened.urls == [authorize])
			try await host.click("Cancel")
			#expect(try await host.waitUntil { !store.platforms.isConnecting })
			#expect(try await host.waitForTextToDisappear("authorize LPM Vault on Netlify"))
		}

		@Test("signed out of LPM, the Netlify section says to sign in, and Connect Netlify does nothing")
		func signedOut() async throws {
			let (store, host) = page(signedIn: false, connectNetlify: { _, _ in
				Issue.record("Started without a session")
				return .failure(.cancelled)
			})
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Sign in to LPM to connect Netlify"))
			try await host.click("Connect Netlify")
			try await host.settle()
			#expect(!store.platforms.isConnecting && opened.urls.isEmpty)
		}

		@Test("a connected Netlify account shows with its email, and Disconnect forgets it on this Mac")
		func disconnects() async throws {
			_ = try await PlatformConnectionStore(service: keychain).save(
				.netlify(NetlifyConnectionAccount(userID: "5f1a2b3c4d5e6f7a8b9c0d1e", name: "Northwind Dev", email: "dev@northwind.test")),
				accessToken: "nfo_1", at: Date()).get()
			let (store, host) = page(connectNetlify: { _, _ in .failure(.cancelled) })
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Northwind Dev"))
			#expect(try await host.waitForText("dev@northwind.test"))
			try await host.click("Disconnect")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Disconnecting asks first")
			let dialog = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("until you revoke it", in: dialog))
			try host.clickAlertButton("Disconnect", in: dialog)
			#expect(try await host.waitUntil { keychain.platformConnectionStorage.isEmpty })
			#expect(try await host.waitForText("No Netlify accounts connected yet"))
		}
	}

	@Suite("Platforms page GitHub section, rendered")
	@MainActor
	struct GitHubSectionRenderingTests {
		private let keychain = MockKeychainService()
		private let opened = OpenedURLs()

		private func page(connectGitHub: @escaping PlatformConnections.ConnectGitHub) -> (VaultStore, SheetTestHost<PlatformsView>) {
			let opened = opened
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in "lpm_session" }, githubConnect: connectGitHub,
				platformURLOpener: { opened.append($0) })
			store.isUnlocked = true
			store.currentUser = LPMUser(id: "lpm_user_1", username: "tolga", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
			store.showPlatforms()
			let host = SheetTestHost(PlatformsView(store: store), size: NSSize(width: 760, height: 720), keepsRequestedSize: true, usesHostingView: true)
			return (store, host)
		}

		@Test("Connect GitHub opens GitHub's page with the LPM session, says where to finish, and Cancel stops it")
		func connectsAndCancels() async throws {
			let authorize = URL(string: "https://github.com/login/oauth/authorize?client_id=Iv23li")!
			let (store, host) = page(connectGitHub: { session, open in
				#expect(session.principalID == "lpm_user_1")
				await open(authorize)
				try? await Task.sleep(for: .seconds(60))
				return .failure(.cancelled)
			})
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("No GitHub accounts connected yet"))
			try await host.click("Connect GitHub")
			#expect(try await host.waitForText("authorize LPM Vault on GitHub"))
			#expect(store.platforms.connecting == .github)
			#expect(opened.urls == [authorize])
			try await host.click("Cancel")
			#expect(try await host.waitUntil { !store.platforms.isConnecting })
			#expect(try await host.waitForTextToDisappear("authorize LPM Vault on GitHub"))
		}

		@Test("a connected GitHub user's row opens the page installing LPM Vault's app on more accounts, and the page says where organizations remove it")
		func linksToInstall() async throws {
			_ = try await PlatformConnectionStore(service: keychain).save(
				.github(GitHubConnectionAccount(userID: "583231", login: "octocat", name: "The Octocat", appSlug: "lpm-vault")),
				accessToken: "ghu_access", at: Date()).get()
			let (store, host) = page(connectGitHub: { _, _ in .failure(.cancelled) })
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("The Octocat"))
			try await host.click("Install on GitHub for The Octocat")
			#expect(try await host.waitUntil { !opened.urls.isEmpty })
			#expect(opened.urls == [URL(string: "https://github.com/apps/lpm-vault/installations/new")!])
			try host.scrollToEnd()
			#expect(try await host.waitForText("an organization's owner uninstalls it in the organization's settings"))
		}

		@Test("a connected GitHub user shows with its login, an expired one says to connect again, and Disconnect explains what stays on GitHub")
		func showsAndDisconnects() async throws {
			var refused = PlatformTokenRefresh(
				token: "ghr_old", accessTokenExpiresAt: Date(), expiresAt: Date().addingTimeInterval(86_400), obtainedAt: Date(),
				principalID: "lpm_user_1")
			refused.isRejected = true
			_ = try await PlatformConnectionStore(service: keychain).save(
				.github(GitHubConnectionAccount(userID: "583231", login: "octocat", name: "The Octocat", appSlug: "lpm-vault")),
				accessToken: "ghu_old", refresh: refused, at: Date()).get()
			let (store, host) = page(connectGitHub: { _, _ in .failure(.cancelled) })
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("The Octocat"))
			#expect(try await host.waitForText("@octocat"))
			#expect(try await host.waitForText("Expired. Connect GitHub again to keep publishing."))
			try await host.click("Disconnect The Octocat")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Disconnecting asks first")
			let dialog = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("until you revoke or uninstall it there", in: dialog))
			try host.clickAlertButton("Disconnect", in: dialog)
			#expect(try await host.waitUntil { keychain.platformConnectionStorage.isEmpty })
			#expect(try await host.waitForText("No GitHub accounts connected yet"))
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


/// The URLs a test's view opened, in order.
final class OpenedURLs: @unchecked Sendable {
	private let lock = NSLock()
	private var opened: [URL] = []

	var urls: [URL] { lock.withLock { opened } }
	func append(_ url: URL) { lock.withLock { opened.append(url) } }
}

extension SheetInteractionTests {
	@Suite("Platforms page Cloudflare section, rendered")
	@MainActor
	struct CloudflareSectionRenderingTests {
		private let keychain = MockKeychainService()
		private let opened = OpenedURLs()
		private let revoker = ScriptedRevoker()

		private func page(
			environment: AppEnvironment = .development,
			connectCloudflare: @escaping PlatformConnections.ConnectCloudflare = { _, _ in .failure(.cancelled) }
		) -> (VaultStore, SheetTestHost<PlatformsView>) {
			let store = makeStore(environment: environment, connectCloudflare: connectCloudflare)
			let host = SheetTestHost(PlatformsView(store: store), size: NSSize(width: 760, height: 1_000), keepsRequestedSize: true, usesHostingView: true)
			return (store, host)
		}

		private func makeStore(
			environment: AppEnvironment = .development,
			connectCloudflare: @escaping PlatformConnections.ConnectCloudflare = { _, _ in .failure(.cancelled) }
		) -> VaultStore {
			let opened = opened
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in "lpm_session" }, cloudflareConnect: connectCloudflare, platformRevoker: revoker,
				platformURLOpener: { opened.append($0) })
			store.appEnvironment = environment
			store.isUnlocked = true
			store.currentUser = LPMUser(id: platformTestPrincipal, username: "tolga", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
			store.showPlatforms()
			return store
		}

		/// A login saved now, with `accounts`, whose renewal the Registry refused when `rejected`.
		@discardableResult
		private func save(
			subject: String = CloudflareLoginFixture.subject,
			label: String = "Work",
			accounts: [CloudflareAccount] = [CloudflareLoginFixture.acme],
			rejected: Bool = false
		) async throws -> PlatformConnection {
			var refresh = CloudflareLoginFixture.refresh(at: Date())
			refresh.isRejected = rejected
			return try await CloudflareLoginFixture.save(
				CloudflareLoginFixture.account(subject: subject, label: label, accounts: accounts), in: PlatformConnectionStore(service: keychain),
				refresh: refresh)
		}

		@Test("Connect Cloudflare opens Cloudflare's page with the LPM session, says where to finish, and Cancel stops it")
		func connectsAndCancels() async throws {
			let authorize = URL(string: "https://dash.cloudflare.com/oauth2/auth?client_id=lpm-vault-development")!
			let (store, host) = page(connectCloudflare: { session, open in
				#expect(session.principalID == platformTestPrincipal && session.issuer == .development)
				await open(authorize)
				try? await Task.sleep(for: .seconds(60))
				return .failure(.cancelled)
			})
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("No Cloudflare logins connected yet"))
			try await host.click("Connect Cloudflare")
			#expect(try await host.waitForText("choose the Cloudflare accounts LPM Vault can reach"))
			#expect(store.platforms.connecting == .cloudflare && opened.urls == [authorize])
			try await host.click("Cancel")
			#expect(try await host.waitUntil { !store.platforms.isConnecting })
		}

		@Test("a connected login shows with its label and accounts, and Disconnect says LPM Vault revokes its access, then does")
		func showsAndDisconnects() async throws {
			try await save(accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
			let (store, host) = page()
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Work"))
			#expect(try await host.waitForText("Acme and Beta"))
			try await host.click("Disconnect Work")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Disconnecting asks first")
			let dialog = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("LPM Vault revokes its access to Work on Cloudflare", in: dialog))
			try host.clickAlertButton("Disconnect", in: dialog)
			#expect(try await host.waitUntil { keychain.platformConnectionStorage.isEmpty })
			#expect(revoker.calls.map(\.token) == ["cf_refresh_1"])
			#expect(try await host.waitForText("LPM Vault's access to it on Cloudflare has ended"))
		}

		@Test("a login that no longer works offers Reconnect, which asks before losing an account, and declining keeps it as it was")
		func reconnectAsksBeforeLosingAccounts() async throws {
			let connection = try await save(accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta], rejected: true)
			let tokens = PlatformTokens(
				accessToken: "cf_new_access", expiry: .init(accessTokenLifetime: 3_600, refreshToken: "cf_new_refresh", refreshTokenLifetime: 31_536_000))!
			let approved = CloudflareConnection(
				login: CloudflareLogin.key(subject: CloudflareLoginFixture.subject), accounts: [CloudflareLoginFixture.acme],
				grant: CloudflareGrant(tokens: tokens)!, issuer: .development, clientID: CloudflareLoginFixture.clientID,
				generation: CloudflareConnectionAccount.makeGeneration(), receivedAt: Date())
			let (store, host) = page(connectCloudflare: { _, _ in .success(approved) })
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("No longer works. Reconnect to keep publishing through it."))
			try await host.click("Reconnect Work")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Reconnecting asks before losing an account")
			let dialog = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Work would reach fewer accounts", in: dialog))
			#expect(try await host.waitForText("would no longer reach Beta through Work", in: dialog))
			try host.clickAlertButton("Cancel", in: dialog)
			#expect(try await host.waitUntil { revoker.calls.map(\.token) == ["cf_new_refresh"] }, "Only the new grant is revoked")
			#expect(try await store.platformConnectionStore.record(for: connection.id).get().connection.generation == connection.generation)
		}

		@Test("reconnecting one login but approving another offers to add it beside it or put it in its place", arguments: ["Add It Separately", "Replace Work"])
		func otherLoginButtons(button: String) async throws {
			let work = try await save(rejected: true)
			let tokens = PlatformTokens(
				accessToken: "cf_new_access", expiry: .init(accessTokenLifetime: 3_600, refreshToken: "cf_new_refresh", refreshTokenLifetime: 31_536_000))!
			let approved = CloudflareConnection(
				login: CloudflareLogin.key(subject: CloudflareLoginFixture.otherSubject), accounts: [CloudflareLoginFixture.acme],
				grant: CloudflareGrant(tokens: tokens)!, issuer: .development, clientID: CloudflareLoginFixture.clientID,
				generation: CloudflareConnectionAccount.makeGeneration(), receivedAt: Date())
			let (store, host) = page(connectCloudflare: { _, _ in .success(approved) })
			defer { host.window.close(); store.lock() }
			try await host.click("Reconnect Work")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Approving another login asks first")
			let dialog = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("You approved a different Cloudflare login, not Work", in: dialog))
			try host.clickAlertButton(button, in: dialog)
			#expect(try await host.waitUntil { keychain.platformConnectionStorage[approved.connectionID] != nil })
			#expect((keychain.platformConnectionStorage[work.id] != nil) == (button == "Add It Separately"))
		}

		@Test("Rename gives a login the name typed, and when another login has it, says so and asks again")
		func renamesThroughAlert() async throws {
			try await save()
			try await save(subject: CloudflareLoginFixture.otherSubject, label: "Home")
			let (store, host) = page()
			defer { host.window.close(); store.lock() }
			try await host.click("Rename Work")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Rename asks for the name")
			let alert = try #require(host.window.sheets.first)
			try host.typeText("Home", placeholder: "Name", in: alert)
			try host.clickAlertButton("Rename", in: alert)
			#expect(try await host.waitUntil { host.window.sheets.first.map { $0 !== alert } ?? false }, "The name taken asks again")
			let again = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Another connected Cloudflare login is called Home. Choose another name.", in: again))
			try host.typeText("Clients", placeholder: "Name", in: again)
			try host.clickAlertButton("Rename", in: again)
			#expect(try await host.waitForText("Clients"))
			#expect(store.platforms.connections.map(\.name).sorted() == ["Clients", "Home"])
		}

		@Test("a question about a login just approved hides behind the privacy curtain unanswered, comes back with it, and Connect Anyway goes on")
		func promptHidesBehindCurtain() async throws {
			let connection = try await save(accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
			let tokens = PlatformTokens(
				accessToken: "cf_new_access", expiry: .init(accessTokenLifetime: 3_600, refreshToken: "cf_new_refresh", refreshTokenLifetime: 31_536_000))!
			let approved = CloudflareConnection(
				login: CloudflareLogin.key(subject: CloudflareLoginFixture.subject), accounts: [CloudflareLoginFixture.acme],
				grant: CloudflareGrant(tokens: tokens)!, issuer: .development, clientID: CloudflareLoginFixture.clientID,
				generation: CloudflareConnectionAccount.makeGeneration(), receivedAt: Date())
			let store = makeStore(connectCloudflare: { _, _ in .success(approved) })
			let curtain = Curtain()
			let host = SheetTestHost(
				CurtainedPlatforms(store: store, curtain: curtain), size: NSSize(width: 760, height: 1_000), keepsRequestedSize: true,
				usesHostingView: true)
			defer { host.window.close(); store.lock() }
			try await host.click("Connect Cloudflare")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Connecting asks before losing an account")
			curtain.isObscured = true
			#expect(try await host.waitUntil { host.window.sheets.isEmpty }, "The question hides behind the curtain")
			#expect(store.platforms.cloudflarePrompt != nil)
			curtain.isObscured = false
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "The question comes back")
			let dialog = try #require(host.window.sheets.first)
			try host.clickAlertButton("Connect Anyway", in: dialog)
			#expect(try await waitUntil {
				await (try? store.platformConnectionStore.record(for: connection.id).get())?.connection.generation == approved.generation
			})
		}

		@Test("where Cloudflare can't be connected, notes of its unconfirmed revocations still show, as one note that dismisses them all")
		func notesWithoutCloudflare() async throws {
			let connections = PlatformConnectionStore(service: keychain)
			for _ in 0..<2 {
				_ = await connections.mark(PlatformCleanupMarker(platform: .cloudflare, generation: CloudflareConnectionAccount.makeGeneration(), createdAt: Date()))
			}
			let (store, host) = page(environment: .production)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("couldn't confirm that the access of 2 Cloudflare logins was revoked"))
			try await host.click("Dismiss the note about unconfirmed revocations")
			#expect(try await host.waitForTextToDisappear("Connected Applications on Cloudflare"))
			#expect(try await waitUntil {
				!keychain.platformCleanupStorage.keys.contains { $0.hasPrefix(PlatformCleanupRecords.markerPrefix) }
			})
		}

		@Test("a login reaching more accounts than its row names lists them all on the row's help")
		func namesEveryAccount() async throws {
			let gamma = CloudflareAccount(id: "2c3d4e5f60718293a4b5c6d7e8f90a1b", name: "Gamma")
			try await save(accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta, gamma])
			let (store, host) = page()
			defer { host.window.close(); store.lock() }
			let summary = try await host.waitForElement(saying: "Acme and 2 more")
			#expect(summary.help == "Reaches " + ListFormatter.localizedString(byJoining: ["Acme", "Beta", "Gamma"]))
		}

		@Test("while a login reconnects, its button's accessible name says what it shows")
		func reconnectingName() async throws {
			try await save(rejected: true)
			let (store, host) = page(connectCloudflare: { _, open in
				await open(URL(string: "https://dash.cloudflare.com/oauth2/auth")!)
				try? await Task.sleep(for: .seconds(60))
				return .failure(.cancelled)
			})
			defer { host.window.close(); store.lock() }
			try await host.click("Reconnect Work")
			let button = try await host.waitForElement(saying: "Reconnecting…")
			#expect(button.label?.contains("Reconnecting…") == true && button.label?.contains("Work") == true)
			try await host.click("Cancel")
			#expect(try await host.waitUntil { !store.platforms.isConnecting })
		}

		@Test("where Cloudflare can't be connected, the page doesn't mention it")
		func noCloudflareCopy() async throws {
			let (store, host) = page(environment: .production)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Disconnecting forgets a token on this Mac only"))
			#expect(!host.lines().contains { $0.text.contains("Cloudflare") })
		}

		@Test("a login disconnected while signed out says signing in finishes revoking its access")
		func revocationAwaitsSignIn() async throws {
			try await save()
			let (store, host) = page()
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Work"))
			store.currentUser = nil
			try await host.click("Disconnect Work")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Disconnecting asks first")
			let dialog = try #require(host.window.sheets.first)
			try host.clickAlertButton("Disconnect", in: dialog)
			#expect(try await host.waitForText("Sign in to LPM to finish revoking Cloudflare access LPM Vault no longer uses."))
			#expect(revoker.calls.isEmpty)
		}

		@Test("a note of an unconfirmed revocation says how to remove LPM Vault on Cloudflare, until it's dismissed")
		func showsMarker() async throws {
			let marker = PlatformCleanupMarker(platform: .cloudflare, generation: CloudflareConnectionAccount.makeGeneration(), createdAt: Date())
			_ = await PlatformConnectionStore(service: keychain).mark(marker)
			try await save()
			let (store, host) = page()
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Connected Applications on Cloudflare"))
			try await host.click("Dismiss the note about an unconfirmed revocation")
			#expect(try await host.waitForTextToDisappear("Connected Applications on Cloudflare"))
		}
	}
}

/// Whether the privacy curtain is up over the window, as a test raises it.
@Observable @MainActor
private final class Curtain {
	var isObscured = false
}

/// The Platforms page under a privacy curtain the test raises.
private struct CurtainedPlatforms: View {
	let store: VaultStore
	var curtain: Curtain
	var body: some View {
		PlatformsView(store: store).environment(\.vaultContentObscured, curtain.isObscured)
	}
}
