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
			return connections.sorted {
				$0.name.localizedStandardCompare($1.name) == .orderedAscending
					|| ($0.name == $1.name && $0.id < $1.id)
			}
		}.mapError(Self.storeError)
	}

	/// Saves the Vercel grant, replacing any earlier connection to the same account.
	func save(_ grant: VercelGrant, account: VercelAccount, at date: Date) -> Result<PlatformConnection, PlatformConnectionStoreError> {
		Result {
			let connection = PlatformConnection(
				account: .vercel(VercelConnectionAccount(
					installationID: grant.installationID,
					teamID: grant.teamID,
					userID: grant.userID,
					name: account.name,
					slug: account.slug
				)),
				connectedAt: PublishTimestamp.normalized(date)
			)
			guard let data = Self.encode(Record(connection: connection, accessToken: grant.accessToken)) else {
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
		guard case .vercel(let vercel) = record.connection.account,
			VercelGrant(
				accessToken: record.accessToken, installationID: vercel.installationID,
				teamID: vercel.teamID, userID: vercel.userID) != nil,
			isValidName(vercel.name), vercel.slug.map(isValidName) ?? true
		else { return nil }
		let object: [String: Any] = [
			"version": version,
			"platform": "vercel",
			"installationId": vercel.installationID,
			"teamId": vercel.teamID ?? NSNull(),
			"userId": vercel.userID,
			"name": vercel.name,
			"slug": vercel.slug ?? NSNull(),
			"accessToken": record.accessToken,
			"connectedAt": PublishTimestamp.milliseconds(record.connection.connectedAt),
		]
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
			data.count <= maximumRecordBytes
		else { return nil }
		return data
	}

	/// The record in `data`, which must belong under `account`.
	static func decode(_ data: Data, account: String) -> Result<Record, PlatformConnectionStoreError> {
		guard data.count <= maximumRecordBytes,
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let version = object["version"] as? Int
		else { return .failure(.unreadable) }
		guard version <= Self.version else { return .failure(.newerVersion) }
		guard version == Self.version,
			object["platform"] as? String == "vercel",
			let installationID = object["installationId"] as? String,
			let userID = object["userId"] as? String,
			let accessToken = object["accessToken"] as? String,
			let name = object["name"] as? String, isValidName(name),
			let milliseconds = object["connectedAt"] as? Int64,
			(0...PublishTimestamp.maximumMilliseconds).contains(milliseconds),
			let teamID = optionalString(object["teamId"]),
			let slug = optionalString(object["slug"]),
			slug.map(isValidName) ?? true,
			let grant = VercelGrant(accessToken: accessToken, installationID: installationID, teamID: teamID, userID: userID)
		else { return .failure(.unreadable) }
		let connection = PlatformConnection(
			account: .vercel(VercelConnectionAccount(
				installationID: grant.installationID, teamID: grant.teamID, userID: grant.userID, name: name, slug: slug)),
			connectedAt: PublishTimestamp.date(milliseconds: milliseconds)
		)
		guard connection.id == account else { return .failure(.unreadable) }
		return .success(Record(connection: connection, accessToken: grant.accessToken))
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
