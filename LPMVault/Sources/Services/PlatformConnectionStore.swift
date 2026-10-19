import CryptoKit
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
	/// LPM Vault is disconnecting or replacing the connection, so its token isn't used any more.
	case retired
	/// Another connected login already has the label.
	case labelTaken

	var description: String {
		switch self {
		case .keychain(let error): error.description
		case .unreadable: "The platform connection can't be read. Connect it again."
		case .newerVersion: "A newer LPM Vault saved this platform connection."
		case .notFound: "The platform connection was removed."
		case .cancelled: "Connecting was cancelled."
		case .retired: "The platform connection is being disconnected."
		case .labelTaken: "Another connected login already has this name."
		}
	}
}

/// Platform connections and their access tokens, one Keychain item each in
/// the app's own access group, on this Mac only. A connection is never
/// synced. Disconnecting forgets the token here; for a Cloudflare login, a
/// cleanup entry first keeps its tokens until the Registry revokes them, and
/// while it does the connection is retired: never listed, read or renewed.
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

	/// What the Platforms page shows of this Mac's connections.
	struct Listing: Equatable, Sendable {
		var connections: [PlatformConnection] = []
		/// Connections whose token can't be renewed any more, which must be connected again.
		var expired: Set<PlatformConnection.ID> = []
		/// Cleanups still revoking a retired connection's tokens.
		var retiring: [PlatformCleanupEntry] = []
		/// Cleanups whose revocation couldn't be confirmed, until they're dismissed.
		var markers: [PlatformCleanupMarker] = []
	}

	/// The connections, as `connections()` lists them, with those whose
	/// token can't be renewed at `date` any more, and the cleanups of retired
	/// ones. Cleanup entries are read first: a connection whose generation
	/// has one is retired, and isn't listed.
	func listing(at date: Date) -> Result<Listing, PlatformConnectionStoreError> {
		Result {
			let cleanup = try readCleanup()
			var listing = Listing(
				retiring: cleanup.entries.compactMap { if case .readable(let entry) = $0 { entry } else { nil } },
				markers: cleanup.markers)
			let retired = Set(cleanup.entries.map(\.generation))
			for account in try service.appItemAccounts(.platformConnections).get() {
				guard let data = try service.readAppItem(.platformConnections, account: account).get(),
					case .success(let record) = Self.decode(data, account: account)
				else { continue }
				if let generation = record.connection.generation, retired.contains(generation) { continue }
				listing.connections.append(record.connection)
				if let refresh = record.refresh, refresh.isRejected || (refresh.attempt == nil && date >= refresh.expiresAt) {
					listing.expired.insert(record.connection.id)
				}
			}
			listing.connections.sort(by: Self.displayOrder)
			listing.retiring.sort { $0.createdAt < $1.createdAt }
			listing.markers.sort { $0.createdAt < $1.createdAt }
			return listing
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

	/// The connection's record, with its token and how it renews, read when
	/// a request needs it. A retired generation's record isn't read.
	func record(for connectionID: PlatformConnection.ID) -> Result<Record, PlatformConnectionStoreError> {
		Result {
			let record = try storedRecord(connectionID)
			if let generation = record.connection.generation, try isRetired(generation) { throw PlatformConnectionStoreError.retired }
			return record
		}.mapError(Self.storeError)
	}

	/// The record as it's stored, retired or not.
	private func storedRecord(_ connectionID: PlatformConnection.ID) throws -> Record {
		guard let data = try service.readAppItem(.platformConnections, account: connectionID).get() else {
			throw PlatformConnectionStoreError.notFound
		}
		return try Self.decode(data, account: connectionID).get()
	}

	/// Whether a cleanup entry retired the generation. An entry that can't be
	/// read retires it as well: its tokens may still be the generation's.
	private func isRetired(_ generation: String) throws -> Bool {
		try service.readAppItem(.platformCleanup, account: PlatformCleanupRecords.entryAccount(generation)).get() != nil
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
	///
	/// With `keepingAttempt`, the attempt's key stays, since the answer left
	/// open whether the platform renewed the token: its cleanup can still
	/// collect, and revoke, the tokens the attempt may have issued.
	func rejectRefresh(
		of connectionID: PlatformConnection.ID,
		attempt attemptID: String,
		keepingAttempt: Bool = false
	) -> Result<Bool, PlatformConnectionStoreError> {
		update(connectionID) { record in
			guard var refresh = record.refresh, refresh.attempt?.id == attemptID else { return nil }
			if !keepingAttempt { refresh.attempt = nil }
			refresh.isRejected = true
			var record = record
			record.refresh = refresh
			return record
		}
	}

	/// Rewrites the connection's record as `change` makes it; false when
	/// `change` leaves it alone by returning nil. A retired record isn't changed.
	private func update(
		_ connectionID: PlatformConnection.ID,
		_ change: (Record) -> Record?
	) -> Result<Bool, PlatformConnectionStoreError> {
		Result {
			let record = try storedRecord(connectionID)
			if let generation = record.connection.generation, try isRetired(generation) { throw PlatformConnectionStoreError.retired }
			guard let changed = change(record) else { return false }
			guard let encoded = Self.encode(changed) else { throw PlatformConnectionStoreError.unreadable }
			try service.writeAppItem(.platformConnections, account: connectionID, data: encoded).get()
			return true
		}.mapError(Self.storeError)
	}

	/// Forgets the connection and its token on this Mac.
	func remove(_ connectionID: PlatformConnection.ID) -> Result<Void, PlatformConnectionStoreError> {
		Result { try service.deleteAppItem(.platformConnections, account: connectionID).get() }.mapError(Self.storeError)
	}

	/// Gives the Cloudflare login a label the person chose, unique among
	/// connected logins; the connection as it's saved now.
	func relabel(_ connectionID: PlatformConnection.ID, to label: String) -> Result<PlatformConnection, PlatformConnectionStoreError> {
		Result {
			let record = try storedRecord(connectionID)
			guard case .cloudflare(let account) = record.connection.account else { throw PlatformConnectionStoreError.notFound }
			if let generation = record.connection.generation, try isRetired(generation) { throw PlatformConnectionStoreError.retired }
			let wanted = CloudflareLogin.comparable(label)
			if try cloudflareLabels(except: connectionID).contains(where: { CloudflareLogin.comparable($0) == wanted }) {
				throw PlatformConnectionStoreError.labelTaken
			}
			let relabeled = CloudflareConnectionAccount(
				login: account.login, label: label, accounts: account.accounts, issuer: account.issuer, clientID: account.clientID,
				generation: account.generation)
			let changed = Record(
				connection: PlatformConnection(account: .cloudflare(relabeled), connectedAt: record.connection.connectedAt),
				accessToken: record.accessToken, refresh: record.refresh)
			guard let encoded = Self.encode(changed) else { throw PlatformConnectionStoreError.unreadable }
			try service.writeAppItem(.platformConnections, account: connectionID, data: encoded).get()
			return changed.connection
		}.mapError(Self.storeError)
	}

	/// The labels of the Cloudflare logins connected now, but `connectionID`'s.
	/// Retired logins' labels are free again.
	func cloudflareLabels(except connectionID: PlatformConnection.ID? = nil) -> Result<Set<String>, PlatformConnectionStoreError> {
		Result { try cloudflareLabels(except: connectionID) }.mapError(Self.storeError)
	}

	private func cloudflareLabels(except connectionID: PlatformConnection.ID?) throws -> Set<String> {
		var labels: Set<String> = []
		for account in try service.appItemAccounts(.platformConnections).get() where account != connectionID {
			guard account.hasPrefix("cloudflare."),
				let data = try service.readAppItem(.platformConnections, account: account).get(),
				case .success(let record) = Self.decode(data, account: account),
				case .cloudflare(let cloudflare) = record.connection.account,
				try !isRetired(cloudflare.generation)
			else { continue }
			labels.insert(cloudflare.label)
		}
		return labels
	}

	// MARK: - Cleanup

	/// An entry as it's stored: readable, or not, though its account still names its generation.
	enum StoredEntry: Equatable, Sendable {
		case readable(PlatformCleanupEntry)
		/// The entry can't be read, or a newer LPM Vault wrote it; it still retires its generation.
		case unreadable(generation: String, isNewer: Bool)

		var generation: String {
			switch self {
			case .readable(let entry): entry.generation
			case .unreadable(let generation, _): generation
			}
		}
	}

	/// The cleanup entries and markers this Mac holds.
	func cleanup() -> Result<(entries: [StoredEntry], markers: [PlatformCleanupMarker]), PlatformConnectionStoreError> {
		Result { try readCleanup() }.mapError(Self.storeError)
	}

	private func readCleanup() throws -> (entries: [StoredEntry], markers: [PlatformCleanupMarker]) {
		var entries: [StoredEntry] = []
		var markers: [PlatformCleanupMarker] = []
		for account in try service.appItemAccounts(.platformCleanup).get() {
			if let generation = PlatformCleanupRecords.generation(ofAccount: account, prefix: PlatformCleanupRecords.entryPrefix) {
				guard let data = try service.readAppItem(.platformCleanup, account: account).get() else { continue }
				switch PlatformCleanupRecords.decodeEntry(data, generation: generation) {
				case .success(let entry): entries.append(.readable(entry))
				case .failure(.newerVersion): entries.append(.unreadable(generation: generation, isNewer: true))
				case .failure(.unreadable): entries.append(.unreadable(generation: generation, isNewer: false))
				}
			} else if let generation = PlatformCleanupRecords.generation(ofAccount: account, prefix: PlatformCleanupRecords.markerPrefix) {
				guard let data = try service.readAppItem(.platformCleanup, account: account).get(),
					case .success(let marker) = PlatformCleanupRecords.decodeMarker(data, generation: generation)
				else { continue }
				markers.append(marker)
			}
		}
		return (entries, markers)
	}

	/// Writes a cleanup entry for tokens that were never installed, as a new
	/// grant LPM Vault won't keep whose revocation wasn't confirmed.
	func writeCleanup(_ entry: PlatformCleanupEntry) -> Result<Void, PlatformConnectionStoreError> {
		Result {
			guard let data = PlatformCleanupRecords.encode(entry) else { throw PlatformConnectionStoreError.unreadable }
			try service.writeAppItem(.platformCleanup, account: PlatformCleanupRecords.entryAccount(entry.generation), data: data).get()
		}.mapError(Self.storeError)
	}

	/// Retires the connection's `generation` by writing its cleanup entry:
	/// its latest refresh token and any renewal of it that may have been
	/// sent. The entry already written for it when there is one; nil when the
	/// connection holds another generation now, or none.
	func retire(
		_ connectionID: PlatformConnection.ID,
		generation: String,
		at date: Date
	) -> Result<PlatformCleanupEntry?, PlatformConnectionStoreError> {
		Result {
			let account = PlatformCleanupRecords.entryAccount(generation)
			if let data = try service.readAppItem(.platformCleanup, account: account).get(),
				case .success(let existing) = PlatformCleanupRecords.decodeEntry(data, generation: generation)
			{
				return existing
			}
			let record: Record
			do {
				record = try storedRecord(connectionID)
			} catch PlatformConnectionStoreError.notFound {
				return nil
			}
			guard case .cloudflare(let cloudflare) = record.connection.account, cloudflare.generation == generation,
				let refresh = record.refresh
			else { return nil }
			let entry = PlatformCleanupEntry(
				platform: .cloudflare, connectionID: connectionID, generation: generation, issuer: cloudflare.issuer,
				clientID: cloudflare.clientID, refreshToken: refresh.token, attempt: refresh.attempt, createdAt: date)
			guard let data = PlatformCleanupRecords.encode(entry) else { throw PlatformConnectionStoreError.unreadable }
			try service.writeAppItem(.platformCleanup, account: account, data: data).get()
			return entry
		}.mapError(Self.storeError)
	}

	/// Puts the tokens a renewal of the entry's generation issued in place of
	/// the refresh token it renewed, and drops the renewal's key, which they
	/// were collected with. False when the entry isn't stored any more.
	func replaceCleanupToken(
		of generation: String,
		renewedBy attemptID: String,
		with refreshToken: String
	) -> Result<Bool, PlatformConnectionStoreError> {
		Result {
			let account = PlatformCleanupRecords.entryAccount(generation)
			guard let data = try service.readAppItem(.platformCleanup, account: account).get(),
				case .success(var entry) = PlatformCleanupRecords.decodeEntry(data, generation: generation),
				entry.attempt?.id == attemptID
			else { return false }
			entry.refreshToken = refreshToken
			entry.attempt = nil
			guard let encoded = PlatformCleanupRecords.encode(entry) else { throw PlatformConnectionStoreError.unreadable }
			try service.writeAppItem(.platformCleanup, account: account, data: encoded).get()
			return true
		}.mapError(Self.storeError)
	}

	/// Ends the cleanup of `entry`: deletes the connection's record if it
	/// still holds the entry's generation, never a newer one, then the entry.
	/// With `unconfirmed`, a marker takes the entry's place, as the
	/// generation's tokens may still work.
	func finishCleanup(_ entry: PlatformCleanupEntry, unconfirmed: Bool, at date: Date) -> Result<Void, PlatformConnectionStoreError> {
		Result {
			if let data = try service.readAppItem(.platformConnections, account: entry.connectionID).get(),
				case .success(let record) = Self.decode(data, account: entry.connectionID),
				record.connection.generation == entry.generation
			{
				try service.deleteAppItem(.platformConnections, account: entry.connectionID).get()
			}
			if unconfirmed {
				try writeMarker(PlatformCleanupMarker(platform: entry.platform, generation: entry.generation, createdAt: date))
			}
			try service.deleteAppItem(.platformCleanup, account: PlatformCleanupRecords.entryAccount(entry.generation)).get()
		}.mapError(Self.storeError)
	}

	/// Turns an entry that can't be read into a marker: its tokens can't be
	/// revoked, so the connection may still be authorized.
	func abandonCleanup(of generation: String, platform: BrowserPlatform, at date: Date) -> Result<Void, PlatformConnectionStoreError> {
		Result {
			try writeMarker(PlatformCleanupMarker(platform: platform, generation: generation, createdAt: date))
			try service.deleteAppItem(.platformCleanup, account: PlatformCleanupRecords.entryAccount(generation)).get()
		}.mapError(Self.storeError)
	}

	/// Leaves a marker for a connection whose tokens LPM Vault couldn't revoke.
	func mark(_ marker: PlatformCleanupMarker) -> Result<Void, PlatformConnectionStoreError> {
		Result { try writeMarker(marker) }.mapError(Self.storeError)
	}

	private func writeMarker(_ marker: PlatformCleanupMarker) throws {
		guard let data = PlatformCleanupRecords.encode(marker) else { throw PlatformConnectionStoreError.unreadable }
		try service.writeAppItem(.platformCleanup, account: PlatformCleanupRecords.markerAccount(marker.generation), data: data).get()
	}

	/// Forgets a marker the person dismissed.
	func dismissMarker(_ generation: String) -> Result<Void, PlatformConnectionStoreError> {
		Result { try service.deleteAppItem(.platformCleanup, account: PlatformCleanupRecords.markerAccount(generation)).get() }
			.mapError(Self.storeError)
	}

	/// This install's salt for Cloudflare logins' label codes, made the
	/// first time it's needed. The item is always the raw 32 bytes; a damaged
	/// one is replaced, which only changes the codes of labels made after.
	func loginLabelSalt() -> Result<Data, PlatformConnectionStoreError> {
		Result {
			let account = PlatformCleanupRecords.labelSaltAccount
			if let data = try service.readAppItem(.platformCleanup, account: account).get(), data.count == 32 { return data }
			let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
			if try service.insertAppItem(.platformCleanup, account: account, data: salt).get() { return salt }
			if let data = try service.readAppItem(.platformCleanup, account: account).get(), data.count == 32 { return data }
			try service.writeAppItem(.platformCleanup, account: account, data: salt).get()
			return salt
		}.mapError(Self.storeError)
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
		case .cloudflare(let cloudflare):
			// A Cloudflare connection's tokens always expire, and renew only through the Registry that issued them.
			guard PlatformTokens.isValidToken(record.accessToken), record.refresh != nil, isValid(cloudflare) else { return nil }
			object.merge([
				"platform": "cloudflare",
				"login": cloudflare.login,
				"label": cloudflare.label,
				"accounts": cloudflare.accounts.map { ["id": $0.id, "name": $0.name] },
				"issuer": cloudflare.issuer.rawValue,
				"clientId": cloudflare.clientID,
				"generation": cloudflare.generation,
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
		case .cloudflare?:
			switch decodeCloudflare(object, keys: keys) {
			case .success(let cloudflare):
				guard PlatformTokens.isValidToken(accessToken), refresh != nil else { return .failure(.unreadable) }
				record = Record(connection: PlatformConnection(account: .cloudflare(cloudflare), connectedAt: connectedAt), accessToken: accessToken)
			case .failure(let error):
				return .failure(error)
			}
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

	/// A Cloudflare login's fields. An issuer this version doesn't know is a newer version's.
	private static func decodeCloudflare(_ object: [String: Any], keys: Set<String>) -> Result<CloudflareConnectionAccount, PlatformConnectionStoreError> {
		guard keys == ["version", "platform", "accessToken", "connectedAt", "login", "label", "accounts", "issuer", "clientId", "generation"],
			let issuerName = object["issuer"] as? String
		else { return .failure(.unreadable) }
		guard let issuer = PlatformIssuer(rawValue: issuerName) else { return .failure(.newerVersion) }
		guard let login = object["login"] as? String,
			let label = (object["label"] as? String)?.escapingDirectionControls,
			let rawAccounts = object["accounts"] as? [Any], rawAccounts.count <= CloudflareAccount.maximumCount,
			let clientID = object["clientId"] as? String,
			let generation = object["generation"] as? String
		else { return .failure(.unreadable) }
		var accounts: [CloudflareAccount] = []
		for raw in rawAccounts {
			guard let entry = raw as? [String: Any], Set(entry.keys) == ["id", "name"],
				let id = entry["id"] as? String, let name = (entry["name"] as? String)?.escapingDirectionControls
			else { return .failure(.unreadable) }
			accounts.append(CloudflareAccount(id: id, name: name))
		}
		let account = CloudflareConnectionAccount(
			login: login, label: label, accounts: accounts, issuer: issuer, clientID: clientID, generation: generation)
		return isValid(account) ? .success(account) : .failure(.unreadable)
	}

	private static func isValid(_ cloudflare: CloudflareConnectionAccount) -> Bool {
		CloudflareLogin.isValidKey(cloudflare.login) && isValidName(cloudflare.label)
			&& !cloudflare.accounts.isEmpty && cloudflare.accounts.count <= CloudflareAccount.maximumCount
			&& cloudflare.accounts.allSatisfy { CloudflareHTTP.isValidID($0.id) && isValidName($0.name) }
			&& Set(cloudflare.accounts.map(\.id)).count == cloudflare.accounts.count
			&& CloudflareOAuth.isValidClientID(cloudflare.clientID)
			&& PlatformAuthorizationClient.isCanonicalUUID(cloudflare.generation)
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
