import Foundation

/// Validation state for adding one key to several environments of a project.
struct AddVariableDraft: Equatable {
	enum KeyIssue: Equatable {
		case invalidName
		case exists(environments: [String])
		case collides(existingKey: String, environment: String)

		var message: String {
			switch self {
			case .invalidName:
				"Use letters, numbers, and underscores; the first character cannot be a number."
			case .exists(let environments):
				"Already exists in \(Self.list(environments.map(VaultProject.displayName(for:))))."
			case .collides(let existingKey, let environment):
				"\(existingKey) already exists in \(VaultProject.displayName(for: environment)). Keys must differ by more than letter case."
			}
		}

		private static func list(_ names: [String]) -> String {
			switch names.count {
			case 0: ""
			case 1: names[0]
			case 2: "\(names[0]) and \(names[1])"
			default: names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
			}
		}
	}

	/// Environment names in display order.
	let environments: [String]
	private let secretsByEnvironment: [String: [String: String]]
	/// Existing keys per environment, indexed by their lowercased form.
	private let keysByFoldedName: [String: [String: String]]
	var key = ""
	var selection: Set<String>

	init(environments: [String], secretsByEnvironment: [String: [String: String]], selection: Set<String>) {
		self.environments = environments
		self.secretsByEnvironment = secretsByEnvironment
		self.selection = selection.intersection(environments)
		var index: [String: [String: String]] = [:]
		for environment in environments {
			guard let secrets = secretsByEnvironment[environment] else { continue }
			var folded: [String: String] = [:]
			folded.reserveCapacity(secrets.count)
			for existingKey in secrets.keys {
				folded[existingKey.lowercased()] = existingKey
			}
			index[environment] = folded
		}
		keysByFoldedName = index
	}

	var selectedEnvironments: [String] {
		environments.filter(selection.contains)
	}

	var allSelected: Bool {
		!environments.isEmpty && selection.count == environments.count
	}

	var keyIssue: KeyIssue? {
		guard !key.isEmpty else { return nil }
		guard EnvValidation.isValidVariableName(key) else { return .invalidName }
		let folded = key.lowercased()
		let selected = selectedEnvironments
		let exactMatches = selected.filter { secretsByEnvironment[$0]?[key] != nil }
		if !exactMatches.isEmpty { return .exists(environments: exactMatches) }
		for environment in selected {
			if let existingKey = keysByFoldedName[environment]?[folded], existingKey != key {
				return .collides(existingKey: existingKey, environment: environment)
			}
		}
		return nil
	}

	/// Whether `key` already exists in `environment`, exactly or by letter case.
	func conflicts(in environment: String) -> Bool {
		guard !key.isEmpty, EnvValidation.isValidVariableName(key) else { return false }
		return keysByFoldedName[environment]?[key.lowercased()] != nil
	}

	var canSubmit: Bool {
		!key.isEmpty && !selection.isEmpty && keyIssue == nil
	}

	var submitTitle: String {
		let selected = selectedEnvironments
		switch selected.count {
		case 0: return "Add variable"
		case 1: return "Add to \(VaultProject.displayName(for: selected[0]))"
		default: return "Add to \(selected.count) environments"
		}
	}

	mutating func toggleAll() {
		selection = allSelected ? [] : Set(environments)
	}
}
