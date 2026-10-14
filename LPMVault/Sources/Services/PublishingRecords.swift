import Foundation

/// The stored forms of a vault's publish destinations and of this Mac's
/// history of publishing to each one. Both are versioned JSON bound to their
/// vault, and a history record to its destination. Reading is strict: a
/// record from a newer version, or naming a platform or environment kind this
/// version doesn't know, reads as newer and is never rewritten; anything else
/// unexpected, including unknown fields, reads as unreadable. Encoding refuses
/// whatever reading would reject.
enum PublishingRecords {
	enum DecodingError: Error, Equatable, Sendable {
		case unreadable
		/// A newer LPM Vault wrote the record.
		case newerVersion
	}

	static let version = 1
	static let maximumDestinations = 64
	static let maximumRecordBytes = 1_024 * 1_024
	static let maximumRemoteIDLength = 128

	// MARK: - Destinations

	static func encode(_ destinations: [PublishDestination], vaultID: String) -> Data? {
		guard destinations.count <= maximumDestinations, destinations.allSatisfy({ $0.invalidity == nil }),
			Set(destinations.map(\.id)).count == destinations.count,
			Set(destinations.map(\.target.location)).count == destinations.count
		else { return nil }
		let entries = destinations.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
		let json = LPMConfigJSON.object([
			.init(key: "version", value: .number(String(version))),
			.init(key: "vault", value: .string(vaultID)),
			.init(key: "destinations", value: .array(entries.map(Self.json))),
		])
		return try? json.compactData(maximumBytes: maximumRecordBytes)
	}

	static func decodeDestinations(_ data: Data, vaultID: String) -> Result<[PublishDestination], DecodingError> {
		decoding {
			let fields = try header(of: data, binding: ["vault": vaultID], body: ["destinations"])
			guard case .array(let items) = try fields.value("destinations"), items.count <= maximumDestinations else {
				throw DecodingError.unreadable
			}
			var destinations: [PublishDestination] = []
			var ids: Set<UUID> = []
			var locations: Set<PublishTarget.Location> = []
			for item in items {
				let destination = try Self.destination(item)
				guard destination.invalidity == nil,
					ids.insert(destination.id).inserted,
					locations.insert(destination.target.location).inserted
				else { throw DecodingError.unreadable }
				destinations.append(destination)
			}
			return destinations
		}
	}

	private static func json(_ destination: PublishDestination) -> LPMConfigJSON {
		let target: LPMConfigJSON
		switch destination.target {
		case .vercel(let vercel):
			let environment: [LPMConfigJSON.Member] = switch vercel.environment {
			case .production, .preview, .development:
				[.init(key: "kind", value: .string(vercel.environment.identifier))]
			case .custom(let id, let name):
				[.init(key: "kind", value: .string("custom")), .init(key: "id", value: .string(id)), .init(key: "name", value: .string(name))]
			}
			target = .object([
				.init(key: "teamId", value: vercel.teamID.map(LPMConfigJSON.string) ?? .null),
				.init(key: "accountId", value: .string(vercel.accountID)),
				.init(key: "teamName", value: .string(vercel.teamName)),
				.init(key: "projectId", value: .string(vercel.projectID)),
				.init(key: "projectName", value: .string(vercel.projectName)),
				.init(key: "environment", value: .object(environment)),
			])
		}
		return .object([
			.init(key: "id", value: .string(destination.id.uuidString.lowercased())),
			.init(key: "source", value: .string(destination.sourceEnvironment)),
			.init(key: "platform", value: .string(destination.target.platform.rawValue)),
			.init(key: "target", value: target),
			.init(key: "excludedKeys", value: .array(destination.excludedKeys.sorted().map(LPMConfigJSON.string))),
			.init(key: "createdAt", value: timestamp(destination.createdAt)),
			.init(key: "updatedAt", value: timestamp(destination.updatedAt)),
		])
	}

	private static func destination(_ json: LPMConfigJSON) throws -> PublishDestination {
		guard case .string(let name)? = json["platform"] else { throw DecodingError.unreadable }
		guard let platform = PublishPlatform(rawValue: name) else { throw DecodingError.newerVersion }
		let fields = try Fields(json, ["id", "source", "platform", "target", "excludedKeys", "createdAt", "updatedAt"])
		let target: PublishTarget
		switch platform {
		case .vercel:
			let vercel = try Fields(fields.value("target"), ["teamId", "accountId", "teamName", "projectId", "projectName", "environment"])
			target = .vercel(VercelPublishTarget(
				teamID: try vercel.optionalString("teamId"),
				accountID: try vercel.string("accountId"),
				teamName: try vercel.string("teamName"),
				projectID: try vercel.string("projectId"),
				projectName: try vercel.string("projectName"),
				environment: try vercelEnvironment(vercel.value("environment"))
			))
		}
		guard case .array(let excluded) = try fields.value("excludedKeys"),
			excluded.count <= PublishDestination.maximumExcludedKeys
		else { throw DecodingError.unreadable }
		var excludedKeys: Set<String> = []
		for key in excluded {
			guard case .string(let name) = key, excludedKeys.insert(name).inserted else { throw DecodingError.unreadable }
		}
		return PublishDestination(
			id: try fields.uuid("id"),
			sourceEnvironment: try fields.string("source"),
			target: target,
			excludedKeys: excludedKeys,
			createdAt: try fields.timestamp("createdAt"),
			updatedAt: try fields.timestamp("updatedAt")
		)
	}

	private static func vercelEnvironment(_ json: LPMConfigJSON) throws -> VercelPublishTarget.Environment {
		guard case .string(let kind)? = json["kind"] else { throw DecodingError.unreadable }
		switch kind {
		case "production", "preview", "development":
			_ = try Fields(json, ["kind"])
			return kind == "production" ? .production : kind == "preview" ? .preview : .development
		case "custom":
			let fields = try Fields(json, ["kind", "id", "name"])
			return .custom(id: try fields.string("id"), name: try fields.string("name"))
		default:
			throw DecodingError.newerVersion
		}
	}

	// MARK: - History

	static func encode(_ history: PublishHistory, destination: UUID, vaultID: String) -> Data? {
		guard history.keys.count <= PublishHistory.maximumKeys,
			history.keys.allSatisfy({ isValidRecord(key: $0.key, $0.value) })
		else { return nil }
		let json = LPMConfigJSON.object([
			.init(key: "version", value: .number(String(version))),
			.init(key: "vault", value: .string(vaultID)),
			.init(key: "destination", value: .string(destination.uuidString.lowercased())),
			.init(key: "publishedAt", value: history.publishedAt.map(timestamp) ?? .null),
			.init(key: "keys", value: .array(history.keys.sorted { $0.key < $1.key }.map { name, key in
				.object([
					.init(key: "key", value: .string(name)),
					.init(key: "fingerprint", value: .string(key.fingerprint.base64EncodedString())),
					.init(key: "publishedAt", value: timestamp(key.publishedAt)),
					.init(key: "remoteId", value: key.remoteID.map(LPMConfigJSON.string) ?? .null),
					.init(key: "remoteUpdatedAt", value: key.remoteUpdatedAt.map(timestamp) ?? .null),
					.init(key: "publishedAsSecret", value: .bool(key.publishedAsSecret)),
				])
			})),
		])
		return try? json.compactData(maximumBytes: maximumRecordBytes)
	}

	/// `history` encoded within the record limit, dropping its oldest
	/// records when its key names are too long to fit them all.
	static func encodeFitting(_ history: PublishHistory, destination: UUID, vaultID: String) -> (data: Data, history: PublishHistory)? {
		if let data = encode(history, destination: destination, vaultID: vaultID) { return (data, history) }
		guard history.keys.allSatisfy({ isValidRecord(key: $0.key, $0.value) }) else { return nil }
		var low = 1
		var high = history.keys.count
		var best: (Data, PublishHistory)?
		while low <= high {
			let dropped = (low + high) / 2
			let trimmed = history.droppingOldest(dropped)
			if let data = encode(trimmed, destination: destination, vaultID: vaultID) {
				best = (data, trimmed)
				high = dropped - 1
			} else {
				low = dropped + 1
			}
		}
		return best
	}

	static func decodeHistory(_ data: Data, destination: UUID, vaultID: String) -> Result<PublishHistory, DecodingError> {
		decoding {
			let fields = try header(
				of: data,
				binding: ["vault": vaultID, "destination": destination.uuidString.lowercased()],
				body: ["publishedAt", "keys"]
			)
			guard case .array(let records) = try fields.value("keys"), records.count <= PublishHistory.maximumKeys else {
				throw DecodingError.unreadable
			}
			var keys: [String: PublishHistory.Key] = [:]
			for record in records {
				let fields = try Fields(record, ["key", "fingerprint", "publishedAt", "remoteId", "remoteUpdatedAt", "publishedAsSecret"])
				let name = try fields.string("key")
				guard keys[name] == nil, let fingerprint = Data(base64Encoded: try fields.string("fingerprint")) else {
					throw DecodingError.unreadable
				}
				let key = PublishHistory.Key(
					fingerprint: fingerprint,
					publishedAt: try fields.timestamp("publishedAt"),
					remoteID: try fields.optionalString("remoteId"),
					remoteUpdatedAt: try fields.optionalTimestamp("remoteUpdatedAt"),
					publishedAsSecret: try fields.bool("publishedAsSecret")
				)
				guard isValidRecord(key: name, key) else { throw DecodingError.unreadable }
				keys[name] = key
			}
			return PublishHistory(publishedAt: try fields.optionalTimestamp("publishedAt"), keys: keys)
		}
	}

	private static func isValidRecord(key name: String, _ key: PublishHistory.Key) -> Bool {
		EnvValidation.isValidVariableName(name)
			&& key.fingerprint.count == PublishFingerprint.byteCount
			&& key.remoteID.map { $0.utf8.count <= maximumRemoteIDLength && VercelPublishTarget.isValidIdentifier($0) } ?? true
	}

	// MARK: - Fields

	private static func decoding<T>(_ body: () throws -> T) -> Result<T, DecodingError> {
		do {
			return .success(try body())
		} catch let error as DecodingError {
			return .failure(error)
		} catch {
			return .failure(.unreadable)
		}
	}

	/// The record's fields, after checking its version and that it's bound
	/// to the expected vault and destination.
	private static func header(of data: Data, binding: [String: String], body: Set<String>) throws -> Fields {
		guard data.count <= maximumRecordBytes else { throw DecodingError.unreadable }
		let json = try LPMConfigJSON(parsing: data, rejectDuplicateKeys: true)
		guard case .number(let raw)? = json["version"], !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
			throw DecodingError.unreadable
		}
		guard let recordVersion = Int(raw), recordVersion <= version else { throw DecodingError.newerVersion }
		let fields = try Fields(json, body.union(binding.keys).union(["version"]))
		guard recordVersion == version, String(recordVersion) == raw else { throw DecodingError.unreadable }
		for (field, expected) in binding where !(try fields.string(field)).utf8.elementsEqual(expected.utf8) {
			throw DecodingError.unreadable
		}
		return fields
	}

	private static func timestamp(_ date: Date) -> LPMConfigJSON {
		.number(String(PublishTimestamp.milliseconds(date)))
	}

	/// An object's members, when it has exactly the expected ones. Names are
	/// compared byte for byte, as the parser checks for duplicates.
	private struct Fields {
		private let values: [Data: LPMConfigJSON]

		init(_ json: LPMConfigJSON, _ keys: Set<String>) throws {
			guard case .object(let members) = json, members.count == keys.count else { throw DecodingError.unreadable }
			let expected = Set(keys.map { Data($0.utf8) })
			var values: [Data: LPMConfigJSON] = [:]
			for member in members {
				let name = Data(member.key.utf8)
				guard expected.contains(name), values.updateValue(member.value, forKey: name) == nil else {
					throw DecodingError.unreadable
				}
			}
			self.values = values
		}

		func value(_ key: String) throws -> LPMConfigJSON {
			guard let value = values[Data(key.utf8)] else { throw DecodingError.unreadable }
			return value
		}

		func string(_ key: String) throws -> String {
			guard case .string(let text) = try value(key) else { throw DecodingError.unreadable }
			return text
		}

		func optionalString(_ key: String) throws -> String? {
			if case .null = try value(key) { return nil }
			return try string(key)
		}

		func bool(_ key: String) throws -> Bool {
			guard case .bool(let value) = try value(key) else { throw DecodingError.unreadable }
			return value
		}

		func uuid(_ key: String) throws -> UUID {
			let text = try string(key)
			guard let id = UUID(uuidString: text), id.uuidString.lowercased().utf8.elementsEqual(text.utf8) else {
				throw DecodingError.unreadable
			}
			return id
		}

		func timestamp(_ key: String) throws -> Date {
			guard case .number(let raw) = try value(key), let milliseconds = Int64(raw), milliseconds >= 0,
				milliseconds <= PublishTimestamp.maximumMilliseconds, String(milliseconds) == raw
			else { throw DecodingError.unreadable }
			return PublishTimestamp.date(milliseconds: milliseconds)
		}

		func optionalTimestamp(_ key: String) throws -> Date? {
			if case .null = try value(key) { return nil }
			return try timestamp(key)
		}
	}
}
