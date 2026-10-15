import CryptoKit
import Foundation

/// What publishing an environment to a destination would do to each of its
/// keys: the Review step's rows. It's worked out from the stored values, the
/// project's rules, the platform's variables and this Mac's history, and
/// holds fingerprints of the values it planned, never the values.
struct PublishPlan: Equatable, Sendable {
	enum Kind: Equatable, Sendable {
		/// The rules mark it secret.
		case secret
		/// The rules declare it, and it is neither secret nor public.
		case config
		/// A client prefix or rule makes it public: it ends up in code sent to browsers.
		case `public`
		/// No rule declares it.
		case undeclared

		/// Whether the platform should store it so its value can't be read
		/// back. Only public keys, whose values reach browsers anyway, are
		/// stored readable; a rule that doesn't say "secret" isn't enough.
		var publishesAsSecret: Bool { self != .public }
	}

	enum Operation: Equatable, Sendable {
		case add
		case replace(remoteID: String)
	}

	/// How the key compares with what this Mac last published here.
	struct Status: Equatable, Sendable {
		enum Platform: Equatable, Sendable {
			case unchanged
			/// The platform's variable was edited or replaced since this Mac published it.
			case changed
			/// The platform's variable is gone since this Mac published it.
			case removed
			/// The platform doesn't say enough to tell whether its variable
			/// changed since this Mac published it, such as when it last changed.
			case unknown
		}

		/// When this Mac last published the key here; nil when it hasn't.
		let publishedAt: Date?
		/// Whether the value differs from the one this Mac published; true when it hasn't published it.
		let valueChanged: Bool
		let platform: Platform
		/// Whether the key should now be stored differently, readable or not,
		/// from how the platform stores it.
		let protectionChanged: Bool

		init(publishedAt: Date?, valueChanged: Bool, platform: Platform, protectionChanged: Bool = false) {
			self.publishedAt = publishedAt
			self.valueChanged = valueChanged
			self.platform = platform
			self.protectionChanged = protectionChanged
		}

		static let notPublished = Status(publishedAt: nil, valueChanged: true, platform: .unchanged)

		/// The platform has the value this Mac published, stored the same way,
		/// and nobody changed it since.
		var isUpToDate: Bool { !valueChanged && !protectionChanged && platform == .unchanged }
	}

	/// A reason a key isn't published unless the person chooses it.
	enum Hold: Equatable, Sendable {
		/// The platform sets this name itself, so it can't be published.
		case reserved
		/// The name is longer than the platform accepts, in bytes.
		case nameTooLong(limit: Int)
		/// The platform doesn't accept the name, as Netlify refuses one that
		/// doesn't start with a letter.
		case nameNotAccepted
		/// No process can receive the value, so it can't be published.
		case unusableValue
		/// The platform would change the value on its way to the app.
		case changesValue(ValueIssue)
		/// The value is longer than the platform accepts, in characters.
		case valueTooLong(limit: Int)
		/// The platform gives every environment the variable's one value, so
		/// the destination can't get a value of its own until the variable
		/// has one per environment there.
		case sameValueEverywhere
		/// The platform doesn't say when its variable last changed, so a
		/// publish can't make sure it isn't overwriting a change made since the review.
		case unknownChangeTime
		/// The platform's variable also applies to these environments, so
		/// publishing changes them too.
		case sharedWith([String])
		/// The platform keeps the variable readable and stores every value of
		/// it that way, so the value would be readable there, though LPM
		/// Vault would store it as a secret.
		case staysReadable
		/// The value fails the project's rules.
		case failsRules([ProjectEnvValueCheck.Problem])
		/// The LPM CLI never passes it to a process.
		case ignoredByLPM
		/// The person left it out of this destination before.
		case excluded
		/// Someone changed or removed it on the platform since this Mac published it.
		case changedOnPlatform
		/// Whether someone changed it on the platform since this Mac published it can't be told.
		case unknownSincePublish
		/// The platform already has the value this Mac published.
		case upToDate

		/// Whether the key can't be published even when the person chooses it.
		var blocksPublishing: Bool {
			switch self {
			case .reserved, .nameTooLong, .nameNotAccepted, .unusableValue, .valueTooLong, .sameValueEverywhere, .unknownChangeTime: true
			case .changesValue(let issue): !issue.allowsPublishing
			case .sharedWith, .staysReadable, .failsRules, .ignoredByLPM, .excluded, .changedOnPlatform, .unknownSincePublish, .upToDate:
				false
			}
		}
	}

	/// Something a platform does to a value before an app receives it.
	enum ValueIssue: Equatable, Sendable {
		/// The quoting ends at a single quote, so the app wouldn't get the value.
		case singleQuote
		/// A backslash at the end escapes the closing quote, so the app wouldn't get the value.
		case trailingBackslash
		/// JSON is passed without quotes, so its line breaks, `$` signs or ` #` would change it.
		case unquotedJSON
		/// It holds a `{{…}}` reference the platform replaces with another value.
		case reference
		/// The spaces and line breaks at its ends are dropped.
		case trimmed

		/// The app still gets the value, changed only in a way the person may want.
		var allowsPublishing: Bool {
			switch self {
			case .reference, .trimmed: true
			case .singleQuote, .trailingBackslash, .unquotedJSON: false
			}
		}
	}

	/// What one platform accepts, and what it does to values on their way to an app.
	struct Platform: Sendable {
		/// Names the platform sets itself.
		var reservedKeys: Set<String> = []
		/// Prefixes of names the platform sets itself.
		var reservedPrefixes: [String] = []
		/// The longest name the platform accepts, in bytes.
		var maximumKeyBytes: Int?
		/// Whether the platform accepts a name, beyond its length.
		var acceptsKey: @Sendable (String) -> Bool = { _ in true }
		/// The longest value the platform accepts, in characters.
		var maximumValueCharacters: Int?
		/// The platform can't make a variable it stores as a secret readable
		/// again, so one stays a secret.
		var secretsStaySecret = false
		/// The platform stores every value of a variable the way it stores the
		/// whole variable, readable or a secret, as Netlify does, so a value a
		/// publish replaces or adds is stored that way too.
		var protectionFollowsVariable = false
		/// What the platform would do to a value, most serious first.
		var valueIssues: @Sendable (String) -> [ValueIssue] = { _ in [] }

		func isReserved(_ key: String) -> Bool {
			reservedKeys.contains(key) || reservedPrefixes.contains { key.hasPrefix($0) }
		}
	}

	struct Row: Equatable, Sendable, Identifiable {
		let key: String
		let kind: Kind
		/// Whether the publish stores it so its value can't be read back.
		let publishesAsSecret: Bool
		/// Its kind says readable, but the platform keeps it a secret, as it
		/// already stores it as one.
		var staysSecret: Bool { publishesAsSecret && !kind.publishesAsSecret }
		let operation: Operation
		let status: Status
		/// Why it isn't published by default, most important first; empty when it is.
		let holds: [Hold]
		/// The fingerprint of the value the row was planned from.
		let fingerprint: Data

		var id: String { key }
		var isSelectedByDefault: Bool { holds.isEmpty }
		/// False for names the platform doesn't accept and values the app wouldn't receive.
		var isPublishable: Bool { !holds.contains(where: \.blocksPublishing) }
		/// Choosing it changes other environments on the platform, so it needs a confirmation.
		var needsConfirmation: Bool {
			holds.contains { if case .sharedWith = $0 { true } else { false } }
		}
	}

	/// A platform variable that applies to the destination.
	struct RemoteVariable: Equatable, Sendable {
		let id: String
		/// The other environments the same variable applies to, for display.
		let sharedWith: [String]
		/// Where the variable applies, as the platform identifies those places,
		/// so a rename doesn't read as a change; compared, never shown.
		let scope: Set<String>
		let updatedAt: Date?
		/// Whether the platform stores it so its value can't be read back; nil when it doesn't say.
		let storedAsSecret: Bool?

		init(id: String, sharedWith: [String] = [], scope: Set<String> = [], updatedAt: Date?, storedAsSecret: Bool? = nil) {
			self.id = id
			self.sharedWith = sharedWith
			self.scope = scope
			self.updatedAt = updatedAt.map(PublishTimestamp.normalized)
			self.storedAsSecret = storedAsSecret
		}
	}

	/// A variable the platform has at the destination's place without a value
	/// of the destination's own, such as a Netlify variable with values for
	/// other deploy contexts only.
	struct RemoteKey: Equatable, Sendable {
		enum Kind: Equatable, Sendable {
			/// Only other environments have values, so a publish adds one for the destination.
			case elsewhere
			/// One value serves every environment, the destination's included.
			case sameValueEverywhere
		}

		let kind: Kind
		/// Whether the platform stores the variable so its values can't be read back.
		let storedAsSecret: Bool
		let updatedAt: Date?

		init(kind: Kind, storedAsSecret: Bool, updatedAt: Date?) {
			self.kind = kind
			self.storedAsSecret = storedAsSecret
			self.updatedAt = updatedAt.map(PublishTimestamp.normalized)
		}
	}

	/// Tells this plan apart from any other, so a selection can't be used with another plan.
	let id = UUID()
	let destination: UUID
	/// Where the destination published when the plan was made.
	let location: PublishTarget.Location
	/// In the key table's order.
	let rows: [Row]
	/// Variables only on the platform that apply to the destination, its own
	/// or one value every environment uses. A publish leaves them as they are.
	let remoteOnlyCount: Int
	/// When the destination the plan was made from last changed.
	let destinationUpdatedAt: Date
	/// Keys the destination left out that the source no longer has.
	let staleExclusions: Set<String>
	/// This Mac's records of keys the source no longer has, by when each was published.
	let staleHistory: [String: Date]
	private let rowIndex: [String: Int]

	/// - Parameters:
	///   - values: The source environment's stored values.
	///   - check: The source environment's evaluation against the project's rules, when the project has rules.
	///   - remote: The platform's variables that apply to the destination, by key.
	///   - remoteKeys: The platform's variables at the destination's place
	///     without a value of the destination's own, by key.
	///   - platform: What the platform accepts.
	///   - history: This Mac's history of publishing to the destination.
	init(
		destination: PublishDestination,
		values: [String: String],
		rules: ProjectEnvSchemaOverview,
		check: ProjectEnvValueCheck.Environment?,
		remote: [String: RemoteVariable],
		remoteKeys: [String: RemoteKey] = [:],
		platform: Platform = Platform(),
		history: PublishHistory?,
		fingerprintKey: SymmetricKey
	) {
		self.destination = destination.id
		location = destination.target.location
		rows = VaultKeySortOrder.sortedAscending(values.keys).map { key in
			let value = values[key] ?? ""
			let fingerprint = PublishFingerprint.of(value: value, key: key, destination: destination.id, using: fingerprintKey)
			let remoteVariable = remote[key]
			let remoteKey = remoteVariable == nil ? remoteKeys[key] : nil
			let kind = Self.kind(of: key, in: rules)
			let variableProtection = platform.protectionFollowsVariable ? remoteVariable?.storedAsSecret ?? remoteKey?.storedAsSecret : nil
			let publishesAsSecret = variableProtection
				?? (kind.publishesAsSecret || (platform.secretsStaySecret && remoteVariable?.storedAsSecret == true))
			let status = Self.status(
				fingerprint: fingerprint, publishesAsSecret: publishesAsSecret, remote: remoteVariable, record: history?.keys[key])
			let problems = check?.problems[key] ?? []
			var holds: [Hold] = []
			if platform.isReserved(key) { holds.append(.reserved) }
			if let limit = platform.maximumKeyBytes, key.utf8.count > limit { holds.append(.nameTooLong(limit: limit)) }
			if !platform.acceptsKey(key) { holds.append(.nameNotAccepted) }
			// A process environment can't carry NUL, whether or not the project has rules to check.
			if value.utf8.contains(0) || problems.contains(where: { $0.kind == .unusableValue }) {
				holds.append(.unusableValue)
			} else {
				holds.append(contentsOf: platform.valueIssues(value).map(Hold.changesValue))
			}
			if let limit = platform.maximumValueCharacters, value.unicodeScalars.count > limit { holds.append(.valueTooLong(limit: limit)) }
			if remoteKey?.kind == .sameValueEverywhere { holds.append(.sameValueEverywhere) }
			if let remoteVariable, remoteVariable.updatedAt == nil { holds.append(.unknownChangeTime) }
			if let shared = remoteVariable?.sharedWith, !shared.isEmpty { holds.append(.sharedWith(shared)) }
			if kind.publishesAsSecret, !publishesAsSecret { holds.append(.staysReadable) }
			let failures = problems.filter { $0.kind != .unusableValue }
			if !failures.isEmpty { holds.append(.failsRules(failures)) }
			if check?.ignored.contains(key) == true { holds.append(.ignoredByLPM) }
			if destination.excludedKeys.contains(key) { holds.append(.excluded) }
			switch status.platform {
			case .changed, .removed: holds.append(.changedOnPlatform)
			case .unknown: holds.append(.unknownSincePublish)
			case .unchanged: break
			}
			if status.isUpToDate { holds.append(.upToDate) }
			return Row(
				key: key,
				kind: kind,
				publishesAsSecret: publishesAsSecret,
				operation: remoteVariable.map { .replace(remoteID: $0.id) } ?? .add,
				status: status,
				holds: holds,
				fingerprint: fingerprint
			)
		}
		rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.key, $0) })
		remoteOnlyCount = remote.keys.reduce(0) { count, key in values[key] == nil ? count + 1 : count }
			+ remoteKeys.reduce(0) { count, entry in entry.value.kind == .sameValueEverywhere && values[entry.key] == nil ? count + 1 : count }
		destinationUpdatedAt = destination.updatedAt
		staleExclusions = destination.excludedKeys.filter { values[$0] == nil }
		staleHistory = history?.keys.filter { values[$0.key] == nil }.mapValues(\.publishedAt) ?? [:]
	}

	func row(_ key: String) -> Row? {
		rowIndex[key].map { rows[$0] }
	}

	private static func kind(of key: String, in rules: ProjectEnvSchemaOverview) -> Kind {
		if rules.publicKeys.contains(key)
			|| ProjectEnvSchemaRule.publicPrefix(of: key, clientPrefixes: rules.clientPrefixes) != nil
		{
			return .public
		}
		if rules.secretKeys.contains(key) { return .secret }
		return rules.declaredKeys.contains(key) ? .config : .undeclared
	}

	/// The platform side is judged on its own, so a value changed here
	/// doesn't hide that someone also changed or removed it there. A variable
	/// counts as unchanged only when its ID and change time are both known
	/// and match this Mac's record. Another ID, or another time, even an
	/// earlier one, counts as changed; an ID or time that isn't known on
	/// either side leaves it unknown. How the platform stores the key comes
	/// from the platform when it says, else from this Mac's last publish.
	private static func status(
		fingerprint: Data,
		publishesAsSecret: Bool,
		remote: RemoteVariable?,
		record: PublishHistory.Key?
	) -> Status {
		guard let record else { return .notPublished }
		let platform: Status.Platform
		switch (remote, record.remoteID) {
		case (nil, _):
			platform = .removed
		case (let remote?, let recordedID?) where recordedID != remote.id:
			platform = .changed
		case (let remote?, _?):
			if let recorded = record.remoteUpdatedAt, let current = remote.updatedAt {
				platform = recorded == current ? .unchanged : .changed
			} else {
				platform = .unknown
			}
		case (_?, nil):
			platform = .unknown
		}
		let storedAsSecret = remote?.storedAsSecret ?? record.publishedAsSecret
		return Status(
			publishedAt: record.publishedAt,
			valueChanged: record.fingerprint != fingerprint,
			platform: platform,
			protectionChanged: storedAsSecret != publishesAsSecret
		)
	}
}

extension PublishPlan {
	/// The keys the person chose to publish, for one plan.
	struct Selection: Equatable, Sendable {
		let planID: UUID
		private(set) var keys: Set<String>

		/// The keys published by default.
		init(defaultsOf plan: PublishPlan) {
			planID = plan.id
			keys = Set(plan.rows.lazy.filter(\.isSelectedByDefault).map(\.key))
		}

		/// Chooses or drops `key`. Choosing fails when the plan can't publish
		/// the key, or when publishing it changes other environments and the
		/// person hasn't confirmed that.
		@discardableResult
		mutating func set(_ key: String, selected: Bool, confirmed: Bool = false, in plan: PublishPlan) -> Bool {
			guard plan.id == planID, let row = plan.row(key) else { return false }
			guard selected else {
				keys.remove(key)
				return true
			}
			guard row.isPublishable, !row.needsConfirmation || confirmed else { return false }
			keys.insert(key)
			return true
		}
	}

	struct Summary: Equatable, Sendable {
		var adding = 0
		var replacing = 0
		/// Not chosen, and the platform already has the value.
		var upToDate = 0
		/// Not chosen for any other reason.
		var skipped = 0

		var publishing: Int { adding + replacing }
	}

	func summary(of selection: Selection) -> Summary {
		var summary = Summary()
		for row in rows {
			if selection.planID == id, selection.keys.contains(row.key) {
				switch row.operation {
				case .add: summary.adding += 1
				case .replace: summary.replacing += 1
				}
			} else if row.status.isUpToDate {
				summary.upToDate += 1
			} else {
				summary.skipped += 1
			}
		}
		return summary
	}

	/// One variable a publish sends. Its value never appears when it's
	/// printed, logged or dumped.
	struct Change: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
		let key: String
		let value: String
		let operation: Operation
		let publishesAsSecret: Bool
		let fingerprint: Data

		/// The history record of this change, once the platform accepted it.
		func published(remoteID: String?, remoteUpdatedAt: Date?) -> PublishHistory.Published {
			PublishHistory.Published(
				key: key, fingerprint: fingerprint, remoteID: remoteID, remoteUpdatedAt: remoteUpdatedAt,
				publishedAsSecret: publishesAsSecret)
		}

		var description: String { "Change(\(key), \(operation), value: <redacted>)" }
		var debugDescription: String { description }
		var customMirror: Mirror {
			Mirror(self, children: ["key": key, "operation": operation, "publishesAsSecret": publishesAsSecret])
		}
	}

	enum ChangesFailure: Error, Equatable, Sendable {
		/// The selection was made for another plan.
		case foreignSelection
		/// These values changed after the plan was made, so they differ from what was reviewed.
		case stale(keys: [String])
	}

	/// The variables to send for `selection`, from the current `values`.
	/// Fails when the selection belongs to another plan, or when any chosen
	/// value differs from the one the plan was made from, so nothing is sent
	/// that the person didn't review.
	func changes(
		for selection: Selection,
		values: [String: String],
		fingerprintKey: SymmetricKey
	) -> Result<[Change], ChangesFailure> {
		guard selection.planID == id else { return .failure(.foreignSelection) }
		var changes: [Change] = []
		var stale: [String] = []
		for row in rows where selection.keys.contains(row.key) {
			guard let value = values[row.key],
				PublishFingerprint.of(value: value, key: row.key, destination: destination, using: fingerprintKey) == row.fingerprint
			else {
				stale.append(row.key)
				continue
			}
			changes.append(Change(
				key: row.key,
				value: value,
				operation: row.operation,
				publishesAsSecret: row.publishesAsSecret,
				fingerprint: row.fingerprint
			))
		}
		return stale.isEmpty ? .success(changes) : .failure(.stale(keys: stale))
	}

	/// The person's choices from a review, applied to the destination and
	/// history as they're stored when the publish is recorded, so changes
	/// made meanwhile, such as a rename or a newer publish, aren't undone.
	struct Choices: Equatable, Sendable {
		/// Keys published by default that the person left out.
		let leftOut: Set<String>
		/// Keys the person chose.
		let chosen: Set<String>
		/// Exclusions of keys the source no longer had, and when the
		/// destination they were read from last changed.
		let staleExclusions: Set<String>
		let destinationUpdatedAt: Date?
		/// Records of keys the source no longer had, by when each was published.
		let staleHistory: [String: Date]

		init(
			leftOut: Set<String>,
			chosen: Set<String>,
			staleExclusions: Set<String> = [],
			destinationUpdatedAt: Date? = nil,
			staleHistory: [String: Date] = [:]
		) {
			self.leftOut = leftOut
			self.chosen = chosen
			self.staleExclusions = staleExclusions
			self.destinationUpdatedAt = destinationUpdatedAt
			self.staleHistory = staleHistory
		}

		/// These choices, as made against the destination saved at `updatedAt`,
		/// as when the publish itself saved the destination it reviewed.
		func made(at updatedAt: Date) -> Choices {
			Choices(
				leftOut: leftOut, chosen: chosen, staleExclusions: staleExclusions,
				destinationUpdatedAt: updatedAt, staleHistory: staleHistory)
		}

		/// A key left out stays out next time, and a chosen key is no longer
		/// left out. Stale exclusions are forgotten only while the destination
		/// is the one the plan saw: a change since, such as a rename onto one
		/// of those names, may have made the exclusion live again.
		func applied(to destination: PublishDestination, at date: Date) -> PublishDestination {
			var excluded = destination.excludedKeys
			if destination.updatedAt == destinationUpdatedAt, PublishTimestamp.identifiesOneWrite(destination.updatedAt) {
				excluded.subtract(staleExclusions)
			}
			excluded.formUnion(leftOut)
			excluded.subtract(chosen)
			guard excluded != destination.excludedKeys else { return destination }
			var updated = destination
			updated.excludedKeys = excluded
			updated.updatedAt = PublishTimestamp.next(after: destination.updatedAt, at: date)
			return updated
		}

		/// The stale records `history` still holds as the plan saw them. A key
		/// published again since has a newer record, which stays.
		func forgottenRecords(in history: PublishHistory) -> Set<String> {
			Set(staleHistory.lazy.filter { key, publishedAt in
				history.keys[key]?.publishedAt == publishedAt && PublishTimestamp.identifiesOneWrite(publishedAt)
			}.map(\.key))
		}
	}

	/// The choices `selection` makes. Keys held back for another reason
	/// aren't remembered as choices.
	func choices(for selection: Selection) -> Choices {
		guard selection.planID == id else { return Choices(leftOut: [], chosen: []) }
		var leftOut: Set<String> = []
		var chosen: Set<String> = []
		for row in rows where row.isPublishable {
			if selection.keys.contains(row.key) {
				chosen.insert(row.key)
			} else if row.isSelectedByDefault {
				leftOut.insert(row.key)
			}
		}
		return Choices(
			leftOut: leftOut,
			chosen: chosen,
			staleExclusions: staleExclusions,
			destinationUpdatedAt: destinationUpdatedAt,
			staleHistory: staleHistory
		)
	}
}
