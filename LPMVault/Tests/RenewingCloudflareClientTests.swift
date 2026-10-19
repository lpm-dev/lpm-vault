import Foundation
import Testing
@testable import LPMVault

/// The tokens requests went with, in order.
private final class SentTokens: @unchecked Sendable {
	private let lock = NSLock()
	private var sent: [String] = []
	var values: [String] { lock.withLock { sent } }
	func append(_ token: String) { lock.withLock { sent.append(token) } }
}

/// Cloudflare's API that refuses one token, or every token when `refused`
/// is nil, recording the token each request went with.
private final class RefusingCloudflare: CloudflareClientProtocol, @unchecked Sendable {
	let token: String
	let refused: String?
	let sent: SentTokens

	init(token: String, refused: String?, sent: SentTokens) {
		self.token = token
		self.refused = refused
		self.sent = sent
	}

	private func answer<Value>(_ value: Value) -> Result<Value, CloudflareAPIError> {
		sent.append(token)
		return refused.map { $0 == token } ?? true ? .failure(.unauthorized) : .success(value)
	}

	func workers(in account: String) async -> Result<[CloudflareWorker], CloudflareAPIError> { answer([]) }
	func worker(_ idOrName: String, in account: String) async -> Result<CloudflareWorker, CloudflareAPIError> {
		answer(CloudflareWorker(id: CloudflareFixture.workerID, name: "api"))
	}
	func newestVersion(ofWorker id: String, in account: String) async -> Result<CloudflareVersion, CloudflareAPIError> {
		.failure(.notFound)
	}
	func activeDeployment(ofScript name: String, in account: String) async -> Result<CloudflareDeployment, CloudflareAPIError> {
		.failure(.notFound)
	}
	func updateSecrets(_ secrets: [String: String], ofScript name: String, in account: String) async
		-> Result<CloudflareSecretsUpdate, CloudflareAPIError>
	{
		answer(CloudflareSecretsUpdate(names: Set(secrets.keys), answeredAt: nil))
	}
}

struct RenewingCloudflareClientTests {
	private let sent = SentTokens()
	private let keychain = MockKeychainService()
	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }

	private let refresher = ScriptedTokenRefresher { call, index in
		ScriptedTokenRefresher.renewed(
			call, access: "cf_access_\(index + 2)", refresh: "cf_refresh_\(index + 2)", accessLifetime: 3_600, refreshLifetime: 31_536_000,
			platform: "cloudflare")
	}

	private func credentials() -> PlatformCredentials {
		PlatformCredentials(
			store: store, refresher: refresher, session: { platformTestSession(URL(string: "http://localhost:3000")!) },
			now: { CloudflareLoginFixture.start })
	}

	@Test("a read Cloudflare refuses is sent once more with the renewed token")
	func resendsReads() async throws {
		let account = CloudflareLoginFixture.account()
		let connection = try await CloudflareLoginFixture.save(account, in: store)
		let client = RenewingCloudflareClient(
			connectionID: connection.id, generation: account.generation, credentials: credentials(),
			make: { [sent] in RefusingCloudflare(token: $0, refused: "cf_access_1", sent: sent) })
		#expect(try await client.worker(CloudflareFixture.workerID, in: CloudflareFixture.account).get().name == "api")
		#expect(sent.values == ["cf_access_1", "cf_access_2"])
	}

	@Test("a publish isn't sent again after a renewal: it's told, so it checks the Worker again first")
	func publishIsTold() async throws {
		let account = CloudflareLoginFixture.account()
		let connection = try await CloudflareLoginFixture.save(account, in: store)
		let client = RenewingCloudflareClient(
			connectionID: connection.id, generation: account.generation, credentials: credentials(), resendsAfterRenewal: false,
			make: { [sent] in RefusingCloudflare(token: $0, refused: "cf_access_1", sent: sent) })
		#expect(await client.updateSecrets(["A": "1"], ofScript: "api", in: CloudflareFixture.account) == .failure(.renewed))
		#expect(try await client.updateSecrets(["A": "1"], ofScript: "api", in: CloudflareFixture.account).get().names == ["A"])
		#expect(sent.values == ["cf_access_1", "cf_access_2"])
	}

	@Test("a login connected again since the client was made sends nothing")
	func refusesOtherGenerations() async throws {
		let account = CloudflareLoginFixture.account()
		let connection = try await CloudflareLoginFixture.save(account, in: store)
		try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(), in: store)
		let client = RenewingCloudflareClient(
			connectionID: connection.id, generation: account.generation, credentials: credentials(),
			make: { [sent] in RefusingCloudflare(token: $0, refused: "none", sent: sent) })
		#expect(await client.workers(in: CloudflareFixture.account) == .failure(.credentials(.replaced)))
		#expect(sent.values.isEmpty)
	}

	@Test("a token Cloudflare refuses again just after it was renewed can't reach what was asked: it isn't renewed again, nor read as a connection to reconnect")
	func refusedAfterRenewal() async throws {
		let account = CloudflareLoginFixture.account()
		let connection = try await CloudflareLoginFixture.save(account, in: store)
		let client = RenewingCloudflareClient(
			connectionID: connection.id, generation: account.generation, credentials: credentials(),
			make: { [sent] in RefusingCloudflare(token: $0, refused: nil, sent: sent) })
		#expect(await client.workers(in: CloudflareFixture.account) == .failure(.forbidden))
		#expect(await client.workers(in: CloudflareFixture.account) == .failure(.forbidden))
		#expect(refresher.calls.count == 1)
		#expect(sent.values == ["cf_access_1", "cf_access_2", "cf_access_2"])
	}

	@Test("a publish whose renewed token Cloudflare refuses again is told it can't reach the Worker, without another renewal")
	func publishRefusedAfterRenewal() async throws {
		let account = CloudflareLoginFixture.account()
		let connection = try await CloudflareLoginFixture.save(account, in: store)
		let client = RenewingCloudflareClient(
			connectionID: connection.id, generation: account.generation, credentials: credentials(), resendsAfterRenewal: false,
			make: { [sent] in RefusingCloudflare(token: $0, refused: nil, sent: sent) })
		#expect(await client.updateSecrets(["A": "1"], ofScript: "api", in: CloudflareFixture.account) == .failure(.renewed))
		#expect(await client.updateSecrets(["A": "1"], ofScript: "api", in: CloudflareFixture.account) == .failure(.forbidden))
		#expect(refresher.calls.count == 1)
	}
}

