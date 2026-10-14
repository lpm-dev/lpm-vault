import Foundation

enum PlatformConnectionStoreError: Error, Equatable, Sendable, CustomStringConvertible {
	case keychain(KeychainError)
	/// The connection's record isn't one this version can read.
	case unreadable
	/// A newer LPM Vault saved the connection, so this version leaves it alone.
	case newerVersion
	case notFound

	var description: String {
		switch self {
		case .keychain(let error): error.description
		case .unreadable: "The platform connection can't be read. Connect it again."
		case .newerVersion: "A newer LPM Vault saved this platform connection."
		case .notFound: "The platform connection was removed."
		}
	}
}

/// Platform connections and their access tokens, one Keychain item each in
/// the app's own access group, on this Mac only. A connection is never
/// synced: disconnecting forgets the token here and changes nothing on the platform.
actor PlatformConnectionStore {
	private static let version = 1
	private static let maximumRecordBytes = 16 * 1024

	private let service: any KeychainServiceProtocol

	init(service: any KeychainServiceProtocol) {
		self.service = service
	}

	/// The connections this Mac holds, by platform and name. Records it can't
	/// read are left out; connecting that account again replaces them.
	func connections() -> Result<[PlatformConnection], PlatformConnectionStoreError> {
		Result {
			var connections: [PlatformConnection] = []
			for account in try service.appItemAccounts(.platformConnections).get() {
				guard let data = try service.readAppItem(.platformConnections, account: account).get(),
					case .success(let record) = Self.decode(data, account: account)
				else { continue }
				connections.append(record.connection)
			}
			return connections.sorted(by: Self.displayOrder)
		}.mapError(Self.storeError)
	}

	/// By name, then by ID, so connections with the same name keep one order.
	nonisolated static func displayOrder(_ lhs: PlatformConnection, _ rhs: PlatformConnection) -> Bool {
		switch lhs.name.localizedStandardCompare(rhs.name) {
		case .orderedAscending: true
		case .orderedDescending: false
		case .orderedSame: lhs.id < rhs.id
		}
	}

	/// Saves the Vercel grant, replacing any earlier connection to the same account.
	func save(_ grant: VercelGrant, account: VercelAccount, at date: Date) -> Result<PlatformConnection, PlatformConnectionStoreError> {
		save(
			.vercel(VercelConnectionAccount(
				installationID: grant.installationID,
				teamID: grant.teamID,
				userID: grant.userID,
				name: account.name,
				slug: account.slug
			)),
			accessToken: grant.accessToken,
			at: date
		)
	}

	/// Saves the account with its token, replacing any earlier connection to the same account.
	func save(_ account: PlatformConnection.Account, accessToken: String, at date: Date) -> Result<PlatformConnection, PlatformConnectionStoreError> {
		Result {
			let connection = PlatformConnection(account: account, connectedAt: PublishTimestamp.normalized(date))
			guard let data = Self.encode(Record(connection: connection, accessToken: accessToken)) else {
				throw PlatformConnectionStoreError.unreadable
			}
			try service.writeAppItem(.platformConnections, account: connection.id, data: data).get()
			return connection
		}.mapError(Self.storeError)
	}

	/// The connection's access token, read when a request needs it.
	func accessToken(for connectionID: PlatformConnection.ID) -> Result<String, PlatformConnectionStoreError> {
		Result {
			guard let data = try service.readAppItem(.platformConnections, account: connectionID).get() else {
				throw PlatformConnectionStoreError.notFound
			}
			return try Self.decode(data, account: connectionID).get().accessToken
		}.mapError(Self.storeError)
	}

	/// Forgets the connection and its token on this Mac.
	func remove(_ connectionID: PlatformConnection.ID) -> Result<Void, PlatformConnectionStoreError> {
		Result { try service.deleteAppItem(.platformConnections, account: connectionID).get() }.mapError(Self.storeError)
	}

	// MARK: - Records

	struct Record: Equatable, Sendable {
		let connection: PlatformConnection
		let accessToken: String
	}

	static func encode(_ record: Record) -> Data? {
		var object: [String: Any] = [
			"version": version,
			"accessToken": record.accessToken,
			"connectedAt": PublishTimestamp.milliseconds(record.connection.connectedAt),
		]
		switch record.connection.account {
		case .vercel(let vercel):
			guard VercelGrant(
				accessToken: record.accessToken, installationID: vercel.installationID,
				teamID: vercel.teamID, userID: vercel.userID) != nil,
				isValidName(vercel.name), vercel.slug.map(isValidName) ?? true
			else { return nil }
			object.merge([
				"platform": "vercel",
				"installationId": vercel.installationID,
				"teamId": vercel.teamID ?? NSNull(),
				"userId": vercel.userID,
				"name": vercel.name,
				"slug": vercel.slug ?? NSNull(),
			]) { _, new in new }
		case .coolify(let coolify):
			guard CoolifyClient.isValidAccessToken(record.accessToken), CoolifyTeam.isValidID(coolify.teamID),
				isValidName(coolify.teamName)
			else { return nil }
			object.merge([
				"platform": "coolify",
				"instance": coolify.instance.origin,
				"teamId": coolify.teamID,
				"teamName": coolify.teamName,
			]) { _, new in new }
		}
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
			data.count <= maximumRecordBytes
		else { return nil }
		return data
	}

	/// The record in `data`, which must belong under `account`. A platform
	/// this version doesn't know reads as a newer version's record.
	static func decode(_ data: Data, account: String) -> Result<Record, PlatformConnectionStoreError> {
		guard data.count <= maximumRecordBytes,
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let version = object["version"] as? Int
		else { return .failure(.unreadable) }
		guard version <= Self.version else { return .failure(.newerVersion) }
		guard version == Self.version,
			let platform = object["platform"] as? String,
			let accessToken = object["accessToken"] as? String,
			let milliseconds = object["connectedAt"] as? Int64,
			(0...PublishTimestamp.maximumMilliseconds).contains(milliseconds)
		else { return .failure(.unreadable) }
		let connectedAt = PublishTimestamp.date(milliseconds: milliseconds)
		let record: Record
		switch PublishPlatform(rawValue: platform) {
		case .vercel?:
			guard Set(object.keys) == ["version", "platform", "accessToken", "connectedAt", "installationId", "teamId", "userId", "name", "slug"],
				let installationID = object["installationId"] as? String,
				let userID = object["userId"] as? String,
				let name = object["name"] as? String, isValidName(name),
				let teamID = optionalString(object["teamId"]),
				let slug = optionalString(object["slug"]),
				slug.map(isValidName) ?? true,
				let grant = VercelGrant(accessToken: accessToken, installationID: installationID, teamID: teamID, userID: userID)
			else { return .failure(.unreadable) }
			record = Record(
				connection: PlatformConnection(
					account: .vercel(VercelConnectionAccount(
						installationID: grant.installationID, teamID: grant.teamID, userID: grant.userID, name: name, slug: slug)),
					connectedAt: connectedAt),
				accessToken: grant.accessToken)
		case .coolify?:
			guard Set(object.keys) == ["version", "platform", "accessToken", "connectedAt", "instance", "teamId", "teamName"],
				let origin = object["instance"] as? String, let instance = CoolifyInstance(origin: origin),
				let teamID = object["teamId"] as? String, CoolifyTeam.isValidID(teamID),
				let teamName = object["teamName"] as? String, isValidName(teamName),
				CoolifyClient.isValidAccessToken(accessToken)
			else { return .failure(.unreadable) }
			record = Record(
				connection: PlatformConnection(
					account: .coolify(CoolifyConnectionAccount(instance: instance, teamID: teamID, teamName: teamName)),
					connectedAt: connectedAt),
				accessToken: accessToken)
		case nil:
			return .failure(.newerVersion)
		}
		guard record.connection.id == account else { return .failure(.unreadable) }
		return .success(record)
	}

	/// A present string, or `.some(nil)` for an explicit null; nil when it's neither.
	private static func optionalString(_ value: Any?) -> String?? {
		switch value {
		case is NSNull: .some(nil)
		case let text as String: .some(text)
		default: nil
		}
	}

	private static func isValidName(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 512 && text.trimmingCharacters(in: .whitespacesAndNewlines) == text
			&& !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
	}

	private static func storeError(_ error: Error) -> PlatformConnectionStoreError {
		switch error {
		case let error as PlatformConnectionStoreError: error
		case let error as KeychainError: .keychain(error)
		default: .unreadable
		}
	}
}
