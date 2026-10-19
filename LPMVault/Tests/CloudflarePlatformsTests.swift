import Foundation
import os
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
		let label = try? await record(new.connectionID).label
		switch answer {
		case .addSeparately:
			#expect(stored == [connection.id, new.connectionID] && revoker.calls.isEmpty)
			#expect(model.notice?.message == "Connected \(label ?? "") on Cloudflare, beside Work, which still needs reconnecting.")
		case .replace:
			#expect(stored == [new.connectionID] && revoker.calls.map(\.token) == ["cf_refresh_1"])
			#expect(model.notice?.message == "Connected \(label ?? "") on Cloudflare in Work's place.")
		default:
			#expect(stored == [connection.id] && revoker.calls.map(\.token) == ["cf_new_refresh"])
		}
	}

	@Test("putting another login in the place of one that reached more accounts asks about those accounts too, then replaces it")
	func replaceThenLosesAccounts() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let revoker = ScriptedRevoker()
		let new = Self.approved(subject: CloudflareLoginFixture.otherSubject, accounts: [CloudflareLoginFixture.acme])
		let (model, _) = model(revoker: revoker) { .success(new) }
		model.reconnectCloudflare(connection)
		#expect(try await waitUntil { model.cloudflarePrompt == .otherLogin(reconnecting: "Work") })
		model.answerCloudflare(.replace)
		#expect(try await waitUntil { model.cloudflarePrompt == .losesAccounts(label: "Work", accounts: ["Beta"]) })
		model.answerCloudflare(.proceed)
		try await idle(model)
		#expect(Set(keychain.platformConnectionStorage.keys) == [new.connectionID])
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1"])
	}

	@Test("an answer meant for one question never answers the next")
	func staleAnswers() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let new = Self.approved(subject: CloudflareLoginFixture.otherSubject, accounts: [CloudflareLoginFixture.acme])
		let (model, _) = model { .success(new) }
		model.reconnectCloudflare(connection)
		#expect(try await waitUntil { model.cloudflarePrompt != nil })
		let first = model.cloudflarePromptNumber
		model.answerCloudflare(.replace, to: first)
		#expect(try await waitUntil { model.cloudflarePrompt == .losesAccounts(label: "Work", accounts: ["Beta"]) })
		model.answerCloudflare(.cancel, to: first)
		#expect(model.cloudflarePrompt != nil)
		model.answerCloudflare(.cancel)
		try await idle(model)
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
		#expect(model.notice?.message == "Connected Home on Cloudflare again. You approved Home, not Work, which still needs reconnecting.")
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

	@Test("a login whose stored connection a newer LPM Vault saved, or that can't be read now, is left alone, and only the new grant is revoked")
	func storedConnectionProblems() async throws {
		for problem in ["newer", "unreadable"] {
			let new = Self.approved()
			keychain.platformConnectionStorage = [:]
			keychain.failAppItemReads = []
			let revoker = ScriptedRevoker()
			if problem == "newer" {
				keychain.platformConnectionStorage[new.connectionID] = Data(#"{"version":9}"#.utf8)
			} else {
				try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
				keychain.failAppItemReads = [new.connectionID]
			}
			let (model, _) = model(revoker: revoker) { .success(new) }
			model.connectCloudflare()
			try await idle(model)
			#expect(revoker.calls.map(\.token) == ["cf_new_refresh"], "\(problem)")
			#expect(model.notice?.isError == true, "\(problem)")
			// A read that fails here fails the page's listing after it too, which says so in its stead.
			let expected = problem == "newer" ? "A newer LPM Vault saved this Cloudflare login's connection" : "couldn't be read"
			#expect(model.notice?.message.contains(expected) == true, "\(problem): \(model.notice?.message ?? "")")
		}
		keychain.failAppItemReads = []
	}

	@Test("Cloudflare's failures to connect say what happened and what to do")
	func connectFailures() {
		#expect(PlatformConnectFailure(code: "insufficient_scope").message(for: .cloudflare)
			== "Cloudflare didn't grant all the access LPM Vault needs. Connect again, and approve every permission it asks for.")
		#expect(PlatformConnectFailure(code: "exchange_uncertain").message(for: .cloudflare)
			== "Cloudflare's answer didn't come back, so the connection couldn't be finished. Connect again.")
		#expect(PlatformsView.retiringMessage(count: 2)
			== "LPM Vault is still revoking the access of 2 Cloudflare logins it no longer uses. It finishes once lpm.dev confirms it.")
	}

	@Test("a reconnect whose old generation can't be retired keeps it, saves nothing, and revokes only the new grant")
	func reconnectStopsWhenRetirementFails() async throws {
		let old = CloudflareLoginFixture.account(label: "Work")
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		keychain.failAppItemWrites = [PlatformCleanupRecords.entryAccount(old.generation)]
		let revoker = ScriptedRevoker()
		let (model, _) = model(revoker: revoker) { .success(Self.approved()) }
		model.connectCloudflare()
		try await idle(model)
		#expect(try await record(connection.id).generation == old.generation)
		#expect(revoker.calls.map(\.token) == ["cf_new_refresh"])
		#expect(model.notice?.isError == true)
	}

	@Test("cancelling while the stored connections are read asks nothing, and revokes the new grant")
	func cancelDuringRead() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let connection = try await CloudflareLoginFixture.save(old, in: store)
		let revoker = ScriptedRevoker()
		let (model, _) = model(revoker: revoker) { .success(Self.approved(accounts: [CloudflareLoginFixture.acme])) }
		let entered = DispatchSemaphore(value: 0)
		let held = DispatchSemaphore(value: 0)
		let once = OSAllocatedUnfairLock(initialState: false)
		keychain.beforeAppItemRead = { store, account in
			guard store == .platformConnections, account == connection.id, once.withLock({ seen in defer { seen = true }; return !seen }) else { return }
			entered.signal()
			_ = held.wait(timeout: .now() + testWaitSeconds)
		}
		model.connectCloudflare()
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + testWaitSeconds)
				continuation.resume()
			}
		}
		model.cancelConnecting()
		held.signal()
		#expect(try await waitUntil { revoker.calls.map(\.token) == ["cf_new_refresh"] || model.cloudflarePrompt != nil })
		#expect(model.cloudflarePrompt == nil)
		#expect(try await record(connection.id).generation == old.generation)
		keychain.beforeAppItemRead = nil
	}

	@Test("a grant dropped because connecting was cancelled is revoked at once, not left to the background")
	func cancelRevokesAtOnce() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		try await CloudflareLoginFixture.save(old, in: store)
		// As the HTTP client does, a cancelled task sends nothing.
		let revoker = ScriptedRevoker { _, _ in Task.isCancelled ? .failure(.cancelled) : .success(.accepted) }
		let (model, _) = model(revoker: revoker) { .success(Self.approved(accounts: [CloudflareLoginFixture.acme])) }
		model.connectCloudflare()
		#expect(try await waitUntil { model.cloudflarePrompt != nil })
		model.cancelConnecting()
		try await idle(model)
		#expect(revoker.calls.map(\.token) == ["cf_new_refresh"])
		#expect(!keychain.platformCleanupStorage.keys.contains { $0.hasPrefix(PlatformCleanupRecords.entryPrefix) })
	}

	@Test("a grant that couldn't be saved, whose revocation lpm.dev couldn't confirm, says why it failed, and the note says once what to do")
	func unsavedGrantUnconfirmed() async throws {
		let new = Self.approved()
		keychain.failAppItemWrites = [new.connectionID]
		let (model, _) = model(revoker: ScriptedRevoker { _, _ in .success(.unconfirmed) }) { .success(new) }
		model.connectCloudflare()
		try await idle(model)
		#expect(model.notice?.message.hasPrefix("Cloudflare connected, but the connection couldn't be saved.") == true)
		#expect(model.notice?.message != PlatformConnections.unrevokedMessage(count: 1) && model.markers.count == 1)
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

	@Test("disconnecting a login whose tokens Cloudflare already ended revokes nothing, and says so")
	func disconnectsEndedLogin() async throws {
		var refresh = CloudflareLoginFixture.refresh()
		refresh.isRejected = true
		let connection = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store, refresh: refresh)
		let revoker = ScriptedRevoker()
		let (model, _) = model(revoker: revoker) { .failure(.cancelled) }
		model.load()
		try await idle(model)
		model.disconnect(connection)
		#expect(try await waitUntil { model.disconnecting.isEmpty })
		#expect(revoker.calls.isEmpty && keychain.platformConnectionStorage.isEmpty && model.connections.isEmpty)
		#expect(model.notice == .init(message: "Disconnected Work. Cloudflare had already ended LPM Vault's access to it.", isError: false))
	}

	@Test("a disconnect while signed out says a sign-in finishes revoking it, rather than that it goes on")
	func disconnectSignedOut() async throws {
		let connection = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		let revoker = ScriptedRevoker()
		let (model, _) = model(revoker: revoker, session: nil) { .failure(.cancelled) }
		model.load()
		try await idle(model)
		model.disconnect(connection)
		#expect(try await waitUntil { model.disconnecting.isEmpty && !model.isLoading && !model.retiring.isEmpty })
		#expect(model.notice == .init(message: "Disconnected Work. Sign in to LPM to finish revoking its access on Cloudflare.", isError: false))
		#expect(model.retiringAwaitsSignIn && revoker.calls.isEmpty)
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
		model.dismissMarkers()
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
		#expect(await model.rename(work, to: "  ") == "Enter a name of 1 to 64 characters.")
		#expect(await model.rename(work, to: "H\u{200B}ome") == "Use a name without invisible characters.")
		#expect(await model.rename(work, to: "\u{FF28}ome") == "Another connected Cloudflare login is called \u{FF28}ome. Choose another name.")
		#expect(await model.rename(work, to: "Clients") == nil)
		#expect(model.connections.map(\.name).sorted() == ["Clients", "Home"])
	}

	@Test("the logins that go on publishing to a disconnected login's accounts are named by account, never one that no longer works")
	func otherLogins() async throws {
		let work = try await CloudflareLoginFixture.save(
			CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta]), in: store)
		try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject, label: "Home"), in: store)
		var rejected = CloudflareLoginFixture.refresh()
		rejected.isRejected = true
		try await CloudflareLoginFixture.save(
			CloudflareLoginFixture.account(subject: "a-third-login", label: "Old", accounts: [CloudflareLoginFixture.beta]), in: store, refresh: rejected)
		let (model, _) = model { .failure(.cancelled) }
		model.load()
		try await idle(model)
		let others = model.otherLogins(reaching: work)
		#expect(others.map(\.account) == ["Acme"] && others.map(\.logins) == [["Home"]])
		#expect(PlatformsView.cloudflareDisconnectMessage(work, others: others).hasSuffix("Destinations in Acme go on publishing through Home."))
	}

	@Test("a disconnect whose revocation lpm.dev couldn't confirm says so, rather than that access ended")
	func disconnectUnconfirmed() async throws {
		let connection = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		let (model, _) = model(revoker: ScriptedRevoker { _, _ in .success(.unconfirmed) }) { .failure(.cancelled) }
		model.load()
		try await idle(model)
		model.disconnect(connection)
		#expect(try await waitUntil { model.disconnecting.isEmpty && !model.isLoading })
		#expect(model.notice == .init(
			message: "Disconnected Work, but lpm.dev couldn't confirm that LPM Vault's access to it on Cloudflare ended.", isError: true))
		#expect(model.markers.count == 1)
	}

	@Test("a declined grant whose revocation, entry and note all fail to save still shows the note until it's dismissed")
	func unsavedNote() async throws {
		let old = CloudflareLoginFixture.account(label: "Work", accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		try await CloudflareLoginFixture.save(old, in: store)
		let new = Self.approved(accounts: [CloudflareLoginFixture.acme])
		keychain.failAppItemWrites = [
			PlatformCleanupRecords.entryAccount(new.generation), PlatformCleanupRecords.markerAccount(new.generation),
		]
		let (model, _) = model(revoker: ScriptedRevoker { _, _ in .failure(.transport) }) { .success(new) }
		model.connectCloudflare()
		#expect(try await waitUntil { model.cloudflarePrompt != nil })
		model.answerCloudflare(.cancel)
		try await idle(model)
		#expect(model.markers.map(\.generation) == [new.generation])
		model.dismissMarkers()
		model.load()
		try await idle(model)
		#expect(model.markers.isEmpty)
	}
}
