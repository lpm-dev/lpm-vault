import Foundation

/// Raw text's reading of an edited environment, line by line, as an import
/// reads a file: blank lines and `#` comments are skipped, `export` is
/// allowed, and a quoted value can span lines. Unlike an import, which keeps
/// the last of two lines for a key and stops at the first bad one, it finds
/// every line that can't be saved, so each can be shown with why.
struct VaultEnvTextCheck: Equatable, Sendable {
	struct Problem: Equatable, Sendable {
		/// Counted from 1, as the editor numbers lines.
		let line: Int
		let reason: String

		var message: String { "Line \(line): \(reason)" }
	}

	/// What the text sets, by key; a key whose line has a problem isn't in it.
	let values: [String: String]
	/// The line each key in `values` is set on.
	let lines: [String: Int]
	/// By line.
	let problems: [Problem]
	/// The lines to mark: each problem's, and the earlier line a duplicate repeats.
	let problemLines: Set<Int>
	/// How many lines the text has, as the editor numbers them, an empty last one included.
	let lineCount: Int

	init(_ text: String, limits: EnvFileImportLimits = .standard) {
		var values: [String: String] = [:]
		var lines: [String: Int] = [:]
		var keysByFoldedName: [String: String] = [:]
		var problems: [Problem] = []
		var problemLines = Set<Int>()
		var parsedBytes = 0
		var pending: (text: String, line: Int, quote: Character)?

		func flag(_ line: Int, _ reason: String) {
			problems.append(Problem(line: line, reason: reason))
			problemLines.insert(line)
		}

		func assign(_ assignment: String, line: Int) {
			let trimmed = assignment.trimmingCharacters(in: .whitespaces)
			let body = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst("export ".count)) : trimmed
			guard let equals = body.firstIndex(of: "=") else {
				return flag(line, "not a KEY=value line")
			}
			let key = body[..<equals].trimmingCharacters(in: .whitespaces)
			guard !key.isEmpty else { return flag(line, "no key before =") }
			guard EnvValidation.isValidVariableName(key) else {
				return flag(line, "invalid key name — use letters, digits and _, not starting with a digit")
			}
			if let first = lines[key] {
				problemLines.insert(first)
				return flag(line, "duplicate of line \(first)")
			}
			if let other = keysByFoldedName[key.lowercased()], let first = lines[other] {
				problemLines.insert(first)
				return flag(line, "\(key) differs from \(other) on line \(first) only in letter case")
			}
			let raw = String(body[body.index(after: equals)...]).trimmingLeadingWhitespace()
			let value: String
			if let quote = raw.first, quote == "\"" || quote == "'" {
				// Quoted values unescape as an import reads them.
				let single = EnvFileImportLimits(maximumInputBytes: limits.maximumInputBytes, maximumAssignments: 1,
					maximumParsedBytes: limits.maximumParsedBytes)
				guard let parsed = (try? EnvFileCodec.parse(key + "=" + raw, limits: single))?[key] else {
					return flag(line, "a value too large to keep")
				}
				value = parsed
			} else {
				value = raw.trimmingCharacters(in: .whitespaces)
			}
			guard values.count < limits.maximumAssignments else {
				return flag(line, "more than \(limits.maximumAssignments.formatted()) keys")
			}
			parsedBytes += key.utf8.count + value.utf8.count
			guard parsedBytes <= limits.maximumParsedBytes else {
				return flag(line, "the environment would be larger than \(ByteCountFormatter.string(fromByteCount: Int64(limits.maximumParsedBytes), countStyle: .file))")
			}
			values[key] = value
			lines[key] = line
			keysByFoldedName[key.lowercased()] = key
		}

		var number = 0
		for slice in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
			number += 1
			var line = String(decoding: slice, as: UTF8.self)
			if line.hasSuffix("\r") { line.removeLast() }
			if let open = pending {
				let joined = open.text + "\n" + line
				if EnvFileCodec.containsClosingQuote(in: line, quote: open.quote) {
					pending = nil
					assign(joined, line: open.line)
				} else {
					pending = (joined, open.line, open.quote)
				}
				continue
			}
			if EnvFileCodec.isBlankOrComment(line) { continue }
			if let quote = EnvFileCodec.unterminatedQuote(in: line) {
				pending = (line, number, quote)
				continue
			}
			assign(line, line: number)
		}
		if let open = pending { flag(open.line, "its value's opening \(open.quote) is never closed") }

		self.values = values
		self.lines = lines
		self.problems = problems.sorted { $0.line < $1.line }
		self.problemLines = problemLines
		lineCount = number
	}
}

/// How edited values differ from the environment's.
struct VaultEnvChanges: Equatable, Sendable {
	let added: [String]
	let changed: [String]
	let removed: [String]
	let unchanged: [String]

	init(from baseline: [String: String], to values: [String: String]) {
		var added: [String] = []
		var changed: [String] = []
		var unchanged: [String] = []
		for (key, value) in values {
			switch baseline[key] {
			case nil: added.append(key)
			case value: unchanged.append(key)
			default: changed.append(key)
			}
		}
		self.added = added.sorted()
		self.changed = changed.sorted()
		self.unchanged = unchanged.sorted()
		removed = baseline.keys.filter { values[$0] == nil }.sorted()
	}

	var count: Int { added.count + changed.count + removed.count }

	/// Such as ["1 added", "2 changed"], leaving out what didn't happen.
	var parts: [String] {
		[(added.count, "added"), (changed.count, "changed"), (removed.count, "removed")]
			.filter { $0.0 > 0 }
			.map { "\($0.0) \($0.1)" }
	}

	/// Such as "1 added, 2 changed".
	var summary: String { parts.joined(separator: ", ") }
}

/// An environment edited as Raw text, kept until it's saved or discarded.
struct VaultRawTextDraft: Equatable, Sendable {
	private(set) var target: VaultEnvironmentTarget
	/// The environment's values when editing began, or when it was last
	/// compared with them; saving writes only if it still has them.
	var baseline: [String: String] {
		didSet { changes = VaultEnvChanges(from: baseline, to: check.values) }
	}
	var text: String {
		didSet {
			guard text != oldValue else { return }
			check = VaultEnvTextCheck(text)
			changes = VaultEnvChanges(from: baseline, to: check.values)
		}
	}
	private(set) var check: VaultEnvTextCheck
	private(set) var changes: VaultEnvChanges

	/// Starts from `baseline`, a line for each key in `order` and an empty line to add on.
	init(target: VaultEnvironmentTarget, baseline: [String: String], order: [String]) {
		self.target = target
		self.baseline = baseline
		let text = order.compactMap { key in baseline[key].map { EnvFileCodec.formatLine(key: key, value: $0) + "\n" } }.joined()
		self.text = text
		check = VaultEnvTextCheck(text)
		changes = VaultEnvChanges(from: baseline, to: check.values)
	}

	var canSave: Bool { check.problems.isEmpty && changes.count > 0 }

	/// The same edit, of the environment under its new name.
	func renamed(to environment: String) -> VaultRawTextDraft {
		var draft = self
		draft.target = VaultEnvironmentTarget(projectId: target.projectId, environment: environment)
		return draft
	}
}

/// What saving a Raw text draft did.
enum VaultRawTextSaveOutcome: Equatable, Sendable {
	case saved(EnvironmentChangeReceipt)
	/// Something else, as the LPM CLI, changed the environment first, so nothing was written.
	case changed
	/// The draft, its project or its environment is gone, or the vault locked.
	case unavailable
	case failed(String)
}
