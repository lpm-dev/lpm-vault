import CryptoKit
import Foundation
import Testing

@testable import LPMVault

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
	private func makeResponse(headers: [String: String] = [:]) -> HTTPURLResponse {
		HTTPURLResponse(
			url: URL(string: "https://lpm.dev/api/test")!,
			statusCode: 200,
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
			authToken: "token",
			requireSignature: true
		)

		#expect(result == false)
	}

	@Test("unsigned non-vault response remains accepted")
	func optionalSignatureAcceptsUnsignedResponse() {
		let response = makeResponse()
		#expect(PinnedSessionDelegate.verifyResponseSignature(response, body: Data()) == true)
	}

	@Test("response with signature header but no auth token rejects")
	func signatureHeaderNoTokenRejects() {
		let response = makeResponse(headers: ["X-LPM-Signature": "some-signature-value"])
		let body = Data("test".utf8)

		// No auth token → can't verify → reject
		let result = PinnedSessionDelegate.verifyResponseSignature(response, body: body)
		#expect(result == false)

		// Empty auth token → reject
		let result2 = PinnedSessionDelegate.verifyResponseSignature(response, body: body, authToken: "")
		#expect(result2 == false)
	}

	@Test("valid HMAC signature is accepted")
	func validHmacAccepted() {
		let token = "test-auth-token-12345"
		let body = Data(#"{"vaultId":"abc","version":1}"#.utf8)

		// Compute expected signature the same way the server does:
		// HMAC-SHA256(body, SHA256(token))
		let hmacKey = SHA256.hash(data: Data(token.utf8))
		let mac = HMAC<SHA256>.authenticationCode(
			for: body, using: SymmetricKey(data: Data(hmacKey))
		)
		let signature = Data(mac).base64EncodedString()

		let response = makeResponse(headers: ["X-LPM-Signature": signature])
		let result = PinnedSessionDelegate.verifyResponseSignature(response, body: body, authToken: token)

		#expect(result == true)
	}

	@Test("tampered body with valid-looking signature is rejected")
	func tamperedBodyRejects() {
		let token = "test-auth-token-12345"
		let originalBody = Data(#"{"vaultId":"abc","version":1}"#.utf8)

		// Sign the original body
		let hmacKey = SHA256.hash(data: Data(token.utf8))
		let mac = HMAC<SHA256>.authenticationCode(
			for: originalBody, using: SymmetricKey(data: Data(hmacKey))
		)
		let signature = Data(mac).base64EncodedString()

		// Tamper with the body
		let tamperedBody = Data(#"{"vaultId":"abc","version":999}"#.utf8)
		let response = makeResponse(headers: ["X-LPM-Signature": signature])
		let result = PinnedSessionDelegate.verifyResponseSignature(response, body: tamperedBody, authToken: token)

		#expect(result == false)
	}

	@Test("wrong auth token produces different HMAC and is rejected")
	func wrongTokenRejects() {
		let realToken = "real-token"
		let body = Data(#"{"status":"ok"}"#.utf8)

		// Sign with real token
		let hmacKey = SHA256.hash(data: Data(realToken.utf8))
		let mac = HMAC<SHA256>.authenticationCode(
			for: body, using: SymmetricKey(data: Data(hmacKey))
		)
		let signature = Data(mac).base64EncodedString()

		// Verify with wrong token
		let response = makeResponse(headers: ["X-LPM-Signature": signature])
		let result = PinnedSessionDelegate.verifyResponseSignature(response, body: body, authToken: "wrong-token")

		#expect(result == false)
	}

	@Test("pinned hashes do not contain placeholder")
	func noPLaceholderHash() {
		#expect(!PinnedSessionDelegate.pinnedHashes.contains("PLACEHOLDER_HASH_NEEDS_UPDATE"))
	}

	@Test("pinned hashes contain at least two entries (leaf + intermediate)")
	func atLeastTwoPins() {
		#expect(PinnedSessionDelegate.pinnedHashes.count >= 2)
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
	@Test("streaming limit rejects a body without a Content-Length")
	func rejectsChunkedOversize() async throws {
		let host = "\(UUID().uuidString.lowercased()).example"
		let body = Data("four".utf8)
		BoundedResponseRoutes.shared.register(host: host, body: body)

		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [BoundedResponseURLProtocol.self]
		let session = URLSession(configuration: configuration)
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
}

@Suite("Stable Wrapping Key File")
struct StableWrappingKeyFileTests {
	@Test("legacy key fallback rejects exposed permissions and symbolic links")
	func rejectsUnsafeFiles() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-vault-key-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let key = Data(repeating: 0x5a, count: 32)
		let encoded = key.map { String(format: "%02x", $0) }.joined()
		let target = directory.appendingPathComponent("key-target")
		try Data(encoded.utf8).write(to: target)

		try FileManager.default.setAttributes(
			[.posixPermissions: 0o604],
			ofItemAtPath: target.path
		)
		#expect(VaultCrypto.readStableWrappingKeyFile(at: target) == nil)

		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: target.path
		)
		#expect(VaultCrypto.readStableWrappingKeyFile(at: target) == key)

		let link = directory.appendingPathComponent("key-link")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
		#expect(VaultCrypto.readStableWrappingKeyFile(at: link) == nil)
	}
}

@Suite("Update Link Validation")
struct UpdateLinkValidationTests {
	@Test("only this project's GitHub release pages are accepted")
	func validatesReleaseOriginAndPath() {
		#expect(UpdateChecker.validatedReleaseURL(
			"https://github.com/lpm-dev/lpm-vault/releases/tag/v1.2.3"
		) != nil)
		#expect(UpdateChecker.validatedReleaseURL(
			"https://example.com/lpm-dev/lpm-vault/releases/tag/v1.2.3"
		) == nil)
		#expect(UpdateChecker.validatedReleaseURL(
			"file:///tmp/fake-release"
		) == nil)
		#expect(UpdateChecker.validatedReleaseURL(
			"https://github.com/attacker/project/releases/tag/v1.2.3"
		) == nil)
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
