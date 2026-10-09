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
	/// Port needs a name that says so, since many numbers are valid ports;
	/// boolean needs words, since 1 and 0 are numbers first; and hostname
	/// needs dotted names, since a single word or a token is a valid one.
	private static func formats(for key: String, values: [String]) -> [ProjectEnvSchemaRule.Format] {
		var formats: [ProjectEnvSchemaRule.Format] = []
		if key.uppercased().contains("PORT") { formats.append(.port) }
		if values.contains(where: { $0.contains(where: \.isLetter) }) { formats.append(.boolean) }
		formats += [.integer, .url, .email, .ip]
		if values.allSatisfy({ ($0.contains(".") || $0 == "localhost") && !looksRandom($0) }) { formats.append(.hostname) }
		return formats
	}

	/// What the stored `values` of `key` suggest. Reads nothing but the values
	/// given, which never leave this computation.
	static func suggestions(for key: String, values: [String], publicPrefix: String?) -> [ProjectEnvSchemaSuggestion] {
		let values = Array(Set(values.filter { !$0.isEmpty })).sorted()
		guard !values.isEmpty else { return [] }
		var suggestions: [ProjectEnvSchemaSuggestion] = []
		let format = formats(for: key, values: values).first { passes(["format": .string($0.rawValue)], key: key, values: values) }
		if let format {
			suggestions.append(.init(change: .format(format), evidence: evidence(for: format, count: values.count)))
		}
		if format == .url {
			let schemes = Set(values.compactMap { URLComponents(string: $0)?.scheme?.lowercased() })
			if schemes.count == 1, let scheme = schemes.first,
				passes(["format": .string("url"), "protocols": .array([.string(scheme)])], key: key, values: values)
			{
				suggestions.append(.init(change: .protocols([scheme]), evidence: values.count == 1 ? "uses the \(scheme) scheme" : "all use the \(scheme) scheme"))
			}
		}
		if publicPrefix == nil, format == nil, let reason = secretEvidence(key: key, values: values) {
			suggestions.append(.init(change: .secret, evidence: reason))
		}
		return suggestions
	}

	private static func passes(_ rule: [String: LPMConfigJSON], key: String, values: [String]) -> Bool {
		let schema = LPMConfigJSON.object([.init(key: "vars", value: .object([
			.init(key: key, value: .object(rule.sorted { $0.key < $1.key }.map { .init(key: $0.key, value: $0.value) })),
		]))])
		let environments = LPMConfigJSON.object([.init(key: "environments", value: .object(values.enumerated().map { index, value in
			.init(key: "e\(index)", value: .object([.init(key: key, value: .string(value))]))
		}))])
		guard let schemaData = try? schema.compactData(maximumBytes: 2 * 1024 * 1024),
			let valuesData = try? environments.compactData(maximumBytes: 2 * 1024 * 1024),
			let output = RustSchemaEngine.check(schema: schemaData, values: valuesData),
			let check = ProjectEnvValueCheck(output: output)
		else { return false }
		return check.environments.values.allSatisfy { $0.problems.isEmpty }
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

	/// Names that say a key is secret, by its words.
	private static let secretWords: Set<String> = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "PRIVATE", "CREDENTIAL", "CREDENTIALS", "APIKEY"]

	private static func secretEvidence(key: String, values: [String]) -> String? {
		let words = key.uppercased().split(separator: "_").map(String.init)
		if words.contains(where: secretWords.contains) || (words.count >= 2 && words.last == "KEY") {
			return "the name says it's secret"
		}
		guard values.allSatisfy(looksRandom) else { return nil }
		return values.count == 1 ? "the value looks random" : "values look random"
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
