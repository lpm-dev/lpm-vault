import Foundation

/// A project's env rules as the app shows them: each declared key's rules as
/// plain-word badges, the file an inherited rule comes from, and the groups.
/// Built from the engine's resolved schema, so it shows exactly what the LPM
/// CLI enforces. Rules are read-only in the app; people edit them in lpm.json.
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
	}

	struct Group: Equatable, Sendable {
		let name: String
		let summary: String
		let members: [String]
	}

	static let empty = ProjectEnvSchemaOverview(rules: [], groups: [])

	/// Declared keys from A to Z.
	let rules: [Rule]
	let groups: [Group]
	let publicKeys: Set<String>
	/// The resolved schema as compact JSON, which the bundled engine checks
	/// stored values against; nil for rules not built from a resolution.
	let effectiveSchema: Data?
	private let index: [String: Int]

	init(rules: [Rule], groups: [Group], effectiveSchema: Data? = nil) {
		let order = Dictionary(uniqueKeysWithValues: VaultKeySortOrder.sortedAscending(rules.map(\.key)).enumerated().map { ($1, $0) })
		self.rules = rules.sorted { order[$0.key, default: 0] < order[$1.key, default: 0] }
		self.groups = groups.sorted { $0.name < $1.name }
		publicKeys = Set(rules.lazy.filter(\.isPublic).map(\.key))
		self.effectiveSchema = effectiveSchema
		index = Dictionary(uniqueKeysWithValues: self.rules.enumerated().map { ($1.key, $0) })
	}

	init(resolution: RustSchemaEngine.Resolution) {
		var rules: [Rule] = []
		if case .object(let declarations)? = resolution.effective["vars"] {
			rules.reserveCapacity(declarations.count)
			for declaration in declarations {
				let source = resolution.origins[declaration.key]?.source
				rules.append(Rule(
					key: declaration.key,
					isPublic: declaration.value["client"] == .bool(true),
					source: source == "lpm.json" ? nil : source,
					badges: Self.badges(for: declaration.value)
				))
			}
		}
		var groups: [Group] = []
		if case .object(let declared)? = resolution.effective["groups"] {
			for group in declared {
				guard case .string(let mode)? = group.value["mode"], case .array(let values)? = group.value["vars"] else { continue }
				let members = values.compactMap { value -> String? in if case .string(let key) = value { key } else { nil } }
				let lead = switch mode {
				case "exactlyOne": "Exactly one of"
				case "atLeastOne": "At least one of"
				default: "All or none of"
				}
				groups.append(Group(name: group.key, summary: "\(lead) \(members.joined(separator: ", "))", members: members))
			}
		}
		self.init(rules: rules, groups: groups, effectiveSchema: try? resolution.effective.compactData(maximumBytes: Self.engineInputLimit))
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

	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.rules == rhs.rules && lhs.groups == rhs.groups && lhs.effectiveSchema == rhs.effectiveSchema
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
		let location = path.isEmpty
			? (diagnostic.source == nil ? "lpm.json › envSchema" : source)
			: "\(source) › \(path.joined(separator: "."))"
		let reason = diagnostic.message.map { $0.prefix(1).uppercased() + $0.dropFirst() }
			?? reasons[diagnostic.code]
			?? "Invalid declaration (\(diagnostic.code))."
		return Problem(location: location, reason: reason)
	}

	/// Plain words for the engine's definition codes when it gives no message.
	private static let reasons: [String: String] = {
		let limits = "The imported schemas exceed the LPM CLI's limits."
		return [
			"env.invalid_definition": "A declaration has an unknown field or a value of the wrong type.",
			"env.invalid_rule": "This rule is invalid.",
			"env.invalid_name": "A key or group name isn't a valid environment variable name.",
			"env.invalid_pattern": "This pattern isn't a valid regular expression.",
			"env.invalid_prefixes": "clientPrefixes is invalid.",
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
