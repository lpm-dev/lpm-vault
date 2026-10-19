import CryptoKit
import Foundation
@testable import LPMVault

/// Cloudflare logins and accounts as the connect tests use them.
enum CloudflareLoginFixture {
	static let clientID = "lpm-vault-development"
	static let subject = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
	static let otherSubject = "9e8d7c6b-5a49-3827-1605-f4e3d2c1b0a9"
	static let acme = CloudflareAccount(id: "832433f01fefba3b0c9edc8bb3749b87", name: "Acme")
	static let beta = CloudflareAccount(id: "1b2c3d4e5f60718293a4b5c6d7e8f901", name: "Beta")
	static let start = Date(timeIntervalSince1970: 1_792_300_000)

	static func account(
		subject: String = subject,
		label: String = "Acme · K7Q2",
		accounts: [CloudflareAccount] = [acme],
		issuer: PlatformIssuer = .development,
		clientID: String = clientID,
		generation: String = CloudflareConnectionAccount.makeGeneration()
	) -> CloudflareConnectionAccount {
		CloudflareConnectionAccount(
			login: CloudflareLogin.key(subject: subject), label: label, accounts: accounts, issuer: issuer, clientID: clientID,
			generation: generation)
	}

	static func refresh(
		token: String = "cf_refresh_1",
		lifetime: TimeInterval = 3_600,
		eligibility: TimeInterval = 365 * 86_400,
		attempt: PlatformTokenRefresh.Attempt? = nil,
		at date: Date = start
	) -> PlatformTokenRefresh {
		PlatformTokenRefresh(
			token: token, accessTokenExpiresAt: date.addingTimeInterval(lifetime), expiresAt: date.addingTimeInterval(eligibility),
			obtainedAt: date, principalID: platformTestPrincipal, attempt: attempt)
	}

	/// Saves a Cloudflare login, as connecting does.
	@discardableResult
	static func save(
		_ account: CloudflareConnectionAccount,
		in store: PlatformConnectionStore,
		access: String = "cf_access_1",
		refresh: PlatformTokenRefresh = refresh()
	) async throws -> PlatformConnection {
		try await store.save(.cloudflare(account), accessToken: access, refresh: refresh, at: start).get()
	}

	/// What the Registry seals for a renewal of `attempt`: Cloudflare's next pair.
	static func successor(
		for attempt: (id: String, publicKey: Data),
		access: String = "cf_access_2",
		refresh: String = "cf_refresh_2"
	) -> PlatformAuthorizationEnvelope.Sealed {
		try! RegistryTestSealer.seal(
			[
				"platform": "cloudflare", "accessToken": access, "accessTokenExpiresIn": 3_600, "refreshToken": refresh,
				"refreshTokenExpiresIn": 31_536_000,
			],
			authorizationID: attempt.id, to: attempt.publicKey, domain: PlatformAuthorizationEnvelope.refreshDomain)
	}
}

/// A Registry that answers revocations as a test scripts it, recording each request.
final class ScriptedRevoker: PlatformTokenRevoking, @unchecked Sendable {
	struct Call: Sendable {
		let platform: BrowserPlatform
		let token: String
		let revocationID: String
		let attempt: (id: String, publicKey: Data)?
		let issuer: PlatformIssuer
	}

	typealias Answer = @Sendable (_ call: Call, _ index: Int) async -> Result<PlatformTokenRevocationOutcome, PlatformAuthorizationError>

	private let lock = NSLock()
	private var log: [Call] = []
	private let answer: Answer

	init(_ answer: @escaping Answer = { _, _ in .success(.accepted) }) {
		self.answer = answer
	}

	var calls: [Call] { lock.withLock { log } }

	func revoke(
		_ platform: BrowserPlatform,
		token: String,
		revocationID: String,
		attempt: (id: String, publicKey: Data)?,
		session: PlatformSession
	) async -> Result<PlatformTokenRevocationOutcome, PlatformAuthorizationError> {
		let call = Call(platform: platform, token: token, revocationID: revocationID, attempt: attempt, issuer: session.issuer)
		let index = lock.withLock {
			log.append(call)
			return log.count - 1
		}
		return await answer(call, index)
	}
}

/// The waits a cleanup asked for. Each wait ends the cleanup's run, as
/// cancelling it would, so a test reads what it asked for and resumes it by hand.
final class RecordedWaits: @unchecked Sendable {
	private let lock = NSLock()
	private var waits: [Duration] = []

	var values: [Duration] { lock.withLock { waits } }

	var sleep: @Sendable (Duration) async throws -> Void {
		{ [self] duration in
			lock.withLock { waits.append(duration) }
			throw CancellationError()
		}
	}
}
