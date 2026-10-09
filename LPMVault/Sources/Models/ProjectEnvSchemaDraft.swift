import Foundation

/// Unsaved changes to the rules a project's root lpm.json declares: its keys,
/// overrides of keys that imported schemas declare, its groups and group
/// overrides, and its client prefixes.
///
/// Each change keeps the item as lpm.json had it when the draft last read the
/// file. When the file changes on disk, the draft merges item by item, and only
/// an item changed both on disk and in the draft conflicts.
struct ProjectEnvSchemaDraft: Sendable {
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

		/// The same kind of declaration with other JSON; `absent` stays absent.
		func replacingJSON(_ change: (inout LPMConfigJSON) -> Void) -> Declaration {
			switch self {
			case .absent: return .absent
			case .declared(var json): change(&json); return .declared(json)
			case .overridden(var json): change(&json); return .overridden(json)
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

		/// This merge followed by `later`, as one note.
		func merged(with later: Rebase) -> Rebase {
			var items = changedItems
			var seen = Set(items)
			for item in later.changedItems where seen.insert(item).inserted { items.append(item) }
			return Rebase(changedItems: items, changedOtherFields: changedOtherFields || later.changedOtherFields, conflicts: later.conflicts)
		}
	}

	/// lpm.json's envSchema as the draft last read it; nil when it has none.
	private(set) var schema: LPMConfigJSON?
	/// In the order they were first made.
	private(set) var changes: [Change] = [] { didSet { changePositions = Self.positions(of: changes.map(\.item)) } }
	private(set) var conflicts: [Conflict] = [] { didSet { conflictPositions = Self.positions(of: conflicts.map(\.item)) } }
	/// Each item `schema` has, which `base(of:)` reads without searching the JSON.
	private var baseItems: [Item: Declaration]
	private var changePositions: [Item: Int] = [:]
	private var conflictPositions: [Item: Int] = [:]

	init(schema: LPMConfigJSON?) {
		let schema = schema == .null ? nil : schema
		self.schema = schema
		baseItems = Self.index(of: schema)
	}

	var isEmpty: Bool { changes.isEmpty && conflicts.isEmpty }

	/// Items with a change or a conflict, in the order they were first changed.
	var changedItems: [Item] { changes.map(\.item) + conflicts.map(\.item) }

	/// How many items have a change or a conflict.
	var changeCount: Int { changes.count + conflicts.count }

	func hasChange(to item: Item) -> Bool {
		changePositions[item] != nil || conflictPositions[item] != nil
	}

	/// The item as lpm.json had it when the draft last read the file.
	func base(of item: Item) -> Declaration {
		baseItems[item] ?? .absent
	}

	/// The item with the draft applied: the draft's version of a conflicting item.
	func declaration(of item: Item) -> Declaration {
		if let index = changePositions[item] { return changes[index].value }
		if let index = conflictPositions[item] { return conflicts[index].mine }
		return base(of: item)
	}

	/// Sets an item. A value equivalent to what lpm.json has drops the item's
	/// change, so the file keeps its own member order; for a conflicting item,
	/// that settles the conflict.
	mutating func set(_ value: Declaration, for item: Item) {
		if let index = conflictPositions[item] {
			if value.isEquivalent(to: conflicts[index].theirs) {
				conflicts.remove(at: index)
			} else {
				conflicts[index] = Conflict(item: item, mine: value, theirs: conflicts[index].theirs)
			}
			return
		}
		let base = base(of: item)
		if let index = changePositions[item] {
			if value.isEquivalent(to: base) { changes.remove(at: index) } else { changes[index].value = value }
		} else if !value.isEquivalent(to: base) {
			changes.append(Change(item: item, base: base, value: value))
		}
	}

	mutating func discard(_ item: Item) {
		if let index = changePositions[item] { changes.remove(at: index) }
		if let index = conflictPositions[item] { conflicts.remove(at: index) }
	}

	mutating func discardAll() {
		changes = []
		conflicts = []
	}

	/// Points the draft's references to `key`, in Required when and in group
	/// members, at `newKey`. lpm.json can't refer to a key it doesn't declare,
	/// so only items the draft changes can refer to a key the draft adds.
	mutating func renameReferences(to key: String, as newKey: String) {
		guard key != newKey else { return }
		for item in changedItems {
			let declaration = declaration(of: item)
			switch item {
			case .key:
				guard let condition = declaration.json?["requiredWhen"], condition["variable"] == .string(key) else { continue }
				var renamed = condition
				renamed.set(.string(newKey), forKey: "variable")
				set(declaration.replacingJSON { $0.set(renamed, forKey: "requiredWhen") }, for: item)
			case .group:
				guard case .array(let members)? = declaration.json?["vars"], members.contains(.string(key)) else { continue }
				set(declaration.replacingJSON { $0.set(.array(members.map { $0 == .string(key) ? .string(newKey) : $0 }), forKey: "vars") }, for: item)
			case .clientPrefixes:
				continue
			}
		}
	}

	/// Settles a conflict with the draft's version or the one now in lpm.json.
	mutating func resolveConflict(_ item: Item, keepingMine: Bool) {
		guard let index = conflictPositions[item] else { return }
		let conflict = conflicts.remove(at: index)
		if keepingMine, !conflict.mine.isEquivalent(to: conflict.theirs) {
			changes.append(Change(item: item, base: conflict.theirs, value: conflict.mine))
		}
	}

	/// Merges an edit the app itself just saved: `schema` is lpm.json's
	/// envSchema after it. A description the app saved for a key the draft
	/// changes joins the draft's version, so the two edits don't conflict.
	@discardableResult
	mutating func rebase(ontoOwnWrite schema: LPMConfigJSON?, description: (key: String, text: String)?) -> Rebase {
		if let description {
			let item = Item.key(description.key)
			let describe: (inout LPMConfigJSON) -> Void = { rule in
				if description.text.isEmpty { rule.removeValue(forKey: "description") } else { rule.set(.string(description.text), forKey: "description") }
			}
			let written = Self.declaration(of: item, in: schema == .null ? nil : schema)
			if let index = changePositions[item] {
				changes[index] = Change(item: item, base: written, value: changes[index].value.replacingJSON(describe))
			} else if let index = conflictPositions[item] {
				conflicts[index] = Conflict(item: item, mine: conflicts[index].mine.replacingJSON(describe), theirs: conflicts[index].theirs)
			}
		}
		return rebase(onto: schema)
	}

	/// Merges the draft onto `schema`, the envSchema lpm.json has now. A change
	/// whose item lpm.json still has as the draft read it stays; one lpm.json
	/// already matches goes away; any other becomes a conflict.
	@discardableResult
	mutating func rebase(onto schema: LPMConfigJSON?) -> Rebase {
		let schema = schema == .null ? nil : schema
		guard schema != self.schema else { return Rebase() }
		let theirs = Self.index(of: schema)
		defer {
			self.schema = schema
			baseItems = theirs
		}
		guard !isEmpty else { return Rebase() }
		var outcome = Rebase(
			changedItems: Self.changedItems(from: self.schema, baseItems, to: schema, theirs),
			changedOtherFields: !Self.otherFields(of: self.schema).isEquivalent(to: Self.otherFields(of: schema))
		)
		var kept: [Change] = []
		var conflicted: [Conflict] = []
		for change in changes {
			let current = theirs[change.item] ?? .absent
			if current.isEquivalent(to: change.base) {
				kept.append(Change(item: change.item, base: current, value: change.value))
			} else if !current.isEquivalent(to: change.value) {
				conflicted.append(Conflict(item: change.item, mine: change.value, theirs: current))
			}
		}
		for conflict in conflicts {
			let current = theirs[conflict.item] ?? .absent
			if !current.isEquivalent(to: conflict.mine) {
				conflicted.append(Conflict(item: conflict.item, mine: conflict.mine, theirs: current))
			}
		}
		changes = kept
		conflicts = conflicted
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

	/// The items of `schema` by item; a key both declared and overridden, which
	/// the engine rejects, counts as declared, as `declaration(of:in:)` reads it.
	private static func index(of schema: LPMConfigJSON?) -> [Item: Declaration] {
		var index: [Item: Declaration] = [:]
		let items = items(in: schema)
		index.reserveCapacity(items.count)
		for (item, declaration) in items where index[item] == nil { index[item] = declaration }
		return index
	}

	private static func positions(of items: [Item]) -> [Item: Int] {
		var positions = [Item: Int](minimumCapacity: items.count)
		for (index, item) in items.enumerated() { positions[item] = index }
		return positions
	}

	private static let itemFields: Set<String> = ["vars", "overrides", "groups", "groupOverrides", "clientPrefixes"]

	private static func otherFields(of schema: LPMConfigJSON?) -> LPMConfigJSON {
		guard case .object(let members)? = schema else { return .object([]) }
		return .object(members.filter { !itemFields.contains($0.key) })
	}

	private static func changedItems(from old: LPMConfigJSON?, _ oldItems: [Item: Declaration], to new: LPMConfigJSON?, _ newItems: [Item: Declaration]) -> [Item] {
		var changed: [Item] = []
		var seen = Set<Item>()
		for (item, _) in items(in: new) where seen.insert(item).inserted {
			if let previous = oldItems[item], let current = newItems[item], previous.isEquivalent(to: current) { continue }
			changed.append(item)
		}
		for (item, _) in items(in: old) where newItems[item] == nil && seen.insert(item).inserted {
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

extension ProjectEnvSchemaDraft: Equatable {
	/// The indexes follow from the schema and the changes, so they don't take part.
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.changes == rhs.changes && lhs.conflicts == rhs.conflicts && lhs.schema == rhs.schema
	}
}

// MARK: - Diff

extension ProjectEnvSchemaDraft {
	/// One item's change as lines of lpm.json, the way the LPM CLI renders the
	/// file. Text that could hide or reorder what surrounds it shows as escapes.
	struct Diff: Equatable, Sendable {
		struct Line: Hashable, Sendable {
			enum Kind: Hashable, Sendable {
				case unchanged, removed, added
				/// Lines left out; the text says how many.
				case omitted
			}

			let kind: Kind
			let text: String
		}

		/// Where the item is in lpm.json, such as "envSchema.vars.PORT".
		let path: String
		/// Where the item was, when the draft moves it, such as from `vars` to `overrides`.
		var previousPath: String? = nil
		let lines: [Line]
	}

	/// The change to `item` as lines of lpm.json; nil when the draft doesn't change it.
	func diff(for item: Item) -> Diff? {
		guard hasChange(to: item) else { return nil }
		let before = base(of: item)
		let after = declaration(of: item)
		let oldPath = Self.path(of: item, in: before)
		let newPath = Self.path(of: item, in: after)
		guard let path = newPath ?? oldPath else { return nil }
		let old = Self.lines(of: item, before)
		let new = Self.lines(of: item, after)
		if let oldPath, let newPath, oldPath != newPath {
			return Diff(path: path.escapingDirectionControls, previousPath: oldPath.escapingDirectionControls,
				lines: Self.collapsed(old.map { .init(kind: .removed, text: $0) } + new.map { .init(kind: .added, text: $0) }))
		}
		return Diff(path: path.escapingDirectionControls, lines: Self.lineDiff(from: old, to: new))
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
		let lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
		return lines.dropFirst().dropLast().map { String(decoding: $0.dropFirst(2), as: UTF8.self) }
	}

	/// Lines kept around a change, and at most this many lines of a run that
	/// is entirely removed or added.
	static let contextLines = 3
	static let runLines = 100

	/// The shortest edit between two lists of lines, compared by their bytes,
	/// after the shared start and end, with long unchanged runs collapsed.
	/// When more than `maximumComparisons` steps would be needed, the middle
	/// shows as removed, then added.
	static func lineDiff(from old: [String], to new: [String], maximumComparisons: Int = 4_000_000) -> [Diff.Line] {
		var identities: [[UInt8]: Int] = [:]
		func identity(_ line: String) -> Int {
			let bytes = Array(line.utf8)
			if let id = identities[bytes] { return id }
			let id = identities.count
			identities[bytes] = id
			return id
		}
		let a = old.map(identity)
		let b = new.map(identity)
		var prefix = 0
		while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
		let middleA = Array(a[prefix..<(a.count - suffix)])
		let middleB = Array(b[prefix..<(b.count - suffix)])
		var result = old[..<prefix].map { Diff.Line(kind: .unchanged, text: $0) }
		let length = middleA.count + middleB.count
		let maximumDistance = length == 0 ? 0 : min(1_000, maximumComparisons / length)
		if let script = editScript(middleA, middleB, maximumDistance: maximumDistance) {
			for step in script {
				switch step {
				case .keep(let index): result.append(.init(kind: .unchanged, text: old[prefix + index]))
				case .remove(let index): result.append(.init(kind: .removed, text: old[prefix + index]))
				case .add(let index): result.append(.init(kind: .added, text: new[prefix + index]))
				}
			}
		} else {
			result += old[prefix..<(old.count - suffix)].map { .init(kind: .removed, text: $0) }
			result += new[prefix..<(new.count - suffix)].map { .init(kind: .added, text: $0) }
		}
		result += old[(old.count - suffix)...].map { .init(kind: .unchanged, text: $0) }
		return collapsed(result)
	}

	private enum Step {
		case keep(Int), remove(Int), add(Int)
	}

	/// Myers' shortest edit script between `a` and `b`; nil beyond `maximumDistance` edits.
	/// Keeps each round's frontier to trace the path back, so memory grows with
	/// the square of the edits, not the lines.
	private static func editScript(_ a: [Int], _ b: [Int], maximumDistance: Int) -> [Step]? {
		let n = a.count
		let m = b.count
		if n == 0 { return (0..<m).map(Step.add) }
		if m == 0 { return (0..<n).map(Step.remove) }
		let limit = min(n + m, maximumDistance)
		let offset = limit + 1
		var frontier = [Int](repeating: 0, count: 2 * limit + 3)
		var trace: [[Int]] = []
		for distance in 0...limit {
			trace.append(Array(frontier[(offset - distance - 1)...(offset + distance + 1)]))
			for diagonal in stride(from: -distance, through: distance, by: 2) {
				var x = diagonal == -distance || (diagonal != distance && frontier[offset + diagonal - 1] < frontier[offset + diagonal + 1])
					? frontier[offset + diagonal + 1]
					: frontier[offset + diagonal - 1] + 1
				var y = x - diagonal
				while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
				frontier[offset + diagonal] = x
				if x >= n, y >= m { return backtrack(trace, n: n, m: m) }
			}
		}
		return nil
	}

	private static func backtrack(_ trace: [[Int]], n: Int, m: Int) -> [Step] {
		var steps: [Step] = []
		var x = n
		var y = m
		for distance in stride(from: trace.count - 1, through: 0, by: -1) {
			let frontier = trace[distance]
			func at(_ diagonal: Int) -> Int { frontier[diagonal + distance + 1] }
			let diagonal = x - y
			let previous = diagonal == -distance || (diagonal != distance && at(diagonal - 1) < at(diagonal + 1)) ? diagonal + 1 : diagonal - 1
			let previousX = distance == 0 ? 0 : at(previous)
			let previousY = distance == 0 ? 0 : previousX - previous
			while x > previousX, y > previousY {
				x -= 1; y -= 1
				steps.append(.keep(x))
			}
			if distance > 0 {
				if x == previousX { y -= 1; steps.append(.add(y)) } else { x -= 1; steps.append(.remove(x)) }
			}
		}
		return steps.reversed()
	}

	/// Leaves out the middle of long unchanged runs and long removed or added
	/// runs, and escapes each line's text for display.
	private static func collapsed(_ lines: [Diff.Line]) -> [Diff.Line] {
		var result: [Diff.Line] = []
		var index = 0
		while index < lines.count {
			let kind = lines[index].kind
			var end = index
			while end < lines.count, lines[end].kind == kind { end += 1 }
			let run = lines[index..<end]
			let atStart = index == 0
			let atEnd = end == lines.count
			let keepFront: Int
			let keepBack: Int
			switch kind {
			case .unchanged:
				keepFront = atStart ? 1 : contextLines
				keepBack = atEnd ? 1 : contextLines
			default:
				keepFront = runLines
				keepBack = 0
			}
			if run.count > keepFront + keepBack + 1 {
				result += run.prefix(keepFront).map(escaped)
				let left = run.count - keepFront - keepBack
				result.append(.init(kind: .omitted, text: kind == .unchanged ? "\(left) unchanged lines" : "\(left) more lines"))
				result += run.suffix(keepBack).map(escaped)
			} else {
				result += run.map(escaped)
			}
			index = end
		}
		return result
	}

	private static func escaped(_ line: Diff.Line) -> Diff.Line {
		.init(kind: line.kind, text: line.text.escapingDirectionControls)
	}
}

// MARK: - Evaluation

extension ProjectEnvSchemaDraft {
	/// Why the bundled engine rejects the rules with the draft applied, tied to
	/// the item and rule field it names when the problem is in lpm.json.
	struct Rejection: Equatable, Sendable {
		let item: Item?
		/// The rule fields, such as "pattern", the problem is in, most likely
		/// first: the one the engine names, or the ones its reason is about.
		let fields: [String]
		/// Where the problem is, such as "lpm.json › envSchema.vars.PORT".
		let location: String
		let reason: String
		let code: String
		/// The engine's own message, when it gives one.
		let message: String?

		init(_ diagnostic: RustSchemaEngine.Diagnostic?) {
			let problem = ProjectEnvSchemaState.problem(diagnostic)
			location = problem.location
			reason = problem.reason
			code = diagnostic?.code ?? "env.invalid_rule"
			message = diagnostic?.message
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
			fields = if let field { [field] } else if item != nil { ProjectEnvSchemaState.fields(code: code, message: message) } else { [] }
		}

		/// lpm.json couldn't be read or the rules couldn't be resolved.
		init(_ error: ProjectEnvSchemaFile.FileError) {
			item = nil
			fields = []
			location = "lpm.json › envSchema"
			reason = error.localizedDescription
			code = "app.unresolved"
			message = nil
		}

		private init(_ rejection: Rejection, item: Item) {
			self.item = item
			fields = item == .clientPrefixes ? [] : ProjectEnvSchemaState.fields(code: rejection.code, message: rejection.message)
			location = rejection.location
			reason = rejection.reason
			code = rejection.code
			message = rejection.message
		}

		/// This rejection tied to the draft's item that causes it when the engine
		/// names none, as it doesn't for client prefixes or a malformed name.
		/// lpm.json's rules resolved before the draft, so one of its items is the cause.
		func attributed(to draft: ProjectEnvSchemaDraft) -> Rejection {
			guard item == nil else { return self }
			let items = draft.changedItems
			if items.contains(.clientPrefixes), code == "env.invalid_prefixes" || message?.hasPrefix("clientPrefixes ") == true {
				return Rejection(self, item: .clientPrefixes)
			}
			if code == "env.invalid_name", let named = items.first(where: { item in
				switch item {
				case .key(let name), .group(let name): !EnvValidation.isValidVariableName(name)
				case .clientPrefixes: false
				}
			}) {
				return Rejection(self, item: named)
			}
			return items.count == 1 ? Rejection(self, item: items[0]) : self
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
		/// The imported schemas the rules were resolved with, which a save
		/// requires unchanged.
		var dependencies: [RustSchemaEngine.Dependency] = []
	}
}

/// Evaluates schema drafts with the bundled engine, one at a time. An
/// evaluation whose task was cancelled while it waited doesn't start, and the
/// rules last resolved are reused when only the stored values changed.
actor ProjectEnvSchemaDraftEvaluator {
	enum Resolved: Sendable {
		case resolved(ProjectEnvSchemaOverview, dependencies: [RustSchemaEngine.Dependency])
		case rejected(ProjectEnvSchemaDraft.Rejection)
	}

	typealias Resolve = @Sendable (_ schema: LPMConfigJSON, _ folder: String) -> Resolved

	private struct Resolution {
		let schema: LPMConfigJSON
		let folder: String
		/// The imported schemas' digests when these were read; nil when unknown,
		/// which resolves again every time.
		let imports: [RustSchemaEngine.Dependency]?
		let resolved: Resolved
	}

	private let resolver: Resolve
	private var last: Resolution?

	init(resolve: @escaping Resolve = ProjectEnvSchemaDraftEvaluator.resolve) {
		resolver = resolve
	}

	static func resolve(_ schema: LPMConfigJSON, inFolder folder: String) -> Resolved {
		do throws(ProjectEnvSchemaFile.FileError) {
			switch try RustSchemaEngine.resolveOrDiagnose(schema, inFolder: folder) {
			case .success(let resolution): return .resolved(ProjectEnvSchemaOverview(resolution: resolution), dependencies: resolution.dependencies)
			case .failure(let rejected): return .rejected(.init(rejected.diagnostic))
			}
		} catch {
			return .rejected(.init(error))
		}
	}

	/// The evaluation of `draft`; nil when the calling task was cancelled.
	/// `imports` are the imported schemas' digests as last read; the last
	/// resolution is reused only while they're known and the same.
	func evaluate(
		_ draft: ProjectEnvSchemaDraft, inFolder folder: String, imports: [RustSchemaEngine.Dependency]?, environments: [String: [String: String]]
	) -> ProjectEnvSchemaDraft.Evaluation? {
		guard !Task.isCancelled else { return nil }
		let schema: LPMConfigJSON
		do { schema = try draft.applied(to: draft.schema) ?? .object([]) } catch {
			return .init(overview: nil, rejection: ProjectEnvSchemaDraft.Rejection(error).attributed(to: draft), check: nil)
		}
		let resolved: Resolved
		if let last, let imports, last.schema == schema, last.folder == folder, last.imports == imports {
			resolved = last.resolved
		} else {
			resolved = resolver(schema, folder)
			last = Resolution(schema: schema, folder: folder, imports: imports, resolved: resolved)
		}
		guard !Task.isCancelled else { return nil }
		switch resolved {
		case .resolved(let overview, let dependencies):
			return .init(overview: overview, rejection: nil, check: overview.check(environments), dependencies: dependencies)
		case .rejected(let rejection):
			return .init(overview: nil, rejection: rejection.attributed(to: draft), check: nil)
		}
	}
}

// MARK: - Effects on stored values

/// What saving a draft changes for the values stored in each environment,
/// attributed to the change that causes it. Never contains values.
struct ProjectEnvSchemaDraftEffects: Equatable, Sendable {
	struct Effect: Hashable, Sendable {
		enum Kind: Hashable, Sendable {
			case newlyFailing, nowPasses
			/// The draft removes the key from lpm.json, so the LPM CLI stops checking it.
			case noLongerChecked
		}

		let environment: String
		let kind: Kind
		/// The problem the draft adds or removes. A group's problem names one member.
		let problem: ProjectEnvValueCheck.Problem
	}

	/// A default the LPM CLI fills an unset key with that the draft adds,
	/// changes, or removes. Never contains the default.
	struct DefaultChange: Hashable, Sendable {
		enum Kind: Hashable, Sendable {
			case added, changed, removed
		}

		let environment: String
		let key: String
		let kind: Kind
	}

	struct Summary: Equatable, Sendable {
		/// By environment in the given order, then failures first, then by key and problem.
		var effects: [Effect] = []
		/// Problems that stay as they are.
		var unchanged = 0
		/// By environment in the given order, then by key.
		var defaults: [DefaultChange] = []

		var isEmpty: Bool { effects.isEmpty && unchanged == 0 && defaults.isEmpty }
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

	/// A problem as one check reports it, with every member that reports a group's.
	private struct Reported {
		var problems: [String: ProjectEnvValueCheck.Problem] = [:]

		var first: ProjectEnvValueCheck.Problem { problems[problems.keys.min()!]! }
	}

	init(before: ProjectEnvValueCheck, after: ProjectEnvValueCheck, draft: ProjectEnvSchemaDraft, environmentOrder: [String] = []) {
		var changedKeys = Set<String>()
		var removedKeys = Set<String>()
		var changedGroups = Set<String>()
		var removedGroups = Set<String>()
		for item in draft.changedItems {
			let removed = if case .declared = draft.base(of: item), draft.declaration(of: item) == .absent { true } else { false }
			switch item {
			case .key(let name):
				changedKeys.insert(name)
				if removed { removedKeys.insert(name) }
			case .group(let name):
				changedGroups.insert(name)
				if removed { removedGroups.insert(name) }
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

		func reported(in check: ProjectEnvValueCheck, _ environment: String) -> [Identity: Reported] {
			var found: [Identity: Reported] = [:]
			guard let checked = check.environments[environment] else { return found }
			for (key, problems) in checked.problems {
				for problem in problems {
					let identity: Identity = if case .group(let name, _) = problem.kind { .group(name) } else { .key(key, problem.kind) }
					found[identity, default: Reported()].problems[key] = problem
				}
			}
			return found
		}

		/// The changed items a problem belongs to, each with the problem as it
		/// reports it: a group's goes to the group, or to each changed member.
		func owners(of identity: Identity, _ reports: [Reported]) -> [(ProjectEnvSchemaDraft.Item?, ProjectEnvValueCheck.Problem)] {
			let fallback = reports[0].first
			switch identity {
			case .key(let key, _):
				return [(changedKeys.contains(key) ? .key(key) : nil, fallback)]
			case .group(let name):
				if changedGroups.contains(name) { return [(.group(name), fallback)] }
				let members = Set(reports.flatMap(\.problems.keys)).filter(changedKeys.contains).sorted()
				guard !members.isEmpty else { return [(nil, fallback)] }
				return members.map { member in (.key(member), reports.lazy.compactMap { $0.problems[member] }.first ?? fallback) }
			}
		}

		for environment in environments {
			let old = reported(in: before, environment)
			let new = reported(in: after, environment)
			var found: [(ProjectEnvSchemaDraft.Item?, Effect)] = []
			for (identity, reports) in new {
				for (item, problem) in owners(of: identity, [reports] + (old[identity].map { [$0] } ?? [])) {
					if old[identity] == nil {
						found.append((item, Effect(environment: environment, kind: .newlyFailing, problem: problem)))
					} else {
						record(unchangedFor: item)
					}
				}
			}
			for (identity, reports) in old where new[identity] == nil {
				let removed = switch identity {
				case .key(let key, _): removedKeys.contains(key)
				case .group(let name): removedGroups.contains(name)
				}
				for (item, problem) in owners(of: identity, [reports]) {
					found.append((item, Effect(environment: environment, kind: removed ? .noLongerChecked : .nowPasses, problem: problem)))
				}
			}
			for (item, effect) in found.sorted(by: { Self.order($0.1, $1.1) }) { record(effect, for: item) }

			let oldDefaults = before.environments[environment]?.defaults ?? [:]
			let newDefaults = after.environments[environment]?.defaults ?? [:]
			for key in changedKeys.sorted() {
				let kind: DefaultChange.Kind? = switch (oldDefaults[key], newDefaults[key]) {
				case (nil, _?): .added
				case (_?, nil): .removed
				case let (old?, new?) where old != new: .changed
				default: nil
				}
				if let kind { items[.key(key), default: Summary()].defaults.append(DefaultChange(environment: environment, key: key, kind: kind)) }
			}
		}
	}

	private static func order(_ a: Effect, _ b: Effect) -> Bool {
		if a.kind != b.kind { return rank(a.kind) < rank(b.kind) }
		if a.problem.key != b.problem.key { return a.problem.key < b.problem.key }
		return sortKey(a.problem.kind) < sortKey(b.problem.kind)
	}

	private static func rank(_ kind: Effect.Kind) -> Int {
		switch kind {
		case .newlyFailing: 0
		case .nowPasses: 1
		case .noLongerChecked: 2
		}
	}

	private static func sortKey(_ kind: ProjectEnvValueCheck.Problem.Kind) -> String {
		switch kind {
		case .required: "required"
		case .empty: "empty"
		case .unusableValue: "unusableValue"
		case .format(let format): "format:\(format)"
		case .constraint(let constraint): "constraint:\(constraint)"
		case .pattern: "pattern"
		case .notAllowed: "notAllowed"
		case .group(let name, let mode): "group:\(name):\(mode)"
		case .other(let code): "other:\(code)"
		}
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
			if a == b { return true }
			// Keys compare by bytes, as lpm.json members do: Swift's String
			// equality would merge distinct spellings of the same text.
			if a.count <= 16 {
				return a.allSatisfy { member in
					b.first(where: { $0.key.utf8.elementsEqual(member.key.utf8) }).map { member.value.isEquivalent(to: $0.value) } ?? false
				}
			}
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
