import Foundation

/// What quitting would lose: each project's unsaved key edits and its
/// unsaved schema draft.
struct VaultUnsavedWork: Equatable {
	struct KeyEdits: Equatable {
		let projectID: String
		let projectName: String
		/// Every edited key, in order.
		let keys: [String]
		/// The drafts that can be saved.
		let saveable: [VaultKeyDraft.ID]
		/// Keys whose edits can't be saved without a review, because the key, its
		/// project or one of its values changed elsewhere.
		let needsReview: [String]
		let editCount: Int
	}

	struct SchemaDraft: Equatable {
		let projectID: String
		let projectName: String
		let changeCount: Int
	}

	var keyEdits: [KeyEdits] = []
	var schemaDrafts: [SchemaDraft] = []

	var isEmpty: Bool { keyEdits.isEmpty && schemaDrafts.isEmpty }
}

extension VaultStore {
	/// The unsaved work of the session, the selected project's first, then in the sidebar's order.
	func unsavedWork() -> VaultUnsavedWork {
		guard isUnlocked else { return VaultUnsavedWork() }
		var order = projects.map(\.id)
		if let selectedProjectId, let index = order.firstIndex(of: selectedProjectId) {
			order.remove(at: index)
			order.insert(selectedProjectId, at: 0)
		}
		let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
		let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
		var drafts: [String: [VaultKeyDraft]] = [:]
		for draft in keyDrafts.drafts.values where draft.isDirty || draft.hasConflict {
			drafts[draft.id.projectID, default: []].append(draft)
		}
		var work = VaultUnsavedWork()
		work.keyEdits = drafts.map { projectID, drafts in
			let sorted = drafts.sorted { $0.key < $1.key }
			return VaultUnsavedWork.KeyEdits(
				projectID: projectID,
				projectName: names[projectID] ?? sorted.first?.projectName ?? projectID,
				keys: sorted.map(\.key),
				saveable: sorted.filter { $0.canSave && names[projectID] != nil }.map(\.id),
				needsReview: sorted.filter { !$0.canSave || names[projectID] == nil }.map(\.key),
				editCount: sorted.reduce(0) { $0 + max(1, $1.unsavedChangeCount) }
			)
		}
		.sorted { (rank[$0.projectID] ?? .max, $0.projectName) < (rank[$1.projectID] ?? .max, $1.projectName) }
		work.schemaDrafts = projectsWithSchemaDrafts.compactMap { projectID in
			guard let name = names[projectID], let draft = schemaDraft(for: projectID), !draft.isEmpty else { return nil }
			return VaultUnsavedWork.SchemaDraft(projectID: projectID, projectName: name, changeCount: draft.changeCount)
		}
		.sorted { (rank[$0.projectID] ?? .max, $0.projectName) < (rank[$1.projectID] ?? .max, $1.projectName) }
		return work
	}
}
