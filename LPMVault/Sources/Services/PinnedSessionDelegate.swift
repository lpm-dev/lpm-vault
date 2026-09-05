import CryptoKit
import Foundation

/// URLSession delegate that enforces certificate pinning for LPM API connections.
///
/// Validates the server's public key hash against a set of known pins (SPKI SHA-256).
/// In debug builds, localhost connections bypass pinning for local development,
/// while every non-local pin mismatch is rejected in every build configuration.
///
/// To update the pin, run:
/// ```
/// openssl s_client -connect lpm.dev:443 </dev/null 2>/dev/null \
///   | openssl x509 -pubkey -noout \
///   | openssl pkey -pubin -outform der \
///   | openssl dgst -sha256 -binary | base64
/// ```
final class PinnedSessionDelegate: BoundedHTTPResponseDelegate, @unchecked Sendable {
	// SHA-256 of lpm.dev's SubjectPublicKeyInfo (SPKI) — base64-encoded.
	// Includes the active leaf and intermediate plus the alternate Let's Encrypt
	// intermediate used by the previous chain. This permits an intentional
	// YE1/YE2 rotation without trusting an entire root hierarchy.
	// Verify with Scripts/audit-tls-pins.sh before every release.
	// Last verified against the production chain: 2026-08-25
	static let pinnedHashes: Set<String> = [
		"KuVBh4ZrhWfWkGuZAxfHWy/YBuyWosBE5/8nEWzMCAM=",  // lpm.dev leaf
		"s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y=",  // Let's Encrypt YE2
		"brzvtCELCIZUo4sD/qPX0ccRtPsd3DY6RfmxpOU9oB4=",  // Let's Encrypt YE1 backup
	]

	// ASN.1 SPKI headers by key type.
	// SecKeyCopyExternalRepresentation returns raw key bytes. To compute the
	// standard SPKI SHA-256 pin (RFC 7469), we prepend the DER header that
	// identifies the algorithm and curve, then hash the full SPKI structure.
	// These headers are fixed for each key type — they never change.
	private static let spkiHeaders: [Int: Data] = [
		// EC P-256: 26-byte header + 65-byte raw key = 91 bytes SPKI
		65: Data([
			0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d,
			0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01,
			0x07, 0x03, 0x42, 0x00,
		]),
		// EC P-384: 23-byte header + 97-byte raw key = 120 bytes SPKI
		97: Data([
			0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d,
			0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62,
			0x00,
		]),
		// RSA 2048: 24-byte header + 270-byte raw key = 294 bytes SPKI
		270: Data([
			0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48,
			0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01,
			0x0f, 0x00,
		]),
		// RSA 4096: 24-byte header + 526-byte raw key = 550 bytes SPKI
		526: Data([
			0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48,
			0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02,
			0x0f, 0x00,
		]),
	]

	/// Compute the SPKI SHA-256 pin for a raw key representation.
	/// Returns nil if the key size doesn't match any known SPKI header.
	static func spkiHash(for rawKeyData: Data) -> String? {
		guard let header = spkiHeaders[rawKeyData.count] else { return nil }
		var spkiData = header
		spkiData.append(rawKeyData)
		let hash = SHA256.hash(data: spkiData)
		return Data(hash).base64EncodedString()
	}

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

		// Walk the certificate chain and check each public key's SPKI hash.
		// SecKeyCopyExternalRepresentation returns raw key bytes; we prepend the
		// ASN.1 SPKI header to reconstruct the full SubjectPublicKeyInfo before
		// hashing, so the result matches standard SPKI SHA-256 pins (RFC 7469).
		let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
		for cert in certificates {
			if
				let publicKey = SecCertificateCopyKey(cert)
			{
				var extractError: Unmanaged<CFError>?
				if let rawKeyData = SecKeyCopyExternalRepresentation(publicKey, &extractError) as Data?,
					let base64Hash = Self.spkiHash(for: rawKeyData)
				{
					if Self.pinnedHashes.contains(base64Hash) {
						completionHandler(.useCredential, URLCredential(trust: serverTrust))
						return
					}
				}
			}
		}

		// No pin matched. Debug builds can still connect to localhost through
		// the explicit bypass above, but live traffic never bypasses pinning.
		completionHandler(.cancelAuthenticationChallenge, nil)
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		guard Self.isSameOrigin(response.url, request.url) else {
			completionHandler(nil)
			return
		}
		completionHandler(request)
	}

	static func isSameOrigin(_ source: URL?, _ destination: URL?) -> Bool {
		guard let source, let destination,
			let sourceScheme = source.scheme?.lowercased(),
			let destinationScheme = destination.scheme?.lowercased(),
			let sourceHost = source.host?.lowercased(),
			let destinationHost = destination.host?.lowercased()
		else { return false }
		return sourceScheme == destinationScheme
			&& sourceHost == destinationHost
			&& effectivePort(source) == effectivePort(destination)
	}

	private static func effectivePort(_ url: URL) -> Int? {
		if let port = url.port { return port }
		return switch url.scheme?.lowercased() {
		case "https": 443
		case "http": 80
		default: nil
		}
	}

	private static let responseSigningKeys: [String: Data] = [
		"vault-2026-09": Data([
			0xbc, 0x44, 0xf7, 0x37, 0xb6, 0x25, 0x34, 0x24,
			0x47, 0x46, 0x16, 0xd6, 0xab, 0x6e, 0x03, 0x12,
			0x77, 0x02, 0xd8, 0x06, 0x96, 0x4e, 0x96, 0x79,
			0x11, 0x54, 0xf3, 0x21, 0x4f, 0x90, 0xc9, 0x1f,
		])
	]
	private static let responseSignatureDomain = Data("lpm-authenticated-response\0".utf8)
	#if DEBUG
	private static let localResponseSigningKeys: [String: Data] = {
		var keys = responseSigningKeys
		keys["vault-test-rfc8032"] = Data([
			0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
			0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
			0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25,
			0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
		])
		return keys
	}()
	#endif

	static func verifyResponseSignature(
		_ response: HTTPURLResponse,
		body: Data,
		requireSignature: Bool = false
	) -> Bool {
		#if DEBUG
		if let url = response.url, url.scheme == "http",
			let host = url.host, ["localhost", "127.0.0.1", "[::1]"].contains(host)
		{
			return verifyResponseSignature(
				response, body: body, requireSignature: requireSignature,
				trustedSigningKeys: localResponseSigningKeys
			)
		}
		#endif
		return verifyResponseSignature(
			response,
			body: body,
			requireSignature: requireSignature,
			trustedSigningKeys: responseSigningKeys
		)
	}

	#if DEBUG
	static func verifyResponseSignatureForTesting(
		_ response: HTTPURLResponse,
		body: Data,
		requireSignature: Bool = false,
		trustedSigningKeys: [String: Data]
	) -> Bool {
		verifyResponseSignature(
			response,
			body: body,
			requireSignature: requireSignature,
			trustedSigningKeys: trustedSigningKeys
		)
	}
	#endif

	private static func verifyResponseSignature(
		_ response: HTTPURLResponse,
		body: Data,
		requireSignature: Bool,
		trustedSigningKeys: [String: Data]
	) -> Bool {
		let keyID = response.value(forHTTPHeaderField: "X-LPM-Response-Key-ID")
		let encodedSignature = response.value(
			forHTTPHeaderField: "X-LPM-Response-Signature")
		guard keyID != nil || encodedSignature != nil else {
			return !requireSignature
		}
		guard let keyID, let encodedSignature,
			keyID.utf8.count <= UInt8.max,
			keyID.utf8.allSatisfy({ byte in
				(65...90).contains(byte) || (97...122).contains(byte)
					|| (48...57).contains(byte) || byte == 45 || byte == 95
			}),
			let rawPublicKey = trustedSigningKeys[keyID],
			let publicKey = try? Curve25519.Signing.PublicKey(
				rawRepresentation: rawPublicKey),
			let signature = decodeCanonicalBase64URL(
				encodedSignature, expectedByteCount: 64)
		else {
			return false
		}
		guard let frame = responseSignatureFrame(
			statusCode: response.statusCode,
			keyID: keyID,
			body: body
		) else { return false }
		return publicKey.isValidSignature(signature, for: frame)
	}

	private static func responseSignatureFrame(
		statusCode: Int,
		keyID: String,
		body: Data
	) -> Data? {
		var frame = Data(capacity:
			responseSignatureDomain.count + 12 + keyID.utf8.count + 32)
		frame.append(responseSignatureDomain)
		frame.append(4)
		guard let status = UInt16(exactly: statusCode),
			100...599 ~= status,
			let keyIDLength = UInt8(exactly: keyID.utf8.count),
			let bodyLength = UInt64(exactly: body.count)
		else { return nil }
		var bigEndianStatus = status.bigEndian
		Swift.withUnsafeBytes(of: &bigEndianStatus) { frame.append(contentsOf: $0) }
		frame.append(keyIDLength)
		frame.append(contentsOf: keyID.utf8)
		var bigEndianBodyLength = bodyLength.bigEndian
		Swift.withUnsafeBytes(of: &bigEndianBodyLength) { frame.append(contentsOf: $0) }
		frame.append(contentsOf: SHA256.hash(data: body))
		return frame
	}

	private static func decodeCanonicalBase64URL(
		_ encoded: String,
		expectedByteCount: Int
	) -> Data? {
		guard encoded.utf8.count == 86,
			encoded.utf8.allSatisfy({ byte in
				(65...90).contains(byte) || (97...122).contains(byte)
					|| (48...57).contains(byte) || byte == 45 || byte == 95
			})
		else { return nil }
		let standard = encoded
			.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
			+ "=="
		guard let decoded = Data(base64Encoded: standard),
			decoded.count == expectedByteCount,
			decoded.base64EncodedString()
				.replacingOccurrences(of: "+", with: "-")
				.replacingOccurrences(of: "/", with: "_")
				.replacingOccurrences(of: "=", with: "") == encoded
		else { return nil }
		return decoded
	}
}
