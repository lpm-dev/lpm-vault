import Foundation

enum PlatformConnectionStoreError: Error, Equatable, Sendable, CustomStringConvertible {
	case keychain(KeychainError)
	/// The connection's record isn't one this version can read.
	case unreadable
	/// A newer LPM Vault saved the connection, so this version leaves it alone.
	case newerVersion
	case notFound
	/// The connection was cancelled before it was saved.
	case cancelled

	var description: String {
		switch self {
		case .keychain(let error): error.description
		case .unreadable: "The platform connection can't be read. Connect it again."
		case .newerVersion: "A newer LPM Vault saved this platform connection."
		case .notFound: "The platform connection was removed."
		case .cancelled: "Connecting was cancelled."
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
	/// Keychain calls block until the security daemon answers, so the store
	/// runs on a queue of its own: blocking on the cooperative pool would hold
	/// up every other task waiting for a thread.
	private let queue = DispatchSerialQueue(label: "dev.lpm.vault.platform-connections", qos: .userInitiated)

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	init(service: any KeychainServiceProtocol) {
		self.service = service
	}

	/// The connections this Mac holds, by platform and name. Records it can't
	/// read are left out; connecting that account again replaces them.
	func connections() -> Result<[PlatformConnection], PlatformConnectionStoreError> {
		listing(at: Date()).map(\.connections)
	}

	/// The connections, as `connections()` lists them, with those whose
	/// token can't be renewed at `date` any more, which must be connected again.
	func listing(at date: Date) -> Result<(connections: [PlatformConnection], expired: Set<PlatformConnection.ID>), PlatformConnectionStoreError> {
		Result {
			var connections: [PlatformConnection] = []
			var expired: Set<PlatformConnection.ID> = []
			for account in try service.appItemAccounts(.platformConnections).get() {
				guard let data = try service.readAppItem(.platformConnections, account: account).get(),
					case .success(let record) = Self.decode(data, account: account)
				else { continue }
				connections.append(record.connection)
				if let refresh = record.refresh, refresh.isRejected || (refresh.attempt == nil && date >= refresh.expiresAt) {
					expired.insert(record.connection.id)
				}
			}
			return (connections.sorted(by: Self.displayOrder), expired)
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

	/// A connection a save wrote, with what it replaced, so the save can be
	/// taken back. The records it holds never appear when it's printed,
	/// logged or dumped.
	struct SavedConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
		let connection: PlatformConnection
		fileprivate let written: Data
		/// The record the save replaced: `.some(nil)` when there was none, and
		/// nil when it couldn't be read.
		fileprivate let replaced: Data??

		var description: String { "SavedConnection(\(connection.id), records: <redacted>)" }
		var debugDescription: String { description }
		var customMirror: Mirror { Mirror(self, children: ["connection": connection]) }
	}

	/// Saves the Vercel grant, replacing any earlier connection to the same account.
	func save(_ grant: VercelGrant, account: VercelAccount, at date: Date) -> Result<PlatformConnection, PlatformConnectionStoreError> {
		saveUndoably(grant, account: account, at: date).map(\.connection)
	}

	/// Saves the Vercel grant as `save` does, keeping what's needed to take the save back.
	func saveUndoably(_ grant: VercelGrant, account: VercelAccount, at date: Date) -> Result<SavedConnection, PlatformConnectionStoreError> {
		saveUndoably(
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

	/// Saves the account with its token, and how the token renews when it
	/// expires, replacing any earlier connection to the same account. Nothing
	/// is saved once the calling task is cancelled, as when the vault locks
	/// while the save waits its turn; one cancelled while the Keychain writes
	/// is taken back.
	func save(
		_ account: PlatformConnection.Account,
		accessToken: String,
		refresh: PlatformTokenRefresh? = nil,
		at date: Date
	) -> Result<PlatformConnection, PlatformConnectionStoreError> {
		saveUndoably(account, accessToken: accessToken, refresh: refresh, at: date).map(\.connection)
	}

	/// Saves the account as `save` does, keeping what's needed to take the
	/// save back, as when the vault locks before the caller can use it.
	func saveUndoably(
		_ account: PlatformConnection.Account,
		accessToken: String,
		refresh: PlatformTokenRefresh? = nil,
		at date: Date
	) -> Result<SavedConnection, PlatformConnectionStoreError> {
		Result {
			guard !Task.isCancelled else { throw PlatformConnectionStoreError.cancelled }
			let connection = PlatformConnection(account: account, connectedAt: PublishTimestamp.normalized(date))
			guard let data = Self.encode(Record(connection: connection, accessToken: accessToken, refresh: refresh)) else {
				throw PlatformConnectionStoreError.unreadable
			}
			// A record the Keychain can't read is still replaced: connecting again is how one is mended.
			let replaced = try? service.readAppItem(.platformConnections, account: connection.id).get()
			try service.writeAppItem(.platformConnections, account: connection.id, data: data).get()
			let saved = SavedConnection(connection: connection, written: data, replaced: replaced)
			guard Task.isCancelled else { return saved }
			try restore(before: saved)
			throw PlatformConnectionStoreError.cancelled
		}.mapError(Self.storeError)
	}

	/// Takes back `saved`, putting back the connection it replaced, unless
	/// the connection was saved again since.
	func undo(_ saved: SavedConnection) -> Result<Void, PlatformConnectionStoreError> {
		Result {
			guard try service.readAppItem(.platformConnections, account: saved.connection.id).get() == saved.written else { return }
			try restore(before: saved)
		}.mapError(Self.storeError)
	}

	/// Puts back the record `saved` replaced, or none. One that couldn't be
	/// read, or written back, is deleted instead, so the saved token never
	/// outlives the save being taken back.
	private func restore(before saved: SavedConnection) throws {
		if case let replaced?? = saved.replaced,
			case .success = service.writeAppItem(.platformConnections, account: saved.connection.id, data: replaced)
		{
			return
		}
		try service.deleteAppItem(.platformConnections, account: saved.connection.id).get()
	}

	/// The connection's record, with its token and how it renews, read when a request needs it.
	func record(for connectionID: PlatformConnection.ID) -> Result<Record, PlatformConnectionStoreError> {
		Result {
			guard let data = try service.readAppItem(.platformConnections, account: connectionID).get() else {
				throw PlatformConnectionStoreError.notFound
			}
			return try Self.decode(data, account: connectionID).get()
		}.mapError(Self.storeError)
	}

	/// Saves `attempt` as the request renewing the connection's `token`,
	/// before it's sent. False when the connection holds another token now, or
	/// already has a request to finish.
	func beginRefresh(
		of connectionID: PlatformConnection.ID,
		token: String,
		attempt: PlatformTokenRefresh.Attempt
	) -> Result<Bool, PlatformConnectionStoreError> {
		update(connectionID) { record in
			guard var refresh = record.refresh, refresh.token == token, refresh.attempt == nil, !refresh.isRejected else { return nil }
			refresh.attempt = attempt
			var record = record
			record.refresh = refresh
			return record
		}
	}

	/// Saves the tokens `attemptID` renewed the connection's token to,
	/// received at `date`. False when the connection no longer waits on that
	/// request, as when it was connected again meanwhile.
	func completeRefresh(
		of connectionID: PlatformConnection.ID,
		attempt attemptID: String,
		with tokens: PlatformTokens,
		at date: Date
	) -> Result<Bool, PlatformConnectionStoreError> {
		update(connectionID) { record in
			guard let refresh = record.refresh, refresh.attempt?.id == attemptID else { return nil }
			return Record(
				connection: record.connection,
				accessToken: tokens.accessToken,
				refresh: tokens.refresh(receivedAt: date, principalID: refresh.principalID))
		}
	}

	/// Marks the connection's token as one that can't be renewed, after the
	/// Registry refused `attemptID`; the platform must be connected again.
	/// False when the connection no longer waits on that request.
	func rejectRefresh(
		of connectionID: PlatformConnection.ID,
		attempt attemptID: String
	) -> Result<Bool, PlatformConnectionStoreError> {
		update(connectionID) { record in
			guard var refresh = record.refresh, refresh.attempt?.id == attemptID else { return nil }
			refresh.attempt = nil
			refresh.isRejected = true
			var record = record
			record.refresh = refresh
			return record
		}
	}

	/// Rewrites the connection's record as `change` makes it; false when
	/// `change` leaves it alone by returning nil.
	private func update(
		_ connectionID: PlatformConnection.ID,
		_ change: (Record) -> Record?
	) -> Result<Bool, PlatformConnectionStoreError> {
		Result {
			guard let data = try service.readAppItem(.platformConnections, account: connectionID).get() else {
				throw PlatformConnectionStoreError.notFound
			}
			guard let changed = change(try Self.decode(data, account: connectionID).get()) else { return false }
			guard let encoded = Self.encode(changed) else { throw PlatformConnectionStoreError.unreadable }
			try service.writeAppItem(.platformConnections, account: connectionID, data: encoded).get()
			return true
		}.mapError(Self.storeError)
	}

	/// Forgets the connection and its token on this Mac.
	func remove(_ connectionID: PlatformConnection.ID) -> Result<Void, PlatformConnectionStoreError> {
		Result { try service.deleteAppItem(.platformConnections, account: connectionID).get() }.mapError(Self.storeError)
	}

	// MARK: - Records

	/// A connection with its token, which never appears when it's printed, logged or dumped.
	struct Record: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
		let connection: PlatformConnection
		let accessToken: String
		/// How the token renews, for a platform whose tokens expire; nil for one that doesn't.
		var refresh: PlatformTokenRefresh?

		init(connection: PlatformConnection, accessToken: String, refresh: PlatformTokenRefresh? = nil) {
			self.connection = connection
			self.accessToken = accessToken
			self.refresh = refresh
		}

		var description: String { "Record(\(connection.id), accessToken: <redacted>)" }
		var debugDescription: String { description }
		var customMirror: Mirror { Mirror(self, children: ["connection": connection]) }
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
		case .netlify(let netlify):
			guard NetlifyHTTP.isValidAccessToken(record.accessToken), NetlifyHTTP.isValidIdentifier(netlify.userID),
				isValidName(netlify.name), netlify.email.map(isValidName) ?? true
			else { return nil }
			object.merge([
				"platform": "netlify",
				"userId": netlify.userID,
				"name": netlify.name,
				"email": netlify.email ?? NSNull(),
			]) { _, new in new }
		case .github(let github):
			guard PlatformTokens.isValidToken(record.accessToken), GitHubHTTP.isValidID(github.userID),
				GitHubHTTP.isValidLogin(github.login), github.name.map(isValidName) ?? true, GitHubHTTP.isValidAppSlug(github.appSlug)
			else { return nil }
			object.merge([
				"platform": "github",
				"userId": github.userID,
				"login": github.login,
				"name": github.name ?? NSNull(),
				"appSlug": github.appSlug,
			]) { _, new in new }
		}
		if let refresh = record.refresh {
			guard BrowserPlatform(record.connection.platform) != nil, let encoded = encode(refresh) else { return nil }
			object["refresh"] = encoded
		}
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
			data.count <= maximumRecordBytes
		else { return nil }
		return data
	}

	private static func encode(_ refresh: PlatformTokenRefresh) -> [String: Any]? {
		guard PlatformTokens.isValidToken(refresh.token), isValidPrincipal(refresh.principalID) else { return nil }
		var attempt: Any = NSNull()
		if let pending = refresh.attempt {
			guard PlatformAuthorizationClient.isCanonicalUUID(pending.id), pending.privateKey != nil else { return nil }
			attempt = [
				"id": pending.id,
				"key": pending.key.base64EncodedString(),
				"startedAt": PublishTimestamp.milliseconds(pending.startedAt),
			]
		}
		return [
			"token": refresh.token,
			"accessTokenExpiresAt": PublishTimestamp.milliseconds(refresh.accessTokenExpiresAt),
			"expiresAt": PublishTimestamp.milliseconds(refresh.expiresAt),
			"obtainedAt": PublishTimestamp.milliseconds(refresh.obtainedAt),
			"principalId": refresh.principalID,
			"rejected": refresh.isRejected,
			"attempt": attempt,
		]
	}

	/// The refresh state in a record, or `.some(nil)` when it has none; nil when it's malformed.
	private static func decodeRefresh(_ value: Any?) -> PlatformTokenRefresh?? {
		guard let value else { return .some(nil) }
		guard let object = value as? [String: Any],
			Set(object.keys) == ["token", "accessTokenExpiresAt", "expiresAt", "obtainedAt", "principalId", "rejected", "attempt"],
			let token = object["token"] as? String, PlatformTokens.isValidToken(token),
			let accessTokenExpiresAt = date(object["accessTokenExpiresAt"]),
			let expiresAt = date(object["expiresAt"]),
			let obtainedAt = date(object["obtainedAt"]),
			let principalID = object["principalId"] as? String, isValidPrincipal(principalID),
			let rejected = object["rejected"] as? NSNumber, CFGetTypeID(rejected) == CFBooleanGetTypeID()
		else { return nil }
		var attempt: PlatformTokenRefresh.Attempt?
		switch object["attempt"] {
		case is NSNull:
			attempt = nil
		case let pending as [String: Any]:
			guard Set(pending.keys) == ["id", "key", "startedAt"],
				let id = pending["id"] as? String, PlatformAuthorizationClient.isCanonicalUUID(id),
				let keyText = pending["key"] as? String, let key = Data(base64Encoded: keyText),
				let startedAt = date(pending["startedAt"])
			else { return nil }
			attempt = PlatformTokenRefresh.Attempt(id: id, key: key, startedAt: startedAt)
			guard attempt?.privateKey != nil else { return nil }
		default:
			return nil
		}
		return .some(PlatformTokenRefresh(
			token: token, accessTokenExpiresAt: accessTokenExpiresAt, expiresAt: expiresAt, obtainedAt: obtainedAt,
			principalID: principalID, attempt: attempt, isRejected: rejected.boolValue))
	}

	private static func date(_ value: Any?) -> Date? {
		guard let milliseconds = value as? Int64, (0...PublishTimestamp.maximumMilliseconds).contains(milliseconds) else { return nil }
		return PublishTimestamp.date(milliseconds: milliseconds)
	}

	/// An LPM account's ID, as the Registry issues it.
	private static func isValidPrincipal(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 128 && text.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
	}

	/// The record in `data`, which must belong under `account`. A platform
	/// this version doesn't know reads as a newer version's record. Names
	/// read back with their direction controls escaped, as they're stored now.
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
		guard case .some(let refresh) = decodeRefresh(object["refresh"]) else { return .failure(.unreadable) }
		let keys = Set(object.keys).subtracting(["refresh"])
		var record: Record
		switch PublishPlatform(rawValue: platform) {
		case .vercel?:
			guard keys == ["version", "platform", "accessToken", "connectedAt", "installationId", "teamId", "userId", "name", "slug"],
				let installationID = object["installationId"] as? String,
				let userID = object["userId"] as? String,
				let name = (object["name"] as? String)?.escapingDirectionControls, isValidName(name),
				let teamID = optionalString(object["teamId"]),
				let slug = optionalString(object["slug"]).map({ $0?.escapingDirectionControls }),
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
			guard keys == ["version", "platform", "accessToken", "connectedAt", "instance", "teamId", "teamName"],
				let origin = object["instance"] as? String, let instance = CoolifyInstance(origin: origin),
				let teamID = object["teamId"] as? String, CoolifyTeam.isValidID(teamID),
				let teamName = (object["teamName"] as? String)?.escapingDirectionControls, isValidName(teamName),
				CoolifyClient.isValidAccessToken(accessToken)
			else { return .failure(.unreadable) }
			record = Record(
				connection: PlatformConnection(
					account: .coolify(CoolifyConnectionAccount(instance: instance, teamID: teamID, teamName: teamName)),
					connectedAt: connectedAt),
				accessToken: accessToken)
		case .netlify?:
			guard keys == ["version", "platform", "accessToken", "connectedAt", "userId", "name", "email"],
				let userID = object["userId"] as? String, NetlifyHTTP.isValidIdentifier(userID),
				let name = (object["name"] as? String)?.escapingDirectionControls, isValidName(name),
				let email = optionalString(object["email"]).map({ $0?.escapingDirectionControls }),
				email.map(isValidName) ?? true,
				NetlifyHTTP.isValidAccessToken(accessToken)
			else { return .failure(.unreadable) }
			record = Record(
				connection: PlatformConnection(
					account: .netlify(NetlifyConnectionAccount(userID: userID, name: name, email: email)),
					connectedAt: connectedAt),
				accessToken: accessToken)
		case .github?:
			guard keys == ["version", "platform", "accessToken", "connectedAt", "userId", "login", "name", "appSlug"],
				let userID = object["userId"] as? String, GitHubHTTP.isValidID(userID),
				let login = object["login"] as? String, GitHubHTTP.isValidLogin(login),
				let name = optionalString(object["name"]).map({ $0?.escapingDirectionControls }),
				name.map(isValidName) ?? true,
				let appSlug = object["appSlug"] as? String, GitHubHTTP.isValidAppSlug(appSlug),
				PlatformTokens.isValidToken(accessToken)
			else { return .failure(.unreadable) }
			record = Record(
				connection: PlatformConnection(
					account: .github(GitHubConnectionAccount(userID: userID, login: login, name: name, appSlug: appSlug)),
					connectedAt: connectedAt),
				accessToken: accessToken)
		case nil:
			return .failure(.newerVersion)
		}
		guard record.connection.id == account else { return .failure(.unreadable) }
		if let refresh {
			guard BrowserPlatform(record.connection.platform) != nil else { return .failure(.unreadable) }
			record.refresh = refresh
		}
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
