import CryptoKit
import Foundation
import Testing

@testable import LPMVault

@Suite("Scoped Organization Sharing Keys")
struct ScopedOrganizationSharingKeyTests {
	@Test("sharing-key accounts match the CLI scope derivation")
	func accountDerivationMatchesCLI() throws {
		let account = try VaultCrypto.x25519KeychainAccount(
			registryURL: "https://registry.example/",
			callerUserID: "user-1"
		)

		#expect(
			account
				== "__x25519_private_key__.5a12911fb761923d976c0aa9f51355a7a8b1c31b06d152393eec5ab45357e666"
		)
	}

	@Test("sharing-key accounts isolate Registry authorities and callers")
	func accountsIsolateTrustDomains() throws {
		let first = try VaultCrypto.x25519KeychainAccount(
			registryURL: "https://registry.example",
			callerUserID: "user-1"
		)
		let same = try VaultCrypto.x25519KeychainAccount(
			registryURL: "HTTPS://REGISTRY.EXAMPLE:443///",
			callerUserID: "user-1"
		)
		let otherRegistry = try VaultCrypto.x25519KeychainAccount(
			registryURL: "https://other.example",
			callerUserID: "user-1"
		)
		let otherCaller = try VaultCrypto.x25519KeychainAccount(
			registryURL: "https://registry.example",
			callerUserID: "user-2"
		)

		#expect(first == same)
		#expect(first != otherRegistry)
		#expect(first != otherCaller)
	}

	@Test("malformed authenticated caller identities cannot select a key account")
	func malformedCallerIsRejected() {
		#expect(throws: (any Error).self) {
			_ = try VaultCrypto.x25519KeychainAccount(
				registryURL: "https://registry.example",
				callerUserID: "caller\nsubstitution"
			)
		}
	}

}

// MARK: - OrgKeyTrust (Strict Mode)

@Suite("OrgKeyTrust — Strict Key Verification")
struct OrgKeyTrustTests {
	/// Helper: create a deterministic public key from a seed string.
	private func makeKey(_ seed: String) -> Data {
		Data(SHA256.hash(data: Data(seed.utf8)).prefix(32))
	}

	@Test("new member is NOT auto-trusted — produces pending approval")
	func newMemberPendingApproval() {
		let trust = OrgKeyTrust()
		let key = makeKey("alice")

		let pending = trust.verify(members: [(id: "alice", publicKey: key)])

		#expect(pending.count == 1)
		#expect(pending[0].memberId == "alice")
		#expect(pending[0].isNewMember == true)
		#expect(pending[0].oldFingerprint == nil)
		// Trust store should NOT be modified
		#expect(trust.trustedFingerprints.isEmpty)
	}

	@Test("already-trusted member with same key produces no pending approval")
	func trustedMemberSameKey() {
		let key = makeKey("bob")
		let fingerprint = SHA256.hash(data: key)
			.map { String(format: "%02x", $0) }.joined()

		let trust = OrgKeyTrust(trustedFingerprints: ["bob": fingerprint])

		let pending = trust.verify(members: [(id: "bob", publicKey: key)])

		#expect(pending.isEmpty)
	}

	@Test("trusted member with changed key produces pending approval with old fingerprint")
	func trustedMemberChangedKey() {
		let oldKey = makeKey("charlie-old")
		let oldFingerprint = SHA256.hash(data: oldKey)
			.map { String(format: "%02x", $0) }.joined()

		let trust = OrgKeyTrust(trustedFingerprints: ["charlie": oldFingerprint])

		let newKey = makeKey("charlie-new")
		let pending = trust.verify(members: [(id: "charlie", publicKey: newKey)])

		#expect(pending.count == 1)
		#expect(pending[0].memberId == "charlie")
		#expect(pending[0].isNewMember == false)
		#expect(pending[0].oldFingerprint == oldFingerprint)
		// Trust store should NOT be modified
		#expect(trust.trustedFingerprints["charlie"] == oldFingerprint)
	}

	@Test("mixed scenario: trusted + new + changed members")
	func mixedScenario() {
		let aliceKey = makeKey("alice")
		let aliceFingerprint = SHA256.hash(data: aliceKey)
			.map { String(format: "%02x", $0) }.joined()

		let trust = OrgKeyTrust(trustedFingerprints: [
			"alice": aliceFingerprint,
			"bob": "old-bob-fingerprint",
		])

		let pending = trust.verify(members: [
			(id: "alice", publicKey: aliceKey),       // trusted, same key
			(id: "bob", publicKey: makeKey("bob-new")),  // trusted, changed key
			(id: "carol", publicKey: makeKey("carol")),  // new member
		])

		#expect(pending.count == 2)

		let bobPending = pending.first { $0.memberId == "bob" }
		#expect(bobPending != nil)
		#expect(bobPending?.isNewMember == false)
		#expect(bobPending?.oldFingerprint == "old-bob-fingerprint")

		let carolPending = pending.first { $0.memberId == "carol" }
		#expect(carolPending != nil)
		#expect(carolPending?.isNewMember == true)
	}

	@Test("verify does not mutate trust store")
	func verifyDoesNotMutate() {
		let trust = OrgKeyTrust(trustedFingerprints: ["existing": "fingerprint"])

		_ = trust.verify(members: [
			(id: "new-member", publicKey: makeKey("new")),
		])

		// Trust store must be unchanged
		#expect(trust.trustedFingerprints.count == 1)
		#expect(trust.trustedFingerprints["new-member"] == nil)
	}

	@Test("approve adds fingerprints to trust store")
	func approveAddsFingerprints() {
		var trust = OrgKeyTrust()
		let key = makeKey("dave")
		let fingerprint = SHA256.hash(data: key)
			.map { String(format: "%02x", $0) }.joined()

		let approval = PendingKeyApproval(
			memberId: "dave",
			fingerprint: fingerprint,
			isNewMember: true,
			oldFingerprint: nil
		)

		trust.approve([approval])

		#expect(trust.trustedFingerprints["dave"] == fingerprint)
	}

	@Test("approve overwrites old fingerprint for changed key")
	func approveOverwritesChangedKey() {
		var trust = OrgKeyTrust(trustedFingerprints: ["eve": "old-fingerprint"])

		let approval = PendingKeyApproval(
			memberId: "eve",
			fingerprint: "new-fingerprint",
			isNewMember: false,
			oldFingerprint: "old-fingerprint"
		)

		trust.approve([approval])

		#expect(trust.trustedFingerprints["eve"] == "new-fingerprint")
	}

	@Test("empty members list produces no pending approvals")
	func emptyMembers() {
		let trust = OrgKeyTrust(trustedFingerprints: ["alice": "fp"])

		let pending = trust.verify(members: [])

		#expect(pending.isEmpty)
	}
}

// MARK: - PinnedSessionDelegate

@Suite("PinnedSessionDelegate — Response Signature Verification")
struct PinnedSessionDelegateTests {
	@Test("development response signatures follow the build trust policy")
	func localDevelopmentSignatureIsAccepted() throws {
		let response = try #require(HTTPURLResponse(
			url: URL(string: "http://localhost:3000/api/test")!,
			statusCode: 200,
			httpVersion: "HTTP/1.1",
			headerFields: [
				"X-LPM-Response-Key-ID": "vault-test-rfc8032",
				"X-LPM-Response-Signature":
					"ABiBKJ3ihBNVXfSmsCZEK_YdQa1Y2VQm8w3uU9apguJ3j4G1FhiHrLVjPQDLiqQUHJV_H6OIqrGWCpaRNAJ0CQ",
			]
		))
		let verified = PinnedSessionDelegate.verifyResponseSignature(
			response, body: Data(#"{"vaultId":"v1","version":3}"#.utf8),
			requireSignature: true
		)
		#if DEBUG
		#expect(verified)
		#else
		#expect(!verified)
		#endif
	}

	@Test("redirect policy is installed as a URL session task delegate")
	func redirectPolicyIsInstalled() {
		let delegate: AnyObject = PinnedSessionDelegate()
		#expect(delegate is URLSessionTaskDelegate)
	}

	@Test("redirects require the exact same origin")
	func redirectsRequireSameOrigin() {
		let live = URL(string: "https://lpm.dev/api/tokens")!
		#expect(PinnedSessionDelegate.isSameOrigin(
			live,
			URL(string: "https://lpm.dev/api/user/me")!
		))
		#expect(!PinnedSessionDelegate.isSameOrigin(
			live,
			URL(string: "https://example.com/api/tokens")!
		))
		#expect(!PinnedSessionDelegate.isSameOrigin(
			live,
			URL(string: "http://lpm.dev/api/tokens")!
		))
		#expect(!PinnedSessionDelegate.isSameOrigin(
			live,
			URL(string: "https://lpm.dev:8443/api/tokens")!
		))
	}

	/// Helper: create a minimal HTTPURLResponse with optional headers.
	private func makeResponse(
		statusCode: Int = 200,
		headers: [String: String] = [:]
	) -> HTTPURLResponse {
		HTTPURLResponse(
			url: URL(string: "https://lpm.dev/api/test")!,
			statusCode: statusCode,
			httpVersion: "HTTP/1.1",
			headerFields: headers
		)!
	}

	@Test("unsigned success is rejected when the endpoint requires a signature")
	func requiredSignatureRejectsUnsignedSuccess() {
		let response = makeResponse()
		let body = Data("test".utf8)

		let result = PinnedSessionDelegate.verifyResponseSignature(
			response,
			body: body,
			requireSignature: true
		)

		#expect(result == false)
	}

	@Test("unsigned non-vault response remains accepted")
	func optionalSignatureAcceptsUnsignedResponse() {
		let response = makeResponse()
		#expect(PinnedSessionDelegate.verifyResponseSignature(response, body: Data()) == true)
	}

	@Test("current Ed25519 response signature matches the cross-language fixture")
	func currentEd25519FixtureIsAccepted() {
		let body = Data(#"{"vaultId":"v1","version":3}"#.utf8)
		let response = makeResponse(headers: [
			"X-LPM-Response-Key-ID": "vault-test-rfc8032",
			"X-LPM-Response-Signature":
				"ABiBKJ3ihBNVXfSmsCZEK_YdQa1Y2VQm8w3uU9apguJ3j4G1FhiHrLVjPQDLiqQUHJV_H6OIqrGWCpaRNAJ0CQ",
		])
		let testPublicKey = Data([
			0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
			0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
			0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25,
			0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
		])

		#expect(PinnedSessionDelegate.verifyResponseSignatureForTesting(
			response,
			body: body,
			requireSignature: true,
			trustedSigningKeys: ["vault-test-rfc8032": testPublicKey]
		))
	}

	@Test("production signing key authenticates only the original status, body, and key ID")
	func productionSigningKeyAuthenticatesExactResponse() {
		let body = Data(#"{"vaultId":"v1","version":3}"#.utf8)
		let signature = "qHV0sHXlvnDewhvNfLUGNR09T96GC2YqkYxhy8K6JGPEOh0KOZB94jmdLodFv3WZb62yDBcExziVXge_dpuGDA"
		for (status, responseBody, keyID, expected) in [
			(200, body, "vault-2026-09-06", true),
			(404, body, "vault-2026-09-06", false),
			(200, Data("changed".utf8), "vault-2026-09-06", false),
			(200, body, "vault-2026-09", false),
		] {
			let response = makeResponse(statusCode: status, headers: [
				"X-LPM-Response-Key-ID": keyID,
				"X-LPM-Response-Signature": signature,
			])
			#expect(PinnedSessionDelegate.verifyResponseSignature(
				response, body: responseBody, requireSignature: true) == expected)
		}
	}

	@Test("response signatures require canonical base64url encoding")
	func noncanonicalResponseSignatureRejects() {
		let body = Data(#"{"vaultId":"v1","version":3}"#.utf8)
		let response = makeResponse(headers: [
			"X-LPM-Response-Key-ID": "vault-test-rfc8032",
			"X-LPM-Response-Signature":
				"HifVVd93oNDzrSakA0UZeMUczKwmQbH8GeYWfw19Hj9nLuqmSS6PfQV0FIreI4KKFGz2lIrELoZlSUrLDm2nAh",
		])
		let testPublicKey = Data([
			0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
			0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
			0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25,
			0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
		])

		#expect(!PinnedSessionDelegate.verifyResponseSignatureForTesting(
			response,
			body: body,
			requireSignature: true,
			trustedSigningKeys: ["vault-test-rfc8032": testPublicKey]
		))
	}

	@Test("production trust anchor rejects the published RFC test key")
	func productionTrustAnchorRejectsRFCFixture() {
		let body = Data(#"{"vaultId":"v1","version":3}"#.utf8)
		let response = makeResponse(headers: [
			"X-LPM-Response-Key-ID": "vault-2026-09",
			"X-LPM-Response-Signature":
				"-4Wt-YkQkGV8-nlni_U_m58rtZ-Bs_FhH-ZR7qPxPkuUAI4YKToV0rvn-qgwZscJ_ml3-1yp3YfhDvFYX1rwAQ",
		])

		#expect(!PinnedSessionDelegate.verifyResponseSignature(
			response, body: body, requireSignature: true))
	}

	@Test("response signature binds the actual HTTP status")
	func responseSignatureBindsStatus() {
		let body = Data(#"{"vaultId":"v1","version":3}"#.utf8)
		let response = makeResponse(statusCode: 404, headers: [
			"X-LPM-Response-Key-ID": "vault-2026-09",
			"X-LPM-Response-Signature":
				"-4Wt-YkQkGV8-nlni_U_m58rtZ-Bs_FhH-ZR7qPxPkuUAI4YKToV0rvn-qgwZscJ_ml3-1yp3YfhDvFYX1rwAQ",
		])

		#expect(!PinnedSessionDelegate.verifyResponseSignature(
			response, body: body, requireSignature: true))
	}

	@Test("unknown response signing keys fail closed")
	func unknownResponseSigningKeyRejects() {
		let response = makeResponse(headers: [
			"X-LPM-Response-Key-ID": "unknown",
			"X-LPM-Response-Signature":
				"-4Wt-YkQkGV8-nlni_U_m58rtZ-Bs_FhH-ZR7qPxPkuUAI4YKToV0rvn-qgwZscJ_ml3-1yp3YfhDvFYX1rwAQ",
		])

		#expect(!PinnedSessionDelegate.verifyResponseSignature(
			response,
			body: Data(#"{"vaultId":"v1","version":3}"#.utf8),
			requireSignature: true
		))
	}

	@Test("retired bearer HMAC response header fails closed")
	func retiredBearerHmacHeaderRejects() {
		let response = makeResponse(headers: ["X-LPM-Signature": "some-signature-value"])

		#expect(!PinnedSessionDelegate.verifyResponseSignature(
			response, body: Data("test".utf8), requireSignature: true))
	}

	@Test("pinned hashes do not contain placeholder")
	func noPLaceholderHash() {
		#expect(!PinnedSessionDelegate.pinnedHashes.contains("PLACEHOLDER_HASH_NEEDS_UPDATE"))
	}

	@Test("pinned hashes contain at least two entries (leaf + intermediate)")
	func atLeastTwoPins() {
		#expect(PinnedSessionDelegate.pinnedHashes.count >= 2)
	}

	@Test("pinset contains the production leaf and active intermediate")
	func productionPins() {
		#expect(PinnedSessionDelegate.pinnedHashes.contains(
			"KuVBh4ZrhWfWkGuZAxfHWy/YBuyWosBE5/8nEWzMCAM="
		))
		#expect(PinnedSessionDelegate.pinnedHashes.contains(
			"s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y="
		))
	}

	@Test("spkiHash returns nil for unknown key size")
	func spkiHashUnknownKeySize() {
		let unknownKey = Data(repeating: 0x42, count: 33)  // not a known key size
		#expect(PinnedSessionDelegate.spkiHash(for: unknownKey) == nil)
	}

	@Test("spkiHash produces correct hash for EC P-256 raw key")
	func spkiHashECP256() {
		// 65-byte EC P-256 raw key (04 || x || y)
		let rawKey = Data(repeating: 0xAB, count: 65)
		let hash = PinnedSessionDelegate.spkiHash(for: rawKey)
		#expect(hash != nil)
		// The hash must be a valid base64-encoded SHA-256 (44 chars with padding)
		#expect(hash!.count == 44)
		#expect(hash!.hasSuffix("="))
	}

	@Test("spkiHash produces correct hash for EC P-384 raw key")
	func spkiHashECP384() {
		// 97-byte EC P-384 raw key
		let rawKey = Data(repeating: 0xCD, count: 97)
		let hash = PinnedSessionDelegate.spkiHash(for: rawKey)
		#expect(hash != nil)
	}

	@Test("spkiHash produces different hashes for different keys")
	func spkiHashDifferentKeys() {
		let key1 = Data(repeating: 0x01, count: 65)
		let key2 = Data(repeating: 0x02, count: 65)
		let hash1 = PinnedSessionDelegate.spkiHash(for: key1)
		let hash2 = PinnedSessionDelegate.spkiHash(for: key2)
		#expect(hash1 != hash2)
	}

	@Test("spkiHash differs from raw SHA-256 of same key")
	func spkiHashDiffersFromRaw() {
		// Prove the SPKI header makes a difference
		let rawKey = Data(repeating: 0xAB, count: 65)
		let spkiResult = PinnedSessionDelegate.spkiHash(for: rawKey)!
		let rawHash = Data(SHA256.hash(data: rawKey)).base64EncodedString()
		#expect(spkiResult != rawHash)
	}
}

// MARK: - LoginService Error Types

@Suite("LoginService — State Mismatch Error")
struct LoginServiceErrorTests {
	@Test("stateMismatch error has descriptive message")
	func stateMismatchDescription() {
		let error = LoginService.LoginError.stateMismatch
		#expect(error.errorDescription?.contains("CSRF") == true)
	}

	@Test("rateLimited error has descriptive message")
	func rateLimitedDescription() {
		let error = LoginService.LoginError.rateLimited
		#expect(error.errorDescription?.contains("wait") == true)
	}
}

// MARK: - Bounded HTTP Responses

@Suite("Bounded HTTP Responses")
struct BoundedHTTPResponseTests {
	@Test("vault sync response cap covers every Registry-accepted request body")
	func vaultSyncResponseCapCoversRegistryRequestLimit() {
		#expect(SyncService.maximumVaultResponseBytes == 16 * 1024 * 1024)
	}

	@Test("streaming limit rejects a body without a Content-Length")
	func rejectsChunkedOversize() async throws {
		let host = "\(UUID().uuidString.lowercased()).example"
		let body = Data("four".utf8)
		BoundedResponseRoutes.shared.register(host: host, body: body)

		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [BoundedResponseURLProtocol.self]
		let session = URLSession(
			configuration: configuration,
			delegate: BoundedHTTPResponseDelegate(),
			delegateQueue: nil
		)
		let request = URLRequest(url: URL(string: "https://\(host)/body")!)

		let exact = try await BoundedHTTPResponse.load(
			for: request,
			using: session,
			maximumBytes: body.count
		)
		#expect(exact.data == body)

		do {
			_ = try await BoundedHTTPResponse.load(
				for: request,
				using: session,
				maximumBytes: body.count - 1
			)
			Issue.record("Oversized response was accepted")
		} catch let error as BoundedHTTPResponse.LoadError {
			#expect(error == .responseTooLarge(limit: body.count - 1))
		}
	}

	@Test("resumed delegate collection preserves the streaming limit")
	func delegateCollectorRejectsChunkedOversize() async throws {
		let host = "\(UUID().uuidString.lowercased()).example"
		let body = Data("delegate-body".utf8)
		BoundedResponseRoutes.shared.register(host: host, body: body)

		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [BoundedResponseURLProtocol.self]
		let session = URLSession(
			configuration: configuration,
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
		let request = URLRequest(url: URL(string: "https://\(host)/body")!)

		let exact = try await BoundedHTTPResponse.start(
			for: request,
			using: session,
			maximumBytes: body.count
		).value()
		#expect(exact.data == body)

		do {
			_ = try await BoundedHTTPResponse.start(
				for: request,
				using: session,
				maximumBytes: body.count - 1
			).value()
			Issue.record("Oversized delegated response was accepted")
		} catch let error as BoundedHTTPResponse.LoadError {
			#expect(error == .responseTooLarge(limit: body.count - 1))
		}
	}

	@Test("auth refresh responses use the bounded delegate collector")
	func authRefreshUsesBoundedDelegateCollector() async throws {
		let validHost = "\(UUID().uuidString.lowercased()).example"
		let validBody = Data(
			#"{"token":"access","refreshToken":"refresh","expiresIn":3600,"expiresAt":"2030-08-22T12:00:00.000Z"}"#.utf8
		)
		BoundedResponseRoutes.shared.register(host: validHost, body: validBody)

		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [BoundedResponseURLProtocol.self]
		let session = URLSession(
			configuration: configuration,
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
		let request = URLRequest(url: URL(string: "https://\(validHost)/refresh")!)
		let credentials = try await AuthSessionStore.loadRefreshCredentials(
			for: request,
			using: session
		)
		#expect(credentials.token == "access")

		let oversizedHost = "\(UUID().uuidString.lowercased()).example"
		BoundedResponseRoutes.shared.register(
			host: oversizedHost,
			body: Data(repeating: 0x61, count: 64 * 1024 + 1)
		)
		let oversized = URLRequest(
			url: URL(string: "https://\(oversizedHost)/refresh")!)
		do {
			_ = try await AuthSessionStore.loadRefreshCredentials(
				for: oversized,
				using: session
			)
			Issue.record("Oversized auth refresh response was accepted")
		} catch AuthSessionRefreshError.invalidResponse {
		} catch {
			Issue.record("Unexpected auth refresh error: \(error)")
		}
	}

	@Test("avatar downloads use a chunked data delegate")
	func avatarDownloadsUseChunkedDelegate() {
		let avatarDelegate: AnyObject = AvatarSessionDelegate()
		#expect(avatarDelegate is BoundedHTTPResponseStarting)
	}

	@Test("cancelling a bounded response cancels its underlying operation")
	func cancellationPropagates() async {
		let probe = BoundedCancellationProbe()
		let accumulator = BoundedHTTPResponse.Accumulator(maximumBytes: 1)
		let started = BoundedHTTPResponse.Started(
			cancel: {
				probe.markCancelled()
				accumulator.complete(error: CancellationError())
			},
			result: { try await accumulator.value() }
		)
		let task = Task { try await started.value() }
		task.cancel()

		do {
			_ = try await task.value
			Issue.record("Cancelled bounded response completed successfully")
		} catch is CancellationError {
			#expect(probe.wasCancelled)
		} catch {
			Issue.record("Unexpected cancellation error: \(error)")
		}
	}

	@Test("avatar redirects stay on the approved origin")
	func avatarRedirectPolicyIsPreserved() throws {
		let delegate = AvatarSessionDelegate()
		let session = URLSession(
			configuration: .ephemeral,
			delegate: delegate,
			delegateQueue: nil
		)
		defer { session.invalidateAndCancel() }
		let source = try #require(URL(string: "https://avatars.githubusercontent.com/u/1"))
		let task = session.dataTask(with: source)
		let response = try #require(HTTPURLResponse(
			url: source,
			statusCode: 302,
			httpVersion: "HTTP/1.1",
			headerFields: nil
		))

		let sameOrigin = try #require(
			URL(string: "https://avatars.githubusercontent.com/u/2")
		)
		var accepted: URLRequest?
		delegate.urlSession(
			session,
			task: task,
			willPerformHTTPRedirection: response,
			newRequest: URLRequest(url: sameOrigin),
			completionHandler: { accepted = $0 }
		)
		#expect(accepted?.url == sameOrigin)

		let differentOrigin = try #require(URL(string: "https://lpm.dev/avatar"))
		var rejected: URLRequest?
		delegate.urlSession(
			session,
			task: task,
			willPerformHTTPRedirection: response,
			newRequest: URLRequest(url: differentOrigin),
			completionHandler: { rejected = $0 }
		)
		#expect(rejected == nil)
	}
}

private final class BoundedResponseRoutes: @unchecked Sendable {
	static let shared = BoundedResponseRoutes()
	private let lock = NSLock()
	private var bodies: [String: Data] = [:]

	func register(host: String, body: Data) {
		lock.withLock { bodies[host] = body }
	}

	func body(for host: String) -> Data? {
		lock.withLock { bodies[host] }
	}
}

private final class BoundedResponseURLProtocol: URLProtocol {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url,
			let host = url.host,
			let body = BoundedResponseRoutes.shared.body(for: host),
			let response = HTTPURLResponse(
				url: url,
				statusCode: 200,
				httpVersion: "HTTP/1.1",
				headerFields: ["Content-Type": "application/octet-stream"]
			)
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

private final class BoundedCancellationProbe: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false

	var wasCancelled: Bool {
		lock.withLock { cancelled }
	}

	func markCancelled() {
		lock.withLock { cancelled = true }
	}
}
