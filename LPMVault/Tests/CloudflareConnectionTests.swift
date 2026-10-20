import CryptoKit
import Foundation
import Testing
@testable import LPMVault

struct CloudflareLoginTests {
	@Test("a login is known by a domain-separated digest of its sub, which shows nothing of the sub and is the same every time")
	func loginKey() {
		let key = CloudflareLogin.key(subject: CloudflareLoginFixture.subject)
		#expect(CloudflareLogin.isValidKey(key))
		#expect(key == CloudflareLogin.key(subject: CloudflareLoginFixture.subject))
		#expect(key != CloudflareLogin.key(subject: CloudflareLoginFixture.otherSubject))
		let plain = SHA256.hash(data: Data(CloudflareLoginFixture.subject.utf8)).map { String(format: "%02x", $0) }.joined()
		#expect(key != plain, "A bare SHA-256 of the sub could be matched across apps")
		#expect(!key.contains("0f1e2d3c"))
	}

	@Test("a sub is 1 to 255 printable ASCII characters", arguments: ["", String(repeating: "a", count: 256), "a\u{7}", "é"])
	func refusesSubjects(subject: String) {
		#expect(!CloudflareLogin.isValidSubject(subject))
	}

	@Test("a label's code is a digest under this install's salt, in an alphabet without lookalikes, that differs between installs")
	func labelCode() {
		let login = CloudflareLogin.key(subject: CloudflareLoginFixture.subject)
		let salt = Data(repeating: 7, count: 32)
		let code = CloudflareLogin.code(for: login, salt: salt)
		#expect(code.count == CloudflareLogin.codeLength)
		#expect(code == CloudflareLogin.code(for: login, salt: salt))
		#expect(code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
		#expect(CloudflareLogin.code(for: login, salt: Data(repeating: 8, count: 32)) != code)
		#expect(CloudflareLogin.code(for: login, salt: salt, length: 6).hasPrefix(code))
	}

	@Test("a default label is the first account's name and a code that grows until no connected login's label reads like it")
	func defaultLabel() {
		let login = CloudflareLogin.key(subject: CloudflareLoginFixture.subject)
		let salt = Data(repeating: 1, count: 32)
		let four = CloudflareLogin.code(for: login, salt: salt)
		let label = CloudflareLogin.defaultLabel(for: login, accounts: [CloudflareLoginFixture.acme], salt: salt, taken: [])
		#expect(label == "Acme · \(four)")
		let grown = CloudflareLogin.defaultLabel(for: login, accounts: [CloudflareLoginFixture.acme], salt: salt, taken: ["acme  ·  \(four.lowercased())"])
		#expect(grown == "Acme · \(CloudflareLogin.code(for: login, salt: salt, length: 5))")
	}

	@Test("a default label made from a long account name is shortened to fit a label, and the login saves with it")
	func longAccountName() async throws {
		let login = CloudflareLogin.key(subject: CloudflareLoginFixture.subject)
		let salt = Data(repeating: 1, count: 32)
		let code = CloudflareLogin.code(for: login, salt: salt)
		for name in [String(repeating: "a", count: 512), String(repeating: "\u{00E9}", count: 256), "Acme"] {
			let account = CloudflareAccount(id: CloudflareLoginFixture.acme.id, name: name)
			let label = CloudflareLogin.defaultLabel(for: login, accounts: [account], salt: salt, taken: [])
			#expect(label.count <= CloudflareLogin.maximumLabelCharacters && label.hasSuffix(" · \(code)"))
			#expect(CloudflareLogin.label(from: label) == .success(label))
			let store = PlatformConnectionStore(service: MockKeychainService())
			_ = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: label, accounts: [account]), in: store)
		}
		let long = CloudflareLogin.defaultLabel(
			for: login, accounts: [CloudflareAccount(id: CloudflareLoginFixture.acme.id, name: String(repeating: "a", count: 512))], salt: salt, taken: [])
		#expect(long == String(repeating: "a", count: CloudflareLogin.maximumLabelCharacters - 4 - code.count) + "… · \(code)")
	}

	@Test("a name a person gives a login is trimmed and bounded, and holds nothing invisible, so no two names look alike that differ")
	func givenLabels() {
		#expect(CloudflareLogin.label(from: "  Work  ") == .success("Work"))
		#expect(CloudflareLogin.label(from: "   ") == .failure(.empty))
		#expect(CloudflareLogin.label(from: String(repeating: "a", count: 65)) == .failure(.tooLong))
		#expect(CloudflareLogin.label(from: "e" + String(repeating: "\u{0301}", count: 300)) == .failure(.tooLong), "One character, too many bytes to store")
		for invisible in ["a\u{0}b", "Work\u{202E}", "W\u{200B}ork", "Wo\u{00AD}rk", "Wo\u{2060}rk", "Work\u{FE0F}", "\u{3164}Work"] {
			#expect(CloudflareLogin.label(from: invisible) == .failure(.invisible), "\(invisible.unicodeScalars.map { String($0.value, radix: 16) })")
		}
		#expect(CloudflareLogin.label(from: "Team \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}") == .success("Team \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"))
		#expect(CloudflareLogin.label(from: "Ops \u{2764}\u{FE0F}") == .success("Ops \u{2764}\u{FE0F}"))
		#expect(CloudflareLogin.comparable("Work") == CloudflareLogin.comparable("\u{FF37}\u{FF4F}\u{FF52}\u{FF4B}"))
		#expect(CloudflareLogin.comparable("Work") == CloudflareLogin.comparable("W\u{00F6}rk"))
		#expect(CloudflareLogin.comparable("My Work") == CloudflareLogin.comparable("my\u{00A0}work"))
	}
}

struct CloudflareOAuthTests {
	@Test("lpm.dev runs only the production client, no other Registry runs it, and the local one is offered in debug builds")
	func clients() {
		#expect(CloudflareOAuth.accepts("prod-client", for: .production, productionClientID: "prod-client"))
		#expect(!CloudflareOAuth.accepts("other-client", for: .production, productionClientID: "prod-client"))
		#expect(!CloudflareOAuth.accepts("prod-client", for: .development, productionClientID: "prod-client"))
		#expect(CloudflareOAuth.accepts("dev-client", for: .development, productionClientID: "prod-client"))
		#expect(!CloudflareOAuth.accepts("dev client", for: .development, productionClientID: "prod-client"))
	}

	@Test("the production client is the one the Registry checks in, so Cloudflare connects through lpm.dev with it alone")
	func productionClient() {
		let registryClientID = "3ffa60cf0c6483c948115e7d2a93cbaa"
		#expect(CloudflareOAuth.productionClientID == registryClientID)
		#expect(CloudflareOAuth.accepts(registryClientID, for: .production))
		#expect(!CloudflareOAuth.accepts(registryClientID, for: .development))
		#expect(!CloudflareOAuth.accepts("0123456789abcdefghijklmnopqrstuv", for: .production))
	}
}

struct CloudflareConnectionStoreTests {
	private let keychain = MockKeychainService()
	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }

	@Test("a Cloudflare login is saved under its Registry and key, with its label, accounts, client and generation, and reads back exactly")
	func roundTrips() async throws {
		let account = CloudflareLoginFixture.account(accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.beta])
		let saved = try await CloudflareLoginFixture.save(account, in: store)
		#expect(saved.id == "cloudflare.development.\(account.login)")
		#expect(saved.name == "Acme · K7Q2" && saved.detail == "Acme and Beta" && saved.platform == .cloudflare)
		let record = try await store.record(for: saved.id).get()
		#expect(record.connection.account == .cloudflare(account))
		#expect(record.accessToken == "cf_access_1" && record.refresh == CloudflareLoginFixture.refresh())
		let data = try #require(keychain.platformConnectionStorage[saved.id])
		#expect(!String(decoding: data, as: UTF8.self).contains(CloudflareLoginFixture.subject), "The sub itself is never kept")
	}

	@Test("the same login through another Registry is another connection")
	func perIssuer() async throws {
		let local = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(issuer: .development), in: store)
		let live = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(issuer: .production), in: store)
		#expect(local.id != live.id)
		#expect(try await store.connections().get().count == 2)
	}

	@Test("a Cloudflare connection without a refresh state, or with a bad field, isn't stored")
	func refusesUnstorable() {
		let connection = PlatformConnection(account: .cloudflare(CloudflareLoginFixture.account()), connectedAt: CloudflareLoginFixture.start)
		#expect(PlatformConnectionStore.encode(.init(connection: connection, accessToken: "cf_access")) == nil)
		let refresh = CloudflareLoginFixture.refresh()
		for account in [
			CloudflareLoginFixture.account(accounts: []),
			CloudflareLoginFixture.account(accounts: [CloudflareLoginFixture.acme, CloudflareLoginFixture.acme]),
			CloudflareLoginFixture.account(accounts: [CloudflareAccount(id: "ACME", name: "Acme")]),
			CloudflareLoginFixture.account(label: " Acme"),
			CloudflareLoginFixture.account(clientID: "a client"),
			CloudflareLoginFixture.account(generation: "not-a-uuid"),
		] {
			let bad = PlatformConnection(account: .cloudflare(account), connectedAt: CloudflareLoginFixture.start)
			#expect(PlatformConnectionStore.encode(.init(connection: bad, accessToken: "cf_access", refresh: refresh)) == nil)
		}
	}

	@Test("a record from a Registry this version doesn't know is a newer version's; one with an unknown field isn't read")
	func refusesForeignRecords() async throws {
		let saved = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(), in: store)
		let data = try #require(keychain.platformConnectionStorage[saved.id])
		func altered(_ change: (inout [String: Any]) -> Void) throws -> Data {
			var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
			change(&object)
			return try JSONSerialization.data(withJSONObject: object)
		}
		#expect(PlatformConnectionStore.decode(try altered { $0["issuer"] = "staging" }, account: saved.id) == .failure(.newerVersion))
		#expect(PlatformConnectionStore.decode(try altered { $0["sub"] = CloudflareLoginFixture.subject }, account: saved.id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["refresh"] = nil }, account: saved.id) == .failure(.unreadable))
		#expect(PlatformConnectionStore.decode(try altered { $0["accounts"] = [["id": CloudflareLoginFixture.acme.id]] }, account: saved.id) == .failure(.unreadable))
	}

	@Test("an account's name stored with a direction control reads back escaped")
	func escapesAccountNames() async throws {
		let saved = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(), in: store)
		var object = try #require(try JSONSerialization.jsonObject(with: keychain.platformConnectionStorage[saved.id]!) as? [String: Any])
		object["accounts"] = [["id": CloudflareLoginFixture.acme.id, "name": "Acme\u{202E}"]]
		keychain.platformConnectionStorage[saved.id] = try JSONSerialization.data(withJSONObject: object)
		guard case .cloudflare(let account) = try await store.record(for: saved.id).get().connection.account else {
			Issue.record("Not a Cloudflare record")
			return
		}
		#expect(account.accounts.map(\.name) == ["Acme\\u{202e}"])
	}

	@Test("a label is unique among connected logins, and a retired login's label is free again")
	func relabels() async throws {
		let first = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		let second = try await CloudflareLoginFixture.save(
			CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject, label: "Home"), in: store)
		#expect(await store.relabel(second.id, to: "work") == .failure(.labelTaken))
		#expect(try await store.relabel(second.id, to: "Side").get().name == "Side")
		guard case .cloudflare(let account) = first.account else { return }
		_ = try await store.retire(first.id, generation: account.generation, at: CloudflareLoginFixture.start).get()
		#expect(try await store.relabel(second.id, to: "Work").get().name == "Work")
	}

	@Test("saving a login whose label another login took meanwhile, as by a rename during a reconnect, gives it a default label instead")
	func saveKeepsLabelsUnique() async throws {
		let work = CloudflareLoginFixture.account(label: "Work")
		let first = try await CloudflareLoginFixture.save(work, in: store)
		_ = try await store.retire(first.id, generation: work.generation, at: CloudflareLoginFixture.start).get()
		let second = try await CloudflareLoginFixture.save(
			CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject, label: "Home"), in: store)
		#expect(try await store.relabel(second.id, to: "Work").get().name == "Work")
		let again = try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(label: "Work"), in: store)
		#expect(again.name.hasPrefix("Acme · "))
		#expect(Set(try await store.connections().get().map(\.name)) == ["Work", again.name])
	}

	@Test("the label salt is made once and kept")
	func salt() async throws {
		let salt = try await store.loginLabelSalt().get()
		#expect(salt.count == 32)
		#expect(try await store.loginLabelSalt().get() == salt)
		keychain.platformCleanupStorage[PlatformCleanupRecords.labelSaltAccount] = Data([1])
		#expect(try await store.loginLabelSalt().get().count == 32)
	}
}

struct PlatformCleanupStoreTests {
	private let keychain = MockKeychainService()
	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }

	private func saved(attempt: PlatformTokenRefresh.Attempt? = nil) async throws -> (PlatformConnection, CloudflareConnectionAccount) {
		let account = CloudflareLoginFixture.account()
		let connection = try await CloudflareLoginFixture.save(account, in: store, refresh: CloudflareLoginFixture.refresh(attempt: attempt))
		return (connection, account)
	}

	@Test("retiring writes the generation's cleanup entry from its refresh token and any renewal that may have been sent, once")
	func retires() async throws {
		let attempt = PlatformTokenRefresh.Attempt.make(at: CloudflareLoginFixture.start)
		let (connection, account) = try await saved(attempt: attempt)
		let entry = try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get().entry)
		#expect(entry.refreshToken == "cf_refresh_1" && entry.attempt == attempt)
		#expect(entry.issuer == .development && entry.clientID == CloudflareLoginFixture.clientID && entry.connectionID == connection.id)
		#expect(PlatformAuthorizationClient.isCanonicalUUID(entry.revocationID))
		#expect(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get() == .entry(entry))
		#expect(try await store.retire(connection.id, generation: CloudflareConnectionAccount.makeGeneration(), at: CloudflareLoginFixture.start).get() == .gone)
	}

	@Test("a retired generation is never listed, read or renewed, even when its entry can't be read, and the listing says it's being revoked")
	func entriesAreAuthoritative() async throws {
		let (connection, account) = try await saved()
		_ = try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get()
		let listing = try await store.listing(at: CloudflareLoginFixture.start).get()
		#expect(listing.connections.isEmpty && listing.retiring == [account.generation])
		#expect(await store.record(for: connection.id) == .failure(.retired))
		let attempt = PlatformTokenRefresh.Attempt.make(at: CloudflareLoginFixture.start)
		#expect(await store.beginRefresh(of: connection.id, token: "cf_refresh_1", attempt: attempt) == .failure(.retired))
		keychain.platformCleanupStorage[PlatformCleanupRecords.entryAccount(account.generation)] = Data("{".utf8)
		#expect(await store.record(for: connection.id) == .failure(.retired))
		#expect(try await store.listing(at: CloudflareLoginFixture.start).get().connections.isEmpty)
	}

	@Test("finishing a cleanup deletes the record only while it holds the entry's generation, never a newer one, then the entry")
	func finishesWithoutTouchingNewerGenerations() async throws {
		let (connection, account) = try await saved()
		let entry = try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get().entry)
		let newer = CloudflareLoginFixture.account(generation: CloudflareConnectionAccount.makeGeneration())
		try await CloudflareLoginFixture.save(newer, in: store, access: "cf_access_new")
		try await store.finishCleanup(entry, unconfirmed: false, at: CloudflareLoginFixture.start).get()
		#expect(try await store.record(for: connection.id).get().accessToken == "cf_access_new")
		#expect(keychain.platformCleanupStorage.isEmpty)

		let current = try #require(try await store.retire(connection.id, generation: newer.generation, at: CloudflareLoginFixture.start).get().entry)
		try await store.finishCleanup(current, unconfirmed: false, at: CloudflareLoginFixture.start).get()
		#expect(keychain.platformConnectionStorage.isEmpty)
	}

	@Test("taking back a save never brings back a generation that was retired, even once its cleanup finished")
	func undoNeverRestoresRetired() async throws {
		let (connection, account) = try await saved()
		let entry = try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get().entry)
		let newer = CloudflareLoginFixture.account()
		let replacement = try await store.saveUndoably(
			.cloudflare(newer), accessToken: "cf_access_new", refresh: CloudflareLoginFixture.refresh(token: "cf_refresh_new"),
			at: CloudflareLoginFixture.start).get()
		try await store.finishCleanup(entry, unconfirmed: false, at: CloudflareLoginFixture.start).get()
		try await store.undo(replacement).get()
		#expect(await store.record(for: connection.id) == .failure(.notFound))
		#expect(try await store.connections().get().isEmpty)
	}

	@Test("an unconfirmed cleanup leaves a marker that holds nothing that names or reaches the connection, until it's dismissed")
	func marksUnconfirmed() async throws {
		let (connection, account) = try await saved()
		let entry = try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get().entry)
		try await store.finishCleanup(entry, unconfirmed: true, at: CloudflareLoginFixture.start).get()
		let markers = try await store.listing(at: CloudflareLoginFixture.start).get().markers
		#expect(markers == [PlatformCleanupMarker(platform: .cloudflare, generation: account.generation, createdAt: CloudflareLoginFixture.start)])
		let data = try #require(keychain.platformCleanupStorage[PlatformCleanupRecords.markerAccount(account.generation)])
		let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(Set(object.keys) == ["version", "kind", "platform", "generation", "createdAt"])
		#expect(keychain.platformConnectionStorage.isEmpty)
		try await store.dismissMarker(account.generation).get()
		#expect(try await store.listing(at: CloudflareLoginFixture.start).get().markers.isEmpty)
	}

	@Test("a renewal's successor takes its token's place in the entry, and the renewal's key is dropped")
	func replacesToken() async throws {
		let attempt = PlatformTokenRefresh.Attempt.make(at: CloudflareLoginFixture.start)
		let (connection, account) = try await saved(attempt: attempt)
		_ = try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get()
		#expect(try await store.replaceCleanupToken(of: account.generation, renewedBy: "00000000-0000-4000-8000-000000000000", with: "x").get() == false)
		#expect(try await store.replaceCleanupToken(of: account.generation, renewedBy: attempt.id, with: "cf_refresh_2").get())
		guard case .readable(let entry)? = try await store.cleanupEntry(of: account.generation).get() else {
			Issue.record("The entry isn't readable")
			return
		}
		#expect(entry.refreshToken == "cf_refresh_2" && entry.attempt == nil)
		let data = try #require(keychain.platformCleanupStorage[PlatformCleanupRecords.entryAccount(account.generation)])
		#expect(!String(decoding: data, as: UTF8.self).contains(attempt.key.base64EncodedString()))
	}

	@Test("entries and markers are read strictly: unknown fields, another generation's account or a newer version aren't taken as this version's")
	func strictRecords() throws {
		let entry = PlatformCleanupEntry(
			platform: .cloudflare, connectionID: "cloudflare.development.x", generation: CloudflareConnectionAccount.makeGeneration(),
			issuer: .development, clientID: "c", refreshToken: "cf_refresh", attempt: nil, createdAt: CloudflareLoginFixture.start)
		let data = try #require(PlatformCleanupRecords.encode(entry))
		#expect(PlatformCleanupRecords.decodeEntry(data, generation: entry.generation) == .success(entry))
		#expect(PlatformCleanupRecords.decodeEntry(data, generation: CloudflareConnectionAccount.makeGeneration()) == .failure(.unreadable))
		var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		object["label"] = "Acme"
		#expect(PlatformCleanupRecords.decodeEntry(try JSONSerialization.data(withJSONObject: object), generation: entry.generation) == .failure(.unreadable))
		object["label"] = nil
		object["version"] = 2
		#expect(PlatformCleanupRecords.decodeEntry(try JSONSerialization.data(withJSONObject: object), generation: entry.generation) == .failure(.newerVersion))
		object["version"] = 1
		object["issuer"] = "staging"
		#expect(PlatformCleanupRecords.decodeEntry(try JSONSerialization.data(withJSONObject: object), generation: entry.generation) == .failure(.newerVersion))
		#expect(!"\(entry)".contains("cf_refresh") && !String(reflecting: entry).contains("cf_refresh"))
	}

	@Test("a Boolean is never read as a record's version or time, in a cleanup record or a connection's")
	func booleansAreNotNumbers() async throws {
		let entry = PlatformCleanupEntry(
			platform: .cloudflare, connectionID: "cloudflare.development.x", generation: CloudflareConnectionAccount.makeGeneration(),
			issuer: .development, clientID: "c", refreshToken: "cf_refresh", attempt: nil, createdAt: CloudflareLoginFixture.start)
		let marker = PlatformCleanupMarker(platform: .cloudflare, generation: entry.generation, createdAt: CloudflareLoginFixture.start)
		let entryData = try #require(PlatformCleanupRecords.encode(entry))
		let markerData = try #require(PlatformCleanupRecords.encode(marker))
		for field in ["version", "createdAt"] {
			var object = try #require(try JSONSerialization.jsonObject(with: entryData) as? [String: Any])
			object[field] = true
			#expect(PlatformCleanupRecords.decodeEntry(try JSONSerialization.data(withJSONObject: object), generation: entry.generation) == .failure(.unreadable), "\(field)")
			var markerObject = try #require(try JSONSerialization.jsonObject(with: markerData) as? [String: Any])
			markerObject[field] = true
			#expect(PlatformCleanupRecords.decodeMarker(try JSONSerialization.data(withJSONObject: markerObject), generation: marker.generation) == .failure(.unreadable), "\(field)")
		}
		let (connection, _) = try await saved()
		for field in ["version", "connectedAt"] {
			let data = try #require(keychain.platformConnectionStorage[connection.id])
			var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
			object[field] = true
			let changed = try JSONSerialization.data(withJSONObject: object)
			if case .success = PlatformConnectionStore.decode(changed, account: connection.id) { Issue.record("\(field) read from a Boolean") }
		}
	}
}
