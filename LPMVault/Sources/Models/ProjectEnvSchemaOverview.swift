import Foundation

/// A project's env rules as the app shows them: each declared key's rules as
/// plain-word badges, the file an inherited rule comes from, and the groups.
/// Built from the engine's resolved schema, so it shows exactly what the LPM
/// CLI enforces.
struct ProjectEnvSchemaOverview: Equatable, Sendable {
	struct Badge: Hashable, Sendable {
		let text: String
		/// Detail for a tooltip, such as a pattern's expression or a long list.
		var help: String?
	}

	struct Rule: Equatable, Sendable {
		let key: String
		let isPublic: Bool
		/// The file that declares an inherited rule; nil when lpm.json declares it.
		let source: String?
		/// Only what differs from the defaults, in a fixed order.
		let badges: [Badge]
		/// The rule bounds the value's length.
		var hasLengthRule = false
		var isSecret = false
		/// The imported file whose declaration lpm.json overrides; nil when
		/// lpm.json declares the key or doesn't override it.
		var overrides: String?
		/// The file that declares an inherited rule as the engine names it,
		/// unescaped, for opening it; nil when lpm.json declares it.
		var sourcePath: String?
		/// `overrides` unescaped, for opening it.
		var overridesPath: String?
		/// The imported file that declares an inherited rule which another
		/// import, `sourcePath`, overrides; unescaped. Nil otherwise.
		var declaringPath: String?
	}

	struct Group: Equatable, Sendable {
		let name: String
		let members: [String]
		/// "exactlyOne", "atLeastOne", or "allOrNone".
		var mode: String
		/// The file that declares the group when lpm.json doesn't, escaped for showing.
		var source: String?
		/// `source` unescaped, for opening it.
		var sourcePath: String?
		/// The imported file whose group lpm.json overrides, escaped for showing;
		/// nil when lpm.json doesn't override it.
		var overrides: String?
		/// `overrides` unescaped, for opening it.
		var overridesPath: String?
		/// The imported file that declares an inherited group which another
		/// import, `sourcePath`, overrides; unescaped. Nil otherwise.
		var declaringPath: String?
		/// The first members as one short line, escaped for showing, such as
		/// "PASSWORD, TOKEN" or "A, B +4,094 more".
		let memberPreview: String

		init(
			name: String, members: [String], mode: String, source: String? = nil, sourcePath: String? = nil, overrides: String? = nil,
			overridesPath: String? = nil, declaringPath: String? = nil
		) {
			self.name = name
			self.members = members
			self.mode = mode
			self.source = source
			self.sourcePath = sourcePath
			self.overrides = overrides
			self.overridesPath = overridesPath
			self.declaringPath = declaringPath
			memberPreview = Self.preview(of: members)
		}

		/// Such as "Exactly one of PASSWORD, OAUTH_TOKEN", escaped for showing.
		var summary: String {
			(ProjectEnvSchemaGroup.Mode(rawValue: mode).map { $0.title + " " } ?? "") + memberPreview
		}

		/// The members that fit in `limit` characters, then how many more
		/// there are; a group can have thousands, which no line shows.
		static func preview(of members: [String], limit: Int = 160) -> String {
			var text = ""
			var length = 0
			var shown = 0
			for member in members {
				let escaped = member.escapingDirectionControls
				let separator = shown == 0 ? 0 : 2
				guard length + separator + escaped.count <= limit else { break }
				text += (shown == 0 ? "" : ", ") + escaped
				length += separator + escaped.count
				shown += 1
			}
			if shown == 0, let first = members.first {
				text = String(first.escapingDirectionControls.prefix(limit)) + "…"
				shown = 1
			}
			let more = members.count - shown
			return more > 0 ? "\(text) +\(more.formatted()) more" : text
		}
	}

	static let empty = ProjectEnvSchemaOverview(rules: [], groups: [])

	/// Declared keys from A to Z.
	let rules: [Rule]
	let groups: [Group]
	let publicKeys: Set<String>
	/// Declared keys whose values are secret.
	let secretKeys: Set<String>
	let declaredKeys: Set<String>
	/// Prefixes that make a key public besides the frameworks', from lpm.json
	/// and the schemas it imports.
	let clientPrefixes: [String]
	/// The resolved schema as compact JSON, which the bundled engine checks
	/// stored values against; nil for rules not built from a resolution.
	let effectiveSchema: Data?
	private let index: [String: Int]
	private let declarations: [String: LPMConfigJSON]
	/// The keys whose Required when compares each key's value, from A to Z.
	private let comparisons: [String: [String]]
	/// Declared keys by their name in capitals, which Windows reads as one name.
	private let foldedKeys: [String: [String]]

	init(rules: [Rule], groups: [Group], effectiveSchema: Data? = nil, clientPrefixes: [String] = [], declarations: [String: LPMConfigJSON] = [:]) {
		let order = Dictionary(uniqueKeysWithValues: VaultKeySortOrder.sortedAscending(rules.map(\.key)).enumerated().map { ($1, $0) })
		self.rules = rules.sorted { order[$0.key, default: 0] < order[$1.key, default: 0] }
		self.groups = groups.sorted { $0.name < $1.name }
		publicKeys = Set(rules.lazy.filter(\.isPublic).map(\.key))
		secretKeys = Set(rules.lazy.filter(\.isSecret).map(\.key))
		declaredKeys = Set(rules.lazy.map(\.key))
		foldedKeys = Dictionary(grouping: self.rules.lazy.map(\.key), by: { $0.uppercased() })
		self.clientPrefixes = clientPrefixes
		self.effectiveSchema = effectiveSchema
		self.declarations = declarations
		index = Dictionary(uniqueKeysWithValues: self.rules.enumerated().map { ($1.key, $0) })
		var comparisons: [String: [String]] = [:]
		for (key, declaration) in declarations {
			if case .string(let source)? = declaration["requiredWhen"]?["variable"], declaration["requiredWhen"]?["equals"] != nil {
				comparisons[source, default: []].append(key)
			}
		}
		self.comparisons = comparisons.mapValues { $0.sorted() }
	}

	init(resolution: RustSchemaEngine.Resolution) {
		var overridden: [String: String] = [:]
		var declaring: [String: String] = [:]
		// lpm.json's override names what it replaces, which can be an import's
		// own override; a rule an import overrides names where it was declared.
		for (key, origin) in resolution.origins {
			if origin.source == "lpm.json" {
				if origin.pointer.hasPrefix("/envSchema/overrides/"), let replaced = resolution.replacedRules[key]?.origin.source { overridden[key] = replaced }
			} else if let declaringSource = resolution.declaringOrigins[key]?.source, declaringSource != origin.source, declaringSource != "lpm.json" {
				declaring[key] = declaringSource
			}
		}
		var overriddenGroups: [String: String] = [:]
		var declaringGroups: [String: String] = [:]
		for (name, origin) in resolution.groupOrigins {
			if origin.source == "lpm.json" {
				if origin.pointer.hasPrefix("/envSchema/groupOverrides/"), let replaced = resolution.replacedGroups[name]?.origin.source { overriddenGroups[name] = replaced }
			} else if let declaringSource = resolution.groupDeclaringOrigins[name]?.source, declaringSource != origin.source, declaringSource != "lpm.json" {
				declaringGroups[name] = declaringSource
			}
		}
		self.init(effective: resolution.effective, sources: resolution.origins.mapValues(\.source), overridden: overridden,
			declaring: declaring, groupSources: resolution.groupOrigins.mapValues(\.source), overriddenGroups: overriddenGroups,
			declaringGroups: declaringGroups)
	}

	private init(
		effective: LPMConfigJSON, sources: [String: String], overridden: [String: String] = [:], declaring: [String: String] = [:],
		groupSources: [String: String] = [:], overriddenGroups: [String: String] = [:], declaringGroups: [String: String] = [:]
	) {
		var rules: [Rule] = []
		var declared: [String: LPMConfigJSON] = [:]
		if case .object(let declarations)? = effective["vars"] {
			rules.reserveCapacity(declarations.count)
			declared.reserveCapacity(declarations.count)
			for declaration in declarations {
				let source = sources[declaration.key]
				declared[declaration.key] = declaration.value
				rules.append(Rule(
					key: declaration.key,
					isPublic: declaration.value["client"] == .bool(true),
					source: source == "lpm.json" ? nil : source?.escapingDirectionControls,
					badges: Self.badges(for: declaration.value).map {
						Badge(text: $0.text.escapingDirectionControls, help: $0.help?.escapingDirectionControls)
					},
					hasLengthRule: declaration.value["minLength"] != nil || declaration.value["maxLength"] != nil,
					isSecret: declaration.value["secret"] == .bool(true),
					overrides: overridden[declaration.key]?.escapingDirectionControls,
					sourcePath: source == "lpm.json" ? nil : source,
					overridesPath: overridden[declaration.key],
					declaringPath: declaring[declaration.key]
				))
			}
		}
		var groups: [Group] = []
		if case .object(let declared)? = effective["groups"] {
			for group in declared {
				guard let parsed = ProjectEnvSchemaGroup(group.value) else { continue }
				let source = groupSources[group.key].flatMap { $0 == "lpm.json" ? nil : $0 }
				groups.append(Group(name: group.key, members: parsed.members, mode: parsed.mode.rawValue,
					source: source?.escapingDirectionControls, sourcePath: source, overrides: overriddenGroups[group.key]?.escapingDirectionControls,
					overridesPath: overriddenGroups[group.key], declaringPath: declaringGroups[group.key]))
			}
		}
		var prefixes: [String] = []
		if case .array(let values)? = effective["clientPrefixes"] {
			prefixes = values.compactMap { if case .string(let prefix) = $0 { prefix } else { nil } }
		}
		self.init(rules: rules, groups: groups, effectiveSchema: try? effective.compactData(maximumBytes: Self.engineInputLimit),
			clientPrefixes: prefixes, declarations: declared)
	}

	/// The bundled engine's input limit for a schema or a set of values.
	private static let engineInputLimit = 2 * 1024 * 1024

	/// Evaluates the values stored in each environment against these rules
	/// with the bundled engine, as the LPM CLI does at runtime; nil when the
	/// rules weren't resolved or the engine can't check the values.
	func check(_ environments: [String: [String: String]]) -> ProjectEnvValueCheck? {
		guard let effectiveSchema else { return nil }
		var members: [LPMConfigJSON.Member] = []
		members.reserveCapacity(environments.count)
		for (environment, values) in environments {
			members.append(.init(key: environment, value: .object(values.map { .init(key: $0.key, value: .string($0.value)) })))
		}
		let input = LPMConfigJSON.object([.init(key: "environments", value: .object(members))])
		guard let values = try? input.compactData(maximumBytes: Self.engineInputLimit),
			let output = RustSchemaEngine.check(schema: effectiveSchema, values: values)
		else { return nil }
		return ProjectEnvValueCheck(output: output)
	}

	func renamingKey(from: String, to: String) -> ProjectEnvSchemaOverview? {
		guard from != to else { return self }
		guard EnvValidation.isValidVariableName(to), let effectiveSchema,
			let schema = try? LPMConfigJSON(parsing: effectiveSchema, rejectDuplicateKeys: true),
			let updated = try? ProjectEnvSchemaFile.applying(.init(rename: .init(from: from, to: to)),
				to: .object([.init(key: "envSchema", value: schema)]), referenceSchema: schema),
			let effective = try? RustSchemaEngine.validate(updated["envSchema"] ?? .object([]))
		else { return nil }
		var sources = Dictionary(uniqueKeysWithValues: rules.compactMap { rule in
			(rule.sourcePath ?? rule.source).map { (rule.key, $0) }
		})
		if schema["vars"]?[from] != nil, schema["vars"]?[to] == nil {
			sources[to] = sources.removeValue(forKey: from)
		}
		var overridden = Dictionary(uniqueKeysWithValues: rules.compactMap { rule in (rule.overridesPath ?? rule.overrides).map { (rule.key, $0) } })
		if let moved = overridden.removeValue(forKey: from) { overridden[to] = moved }
		var declaring = Dictionary(uniqueKeysWithValues: rules.compactMap { rule in rule.declaringPath.map { (rule.key, $0) } })
		if let moved = declaring.removeValue(forKey: from) { declaring[to] = moved }
		let groupSources = Dictionary(uniqueKeysWithValues: groups.compactMap { group in (group.sourcePath ?? group.source).map { (group.name, $0) } })
		let overriddenGroups = Dictionary(uniqueKeysWithValues: groups.compactMap { group in (group.overridesPath ?? group.overrides).map { (group.name, $0) } })
		let declaringGroups = Dictionary(uniqueKeysWithValues: groups.compactMap { group in group.declaringPath.map { (group.name, $0) } })
		return ProjectEnvSchemaOverview(effective: effective, sources: sources, overridden: overridden, declaring: declaring, groupSources: groupSources,
			overriddenGroups: overriddenGroups, declaringGroups: declaringGroups)
	}

	var isEmpty: Bool { rules.isEmpty && groups.isEmpty }

	/// Declared keys a new key could be: those not set in every one of
	/// `environments`, whose names contain `query`, names that start with it first.
	func suggestions(matching query: String, unsetIn environments: Set<String>, of project: VaultProject, limit: Int = 6) -> [Rule] {
		let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
		guard !needle.isEmpty, !environments.isEmpty else { return [] }
		var leading: [Rule] = []
		var inner: [Rule] = []
		for rule in rules where environments.contains(where: { project.value(for: rule.key, in: $0) == nil }) {
			let name = rule.key.lowercased()
			if rule.key == query { return [] }
			if name.hasPrefix(needle) { leading.append(rule) } else if name.contains(needle) { inner.append(rule) }
		}
		return Array((leading + inner).prefix(limit))
	}

	var inheritedCount: Int { rules.lazy.filter { $0.source != nil }.count }

	func rule(for key: String) -> Rule? {
		index[key].map { rules[$0] }
	}

	/// Where `key` is in `rules`.
	func position(of key: String) -> Int? {
		index[key]
	}

	/// Declared keys other than `key` whose names differ from `name` at most in letter case.
	func keys(named name: String, otherThan key: String) -> [String] {
		(foldedKeys[name.uppercased()] ?? []).filter { $0 != key }
	}

	/// Declared keys whose names differ only in letter case.
	struct CaseClash: Equatable, Sendable {
		/// From A to Z.
		let keys: [String]

		var message: String {
			let names = keys.map(\.escapingDirectionControls)
			let listed = names.count == 2 ? "\(names[0]) and \(names[1])" : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
			return "\(listed) differ only in letter case, which Windows reads as one name. \(keys.count == 2 ? "Rename one of them." : "Rename all but one of them.")"
		}
	}

	/// The first set of keys that differ only in letter case which `earlier`
	/// doesn't have, by its first name.
	func caseClash(since earlier: ProjectEnvSchemaOverview?) -> CaseClash? {
		var first: [String]?
		for keys in foldedKeys.values where keys.count > 1 {
			let sorted = keys.sorted()
			guard earlier?.foldedKeys[sorted[0].uppercased()].map({ $0.sorted() == sorted }) != true else { continue }
			if first.map({ sorted[0] < $0[0] }) ?? true { first = sorted }
		}
		return first.map(CaseClash.init(keys:))
	}

	/// The keys whose Required when compares `key`'s value, which keeps it from being secret.
	func keys(comparing key: String) -> [String] {
		comparisons[key] ?? []
	}

	/// The key's resolved rule as JSON, as the LPM CLI enforces it.
	func declaration(of key: String) -> LPMConfigJSON? {
		declarations[key]
	}

	/// The resolved schema decides the rest, unless it was too large to keep.
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.rules == rhs.rules && lhs.groups == rhs.groups && lhs.clientPrefixes == rhs.clientPrefixes && lhs.effectiveSchema == rhs.effectiveSchema
			&& (lhs.effectiveSchema != nil || lhs.declarations == rhs.declarations)
	}

	// MARK: - Badges

	static func badges(for rule: LPMConfigJSON) -> [Badge] {
		var badges: [Badge] = []
		if rule["required"] == .bool(true) { badges.append(Badge(text: "Required")) }
		if let condition = rule["requiredWhen"], case .string(let variable)? = condition["variable"] {
			if case .string(let value)? = condition["equals"] {
				let shown = shortText(value)
				badges.append(Badge(text: "Required when \(variable) = \(shown.text)", help: shown.help))
			} else if case .bool(let present)? = condition["present"] {
				badges.append(Badge(text: "Required when \(variable) is \(present ? "set" : "not set")"))
			}
		}
		if case .array(let selectors)? = rule["requiredIn"] {
			for selector in selectors {
				badges.append(Badge(text: "Required in \(scope(selector))"))
			}
		}
		if case .string(let format)? = rule["format"], let name = formatNames[format] {
			badges.append(Badge(text: name))
		}
		switch (integer(rule["min"]), integer(rule["max"])) {
		case (let low?, let high?): badges.append(Badge(text: low == high ? "Exactly \(low)" : "\(low)–\(high)"))
		case (let low?, nil): badges.append(Badge(text: "≥ \(low)"))
		case (nil, let high?): badges.append(Badge(text: "≤ \(high)"))
		case (nil, nil): break
		}
		switch (integer(rule["minLength"]), integer(rule["maxLength"])) {
		case (let low?, let high?): badges.append(Badge(text: low == high ? "\(low) \(chars(low))" : "\(low)–\(high) chars"))
		case (let low?, nil): badges.append(Badge(text: "\(low)+ chars"))
		case (nil, let high?): badges.append(Badge(text: "≤ \(high) \(chars(high))"))
		case (nil, nil): break
		}
		if case .array(let values)? = rule["protocols"] {
			let schemes = values.compactMap { value -> String? in if case .string(let scheme) = value { scheme } else { nil } }
			if !schemes.isEmpty { badges.append(Badge(text: "\(schemes.joined(separator: ", ")) only")) }
		}
		if case .array(let values)? = rule["enum"] {
			let options = values.compactMap { value -> String? in if case .string(let option) = value { option } else { nil } }
			badges.append(choices(options))
		}
		if case .string(let pattern)? = rule["pattern"] {
			badges.append(Badge(text: "Pattern", help: pattern))
		}
		if case .string(let value)? = rule["default"] {
			let shown = shortText(value)
			badges.append(Badge(text: "Default: \(shown.text)", help: shown.help))
		}
		if case .array(let defaults)? = rule["defaultsIn"] {
			for scoped in defaults {
				guard case .string(let value)? = scoped["value"], let selector = scoped["when"] else { continue }
				let shown = shortText(value)
				badges.append(Badge(text: "Default in \(scope(selector)): \(shown.text)", help: shown.help))
			}
		}
		switch rule["empty"] {
		case .string("allow")?: badges.append(Badge(text: "Empty allowed"))
		case .string("reject")?: badges.append(Badge(text: "Empty rejected"))
		default: break
		}
		if rule["secret"] == .bool(true) { badges.append(Badge(text: "Secret")) }
		if rule["ci"] == .string("variable") { badges.append(Badge(text: "CI variable")) }
		return badges
	}

	private static let formatNames = [
		"url": "URL", "email": "Email", "port": "Port", "boolean": "Boolean",
		"integer": "Integer", "hostname": "Hostname", "ip": "IP",
	]

	private static let shortLimit = 32

	/// A scope selector in words: environments, then stages, then services.
	private static func scope(_ selector: LPMConfigJSON) -> String {
		func names(_ field: String) -> [String] {
			guard case .array(let values)? = selector[field] else { return [] }
			return values.compactMap { value in if case .string(let name) = value { name } else { nil } }
		}
		var parts: [String] = []
		let environments = names("environment"), stages = names("stage"), services = names("service")
		if !environments.isEmpty { parts.append(environments.joined(separator: ", ")) }
		if !stages.isEmpty { parts.append("\(stages.joined(separator: ", ")) \(stages.count == 1 ? "stage" : "stages")") }
		if !services.isEmpty { parts.append("\(services.joined(separator: ", ")) \(services.count == 1 ? "service" : "services")") }
		return parts.isEmpty ? "every context" : parts.joined(separator: " · ")
	}

	private static func choices(_ options: [String]) -> Badge {
		let shortened = options.map(shortText)
		let all = "One of: " + shortened.map(\.text).joined(separator: ", ")
		guard all.count > shortLimit + 16, options.count > 1 else {
			return Badge(text: all, help: shortened.contains { $0.help != nil } ? options.joined(separator: "\n") : nil)
		}
		var shown: [String] = []
		var length = 0
		for option in shortened {
			let text = option.text
			guard shown.isEmpty || length + text.count <= shortLimit else { break }
			shown.append(text)
			length += text.count + 2
		}
		return Badge(text: "One of: \(shown.joined(separator: ", ")) +\(options.count - shown.count)", help: options.joined(separator: "\n"))
	}

	/// Literal text from lpm.json on one short line; the full text goes to the tooltip.
	private static func shortText(_ value: String) -> (text: String, help: String?) {
		if value.isEmpty { return ("\"\"", nil) }
		let line = value.split(whereSeparator: \.isNewline).joined(separator: " ")
		guard line.count > shortLimit || line != value else { return (value, nil) }
		return (line.count > shortLimit ? String(line.prefix(shortLimit)) + "…" : line, value)
	}

	private static func integer(_ value: LPMConfigJSON?) -> String? {
		switch value {
		case .string(let text)?, .number(let text)?: text
		default: nil
		}
	}

	private static func chars(_ count: String) -> String { count == "1" ? "char" : "chars" }
}

extension ProjectEnvSchemaOverview.Rule {
	/// A key's rule as a draft writes it, before the engine resolves it.
	/// `saved` is its rule in lpm.json's resolved rules, which names the
	/// schema an override replaces.
	init(key: String, draft declaration: LPMConfigJSON, isOverride: Bool, saved: Self?) {
		self.init(
			key: key,
			isPublic: declaration["client"] == .bool(true),
			source: nil,
			badges: ProjectEnvSchemaOverview.badges(for: declaration).map {
				.init(text: $0.text.escapingDirectionControls, help: $0.help?.escapingDirectionControls)
			},
			hasLengthRule: declaration["minLength"] != nil || declaration["maxLength"] != nil,
			isSecret: declaration["secret"] == .bool(true),
			overrides: isOverride ? saved?.overrides ?? saved?.source : nil
		)
	}
}

extension ProjectEnvSchemaOverview.Group {
	/// A group as a draft writes it, before the engine resolves it. `saved`
	/// is the group in lpm.json's resolved rules, which names the schema an
	/// override replaces.
	init?(name: String, draft declaration: LPMConfigJSON, isOverride: Bool, saved: Self?) {
		guard let group = ProjectEnvSchemaGroup(declaration) else { return nil }
		self.init(name: name, members: group.members, mode: group.mode.rawValue, overrides: isOverride ? saved?.overrides ?? saved?.source : nil,
			overridesPath: isOverride ? saved?.overridesPath ?? saved?.sourcePath : nil)
	}
}

/// What the Schema page shows for a project.
enum ProjectEnvSchemaState: Equatable, Sendable {
	/// The project has no folder on this Mac to read lpm.json from.
	case noFolder
	/// The rules lpm.json declares; empty when it declares none. `file` is
	/// lpm.json, or nil when the folder has none.
	case loaded(ProjectEnvSchemaOverview, file: URL?)
	/// lpm.json can't be read as rules; the app checks nothing until it can.
	case unreadable(Problem)

	struct Problem: Equatable, Sendable {
		/// Where the problem is, such as "lpm.json › envSchema.vars.PORT".
		let location: String
		let reason: String
	}

	var overview: ProjectEnvSchemaOverview? {
		if case .loaded(let overview, _) = self { overview } else { nil }
	}

	static func problem(_ diagnostic: RustSchemaEngine.Diagnostic?) -> Problem {
		guard let diagnostic else {
			return Problem(location: "lpm.json › envSchema", reason: ProjectEnvSchemaFile.FileError.invalidSchema.localizedDescription)
		}
		let source = diagnostic.source ?? "lpm.json"
		let path = (diagnostic.pointer ?? "").split(separator: "/").map {
			$0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
		}
		let location = (path.isEmpty
			? (diagnostic.source == nil ? "lpm.json › envSchema" : source)
			: "\(source) › \(path.joined(separator: "."))").escapingDirectionControls
		return Problem(location: location, reason: reason(code: diagnostic.code, message: diagnostic.message))
	}

	/// The engine's reason in plain words: its message when it gives one, or
	/// what its code means.
	static func reason(code: String, message: String?) -> String {
		if let message {
			return messages[message]?.reason ?? message.prefix(1).uppercased() + message.dropFirst()
		}
		return reasons[code] ?? "Invalid declaration (\(code))."
	}

	/// The rule fields a definition problem is about, most likely first, when
	/// the engine's location names only the key. Empty when it isn't about one.
	static func fields(code: String, message: String?) -> [String] {
		if let message { return messages[message]?.fields ?? [] }
		return switch code {
		case "env.invalid_pattern": ["pattern"]
		case "env.invalid_format", "env.enum_mismatch", "env.pattern_mismatch", "env.constraint", "env.invalid_value": ["default"]
		case "env.empty", "env.required": ["default", "defaultsIn"]
		default: []
		}
	}

	/// The engine's rule messages, in plain words, with the fields they're about.
	private static let messages: [String: (reason: String, fields: [String])] = [
		"min and max require the integer or port format": ("Min and max need the integer or port format.", ["min", "max"]),
		"min cannot exceed max": ("Min can't be more than max.", ["min", "max"]),
		"numeric bounds exclude every valid port": ("These bounds leave no valid port, which runs from 1 to 65535.", ["min", "max"]),
		"minLength cannot exceed maxLength": ("The shortest length can't be more than the longest.", ["minLength", "maxLength"]),
		"protocols require the url format": ("Protocols need the url format.", ["protocols"]),
		"protocols must contain 1 to 32 unique lowercase URL schemes": ("List 1 to 32 different URL schemes in lowercase, such as https, without a colon.", ["protocols"]),
		"requiredWhen must reference a declared variable": ("Required when must name a declared key.", ["requiredWhen"]),
		"requiredWhen cannot compare a secret source with a literal": ("Required when can't compare a secret key's value. Use “is set” or “is not set”.", ["requiredWhen"]),
		"schema text cannot contain unsafe control characters": ("The rule's text can't contain control characters.", ["description", "pattern", "default", "defaultsIn", "enum", "requiredWhen"]),
		"secret rules cannot be client-visible": ("Public keys can't be secret.", ["secret", "client"]),
		"secret rules cannot use readable CI variable storage": ("Secret keys can't use readable CI variables.", ["ci"]),
		"client-visible keys must use a framework or declared client prefix; rename the key or add its prefix to clientPrefixes":
			("Public keys need a public prefix, such as NEXT_PUBLIC_ or one of the project's client prefixes.", ["client"]),
		"public-prefix keys require client: true; remove secret: true or rename the key to keep it private":
			("A key with a public prefix is public. Turn off Secret, or rename the key to keep it private.", ["secret", "client"]),
		"secret rules cannot contain literal defaults or enum values": ("Secret keys can't have a default or allowed values.", ["default", "enum"]),
		"secret rules cannot contain literal scoped defaults": ("Secret keys can't have scoped defaults.", ["defaultsIn"]),
		"enum must contain at least one value": ("Add at least one allowed value.", ["enum"]),
		"scoped default does not satisfy its format": ("A scoped default doesn't match the format.", ["defaultsIn"]),
		"scoped default does not satisfy its enum": ("A scoped default isn't one of the allowed values.", ["defaultsIn"]),
		"scoped default does not satisfy its pattern": ("A scoped default doesn't match the pattern.", ["defaultsIn"]),
		"scoped default does not satisfy its scalar constraints": ("A scoped default is outside the bounds or length.", ["defaultsIn"]),
		"scoped default is not a process environment value": ("A scoped default can't contain a null character.", ["defaultsIn"]),
		"requiredIn and defaultsIn each support at most 32 selectors": ("A rule can have at most 32 scopes in Required in and 32 in Default in.", ["requiredIn", "defaultsIn"]),
		"scope selectors require unique nonempty dimensions with valid environment, stage, and service names":
			("A scope names an environment or service that isn't valid, or names one twice. Names use letters, digits, “.”, “_” and “-”, up to 64 characters.", ["requiredIn", "defaultsIn"]),
		"requiredIn selectors must be unique": ("Two scopes in Required in are the same.", ["requiredIn"]),
		"defaultsIn selectors cannot overlap": ("Scoped defaults overlap, so more than one could apply. Narrow them.", ["defaultsIn"]),
		"groups must contain at most 128 groups and 4096 total members": ("There can be at most 128 groups, with 4096 members in all.", []),
		"group names must be portable environment variable names": ("Group names use letters, digits and underscores, and can't start with a digit.", []),
		"groups must contain at least one declared variable": ("A group needs at least one key.", ["vars"]),
		"group members must be unique declared variables": ("A group's members must be declared keys, each listed once.", ["vars"]),
		"clientPrefixes must contain at most 32 unique portable prefixes ending in '_'":
			("Client prefixes: at most 32, each listed once, using letters, digits and underscores, and ending in “_”.", []),
	]

	/// Plain words for the engine's definition codes when it gives no message.
	private static let reasons: [String: String] = {
		let limits = "The imported schemas exceed the LPM CLI's limits."
		return [
			"env.invalid_definition": "A declaration has an unknown field or a value of the wrong type.",
			"env.invalid_rule": "This rule is invalid.",
			"env.invalid_name": "A key or group name isn't a valid environment variable name.",
			"env.invalid_pattern": "This pattern isn't a valid regular expression.",
			"env.invalid_format": "The default doesn't match the format.",
			"env.enum_mismatch": "The default isn't one of the allowed values.",
			"env.pattern_mismatch": "The default doesn't match the pattern.",
			"env.constraint": "The default is outside the bounds or length.",
			"env.invalid_value": "The default can't contain a null character.",
			"env.empty": "An empty default can't be used while empty values are rejected.",
			"env.required": "An empty default can't satisfy Required.",
			"env.invalid_prefixes": "A client prefix is listed twice.",
			"env.declaration_conflict": "More than one schema declares this key. Add an override in lpm.json to choose one.",
			"env.override_missing": "This override names a key that no imported schema declares.",
			"env.import_unreadable": "An imported schema can't be read.",
			"env.import_path": "This import path isn't allowed.",
			"env.import_escape": "This import points outside the project.",
			"env.import_cycle": "The imports form a cycle.",
			"env.source_alias": "The same file is imported under two spellings.",
			"env.unknown_preset": "This preset doesn't exist.",
			"env.source_changed": "A schema file changed while it was read. Recheck.",
			"env.project_unavailable": "The project folder can't be read.",
			"env.graph_depth": limits, "env.graph_nodes": limits, "env.graph_edges": limits,
			"env.source_budget": limits, "env.fragment_budget": limits, "env.aggregate_budget": limits,
			"env.merge_budget": limits, "env.output_budget": limits,
		]
	}()
}

extension String {
	/// Whether the text has characters that could hide or reorder the text around them.
	var hasHiddenCharacters: Bool { unicodeScalars.contains(where: \.hidesOrReordersText) }

	/// This text with each character that could hide or reorder the text
	/// around it written as an escape, such as \u{202e}, for showing text
	/// that comes from lpm.json, which an untrusted project can write.
	var escapingDirectionControls: String {
		guard hasHiddenCharacters else { return self }
		var escaped = ""
		escaped.reserveCapacity(utf8.count + 8)
		for scalar in unicodeScalars {
			if scalar.hidesOrReordersText {
				escaped += "\\u{\(String(scalar.value, radix: 16))}"
			} else {
				escaped.unicodeScalars.append(scalar)
			}
		}
		return escaped
	}
}

private extension Unicode.Scalar {
	/// Matches the characters the LPM CLI escapes in its diagnostics.
	var hidesOrReordersText: Bool {
		properties.generalCategory == .control
			|| value == 0x061C || value == 0x200E || value == 0x200F
			|| (0x2028...0x202E).contains(value) || (0x2066...0x2069).contains(value)
	}
}
