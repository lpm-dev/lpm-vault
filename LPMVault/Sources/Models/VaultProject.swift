import Foundation

struct VaultProject: Identifiable, Hashable {
	let id: String  // vault UUID
	var name: String
	var path: String
	var secrets: [String: String]

	var sortedSecrets: [VaultSecret] {
		secrets
			.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
			.map { VaultSecret(key: $0.key, value: $0.value) }
	}

	var secretCount: Int {
		secrets.count
	}

	var pathExists: Bool {
		FileManager.default.fileExists(atPath: path)
	}
}
