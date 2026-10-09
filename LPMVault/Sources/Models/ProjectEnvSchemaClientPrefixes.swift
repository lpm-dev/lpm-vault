import Foundation

/// lpm.json's client prefixes, which make keys that start with them public,
/// and what changing them does to the keys they cover. The LPM CLI requires
/// a key to be marked public exactly when a framework's or a declared prefix
/// starts its name, so a prefix and the keys it covers change together.
enum ProjectEnvSchemaClientPrefixes {
	typealias Draft = ProjectEnvSchemaDraft

	/// The most prefixes the LPM CLI accepts, lpm.json's and its imports' together.
	static let maximum = 32

	/// lpm.json's own prefixes with the draft applied, in its order.
	static func own(in draft: Draft) -> [String] {
		guard case .array(let values)? = draft.declaration(of: .clientPrefixes).json else { return [] }
		return values.compactMap { if case .string(let prefix) = $0 { prefix } else { nil } }
	}

	/// Why a prefix can't be added.
	enum Issue: Equatable, Sendable {
		case invalid
		/// The LPM CLI requires a prefix to end with an underscore.
		case missingUnderscore
		/// A framework's prefix, which makes keys public anyway.
		case framework
		case duplicate
		case tooMany
		/// A Secret key would become public, which the LPM CLI rejects.
		case secret(key: String)

		var message: String {
			switch self {
			case .invalid: "Use letters, digits and underscores; a prefix can't start with a digit."
			case .missingUnderscore: "A prefix ends with an underscore, such as ACME_PUBLIC_."
			case .framework: "Keys with a framework's prefix are always public."
			case .duplicate: "This prefix is already listed."
			case .tooMany: "The LPM CLI accepts at most \(maximum) prefixes."
			case .secret(let key):
				"\(key.escapingDirectionControls) is Secret. Public keys can't be secret — rename it or turn off Secret first."
			}
		}
	}

	/// A change to lpm.json's prefixes and to the keys it makes public or private.
	struct Change: Equatable, Sendable {
		/// Every item the change sets, the prefixes first.
		let edits: [Edit]
		/// Keys that become public or private, from A to Z.
		let keys: [String]
		/// Of `keys`, those an imported schema declares, which an override in lpm.json changes.
		let overridden: [String]
	}

	struct Edit: Equatable, Sendable {
		let item: Draft.Item
		let declaration: Draft.Declaration
	}

	/// Why `prefix` can't be added, or nil when it can.
	static func issue(adding prefix: String, draft: Draft, rules: ProjectEnvSchemaOverview?) -> Issue? {
		guard EnvValidation.isValidVariableName(prefix), prefix.utf8.count <= EnvValidation.maximumSchemaKeyNameBytes else { return .invalid }
		guard prefix.hasSuffix("_") else { return .missingUnderscore }
		if ProjectEnvSchemaRule.frameworkPrefixes.contains(prefix) || prefix.uppercased() == "REACT_APP_" { return .framework }
		let current = Set(rules?.clientPrefixes ?? []).union(own(in: draft))
		guard !current.contains(prefix) else { return .duplicate }
		guard current.count < maximum else { return .tooMany }
		let before = Array(current)
		if let secret = rules?.rules.first(where: { $0.isSecret && $0.key.hasPrefix(prefix) && !isPublic($0.key, before) }) {
			return .secret(key: secret.key)
		}
		return nil
	}

	/// Adding `prefix`, with the keys it makes public marked so.
	static func adding(_ prefix: String, draft: Draft, rules: ProjectEnvSchemaOverview?) -> Change {
		let current = Array(Set(rules?.clientPrefixes ?? []).union(own(in: draft)))
		let keys = (rules?.rules ?? []).filter { $0.key.hasPrefix(prefix) && !isPublic($0.key, current) }
		return change(prefixes: own(in: draft) + [prefix], keys: keys, public: true, draft: draft, rules: rules)
	}

	/// The prefixes lpm.json's imports declare: `known` when the rules were
	/// read with them told apart, otherwise those lpm.json doesn't list itself.
	static func imported(_ known: [String]?, draft: Draft, rules: ProjectEnvSchemaOverview?) -> Set<String> {
		known.map(Set.init) ?? Set(rules?.clientPrefixes ?? []).subtracting(own(in: draft))
	}

	/// The keys removing `prefix` makes private: public ones no other prefix
	/// covers. `imported` are the imports' prefixes, which stay in effect.
	static func keys(removing prefix: String, imported: Set<String>, draft: Draft, rules: ProjectEnvSchemaOverview?) -> [String] {
		removedKeys(prefix, imported: imported, draft: draft, rules: rules).map(\.key)
	}

	/// Removing `prefix` from lpm.json, with the keys it alone made public marked private.
	static func removing(_ prefix: String, imported: Set<String>, draft: Draft, rules: ProjectEnvSchemaOverview?) -> Change {
		change(prefixes: own(in: draft).filter { $0 != prefix }, keys: removedKeys(prefix, imported: imported, draft: draft, rules: rules),
			public: false, draft: draft, rules: rules)
	}

	/// The keys each of lpm.json's own prefixes, and each imported one, covers.
	static func keyCount(of prefix: String, rules: ProjectEnvSchemaOverview?) -> Int {
		(rules?.rules ?? []).lazy.filter { $0.key.hasPrefix(prefix) }.count
	}

	// MARK: - Private

	private static func removedKeys(
		_ prefix: String, imported: Set<String>, draft: Draft, rules: ProjectEnvSchemaOverview?
	) -> [ProjectEnvSchemaOverview.Rule] {
		// An imported schema that lists the same prefix keeps it in effect.
		guard !imported.contains(prefix) else { return [] }
		let remaining = Array(Set(rules?.clientPrefixes ?? []).union(own(in: draft)).subtracting([prefix]))
		return (rules?.rules ?? []).filter { $0.isPublic && $0.key.hasPrefix(prefix) && !isPublic($0.key, remaining) }
	}

	private static func isPublic(_ key: String, _ prefixes: [String]) -> Bool {
		ProjectEnvSchemaRule.publicPrefix(of: key, clientPrefixes: prefixes) != nil
	}

	private static func change(
		prefixes: [String], keys: [ProjectEnvSchemaOverview.Rule], public isPublic: Bool, draft: Draft, rules: ProjectEnvSchemaOverview?
	) -> Change {
		// Without prefixes of its own, lpm.json has no list at all.
		let list: Draft.Declaration = prefixes.isEmpty ? .absent : .declared(.array(prefixes.map(LPMConfigJSON.string)))
		var edits = [Edit(item: .clientPrefixes, declaration: list)]
		var overridden: [String] = []
		for rule in keys {
			let item = Draft.Item.key(rule.key)
			let mark: (inout LPMConfigJSON) -> Void = { json in
				if isPublic { json.set(.bool(true), forKey: "client") } else { json.removeValue(forKey: "client") }
			}
			switch draft.declaration(of: item) {
			case .declared, .overridden:
				edits.append(Edit(item: item, declaration: draft.declaration(of: item).replacingJSON(mark)))
			case .absent:
				// Declared in an imported schema: an override in lpm.json changes it.
				var resolved = ProjectEnvSchemaRule(resolved: rules?.declaration(of: rule.key))
				resolved.client = isPublic
				edits.append(Edit(item: item, declaration: .overridden(resolved.json)))
				overridden.append(rule.key)
			}
		}
		let sorted = VaultKeySortOrder.sortedAscending(keys.map(\.key))
		return Change(edits: edits, keys: sorted, overridden: VaultKeySortOrder.sortedAscending(overridden))
	}
}
