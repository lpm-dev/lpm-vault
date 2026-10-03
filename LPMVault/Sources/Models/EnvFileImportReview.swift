import Foundation

struct EnvFileImportReview: Identifiable, Sendable {
	enum Change: String, Sendable {
		case added = "Add"
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
	let sourceURL: URL
	let sessionGeneration: Int
	let imported: ImportedEnvFile
	let baseline: [String: String]
	let rows: [Row]
	let changedKeys: Set<String>
	let addedCount: Int
	let unchangedCount: Int

	init(
		id: UUID, project: VaultProject, environment: String, sourceURL: URL, sessionGeneration: Int,
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
		self.sourceURL = sourceURL
		self.sessionGeneration = sessionGeneration
		self.imported = imported
		self.baseline = baseline
		self.rows = imported.secrets.keys.sorted().map { key in
			let change: Change =
				baseline[key] == nil ? .added : baseline[key] == imported.secrets[key] ? .unchanged : .changed
			return Row(key: key, change: change)
		}
		self.changedKeys = Set(rows.lazy.filter { $0.change == .changed }.map(\.key))
		self.addedCount = rows.lazy.filter { $0.change == .added }.count
		self.unchangedCount = rows.lazy.filter { $0.change == .unchanged }.count
	}

	func summary(replacing keys: Set<String>) -> String {
		let replacements = changedKeys.intersection(keys).count
		return
			"\(addedCount) added · \(replacements) replaced · \(changedKeys.count - replacements) kept · \(unchangedCount) unchanged"
	}
}
