import Foundation

/// What the bundled engine finds when it evaluates a project's stored values
/// against its rules, the way the LPM CLI does at runtime: the problems in
/// each environment, the defaults that fill unset keys, and the keys the CLI
/// ignores. Never contains stored values.
struct ProjectEnvValueCheck: Equatable, Sendable {
	struct Problem: Hashable, Sendable {
		enum Kind: Hashable, Sendable {
			/// Required in this environment, with no usable value.
			case required
			/// An empty value where the rule rejects empty values.
			case empty
			/// A value the operating system can't pass to a process.
			case unusableValue
			/// Not in the rule's format, such as "url" or "port".
			case format(String)
			/// Outside a bound: "min", "max", "minLength", "maxLength", or "protocols".
			case constraint(String)
			case pattern
			case notAllowed
			/// The group's relation fails; reported on every member.
			case group(name: String, mode: String)
			/// A code this version of the app doesn't describe.
			case other(String)
		}

		let key: String
		let kind: Kind
	}

	struct Environment: Equatable, Sendable {
		/// The environment has no values of its own, so the LPM CLI uses the
		/// default environment's values, and those were checked.
		var readsDefaultEnvironment = false
		/// Each key's problems, in the engine's order.
		var problems: [String: [Problem]] = [:]
		/// Keys without a usable value that a schema default fills, with that default.
		var defaults: [String: String] = [:]
		/// Stored keys the LPM CLI never passes to a process.
		var ignored: Set<String> = []
	}

	let environments: [String: Environment]

	init(environments: [String: Environment]) {
		self.environments = environments
	}

	/// Decodes the engine's output; nil when it isn't the expected shape.
	init?(output: LPMConfigJSON) {
		guard case .object(let checked)? = output["environments"] else { return nil }
		var environments = Dictionary<String, Environment>(minimumCapacity: checked.count)
		for member in checked {
			guard case .bool(let readsDefault)? = member.value["readsDefaultEnvironment"],
				case .array(let problems)? = member.value["problems"],
				case .object(let defaults)? = member.value["defaults"],
				case .array(let ignored)? = member.value["ignored"]
			else { return nil }
			var environment = Environment(readsDefaultEnvironment: readsDefault)
			for entry in problems {
				guard let problem = Problem(entry) else { return nil }
				environment.problems[problem.key, default: []].append(problem)
			}
			for entry in defaults {
				guard case .string(let value) = entry.value else { return nil }
				environment.defaults[entry.key] = value
			}
			for entry in ignored {
				guard case .string(let key) = entry else { return nil }
				environment.ignored.insert(key)
			}
			environments[member.key] = environment
		}
		self.environments = environments
	}

	/// The problems of `key` in `environment`.
	func problems(of key: String, in environment: String) -> [Problem] {
		environments[environment]?.problems[key] ?? []
	}

	/// The schema default that fills `key` in `environment`, if any.
	func defaultValue(of key: String, in environment: String) -> String? {
		environments[environment]?.defaults[key]
	}
}

extension ProjectEnvValueCheck.Problem {
	init?(_ entry: LPMConfigJSON) {
		guard case .string(let key)? = entry["key"], case .string(let code)? = entry["code"] else { return nil }
		func text(_ field: String) -> String? {
			if case .string(let value)? = entry[field] { value } else { nil }
		}
		let kind: Kind
		switch code {
		case "env.required": kind = .required
		case "env.empty": kind = .empty
		case "env.invalid_value": kind = .unusableValue
		case "env.pattern_mismatch": kind = .pattern
		case "env.enum_mismatch": kind = .notAllowed
		case "env.invalid_format":
			guard let format = text("format") else { return nil }
			kind = .format(format)
		case "env.constraint":
			guard let constraint = text("constraint") else { return nil }
			kind = .constraint(constraint)
		case "env.group":
			guard let group = text("group"), let mode = text("mode") else { return nil }
			kind = .group(name: group, mode: mode)
		default: kind = .other(code)
		}
		self.init(key: key, kind: kind)
	}
}

actor ProjectEnvValueCheckWorker {
	typealias Checker = @Sendable (ProjectEnvSchemaOverview, [String: [String: String]]) -> ProjectEnvValueCheck?

	private let checker: Checker

	init(checker: @escaping Checker = { rules, environments in rules.check(environments) }) {
		self.checker = checker
	}

	func check(
		rules: ProjectEnvSchemaOverview,
		environments: [String: [String: String]]
	) -> ProjectEnvValueCheck? {
		guard !Task.isCancelled else { return nil }
		return checker(rules, environments)
	}
}
