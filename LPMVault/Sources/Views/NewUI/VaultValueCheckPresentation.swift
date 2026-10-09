import Foundation

/// How the tables and the inspector show a project's value check: which keys
/// have problems, why, and which defaults fill empty values. An environment
/// without values of its own checks the default environment's values against
/// the requested environment's rules.
struct VaultValueCheckPresentation {
	typealias Problem = ProjectEnvValueCheck.Problem

	struct GroupFailure: Equatable, Identifiable {
		let name: String
		/// Such as "Exactly one of PASSWORD, OAUTH_TOKEN — both set".
		let message: String
		var id: String { name }
	}

	static let none = VaultValueCheckPresentation(check: nil, rules: nil, project: nil)

	private let check: ProjectEnvValueCheck?
	private let rules: ProjectEnvSchemaOverview?
	private let environments: [String: [String: String]]
	/// Keys with a problem in at least one environment.
	let invalidKeys: Set<String>
	private let invalidKeysByEnvironment: [String: Set<String>]

	init(check: ProjectEnvValueCheck?, rules: ProjectEnvSchemaOverview?, project: VaultProject?) {
		self.check = check
		self.rules = rules
		environments = project?.environments ?? [:]
		var byEnvironment: [String: Set<String>] = [:]
		for (name, environment) in check?.environments ?? [:] {
			var keys = Set(environment.problems.keys)
			keys.formUnion(environment.ignored)
			byEnvironment[name] = keys
		}
		invalidKeysByEnvironment = byEnvironment
		invalidKeys = byEnvironment.values.reduce(into: Set<String>()) { $0.formUnion($1) }
	}

	/// Whether the project's rules were read, so its values were checked.
	var hasCheck: Bool { check != nil }

	func invalidKeys(in environment: String) -> Set<String> {
		invalidKeysByEnvironment[environment] ?? []
	}

	/// Whether the LPM CLI uses the default environment's values for `environment`.
	func readsDefaultEnvironment(_ environment: String) -> Bool {
		check?.environments[environment]?.readsDefaultEnvironment ?? false
	}

	func problems(of key: String, in environment: String) -> [Problem] {
		guard let checked = check?.environments[environment] else { return [] }
		return checked.problems[key] ?? []
	}

	/// The schema default the LPM CLI fills `key` with in `environment`.
	func defaultValue(of key: String, in environment: String) -> String? {
		guard let checked = check?.environments[environment] else { return nil }
		return checked.defaults[key]?.escapingDirectionControls
	}

	func isIgnored(_ key: String, in environment: String) -> Bool {
		guard let checked = check?.environments[environment] else { return false }
		return checked.ignored.contains(key)
	}

	func isRequiredAndUnset(_ key: String, in environment: String) -> Bool {
		problems(of: key, in: environment).contains { $0.kind == .required }
	}

	/// Keys without a stored value in `environment` that it still shows: a
	/// failing requirement, a default, or an ignored inherited key.
	func unstoredKeys(in environment: String) -> Set<String> {
		guard let checked = check?.environments[environment] else { return [] }
		let stored = environments[environment] ?? [:]
		var keys = Set(checked.defaults.keys)
		keys.formUnion(checked.problems.keys)
		keys.formUnion(checked.ignored)
		return keys.filter { stored[$0] == nil }
	}

	/// Keys stored in no environment that have a problem somewhere.
	func unstoredInvalidKeys() -> Set<String> {
		invalidKeys.filter { key in !environments.values.contains { $0[key] != nil } }
	}

	/// Why `key` fails in `environment`, one reason per line; nil when it doesn't.
	func reason(for key: String, in environment: String) -> String? {
		var reasons = problems(of: key, in: environment).map { message(for: $0, in: environment) }
		if isIgnored(key, in: environment) {
			reasons.append("The LPM CLI never passes \(key) to commands.")
		}
		var seen = Set<String>()
		reasons = reasons.filter { seen.insert($0).inserted }
		return reasons.isEmpty ? nil : reasons.joined(separator: "\n")
	}

	func groupFailures(in environment: String) -> [GroupFailure] {
		guard let checked = check?.environments[environment] else { return [] }
		var names = Set<String>()
		for problems in checked.problems.values {
			for problem in problems {
				if case .group(let name, _) = problem.kind { names.insert(name) }
			}
		}
		return names.sorted().map { GroupFailure(name: $0, message: groupMessage($0, in: environment)) }
	}

	func message(for problem: Problem, in environment: String) -> String {
		switch problem.kind {
		case .required:
			rules?.rule(for: problem.key)?.badges.first { $0.text.hasPrefix("Required") }?.text ?? "Required"
		case .empty: "Empty values aren't allowed"
		case .unusableValue: "Contains a character a process can't receive"
		case .format(let format): Self.formatMessage(format)
		case .constraint(let constraint): Self.constraintMessage(constraint)
		case .pattern: "Doesn't match the pattern"
		case .notAllowed: "Not one of the allowed values"
		case .group(let name, _): groupMessage(name, in: environment)
		case .other: "Doesn't meet its rule"
		}
	}

	private func groupMessage(_ name: String, in environment: String) -> String {
		guard let group = rules?.groups.first(where: { $0.name == name }) else { return "Group \(name.escapingDirectionControls) fails" }
		let checked = check?.environments[environment]
		let stored = environments[checked?.readsDefaultEnvironment == true ? "default" : environment]
		let set = group.members.filter { member in
			guard checked?.ignored.contains(member) != true else { return false }
			let value = checked?.defaults[member] ?? stored?[member]
			return value.map { !$0.isEmpty } ?? false
		}.count
		let state = switch set {
		case 0: "none set"
		case group.members.count: group.members.count == 2 ? "both set" : "all set"
		default: "\(set) of \(group.members.count) set"
		}
		return "\(group.summary) — \(state)"
	}

	private static func formatMessage(_ format: String) -> String {
		switch format {
		case "url": "Not a valid URL"
		case "port": "Not a valid port"
		case "email": "Not a valid email address"
		case "hostname": "Not a valid hostname"
		case "ip": "Not a valid IP address"
		case "boolean": "Not true or false"
		case "integer": "Not a whole number"
		default: "Not a valid \(format)"
		}
	}

	private static func constraintMessage(_ constraint: String) -> String {
		switch constraint {
		case "min": "Below the minimum"
		case "max": "Above the maximum"
		case "minLength": "Too short"
		case "maxLength": "Too long"
		case "protocols": "Uses a protocol the rule doesn't allow"
		default: "Outside the rule's bounds"
		}
	}
}
