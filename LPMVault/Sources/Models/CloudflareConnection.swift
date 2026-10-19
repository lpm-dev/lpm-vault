import CryptoKit
import Foundation

/// The Registry whose OAuth client issued a connection's tokens, which alone
/// can renew or revoke them. It's kept as this closed value, never as an
/// address, and a request goes only to the Registry the app is signed in to,
/// so nothing stored can send a token anywhere else.
enum PlatformIssuer: String, CaseIterable, Sendable {
	case production
	/// LPM's local Registry, which only debug builds reach. Release builds
	/// read it, so what it issued waits rather than reading as damaged.
	case development
}

/// LPM Vault's OAuth client at Cloudflare, which the Registry runs.
enum CloudflareOAuth {
	/// The production client's ID, which the Registry checks in too. Until
	/// it's set, Cloudflare can't be connected through lpm.dev.
	static let productionClientID: String? = nil
	/// The scopes LPM Vault asks for, in the order the Registry sends them.
	static let scope = "offline_access memberships.read workers-scripts.write"
	/// The issuer Cloudflare's userinfo names.
	static let issuer = "https://dash.cloudflare.com"
	static let authorizeURL = URL(string: "https://dash.cloudflare.com/oauth2/auth")!
	static let userInfoURL = URL(string: "https://dash.cloudflare.com/oauth2/userinfo")!

	/// A client ID as the Registry accepts one: letters, digits, `_` and `-`.
	static func isValidClientID(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 128
			&& text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }
	}

	/// Whether a connection through `issuer` may use the client `clientID`:
	/// lpm.dev runs only the production client, and no other Registry runs it.
	/// Only debug builds use the local Registry's client.
	static func accepts(_ clientID: String, for issuer: PlatformIssuer, productionClientID: String? = productionClientID) -> Bool {
		guard isValidClientID(clientID) else { return false }
		switch issuer {
		case .production:
			return clientID == productionClientID
		case .development:
			#if DEBUG
				return clientID != productionClientID
			#else
				return false
			#endif
		}
	}

	/// Whether Cloudflare can be connected through `issuer`.
	static func isAvailable(through issuer: PlatformIssuer, productionClientID: String? = productionClientID) -> Bool {
		switch issuer {
		case .production:
			return productionClientID != nil
		case .development:
			#if DEBUG
				return true
			#else
				return false
			#endif
		}
	}
}

/// A Cloudflare account a login reaches, as Cloudflare named it when it was read.
struct CloudflareAccount: Hashable, Sendable {
	/// Cloudflare's ID for the account: 32 lowercase hexadecimal digits.
	let id: String
	/// The account's name, as `ProviderName.display` shows it.
	let name: String

	static let maximumCount = 256
}

/// A Cloudflare login that approved LPM Vault, with the accounts it chose
/// to let LPM Vault reach. Cloudflare has no name for a login that LPM Vault
/// can read, so it's known by a local label.
struct CloudflareConnectionAccount: Hashable, Sendable {
	/// The login's key; see `CloudflareLogin.key(subject:)`.
	let login: String
	/// The login's label, unique among connected logins.
	let label: String
	/// The accounts it reaches, by name.
	let accounts: [CloudflareAccount]
	/// The Registry that issued its tokens.
	let issuer: PlatformIssuer
	/// The OAuth client its tokens belong to.
	let clientID: String
	/// One approval's tokens, as they renew: connecting again starts another
	/// generation, and a cleanup entry retires one.
	let generation: String

	/// Whether the login reaches the account with this ID.
	func reaches(_ accountID: String) -> Bool {
		accounts.contains { $0.id == accountID }
	}

	/// The accounts it reaches, shortly: "Acme", "Acme and Beta", or "Acme and 2 more".
	var accountsSummary: String {
		switch accounts.count {
		case 0: "No accounts"
		case 1: accounts[0].name
		case 2: "\(accounts[0].name) and \(accounts[1].name)"
		default: "\(accounts[0].name) and \(accounts.count - 1) more"
		}
	}

	/// A generation's ID, as a new approval gets one.
	static func makeGeneration() -> String {
		UUID().uuidString.lowercased()
	}
}

/// How LPM Vault knows a Cloudflare login without keeping Cloudflare's ID
/// for it, and the local label it shows the login by.
enum CloudflareLogin {
	private static let keyDomain = "lpm-vault:cloudflare-login:v1"
	private static let labelDomain = "lpm-vault:cloudflare-login-label:v1"
	/// Crockford's base32, which leaves out I, L, O and U, so no two characters read alike.
	private static let codeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
	static let codeLength = 4
	/// The longest label a person gives a login, in characters.
	static let maximumLabelCharacters = 64

	/// A `sub` as LPM Vault accepts one: 1 to 255 printable ASCII characters.
	static func isValidSubject(_ subject: String) -> Bool {
		!subject.isEmpty && subject.utf8.count <= 255 && subject.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
	}

	/// The login's key: the SHA-256 of its `sub` under a domain label, in
	/// lowercase hexadecimal. The `sub` itself is never kept.
	static func key(subject: String) -> String {
		hex(SHA256.hash(data: Data(keyDomain.utf8) + [0] + Data(subject.utf8)))
	}

	static func isValidKey(_ text: String) -> Bool {
		text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
	}

	/// The code a default label ends in: `length` characters of a digest of
	/// the login's key under this install's salt, so it shows nothing of the
	/// `sub`, and two installs give one login different codes.
	static func code(for login: String, salt: Data, length: Int = codeLength) -> String {
		let mac = HMAC<SHA256>.authenticationCode(for: Data(labelDomain.utf8) + [0] + Data(login.utf8), using: SymmetricKey(data: salt))
		var bits = 0
		var value = 0
		var code = ""
		for byte in mac {
			value = (value << 8) | Int(byte)
			bits += 8
			while bits >= 5, code.count < length {
				bits -= 5
				code.append(codeAlphabet[(value >> bits) & 31])
			}
			value &= (1 << bits) - 1
			if code.count == length { break }
		}
		return code
	}

	/// The label a new login gets: its first account's name and a code,
	/// whose code grows until no label in `taken` matches it.
	static func defaultLabel(for login: String, accounts: [CloudflareAccount], salt: Data, taken: Set<String>) -> String {
		let name = accounts.first?.name ?? "Cloudflare"
		let used = Set(taken.map(comparable))
		// The digest gives 51 characters, far more than unique labels among connected logins ever need.
		for length in codeLength...51 {
			let label = "\(name) · \(code(for: login, salt: salt, length: length))"
			if !used.contains(comparable(label)) { return label }
		}
		return "\(name) · \(code(for: login, salt: salt, length: 51))"
	}

	/// A label a person gave a login, trimmed; nil when it's empty, too long or holds control characters.
	static func label(from text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.count <= maximumLabelCharacters,
			!trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
		else { return nil }
		return trimmed.escapingDirectionControls
	}

	/// Whether two labels would read as one: case and runs of spaces aside.
	static func comparable(_ label: String) -> String {
		label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	private static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
		let digits = Array("0123456789abcdef".utf8)
		var text = [UInt8]()
		for byte in digest {
			text.append(digits[Int(byte >> 4)])
			text.append(digits[Int(byte & 0x0F)])
		}
		return String(decoding: text, as: UTF8.self)
	}
}
