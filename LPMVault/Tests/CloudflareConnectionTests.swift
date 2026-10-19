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

	@Test("a name a person gives a login is trimmed, bounded and free of controls, with direction controls escaped")
	func givenLabels() {
		#expect(CloudflareLogin.label(from: "  Work  ") == "Work")
		#expect(CloudflareLogin.label(from: "   ") == nil)
		#expect(CloudflareLogin.label(from: String(repeating: "a", count: 65)) == nil)
		#expect(CloudflareLogin.label(from: "a\u{0}b") == nil)
		#expect(CloudflareLogin.label(from: "Work\u{202E}") == "Work\\u{202e}")
	}
}

struct CloudflareOAuthTests {
	@Test("lpm.dev runs only the production client, no other Registry runs it, and the local one is offered in debug builds")
	func clients() {
		#expect(!CloudflareOAuth.accepts("prod-client", for: .production, productionClientID: nil))
		#expect(CloudflareOAuth.accepts("prod-client", for: .production, productionClientID: "prod-client"))
		#expect(!CloudflareOAuth.accepts("other-client", for: .production, productionClientID: "prod-client"))
		#expect(!CloudflareOAuth.accepts("prod-client", for: .development, productionClientID: "prod-client"))
		#expect(CloudflareOAuth.accepts("dev-client", for: .development, productionClientID: "prod-client"))
		#expect(!CloudflareOAuth.accepts("dev client", for: .development, productionClientID: nil))
		#expect(!CloudflareOAuth.isAvailable(through: .production, productionClientID: nil))
		#expect(CloudflareOAuth.isAvailable(through: .production, productionClientID: "prod-client"))
		#expect(CloudflareOAuth.isAvailable(through: .development, productionClientID: nil))
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
		let entry = try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get())
		#expect(entry.refreshToken == "cf_refresh_1" && entry.attempt == attempt)
		#expect(entry.issuer == .development && entry.clientID == CloudflareLoginFixture.clientID && entry.connectionID == connection.id)
		#expect(PlatformAuthorizationClient.isCanonicalUUID(entry.revocationID))
		#expect(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get() == entry)
		#expect(try await store.retire(connection.id, generation: CloudflareConnectionAccount.makeGeneration(), at: CloudflareLoginFixture.start).get() == nil)
	}

	@Test("a retired generation is never listed, read or renewed, even when its entry can't be read, and the listing says it's being revoked")
	func entriesAreAuthoritative() async throws {
		let (connection, account) = try await saved()
		_ = try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get()
		let listing = try await store.listing(at: CloudflareLoginFixture.start).get()
		#expect(listing.connections.isEmpty && listing.retiring.map(\.generation) == [account.generation])
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
		let entry = try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get())
		let newer = CloudflareLoginFixture.account(generation: CloudflareConnectionAccount.makeGeneration())
		try await CloudflareLoginFixture.save(newer, in: store, access: "cf_access_new")
		try await store.finishCleanup(entry, unconfirmed: false, at: CloudflareLoginFixture.start).get()
		#expect(try await store.record(for: connection.id).get().accessToken == "cf_access_new")
		#expect(keychain.platformCleanupStorage.isEmpty)

		let current = try #require(try await store.retire(connection.id, generation: newer.generation, at: CloudflareLoginFixture.start).get())
		try await store.finishCleanup(current, unconfirmed: false, at: CloudflareLoginFixture.start).get()
		#expect(keychain.platformConnectionStorage.isEmpty)
	}

	@Test("an unconfirmed cleanup leaves a marker that holds nothing that names or reaches the connection, until it's dismissed")
	func marksUnconfirmed() async throws {
		let (connection, account) = try await saved()
		let entry = try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get())
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
		guard case .readable(let entry)? = try await store.cleanup().get().entries.first else {
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
}
