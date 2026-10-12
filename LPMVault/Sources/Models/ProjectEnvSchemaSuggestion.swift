import Foundation

/// A rule a stored key's values already follow, suggested when the key is
/// declared. The bundled engine decides whether every value passes, as the
/// LPM CLI would. A suggestion names its evidence, never a value, and a
/// default is never suggested: lpm.json is shared, and a value may be secret.
struct ProjectEnvSchemaSuggestion: Equatable, Identifiable, Sendable {
	enum Change: Equatable, Sendable {
		case format(ProjectEnvSchemaRule.Format)
		case protocols([String])
		case secret
	}

	let change: Change
	/// Why, without values: "all 3 values are URLs".
	let evidence: String

	var id: String {
		switch change {
		case .format(let format): "format:\(format.rawValue)"
		case .protocols(let schemes): "protocols:\(schemes.joined(separator: ","))"
		case .secret: "secret"
		}
	}

	/// The rule as a badge would name it, such as "URL" or "redis only".
	var title: String {
		switch change {
		case .format(let format): format.title
		case .protocols(let schemes): "\(schemes.joined(separator: ", ")) only"
		case .secret: "Secret"
		}
	}

	func isApplied(in rule: ProjectEnvSchemaRule) -> Bool {
		switch change {
		case .format(let format): rule.format == format
		case .protocols(let schemes): rule.protocols == schemes
		case .secret: rule.secret
		}
	}

	func apply(to rule: inout ProjectEnvSchemaRule) {
		switch change {
		case .format(let format): rule.format = format
		case .protocols(let schemes):
			if rule.format != .url { rule.format = .url }
			rule.protocols = schemes
		case .secret: rule.secret = true
		}
	}

	func undo(in rule: inout ProjectEnvSchemaRule) {
		switch change {
		case .format: rule.remove(.format); rule.remove(.bounds); rule.remove(.protocols)
		case .protocols: rule.remove(.protocols)
		case .secret: rule.secret = false
		}
	}

	/// Formats from most to least specific; the first every value passes wins.
	/// A value passing isn't enough on its own for the formats many values
	/// pass: port needs PORT as a word of the name, since many numbers are
	/// valid ports; boolean needs words, since 1 and 0 are numbers first; and
	/// hostname needs a name that says so and dotted names, since a single word
	/// or a file name is a valid one.
	private static func formats(for words: Set<String>, values: [String]) -> [ProjectEnvSchemaRule.Format] {
		// No value of the other formats is this long; a long value is a URL or none.
		if values.contains(where: { $0.utf8.count > 254 }) { return [.url] }
		var formats: [ProjectEnvSchemaRule.Format] = []
		if words.contains("PORT") { formats.append(.port) }
		if values.contains(where: { $0.contains(where: \.isLetter) }) { formats.append(.boolean) }
		formats += [.integer, .url, .email, .ip]
		if !words.isDisjoint(with: hostWords), values.allSatisfy(looksLikeHostname) { formats.append(.hostname) }
		return formats
	}

	/// What the `values` stored for `key`, one per environment that stores it,
	/// suggest, for a key `publicPrefix` makes public with the project's
	/// `clientPrefixes`. Reads nothing but the values given, which never leave
	/// this computation. A key the LPM CLI never passes to a process gets none,
	/// and a cancelled task stops between the engine's checks with none.
	static func suggestions(for key: String, values: [String], publicPrefix: String?, clientPrefixes: [String] = []) -> [ProjectEnvSchemaSuggestion] {
		let stored = values.filter { !$0.isEmpty }
		guard !stored.isEmpty else { return [] }
		let distinct = Array(Set(stored)).sorted()
		let engine = Engine(key: key, values: distinct, isPublic: publicPrefix != nil, clientPrefixes: clientPrefixes)
		guard let baseline = engine.check([:]), !baseline.environments.values.contains(where: { $0.ignored.contains(key) }) else { return [] }
		let parts = key.uppercased().split(separator: "_").map(String.init)
		let words = Set(parts)
		var suggestions: [ProjectEnvSchemaSuggestion] = []
		let format = formats(for: words, values: distinct).first { engine.passes(["format": .string($0.rawValue)]) }
		if let format {
			suggestions.append(.init(change: .format(format), evidence: evidence(for: format, count: stored.count)))
		}
		if format == .url {
			let schemes = Set(distinct.compactMap { URLComponents(string: $0)?.scheme?.lowercased() })
			// A scheme is written into lpm.json, so only one short enough to be a real one.
			if schemes.count == 1, let scheme = schemes.first, scheme.utf8.count <= 16,
				engine.passes(["format": .string("url"), "protocols": .array([.string(scheme)])])
			{
				let subject = switch stored.count { case 1: "uses"; case 2: "both use"; default: "all use" }
				suggestions.append(.init(change: .protocols([scheme]), evidence: "\(subject) the \(scheme) scheme"))
			}
		}
		if publicPrefix == nil, words.isDisjoint(with: publicWords),
			let reason = secretEvidence(parts: parts, values: distinct, count: stored.count, format: format)
		{
			suggestions.append(.init(change: .secret, evidence: reason))
		}
		return Task.isCancelled ? [] : suggestions
	}

	/// Why a key whose name says it's secret shouldn't be public, when a
	/// public prefix makes it so. Keys named for tokens and keys aren't
	/// warned about: browser SDKs take public ones by design.
	static func exposureWarning(for key: String, publicPrefix: String?) -> String? {
		guard let publicPrefix, key.uppercased().split(separator: "_").contains(where: { exposedSecretWords.contains(String($0)) }) else { return nil }
		return "Its name says it's secret, but \(publicPrefix) makes it public: the LPM CLI exposes its value to the browser."
	}

	/// A name that looks like a pasted credential, such as a GitHub or AWS
	/// token, rather than a key's name: long, random, with digits, and either
	/// mixed case or without the underscores names have.
	static func looksLikeCredential(_ name: String) -> Bool {
		guard looksRandom(name) else { return false }
		var digits = 0
		var lower = false
		var upper = false
		for byte in name.utf8 {
			switch byte {
			case 48...57: digits += 1
			case 97...122: lower = true
			case 65...90: upper = true
			default: break
			}
		}
		return digits >= 2 && ((lower && upper) || !name.utf8.contains(95))
	}

	/// Checks the stored values of one key against rules with the bundled engine.
	private struct Engine {
		let key: String
		let values: [String]
		/// A public prefix makes the key public, which the engine requires the rule to say.
		let isPublic: Bool
		let clientPrefixes: [String]

		func passes(_ rule: [String: LPMConfigJSON]) -> Bool {
			check(rule)?.environments.values.allSatisfy { $0.problems.isEmpty } ?? false
		}

		/// The engine's check of the values, one environment each, against `rule`.
		func check(_ rule: [String: LPMConfigJSON]) -> ProjectEnvValueCheck? {
			guard !Task.isCancelled else { return nil }
			var rule = rule
			if isPublic { rule["client"] = .bool(true) }
			var members: [LPMConfigJSON.Member] = []
			if !clientPrefixes.isEmpty { members.append(.init(key: "clientPrefixes", value: .array(clientPrefixes.map(LPMConfigJSON.string)))) }
			members.append(.init(key: "vars", value: .object([
				.init(key: key, value: .object(rule.sorted { $0.key < $1.key }.map { .init(key: $0.key, value: $0.value) })),
			])))
			let schema = LPMConfigJSON.object(members)
			let environments = LPMConfigJSON.object([.init(key: "environments", value: .object(values.enumerated().map { index, value in
				.init(key: "e\(index)", value: .object([.init(key: key, value: .string(value))]))
			}))])
			guard let schemaData = try? schema.compactData(maximumBytes: 2 * 1024 * 1024),
				let valuesData = try? environments.compactData(maximumBytes: 2 * 1024 * 1024),
				let output = RustSchemaEngine.check(schema: schemaData, values: valuesData)
			else { return nil }
			return ProjectEnvValueCheck(output: output)
		}
	}

	private static func evidence(for format: ProjectEnvSchemaRule.Format, count: Int) -> String {
		let noun = switch format {
		case .url: count == 1 ? "a URL" : "URLs"
		case .port: count == 1 ? "a whole number from 1 to 65535" : "whole numbers from 1 to 65535"
		case .integer: count == 1 ? "a whole number" : "whole numbers"
		case .boolean: count == 1 ? "a boolean" : "booleans"
		case .email: count == 1 ? "an email address" : "email addresses"
		case .ip: count == 1 ? "an IP address" : "IP addresses"
		case .hostname: count == 1 ? "a hostname" : "hostnames"
		}
		return switch count {
		case 1: "the value is \(noun)"
		case 2: "both values are \(noun)"
		default: "all \(count) values are \(noun)"
		}
	}

	/// Words of a name that say its value is a host.
	private static let hostWords: Set<String> = ["HOST", "HOSTNAME", "DOMAIN", "SERVER"]
	/// Words of a name that say a key is secret.
	private static let secretWords: Set<String> = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "PRIVATE", "CREDENTIAL", "CREDENTIALS", "APIKEY"]
	/// Words of a name that say a key is secret, which a public one shouldn't be.
	private static let exposedSecretWords: Set<String> = ["SECRET", "PASSWORD", "PASSWD", "PRIVATE", "CREDENTIAL", "CREDENTIALS"]
	/// Words of a name that say its value is meant to be seen, however it looks.
	private static let publicWords: Set<String> = ["PUBLIC", "PUBLISHABLE"]
	/// Words of a name for identifiers, whose values look random without being secret.
	private static let identifierWords: Set<String> = ["ID", "SHA", "HASH", "COMMIT", "REVISION", "VERSION", "BUILD"]

	/// Why the key looks secret: its name says so, whatever its format; a URL
	/// carries a password; or values without a format look random and the
	/// name isn't an identifier's. A name ending in KEY says so only for long
	/// values, since sort and cache keys are short words.
	private static func secretEvidence(parts: [String], values: [String], count: Int, format: ProjectEnvSchemaRule.Format?) -> String? {
		if parts.contains(where: secretWords.contains) {
			return "the name says it's secret"
		}
		if parts.count >= 2, parts.last == "KEY", values.allSatisfy({ $0.utf8.count >= 16 && !$0.contains(where: \.isWhitespace) }) {
			return "the name says it's secret"
		}
		if format == .url, values.contains(where: { URLComponents(string: $0)?.password?.isEmpty == false }) {
			return count == 1 ? "the URL contains a password" : "a stored URL contains a password"
		}
		guard format == nil, !parts.contains(where: identifierWords.contains), values.allSatisfy(looksRandom) else { return nil }
		return count == 1 ? "the value looks random" : "values look random"
	}

	/// A dotted name ending in a word, such as db.example.com, or localhost.
	private static func looksLikeHostname(_ value: String) -> Bool {
		if value == "localhost" { return true }
		guard let last = value.split(separator: ".", omittingEmptySubsequences: false).last, value.contains("."),
			!last.isEmpty, last.allSatisfy({ $0.isASCII && $0.isLetter })
		else { return false }
		return !looksRandom(value)
	}

	/// Long, without spaces, and with high entropy per character, as keys and tokens are.
	private static func looksRandom(_ value: String) -> Bool {
		let scalars = Array(value.unicodeScalars)
		guard scalars.count >= 20, !scalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
		var counts: [Unicode.Scalar: Int] = [:]
		for scalar in scalars { counts[scalar, default: 0] += 1 }
		let length = Double(scalars.count)
		let entropy = counts.values.reduce(0.0) { sum, count in
			let p = Double(count) / length
			return sum - p * log2(p)
		}
		return entropy >= 3.5
	}
}
