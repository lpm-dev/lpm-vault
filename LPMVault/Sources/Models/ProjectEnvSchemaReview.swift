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
		enum Kind: Hashable { case newlyFailing, nowPasses, noLongerChecked }
		let environment: String
		let kind: Kind
		let message: String
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

		var id: ProjectEnvSchemaDraft.Item { item }
	}

	let items: [Item]
	/// Effects on keys the draft doesn't change.
	let others: [Effect]
	let othersUnchanged: Int
	/// The stored values were checked; false when the project's values aren't loaded.
	let checkedValues: Bool

	/// The review of `draft` with `evaluation`, its current evaluation; nil
	/// while the engine rejects the draft.
	init?(
		draft: ProjectEnvSchemaDraft, evaluation: ProjectEnvSchemaDraft.Evaluation, savedRules: ProjectEnvSchemaOverview?,
		savedCheck: ProjectEnvValueCheck?, project: VaultProject, environments: [String]
	) {
		guard evaluation.rejection == nil, let rules = evaluation.overview else { return nil }
		let before = VaultValueCheckPresentation(check: savedCheck, rules: savedRules, project: project)
		let after = VaultValueCheckPresentation(check: evaluation.check, rules: rules, project: project)
		var effects: ProjectEnvSchemaDraftEffects?
		if let savedCheck, let check = evaluation.check {
			effects = ProjectEnvSchemaDraftEffects(before: savedCheck, after: check, draft: draft, environmentOrder: environments)
		}
		func words(_ effect: ProjectEnvSchemaDraftEffects.Effect, naming key: Bool) -> Effect {
			let presentation = effect.kind == .newlyFailing ? after : before
			var message = effect.kind == .noLongerChecked
				? "Stored value kept; no longer checked"
				: presentation.message(for: effect.problem, in: effect.environment)
			let isGroupProblem = if case .group = effect.problem.kind { true } else { false }
			if key, !isGroupProblem { message = "\(effect.problem.key): \(message)" }
			let kind: Effect.Kind = switch effect.kind {
			case .newlyFailing: .newlyFailing
			case .nowPasses: .nowPasses
			case .noLongerChecked: .noLongerChecked
			}
			return Effect(environment: effect.environment, kind: kind, message: message)
		}
		items = draft.changedItems.compactMap { item in
			guard let diff = draft.diff(for: item) else { return nil }
			let summary = effects?.summary(for: item) ?? .init()
			let isGroup = if case .group = item { true } else { false }
			return Item(
				item: item, title: Self.title(of: item), state: Self.state(of: item, in: draft, savedRules: savedRules),
				diff: diff, effects: summary.effects.map { words($0, naming: isGroup) }, unchanged: summary.unchanged
			)
		}
		others = effects?.others.effects.map { words($0, naming: true) } ?? []
		othersUnchanged = effects?.others.unchanged ?? 0
		checkedValues = effects != nil
	}

	static func title(of item: ProjectEnvSchemaDraft.Item) -> String {
		switch item {
		case .key(let name), .group(let name): name.escapingDirectionControls
		case .clientPrefixes: "clientPrefixes"
		}
	}

	private static func state(of item: ProjectEnvSchemaDraft.Item, in draft: ProjectEnvSchemaDraft, savedRules: ProjectEnvSchemaOverview?) -> State {
		let key: String? = if case .key(let name) = item { name } else { nil }
		let source = key.flatMap { savedRules?.rule(for: $0)?.overrides ?? savedRules?.rule(for: $0)?.source } ?? "an imported schema"
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
		case nil: others = []
		case .object(let fields)?: others = fields
		default: return members.isEmpty ? "no rules" : members.prefix(3).map { "\($0.key.escapingDirectionControls) \(text($0.value, limit: 24))" }.joined(separator: ", ")
		}
		let differing = members.filter { member in
			others.first { $0.key.utf8.elementsEqual(member.key.utf8) }.map { !$0.value.isEquivalent(to: member.value) } ?? true
		}
		let missing = others.filter { other in !members.contains { $0.key.utf8.elementsEqual(other.key.utf8) } }
		var parts = differing.prefix(3).map { "\($0.key.escapingDirectionControls) \(text($0.value, limit: 24))" }
		parts += missing.prefix(max(0, 3 - parts.count)).map { "no \($0.key.escapingDirectionControls)" }
		let shown = parts.count
		let total = differing.count + missing.count
		if total > shown { parts.append("+\(total - shown) more") }
		return parts.isEmpty ? "the same rules in another order" : parts.joined(separator: ", ")
	}

	private static func text(_ json: LPMConfigJSON, limit: Int) -> String {
		let raw: String = switch json {
		case .string(let value): value
		case .number(let value): value
		case .bool(let value): value ? "on" : "off"
		case .null: "null"
		case .array(let values): values.map { text($0, limit: limit) }.joined(separator: ", ")
		case .object: "{…}"
		}
		let line = raw.split(whereSeparator: \.isNewline).joined(separator: " ").escapingDirectionControls
		return line.count > limit ? String(line.prefix(limit)) + "…" : line
	}
}

extension ProjectEnvSchemaDraft.Rebase {
	/// What changed on disk, such as "RETRY_COUNT and the auth group changed outside".
	var summary: String {
		var names = changedItems.map { item in
			switch item {
			case .key(let name): name.escapingDirectionControls
			case .group(let name): "the \(name.escapingDirectionControls) group"
			case .clientPrefixes: "the client prefixes"
			}
		}
		if changedOtherFields { names.append("its imports") }
		guard let last = names.last else { return "lpm.json changed outside" }
		let text = switch names.count {
		case 1: last
		case 2, 3: names.dropLast().joined(separator: ", ") + " and " + last
		default: names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
		}
		return "\(text) changed outside"
	}
}
