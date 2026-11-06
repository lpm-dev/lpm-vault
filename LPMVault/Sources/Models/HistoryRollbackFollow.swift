import Foundation

/// What a rollback, applied as switched, does that publish destinations
/// follow: environments it deletes or gives back an earlier name, and keys
/// it gives back an earlier name.
struct HistoryRollbackFollow: Equatable, Sendable {
	struct KeyRename: Equatable, Sendable {
		/// The environment's name after the rollback.
		let environment: String
		let from: String
		let to: String
	}

	var deletedEnvironments: Set<String> = []
	/// Each name now and the name it goes back to. They change together, so
	/// names that swap stay right.
	var renamedEnvironments: [String: String] = [:]
	var renamedKeys: [KeyRename] = []

	var isEmpty: Bool { deletedEnvironments.isEmpty && renamedEnvironments.isEmpty && renamedKeys.isEmpty }

	init(deletedEnvironments: Set<String> = [], renamedEnvironments: [String: String] = [:], renamedKeys: [KeyRename] = []) {
		self.deletedEnvironments = deletedEnvironments
		self.renamedEnvironments = renamedEnvironments
		self.renamedKeys = renamedKeys
	}

	init(plan: HistoryEngine.Plan, skipped: Set<HistoryRollbackSkip>, keepEmpty: Set<Int>) {
		for (index, environment) in plan.environments.enumerated() {
			let applies = { (row: Int) in !skipped.contains(HistoryRollbackSkip(environment: index, row: row)) }
			if environment.offersDeletion, let current = environment.current, !keepEmpty.contains(index),
				environment.rows.indices.allSatisfy(applies)
			{
				deletedEnvironments.insert(current)
				continue
			}
			if environment.renames, let current = environment.current, let target = environment.target {
				renamedEnvironments[current] = target
			}
			guard let name = environment.target ?? environment.current else { continue }
			let rowsByKey = Dictionary(environment.rows.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { first, _ in first })
			// A key renamed once since the point is a pair of linked rows: its
			// name now leaves, and its earlier name comes back.
			for (rowIndex, row) in environment.rows.enumerated()
			where row.change == "added" && row.linked.count == 1 && applies(rowIndex) {
				guard let leaving = rowsByKey[row.linked[0]], applies(leaving),
					environment.rows[leaving].change == "removed", environment.rows[leaving].linked == [row.key]
				else { continue }
				renamedKeys.append(KeyRename(environment: name, from: environment.rows[leaving].key, to: row.key))
			}
		}
	}

	/// Whether `environments` shows the rollback applied.
	func isApplied(to environments: [String: [String: String]]) -> Bool {
		let freed = Set(renamedEnvironments.keys).subtracting(renamedEnvironments.values)
		return deletedEnvironments.allSatisfy { environments[$0] == nil }
			&& freed.allSatisfy { environments[$0] == nil }
			&& renamedEnvironments.values.allSatisfy { environments[$0] != nil }
			&& renamedKeys.allSatisfy { rename in
				environments[rename.environment].map { $0[rename.from] == nil && $0[rename.to] != nil } ?? false
			}
	}
}
