import Foundation

/// lpm.json's client prefixes, which make keys that start with them public,
/// and what changing them does to the keys they cover. The LPM CLI requires
/// a key to be marked public exactly when a framework's or a declared prefix
/// starts its name, so a prefix and the keys it covers change together.
enum ProjectEnvSchemaClientPrefixes {
	typealias Draft = ProjectEnvSchemaDraft
	typealias Rules = ProjectEnvSchemaOverview

	/// The most prefixes the LPM CLI accepts, lpm.json's and its imports' together.
	static let maximum = 32

	/// lpm.json's own prefixes with the draft applied, in its order.
	static func own(in draft: Draft) -> [String] {
		prefixes(in: draft.declaration(of: .clientPrefixes))
	}

	private static func prefixes(in list: Draft.Declaration) -> [String] {
		guard case .array(let values)? = list.json else { return [] }
		return values.compactMap { if case .string(let prefix) = $0 { prefix } else { nil } }
	}

	/// What a change to the prefixes is worked out from: the draft, and the
	/// rules the engine resolved for exactly that draft, never rules of
	/// another version of it.
	struct Context: Equatable, Sendable {
		let draft: Draft
		/// lpm.json's rules with the draft applied; lpm.json's own without a draft.
		let rules: Rules
		/// lpm.json's rules as last read, without the draft.
		let saved: Rules

		/// lpm.json's own prefixes with the draft applied, in its order.
		var own: [String] { ProjectEnvSchemaClientPrefixes.own(in: draft) }
		/// The prefixes lpm.json's imports list, each with the first schema that lists it.
		var imported: [String: String] { rules.importedClientPrefixes }
		/// Every declared prefix in effect: lpm.json's and its imports'.
		var inEffect: Set<String> { Set(own).union(imported.keys) }
	}

	/// Whether the prefixes can be changed now, and from what.
	enum Availability: Equatable, Sendable {
		case ready(Context)
		/// The draft is being checked, so its rules aren't known yet.
		case checking
		/// The LPM CLI rejects the draft, so its rules aren't known.
		case rejected
		/// lpm.json's rules can't be read.
		case unreadable

		var context: Context? { if case .ready(let context) = self { context } else { nil } }

		/// Why the prefixes can't be changed now; nil when they can.
		var reason: String? {
			switch self {
			case .ready: nil
			case .checking: "Checking your draft…"
			case .rejected: "Fix your draft's problems to change prefixes."
			case .unreadable: "lpm.json's rules can't be read."
			}
		}
	}

	/// Why a prefix can't be added.
	enum Issue: Equatable, Sendable {
		case invalid
		case tooLong
		/// The LPM CLI requires a prefix to end with an underscore.
		case missingUnderscore
		/// A framework's prefix, which makes keys public anyway.
		case framework
		case duplicate
		/// Keys that start with it are already public through `prefix`.
		case redundant(by: String)
		case tooMany
		/// A Secret key would become public, which the LPM CLI rejects.
		case secret(key: String)

		var message: String {
			switch self {
			case .invalid: "Use letters, digits and underscores; a prefix can't start with a digit."
			case .tooLong: "A prefix can be at most \(EnvValidation.maximumSchemaKeyNameBytes) bytes."
			case .missingUnderscore: "A prefix ends with an underscore, such as ACME_PUBLIC_."
			case .framework: "Keys with a framework's prefix are always public."
			case .duplicate: "This prefix is already listed."
			case .redundant(let prefix): "Keys that start with it are already public through \(prefix.escapingDirectionControls)."
			case .tooMany: "The LPM CLI accepts at most \(maximum) prefixes."
			case .secret(let key):
				"\(key.escapingDirectionControls) is Secret, and a public key can't be. Turn off its Secret first, or choose a prefix it doesn't start with."
			}
		}
	}

	/// A change to lpm.json's prefixes and to the keys it makes public or private.
	struct Change: Equatable, Sendable {
		/// Every item the change sets, the prefixes first.
		let edits: [Edit]
		/// Keys that become public or private, from A to Z.
		let keys: [String]
		/// Of `keys`, those an imported schema declares that lpm.json starts
		/// overriding, with a copy of the imported rule, to change them.
		let overridden: [String]
		/// Of `keys`, those whose override in lpm.json would only repeat the
		/// imported rule once marked, which goes, so the imported rule applies as it is.
		let restored: [String]
		/// Of `keys`, those an import marks Secret whose override in lpm.json
		/// doesn't, so the change makes their values public.
		var exposed: [Exposure] = []
	}

	/// A key whose value becomes public though an import marks it Secret.
	struct Exposure: Equatable, Sendable {
		let key: String
		/// The schema that marks it Secret, escaped.
		let source: String
	}

	struct Edit: Equatable, Sendable {
		let item: Draft.Item
		let declaration: Draft.Declaration
	}

	/// Why `prefix` can't be added, or nil when it can.
	static func issue(adding prefix: String, in context: Context) -> Issue? {
		guard prefix.utf8.count <= EnvValidation.maximumSchemaKeyNameBytes else { return .tooLong }
		guard EnvValidation.isValidVariableName(prefix) else { return .invalid }
		guard prefix.hasSuffix("_") else { return .missingUnderscore }
		if ProjectEnvSchemaRule.frameworkPrefixes.contains(prefix) || prefix.uppercased() == "REACT_APP_" { return .framework }
		let current = context.inEffect
		guard !current.contains(prefix) else { return .duplicate }
		if let covering = ProjectEnvSchemaRule.publicPrefix(of: prefix, clientPrefixes: Array(current)) { return .redundant(by: covering) }
		guard current.count < maximum else { return .tooMany }
		if let secret = context.rules.rules.first(where: { $0.isSecret && $0.key.hasPrefix(prefix) }) { return .secret(key: secret.key) }
		return nil
	}

	/// Adding `prefix`, with the keys it makes public marked so.
	static func adding(_ prefix: String, in context: Context) -> Change {
		let current = Array(context.inEffect)
		let keys = context.rules.rules.lazy.filter { $0.key.hasPrefix(prefix) && !isPublic($0.key, current) }.map(\.key)
		return change(prefixes: context.own + [prefix], keys: Array(keys), public: true, in: context)
	}

	/// The keys removing `prefix` makes private: public ones no other prefix
	/// covers. An imported schema that lists it too keeps it in effect.
	static func keys(removing prefix: String, in context: Context) -> [String] {
		guard context.imported[prefix] == nil else { return [] }
		let remaining = Array(context.inEffect.subtracting([prefix]))
		return context.rules.rules.lazy.filter { $0.isPublic && $0.key.hasPrefix(prefix) && !isPublic($0.key, remaining) }.map(\.key)
	}

	/// Removing `prefix` from lpm.json, with the keys it alone made public marked private.
	static func removing(_ prefix: String, in context: Context) -> Change {
		change(prefixes: context.own.filter { $0 != prefix }, keys: keys(removing: prefix, in: context), public: false, in: context)
	}

	/// The change to make when adding `prefix` is confirmed: `shown`, as long
	/// as `entry` still holds the prefix and adding it still does exactly
	/// that. Return or a click can arrive before the newest text or rules
	/// have been shown; then nothing is added until they are.
	static func confirmed(_ shown: Change, adding prefix: String, entry: String, in context: Context) -> Change? {
		guard entry.trimmingCharacters(in: .whitespaces) == prefix, issue(adding: prefix, in: context) == nil,
			adding(prefix, in: context) == shown
		else { return nil }
		return shown
	}

	/// The change to make when removing `prefix` is confirmed: `shown`, as
	/// long as removing it still does exactly that.
	static func confirmed(_ shown: Change, removing prefix: String, in context: Context) -> Change? {
		guard context.own.contains(prefix), removing(prefix, in: context) == shown else { return nil }
		return shown
	}

	/// How many declared keys each prefix covers, counted in one pass over the rules.
	static func keyCounts(of prefixes: some Sequence<String>, rules: Rules) -> [String: Int] {
		var counts = Dictionary(uniqueKeysWithValues: prefixes.map { ($0, 0) })
		guard !counts.isEmpty else { return counts }
		let listed = Array(counts.keys)
		for rule in rules.rules {
			for prefix in listed where rule.key.hasPrefix(prefix) { counts[prefix, default: 0] += 1 }
		}
		return counts
	}

	/// Marks each key lpm.json declares public exactly when a prefix in effect
	/// starts its name, as the LPM CLI requires, among the keys an edit from
	/// `previous` could have unsettled: those it changed, and those a prefix
	/// it added or removed covers. After a merge of a change on disk,
	/// `everyKey` settles them all, since the file's own keys and prefixes
	/// can disagree with the draft's. `imported` are the imports' prefixes,
	/// which stay in effect whatever lpm.json lists, and `saved` is
	/// lpm.json's rules as last read.
	///
	/// A Secret key is left unmarked, for the LPM CLI to reject and the user
	/// to decide. An override the draft adds that, once marked, repeats the
	/// imported rule goes, so that rule applies as it is.
	static func settle(_ draft: inout Draft, since previous: Draft, everyKey: Bool = false, imported: Set<String>, saved: Rules) {
		let own = Self.own(in: draft)
		var keys: Set<String> = []
		if everyKey {
			for case (.key(let key), _) in draft.currentItems { keys.insert(key) }
		} else {
			for case .key(let key) in previous.changedItems + draft.changedItems
			where draft.declaration(of: .key(key)) != previous.declaration(of: .key(key)) {
				keys.insert(key)
			}
			let changedPrefixes = Set(own).symmetricDifference(Self.own(in: previous))
			if !changedPrefixes.isEmpty {
				for case (.key(let key), _) in draft.currentItems where changedPrefixes.contains(where: key.hasPrefix) { keys.insert(key) }
			}
		}
		guard !keys.isEmpty else { return }
		let prefixes = Array(Set(own).union(imported))
		var edits: [(Draft.Item, Draft.Declaration)] = []
		for key in keys {
			let item = Draft.Item.key(key)
			let declaration = draft.declaration(of: item)
			guard case .object? = declaration.json else { continue }
			let wanted = isPublic(key, prefixes)
			guard (declaration.json?["client"] == .bool(true)) != wanted, !(wanted && declaration.json?["secret"] == .bool(true)) else { continue }
			let settled = declaration.replacingJSON { json in
				if wanted { json.set(.bool(true), forKey: "client") } else { json.removeValue(forKey: "client") }
			}
			if case .overridden(let json) = settled, repeatsImport(key, json, in: draft, saved: saved) {
				edits.append((item, .absent))
			} else {
				edits.append((item, settled))
			}
		}
		if !edits.isEmpty { draft.set(edits) }
	}

	/// Whether lpm.json's override of `key`, marked public or not as
	/// `isPublic` says, would be the imported rule it replaces, so it can go.
	static func overrideCanGo(_ key: String, public isPublic: Bool, in context: Context) -> Bool {
		guard case .overridden(let json) = context.draft.declaration(of: .key(key)) else { return false }
		var rule = ProjectEnvSchemaRule(resolved: json)
		rule.client = isPublic
		return repeatsImport(key, rule.json, in: context.draft, saved: context.saved)
	}

	/// Whether `json`, as lpm.json's override of `key`, is the imported rule
	/// it replaces. Only an override the draft adds is known that well: the
	/// imported rule is lpm.json's rule for the key as last read, when
	/// lpm.json doesn't override it, so a single import declares it. The
	/// engine never reports an overridden rule's values.
	static func repeatsImport(_ key: String, _ json: LPMConfigJSON, in draft: Draft, saved: Rules) -> Bool {
		guard draft.base(of: .key(key)) == .absent, saved.rule(for: key)?.source != nil, let imported = saved.declaration(of: key) else { return false }
		return ProjectEnvSchemaRule(resolved: json).json.isEquivalent(to: ProjectEnvSchemaRule(resolved: imported).json)
	}

	// MARK: - Private

	private static func isPublic(_ key: String, _ prefixes: [String]) -> Bool {
		ProjectEnvSchemaRule.publicPrefix(of: key, clientPrefixes: prefixes) != nil
	}

	private static func change(prefixes: [String], keys: [String], public isPublic: Bool, in context: Context) -> Change {
		let draft = context.draft
		// Back to the prefixes lpm.json has, the list is as lpm.json writes it, even an empty one.
		let list: Draft.Declaration = if prefixes == Self.prefixes(in: draft.base(of: .clientPrefixes)) {
			draft.base(of: .clientPrefixes)
		} else if prefixes.isEmpty {
			.absent
		} else {
			.declared(.array(prefixes.map(LPMConfigJSON.string)))
		}
		var edits = [Edit(item: .clientPrefixes, declaration: list)]
		var overridden: [String] = []
		var restored: [String] = []
		var exposed: [Exposure] = []
		for key in keys {
			let item = Draft.Item.key(key)
			if isPublic, let secret = context.rules.replacedRules[key]?.secret {
				exposed.append(Exposure(key: key, source: secret.source.escapingDirectionControls))
			}
			switch draft.declaration(of: item) {
			case .overridden where overrideCanGo(key, public: isPublic, in: context):
				edits.append(Edit(item: item, declaration: .absent))
				restored.append(key)
			case .declared, .overridden:
				edits.append(Edit(item: item, declaration: draft.declaration(of: item).replacingJSON { json in
					if isPublic { json.set(.bool(true), forKey: "client") } else { json.removeValue(forKey: "client") }
				}))
			case .absent:
				// Declared in an imported schema: an override in lpm.json changes it.
				var resolved = ProjectEnvSchemaRule(resolved: context.rules.declaration(of: key))
				resolved.client = isPublic
				edits.append(Edit(item: item, declaration: .overridden(resolved.json)))
				overridden.append(key)
			}
		}
		return Change(edits: edits, keys: keys, overridden: overridden, restored: restored, exposed: exposed)
	}
}
