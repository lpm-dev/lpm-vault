import Foundation

/// One save from the key inspector: an optional rename plus new values, applied
/// to every environment of a project at once.
///
/// A rename moves the key in every environment that has it, so one variable
/// keeps one name everywhere. Environments without the key are untouched unless
/// the edit gives them a value.
struct VaultKeyEdit: Equatable, Sendable {
	/// The key's name when the edit began.
	let key: String
	/// The name to save under; equal to `key` when the key is not renamed.
	let newKey: String
	/// The key's value in each environment when the edit began, or nil where it
	/// was absent. Any difference at save time means another process changed it.
	let baseline: [String: String?]
	/// Values to save under `newKey`, by environment. An environment without the
	/// key gains it.
	let values: [String: String]

	enum Failure: Error, Equatable, Sendable {
		case invalidName
		/// The key's values or environments changed since the edit began.
		case changed
		/// `newKey` would collide with `existingKey`, which differs at most in letter case.
		case collision(environment: String, existingKey: String)
	}

	init(key: String, newKey: String, baseline: [String: String?], values: [String: String]) {
		self.key = key
		self.newKey = newKey
		self.baseline = baseline
		self.values = values
	}

	/// Starts an edit of `key` from the project's current environments.
	init(key: String, environments: [String: [String: String]], newKey: String? = nil, values: [String: String] = [:]) {
		self.init(
			key: key,
			newKey: newKey ?? key,
			baseline: environments.mapValues { $0[key] },
			values: values
		)
	}

	var isRename: Bool { newKey != key }

	/// Environments where a rename would apply: each one that has the key.
	static func environments(containing key: String, in environments: [String: [String: String]]) -> [String] {
		environments.compactMap { $0.value[key] == nil ? nil : $0.key }.sorted()
	}

	/// The project's environments after this edit, or why it cannot apply to them.
	func applied(to environments: [String: [String: String]]) -> Result<[String: [String: String]], Failure> {
		let addsKey = values.keys.contains { environments[$0]?[key] == nil }
		if isRename || addsKey, !EnvValidation.isValidVariableName(newKey) {
			return .failure(.invalidName)
		}
		for (name, secrets) in environments where secrets[key] != baseline[name] ?? nil {
			return .failure(.changed)
		}
		for (name, value) in baseline where value != nil && environments[name] == nil {
			return .failure(.changed)
		}
		for name in values.keys where environments[name] == nil {
			return .failure(.changed)
		}

		let foldedNewKey = newKey.lowercased()
		var result = environments
		for name in environments.keys.sorted() {
			guard var secrets = result[name] else { continue }
			let hasKey = secrets[key] != nil
			let changesHere = values[name] != nil || (hasKey && isRename)
			guard changesHere else { continue }
			if isRename || !hasKey,
				let existing = secrets.keys.first(where: { $0 != key && $0.lowercased() == foldedNewKey })
			{
				return .failure(.collision(environment: name, existingKey: existing))
			}
			let value = values[name] ?? secrets[key]
			secrets.removeValue(forKey: key)
			secrets[newKey] = value
			result[name] = secrets
		}
		return .success(result)
	}
}

enum VaultKeyEditError: LocalizedError, Equatable, Sendable {
	case vaultLocked
	case targetUnavailable
	case invalidName
	case changed
	case collision(environment: String, existingKey: String, newKey: String)
	case persistence(String)
	/// `lpm.json` could not be updated; `keySaved` tells whether the Keychain part was.
	case description(String, keySaved: Bool)

	init(_ failure: VaultKeyEdit.Failure, newKey: String) {
		switch failure {
		case .invalidName: self = .invalidName
		case .changed: self = .changed
		case .collision(let environment, let existingKey):
			self = .collision(environment: environment, existingKey: existingKey, newKey: newKey)
		}
	}

	var errorDescription: String? {
		switch self {
		case .vaultLocked:
			"Unlock LPM Vault before saving."
		case .targetUnavailable:
			"The env project changed before the edit was saved."
		case .invalidName:
			"Use letters, numbers, and underscores; the first character cannot be a number."
		case .changed:
			"This key changed in another LPM process. Review the latest values, then save again."
		case .collision(let environment, let existingKey, let newKey) where existingKey == newKey:
			"\(newKey) already exists in \(VaultProject.displayName(for: environment))."
		case .collision(let environment, let existingKey, _):
			"\(existingKey) already exists in \(VaultProject.displayName(for: environment)). Keys that differ only in letter case conflict on Windows."
		case .persistence(let message):
			"Could not save the key. \(message)"
		case .description(let reason, keySaved: false):
			"Could not save the description. \(reason)"
		case .description(let reason, keySaved: true):
			"The key was saved, but lpm.json was not updated. \(reason)"
		}
	}
}
