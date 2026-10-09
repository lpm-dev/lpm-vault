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

		fileprivate init?(_ json: LPMConfigJSON) {
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

	func has(_ field: Field) -> Bool {
		field.names.contains { json[$0] != nil }
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
		set { setArray(newValue.map(\.json), for: "requiredIn") }
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
			return entries.compactMap { entry in
				guard let when = entry["when"], let scope = Scope(when), case .string(let value)? = entry["value"] else { return nil }
				return ScopedDefault(scope: scope, value: value)
			}
		}
		set {
			setArray(newValue.map { .object([.init(key: "when", value: $0.scope.json), .init(key: "value", value: .string($0.value))]) }, for: "defaultsIn")
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
	/// the LPM CLI rejects with a reason the editor shows.
	private mutating func setNumber(_ value: String?, for name: String) {
		guard let value, !value.isEmpty else { json.removeValue(forKey: name); return }
		json.set(Self.isJSONInteger(value) ? .number(value) : .string(value), forKey: name)
	}

	static func isJSONInteger(_ text: String) -> Bool {
		let digits = text.utf8.first == UInt8(ascii: "-") ? text.utf8.dropFirst() : text.utf8[...]
		guard let first = digits.first, digits.allSatisfy({ (48...57).contains($0) }) else { return false }
		return first != UInt8(ascii: "0") || digits.count == 1
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

	private mutating func setArray(_ values: [LPMConfigJSON], for name: String) {
		if values.isEmpty { json.removeValue(forKey: name) } else { json.set(.array(values), forKey: name) }
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
	/// Whether a row can be added, with the hint the "Add rule" menu shows.
	struct Availability: Equatable, Sendable {
		let isAvailable: Bool
		let hint: String
	}

	func availability(of field: Field, publicPrefix: String?) -> Availability {
		switch field {
		case .required: .init(isAvailable: true, hint: "every environment")
		case .requiredIn: .init(isAvailable: true, hint: "scopes")
		case .requiredWhen: .init(isAvailable: true, hint: "another key")
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
		case .secret: publicPrefix != nil ? .init(isAvailable: false, hint: "not for public keys") : .init(isAvailable: true, hint: "hidden in CLI output")
		case .client: publicPrefix != nil ? .init(isAvailable: false, hint: "from the name") : .init(isAvailable: false, hint: "needs a public prefix")
		case .ci: .init(isAvailable: true, hint: "secret / variable")
		}
	}

	/// A fix offered next to a conflict.
	enum Fix: Hashable, Sendable {
		case turnOffSecret
		case turnOffRequired
		case remove(Field)
		case setFormat(Format)
		case setCIStorage(CIStorage)

		var title: String {
			switch self {
			case .turnOffSecret: "Turn off Secret"
			case .turnOffRequired: "Turn off Required"
			case .remove: "Remove rule"
			case .setFormat(let format): "Use \(format.rawValue) format"
			case .setCIStorage(let storage): "Use CI \(storage.rawValue)"
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
	/// `secretKeys` are the declared keys whose values are secret.
	func conflicts(key: String, publicPrefix: String?, secretKeys: Set<String>) -> [Field: Conflict] {
		var conflicts: [Field: Conflict] = [:]
		if secret {
			if json["default"] != nil {
				conflicts[.defaultValue] = .init(kind: .blocking, message: "Secret keys can't have a default.", fixes: [.turnOffSecret, .remove(.defaultValue)])
			}
			if json["defaultsIn"] != nil {
				conflicts[.defaultsIn] = .init(kind: .blocking, message: "Secret keys can't have scoped defaults.", fixes: [.turnOffSecret, .remove(.defaultsIn)])
			}
			if json["enum"] != nil {
				conflicts[.allowedValues] = .init(kind: .blocking, message: "Secret keys can't have allowed values.", fixes: [.turnOffSecret, .remove(.allowedValues)])
			}
			if publicPrefix != nil || client {
				conflicts[.secret] = .init(kind: .blocking, message: "Public keys can't be secret.", fixes: [.turnOffSecret])
			}
			if ci == .variable {
				conflicts[.ci] = .init(kind: .blocking, message: "Secret keys can't use readable CI variables.", fixes: [.setCIStorage(.secret)])
			}
		}
		if client, publicPrefix == nil {
			conflicts[.client] = .init(kind: .blocking, message: "Public keys need a public prefix, such as NEXT_PUBLIC_ or one of the project's client prefixes.", fixes: [.remove(.client)])
		}
		if has(.bounds) {
			if format?.allowsBounds != true {
				conflicts[.bounds] = .init(kind: .blocking, message: "Min and max need the integer or port format.", fixes: [.setFormat(.integer), .remove(.bounds)])
			} else if let low = min.flatMap(Int64.init), let high = max.flatMap(Int64.init), low > high {
				conflicts[.bounds] = .init(kind: .blocking, message: "Min can't be more than max.", fixes: [])
			} else if let issue = Self.boundIssue(min) ?? Self.boundIssue(max) {
				conflicts[.bounds] = .init(kind: .blocking, message: issue, fixes: [])
			}
		}
		if has(.length) {
			if let issue = Self.lengthIssue(minLength) ?? Self.lengthIssue(maxLength) {
				conflicts[.length] = .init(kind: .blocking, message: issue, fixes: [])
			} else if let low = minLength.flatMap(UInt32.init), let high = maxLength.flatMap(UInt32.init), low > high {
				conflicts[.length] = .init(kind: .blocking, message: "The shortest length can't be more than the longest.", fixes: [])
			}
		}
		if let protocols {
			if format != .url {
				conflicts[.protocols] = .init(kind: .blocking, message: "Protocols need the url format.", fixes: [.setFormat(.url), .remove(.protocols)])
			} else if protocols.isEmpty {
				conflicts[.protocols] = .init(kind: .blocking, message: "Add at least one URL scheme.", fixes: [.remove(.protocols)])
			}
		}
		if let values = allowedValues, values.isEmpty, conflicts[.allowedValues] == nil {
			conflicts[.allowedValues] = .init(kind: .blocking, message: "Add at least one allowed value.", fixes: [.remove(.allowedValues)])
		}
		if empty == .reject, defaultValue == "" || defaultsIn.contains(where: { $0.value.isEmpty }), conflicts[.defaultValue] == nil {
			conflicts[.defaultValue] = .init(kind: .blocking, message: "An empty default can't be used while empty values are rejected.", fixes: [])
		}
		if let condition = requiredWhen {
			if condition.variable == key {
				conflicts[.requiredWhen] = .init(kind: .blocking, message: "A key can't depend on itself.", fixes: [.remove(.requiredWhen)])
			} else if case .equals = condition.condition, secretKeys.contains(condition.variable) {
				conflicts[.requiredWhen] = .init(kind: .blocking, message: "\(condition.variable) is secret, so its value can't be compared. Use “is set” or “is not set”.", fixes: [.remove(.requiredWhen)])
			}
		}
		let overlapping = defaultsIn.indices.contains { index in
			defaultsIn[(index + 1)...].contains { $0.scope.overlaps(defaultsIn[index].scope) }
		}
		if overlapping, conflicts[.defaultsIn] == nil {
			conflicts[.defaultsIn] = .init(kind: .blocking, message: "Scoped defaults overlap, so more than one could apply. Narrow them.", fixes: [])
		}
		if required {
			for field in [Field.requiredIn, .requiredWhen] where has(field) && conflicts[field] == nil {
				conflicts[field] = .init(kind: .noEffect, message: "No effect while Required is on.", fixes: [.remove(field)])
			}
		}
		return conflicts
	}

	private static func boundIssue(_ text: String?) -> String? {
		guard let text else { return nil }
		return isJSONInteger(text) && Int64(text) != nil ? nil : "Use a whole number."
	}

	private static func lengthIssue(_ text: String?) -> String? {
		guard let text else { return nil }
		return !text.hasPrefix("-") && isJSONInteger(text) && UInt32(text) != nil ? nil : "Use a whole number of characters."
	}

	/// Applies a fix.
	mutating func apply(_ fix: Fix) {
		switch fix {
		case .turnOffSecret: secret = false
		case .turnOffRequired: required = false
		case .remove(let field): remove(field)
		case .setFormat(let format): self.format = format
		case .setCIStorage(let storage): ci = storage
		}
	}
}
