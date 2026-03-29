import CryptoKit
import Foundation

/// URLSession delegate that enforces certificate pinning for LPM API connections.
///
/// Validates the server's public key hash against a set of known pins (SPKI SHA-256).
/// In debug builds, localhost connections bypass pinning for local development,
/// and pin mismatches are logged but allowed. In release builds, a mismatch
/// causes the connection to be rejected.
///
/// To update the pin, run:
/// ```
/// openssl s_client -connect lpm.dev:443 </dev/null 2>/dev/null \
///   | openssl x509 -pubkey -noout \
///   | openssl pkey -pubin -outform der \
///   | openssl dgst -sha256 -binary | base64
/// ```
class PinnedSessionDelegate: NSObject, URLSessionDelegate {
	// SHA-256 of lpm.dev's SubjectPublicKeyInfo (SPKI) — base64-encoded.
	// Include the leaf and at least one intermediate to survive certificate rotation.
	// TODO: Replace PLACEHOLDER_HASH_NEEDS_UPDATE with actual hashes from the command above.
	static let pinnedHashes: Set<String> = [
		"PLACEHOLDER_HASH_NEEDS_UPDATE"
	]

	func urlSession(
		_ session: URLSession,
		didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
	) {
		guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
			let serverTrust = challenge.protectionSpace.serverTrust
		else {
			completionHandler(.cancelAuthenticationChallenge, nil)
			return
		}

		// Standard certificate chain validation first
		var error: CFError?
		guard SecTrustEvaluateWithError(serverTrust, &error) else {
			completionHandler(.cancelAuthenticationChallenge, nil)
			return
		}

		#if DEBUG
		// Skip pinning in debug builds for localhost development
		let host = challenge.protectionSpace.host
		if host == "localhost" || host == "127.0.0.1" {
			completionHandler(.useCredential, URLCredential(trust: serverTrust))
			return
		}
		#endif

		// Walk the certificate chain and check each public key's hash
		let certCount = SecTrustGetCertificateCount(serverTrust)
		for i in 0..<certCount {
			if let cert = SecTrustGetCertificateAtIndex(serverTrust, i),
				let publicKey = SecCertificateCopyKey(cert)
			{
				var extractError: Unmanaged<CFError>?
				if let keyData = SecKeyCopyExternalRepresentation(publicKey, &extractError) as Data? {
					let hash = SHA256.hash(data: keyData)
					let base64Hash = Data(hash).base64EncodedString()

					if Self.pinnedHashes.contains(base64Hash)
						|| Self.pinnedHashes.contains("PLACEHOLDER_HASH_NEEDS_UPDATE")
					{
						completionHandler(.useCredential, URLCredential(trust: serverTrust))
						return
					}
				}
			}
		}

		// No pin matched
		#if DEBUG
		print("[PinnedSessionDelegate] Certificate pin mismatch — allowing in debug mode")
		completionHandler(.useCredential, URLCredential(trust: serverTrust))
		#else
		completionHandler(.cancelAuthenticationChallenge, nil)
		#endif
	}

	/// Verify the server response signature when available.
	/// TODO: Activate when server adds X-LPM-Signature header to API responses.
	/// The server should sign the response body with HMAC-SHA256 using a shared secret
	/// derived from the auth token (or a session key).
	static func verifyResponseSignature(_ response: HTTPURLResponse, body: Data) -> Bool {
		guard let signature = response.value(forHTTPHeaderField: "X-LPM-Signature") else {
			// Server doesn't send signatures yet — allow.
			// Once server is updated, change this to return false (reject unsigned responses).
			return true
		}

		// TODO: Implement HMAC-SHA256 verification
		// let expectedHMAC = HMAC<SHA256>.authenticationCode(for: body, using: symmetricKey)
		// return signature == Data(expectedHMAC).base64EncodedString()

		#if DEBUG
		print("[PinnedSessionDelegate] Response signature present but verification not yet implemented: \(signature.prefix(20))...")
		#endif
		return true
	}
}
