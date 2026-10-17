import CryptoKit
import Foundation

/// A platform's access token as a connection's grant or a refresh carries
/// it, with what renews it when it expires. Tokens never appear when it's
/// printed, logged or dumped.
struct PlatformTokens: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	/// What renews an access token that expires.
	struct Expiry: Equatable, Sendable {
		/// How long the access token lasts from when it's issued, in seconds.
		let accessTokenLifetime: Int
		let refreshToken: String
		/// How long the refresh token lasts from when it's issued, in seconds.
		let refreshTokenLifetime: Int
	}

	let accessToken: String
	/// Nil for a token that doesn't expire.
	let expiry: Expiry?

	static let maximumTokenBytes = 4_096
	/// The longest lifetime, in seconds, a platform's token is believed to have.
	static let maximumLifetime = 400 * 24 * 60 * 60

	init?(accessToken: String, expiry: Expiry?) {
		guard Self.isValidToken(accessToken) else { return nil }
		if let expiry {
			guard Self.isValidToken(expiry.refreshToken), expiry.refreshToken != accessToken,
				Self.isLifetime(expiry.accessTokenLifetime), Self.isLifetime(expiry.refreshTokenLifetime)
			else { return nil }
		}
		self.accessToken = accessToken
		self.expiry = expiry
	}

	/// The tokens `payload` carries, as the Registry seals them: the access
	/// token alone, or with all of `accessTokenExpiresIn`, `refreshToken` and
	/// `refreshTokenExpiresIn`. Nil for anything else.
	init?(payload: [String: Any]) {
		guard let accessToken = payload["accessToken"] as? String else { return nil }
		let fields = ["accessTokenExpiresIn", "refreshToken", "refreshTokenExpiresIn"]
		switch fields.filter({ payload[$0] != nil }).count {
		case 0:
			self.init(accessToken: accessToken, expiry: nil)
		case fields.count:
			guard let accessLifetime = Self.integer(payload["accessTokenExpiresIn"]),
				let refreshToken = payload["refreshToken"] as? String,
				let refreshLifetime = Self.integer(payload["refreshTokenExpiresIn"])
			else { return nil }
			self.init(
				accessToken: accessToken,
				expiry: Expiry(accessTokenLifetime: accessLifetime, refreshToken: refreshToken, refreshTokenLifetime: refreshLifetime))
		default:
			return nil
		}
	}

	/// Printable ASCII without spaces, as the Registry checks before sealing a token.
	static func isValidToken(_ token: String) -> Bool {
		!token.isEmpty && token.utf8.count <= maximumTokenBytes && token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
	}

	private static func isLifetime(_ seconds: Int) -> Bool {
		seconds > 0 && seconds <= maximumLifetime
	}

	/// A JSON integer, never a Boolean or a fraction.
	static func integer(_ value: Any?) -> Int? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
			let integer = Int(exactly: number.doubleValue)
		else { return nil }
		return integer
	}

	/// What renews these tokens on this Mac, received at `date` for the LPM
	/// account `principalID`; nil for a token that doesn't expire.
	func refresh(receivedAt date: Date, principalID: String) -> PlatformTokenRefresh? {
		expiry.map { expiry in
			PlatformTokenRefresh(
				token: expiry.refreshToken,
				accessTokenExpiresAt: date.addingTimeInterval(TimeInterval(expiry.accessTokenLifetime)),
				expiresAt: date.addingTimeInterval(TimeInterval(expiry.refreshTokenLifetime)),
				obtainedAt: date,
				principalID: principalID)
		}
	}

	var description: String { "PlatformTokens(expires: \(expiry != nil), tokens: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["expires": expiry != nil]) }
}

/// How a connection's expiring access token is renewed, kept with the token
/// in this Mac's Keychain. Renewing goes through the Registry, which refreshes
/// a token only for the LPM account it was issued to. Tokens and keys never
/// appear when it's printed, logged or dumped.
struct PlatformTokenRefresh: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	/// One request to renew the token, saved before it's sent: the platform
	/// replaces the refresh token as soon as it's used, so a request whose
	/// answer was lost is sent again, and its result opens with the same key.
	struct Attempt: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
		/// A lowercase UUID naming the attempt to the Registry.
		let id: String
		/// The P-256 private key the result is sealed to, raw.
		let key: Data
		let startedAt: Date

		static func make(at date: Date) -> Attempt {
			Attempt(
				id: UUID().uuidString.lowercased(),
				key: P256.KeyAgreement.PrivateKey().rawRepresentation,
				startedAt: PublishTimestamp.normalized(date))
		}

		var privateKey: P256.KeyAgreement.PrivateKey? {
			try? P256.KeyAgreement.PrivateKey(rawRepresentation: key)
		}

		var description: String { "Attempt(\(id), key: <redacted>)" }
		var debugDescription: String { description }
		var customMirror: Mirror { Mirror(self, children: ["id": id, "startedAt": startedAt]) }
	}

	let token: String
	let accessTokenExpiresAt: Date
	/// When the refresh token itself expires.
	let expiresAt: Date
	/// When the access token was received, so a clock set back is noticed.
	let obtainedAt: Date
	/// The LPM account the connection was made with, which alone can renew it.
	let principalID: String
	/// A request that may have renewed the token; it's finished before the token is used.
	var attempt: Attempt?
	/// The Registry refused to renew the token, so the platform must be connected again.
	var isRejected = false

	/// How long before it expires an access token is renewed, so a review and
	/// the publish after it don't outlive it.
	static let renewalMargin: TimeInterval = 10 * 60

	init(token: String, accessTokenExpiresAt: Date, expiresAt: Date, obtainedAt: Date, principalID: String, attempt: Attempt? = nil, isRejected: Bool = false) {
		self.token = token
		self.accessTokenExpiresAt = PublishTimestamp.normalized(accessTokenExpiresAt)
		self.expiresAt = PublishTimestamp.normalized(expiresAt)
		self.obtainedAt = PublishTimestamp.normalized(obtainedAt)
		self.principalID = principalID
		self.attempt = attempt
		self.isRejected = isRejected
	}

	/// Whether the access token must be renewed before it's used at `date`:
	/// it's about to expire, the clock went back since it was received, or a
	/// request that may already have replaced it hasn't been finished.
	func isDue(at date: Date) -> Bool {
		attempt != nil || date < obtainedAt || date >= accessTokenExpiresAt.addingTimeInterval(-Self.renewalMargin)
	}

	var description: String {
		"PlatformTokenRefresh(expires: \(accessTokenExpiresAt), attempt: \(attempt?.id ?? "none"), rejected: \(isRejected), token: <redacted>)"
	}
	var debugDescription: String { description }
	var customMirror: Mirror {
		Mirror(self, children: [
			"accessTokenExpiresAt": accessTokenExpiresAt, "expiresAt": expiresAt, "attempt": attempt?.id as Any, "isRejected": isRejected,
		])
	}
}
