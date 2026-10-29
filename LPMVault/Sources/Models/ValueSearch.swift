import CryptoKit
import Foundation
import os

/// A key in one environment of one project: a place a value is stored.
struct ValueLocation: Hashable, Sendable {
	let projectID: String
	let environment: String
	let key: String
}

/// An account whose projects a search reads, named as the account menu names it.
struct ValueSearchAccount: Hashable, Sendable {
	let account: SelectedAccount
	let name: String
}

/// A place as a search's results show it.
struct ValueSearchPlace: Identifiable, Hashable, Sendable {
	let location: ValueLocation
	let projectName: String
	let account: ValueSearchAccount
	/// The environment's position in its project's order, which colors its swatch.
	let environmentIndex: Int

	var id: ValueLocation { location }
}

/// A place that stores the value searched for.
struct ValueSearchHit: Identifiable, Hashable, Sendable {
	enum Match: Hashable, Sendable {
		case exact
		/// A longer value with the value searched for inside it.
		case contains
	}

	let place: ValueSearchPlace
	let match: Match

	var id: ValueLocation { place.location }
}

/// A project a search couldn't read, and why.
struct ValueSearchSkip: Identifiable, Hashable, Sendable {
	enum Reason: Hashable, Sendable {
		/// Its newer data comes from a newer version of LPM.
		case newerVersion
		case damaged
		/// An interrupted change to its newer data couldn't be finished.
		case unfinished
		/// The bundled engine couldn't check its newer data.
		case unchecked
		/// The Keychain couldn't read it.
		case unreadable

		init(_ error: KeychainError) {
			switch error {
			case .companion(.unsupported): self = .newerVersion
			case .companion(.damaged): self = .damaged
			case .companion(.unfinished): self = .unfinished
			case .companion: self = .unchecked
			default: self = .unreadable
			}
		}
	}

	let projectID: String
	let projectName: String
	let account: ValueSearchAccount
	let reason: Reason

	var id: String { projectID }
}

/// One project a search reads.
struct ValueSearchTarget: Sendable {
	let id: String
	let name: String
	let account: ValueSearchAccount
	/// Its environments in the order the sidebar lists them.
	let environments: [String]
	/// Whether the app holds its stored values already, as it holds the
	/// selected project's, which a search borrows at the project's turn
	/// rather than reading them again; the others are read then too.
	var isHeld = false
	/// The folder whose lpm.json says which of its keys are public or secret.
	var folder: String = ""
	/// What its rules say, when the app has read them already.
	var secrecy: ValueSecrecyRules?

	func skip(_ reason: ValueSearchSkip.Reason) -> ValueSearchSkip {
		ValueSearchSkip(projectID: id, projectName: name, account: account, reason: reason)
	}

	/// The project's environments in the sidebar's order, then any the
	/// sidebar didn't know of yet, such as one the CLI just added.
	func environmentOrder(of project: VaultProject) -> [String] {
		let known = environments.filter { project.environments[$0] != nil }
		let listed = Set(known)
		return known + project.environments.keys.filter { !listed.contains($0) }.sorted()
	}
}

/// Lends a search one project's stored values at a time.
protocol ValueSearchSource: Sendable {
	/// Reads the project's stored values without letting macOS ask for
	/// approval and lends them to `body`, which must not keep them. Nil when
	/// the project no longer exists.
	func withValues<T>(of projectID: String, _ body: (VaultProject) -> T) async -> Result<T?, KeychainError>
}

/// Reads through the persistence coordinator, which takes the lock the LPM
/// CLI shares for one project at a time.
struct PersistedValueSearchSource: ValueSearchSource {
	let persistence: VaultPersistenceCoordinator

	func withValues<T>(of projectID: String, _ body: (VaultProject) -> T) async -> Result<T?, KeychainError> {
		await persistence.loadProjectWithoutPrompting(vaultId: projectID).map { $0.map(body) }
	}
}

/// Lends the values the app holds, as it holds the selected project's, from
/// the app at the project's turn, and the others through `others`: a search
/// waiting on one project's read holds no other project's values.
struct HeldValueSearchSource: ValueSearchSource {
	/// The projects whose values the app held as the search began.
	let heldProjectIDs: Set<String>
	/// The values the app holds of a project now, if it still does.
	let held: @MainActor @Sendable (String) -> VaultProject?
	let others: any ValueSearchSource

	func withValues<T>(of projectID: String, _ body: (VaultProject) -> T) async -> Result<T?, KeychainError> {
		if heldProjectIDs.contains(projectID), let project = await held(projectID) { return .success(body(project)) }
		return await others.withValues(of: projectID, body)
	}
}

/// A secret a search borrows for each use, which whoever started the search
/// can take back while the search still holds this: one left waiting on a
/// read then holds nothing to match or link a value with.
final class ValueSearchSecret<Secret: Sendable>: Sendable {
	private let secret: OSAllocatedUnfairLock<Secret?>

	init(_ secret: Secret) {
		self.secret = OSAllocatedUnfairLock(initialState: secret)
	}

	/// Lets the secret go, which zeroes it as its last holder lets it go.
	func revoke() {
		secret.withLock { $0 = nil }
	}

	/// What `body` makes of the secret; nil once it's revoked.
	func borrow<T>(_ body: (Secret) -> T) -> T? {
		secret.withLockUnchecked { $0.map(body) }
	}
}

/// What a value search looks for: values whose bytes are exactly the term's
/// and, when asked, longer values that hold those bytes. Nothing is trimmed
/// or normalized, since two values that look the same can differ.
struct ValueMatcher: Sendable {
	/// The fewest characters a term needs before values that contain it are
	/// found too: a shorter one is inside too many values to mean anything.
	static let minimumContainedCharacters = 8

	private let term: ValueSearchSecret<Term>
	let findsContainingValues: Bool

	/// Nil for an empty term, which matches nothing.
	init?(term: String, findsContainingValues: Bool) {
		guard !term.isEmpty else { return nil }
		let containing = findsContainingValues && Self.allowsContaining(term)
		var bytes = term
		self.term = ValueSearchSecret(bytes.withUTF8 { Term(UnsafeRawBufferPointer($0), findsContainingValues: containing) })
		self.findsContainingValues = containing
	}

	/// Lets the term go: every copy of this matcher matches nothing after.
	func revoke() {
		term.revoke()
	}

	static func allowsContaining(_ term: String) -> Bool {
		term.count >= minimumContainedCharacters
	}

	func match(_ value: String) -> ValueSearchHit.Match? {
		var value = value
		return value.withUTF8 { value in
			term.borrow { $0.match(UnsafeRawBufferPointer(value)) } ?? nil
		}
	}

	/// The term's bytes and, for a search that finds values containing it,
	/// the table that reads each value's bytes once, Knuth–Morris–Pratt:
	/// memmem compares from each start again, which a long repetitive value
	/// makes quadratic. Both are zeroed as the term goes.
	private struct Term: Sendable {
		let bytes: SecretBytes
		/// For each length of the term's start, the length of the longest
		/// shorter start that also ends it, as 32-bit counts.
		let borders: SecretBytes?

		init(_ term: UnsafeRawBufferPointer, findsContainingValues: Bool) {
			bytes = SecretBytes(copying: term)
			borders = findsContainingValues ? Self.borders(of: term) : nil
		}

		func match(_ value: UnsafeRawBufferPointer) -> ValueSearchHit.Match? {
			bytes.withUnsafeBytes { term in
				if value.count == term.count {
					return memcmp(value.baseAddress!, term.baseAddress!, term.count) == 0 ? .exact : nil
				}
				guard let borders, value.count > term.count else { return nil }
				return borders.withUnsafeBytes { Self.contains(term, in: value, borders: $0) } ? .contains : nil
			}
		}

		private static func borders(of term: UnsafeRawBufferPointer) -> SecretBytes {
			let width = MemoryLayout<UInt32>.size
			return SecretBytes(count: term.count * width) { table in
				var length = 0
				var index = 1
				while index < term.count {
					if term[index] == term[length] {
						length += 1
						table.storeBytes(of: UInt32(length), toByteOffset: index * width, as: UInt32.self)
						index += 1
					} else if length > 0 {
						length = Int(table.loadUnaligned(fromByteOffset: (length - 1) * width, as: UInt32.self))
					} else {
						index += 1
					}
				}
			}
		}

		private static func contains(_ term: UnsafeRawBufferPointer, in value: UnsafeRawBufferPointer, borders: UnsafeRawBufferPointer) -> Bool {
			let width = MemoryLayout<UInt32>.size
			var matched = 0
			for byte in value {
				while matched > 0, byte != term[matched] {
					matched = Int(borders.loadUnaligned(fromByteOffset: (matched - 1) * width, as: UInt32.self))
				}
				if byte == term[matched] {
					matched += 1
					if matched == term.count { return true }
				}
			}
			return false
		}
	}
}

/// A value's digest under a key made for one scan and dropped with it, which
/// shows that two values are equal without keeping either. 128 bits of
/// HMAC-SHA256: two different values share a digest with odds far below any
/// scan's size.
struct ValueDigest: Hashable, Sendable {
	let high: UInt64
	let low: UInt64
}

struct ValueDigester: Sendable {
	private let key = ValueSearchSecret(SymmetricKey(size: .bits256))

	/// Nil once the key is revoked.
	func digest(_ value: String) -> ValueDigest? {
		var value = value
		return key.borrow { key in
			let code = value.withUTF8 { HMAC<SHA256>.authenticationCode(for: UnsafeRawBufferPointer($0), using: key) }
			return code.withUnsafeBytes {
				ValueDigest(high: $0.loadUnaligned(as: UInt64.self), low: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
			}
		}
	}

	/// Lets the key go: the digests made with it can't be linked to a value after.
	func revoke() {
		key.revoke()
	}
}

/// Whether a project's keys hold secrets, as its rules and the schema's
/// Secret suggestion say: a public key's value is meant to be seen, a key
/// lpm.json marks secret is secret whatever it holds, and the others are
/// judged by their names and values.
struct ValueSecrecyRules: Sendable {
	static let none = ValueSecrecyRules(overview: nil)

	private let publicKeys: Set<String>
	private let secretKeys: Set<String>
	private let clientPrefixes: [String]

	init(overview: ProjectEnvSchemaOverview?) {
		publicKeys = overview?.publicKeys ?? []
		secretKeys = overview?.secretKeys ?? []
		clientPrefixes = overview?.clientPrefixes ?? []
	}

	func isPublic(_ key: String) -> Bool {
		publicKeys.contains(key) || ProjectEnvSchemaRule.publicPrefix(of: key, clientPrefixes: clientPrefixes) != nil
	}

	/// What the rules alone say of `key`: not secret when it's public, secret
	/// when lpm.json says so, and nil when its name and value decide.
	func ruling(on key: String) -> Bool? {
		if isPublic(key) { return false }
		return secretKeys.contains(key) ? true : nil
	}

	func looksSecret(key: String, value: String) -> Bool {
		guard !value.isEmpty else { return false }
		return ruling(on: key) ?? ProjectEnvSchemaSuggestion.looksSecret(key: key, value: value)
	}

	/// Whether any of `values` stored for `key` looks secret, judged off the
	/// main actor, since the engine may check a value's format. A value
	/// several environments hold is judged once.
	func anyLooksSecret(key: String, values: [String]) async -> Bool {
		var judged: Set<ExactText> = []
		return values.contains { judged.insert(ExactText($0)).inserted && looksSecret(key: key, value: $0) }
	}
}

/// The environments of one key that hold byte for byte the same value,
/// grouped once; each card asks for its own others.
struct SameValueEnvironments {
	static let none = SameValueEnvironments()

	private var groupOf: [String: Int] = [:]
	private var groups: [[String]] = []

	private init() {}

	/// Groups the environments in `order` whose values aren't empty by value.
	init(_ values: [String: String], order: [String]) {
		var groupOfValue: [ExactText: Int] = [:]
		for environment in order {
			guard let value = values[environment], !value.isEmpty else { continue }
			let group = groupOfValue[ExactText(value)] ?? {
				groups.append([])
				groupOfValue[ExactText(value)] = groups.count - 1
				return groups.count - 1
			}()
			groups[group].append(environment)
			groupOf[environment] = group
		}
	}

	/// The other environments, in order, whose value is exactly `environment`'s.
	func others(of environment: String) -> [String] {
		guard let group = groupOf[environment], groups[group].count > 1 else { return [] }
		return groups[group].filter { $0 != environment }
	}
}

/// Values stored in more than one place, without the value.
struct ReusedValueGroup: Identifiable, Hashable, Sendable {
	/// How far apart the places are, from the riskiest.
	enum Span: Int, Comparable, Sendable {
		/// Different projects.
		case projects
		/// Different environments of one project.
		case environments
		/// Different keys in one environment.
		case environment

		static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
	}

	let id: Int
	/// In the sidebar's order of projects and environments, then by key.
	let places: [ValueSearchPlace]
	let span: Span
	/// No place looks secret: a port, a host or a flag that many keys share
	/// for good reason.
	let isConfiguration: Bool
}

/// Where each value a scan read was stored, by digest, holding no value.
/// Places are kept as small indexes, so a scan of many projects stays small.
/// Whether a value looks secret is judged only once a second place holds
/// it, with the value then at hand, since every place holds the same bytes;
/// most values are stored once, and judging one can take the engine.
struct ValueReuseIndex {
	private struct Entry {
		let target: Int32
		let environment: Int32
		let key: Int32
		/// The entry before it with the same digest, or -1.
		let previous: Int32
	}

	/// The places holding one value, newest first, and whether one looks secret.
	private struct Chain {
		var latest: Int32
		var looksSecret = false
	}

	/// A key holding a value, as judged once for each key.
	private struct Judgment: Hashable {
		let digest: ValueDigest
		let key: Int32
	}

	private let digester: ValueDigester
	private var chains: [ValueDigest: Chain] = [:]
	private var entries: [Entry] = []
	private var keys: [String] = []
	private var keyIndexes: [String: Int32] = [:]
	/// Each target's environments in the order its places sort by.
	private var environments: [Int: [String]] = [:]
	private var rules: [Int: ValueSecrecyRules] = [:]
	/// What the Secret suggestion said of each key holding a reused value,
	/// while no place holding it looked secret.
	private var judgments: [Judgment: Bool] = [:]
	/// How many places were judged secret or not.
	private(set) var judgedPlaces = 0

	init(digester: ValueDigester = ValueDigester()) {
		self.digester = digester
	}

	/// Records every non-empty value of `project`, read for `targets[target]`.
	mutating func add(_ project: VaultProject, target: Int, of targets: [ValueSearchTarget], secrecy: ValueSecrecyRules) {
		let order = targets[target].environmentOrder(of: project)
		environments[target] = order
		rules[target] = secrecy
		for (environmentIndex, environment) in order.enumerated() {
			guard let values = project.environments[environment] else { continue }
			for (key, value) in values where !value.isEmpty {
				guard let digest = digester.digest(value) else { return }
				let entry = Entry(target: Int32(target), environment: Int32(environmentIndex), key: intern(key), previous: chains[digest]?.latest ?? -1)
				let index = Int32(entries.count)
				entries.append(entry)
				guard var chain = chains[digest] else {
					chains[digest] = Chain(latest: index)
					continue
				}
				chain.latest = index
				if !chain.looksSecret {
					// The place before was stored alone until now, unjudged.
					if entries[Int(entry.previous)].previous < 0 {
						chain.looksSecret = judge(entries[Int(entry.previous)], holding: value, digest: digest)
					}
					if !chain.looksSecret { chain.looksSecret = judge(entry, holding: value, digest: digest) }
				}
				chains[digest] = chain
			}
		}
	}

	private mutating func judge(_ entry: Entry, holding value: String, digest: ValueDigest) -> Bool {
		judgedPlaces += 1
		let key = keys[Int(entry.key)]
		if let ruling = rules[Int(entry.target)]?.ruling(on: key) { return ruling }
		let judgment = Judgment(digest: digest, key: entry.key)
		if let known = judgments[judgment] { return known }
		let looksSecret = ProjectEnvSchemaSuggestion.looksSecret(key: key, value: value)
		judgments[judgment] = looksSecret
		return looksSecret
	}

	/// The values stored in more than one place, riskiest first: across
	/// projects, then across environments, then within one environment;
	/// larger groups first within each.
	func groups(of targets: [ValueSearchTarget]) -> [ReusedValueGroup] {
		var found: [(span: ReusedValueGroup.Span, members: [Entry], isConfiguration: Bool)] = []
		for chain in chains.values where entries[Int(chain.latest)].previous >= 0 {
			var members: [Entry] = []
			var next = chain.latest
			while next >= 0 {
				let entry = entries[Int(next)]
				members.append(entry)
				next = entry.previous
			}
			members.sort { ($0.target, $0.environment, keys[Int($0.key)]) < ($1.target, $1.environment, keys[Int($1.key)]) }
			let span: ReusedValueGroup.Span = members.contains { $0.target != members[0].target } ? .projects
				: members.contains { $0.environment != members[0].environment } ? .environments : .environment
			found.append((span, members, !chain.looksSecret))
		}
		found.sort { lhs, rhs in
			if lhs.span != rhs.span { return lhs.span < rhs.span }
			if lhs.members.count != rhs.members.count { return lhs.members.count > rhs.members.count }
			let left = lhs.members[0], right = rhs.members[0]
			return (left.target, left.environment, keys[Int(left.key)]) < (right.target, right.environment, keys[Int(right.key)])
		}
		return found.enumerated().map { id, group in
			ReusedValueGroup(id: id, places: group.members.map { place($0, of: targets) }, span: group.span,
				isConfiguration: group.isConfiguration)
		}
	}

	private func place(_ entry: Entry, of targets: [ValueSearchTarget]) -> ValueSearchPlace {
		let target = targets[Int(entry.target)]
		let environment = environments[Int(entry.target)]?[Int(entry.environment)] ?? ""
		return ValueSearchPlace(
			location: ValueLocation(projectID: target.id, environment: environment, key: keys[Int(entry.key)]),
			projectName: target.name, account: target.account, environmentIndex: Int(entry.environment))
	}

	private mutating func intern(_ key: String) -> Int32 {
		if let index = keyIndexes[key] { return index }
		let index = Int32(keys.count)
		keys.append(key)
		keyIndexes[key] = index
		return index
	}
}

/// Reads projects for a search one at a time, letting each project's values
/// go before reading the next.
enum ValueSearchScan {
	/// What one project held of the value searched for.
	enum FindOutcome: Sendable {
		case searched([ValueSearchHit])
		case skipped(ValueSearchSkip)
		/// The project was deleted before the search reached it.
		case gone
	}

	/// What a scan for reused values found.
	struct Reuse: Sendable {
		let groups: [ReusedValueGroup]
		let skips: [ValueSearchSkip]
		/// How many projects' values were read and compared.
		let compared: Int
	}

	/// Compares every stored value of each target with `matcher`, one
	/// target at a time. `report` hears each target's outcome, by its index,
	/// and says whether to go on; a cancelled task stops between targets.
	static func find(
		_ matcher: ValueMatcher, in targets: [ValueSearchTarget], from source: some ValueSearchSource,
		report: @MainActor @Sendable (Int, FindOutcome) -> Bool
	) async {
		for (index, target) in targets.enumerated() {
			guard !Task.isCancelled else { return }
			let result = await source.withValues(of: target.id) { hits(of: matcher, in: $0, target: target) }
			guard !Task.isCancelled else { return }
			let outcome: FindOutcome = switch result {
			case .success(let hits?): .searched(hits)
			case .success(nil): .gone
			case .failure(let error): .skipped(target.skip(ValueSearchSkip.Reason(error)))
			}
			guard await report(index, outcome) else { return }
		}
	}

	/// Records where each stored value of every target is, by a digest made
	/// for this scan, one target at a time, then groups the values stored in
	/// more than one place. `secrecy` reads a target's rules before its
	/// values are read; `digester` holds the scan's key, which whoever started
	/// it can revoke. `progress` hears each target done, by its index, and
	/// says whether to go on; nil when the scan stopped first.
	static func reuse(
		in targets: [ValueSearchTarget], from source: some ValueSearchSource,
		secrecy: @Sendable (ValueSearchTarget) async -> ValueSecrecyRules,
		digester: ValueDigester = ValueDigester(),
		progress: @MainActor @Sendable (Int) -> Bool
	) async -> Reuse? {
		var index = ValueReuseIndex(digester: digester)
		var skips: [ValueSearchSkip] = []
		var compared = 0
		for (position, target) in targets.enumerated() {
			guard !Task.isCancelled else { return nil }
			var rules = target.secrecy ?? .none
			if target.secrecy == nil { rules = await secrecy(target) }
			guard !Task.isCancelled else { return nil }
			let result = await source.withValues(of: target.id) { index.add($0, target: position, of: targets, secrecy: rules) }
			guard !Task.isCancelled else { return nil }
			switch result {
			case .success(_?): compared += 1
			case .success(nil): break
			case .failure(let error): skips.append(target.skip(ValueSearchSkip.Reason(error)))
			}
			guard await progress(position) else { return nil }
		}
		guard !Task.isCancelled else { return nil }
		return Reuse(groups: index.groups(of: targets), skips: skips, compared: compared)
	}

	/// The project's places that hold the value, in its environments' order, then by key.
	static func hits(of matcher: ValueMatcher, in project: VaultProject, target: ValueSearchTarget) -> [ValueSearchHit] {
		var hits: [ValueSearchHit] = []
		for (environmentIndex, environment) in target.environmentOrder(of: project).enumerated() {
			guard let values = project.environments[environment] else { continue }
			var found: [String: ValueSearchHit] = [:]
			for (key, value) in values {
				guard let match = matcher.match(value) else { continue }
				found[key] = ValueSearchHit(place: ValueSearchPlace(
					location: ValueLocation(projectID: target.id, environment: environment, key: key),
					projectName: target.name, account: target.account, environmentIndex: environmentIndex), match: match)
			}
			hits += VaultKeySortOrder.sortedAscending(Array(found.keys)).compactMap { found[$0] }
		}
		return hits
	}
}
