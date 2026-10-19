import Foundation
import Testing
@testable import LPMVault

/// Connecting, reconnecting and disconnecting Cloudflare logins on the Platforms page.
@MainActor
struct CloudflarePlatformsTests {
	private let keychain = MockKeychainService()
	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }

	/// A login just approved, as the connector hands it over.
	private nonisolated static func approved(
		subject: String = CloudflareLoginFixture.subject,
		accounts: [CloudflareAccount] = [CloudflareLoginFixture.acme],
		refresh: String = "cf_new_refresh"
	) -> CloudflareConnection {
		let tokens = PlatformTokens(
			accessToken: "cf_new_access",
			expiry: .init(accessTokenLifetime: 3_600, refreshToken: refresh, refreshTokenLifetime: 31_536_000))!
		return CloudflareConnection(
			login: CloudflareLogin.key(subject: subject), accounts: accounts, grant: CloudflareGrant(tokens: tokens)!, issuer: .development,
			clientID: CloudflareLoginFixture.clientID, generation: CloudflareConnectionAccount.makeGeneration(), receivedAt: CloudflareLoginFixture.start)
	}

	private func model(
		revoker: ScriptedRevoker = ScriptedRevoker(),
		session: PlatformSession? = platformTestSession(URL(string: "http://localhost:3000")!),
		_ connect: @escaping @Sendable () async -> Result<CloudflareConnection, BrowserConnectError>
	) -> (PlatformConnections, PlatformCredentials) {
		let store = store
		let credentials = PlatformCredentials(
			store: store, revoker: revoker, session: { session }, now: { CloudflareLoginFixture.start },
			sleep: RecordedWaits().sleep, productionClientID: "lpm-vault-production")
		let model = PlatformConnections(
			store: store,
			connectCloudflare: { _, open in
				await open(URL(string: "https://dash.cloudflare.com/oauth2/auth")!)
				return await connect()
			},
			credentials: credentials,
			session: { session },
			openURL: { _ in },
			now: { CloudflareLoginFixture.start })
		return (model, credentials)
	}

	private func idle(_ model: PlatformConnections) async throws {
		#expect(try await waitUntil { !model.isConnecting && !model.isLoading }, "The connection or the listing ended")
	}

	private func record(_ id: PlatformConnection.ID) async throws -> CloudflareConnectionAccount {
		guard case .cloudflare(let account) = try await store.record(for: id).get().connection.account else {
			throw PlatformConnectionStoreError.notFound
		}
		return account
	}

	@Test("connecting saves the login with a default label, its accounts, client and generation, and says so")
	func connects() async throws {
		let new = Self.approved(accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let (model, _) = model { .success(new) }
		model.connectCloudflare()
		try await idle(model)
		let saved = try await record(new.connectionID)
		#expect(saved.generation == new.generation && saved.accounts == new.accounts && saved.clientID == CloudflareLoginFixture.clientID)
		#expect(saved.label.hasPrefix("Acme · ") && saved.label.count == "Acme · ".count + CloudflareLogin.codeLength)
		#expect(model.connections.map(\.name) == [saved.label])
		#expect(model.notice == .init(message: "Connected \(saved.label) on Cloudflare.", isError: false))
		#expect(try await store.record(for: new.connectionID).get().refresh?.token == "cf_new_refresh")
	}

	@Test("connecting a login that's already connected revokes its old generation first, then saves the new one under its label")
	func reconnectsSameLogin() async throws {
		let old = CloudflareLoginFixture.account(label: "Work")
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let revoker = ScriptedRevoker()
		let new = Self.approved()
		let (model, _) = model(revoker: revoker) { .success(new) }
		model.connectCloudflare()
		try await idle(model)
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1"])
		let saved = try await record(connection.id)
		#expect(saved.generation == new.generation && saved.label == "Work")
		#expect(keychain.platformCleanupStorage.keys.allSatisfy { $0 == PlatformCleanupRecords.labelSaltAccount })
	}

	@Test("a reconnect that would lose accounts asks first; declining revokes only the new grant and leaves the old connection working")
	func lostAccountsDeclined() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let revoker = ScriptedRevoker()
		let (model, _) = model(revoker: revoker) { .success(Self.approved(accounts: [CloudflareLoginFixture.acme])) }
		model.connectCloudflare()
		#expect(try await waitUntil { model.cloudflarePrompt != nil })
		#expect(model.cloudflarePrompt == .losesAccounts(label: "Work", accounts: ["Beta"]))
		model.answerCloudflare(.cancel)
		try await idle(model)
		#expect(revoker.calls.map(\.token) == ["cf_new_refresh"])
		#expect(try await record(connection.id).generation == old.generation)
	}

	@Test("a reconnect that would lose accounts goes ahead when the person agrees")
	func lostAccountsAccepted() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let new = Self.approved(accounts: [CloudflareLoginFixture.acme])
		let (model, _) = model { .success(new) }
		model.connectCloudflare()
		#expect(try await waitUntil { model.cloudflarePrompt != nil })
		model.answerCloudflare(.proceed)
		try await idle(model)
		#expect(try await record(connection.id).generation == new.generation)
	}

	@Test("reconnecting one login but approving another asks whether to add it beside it or put it in its place", arguments: [
		PlatformConnections.CloudflarePromptAnswer.addSeparately, .replace, .cancel,
	])
	func otherLogin(answer: PlatformConnections.CloudflarePromptAnswer) async throws {
		let old = CloudflareLoginFixture.account(label: "Work")
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let revoker = ScriptedRevoker()
		let new = Self.approved(subject: CloudflareLoginFixture.otherSubject)
		let (model, _) = model(revoker: revoker) { .success(new) }
		model.reconnectCloudflare(connection)
		#expect(try await waitUntil { model.cloudflarePrompt != nil })
		#expect(model.cloudflarePrompt == .otherLogin(reconnecting: "Work"))
		model.answerCloudflare(answer)
		try await idle(model)
		let stored = Set(keychain.platformConnectionStorage.keys)
		switch answer {
		case .addSeparately:
			#expect(stored == [connection.id, new.connectionID] && revoker.calls.isEmpty)
		case .replace:
			#expect(stored == [new.connectionID] && revoker.calls.map(\.token) == ["cf_refresh_1"])
		default:
			#expect(stored == [connection.id] && revoker.calls.map(\.token) == ["cf_new_refresh"])
		}
	}

	@Test("approving a login that already has its own connection while reconnecting another connects that one again, asking nothing")
	func otherLoginAlreadyConnected() async throws {
		let work = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		let home = CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject, label: "Home")
		let homeConnection = try await CloudflareLoginFixture.save(home, in: store, refresh: CloudflareLoginFixture.refresh(token: "cf_home_refresh"))
		let revoker = ScriptedRevoker()
		let new = Self.approved(subject: CloudflareLoginFixture.otherSubject)
		let (model, _) = model(revoker: revoker) { .success(new) }
		model.reconnectCloudflare(work)
		try await idle(model)
		#expect(revoker.calls.map(\.token) == ["cf_home_refresh"])
		#expect(try await record(homeConnection.id).generation == new.generation)
		#expect(try await record(work.id).label == "Work")
	}

	@Test("locking while a question waits revokes the new grant and changes nothing else")
	func lockDuringPrompt() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let revoker = ScriptedRevoker()
		let (model, _) = model(revoker: revoker) { .success(Self.approved(accounts: [CloudflareLoginFixture.acme])) }
		model.connectCloudflare()
		#expect(try await waitUntil { model.cloudflarePrompt != nil })
		model.reset()
		#expect(model.cloudflarePrompt == nil)
		#expect(try await waitUntil { revoker.calls.map(\.token) == ["cf_new_refresh"] })
		#expect(try await record(connection.id).generation == old.generation)
	}

	@Test("an old connection that can't be read is replaced, and a note says it may still be authorized, as it can't be revoked")
	func unreadableOldRecord() async throws {
		let new = Self.approved()
		keychain.platformConnectionStorage[new.connectionID] = Data("{".utf8)
		let (model, _) = model { .success(new) }
		model.connectCloudflare()
		try await idle(model)
		#expect(try await record(new.connectionID).generation == new.generation)
		#expect(model.markers.count == 1 && model.markers.first?.platform == .cloudflare)
	}

	@Test("disconnecting revokes the login's access through lpm.dev, forgets it, and says so")
	func disconnects() async throws {
		let connection = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		let revoker = ScriptedRevoker()
		let (model, _) = model(revoker: revoker) { .failure(.cancelled) }
		model.load()
		try await idle(model)
		model.disconnect(connection)
		#expect(try await waitUntil { model.disconnecting.isEmpty })
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1"])
		#expect(keychain.platformConnectionStorage.isEmpty && model.connections.isEmpty)
		#expect(model.notice == .init(message: "Disconnected Work. LPM Vault's access to it on Cloudflare has ended.", isError: false))
	}

	@Test("a disconnect lpm.dev can't confirm now goes on in the background, and the page says it's still revoking")
	func disconnectPending() async throws {
		let connection = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		let (model, _) = model(revoker: ScriptedRevoker { _, _ in .failure(.transport) }) { .failure(.cancelled) }
		model.load()
		try await idle(model)
		model.disconnect(connection)
		#expect(try await waitUntil { model.disconnecting.isEmpty && !model.retiring.isEmpty })
		#expect(model.connections.isEmpty)
		#expect(model.notice?.message == "Disconnected Work. LPM Vault goes on revoking its access on Cloudflare until lpm.dev confirms it.")
	}

	@Test("a note of a revocation that couldn't be confirmed shows until it's dismissed")
	func markers() async throws {
		let marker = PlatformCleanupMarker(platform: .cloudflare, generation: CloudflareConnectionAccount.makeGeneration(), createdAt: CloudflareLoginFixture.start)
		_ = await store.mark(marker)
		let (model, _) = model { .failure(.cancelled) }
		model.load()
		try await idle(model)
		#expect(model.markers == [marker])
		model.dismiss(marker)
		#expect(model.markers.isEmpty)
		#expect(try await waitUntil { keychain.platformCleanupStorage.isEmpty })
	}

	@Test("a login is renamed only to a name no other connected login has")
	func renames() async throws {
		let work = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject, label: "Home"), in: store)
		let (model, _) = model { .failure(.cancelled) }
		model.load()
		try await idle(model)
		#expect(await model.rename(work, to: "home") == "Another connected Cloudflare login is called home. Choose another name.")
		#expect(await model.rename(work, to: "  ") == "Use a name of up to 64 characters.")
		#expect(await model.rename(work, to: "Clients") == nil)
		#expect(model.connections.map(\.name).sorted() == ["Clients", "Home"])
	}

	@Test("the logins that go on publishing to a disconnected login's accounts are named by account")
	func otherLogins() async throws {
		let work = try await CloudflareLoginFixture.save(
			CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta]), in: store)
		try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject, label: "Home"), in: store)
		let (model, _) = model { .failure(.cancelled) }
		model.load()
		try await idle(model)
		let others = model.otherLogins(reaching: work)
		#expect(others.map(\.account) == ["Acme"] && others.map(\.logins) == [["Home"]])
		#expect(PlatformsView.cloudflareDisconnectMessage(work, others: others).hasSuffix("Destinations in Acme go on publishing through Home."))
	}
}
