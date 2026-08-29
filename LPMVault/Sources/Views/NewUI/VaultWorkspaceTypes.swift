import Foundation

enum VaultWorkspaceMode: Equatable {
	case matrix
	case environment(String)
}

enum VaultWorkspaceFilter: String, CaseIterable, Identifiable {
	case all = "All keys"
	case drift = "Drift"
	case missing = "Missing"

	var id: String { rawValue }
}

enum VaultEnvironmentViewMode: String, CaseIterable, Identifiable {
	case table = "Table"
	case raw = "Raw text"

	var id: String { rawValue }
}

struct VaultSecretTarget: Identifiable {
	let id = UUID()
	let projectId: String
	let environment: String
}

struct VaultSecretDeleteTarget: Identifiable {
	var id: String { "\(projectId)-\(environment)-\(key)" }
	let projectId: String
	let environment: String
	let key: String
}

struct VaultEnvironmentTarget: Identifiable {
	var id: String { "\(projectId)-\(environment)" }
	let projectId: String
	let environment: String
}

struct VaultSyncTarget: Identifiable, Equatable {
	let projectId: String
	let account: SelectedAccount

	var id: String {
		switch account {
		case .personal: "personal:\(projectId)"
		case .org(let slug): "org:\(slug):\(projectId)"
		}
	}
}

struct VaultWorkspaceSnapshot: Equatable {
	struct KeySummary: Equatable {
		let environmentCount: Int
		let hasDrift: Bool
	}

	let allSecretKeys: [String]
	let sortedKeysByEnvironment: [String: [String]]
	let normalizedSearchIndex: String
	let summaries: [String: KeySummary]
	let environmentCount: Int
	let driftingKeyCount: Int
	let missingKeyCount: Int

	init(project: VaultProject) {
		var valuesByKey: [String: Set<String>] = [:]
		var countsByKey: [String: Int] = [:]
		var sortedKeysByEnvironment: [String: [String]] = [:]
		sortedKeysByEnvironment.reserveCapacity(project.environments.count)
		for (environment, secrets) in project.environments {
			for (key, value) in secrets {
				valuesByKey[key, default: []].insert(value)
				countsByKey[key, default: 0] += 1
			}
			sortedKeysByEnvironment[environment] = Self.sortedKeys(secrets.keys)
		}
		self.sortedKeysByEnvironment = sortedKeysByEnvironment

		environmentCount = project.environments.count
		allSecretKeys = valuesByKey.keys.sorted {
			let comparison = $0.localizedCaseInsensitiveCompare($1)
			return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
		}
		normalizedSearchIndex = allSecretKeys.lazy.map { $0.lowercased() }.joined(separator: "\0")

		var summaries: [String: KeySummary] = [:]
		summaries.reserveCapacity(allSecretKeys.count)
		var drifting = 0
		var missing = 0
		for key in allSecretKeys {
			let count = countsByKey[key] ?? 0
			let hasDrift = (valuesByKey[key]?.count ?? 0) > 1
			if hasDrift { drifting += 1 }
			if count < environmentCount { missing += 1 }
			summaries[key] = KeySummary(environmentCount: count, hasDrift: hasDrift)
		}
		self.summaries = summaries
		driftingKeyCount = drifting
		missingKeyCount = missing
	}

	func sortedKeys(for environment: String) -> [String] {
		sortedKeysByEnvironment[environment] ?? []
	}

	private static func sortedKeys<S: Sequence>(_ keys: S) -> [String]
	where S.Element == String {
		keys.sorted {
			let comparison = $0.localizedCaseInsensitiveCompare($1)
			return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
		}
	}

	func hasDrift(for key: String) -> Bool {
		summaries[key]?.hasDrift ?? false
	}

	func isMissingSomewhere(_ key: String) -> Bool {
		guard let summary = summaries[key] else { return false }
		return summary.environmentCount < environmentCount
	}

	func environmentCount(for key: String) -> Int {
		summaries[key]?.environmentCount ?? 0
	}
}

struct VaultContentDerivation: Equatable {
	let allKeys: [String]
	let filteredKeys: [String]
	let environmentKeys: [String]
	let environmentDriftingKeyCount: Int
	let allVisibleRevealed: Bool

	init(
		project: VaultProject,
		snapshot: VaultWorkspaceSnapshot,
		selectedEnvironment: String,
		mode: VaultWorkspaceMode,
		filter: VaultWorkspaceFilter,
		searchText: String,
		revealedKeys: Set<String>
	) {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		allKeys = snapshot.allSecretKeys
		switch mode {
		case .matrix:
			filteredKeys = allKeys.filter { key in
				let matchesFilter: Bool
				switch filter {
				case .all: matchesFilter = true
				case .drift: matchesFilter = snapshot.hasDrift(for: key)
				case .missing: matchesFilter = snapshot.isMissingSomewhere(key)
				}
				return matchesFilter && (query.isEmpty || key.lowercased().contains(query))
			}
			environmentKeys = []
			environmentDriftingKeyCount = 0
		case .environment:
			filteredKeys = []
			environmentKeys = snapshot.sortedKeys(for: selectedEnvironment)
				.filter { query.isEmpty || $0.lowercased().contains(query) }
			environmentDriftingKeyCount = environmentKeys.reduce(into: 0) { count, key in
				if snapshot.hasDrift(for: key) { count += 1 }
			}
		}
		let visibleKeys = mode == .matrix ? filteredKeys : environmentKeys
		allVisibleRevealed = !visibleKeys.isEmpty && visibleKeys.allSatisfy(revealedKeys.contains)
	}
}

struct VaultSecretEditDraft: Equatable {
	private(set) var baseline: String
	var draft: String
	private(set) var hasExternalConflict = false

	init(value: String) {
		baseline = value
		draft = value
	}

	var isDirty: Bool { draft != baseline }
	var canSave: Bool { isDirty && !hasExternalConflict }
	var canRevert: Bool { isDirty || hasExternalConflict }

	mutating func receiveExternalValue(_ value: String) {
		if value == draft {
			baseline = value
			hasExternalConflict = false
			return
		}
		guard value != baseline else { return }
		if !isDirty {
			baseline = value
			draft = value
			hasExternalConflict = false
		} else {
			baseline = value
			hasExternalConflict = true
		}
	}

	mutating func revert() {
		draft = baseline
		hasExternalConflict = false
	}

}

extension VaultProject {
	var allSecretKeys: [String] {
		VaultWorkspaceSnapshot(project: self).allSecretKeys
	}

	func value(for key: String, in environment: String) -> String? {
		environments[environment]?[key]
	}

	func hasDrift(for key: String) -> Bool {
		VaultWorkspaceSnapshot(project: self).hasDrift(for: key)
	}

	func isMissingSomewhere(_ key: String) -> Bool {
		VaultWorkspaceSnapshot(project: self).isMissingSomewhere(key)
	}

	func environmentCount(for key: String) -> Int {
		VaultWorkspaceSnapshot(project: self).environmentCount(for: key)
	}
}
