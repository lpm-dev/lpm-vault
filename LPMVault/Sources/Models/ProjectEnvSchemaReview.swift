import Foundation

/// What the review before saving a schema draft shows: each changed item as
/// lines of lpm.json, and what saving does to the values stored in each
/// environment, in words. Never contains values.
struct ProjectEnvSchemaReview: Equatable {
	enum State: Equatable {
		case changed
		case new
		case removed
		/// lpm.json gains an override that replaces the rule from `source`.
		case override(source: String)
		/// lpm.json drops its override, so the rule from `source` applies again.
		case resetOverride(source: String)
	}

	struct Effect: Hashable {
		enum Kind: Hashable {
			case newlyFailing, nowPasses, noLongerChecked
			/// An unset key's default, which the LPM CLI fills in, changes.
			case defaultChanged
		}
		let environment: String
		let kind: Kind
		let message: String
	}

	/// Whether the stored values were checked against the draft.
	enum Values: Equatable {
		case checked
		/// The saved rules' check is still running; saving waits for it.
		case checking
		/// The project's values aren't loaded, or the engine can't check
		/// rules this large.
		case unchecked
	}

	struct Item: Equatable, Identifiable {
		let item: ProjectEnvSchemaDraft.Item
		/// Such as "PORT", "auth", or "clientPrefixes".
		let title: String
		let state: State
		let diff: ProjectEnvSchemaDraft.Diff
		let effects: [Effect]
		/// Problems that stay as they are.
		let unchanged: Int
		/// What the change gives up that an import asks for, such as Secret,
		/// when lpm.json's override drops it; escaped.
		var warning: String?

		var id: ProjectEnvSchemaDraft.Item { item }
	}

	let items: [Item]
	/// What the review says first when changes give up Secret an import asks
	/// for, naming the keys; nil when none does. Escaped.
	var warningSummary: String? {
		let keys = items.lazy.filter { $0.warning != nil }.map(\.title)
		guard let first = keys.first else { return nil }
		let count = keys.count
		if count == 1 { return "\(first) loses the Secret an import gives it. Check its change below before saving." }
		let shown = keys.prefix(Self.summaryKeys).joined(separator: ", ")
		let more = count > Self.summaryKeys ? " and \(count - Self.summaryKeys) more" : ""
		return "\(count) keys lose the Secret an import gives them: \(shown)\(more). Check their changes below before saving."
	}

	/// Keys `warningSummary` names before "and N more".
	private static let summaryKeys = 5

	/// Effects on keys the draft doesn't change.
	let others: [Effect]
	let othersUnchanged: Int
	let values: Values

	/// The review of `draft` with `evaluation`, its current evaluation; nil
	/// while the engine rejects the draft. Rules that check nothing, as a
	/// project without lpm.json has, compare as a check without problems.
	init?(
		draft: ProjectEnvSchemaDraft, evaluation: ProjectEnvSchemaDraft.Evaluation, savedRules: ProjectEnvSchemaOverview?,
		savedCheck: ProjectEnvValueCheck?, project: VaultProject, environments: [String]
	) {
		guard evaluation.rejection == nil, let rules = evaluation.overview else { return nil }
		var savedCheck = savedCheck
		if savedCheck == nil, savedRules?.isEmpty ?? true { savedCheck = ProjectEnvValueCheck(environments: [:]) }
		let before = VaultValueCheckPresentation(check: savedCheck, rules: savedRules, project: project)
		let after = VaultValueCheckPresentation(check: evaluation.check, rules: rules, project: project)
		var effects: ProjectEnvSchemaDraftEffects?
		if !project.hasLoadedEnvironments || evaluation.check == nil {
			values = .unchecked
		} else if let savedCheck, let check = evaluation.check {
			values = .checked
			effects = ProjectEnvSchemaDraftEffects(before: savedCheck, after: check, draft: draft, environmentOrder: environments)
		} else {
			values = savedRules?.effectiveSchema == nil ? .unchecked : .checking
		}
		let rank = Dictionary(environments.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
		func words(_ summary: ProjectEnvSchemaDraftEffects.Summary, naming: Bool) -> [Effect] {
			var problems: [Effect] = []
			var previous: (environment: String, key: String)?
			var merged: [String] = []
			func flush() {
				guard let last = previous else { return }
				var message = merged.joined(separator: "; ")
				if naming { message = "\(last.key.escapingDirectionControls): \(message)" }
				problems.append(Effect(environment: last.environment, kind: .noLongerChecked, message: message))
				previous = nil
				merged = []
			}
			for effect in summary.effects {
				let isGroupProblem = if case .group = effect.problem.kind { true } else { false }
				if effect.kind == .noLongerChecked, !isGroupProblem {
					// A key that leaves lpm.json shows once per environment, naming each check that stops.
					if let last = previous, last.environment != effect.environment || last.key != effect.problem.key { flush() }
					previous = (effect.environment, effect.problem.key)
					let message = before.message(for: effect.problem, in: effect.environment).escapingDirectionControls
					if !merged.contains(message) { merged.append(message) }
					continue
				}
				flush()
				let presentation = effect.kind == .newlyFailing ? after : before
				var message = presentation.message(for: effect.problem, in: effect.environment).escapingDirectionControls
				if naming, !isGroupProblem { message = "\(effect.problem.key.escapingDirectionControls): \(message)" }
				let kind: Effect.Kind = switch effect.kind {
				case .newlyFailing: .newlyFailing
				case .nowPasses: .nowPasses
				case .noLongerChecked: .noLongerChecked
				}
				problems.append(Effect(environment: effect.environment, kind: kind, message: message))
			}
			flush()
			let defaults = summary.defaults.map { change in
				let message = switch change.kind {
				case .added: "Now uses the default"
				case .changed: "Uses the default, which this changes"
				case .removed: "Used the default, which this removes"
				}
				return Effect(environment: change.environment, kind: .defaultChanged, message: message)
			}
			guard !defaults.isEmpty else { return problems }
			// Both lists are in environment order; each environment's defaults follow its problems.
			let order = { (effect: Effect) in rank[effect.environment] ?? environments.count }
			return (problems.map { (effect: $0, list: 0) } + defaults.map { (effect: $0, list: 1) })
				.enumerated()
				.sorted { a, b in
					let (x, y) = (order(a.element.effect), order(b.element.effect))
					if x != y { return x < y }
					if a.element.list != b.element.list { return a.element.list < b.element.list }
					return a.offset < b.offset
				}
				.map(\.element.effect)
		}
		items = draft.changedItems.compactMap { item in
			guard let diff = draft.diff(for: item) else { return nil }
			let summary = effects?.summary(for: item) ?? .init()
			let isGroup = if case .group = item { true } else { false }
			return Item(
				item: item, title: Self.title(of: item), state: Self.state(of: item, in: draft, savedRules: savedRules, draftRules: evaluation.overview),
				diff: diff, effects: words(summary, naming: isGroup), unchanged: summary.unchanged,
				warning: Self.droppedSecret(item, in: draft, rules: rules)
			)
		}
		others = effects.map { words($0.others, naming: true) } ?? []
		othersUnchanged = effects?.others.unchanged ?? 0
	}

	/// A key lpm.json's override leaves without Secret though an import it
	/// replaces marks it so, which a prefix or an edit made from rules read
	/// before the import changed can do; nil otherwise.
	private static func droppedSecret(_ item: ProjectEnvSchemaDraft.Item, in draft: ProjectEnvSchemaDraft, rules: ProjectEnvSchemaOverview) -> String? {
		guard case .key(let key) = item, case .overridden(let json) = draft.declaration(of: item),
			let secret = rules.replacedRules[key]?.secret, !ProjectEnvSchemaRule(resolved: json).secret
		else { return nil }
		let rule = ProjectEnvSchemaRule(resolved: json)
		return "\(secret.source.escapingDirectionControls) marks \(key.escapingDirectionControls) Secret, and this override doesn't"
			+ (rule.client ? ", so its value becomes public." : ", so its value is no longer treated as secret.")
	}

	static func title(of item: ProjectEnvSchemaDraft.Item) -> String {
		switch item {
		case .key(let name), .group(let name): name.escapingDirectionControls
		case .clientPrefixes: "clientPrefixes"
		}
	}

	/// How the draft changes `item`. The file an override replaces, or that
	/// applies again once it goes, comes from lpm.json's rules, which name
	/// what each override replaces; the draft's name the file of a group that
	/// lpm.json's rules don't have.
	private static func state(
		of item: ProjectEnvSchemaDraft.Item, in draft: ProjectEnvSchemaDraft, savedRules: ProjectEnvSchemaOverview?, draftRules: ProjectEnvSchemaOverview?
	) -> State {
		let key: String? = if case .key(let name) = item { name } else { nil }
		let source: String = switch item {
		case .key(let name): savedRules?.rule(for: name)?.overrides ?? savedRules?.rule(for: name)?.source ?? "an imported schema"
		case .group(let name):
			savedRules?.groups.first { $0.name == name }.flatMap { $0.overrides ?? $0.source }
				?? draftRules?.groups.first { $0.name == name }?.source ?? "an imported schema"
		case .clientPrefixes: "an imported schema"
		}
		switch (draft.base(of: item), draft.declaration(of: item)) {
		case (.declared, .absent): return .removed
		case (.overridden, .absent): return .resetOverride(source: source)
		case (.absent, .overridden): return .override(source: source)
		case (.absent, .declared):
			if let key, savedRules?.rule(for: key) != nil { return .changed }
			return .new
		default: return .changed
		}
	}
}

// MARK: - Conflicts in words

extension ProjectEnvSchemaDraft.Conflict {
	/// Each side of the conflict in a few words, naming only what differs,
	/// such as "default 8080" against "default 4000".
	var summary: (mine: String, theirs: String) {
		(Self.describe(mine, against: theirs), Self.describe(theirs, against: mine))
	}

	private static func describe(_ declaration: ProjectEnvSchemaDraft.Declaration, against other: ProjectEnvSchemaDraft.Declaration) -> String {
		guard let json = declaration.json else { return "removed" }
		guard case .object(let members) = json else { return text(json, limit: 60) }
		let others: [LPMConfigJSON.Member]
		switch other.json {
		case nil: return members.isEmpty ? "no rules" : fields(members.prefix(3), total: members.count)
		case .object(let fields)?: others = fields
		default: return members.isEmpty ? "no rules" : fields(members.prefix(3), total: members.count)
		}
		let differing = members.filter { member in
			others.first { $0.key.utf8.elementsEqual(member.key.utf8) }.map { !$0.value.isEquivalent(to: member.value) } ?? true
		}
		let missing = others.filter { other in !members.contains { $0.key.utf8.elementsEqual(other.key.utf8) } }
		guard !differing.isEmpty || !missing.isEmpty else {
			// Equivalent rules conflict only when one is in vars and the other an override.
			if case .overridden = declaration { return "as an override" }
			return "in vars"
		}
		var parts = differing.prefix(3).map { "\(name($0.key)) \(text($0.value, limit: 24))" }
		parts += missing.prefix(max(0, 3 - parts.count)).map { "no \(name($0.key))" }
		let total = differing.count + missing.count
		if total > parts.count { parts.append("+\(total - parts.count) more") }
		return parts.joined(separator: ", ")
	}

	private static func fields(_ members: ArraySlice<LPMConfigJSON.Member>, total: Int) -> String {
		var parts = members.map { "\(name($0.key)) \(text($0.value, limit: 24))" }
		if total > parts.count { parts.append("+\(total - parts.count) more") }
		return parts.joined(separator: ", ")
	}

	private static func name(_ key: String) -> String {
		bounded(key, limit: 40)
	}

	/// A value on one short line: at most `limit` characters of it, cut before
	/// escaping so an escape is never cut in half, and read no further than that.
	private static func text(_ json: LPMConfigJSON, limit: Int) -> String {
		var raw = ""
		var length = 0
		var truncated = false
		func append(_ piece: String) {
			guard !truncated else { return }
			for character in piece {
				guard length < limit else {
					truncated = true
					return
				}
				raw.append(character.isNewline ? " " : character)
				length += 1
			}
		}
		func walk(_ value: LPMConfigJSON) {
			switch value {
			case .string(let string): append(string)
			case .number(let number): append(number)
			case .bool(let flag): append(flag ? "on" : "off")
			case .null: append("null")
			case .object: append("{…}")
			case .array(let values):
				if values.isEmpty { append("none") }
				for (index, element) in values.enumerated() {
					if truncated { return }
					if index > 0 { append(", ") }
					walk(element)
				}
			}
		}
		walk(json)
		return raw.escapingDirectionControls + (truncated ? "…" : "")
	}

	private static func bounded(_ text: String, limit: Int) -> String {
		text.count > limit ? String(text.prefix(limit)).escapingDirectionControls + "…" : text.escapingDirectionControls
	}
}

extension ProjectEnvSchemaDraft.Rebase {
	/// What changed on disk, such as "RETRY_COUNT and the auth group changed outside".
	var summary: String {
		var count = changedItems.count + (changedOtherFields ? 1 : 0)
		var names = changedItems.prefix(4).map { item in
			switch item {
			case .key(let name): name.escapingDirectionControls
			case .group(let name): "the \(name.escapingDirectionControls) group"
			case .clientPrefixes: "the client prefixes"
			}
		}
		if changedOtherFields, names.count < 4 { names.append("its imports") }
		count = max(count, names.count)
		guard let last = names.last else { return "lpm.json changed outside" }
		let text = switch count {
		case 1: last
		case 2, 3: names.prefix(count - 1).joined(separator: ", ") + " and " + last
		default: names.prefix(3).joined(separator: ", ") + " and \(count - 3) more"
		}
		return "\(text) changed outside"
	}
}
