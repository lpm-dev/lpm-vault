import Foundation

/// The stored forms of a vault's publish destinations and of this Mac's
/// publish history. Both are versioned JSON bound to their vault. Reading is
/// strict: a record with fields this version doesn't know was written by a
/// newer version, and is reported as such rather than rewritten.
enum PublishingRecords {
	enum DecodingError: Error, Equatable, Sendable {
		case unreadable
		/// A newer LPM Vault wrote the record.
		case newerVersion
	}

	static let version = 1
	static let maximumDestinations = 64
	static let maximumRecordBytes = 1_024 * 1_024

	// MARK: - Destinations

	static func encode(_ destinations: [PublishDestination], vaultID: String) -> Data? {
		let entries = destinations.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
		let json = LPMConfigJSON.object([
			.init(key: "version", value: .number(String(version))),
			.init(key: "vault", value: .string(vaultID)),
			.init(key: "destinations", value: .array(entries.map(Self.json))),
		])
		return try? json.compactData(maximumBytes: maximumRecordBytes)
	}

	static func decodeDestinations(_ data: Data, vaultID: String) -> Result<[PublishDestination], DecodingError> {
		do {
			let entries = try body(of: data, vaultID: vaultID, field: "destinations")
			guard case .array(let items) = entries, items.count <= maximumDestinations else { throw DecodingError.unreadable }
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
			return .success(destinations)
		} catch let error as DecodingError {
			return .failure(error)
		} catch {
			return .failure(.unreadable)
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
		let fields = try Fields(json, ["id", "source", "platform", "target", "excludedKeys", "createdAt", "updatedAt"])
		guard let platform = PublishPlatform(rawValue: try fields.string("platform")) else { throw DecodingError.newerVersion }
		let target: PublishTarget
		switch platform {
		case .vercel:
			let vercel = try Fields(fields.value("target"), ["teamId", "teamName", "projectId", "projectName", "environment"])
			target = .vercel(VercelPublishTarget(
				teamID: try vercel.optionalString("teamId"),
				teamName: try vercel.string("teamName"),
				projectID: try vercel.string("projectId"),
				projectName: try vercel.string("projectName"),
				environment: try vercelEnvironment(vercel.value("environment"))
			))
		}
		guard case .array(let excluded) = try fields.value("excludedKeys") else { throw DecodingError.unreadable }
		var excludedKeys: Set<String> = []
		for key in excluded {
			guard case .string(let name) = key, excludedKeys.insert(name).inserted else { throw DecodingError.unreadable }
		}
		let createdAt = try fields.timestamp("createdAt")
		return PublishDestination(
			id: try fields.uuid("id"),
			sourceEnvironment: try fields.string("source"),
			target: target,
			excludedKeys: excludedKeys,
			createdAt: createdAt,
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

	static func encode(_ history: PublishHistory, vaultID: String) -> Data? {
		let entries = history.entries.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, entry in
			LPMConfigJSON.object([
				.init(key: "destination", value: .string(id.uuidString.lowercased())),
				.init(key: "publishedAt", value: timestamp(entry.publishedAt)),
				.init(key: "keys", value: .array(entry.keys.sorted { $0.key < $1.key }.map { name, key in
					.object([
						.init(key: "key", value: .string(name)),
						.init(key: "fingerprint", value: .string(key.fingerprint.base64EncodedString())),
						.init(key: "publishedAt", value: timestamp(key.publishedAt)),
						.init(key: "remoteId", value: key.remoteID.map(LPMConfigJSON.string) ?? .null),
						.init(key: "remoteUpdatedAt", value: key.remoteUpdatedAt.map(timestamp) ?? .null),
					])
				})),
			])
		}
		let json = LPMConfigJSON.object([
			.init(key: "version", value: .number(String(version))),
			.init(key: "vault", value: .string(vaultID)),
			.init(key: "destinations", value: .array(entries)),
		])
		return try? json.compactData(maximumBytes: maximumRecordBytes)
	}

	static func decodeHistory(_ data: Data, vaultID: String) -> Result<PublishHistory, DecodingError> {
		do {
			guard case .array(let items) = try body(of: data, vaultID: vaultID, field: "destinations"),
				items.count <= maximumDestinations
			else { throw DecodingError.unreadable }
			var entries: [UUID: PublishHistory.Entry] = [:]
			for item in items {
				let fields = try Fields(item, ["destination", "publishedAt", "keys"])
				let id = try fields.uuid("destination")
				guard entries[id] == nil, case .array(let records) = try fields.value("keys"),
					records.count <= PublishHistory.maximumKeysPerEntry
				else { throw DecodingError.unreadable }
				var keys: [String: PublishHistory.Key] = [:]
				for record in records {
					let key = try Fields(record, ["key", "fingerprint", "publishedAt", "remoteId", "remoteUpdatedAt"])
					let name = try key.string("key")
					guard EnvValidation.isValidVariableName(name), keys[name] == nil,
						let fingerprint = Data(base64Encoded: try key.string("fingerprint")),
						fingerprint.count == PublishFingerprint.byteCount
					else { throw DecodingError.unreadable }
					keys[name] = PublishHistory.Key(
						fingerprint: fingerprint,
						publishedAt: try key.timestamp("publishedAt"),
						remoteID: try key.optionalString("remoteId"),
						remoteUpdatedAt: try key.optionalTimestamp("remoteUpdatedAt")
					)
				}
				entries[id] = PublishHistory.Entry(publishedAt: try fields.timestamp("publishedAt"), keys: keys)
			}
			return .success(PublishHistory(entries: entries))
		} catch let error as DecodingError {
			return .failure(error)
		} catch {
			return .failure(.unreadable)
		}
	}

	// MARK: - Fields

	/// The record's `field`, after checking its version and vault.
	private static func body(of data: Data, vaultID: String, field: String) throws -> LPMConfigJSON {
		guard data.count <= maximumRecordBytes else { throw DecodingError.unreadable }
		let json = try LPMConfigJSON(parsing: data, rejectDuplicateKeys: true)
		guard case .number(let raw)? = json["version"], let recordVersion = Int(raw) else { throw DecodingError.unreadable }
		guard recordVersion <= version else { throw DecodingError.newerVersion }
		let fields = try Fields(json, ["version", "vault", field])
		guard recordVersion == version, try fields.string("vault") == vaultID else { throw DecodingError.unreadable }
		return try fields.value(field)
	}

	private static func timestamp(_ date: Date) -> LPMConfigJSON {
		.number(String(PublishTimestamp.milliseconds(date)))
	}

	/// An object's members, when it has exactly the expected ones.
	private struct Fields {
		private let values: [String: LPMConfigJSON]

		init(_ json: LPMConfigJSON, _ keys: Set<String>) throws {
			guard case .object(let members) = json, members.count == keys.count else { throw DecodingError.unreadable }
			var values: [String: LPMConfigJSON] = [:]
			for member in members {
				guard keys.contains(member.key), values.updateValue(member.value, forKey: member.key) == nil else {
					throw DecodingError.unreadable
				}
			}
			self.values = values
		}

		func value(_ key: String) throws -> LPMConfigJSON {
			guard let value = values[key] else { throw DecodingError.unreadable }
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

		func uuid(_ key: String) throws -> UUID {
			let text = try string(key)
			guard let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { throw DecodingError.unreadable }
			return id
		}

		func timestamp(_ key: String) throws -> Date {
			guard case .number(let raw) = try value(key), let milliseconds = Int64(raw), milliseconds >= 0,
				String(milliseconds) == raw
			else { throw DecodingError.unreadable }
			return PublishTimestamp.date(milliseconds: milliseconds)
		}

		func optionalTimestamp(_ key: String) throws -> Date? {
			if case .null = try value(key) { return nil }
			return try timestamp(key)
		}
	}
}
