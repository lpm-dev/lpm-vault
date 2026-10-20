import Foundation

struct EnvFileImportReview: Identifiable, Sendable {
	enum Change: String, Sendable {
		case added = "New"
		case changed = "Different value"
		case unchanged = "Unchanged"
	}

	struct Row: Identifiable, Sendable {
		let key: String
		let change: Change
		var id: String { key }
	}

	let id: UUID
	let projectId: String
	let projectName: String
	let projectPath: String
	let environment: String
	let source: EnvImportSource
	let sessionGeneration: Int
	let imported: ImportedEnvFile
	let baseline: [String: String]
	let rows: [Row]
	/// The rows for each kind of change, sorted by key.
	let added: [Row]
	let changed: [Row]
	let unchanged: [Row]
	let addedKeys: Set<String>
	let changedKeys: Set<String>
	var addedCount: Int { added.count }
	var unchangedCount: Int { unchanged.count }

	init(
		id: UUID, project: VaultProject, environment: String, source: EnvImportSource, sessionGeneration: Int,
		imported: ImportedEnvFile
	) throws {
		guard let baseline = project.environments[environment] else {
			throw EnvFileImportError.targetUnavailable
		}
		let foldedKeys = Set(baseline.keys.map { $0.lowercased() })
		for key in imported.secrets.keys where baseline[key] == nil {
			guard !foldedKeys.contains(key.lowercased()) else {
				throw EnvFileImportError.caseInsensitiveCollisionWithExisting
			}
		}
		self.id = id
		self.projectId = project.id
		self.projectName = project.name
		self.projectPath = project.path
		self.environment = environment
		self.source = source
		self.sessionGeneration = sessionGeneration
		self.imported = imported
		self.baseline = baseline
		self.rows = imported.secrets.keys.sorted().map { key in
			let change: Change =
				baseline[key] == nil ? .added : baseline[key] == imported.secrets[key] ? .unchanged : .changed
			return Row(key: key, change: change)
		}
		self.added = rows.filter { $0.change == .added }
		self.changed = rows.filter { $0.change == .changed }
		self.unchanged = rows.filter { $0.change == .unchanged }
		self.addedKeys = Set(added.lazy.map(\.key))
		self.changedKeys = Set(changed.lazy.map(\.key))
	}

	/// What an import replacing `replacing` and leaving out `skipping` does to each key.
	struct Outcome: Equatable {
		let added: Int
		let replaced: Int
		let kept: Int
		/// Unchanged keys, and new keys left out.
		let skipped: Int

		/// The keys whose values the import writes.
		var changes: Int { added + replaced }

		var summary: String { "\(added) added · \(replaced) replaced · \(kept) kept · \(skipped) skipped" }
	}

	func outcome(replacing: Set<String> = [], skipping: Set<String> = []) -> Outcome {
		let replaced = changedKeys.intersection(replacing).count
		let leftOut = addedKeys.intersection(skipping).count
		return Outcome(
			added: addedCount - leftOut, replaced: replaced, kept: changedKeys.count - replaced, skipped: unchangedCount + leftOut)
	}
}

/// What an import did to an environment, which undoing it reverses.
struct EnvImportReceipt: Sendable, Equatable {
	let projectId: String
	let environment: String
	let before: [String: String]
	let after: [String: String]

	var changed: Bool { before != after }
}
