import CryptoKit
import Foundation

/// A platform's access grant, as the Registry encrypts it to this Mac's
/// one-time key after the browser finishes connecting. Matches
/// `sealAuthorizationResult` in the Registry's `lib/vault/platform-authorization.js`:
///
///     shared = ECDH-P256(client, serverEphemeral)
///     key    = HKDF-SHA256(ikm: shared, salt: authorizationID (UTF-8),
///                          info: DOMAIN || 0x00 || clientKey || ephemeralKey, 32)
///     AES-256-GCM(key, 12-byte nonce, aad: DOMAIN || 0x00 || authorizationID)
///
/// Keys are uncompressed SEC1 points, and the ciphertext ends with the 16-byte tag.
/// A refresh's result comes in the same envelope under `refreshDomain`, with
/// the refresh ID in place of the authorization ID, so neither opens as the other.
enum PlatformAuthorizationEnvelope {
	static let domain = "lpm-vault:platform-authorization:v1"
	static let refreshDomain = "lpm-vault:platform-token-refresh:v1"

	enum OpenError: Error, Equatable, Sendable {
		/// The envelope isn't one this version reads.
		case malformed
		/// It wasn't encrypted to this key for this authorization, or was changed.
		case undecryptable
		/// It decrypted, but not to a grant this version accepts.
		case invalidGrant
	}

	/// The sealed form, as the Registry's redeem response carries it.
	struct Sealed: Decodable, Equatable, Sendable {
		let version: Int
		let ephemeralPublicKey: String
		let nonce: String
		let ciphertext: String
	}

	private static let maximumCiphertextBytes = 16 * 1024

	/// The grant inside `sealed`, decrypted with `clientKey` for
	/// `authorizationID`. It opens only as the platform's grant it names.
	static func open<Grant: PlatformGrant>(
		_ sealed: Sealed,
		as _: Grant.Type,
		authorizationID: String,
		clientKey: P256.KeyAgreement.PrivateKey
	) -> Result<Grant, OpenError> {
		open(sealed, id: authorizationID, clientKey: clientKey, domain: domain) { payload in
			guard payload["platform"] as? String == Grant.platform.rawValue else { return nil }
			return Grant(payload: payload)
		}
	}

	/// What `read` makes of the payload inside `sealed`, decrypted with
	/// `clientKey` for `id` under `domain`; `read` returns nil for a payload
	/// this version doesn't accept.
	static func open<Value>(
		_ sealed: Sealed,
		id: String,
		clientKey: P256.KeyAgreement.PrivateKey,
		domain: String,
		read: ([String: Any]) -> Value?
	) -> Result<Value, OpenError> {
		guard sealed.version == 1,
			let ephemeralBytes = Data(base64Encoded: sealed.ephemeralPublicKey), ephemeralBytes.count == 65,
			let nonceBytes = Data(base64Encoded: sealed.nonce), nonceBytes.count == 12,
			let ciphertext = Data(base64Encoded: sealed.ciphertext),
			ciphertext.count > 16, ciphertext.count <= maximumCiphertextBytes,
			let ephemeralKey = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralBytes),
			let nonce = try? AES.GCM.Nonce(data: nonceBytes)
		else { return .failure(.malformed) }

		let domainPrefix = Data(domain.utf8) + [0]
		let authorization = Data(id.utf8)
		var plaintext: Data
		do {
			let shared = try clientKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
			let key = shared.hkdfDerivedSymmetricKey(
				using: SHA256.self,
				salt: authorization,
				sharedInfo: domainPrefix + clientKey.publicKey.x963Representation + ephemeralBytes,
				outputByteCount: 32
			)
			let box = try AES.GCM.SealedBox(
				nonce: nonce,
				ciphertext: ciphertext.prefix(ciphertext.count - 16),
				tag: ciphertext.suffix(16)
			)
			plaintext = try AES.GCM.open(box, using: key, authenticating: domainPrefix + authorization)
		} catch {
			return .failure(.undecryptable)
		}
		defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
		guard let payload = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
			let value = read(payload)
		else { return .failure(.invalidGrant) }
		return .success(value)
	}
}

/// What connecting a platform account grants, as the Registry seals it.
/// The payload names its platform, which `open` checks before reading it.
protocol PlatformGrant: Sendable {
	static var platform: BrowserPlatform { get }
	/// The grant `payload` describes, or nil when it isn't a well-formed one.
	init?(payload: [String: Any])
}

/// What connecting a Vercel account grants: an access token for one
/// installation of the LPM Vault integration. The token never appears when
/// the grant is printed, logged or dumped.
struct VercelGrant: PlatformGrant, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	static let platform = BrowserPlatform.vercel

	let accessToken: String
	let installationID: String
	/// The team the integration was installed for, or nil for a personal account.
	let teamID: String?
	let userID: String

	static let maximumAccessTokenLength = 4_096

	init?(accessToken: String, installationID: String, teamID: String?, userID: String) {
		guard Self.isValidAccessToken(accessToken),
			VercelPublishTarget.isValidIdentifier(installationID),
			VercelPublishTarget.isValidIdentifier(userID),
			teamID.map(VercelPublishTarget.isValidIdentifier) ?? true
		else { return nil }
		self.accessToken = accessToken
		self.installationID = installationID
		self.teamID = teamID
		self.userID = userID
	}

	init?(payload: [String: Any]) {
		guard let accessToken = payload["accessToken"] as? String,
			let installationID = payload["installationId"] as? String,
			let userID = payload["userId"] as? String
		else { return nil }
		let teamID: String?
		switch payload["teamId"] {
		case nil, is NSNull: teamID = nil
		case let value as String: teamID = value
		default: return nil
		}
		self.init(accessToken: accessToken, installationID: installationID, teamID: teamID, userID: userID)
	}

	/// Printable ASCII without spaces, as the Registry checks before sealing it.
	static func isValidAccessToken(_ token: String) -> Bool {
		!token.isEmpty && token.utf8.count <= maximumAccessTokenLength
			&& token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
	}

	var description: String {
		"VercelGrant(installation: \(installationID), team: \(teamID ?? "personal"), token: <redacted>)"
	}
	var debugDescription: String { description }
	var customMirror: Mirror {
		Mirror(self, children: ["installationID": installationID, "teamID": teamID as Any, "userID": userID])
	}
}

/// What connecting a Netlify account grants: an access token that reaches
/// every team of the Netlify user who approved LPM Vault. The token never
/// appears when the grant is printed, logged or dumped.
struct NetlifyGrant: PlatformGrant, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	static let platform = BrowserPlatform.netlify

	let accessToken: String

	init?(accessToken: String) {
		guard NetlifyHTTP.isValidAccessToken(accessToken) else { return nil }
		self.accessToken = accessToken
	}

	init?(payload: [String: Any]) {
		guard let accessToken = payload["accessToken"] as? String else { return nil }
		self.init(accessToken: accessToken)
	}

	var description: String { "NetlifyGrant(accessToken: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What connecting a GitHub account grants: a user token for LPM Vault's
/// GitHub App, which reaches the repositories the app is installed on that
/// the person can reach. It expires after eight hours and renews through the
/// Registry. Tokens never appear when the grant is printed, logged or dumped.
struct GitHubGrant: PlatformGrant, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	static let platform = BrowserPlatform.github

	let tokens: PlatformTokens
	/// The app's slug, whose page installs it on more accounts and repositories.
	let appSlug: String

	init?(tokens: PlatformTokens, appSlug: String) {
		guard GitHubHTTP.isValidAppSlug(appSlug) else { return nil }
		self.tokens = tokens
		self.appSlug = appSlug
	}

	init?(payload: [String: Any]) {
		guard let tokens = PlatformTokens(payload: payload), let appSlug = payload["appSlug"] as? String else { return nil }
		self.init(tokens: tokens, appSlug: appSlug)
	}

	var description: String { "GitHubGrant(app: \(appSlug), tokens: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["appSlug": appSlug]) }
}
