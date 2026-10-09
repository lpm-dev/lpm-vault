import Foundation

/// Unsaved changes to the rules a project's root lpm.json declares: its keys,
/// overrides of keys that imported schemas declare, its groups and group
/// overrides, and its client prefixes.
///
/// Each change keeps the item as lpm.json had it when the draft last read the
/// file. When the file changes on disk, the draft merges item by item, and only
/// an item changed both on disk and in the draft conflicts.
struct ProjectEnvSchemaDraft: Equatable, Sendable {
	enum Item: Hashable, Sendable {
		case key(String)
		case group(String)
		case clientPrefixes
	}

	/// Where an item is in the root envSchema, with its JSON.
	enum Declaration: Equatable, Sendable {
		case absent
		/// In `vars` for a key, in `groups` for a group, or the `clientPrefixes` list.
		case declared(LPMConfigJSON)
		/// In `overrides` or `groupOverrides`, which replace an imported
		/// declaration entirely rather than merging with it.
		case overridden(LPMConfigJSON)

		var json: LPMConfigJSON? {
			switch self {
			case .absent: nil
			case .declared(let json), .overridden(let json): json
			}
		}

		func isEquivalent(to other: Declaration) -> Bool {
			switch (self, other) {
			case (.absent, .absent): true
			case (.declared(let a), .declared(let b)), (.overridden(let a), .overridden(let b)): a.isEquivalent(to: b)
			default: false
			}
		}
	}

	struct Change: Equatable, Sendable {
		let item: Item
		/// The item as lpm.json had it when the draft last read the file.
		fileprivate(set) var base: Declaration
		fileprivate(set) var value: Declaration
	}

	/// An item changed both in lpm.json and in the draft since the draft last read the file.
	struct Conflict: Equatable, Sendable {
		let item: Item
		let mine: Declaration
		let theirs: Declaration
	}

	/// What merging the draft onto lpm.json's current rules did.
	struct Rebase: Equatable, Sendable {
		/// Items lpm.json changed since the draft last read it, in file order.
		var changedItems: [Item] = []
		/// lpm.json changed other envSchema fields, such as `extends`.
		var changedOtherFields = false
		/// Items now in conflict.
		var conflicts: [Item] = []

		var isEmpty: Bool { changedItems.isEmpty && !changedOtherFields }
	}

	/// lpm.json's envSchema as the draft last read it; nil when it has none.
	private(set) var schema: LPMConfigJSON?
	/// In the order they were first made.
	private(set) var changes: [Change] = []
	private(set) var conflicts: [Conflict] = []

	init(schema: LPMConfigJSON?) {
		self.schema = schema == .null ? nil : schema
	}

	var isEmpty: Bool { changes.isEmpty && conflicts.isEmpty }

	/// Items with a change or a conflict, in the order they were first changed.
	var changedItems: [Item] { changes.map(\.item) + conflicts.map(\.item) }

	func hasChange(to item: Item) -> Bool {
		changes.contains { $0.item == item } || conflicts.contains { $0.item == item }
	}

	/// The item as lpm.json had it when the draft last read the file.
	func base(of item: Item) -> Declaration {
		Self.declaration(of: item, in: schema)
	}

	/// The item with the draft applied: the draft's version of a conflicting item.
	func declaration(of item: Item) -> Declaration {
		if let change = changes.first(where: { $0.item == item }) { return change.value }
		if let conflict = conflicts.first(where: { $0.item == item }) { return conflict.mine }
		return base(of: item)
	}

	/// Sets an item. A value equivalent to what lpm.json has drops the item's
	/// change, so the file keeps its own member order.
	mutating func set(_ value: Declaration, for item: Item) {
		if let index = conflicts.firstIndex(where: { $0.item == item }) {
			conflicts[index] = Conflict(item: item, mine: value, theirs: conflicts[index].theirs)
			return
		}
		let base = base(of: item)
		if let index = changes.firstIndex(where: { $0.item == item }) {
			if value.isEquivalent(to: base) { changes.remove(at: index) } else { changes[index].value = value }
		} else if !value.isEquivalent(to: base) {
			changes.append(Change(item: item, base: base, value: value))
		}
	}

	mutating func discard(_ item: Item) {
		changes.removeAll { $0.item == item }
		conflicts.removeAll { $0.item == item }
	}

	mutating func discardAll() {
		changes = []
		conflicts = []
	}

	/// Settles a conflict with the draft's version or the one now in lpm.json.
	mutating func resolveConflict(_ item: Item, keepingMine: Bool) {
		guard let index = conflicts.firstIndex(where: { $0.item == item }) else { return }
		let conflict = conflicts.remove(at: index)
		if keepingMine { changes.append(Change(item: item, base: conflict.theirs, value: conflict.mine)) }
	}

	/// Merges the draft onto `schema`, the envSchema lpm.json has now. A change
	/// whose item lpm.json still has as the draft read it stays; one lpm.json
	/// already matches goes away; any other becomes a conflict.
	@discardableResult
	mutating func rebase(onto schema: LPMConfigJSON?) -> Rebase {
		let schema = schema == .null ? nil : schema
		guard schema != self.schema else { return Rebase() }
		var outcome = Rebase(
			changedItems: Self.changedItems(from: self.schema, to: schema),
			changedOtherFields: !Self.otherFields(of: self.schema).isEquivalent(to: Self.otherFields(of: schema))
		)
		var kept: [Change] = []
		var conflicted: [Conflict] = []
		for change in changes {
			let theirs = Self.declaration(of: change.item, in: schema)
			if theirs.isEquivalent(to: change.base) {
				kept.append(Change(item: change.item, base: theirs, value: change.value))
			} else if !theirs.isEquivalent(to: change.value) {
				conflicted.append(Conflict(item: change.item, mine: change.value, theirs: theirs))
			}
		}
		for conflict in conflicts {
			let theirs = Self.declaration(of: conflict.item, in: schema)
			if !theirs.isEquivalent(to: conflict.mine) {
				conflicted.append(Conflict(item: conflict.item, mine: conflict.mine, theirs: theirs))
			}
		}
		changes = kept
		conflicts = conflicted
		self.schema = schema
		outcome.conflicts = conflicted.map(\.item)
		return outcome
	}

	/// `schema` with every change applied: nil when the draft empties an
	/// envSchema that had rules, or adds none to a file without one.
	/// Members keep their place; new ones go last; a container the draft
	/// empties goes away, and one that was already empty stays.
	func applied(to schema: LPMConfigJSON?) throws(ProjectEnvSchemaFile.FileError) -> LPMConfigJSON? {
		let before = schema == .null ? nil : schema
		var result = before ?? .object([])
		guard case .object = result else { throw .invalidSchema }
		for change in changes { try Self.apply(change.value, for: change.item, to: &result) }
		for conflict in conflicts { try Self.apply(conflict.mine, for: conflict.item, to: &result) }
		if result.isEmptyObject, before?.isEmptyObject != true { return nil }
		return result
	}

	// MARK: - Items in a schema

	static func declaration(of item: Item, in schema: LPMConfigJSON?) -> Declaration {
		switch item {
		case .key(let name): declaration(of: name, declaredIn: "vars", overriddenIn: "overrides", schema: schema)
		case .group(let name): declaration(of: name, declaredIn: "groups", overriddenIn: "groupOverrides", schema: schema)
		case .clientPrefixes: schema?["clientPrefixes"].map(Declaration.declared) ?? .absent
		}
	}

	private static func declaration(of name: String, declaredIn declared: String, overriddenIn overridden: String, schema: LPMConfigJSON?) -> Declaration {
		if let json = schema?[declared]?[name] { return .declared(json) }
		if let json = schema?[overridden]?[name] { return .overridden(json) }
		return .absent
	}

	/// Every item `schema` has, in file order: keys, overrides, groups, group
	/// overrides, then client prefixes.
	static func items(in schema: LPMConfigJSON?) -> [(item: Item, declaration: Declaration)] {
		var items: [(item: Item, declaration: Declaration)] = []
		for (field, overridden) in [("vars", false), ("overrides", true), ("groups", false), ("groupOverrides", true)] {
			guard case .object(let members)? = schema?[field] else { continue }
			let isKey = field == "vars" || field == "overrides"
			for member in members {
				items.append((isKey ? .key(member.key) : .group(member.key), overridden ? .overridden(member.value) : .declared(member.value)))
			}
		}
		if let prefixes = schema?["clientPrefixes"] { items.append((.clientPrefixes, .declared(prefixes))) }
		return items
	}

	private static let itemFields: Set<String> = ["vars", "overrides", "groups", "groupOverrides", "clientPrefixes"]

	private static func otherFields(of schema: LPMConfigJSON?) -> LPMConfigJSON {
		guard case .object(let members)? = schema else { return .object([]) }
		return .object(members.filter { !itemFields.contains($0.key) })
	}

	private static func changedItems(from old: LPMConfigJSON?, to new: LPMConfigJSON?) -> [Item] {
		var before = Dictionary(items(in: old).map { ($0.item, $0.declaration) }, uniquingKeysWith: { first, _ in first })
		var changed: [Item] = []
		for (item, declaration) in items(in: new) {
			if let previous = before.removeValue(forKey: item) {
				if !previous.isEquivalent(to: declaration) { changed.append(item) }
			} else if !changed.contains(item) {
				changed.append(item)
			}
		}
		for (item, _) in items(in: old) where before[item] != nil && !changed.contains(item) {
			changed.append(item)
		}
		return changed
	}

	private static func apply(_ value: Declaration, for item: Item, to schema: inout LPMConfigJSON) throws(ProjectEnvSchemaFile.FileError) {
		let name: String
		let declared: String
		let overridden: String
		switch item {
		case .clientPrefixes:
			if let json = value.json { schema.set(json, forKey: "clientPrefixes") } else { schema.removeValue(forKey: "clientPrefixes") }
			return
		case .key(let key): (name, declared, overridden) = (key, "vars", "overrides")
		case .group(let group): (name, declared, overridden) = (group, "groups", "groupOverrides")
		}
		switch value {
		case .absent:
			try remove(name, from: declared, in: &schema)
			try remove(name, from: overridden, in: &schema)
		case .declared(let json):
			try remove(name, from: overridden, in: &schema)
			try set(json, for: name, in: declared, of: &schema)
		case .overridden(let json):
			try remove(name, from: declared, in: &schema)
			try set(json, for: name, in: overridden, of: &schema)
		}
	}

	private static func set(_ value: LPMConfigJSON, for name: String, in field: String, of schema: inout LPMConfigJSON) throws(ProjectEnvSchemaFile.FileError) {
		var container = schema[field] ?? .object([])
		if container == .null { container = .object([]) }
		guard case .object = container else { throw .invalidSchema }
		container.set(value, forKey: name)
		schema.set(container, forKey: field)
	}

	private static func remove(_ name: String, from field: String, in schema: inout LPMConfigJSON) throws(ProjectEnvSchemaFile.FileError) {
		guard var container = schema[field], container != .null else { return }
		guard case .object = container else { throw .invalidSchema }
		guard container.removeValue(forKey: name) != nil else { return }
		if container.isEmptyObject { schema.removeValue(forKey: field) } else { schema.set(container, forKey: field) }
	}
}

// MARK: - Diff

extension ProjectEnvSchemaDraft {
	/// One item's change as lines of lpm.json, the way the LPM CLI renders the file.
	struct Diff: Equatable, Sendable {
		struct Line: Hashable, Sendable {
			enum Kind: Hashable, Sendable { case unchanged, removed, added }
			let kind: Kind
			let text: String
		}

		/// Where the item is in lpm.json, such as "envSchema.vars.PORT".
		let path: String
		let lines: [Line]
	}

	/// The change to `item` as lines of lpm.json; nil when the draft doesn't change it.
	func diff(for item: Item) -> Diff? {
		guard hasChange(to: item) else { return nil }
		let before = base(of: item)
		let after = declaration(of: item)
		let shown = after.json == nil ? before : after
		guard let path = Self.path(of: item, in: shown) else { return nil }
		let old = Self.lines(of: item, before)
		let new = Self.lines(of: item, after)
		if Self.path(of: item, in: before) != Self.path(of: item, in: after) {
			return Diff(path: path, lines: old.map { .init(kind: .removed, text: $0) } + new.map { .init(kind: .added, text: $0) })
		}
		return Diff(path: path, lines: Self.lineDiff(from: old, to: new))
	}

	private static func path(of item: Item, in declaration: Declaration) -> String? {
		switch (item, declaration) {
		case (_, .absent): nil
		case (.clientPrefixes, _): "envSchema.clientPrefixes"
		case (.key(let name), .declared): "envSchema.vars.\(name)"
		case (.key(let name), .overridden): "envSchema.overrides.\(name)"
		case (.group(let name), .declared): "envSchema.groups.\(name)"
		case (.group(let name), .overridden): "envSchema.groupOverrides.\(name)"
		}
	}

	private static func lines(of item: Item, _ declaration: Declaration) -> [String] {
		guard let json = declaration.json else { return [] }
		let name = switch item {
		case .key(let key): key
		case .group(let group): group
		case .clientPrefixes: "clientPrefixes"
		}
		let text = LPMConfigJSON.object([.init(key: name, value: json)]).rendered()
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		return lines.dropFirst().dropLast().map { String($0.dropFirst(2)) }
	}

	/// The longest common subsequence of lines, after the shared start and end.
	/// Beyond `maximumComparisons` the middle shows as removed, then added.
	static func lineDiff(from old: [String], to new: [String], maximumComparisons: Int = 250_000) -> [Diff.Line] {
		var prefix = 0
		while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
		let a = Array(old[prefix..<(old.count - suffix)])
		let b = Array(new[prefix..<(new.count - suffix)])
		var result = old[..<prefix].map { Diff.Line(kind: .unchanged, text: $0) }
		result.reserveCapacity(old.count + new.count)
		if a.isEmpty || b.isEmpty || a.count * b.count > maximumComparisons {
			result += a.map { .init(kind: .removed, text: $0) }
			result += b.map { .init(kind: .added, text: $0) }
		} else {
			let width = b.count + 1
			var lengths = [Int32](repeating: 0, count: (a.count + 1) * width)
			for i in stride(from: a.count - 1, through: 0, by: -1) {
				for j in stride(from: b.count - 1, through: 0, by: -1) {
					lengths[i * width + j] = a[i] == b[j]
						? lengths[(i + 1) * width + j + 1] + 1
						: max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
				}
			}
			var i = 0
			var j = 0
			while i < a.count, j < b.count {
				if a[i] == b[j] {
					result.append(.init(kind: .unchanged, text: a[i])); i += 1; j += 1
				} else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
					result.append(.init(kind: .removed, text: a[i])); i += 1
				} else {
					result.append(.init(kind: .added, text: b[j])); j += 1
				}
			}
			result += a[i...].map { .init(kind: .removed, text: $0) }
			result += b[j...].map { .init(kind: .added, text: $0) }
		}
		result += old[(old.count - suffix)...].map { .init(kind: .unchanged, text: $0) }
		return result
	}
}

// MARK: - Evaluation

extension ProjectEnvSchemaDraft {
	/// Why the bundled engine rejects the rules with the draft applied, tied to
	/// the item and rule field it names when the problem is in lpm.json.
	struct Rejection: Equatable, Sendable {
		let item: Item?
		/// The rule field, such as "pattern", when the engine names one.
		let field: String?
		/// Where the problem is, such as "lpm.json › envSchema.vars.PORT".
		let location: String
		let reason: String
		let code: String

		init(_ diagnostic: RustSchemaEngine.Diagnostic?) {
			let problem = ProjectEnvSchemaState.problem(diagnostic)
			location = problem.location
			reason = problem.reason
			code = diagnostic?.code ?? "env.invalid_rule"
			var item: Item?
			var field: String?
			if let diagnostic, diagnostic.source == nil || diagnostic.source == "lpm.json",
				let pointer = diagnostic.pointer, pointer.hasPrefix("/envSchema/")
			{
				let parts = pointer.dropFirst("/envSchema/".count).split(separator: "/", omittingEmptySubsequences: false).map {
					$0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
				}
				switch parts.first {
				case "vars"?, "overrides"?: item = parts.count > 1 ? .key(parts[1]) : nil
				case "groups"?, "groupOverrides"?: item = parts.count > 1 ? .group(parts[1]) : nil
				case "clientPrefixes"?: item = .clientPrefixes
				default: break
				}
				if item != nil, item != .clientPrefixes, parts.count > 2 { field = parts[2] }
			}
			self.item = item
			self.field = field
		}

		/// lpm.json couldn't be read or the rules couldn't be resolved.
		init(_ error: ProjectEnvSchemaFile.FileError) {
			item = nil
			field = nil
			location = "lpm.json › envSchema"
			reason = error.localizedDescription
			code = "app.unresolved"
		}
	}

	/// The rules with the draft applied, as the engine resolves them, and what
	/// they make of the stored values.
	struct Evaluation: Equatable, Sendable {
		/// The resolved rules; nil when the engine rejects them.
		let overview: ProjectEnvSchemaOverview?
		let rejection: Rejection?
		/// The stored values checked against the resolved rules.
		let check: ProjectEnvValueCheck?
	}
}

// MARK: - Effects on stored values

/// What saving a draft changes for the values stored in each environment,
/// attributed to the change that causes it. Never contains values.
struct ProjectEnvSchemaDraftEffects: Equatable, Sendable {
	struct Effect: Hashable, Sendable {
		enum Kind: Hashable, Sendable { case newlyFailing, nowPasses }
		let environment: String
		let kind: Kind
		/// The problem the draft adds or removes. A group's problem names one member.
		let problem: ProjectEnvValueCheck.Problem
	}

	struct Summary: Equatable, Sendable {
		/// By environment in the given order, failures before passes.
		var effects: [Effect] = []
		/// Problems that stay as they are.
		var unchanged = 0

		var isEmpty: Bool { effects.isEmpty && unchanged == 0 }
	}

	private(set) var items: [ProjectEnvSchemaDraft.Item: Summary] = [:]
	/// Effects on keys and groups the draft doesn't change, such as a key a
	/// changed default makes required through its `requiredWhen`.
	private(set) var others = Summary()

	func summary(for item: ProjectEnvSchemaDraft.Item) -> Summary { items[item] ?? Summary() }

	/// A key's problems count once per problem; a group's, which the engine
	/// reports on every member, once per environment whatever its mode.
	private enum Identity: Hashable {
		case key(String, ProjectEnvValueCheck.Problem.Kind)
		case group(String)
	}

	init(before: ProjectEnvValueCheck, after: ProjectEnvValueCheck, draft: ProjectEnvSchemaDraft, environmentOrder: [String] = []) {
		var changedKeys = Set<String>()
		var changedGroups = Set<String>()
		for item in draft.changedItems {
			switch item {
			case .key(let name): changedKeys.insert(name)
			case .group(let name): changedGroups.insert(name)
			case .clientPrefixes: break
			}
		}
		let rank = Dictionary(environmentOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
		let environments = Set(before.environments.keys).union(after.environments.keys).sorted {
			switch (rank[$0], rank[$1]) {
			case (let a?, let b?): a < b
			case (_?, nil): true
			case (nil, _?): false
			case (nil, nil): $0 < $1
			}
		}

		func problems(in check: ProjectEnvValueCheck, _ environment: String) -> [Identity: ProjectEnvValueCheck.Problem] {
			var found: [Identity: ProjectEnvValueCheck.Problem] = [:]
			guard let checked = check.environments[environment] else { return found }
			for key in checked.problems.keys.sorted() {
				for problem in checked.problems[key] ?? [] {
					let identity: Identity = if case .group(let name, _) = problem.kind { .group(name) } else { .key(key, problem.kind) }
					if found[identity] == nil { found[identity] = problem }
				}
			}
			return found
		}

		func owner(of identity: Identity, _ problem: ProjectEnvValueCheck.Problem) -> ProjectEnvSchemaDraft.Item? {
			switch identity {
			case .group(let name):
				if changedGroups.contains(name) { return .group(name) }
				return changedKeys.contains(problem.key) ? .key(problem.key) : nil
			case .key(let key, _):
				return changedKeys.contains(key) ? .key(key) : nil
			}
		}

		for environment in environments {
			let old = problems(in: before, environment)
			let new = problems(in: after, environment)
			var failing: [(ProjectEnvSchemaDraft.Item?, Effect)] = []
			var passing: [(ProjectEnvSchemaDraft.Item?, Effect)] = []
			for (identity, problem) in new {
				if old[identity] == nil {
					failing.append((owner(of: identity, problem), Effect(environment: environment, kind: .newlyFailing, problem: problem)))
				} else {
					record(unchangedFor: owner(of: identity, problem))
				}
			}
			for (identity, problem) in old where new[identity] == nil {
				passing.append((owner(of: identity, problem), Effect(environment: environment, kind: .nowPasses, problem: problem)))
			}
			for (item, effect) in (failing + passing).sorted(by: { Self.order($0.1, $1.1) }) { record(effect, for: item) }
		}
	}

	private static func order(_ a: Effect, _ b: Effect) -> Bool {
		if a.kind != b.kind { return a.kind == .newlyFailing }
		return a.problem.key < b.problem.key
	}

	private mutating func record(_ effect: Effect, for item: ProjectEnvSchemaDraft.Item?) {
		if let item { items[item, default: Summary()].effects.append(effect) } else { others.effects.append(effect) }
	}

	private mutating func record(unchangedFor item: ProjectEnvSchemaDraft.Item?) {
		if let item { items[item, default: Summary()].unchanged += 1 } else { others.unchanged += 1 }
	}
}

extension LPMConfigJSON {
	/// Equal as JSON values: objects with the same members in any order.
	func isEquivalent(to other: LPMConfigJSON) -> Bool {
		switch (self, other) {
		case (.object(let a), .object(let b)):
			guard a.count == b.count else { return false }
			// Keys compare by bytes, as lpm.json members do: Swift's String
			// equality would merge distinct spellings of the same text.
			var members = [[UInt8]: LPMConfigJSON](minimumCapacity: b.count)
			for member in b { members[Array(member.key.utf8)] = member.value }
			return a.allSatisfy { member in members[Array(member.key.utf8)].map { member.value.isEquivalent(to: $0) } ?? false }
		case (.array(let a), .array(let b)):
			return a.count == b.count && zip(a, b).allSatisfy { $0.isEquivalent(to: $1) }
		default:
			return self == other
		}
	}
}
