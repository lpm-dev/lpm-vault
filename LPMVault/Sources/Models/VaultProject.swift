import Foundation

struct VaultProject: Identifiable, Hashable, Sendable {
	let id: String  // vault UUID
	var name: String
	var path: String
	var environments: [String: [String: String]]  // env name → secrets

	/// All environment names (internal keys), sorted. Always has at least "default".
	var environmentNames: [String] {
		let names = Array(environments.keys).sorted()
		return names.isEmpty ? ["default"] : names
	}

	/// Convert internal env name to display format: "default" → ".env", "live" → ".env.live"
	static func displayName(for env: String) -> String {
		if env == "default" { return ".env" }
		return ".env.\(env)"
	}

	/// Get secrets for a specific environment.
	func secrets(for env: String) -> [String: String] {
		environments[env] ?? [:]
	}

	/// Get sorted secrets for a specific environment.
	func sortedSecrets(for env: String) -> [VaultSecret] {
		secrets(for: env)
			.sorted {
				let comparison = $0.key.localizedCaseInsensitiveCompare($1.key)
				return comparison == .orderedSame
					? $0.key < $1.key
					: comparison == .orderedAscending
			}
			.map { VaultSecret(key: $0.key, value: $0.value) }
	}

	/// Total secret count across all environments.
	var secretCount: Int {
		environments.values.reduce(0) { $0 + $1.count }
	}

	/// Secret count for a specific environment.
	func secretCount(for env: String) -> Int {
		environments[env]?.count ?? 0
	}

	var pathExists: Bool {
		FileManager.default.fileExists(atPath: path)
	}

	// MARK: - Backwards compatibility

	/// Flat secrets (for old code paths) — returns "default" environment.
	var secrets: [String: String] {
		get { environments["default"] ?? [:] }
		set {
			var envs = environments
			envs["default"] = newValue
			environments = envs
		}
	}

	var sortedSecrets: [VaultSecret] {
		sortedSecrets(for: environmentNames.first ?? "default")
	}
}
