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

		/// Whether the platform should store it so its value can't be read back.
		/// Keys without a rule are treated as secrets.
		var publishesAsSecret: Bool { self == .secret || self == .undeclared }
	}

	enum Operation: Equatable, Sendable {
		case add
		case replace(remoteID: String)
	}

	/// How the value compares with what this Mac last published here.
	enum Status: Equatable, Sendable {
		/// This Mac hasn't published the key here.
		case notPublished
		case changedSincePublish(publishedAt: Date)
		case unchangedSincePublish(publishedAt: Date)
		/// Unchanged here, but the platform's variable changed or was replaced since.
		case changedOnPlatform(publishedAt: Date)
		/// Unchanged here, but the platform's variable is gone.
		case removedFromPlatform(publishedAt: Date)
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

		init(id: String, sharedWith: [String] = [], updatedAt: Date?) {
			self.id = id
			self.sharedWith = sharedWith
			self.updatedAt = updatedAt.map(PublishTimestamp.normalized)
		}
	}

	let destination: UUID
	/// In the key table's order.
	let rows: [Row]
	/// Variables only on the platform. A publish leaves them as they are.
	let remoteOnlyCount: Int

	/// - Parameters:
	///   - values: The source environment's stored values.
	///   - check: The source environment's evaluation against the project's rules, when the project has rules.
	///   - remote: The platform's variables that apply to the destination, by key.
	///   - reservedKeys: Names the platform sets itself.
	///   - history: This Mac's last publish to the destination.
	init(
		destination: PublishDestination,
		values: [String: String],
		rules: ProjectEnvSchemaOverview,
		check: ProjectEnvValueCheck.Environment?,
		remote: [String: RemoteVariable],
		reservedKeys: Set<String>,
		history: PublishHistory.Entry?,
		fingerprintKey: SymmetricKey
	) {
		self.destination = destination.id
		rows = VaultKeySortOrder.sortedAscending(values.keys).map { key in
			let value = values[key] ?? ""
			let fingerprint = PublishFingerprint.of(value: value, key: key, destination: destination.id, using: fingerprintKey)
			let remoteVariable = remote[key]
			let status = Self.status(fingerprint: fingerprint, remote: remoteVariable, record: history?.keys[key])
			let problems = check?.problems[key] ?? []
			var holds: [Hold] = []
			if reservedKeys.contains(key) { holds.append(.reserved) }
			if problems.contains(where: { $0.kind == .unusableValue }) { holds.append(.unusableValue) }
			if let shared = remoteVariable?.sharedWith, !shared.isEmpty { holds.append(.sharedWith(shared)) }
			let failures = problems.filter { $0.kind != .unusableValue }
			if !failures.isEmpty { holds.append(.failsRules(failures)) }
			if check?.ignored.contains(key) == true { holds.append(.ignoredByLPM) }
			if destination.excludedKeys.contains(key) { holds.append(.excluded) }
			switch status {
			case .changedOnPlatform, .removedFromPlatform: holds.append(.changedOnPlatform)
			case .unchangedSincePublish: holds.append(.upToDate)
			case .notPublished, .changedSincePublish: break
			}
			return Row(
				key: key,
				kind: Self.kind(of: key, in: rules),
				operation: remoteVariable.map { .replace(remoteID: $0.id) } ?? .add,
				status: status,
				holds: holds,
				fingerprint: fingerprint
			)
		}
		remoteOnlyCount = remote.keys.reduce(0) { count, key in values[key] == nil ? count + 1 : count }
	}

	func row(_ key: String) -> Row? {
		rows.first { $0.key == key }
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

	private static func status(fingerprint: Data, remote: RemoteVariable?, record: PublishHistory.Key?) -> Status {
		guard let record else { return .notPublished }
		guard record.fingerprint == fingerprint else { return .changedSincePublish(publishedAt: record.publishedAt) }
		guard let remote else { return .removedFromPlatform(publishedAt: record.publishedAt) }
		let replaced = record.remoteID.map { $0 != remote.id } ?? false
		let edited = record.remoteUpdatedAt.flatMap { recorded in remote.updatedAt.map { $0 > recorded } } ?? false
		return replaced || edited
			? .changedOnPlatform(publishedAt: record.publishedAt)
			: .unchangedSincePublish(publishedAt: record.publishedAt)
	}
}

extension PublishPlan {
	/// The keys the person chose to publish.
	struct Selection: Equatable, Sendable {
		private(set) var keys: Set<String>

		/// The keys published by default.
		init(defaultsOf plan: PublishPlan) {
			keys = Set(plan.rows.lazy.filter(\.isSelectedByDefault).map(\.key))
		}

		/// Chooses or drops `key`; false when the plan has no publishable row for it.
		/// A row that needs a confirmation should be chosen only once the person gives it.
		@discardableResult
		mutating func set(_ key: String, selected: Bool, in plan: PublishPlan) -> Bool {
			guard let row = plan.row(key), row.isPublishable else { return false }
			if selected { keys.insert(key) } else { keys.remove(key) }
			return true
		}
	}

	struct Summary: Equatable, Sendable {
		var adding = 0
		var replacing = 0
		/// Not chosen because the platform already has the value.
		var upToDate = 0
		/// Not chosen for any other reason.
		var skipped = 0

		var publishing: Int { adding + replacing }
	}

	func summary(of selection: Selection) -> Summary {
		var summary = Summary()
		for row in rows {
			if selection.keys.contains(row.key), row.isPublishable {
				switch row.operation {
				case .add: summary.adding += 1
				case .replace: summary.replacing += 1
				}
			} else if row.holds == [.upToDate] {
				summary.upToDate += 1
			} else {
				summary.skipped += 1
			}
		}
		return summary
	}

	/// One variable a publish sends.
	struct Change: Equatable, Sendable {
		let key: String
		let value: String
		let operation: Operation
		let publishesAsSecret: Bool
		let fingerprint: Data

		/// The history record of this change, once the platform accepted it.
		func published(remoteID: String?, remoteUpdatedAt: Date?) -> PublishHistory.Published {
			PublishHistory.Published(key: key, fingerprint: fingerprint, remoteID: remoteID, remoteUpdatedAt: remoteUpdatedAt)
		}
	}

	/// The values changed after the plan was made; these keys differ from what was reviewed.
	struct StalePlan: Error, Equatable, Sendable {
		let keys: [String]
	}

	/// The variables to send for `selection`, from the current `values`.
	/// Fails when any chosen value differs from the one the plan was made
	/// from, so nothing is sent that the person didn't review.
	func changes(
		for selection: Selection,
		values: [String: String],
		fingerprintKey: SymmetricKey
	) -> Result<[Change], StalePlan> {
		var changes: [Change] = []
		var stale: [String] = []
		for row in rows where selection.keys.contains(row.key) && row.isPublishable {
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
		return stale.isEmpty ? .success(changes) : .failure(StalePlan(keys: stale))
	}

	/// The destination after a publish of `selection`, remembering the
	/// person's choices: a key they left out that would have been published
	/// stays out next time, and a key they chose is no longer left out.
	/// Keys held back for another reason aren't remembered as choices.
	func destination(
		_ destination: PublishDestination,
		afterPublishing selection: Selection,
		at date: Date
	) -> PublishDestination {
		var updated = destination
		for row in rows where row.isPublishable {
			if selection.keys.contains(row.key) {
				updated.excludedKeys.remove(row.key)
			} else if row.isSelectedByDefault {
				updated.excludedKeys.insert(row.key)
			}
		}
		updated.updatedAt = max(destination.updatedAt, PublishTimestamp.normalized(date))
		return updated
	}
}
