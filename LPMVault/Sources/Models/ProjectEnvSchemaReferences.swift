import Foundation

/// What in the rules names a key, which removing the key would leave pointing
/// at nothing: groups that list it, and keys whose Required when depends on
/// it. The LPM CLI rejects both, so each needs a fix before the key goes.
struct ProjectEnvSchemaReference: Identifiable, Equatable, Sendable {
	typealias Draft = ProjectEnvSchemaDraft

	enum Kind: Equatable, Sendable {
		/// A group that lists the key, with its mode and members.
		case group(name: String, mode: String, members: [String])
		/// A key whose Required when names the key.
		case condition(key: String)
	}

	/// A way to stop referring to the key.
	enum Fix: Hashable, Sendable {
		case dropFromGroup
		case removeGroup
		case removeCondition
		/// Removes lpm.json's override of an imported group, so the original applies.
		case removeGroupOverride
	}

	let kind: Kind
	/// The key removed.
	let key: String
	/// The item as lpm.json has it with the draft applied, or as an imported
	/// schema declares it, which a fix overrides in lpm.json.
	let declaration: Draft.Declaration
	/// The file that declares it when lpm.json doesn't, escaped for showing.
	let source: String?

	var item: Draft.Item {
		switch kind {
		case .group(let name, _, _): .group(name)
		case .condition(let key): .key(key)
		}
	}

	var id: Draft.Item { item }

	/// The fix writes an override of an imported declaration into lpm.json,
	/// which replaces it whole: later changes to that file no longer apply.
	var writesOverride: Bool { source != nil }

	func title(of fix: Fix) -> String {
		switch fix {
		case .dropFromGroup: writesOverride ? "Override without it" : "Drop from group"
		case .removeGroup: "Remove group"
		case .removeCondition: writesOverride ? "Override without the rule" : "Remove rule"
		case .removeGroupOverride: "Use the original group"
		}
	}

	/// What the reference shows once `fix` is chosen.
	func done(by fix: Fix) -> String {
		if writesOverride { return "Overridden in lpm.json" }
		return switch fix {
		case .dropFromGroup: "Dropped from group"
		case .removeGroup: "Group removed"
		case .removeCondition: "Rule removed"
		case .removeGroupOverride: "Override removed"
		}
	}

	/// What `fix` does beyond dropping the reference, when that needs saying.
	func note(for fix: Fix) -> String? {
		if writesOverride, let source {
			let container = item.isGroup ? "groupOverrides" : "overrides"
			return "Writes envSchema.\(container).\(item.name.escapingDirectionControls) to lpm.json, which replaces \(source)'s version in full: later changes there won't apply."
		}
		switch (fix, kind) {
		case (.dropFromGroup, .group(_, let mode, let members)) where mode != "allOrNone" && members.count == 2:
			let other = members.first { $0 != key } ?? ""
			return "Leaves \(other.escapingDirectionControls) as the group's only member, which makes it required."
		case (.removeGroupOverride, _):
			return "The group the import declares applies again."
		default:
			return nil
		}
	}

	/// Such as "Group auth: Exactly one of PASSWORD, OAUTH_TOKEN".
	var title: String {
		switch kind {
		case .group(let name, let mode, let members):
			let lead = switch mode {
			case "exactlyOne": "Exactly one of"
			case "atLeastOne": "At least one of"
			default: "All or none of"
			}
			return "Group \(name.escapingDirectionControls): \(lead) \(ProjectEnvSchemaOverview.Group.preview(of: members))"
		case .condition(let other):
			return "\(other.escapingDirectionControls) · Required when \(key.escapingDirectionControls) \(conditionText)"
		}
	}

	private var conditionText: String {
		switch ProjectEnvSchemaRule(declaration.json).requiredWhen?.condition {
		case .equals(let value)?: "equals “\(value.escapingDirectionControls)”"
		case .present(false)?: "is not set"
		default: "is set"
		}
	}

	/// Where it is, such as "envSchema.groups.auth" or the file that declares it.
	var location: String {
		if let source { return source }
		let container = switch (item, declaration) {
		case (.group, .overridden): "groupOverrides"
		case (.group, _): "groups"
		case (_, .overridden): "overrides"
		default: "vars"
		}
		let name = switch item {
		case .group(let name), .key(let name): name.escapingDirectionControls
		case .clientPrefixes: ""
		}
		return switch kind {
		case .group: "envSchema.\(container).\(name)"
		case .condition: "envSchema.\(container).\(name).requiredWhen"
		}
	}

	/// The ways to settle the reference, the one that changes least first.
	var fixes: [Fix] {
		switch kind {
		case .condition:
			return [.removeCondition]
		case .group(_, let mode, let members):
			// A group needs a member, and only lpm.json's own groups can be removed from it.
			let drop: [Fix] = members.count > 1 ? [.dropFromGroup] : []
			let remove: [Fix] = source == nil && declaration.isDeclared ? [.removeGroup] : []
			let reset: [Fix] = source == nil && !declaration.isDeclared ? [.removeGroupOverride] : []
			// Dropping one of two members leaves the other required, which removing the group doesn't.
			let leavesRequired = mode != "allOrNone" && members.count == 2
			return leavesRequired ? remove + reset + drop : drop + remove + reset
		}
	}

	/// Why the reference can't be fixed in lpm.json, when it can't.
	var unfixable: String? {
		guard fixes.isEmpty else { return nil }
		return "The group has no other member and is declared in \(source ?? "an imported schema"). Remove it there."
	}

	/// The item's declaration after `fix`.
	func fixed(by fix: Fix) -> Draft.Declaration {
		switch fix {
		case .removeGroup, .removeGroupOverride:
			return .absent
		case .dropFromGroup:
			guard case .group(_, let mode, let members) = kind else { return declaration }
			let json = LPMConfigJSON.object([
				.init(key: "mode", value: .string(mode)),
				.init(key: "vars", value: .array(members.filter { $0 != key }.map(LPMConfigJSON.string))),
			])
			guard source == nil, let current = declaration.json else { return .overridden(json) }
			let kept = current.replacingMembers(of: "vars", with: members.filter { $0 != key })
			return declaration.replacingJSON { $0 = kept }
		case .removeCondition:
			if source != nil {
				var rule = ProjectEnvSchemaRule(resolved: declaration.json)
				rule.requiredWhen = nil
				return .overridden(rule.json)
			}
			return declaration.replacingJSON { $0.removeValue(forKey: "requiredWhen") }
		}
	}

	/// The references to `key` in `draft`'s rules, and in imported schemas as
	/// `rules` resolve them, groups first, each in name order.
	static func references(to key: String, in draft: Draft, rules: ProjectEnvSchemaOverview?) -> [ProjectEnvSchemaReference] {
		var groups: [ProjectEnvSchemaReference] = []
		var conditions: [ProjectEnvSchemaReference] = []
		var inRoot = Set<Draft.Item>()
		for (item, declaration) in draft.currentItems {
			inRoot.insert(item)
			guard let json = declaration.json else { continue }
			switch item {
			case .group(let name):
				let members = Self.members(json)
				if members.contains(key), case .string(let mode)? = json["mode"] {
					groups.append(.init(kind: .group(name: name, mode: mode, members: members), key: key, declaration: declaration, source: nil))
				}
			case .key(let other):
				if other != key, case .string(key)? = json["requiredWhen"]?["variable"] {
					conditions.append(.init(kind: .condition(key: other), key: key, declaration: declaration, source: nil))
				}
			case .clientPrefixes:
				break
			}
		}
		for group in rules?.groups ?? [] where group.source != nil && !inRoot.contains(.group(group.name)) && group.members.contains(key) {
			let json = LPMConfigJSON.object([.init(key: "mode", value: .string(group.mode)), .init(key: "vars", value: .array(group.members.map(LPMConfigJSON.string)))])
			groups.append(.init(kind: .group(name: group.name, mode: group.mode, members: group.members), key: key, declaration: .declared(json), source: group.source))
		}
		for rule in rules?.rules ?? [] where rule.key != key && rule.source != nil && !inRoot.contains(.key(rule.key)) {
			guard let json = rules?.declaration(of: rule.key), case .string(key)? = json["requiredWhen"]?["variable"] else { continue }
			conditions.append(.init(kind: .condition(key: rule.key), key: key, declaration: .declared(json), source: rule.source))
		}
		let byName = { (a: ProjectEnvSchemaReference, b: ProjectEnvSchemaReference) in a.item.name < b.item.name }
		return groups.sorted(by: byName) + conditions.sorted(by: byName)
	}

	private static func members(_ json: LPMConfigJSON) -> [String] {
		guard case .array(let values)? = json["vars"] else { return [] }
		return values.compactMap { if case .string(let name) = $0 { name } else { nil } }
	}
}

private extension ProjectEnvSchemaDraft.Item {
	var name: String {
		switch self {
		case .key(let name), .group(let name): name
		case .clientPrefixes: ""
		}
	}

	var isGroup: Bool { if case .group = self { true } else { false } }
}

private extension ProjectEnvSchemaDraft.Declaration {
	var isDeclared: Bool { if case .declared = self { true } else { false } }
}

private extension LPMConfigJSON {
	/// This object with `name`'s list replaced by `values`, in its place.
	func replacingMembers(of name: String, with values: [String]) -> LPMConfigJSON {
		var copy = self
		copy.set(.array(values.map(LPMConfigJSON.string)), forKey: name)
		return copy
	}
}
