import Foundation

/// What the bundled engine finds in a value that's hard to see, by the rule
/// the LPM CLI uses: which characters and where, never the value. It's a
/// warning, not a value-check problem: it never makes a key invalid or keeps
/// a value from being saved or published.
struct ValueCharacters: Equatable, Sendable {
	enum Kind: String, Sendable {
		case leadingWhitespace = "leading_whitespace"
		case trailingWhitespace = "trailing_whitespace"
		/// A format or other default-ignorable character, which draws nothing.
		case invisible
		/// A character that changes the direction text runs in.
		case direction
		/// A space other than U+0020, a tab, or the blank Braille cell.
		case space
		/// A line break other than `\n`.
		case lineBreak = "line_break"
		case control
	}

	/// Consecutive occurrences, counted in characters (Unicode scalars) from 1.
	struct Run: Equatable, Sendable {
		let position: Int
		let count: Int
	}

	struct Character: Equatable, Sendable {
		let kind: Kind
		/// Such as `\u{200b}` or `\t`; nil for a group, which stands for
		/// characters that can spell out hidden text, so they aren't told apart.
		let escape: String?
		/// The Unicode name, such as "ZERO WIDTH SPACE", or a group's, such as "tag characters".
		let name: String
		/// Every occurrence, listed in `runs` or not.
		let count: Int
		let runs: [Run]
	}

	let characters: [Character]
	/// How many more characters were found and not listed.
	let more: Int
	/// Whether removing hidden characters changes the value.
	let removable: Bool
	/// Whether trimming the ends changes the value.
	let trimmable: Bool
}

extension ValueCharacters {
	/// Decodes one value's report from the engine; nil when it isn't the expected shape.
	init?(_ report: LPMConfigJSON) {
		guard case .array(let entries)? = report["characters"], !entries.isEmpty,
			case .number(let rawMore)? = report["more"], let more = Int(rawMore), more >= 0,
			case .bool(let removable)? = report["removable"], case .bool(let trimmable)? = report["trimmable"]
		else { return nil }
		var characters: [Character] = []
		characters.reserveCapacity(entries.count)
		for entry in entries {
			guard case .string(let rawKind)? = entry["kind"], let kind = Kind(rawValue: rawKind),
				case .string(let name)? = entry["name"],
				case .number(let rawCount)? = entry["count"], let count = Int(rawCount), count >= 1,
				case .array(let rawRuns)? = entry["runs"], !rawRuns.isEmpty
			else { return nil }
			let escape: String?
			switch entry["escape"] {
			case .string(let value)?: escape = value
			case .null?: escape = nil
			default: return nil
			}
			var runs: [Run] = []
			runs.reserveCapacity(rawRuns.count)
			for rawRun in rawRuns {
				guard case .number(let rawPosition)? = rawRun["position"], let position = Int(rawPosition), position >= 1,
					case .number(let rawLength)? = rawRun["count"], let length = Int(rawLength), length >= 1
				else { return nil }
				runs.append(Run(position: position, count: length))
			}
			characters.append(Character(kind: kind, escape: escape, name: name, count: count, runs: runs))
		}
		self.init(characters: characters, more: more, removable: removable, trimmable: trimmable)
	}
}

/// The values of each environment that hold characters that are hard to see,
/// by key. Values without any aren't in it.
struct ValueCharacterCheck: Equatable, Sendable {
	var environments: [String: [String: ValueCharacters]]

	init(environments: [String: [String: ValueCharacters]] = [:]) {
		self.environments = environments
	}

	/// Decodes the engine's output; nil when it isn't the expected shape.
	init?(output: LPMConfigJSON) {
		guard output["abiVersion"] == .number("1"), case .object(let checked)? = output["environments"] else { return nil }
		var environments = Dictionary<String, [String: ValueCharacters]>(minimumCapacity: checked.count)
		for environment in checked {
			guard case .object(let values) = environment.value else { return nil }
			guard !values.isEmpty else { continue }
			var found = Dictionary<String, ValueCharacters>(minimumCapacity: values.count)
			for value in values {
				guard let characters = ValueCharacters(value.value) else { return nil }
				found[value.key] = characters
			}
			environments[environment.key] = found
		}
		self.environments = environments
	}

	func characters(of key: String, in environment: String) -> ValueCharacters? {
		environments[environment]?[key]
	}

	/// How many values hold characters that are hard to see.
	var valueCount: Int { environments.values.reduce(0) { $0 + $1.count } }
}

/// A value shown with each character that's hard to see written as its
/// escape, such as `\u{200b}`, for someone who sees the value.
struct ShownValueCharacters: Equatable, Sendable {
	let text: String
	/// Where each escape is in `text`, in UTF-16 code units.
	let marks: [NSRange]
}

/// Checks values for characters that are hard to see with the bundled
/// engine, on a queue of its own so a check never holds a cooperative
/// thread. It keeps nothing: a caller that checks the same values again
/// hands back the last check, and only the values that changed since are
/// sent to the engine, so whoever holds the values decides when they go.
actor ValueCharacterChecker {
	typealias Engine = @Sendable ([String: [String: String]]) -> ValueCharacterCheck?

	/// Values and what the engine found in them, which a later check of
	/// mostly the same values starts from.
	struct Checked: Sendable {
		let values: [String: [String: String]]
		let check: ValueCharacterCheck

		/// What `key`'s value in `environment` holds, while it's still `value`, byte for byte.
		func characters(of key: String, in environment: String, whileItIs value: String) -> ValueCharacters? {
			guard let checked = values[environment]?[key], ExactText(checked) == ExactText(value) else { return nil }
			return check.characters(of: key, in: environment)
		}
	}

	private let engine: Engine
	private let queue = DispatchSerialQueue(label: "dev.lpm.vault.value-characters", qos: .userInitiated)

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	init(engine: @escaping Engine = { RustSchemaEngine.checkCharacters($0) }) {
		self.engine = engine
	}

	/// What `environments` holds that's hard to see, sending the engine only
	/// the values that differ from `previous`'s, byte for byte. Nil when the
	/// engine refuses them.
	func check(_ environments: [String: [String: String]], since previous: Checked?) -> Checked? {
		guard !Task.isCancelled else { return nil }
		var changed: [String: [String: String]] = [:]
		var result = ValueCharacterCheck()
		for (environment, values) in environments {
			let before = previous?.values[environment]
			let found = previous?.check.environments[environment]
			for (key, value) in values {
				if let old = before?[key], ExactText(old) == ExactText(value) {
					if let flagged = found?[key] { result.environments[environment, default: [:]][key] = flagged }
				} else {
					changed[environment, default: [:]][key] = value
				}
			}
		}
		if !changed.isEmpty {
			guard let fresh = engine(changed) else { return nil }
			for (environment, values) in fresh.environments {
				result.environments[environment, default: [:]].merge(values) { $1 }
			}
		}
		return Checked(values: environments, check: result)
	}

	/// What the values hold, such as a value being typed.
	func check(_ environments: [String: [String: String]]) -> ValueCharacterCheck? {
		guard !Task.isCancelled else { return nil }
		return engine(environments)
	}

	/// What one value holds that's hard to see, and the value shown with
	/// them made visible when it holds any; nil when the engine can't check it.
	func inspect(_ value: String) -> Inspection? {
		guard !Task.isCancelled, let check = engine(["default": ["VALUE": value]]) else { return nil }
		let found = check.characters(of: "VALUE", in: "default")
		return Inspection(value: value, found: found, shown: found == nil ? nil : RustSchemaEngine.showCharacters(in: value))
	}

	/// What each value holds that's hard to see, by key, checked in one call,
	/// with each value that holds any shown with them made visible. Keys of
	/// values that hold none aren't in it. Nil when the engine refuses them.
	func inspect(values: [String: String]) -> [String: Inspection]? {
		guard !Task.isCancelled else { return nil }
		guard !values.isEmpty else { return [:] }
		guard let check = engine(["default": values]) else { return nil }
		var inspections: [String: Inspection] = [:]
		for (key, found) in check.environments["default"] ?? [:] {
			guard let value = values[key] else { continue }
			inspections[key] = Inspection(value: value, found: found, shown: RustSchemaEngine.showCharacters(in: value))
		}
		return inspections
	}

	/// One value's check, with the value it checked, so a view can tell it's still current.
	struct Inspection: Equatable, Sendable {
		let value: String
		let found: ValueCharacters?
		let shown: ShownValueCharacters?

		/// Whether this inspection is of `value`, byte for byte.
		func isOf(_ value: String) -> Bool {
			ExactText(self.value) == ExactText(value)
		}

		static func == (lhs: Self, rhs: Self) -> Bool {
			lhs.isOf(rhs.value) && lhs.found == rhs.found && lhs.shown == rhs.shown
		}
	}

}
