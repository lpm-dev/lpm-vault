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
		/// No process can receive the value, so it can't be published.
		case unusableValue
		/// The platform's variable also applies to these environments, so
		/// publishing changes them too.
		case sharedWith([String])
		/// The value fails the project's rules.
		case failsRules([ProjectEnvValueCheck.Problem])
		/// The LPM CLI never passes it to a process.
		case ignoredByLPM
		/// The person left it out of this destination before.
		case excluded
		/// Someone changed or removed it on the platform since this Mac published it.
		case changedOnPlatform
		/// The platform already has the value this Mac published.
		case upToDate
	}

	struct Row: Equatable, Sendable, Identifiable {
		let key: String
		let kind: Kind
		let operation: Operation
		let status: Status
		/// Why it isn't published by default, most important first; empty when it is.
		let holds: [Hold]
		/// The fingerprint of the value the row was planned from.
		let fingerprint: Data

		var id: String { key }
		var isSelectedByDefault: Bool { holds.isEmpty }
		/// False for names the platform reserves and values no process can receive.
		var isPublishable: Bool { !holds.contains(.reserved) && !holds.contains(.unusableValue) }
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
		let updatedAt: Date?
		/// Whether the platform stores it so its value can't be read back; nil when it doesn't say.
		let storedAsSecret: Bool?

		init(id: String, sharedWith: [String] = [], updatedAt: Date?, storedAsSecret: Bool? = nil) {
			self.id = id
			self.sharedWith = sharedWith
			self.updatedAt = updatedAt.map(PublishTimestamp.normalized)
			self.storedAsSecret = storedAsSecret
		}
	}

	/// Tells this plan apart from any other, so a selection can't be used with another plan.
	let id = UUID()
	let destination: UUID
	/// Where the destination published when the plan was made.
	let location: PublishTarget.Location
	/// In the key table's order.
	let rows: [Row]
	/// Variables only on the platform. A publish leaves them as they are.
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
	///   - reservedKeys: Names the platform sets itself.
	///   - history: This Mac's history of publishing to the destination.
	init(
		destination: PublishDestination,
		values: [String: String],
		rules: ProjectEnvSchemaOverview,
		check: ProjectEnvValueCheck.Environment?,
		remote: [String: RemoteVariable],
		reservedKeys: Set<String>,
		history: PublishHistory?,
		fingerprintKey: SymmetricKey
	) {
		self.destination = destination.id
		location = destination.target.location
		rows = VaultKeySortOrder.sortedAscending(values.keys).map { key in
			let value = values[key] ?? ""
			let fingerprint = PublishFingerprint.of(value: value, key: key, destination: destination.id, using: fingerprintKey)
			let remoteVariable = remote[key]
			let kind = Self.kind(of: key, in: rules)
			let status = Self.status(
				fingerprint: fingerprint, publishesAsSecret: kind.publishesAsSecret, remote: remoteVariable, record: history?.keys[key])
			let problems = check?.problems[key] ?? []
			var holds: [Hold] = []
			if reservedKeys.contains(key) { holds.append(.reserved) }
			// A process environment can't carry NUL, whether or not the project has rules to check.
			if value.utf8.contains(0) || problems.contains(where: { $0.kind == .unusableValue }) {
				holds.append(.unusableValue)
			}
			if let shared = remoteVariable?.sharedWith, !shared.isEmpty { holds.append(.sharedWith(shared)) }
			let failures = problems.filter { $0.kind != .unusableValue }
			if !failures.isEmpty { holds.append(.failsRules(failures)) }
			if check?.ignored.contains(key) == true { holds.append(.ignoredByLPM) }
			if destination.excludedKeys.contains(key) { holds.append(.excluded) }
			if status.platform != .unchanged { holds.append(.changedOnPlatform) }
			if status.isUpToDate { holds.append(.upToDate) }
			return Row(
				key: key,
				kind: kind,
				operation: remoteVariable.map { .replace(remoteID: $0.id) } ?? .add,
				status: status,
				holds: holds,
				fingerprint: fingerprint
			)
		}
		rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.key, $0) })
		remoteOnlyCount = remote.keys.reduce(0) { count, key in values[key] == nil ? count + 1 : count }
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
	/// doesn't hide that someone also changed or removed it there. How the
	/// platform stores the key comes from the platform when it says, else
	/// from this Mac's last publish.
	private static func status(
		fingerprint: Data,
		publishesAsSecret: Bool,
		remote: RemoteVariable?,
		record: PublishHistory.Key?
	) -> Status {
		guard let record else { return .notPublished }
		let platform: Status.Platform
		if let remote {
			let replaced = record.remoteID.map { $0 != remote.id } ?? false
			let edited = record.remoteUpdatedAt.flatMap { recorded in remote.updatedAt.map { $0 > recorded } } ?? false
			platform = replaced || edited ? .changed : .unchanged
		} else {
			platform = .removed
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
				publishesAsSecret: row.kind.publishesAsSecret,
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
