import Foundation

struct VaultProject: Identifiable, Hashable, Sendable {
	let id: String  // vault UUID
	var name: String {
		didSet { refreshWorkspaceSnapshotIdentity() }
	}
	var path: String {
		didSet { refreshWorkspaceSnapshotIdentity() }
	}
	var environments: [String: [String: String]] {
		didSet {
			hasLoadedEnvironments = true
			environmentKeyCounts = environments.mapValues(\.count)
			refreshWorkspaceSnapshotIdentity()
		}
	}
	private(set) var environmentKeyCounts: [String: Int]
	private(set) var hasLoadedEnvironments: Bool
	private(set) var workspaceSnapshotIdentity: UUID

	init(
		id: String,
		name: String,
		path: String,
		environments: [String: [String: String]]
	) {
		self.id = id
		self.name = name
		self.path = path
		self.environments = environments
		self.environmentKeyCounts = environments.mapValues(\.count)
		self.hasLoadedEnvironments = true
		self.workspaceSnapshotIdentity = UUID()
	}

	init(metadata: VaultProjectMetadata) {
		self.id = metadata.id
		self.name = metadata.name
		self.path = metadata.path
		self.environments = [:]
		self.environmentKeyCounts = Dictionary(uniqueKeysWithValues:
			metadata.environmentSummaries.map { ($0.name, $0.keyCount) }
		)
		self.hasLoadedEnvironments = false
		self.workspaceSnapshotIdentity = UUID()
	}

	var metadata: VaultProjectMetadata {
		VaultProjectMetadata(
			id: id,
			name: name,
			path: path,
			environmentSummaries: environmentKeyCounts.map { name, count in
				VaultProjectEnvironmentSummary(name: name, keyCount: count)
			}.sorted { $0.name < $1.name }
		)
	}

	static func == (lhs: VaultProject, rhs: VaultProject) -> Bool {
		lhs.id == rhs.id && lhs.name == rhs.name && lhs.path == rhs.path
			&& lhs.environments == rhs.environments
			&& lhs.environmentKeyCounts == rhs.environmentKeyCounts
			&& lhs.hasLoadedEnvironments == rhs.hasLoadedEnvironments
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
		hasher.combine(name)
		hasher.combine(path)
		hasher.combine(environments)
		hasher.combine(environmentKeyCounts)
		hasher.combine(hasLoadedEnvironments)
	}

	private mutating func refreshWorkspaceSnapshotIdentity() {
		workspaceSnapshotIdentity = UUID()
	}

	/// All environment names (internal keys), sorted. Always has at least "default".
	var environmentNames: [String] {
		let names = hasLoadedEnvironments
			? environments.keys.sorted()
			: environmentKeyCounts.keys.sorted()
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
		hasLoadedEnvironments
			? environments.values.reduce(0) { $0 + $1.count }
			: environmentKeyCounts.values.reduce(0, +)
	}

	/// Secret count for a specific environment.
	func secretCount(for env: String) -> Int {
		hasLoadedEnvironments ? environments[env]?.count ?? 0 : environmentKeyCounts[env] ?? 0
	}

	var pathExists: Bool {
		FileManager.default.fileExists(atPath: path)
	}

}
