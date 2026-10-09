import Foundation

/// One key's rule in lpm.json, read and written field by field. Fields keep
/// their place in the object, a new one goes last, and fields the editor
/// doesn't know stay as they are.
struct ProjectEnvSchemaRule: Equatable, Sendable {
	enum Section: CaseIterable, Sendable {
		case presence, shape, defaults, exposure

		var title: String {
			switch self {
			case .presence: "PRESENCE"
			case .shape: "SHAPE"
			case .defaults: "DEFAULTS"
			case .exposure: "EXPOSURE"
			}
		}
	}

	/// What the editor shows as one row; some rows hold two JSON fields.
	enum Field: CaseIterable, Hashable, Sendable {
		case required, requiredIn, requiredWhen, empty
		case format, bounds, length, protocols, pattern, allowedValues
		case defaultValue, defaultsIn
		case secret, client, ci

		var section: Section {
			switch self {
			case .required, .requiredIn, .requiredWhen, .empty: .presence
			case .format, .bounds, .length, .protocols, .pattern, .allowedValues: .shape
			case .defaultValue, .defaultsIn: .defaults
			case .secret, .client, .ci: .exposure
			}
		}

		var title: String {
			switch self {
			case .required: "Required"
			case .requiredIn: "Required in"
			case .requiredWhen: "Required when"
			case .empty: "Empty"
			case .format: "Format"
			case .bounds: "Min / max"
			case .length: "Length"
			case .protocols: "Protocols"
			case .pattern: "Pattern"
			case .allowedValues: "Allowed values"
			case .defaultValue: "Default"
			case .defaultsIn: "Default in"
			case .secret: "Secret"
			case .client: "Public"
			case .ci: "CI storage"
			}
		}

		/// The JSON fields of the row.
		var names: [String] {
			switch self {
			case .required: ["required"]
			case .requiredIn: ["requiredIn"]
			case .requiredWhen: ["requiredWhen"]
			case .empty: ["empty"]
			case .format: ["format"]
			case .bounds: ["min", "max"]
			case .length: ["minLength", "maxLength"]
			case .protocols: ["protocols"]
			case .pattern: ["pattern"]
			case .allowedValues: ["enum"]
			case .defaultValue: ["default"]
			case .defaultsIn: ["defaultsIn"]
			case .secret: ["secret"]
			case .client: ["client"]
			case .ci: ["ci"]
			}
		}

		/// The row a JSON field belongs to, such as `bounds` for "max".
		init?(name: String) {
			guard let field = Self.allCases.first(where: { $0.names.contains(name) }) else { return nil }
			self = field
		}
	}

	enum Format: String, CaseIterable, Sendable {
		case url, port, email, boolean, integer, hostname, ip

		var title: String {
			switch self {
			case .url: "URL"
			case .port: "Port"
			case .email: "Email"
			case .boolean: "Boolean"
			case .integer: "Integer"
			case .hostname: "Hostname"
			case .ip: "IP"
			}
		}

		var allowsBounds: Bool { self == .integer || self == .port }
	}

	enum EmptyPolicy: String, CaseIterable, Sendable {
		/// The default: an empty value counts as unset, so defaults apply.
		case missing
		case allow
		case reject

		var title: String {
			switch self {
			case .missing: "Unset"
			case .allow: "Allow"
			case .reject: "Reject"
			}
		}
	}

	enum CIStorage: String, CaseIterable, Sendable {
		case secret, variable
	}

	enum Stage: String, CaseIterable, Sendable {
		case development, build, runtime, ci, test
	}

	/// Contexts where a rule applies: any of the listed values in each listed
	/// dimension, and every listed dimension.
	struct Scope: Hashable, Sendable {
		var environments: [String] = []
		var stages: [Stage] = []
		var services: [String] = []

		var isEmpty: Bool { environments.isEmpty && stages.isEmpty && services.isEmpty }

		/// Why the LPM CLI rejects the scope, if it does.
		var issue: String? {
			if isEmpty { return "A scope needs an environment, stage or service." }
			for names in [environments, services] {
				var seen = Set<String>()
				for name in names {
					if !EnvValidation.isValidEnvironmentName(name) {
						return "“\(name.escapingDirectionControls)” isn't a valid name. Use letters, digits, “.”, “_” and “-”, up to 64 characters."
					}
					if !seen.insert(name).inserted { return "“\(name.escapingDirectionControls)” is listed twice in one scope." }
				}
			}
			return Set(stages).count == stages.count ? nil : "A stage is listed twice in one scope."
		}

		/// Whether the LPM CLI counts both as one scope: the same names in
		/// each dimension, in any order, where no stages means every stage.
		func isEquivalent(to other: Scope) -> Bool {
			let all = Set(Stage.allCases)
			return Set(environments) == Set(other.environments) && Set(services) == Set(other.services)
				&& (stages.isEmpty ? all : Set(stages)) == (other.stages.isEmpty ? all : Set(other.stages))
		}

		/// Such as "production · runtime".
		var summary: String {
			var parts: [String] = []
			if !environments.isEmpty { parts.append(environments.joined(separator: ", ")) }
			if !stages.isEmpty { parts.append(stages.map(\.rawValue).joined(separator: ", ")) }
			if !services.isEmpty { parts.append(services.joined(separator: ", ")) }
			return parts.joined(separator: " · ")
		}

		/// Whether some context matches both scopes.
		func overlaps(_ other: Scope) -> Bool {
			func meets<T: Hashable>(_ a: [T], _ b: [T]) -> Bool { a.isEmpty || b.isEmpty || !Set(a).isDisjoint(with: b) }
			return meets(environments, other.environments) && meets(stages, other.stages) && meets(services, other.services)
		}

		init(environments: [String] = [], stages: [Stage] = [], services: [String] = []) {
			self.environments = environments
			self.stages = stages
			self.services = services
		}

		init?(_ json: LPMConfigJSON) {
			guard case .object = json else { return nil }
			environments = Self.names(json["environment"])
			stages = Self.names(json["stage"]).compactMap(Stage.init(rawValue:))
			services = Self.names(json["service"])
		}

		fileprivate var json: LPMConfigJSON {
			var members: [LPMConfigJSON.Member] = []
			if !environments.isEmpty { members.append(.init(key: "environment", value: .array(environments.map(LPMConfigJSON.string)))) }
			if !stages.isEmpty { members.append(.init(key: "stage", value: .array(stages.map { .string($0.rawValue) }))) }
			if !services.isEmpty { members.append(.init(key: "service", value: .array(services.map(LPMConfigJSON.string)))) }
			return .object(members)
		}

		private static func names(_ value: LPMConfigJSON?) -> [String] {
			switch value {
			case .string(let name)?: [name]
			case .array(let values)?: values.compactMap { if case .string(let name) = $0 { name } else { nil } }
			default: []
			}
		}
	}

	struct ScopedDefault: Hashable, Sendable {
		var scope: Scope
		var value: String
	}

	struct RequiredWhen: Hashable, Sendable {
		enum Condition: Hashable, Sendable {
			case equals(String)
			case present(Bool)
		}

		var variable: String
		var condition: Condition
	}

	private(set) var json: LPMConfigJSON

	init(_ json: LPMConfigJSON? = nil) {
		if let json, case .object = json { self.json = json } else { self.json = .object([]) }
	}

	/// A rule as the engine resolves it, without the fields it fills in with
	/// their defaults, so it reads, and saves as an override, like a rule a
	/// person wrote. Bounds the engine writes as text go back to numbers.
	init(resolved json: LPMConfigJSON?) {
		self.init(json)
		guard case .object(let members) = self.json else { return }
		self.json = .object(members.compactMap { member in
			switch (member.key, member.value) {
			case (_, .null): nil
			case ("required", .bool(false)), ("secret", .bool(false)), ("client", .bool(false)): nil
			case ("empty", .string("missing")): nil
			case ("requiredIn", .array([])), ("defaultsIn", .array([])): nil
			case ("min", .string(let text)), ("max", .string(let text)), ("minLength", .string(let text)), ("maxLength", .string(let text)):
				Self.isJSONInteger(text) ? .init(key: member.key, value: .number(text)) : member
			default: member
			}
		})
	}

	/// Whether the rule sets the row; null leaves a field unset, as it does for the LPM CLI.
	func has(_ field: Field) -> Bool {
		field.names.contains { name in json[name].map { $0 != .null } ?? false }
	}

	mutating func remove(_ field: Field) {
		for name in field.names { json.removeValue(forKey: name) }
	}

	// MARK: - Fields

	var description: String? {
		get { text("description") }
		set { setText(newValue, for: "description") }
	}

	var required: Bool {
		get { json["required"] == .bool(true) }
		set { setFlag(newValue, for: "required") }
	}

	var requiredIn: [Scope] {
		get { scopes("requiredIn") }
		set { setEntries(newValue, for: "requiredIn", reading: Scope.init, writing: \.json) }
	}

	var requiredWhen: RequiredWhen? {
		get {
			guard case .string(let variable)? = json["requiredWhen"]?["variable"] else { return nil }
			if case .string(let value)? = json["requiredWhen"]?["equals"] { return RequiredWhen(variable: variable, condition: .equals(value)) }
			if case .bool(let present)? = json["requiredWhen"]?["present"] { return RequiredWhen(variable: variable, condition: .present(present)) }
			return nil
		}
		set {
			guard let newValue else { json.removeValue(forKey: "requiredWhen"); return }
			let condition: LPMConfigJSON.Member = switch newValue.condition {
			case .equals(let value): .init(key: "equals", value: .string(value))
			case .present(let present): .init(key: "present", value: .bool(present))
			}
			json.set(.object([.init(key: "variable", value: .string(newValue.variable)), condition]), forKey: "requiredWhen")
		}
	}

	var empty: EmptyPolicy {
		get { text("empty").flatMap(EmptyPolicy.init(rawValue:)) ?? .missing }
		set {
			if newValue == .missing { json.removeValue(forKey: "empty") } else { json.set(.string(newValue.rawValue), forKey: "empty") }
		}
	}

	var format: Format? {
		get { text("format").flatMap(Format.init(rawValue:)) }
		set { setText(newValue?.rawValue, for: "format") }
	}

	/// Bounds as the text they're written with in lpm.json.
	var min: String? {
		get { number("min") }
		set { setNumber(newValue, for: "min") }
	}

	var max: String? {
		get { number("max") }
		set { setNumber(newValue, for: "max") }
	}

	var minLength: String? {
		get { number("minLength") }
		set { setNumber(newValue, for: "minLength") }
	}

	var maxLength: String? {
		get { number("maxLength") }
		set { setNumber(newValue, for: "maxLength") }
	}

	var protocols: [String]? {
		get { strings("protocols") }
		set { setStrings(newValue, for: "protocols") }
	}

	var pattern: String? {
		get { text("pattern") }
		set { setText(newValue, for: "pattern") }
	}

	var allowedValues: [String]? {
		get { strings("enum") }
		set { setStrings(newValue, for: "enum") }
	}

	var defaultValue: String? {
		get { text("default") }
		set { setText(newValue, for: "default") }
	}

	var defaultsIn: [ScopedDefault] {
		get {
			guard case .array(let entries)? = json["defaultsIn"] else { return [] }
			return entries.compactMap(Self.scopedDefault)
		}
		set {
			setEntries(newValue, for: "defaultsIn", reading: Self.scopedDefault) {
				.object([.init(key: "when", value: $0.scope.json), .init(key: "value", value: .string($0.value))])
			}
		}
	}

	var secret: Bool {
		get { json["secret"] == .bool(true) }
		set { setFlag(newValue, for: "secret") }
	}

	var client: Bool {
		get { json["client"] == .bool(true) }
		set { setFlag(newValue, for: "client") }
	}

	var ci: CIStorage? {
		get { text("ci").flatMap(CIStorage.init(rawValue:)) }
		set { setText(newValue?.rawValue, for: "ci") }
	}

	// MARK: - JSON

	private func text(_ name: String) -> String? {
		if case .string(let value)? = json[name] { value } else { nil }
	}

	/// Clearing a field removes it from the rule.
	private mutating func setText(_ value: String?, for name: String) {
		if let value, !value.isEmpty { json.set(.string(value), forKey: name) } else { json.removeValue(forKey: name) }
	}

	/// A false flag is the default, so it leaves the rule.
	private mutating func setFlag(_ value: Bool, for name: String) {
		if value { json.set(.bool(true), forKey: name) } else { json.removeValue(forKey: name) }
	}

	private func number(_ name: String) -> String? {
		switch json[name] {
		case .number(let text)?, .string(let text)?: text
		default: nil
		}
	}

	/// Writes whole numbers as JSON numbers and anything else as text, which
	/// the LPM CLI reads as decimal text or rejects with a reason the editor shows.
	private mutating func setNumber(_ value: String?, for name: String) {
		guard let value, !value.isEmpty else { json.removeValue(forKey: name); return }
		json.set(Self.isJSONInteger(value) ? .number(value) : .string(value), forKey: name)
	}

	/// Whether `text` is a JSON integer the LPM CLI reads as one. It reads -0
	/// as a fraction, so that's written as text.
	static func isJSONInteger(_ text: String) -> Bool {
		let digits = text.utf8.first == UInt8(ascii: "-") ? text.utf8.dropFirst() : text.utf8[...]
		guard let first = digits.first, digits.allSatisfy({ (48...57).contains($0) }) else { return false }
		return first != UInt8(ascii: "0") || digits.count == 1 && digits.count == text.utf8.count
	}

	private func strings(_ name: String) -> [String]? {
		guard case .array(let values)? = json[name] else { return nil }
		return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
	}

	/// An empty list stays, so a row the person just added keeps its place; the
	/// LPM CLI's reason for rejecting it shows until a value is added.
	private mutating func setStrings(_ values: [String]?, for name: String) {
		guard let values else { json.removeValue(forKey: name); return }
		json.set(.array(values.map(LPMConfigJSON.string)), forKey: name)
	}

	private func scopes(_ name: String) -> [Scope] {
		guard case .array(let entries)? = json[name] else { return [] }
		return entries.compactMap(Scope.init)
	}

	private static func scopedDefault(_ entry: LPMConfigJSON) -> ScopedDefault? {
		guard let when = entry["when"], let scope = Scope(when), case .string(let value)? = entry["value"] else { return nil }
		return ScopedDefault(scope: scope, value: value)
	}

	/// Writes a list, keeping each entry that reads the same as it's written in
	/// lpm.json, so entries nobody changed keep their form.
	private mutating func setEntries<Entry: Equatable>(
		_ entries: [Entry], for name: String, reading read: (LPMConfigJSON) -> Entry?, writing write: (Entry) -> LPMConfigJSON
	) {
		guard !entries.isEmpty else { json.removeValue(forKey: name); return }
		var written: [(json: LPMConfigJSON, entry: Entry?)] = if case .array(let old)? = json[name] { old.map { ($0, read($0)) } } else { [] }
		json.set(.array(entries.map { entry in
			if let index = written.firstIndex(where: { $0.entry == entry }) { return written.remove(at: index).json }
			return write(entry)
		}), forKey: name)
	}
}

// MARK: - Public prefixes

extension ProjectEnvSchemaRule {
	/// Prefixes the frameworks the LPM CLI knows expose to the browser.
	static let frameworkPrefixes = ["NEXT_PUBLIC_", "VITE_", "PUBLIC_", "EXPO_PUBLIC_", "GATSBY_", "NUXT_PUBLIC_", "REACT_APP_"]

	/// The prefix that makes `key` public, as the LPM CLI decides it: a
	/// framework's, or one of the project's client prefixes.
	static func publicPrefix(of key: String, clientPrefixes: [String]) -> String? {
		if key.utf8.count >= 10, key.utf8.prefix(10).elementsEqual("REACT_APP_".utf8, by: { ($0 >= 97 && $0 <= 122 ? $0 - 32 : $0) == $1 }) {
			return "REACT_APP_"
		}
		if let prefix = frameworkPrefixes.first(where: { $0 != "REACT_APP_" && key.hasPrefix($0) }) { return prefix }
		return clientPrefixes.first { key.hasPrefix($0) }
	}
}

// MARK: - Availability and conflicts

extension ProjectEnvSchemaRule {
	/// What a rule's conflicts depend on beyond the rule itself.
	struct Context: Sendable {
		let key: String
		/// The prefix that makes the key public, if any.
		var publicPrefix: String?
		/// Declared keys whose values are secret.
		var secretKeys: Set<String> = []
		/// Declared keys whose Required when compares this key's value.
		var comparedBy: [String] = []
		/// The keys Required when can name; nil when they aren't known.
		var declaredKeys: Set<String>?
	}

	/// Whether a row can be added, with the hint the "Add rule" menu shows.
	struct Availability: Equatable, Sendable {
		let isAvailable: Bool
		let hint: String
	}

	func availability(of field: Field, in context: Context) -> Availability {
		switch field {
		case .required: .init(isAvailable: true, hint: "every environment")
		case .requiredIn: .init(isAvailable: true, hint: "scopes")
		case .requiredWhen:
			context.declaredKeys?.contains(where: { $0 != context.key }) == false
				? .init(isAvailable: false, hint: "no other keys") : .init(isAvailable: true, hint: "another key")
		case .empty: .init(isAvailable: true, hint: "unset / allow / reject")
		case .format: .init(isAvailable: true, hint: "url, port, email…")
		case .bounds:
			format?.allowsBounds == true ? .init(isAvailable: true, hint: "inclusive bounds") : .init(isAvailable: false, hint: "needs integer or port format")
		case .length: .init(isAvailable: true, hint: "chars")
		case .protocols:
			format == .url ? .init(isAvailable: true, hint: "url schemes") : .init(isAvailable: false, hint: "needs url format")
		case .pattern: .init(isAvailable: true, hint: "regular expression")
		case .allowedValues: secret ? .init(isAvailable: false, hint: "not for secret keys") : .init(isAvailable: true, hint: "enum")
		case .defaultValue: secret ? .init(isAvailable: false, hint: "not for secret keys") : .init(isAvailable: true, hint: "value")
		case .defaultsIn: secret ? .init(isAvailable: false, hint: "not for secret keys") : .init(isAvailable: true, hint: "per scope")
		case .secret:
			if context.publicPrefix != nil { .init(isAvailable: false, hint: "not for public keys") }
			else if let source = context.comparedBy.first { .init(isAvailable: false, hint: "\(source) compares its value") }
			else { .init(isAvailable: true, hint: "hidden in CLI output") }
		case .client: context.publicPrefix != nil ? .init(isAvailable: false, hint: "from the name") : .init(isAvailable: false, hint: "needs a public prefix")
		case .ci: .init(isAvailable: true, hint: "secret / variable")
		}
	}

	/// A fix offered next to a conflict.
	enum Fix: Hashable, Sendable {
		case turnOffSecret
		case turnOnPublic
		case remove(Field)
		case setFormat(Format)
		case setCIStorage(CIStorage)
		/// Required when checks whether the key is set instead of comparing its value.
		case usePresence

		var title: String {
			switch self {
			case .turnOffSecret: "Turn off Secret"
			case .turnOnPublic: "Make public"
			case .remove: "Remove rule"
			case .setFormat(let format): "Use \(format.rawValue) format"
			case .setCIStorage(let storage): "Use CI \(storage.rawValue)"
			case .usePresence: "Use “is set”"
			}
		}
	}

	/// Why a row can't stay as it is, or has no effect, with ways to settle it.
	struct Conflict: Equatable, Sendable {
		enum Kind: Equatable, Sendable {
			/// The LPM CLI rejects the rule until it's settled.
			case blocking
			/// Allowed, but it changes nothing.
			case noEffect
		}

		let kind: Kind
		let message: String
		let fixes: [Fix]
	}

	/// What blocks each row, or makes it pointless, as the LPM CLI sees it.
	func conflicts(in context: Context) -> [Field: Conflict] {
		var conflicts: [Field: Conflict] = [:]
		func block(_ field: Field, _ message: String, _ fixes: [Fix] = []) {
			if conflicts[field] == nil { conflicts[field] = .init(kind: .blocking, message: message, fixes: fixes) }
		}
		if secret {
			if has(.defaultValue) { block(.defaultValue, "Secret keys can't have a default.", [.turnOffSecret, .remove(.defaultValue)]) }
			if has(.defaultsIn) { block(.defaultsIn, "Secret keys can't have scoped defaults.", [.turnOffSecret, .remove(.defaultsIn)]) }
			if has(.allowedValues) { block(.allowedValues, "Secret keys can't have allowed values.", [.turnOffSecret, .remove(.allowedValues)]) }
			if context.publicPrefix != nil || client {
				block(.secret, "Public keys can't be secret.", [.turnOffSecret])
			} else if let source = context.comparedBy.first {
				block(.secret, "\(source) compares this key's value in Required when, so it can't be secret.", [.turnOffSecret])
			}
			if ci == .variable { block(.ci, "Secret keys can't use readable CI variables.", [.setCIStorage(.secret)]) }
		}
		if client, context.publicPrefix == nil {
			block(.client, "Public keys need a public prefix, such as NEXT_PUBLIC_ or one of the project's client prefixes.", [.remove(.client)])
		} else if let prefix = context.publicPrefix, !client, !secret {
			block(.client, "Keys starting with \(prefix) are public.", [.turnOnPublic])
		}
		if has(.bounds) {
			let low = Self.bound(json["min"]), high = Self.bound(json["max"])
			if format?.allowsBounds != true {
				block(.bounds, "Min and max need the integer or port format.", [.setFormat(.integer), .remove(.bounds)])
			} else if let issue = low.issue ?? high.issue {
				block(.bounds, issue)
			} else if let low = low.value, let high = high.value, low > high {
				block(.bounds, "Min can't be more than max.")
			} else if format == .port, low.value.map({ $0 > 65535 }) == true || high.value.map({ $0 < 1 }) == true {
				block(.bounds, "These bounds leave no valid port, which runs from 1 to 65535.")
			}
		}
		if has(.length) {
			let low = Self.length(json["minLength"]), high = Self.length(json["maxLength"])
			if let issue = low.issue ?? high.issue {
				block(.length, issue)
			} else if let low = low.value, let high = high.value, low > high {
				block(.length, "The shortest length can't be more than the longest.")
			}
		}
		if has(.protocols), let protocols {
			if format != .url {
				block(.protocols, "Protocols need the url format.", [.setFormat(.url), .remove(.protocols)])
			} else if protocols.isEmpty {
				block(.protocols, "Add at least one URL scheme.", [.remove(.protocols)])
			} else if protocols.count > 32 {
				block(.protocols, "List at most 32 URL schemes.")
			} else if let scheme = protocols.first(where: { !Self.isURLScheme($0) }) {
				block(.protocols, "“\(scheme.escapingDirectionControls)” isn't a URL scheme. Use lowercase letters, digits, “+”, “.” and “-”, starting with a letter, without a colon.")
			} else if Set(protocols).count != protocols.count {
				block(.protocols, "A URL scheme is listed twice.")
			}
		}
		if let values = allowedValues, values.isEmpty {
			block(.allowedValues, "Add at least one allowed value.", [.remove(.allowedValues)])
		}
		if empty == .reject {
			if defaultValue == "" { block(.defaultValue, "An empty default can't be used while empty values are rejected.", [.remove(.defaultValue)]) }
			if defaultsIn.contains(where: { $0.value.isEmpty }) { block(.defaultsIn, "An empty scoped default can't be used while empty values are rejected.") }
		} else if required {
			if defaultValue == "" { block(.defaultValue, "An empty default can't satisfy Required.", [.remove(.defaultValue)]) }
			if defaultsIn.contains(where: { $0.value.isEmpty }) { block(.defaultsIn, "An empty scoped default can't satisfy Required.") }
		}
		if let condition = requiredWhen {
			if condition.variable == context.key {
				let pointless = switch condition.condition {
				case .present(let present): present
				case .equals(let value): !value.isEmpty
				}
				if pointless {
					conflicts[.requiredWhen] = .init(kind: .noEffect, message: "No effect: it depends on the key itself.", fixes: [.remove(.requiredWhen)])
				}
			} else if let declared = context.declaredKeys, !declared.contains(condition.variable) {
				block(.requiredWhen, "\(condition.variable) isn't declared.", [.remove(.requiredWhen)])
			} else if case .equals = condition.condition, context.secretKeys.contains(condition.variable) {
				block(.requiredWhen, "\(condition.variable) is secret, so its value can't be compared.", [.usePresence, .remove(.requiredWhen)])
			}
		}
		for (field, scopes) in [(Field.requiredIn, requiredIn), (.defaultsIn, defaultsIn.map(\.scope))] where !scopes.isEmpty {
			if scopes.count > 32 {
				block(field, "A rule can have at most 32 scopes here.")
			} else if let issue = scopes.lazy.compactMap(\.issue).first {
				block(field, issue)
			}
		}
		let scopes = requiredIn
		if scopes.indices.contains(where: { index in scopes[(index + 1)...].contains { $0.isEquivalent(to: scopes[index]) } }) {
			block(.requiredIn, "Two scopes are the same.")
		}
		let defaults = defaultsIn
		if defaults.indices.contains(where: { index in defaults[(index + 1)...].contains { $0.scope.overlaps(defaults[index].scope) } }) {
			block(.defaultsIn, "Scoped defaults overlap, so more than one could apply. Narrow them.")
		}
		if required {
			for field in [Field.requiredIn, .requiredWhen] where has(field) && conflicts[field] == nil {
				conflicts[field] = .init(kind: .noEffect, message: "No effect while Required is on.", fixes: [.remove(field)])
			}
		}
		return conflicts
	}

	/// A bound as the LPM CLI reads it, or why it can't.
	private struct Bound<Value> {
		var value: Value?
		var issue: String?
	}

	/// A whole JSON number, or decimal text of up to 19 digits with an optional sign.
	private static func bound(_ json: LPMConfigJSON?) -> Bound<Int64> {
		let malformed = Bound<Int64>(issue: "Use a whole number.")
		let range = Bound<Int64>(issue: "Use a whole number from \(Int64.min) to \(Int64.max).")
		switch json {
		case .number(let text)?:
			guard isJSONInteger(text) else { return malformed }
			return Int64(text).map { Bound(value: $0) } ?? range
		case .string(let text)?:
			let digits = text.utf8.first.map { $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") } == true ? text.utf8.dropFirst() : text.utf8[...]
			guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return malformed }
			guard digits.count <= 19, let value = Int64(text) else { return range }
			return Bound(value: value)
		case nil, .null?: return Bound()
		default: return malformed
		}
	}

	/// A whole JSON number, or decimal text of up to 10 digits, within 32 bits.
	private static func length(_ json: LPMConfigJSON?) -> Bound<UInt32> {
		let malformed = Bound<UInt32>(issue: "Use a whole number of characters.")
		let range = Bound<UInt32>(issue: "Use at most \(UInt32.max) characters.")
		switch json {
		case .number(let text)?:
			guard isJSONInteger(text), !text.hasPrefix("-") else { return malformed }
			return UInt32(text).map { Bound(value: $0) } ?? range
		case .string(let text)?:
			guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return malformed }
			guard text.utf8.count <= 10, let value = UInt32(text) else { return range }
			return Bound(value: value)
		case nil, .null?: return Bound()
		default: return malformed
		}
	}

	/// A lowercase URL scheme without its colon, as the LPM CLI accepts one.
	static func isURLScheme(_ text: String) -> Bool {
		guard let first = text.utf8.first, (97...122).contains(first), text.utf8.count <= 256 else { return false }
		return text.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") }
	}

	/// Applies a fix.
	mutating func apply(_ fix: Fix) {
		switch fix {
		case .turnOffSecret: secret = false
		case .turnOnPublic: client = true
		case .remove(let field): remove(field)
		case .setFormat(let format): self.format = format
		case .setCIStorage(let storage): ci = storage
		case .usePresence:
			if let condition = requiredWhen { requiredWhen = .init(variable: condition.variable, condition: .present(true)) }
		}
	}
}
