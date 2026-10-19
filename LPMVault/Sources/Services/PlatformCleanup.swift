import Foundation

/// A connection's tokens LPM Vault is revoking, as when it was disconnected
/// or replaced, or a new grant it won't keep. Writing the entry retires the
/// generation: its record is never listed, read or renewed again, so a crash
/// at any step resumes at launch. The tokens and the attempt's key never
/// appear when it's printed, logged or dumped.
struct PlatformCleanupEntry: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let platform: BrowserPlatform
	/// The connection the generation is, or would have been, installed under.
	let connectionID: PlatformConnection.ID
	let generation: String
	/// The Registry that issued the tokens, which alone can revoke them.
	let issuer: PlatformIssuer
	/// The OAuth client the tokens belong to.
	let clientID: String
	/// Names every request revoking these tokens, so each answer is bound to this cleanup.
	let revocationID: String
	/// The generation's latest refresh token, which ends its tokens when it's revoked.
	var refreshToken: String
	/// A renewal of the generation that may have been sent. Its key collects
	/// the tokens it issued, which are revoked in turn.
	var attempt: PlatformTokenRefresh.Attempt?
	/// LPM's eligibility for the login's tokens ended, rather than the person
	/// retiring it: once they're revoked, the login stays, as one to reconnect.
	let asksToReconnect: Bool
	let createdAt: Date

	init(
		platform: BrowserPlatform,
		connectionID: PlatformConnection.ID,
		generation: String,
		issuer: PlatformIssuer,
		clientID: String,
		revocationID: String = UUID().uuidString.lowercased(),
		refreshToken: String,
		attempt: PlatformTokenRefresh.Attempt?,
		asksToReconnect: Bool = false,
		createdAt: Date
	) {
		self.platform = platform
		self.connectionID = connectionID
		self.generation = generation
		self.issuer = issuer
		self.clientID = clientID
		self.revocationID = revocationID
		self.refreshToken = refreshToken
		self.attempt = attempt
		self.asksToReconnect = asksToReconnect
		self.createdAt = PublishTimestamp.normalized(createdAt)
	}

	var description: String { "PlatformCleanupEntry(\(platform.rawValue), \(generation), attempt: \(attempt?.id ?? "none"), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror {
		Mirror(self, children: ["platform": platform, "generation": generation, "issuer": issuer, "attempt": attempt?.id as Any])
	}
}

/// What's left of a cleanup whose revocation couldn't be confirmed, kept
/// until the person dismisses it: the connection may still be authorized on
/// the platform. It holds nothing that names or reaches the connection.
struct PlatformCleanupMarker: Equatable, Sendable, Identifiable {
	let platform: BrowserPlatform
	let generation: String
	let createdAt: Date

	var id: String { generation }

	init(platform: BrowserPlatform, generation: String, createdAt: Date) {
		self.platform = platform
		self.generation = generation
		self.createdAt = PublishTimestamp.normalized(createdAt)
	}
}

/// The stored forms of cleanup entries and markers, read strictly: anything
/// unexpected, unknown fields included, reads as unreadable, and a newer
/// version's record as newer.
enum PlatformCleanupRecords {
	enum DecodingError: Error, Equatable, Sendable {
		case unreadable
		case newerVersion
	}

	static let version = 1
	static let maximumBytes = 8 * 1024
	static let entryPrefix = "entry."
	static let markerPrefix = "marker."
	static let labelSaltAccount = "login-label-salt.v1"

	static func entryAccount(_ generation: String) -> String { entryPrefix + generation }
	static func markerAccount(_ generation: String) -> String { markerPrefix + generation }

	/// The generation an entry's or marker's account names; nil for another account.
	static func generation(ofAccount account: String, prefix: String) -> String? {
		guard account.hasPrefix(prefix) else { return nil }
		let generation = String(account.dropFirst(prefix.count))
		return PlatformAuthorizationClient.isCanonicalUUID(generation) ? generation : nil
	}

	static func encode(_ entry: PlatformCleanupEntry) -> Data? {
		guard entry.platform == .cloudflare,
			PlatformAuthorizationClient.isCanonicalUUID(entry.generation),
			PlatformAuthorizationClient.isCanonicalUUID(entry.revocationID),
			CloudflareOAuth.isValidClientID(entry.clientID),
			PlatformTokens.isValidToken(entry.refreshToken),
			!entry.connectionID.isEmpty, entry.connectionID.utf8.count <= 256
		else { return nil }
		var attempt: Any = NSNull()
		if let pending = entry.attempt {
			guard PlatformAuthorizationClient.isCanonicalUUID(pending.id), pending.privateKey != nil else { return nil }
			attempt = ["id": pending.id, "key": pending.key.base64EncodedString(), "startedAt": PublishTimestamp.milliseconds(pending.startedAt)]
		}
		let object: [String: Any] = [
			"version": version,
			"kind": "entry",
			"platform": entry.platform.rawValue,
			"connectionId": entry.connectionID,
			"generation": entry.generation,
			"issuer": entry.issuer.rawValue,
			"clientId": entry.clientID,
			"revocationId": entry.revocationID,
			"refreshToken": entry.refreshToken,
			"attempt": attempt,
			"asksToReconnect": entry.asksToReconnect,
			"createdAt": PublishTimestamp.milliseconds(entry.createdAt),
		]
		return bounded(object)
	}

	/// The entry in `data`, which must be stored under the account of its generation.
	static func decodeEntry(_ data: Data, generation expected: String) -> Result<PlatformCleanupEntry, DecodingError> {
		guard let object = header(data, kind: "entry") else { return .failure(.unreadable) }
		if let newer = newer(object) { return .failure(newer) }
		guard Set(object.keys) == [
			"version", "kind", "platform", "connectionId", "generation", "issuer", "clientId", "revocationId", "refreshToken", "attempt",
			"asksToReconnect", "createdAt",
		],
			let asksToReconnect = object["asksToReconnect"] as? NSNumber, CFGetTypeID(asksToReconnect) == CFBooleanGetTypeID(),
			object["platform"] as? String == BrowserPlatform.cloudflare.rawValue,
			let connectionID = object["connectionId"] as? String, !connectionID.isEmpty, connectionID.utf8.count <= 256,
			let generation = object["generation"] as? String, generation == expected,
			let clientID = object["clientId"] as? String, CloudflareOAuth.isValidClientID(clientID),
			let revocationID = object["revocationId"] as? String, PlatformAuthorizationClient.isCanonicalUUID(revocationID),
			let refreshToken = object["refreshToken"] as? String, PlatformTokens.isValidToken(refreshToken),
			let createdAt = date(object["createdAt"])
		else { return .failure(.unreadable) }
		// An issuer this version doesn't know is a newer version's: the entry waits for it.
		guard let issuerName = object["issuer"] as? String else { return .failure(.unreadable) }
		guard let issuer = PlatformIssuer(rawValue: issuerName) else { return .failure(.newerVersion) }
		var attempt: PlatformTokenRefresh.Attempt?
		switch object["attempt"] {
		case is NSNull:
			attempt = nil
		case let pending as [String: Any]:
			guard Set(pending.keys) == ["id", "key", "startedAt"],
				let id = pending["id"] as? String, PlatformAuthorizationClient.isCanonicalUUID(id),
				let keyText = pending["key"] as? String, let key = Data(base64Encoded: keyText),
				let startedAt = date(pending["startedAt"])
			else { return .failure(.unreadable) }
			attempt = PlatformTokenRefresh.Attempt(id: id, key: key, startedAt: startedAt)
			guard attempt?.privateKey != nil else { return .failure(.unreadable) }
		default:
			return .failure(.unreadable)
		}
		return .success(PlatformCleanupEntry(
			platform: .cloudflare, connectionID: connectionID, generation: generation, issuer: issuer, clientID: clientID,
			revocationID: revocationID, refreshToken: refreshToken, attempt: attempt, asksToReconnect: asksToReconnect.boolValue,
			createdAt: createdAt))
	}

	static func encode(_ marker: PlatformCleanupMarker) -> Data? {
		guard PlatformAuthorizationClient.isCanonicalUUID(marker.generation) else { return nil }
		return bounded([
			"version": version,
			"kind": "marker",
			"platform": marker.platform.rawValue,
			"generation": marker.generation,
			"createdAt": PublishTimestamp.milliseconds(marker.createdAt),
		])
	}

	static func decodeMarker(_ data: Data, generation expected: String) -> Result<PlatformCleanupMarker, DecodingError> {
		guard let object = header(data, kind: "marker") else { return .failure(.unreadable) }
		if let newer = newer(object) { return .failure(newer) }
		guard Set(object.keys) == ["version", "kind", "platform", "generation", "createdAt"],
			let platformName = object["platform"] as? String, let platform = BrowserPlatform(rawValue: platformName),
			let generation = object["generation"] as? String, generation == expected,
			let createdAt = date(object["createdAt"])
		else { return .failure(.unreadable) }
		return .success(PlatformCleanupMarker(platform: platform, generation: generation, createdAt: createdAt))
	}

	/// The object in `data` when it's a bounded record of `kind`; its version isn't checked yet.
	private static func header(_ data: Data, kind: String) -> [String: Any]? {
		guard data.count <= maximumBytes,
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			PlatformTokens.integer(object["version"]) != nil, object["kind"] as? String == kind
		else { return nil }
		return object
	}

	/// Why a record isn't this version's; nil when it is.
	private static func newer(_ object: [String: Any]) -> DecodingError? {
		guard let recordVersion = PlatformTokens.integer(object["version"]) else { return .unreadable }
		if recordVersion > version { return .newerVersion }
		return recordVersion == version ? nil : .unreadable
	}

	private static func bounded(_ object: [String: Any]) -> Data? {
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count <= maximumBytes else {
			return nil
		}
		return data
	}

	private static func date(_ value: Any?) -> Date? {
		guard let milliseconds = PlatformTokens.integer(value).map(Int64.init), (0...PublishTimestamp.maximumMilliseconds).contains(milliseconds)
		else { return nil }
		return PublishTimestamp.date(milliseconds: milliseconds)
	}
}
