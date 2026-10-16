import Foundation

/// What quitting would lose: each project's unsaved key edits, its unsaved
/// schema draft, and what sheets still open hold.
struct VaultUnsavedWork: Equatable {
	/// A key's draft and how many unsaved changes it holds.
	struct KeyEdit: Hashable {
		let id: VaultKeyDraft.ID
		let edits: Int

		var key: String { id.key }
	}

	struct KeyEdits: Equatable {
		let projectID: String
		let projectName: String
		/// The drafts that can be saved, by key.
		let saveable: [KeyEdit]
		/// Drafts that can't be saved without a review, because the key, its
		/// project or one of its values changed elsewhere.
		let needsReview: [KeyEdit]
	}

	struct SchemaDraft: Equatable {
		let projectID: String
		let projectName: String
		let changeCount: Int
	}

	/// A project's unsaved Project Settings: a new name, a new icon, or both.
	struct ProjectSettings: Equatable {
		let projectID: String
		let projectName: String
		/// The name typed over the saved one, if it was changed.
		let newName: String?
		let changesIcon: Bool
	}

	/// A sheet still open with something typed into it, which only it can save.
	struct OpenSheet: Equatable, Identifiable {
		let id: UUID
		/// The project it adds to; nil for a sheet of the app's own, such as connecting a platform.
		let projectID: String?
		/// The project's name, or where the sheet is, such as "Platforms".
		let projectName: String
		/// What the sheet does, such as "Add variable".
		let title: String
		/// What's typed into it, such as the new key's name.
		let detail: String
	}

	var keyEdits: [KeyEdits] = []
	var schemaDrafts: [SchemaDraft] = []
	var projectSettings: [ProjectSettings] = []
	var openSheets: [OpenSheet] = []
	/// The projects with unsaved work, the selected one first, then in the sidebar's order.
	var projectOrder: [String] = []

	var isEmpty: Bool { keyEdits.isEmpty && schemaDrafts.isEmpty && projectSettings.isEmpty && openSheets.isEmpty }
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
		func ranked(_ projectID: String, _ name: String) -> (Int, String) { (rank[projectID] ?? .max, name) }
		var drafts: [String: [VaultKeyDraft]] = [:]
		for draft in keyDrafts.drafts.values where draft.isDirty || draft.hasConflict {
			drafts[draft.id.projectID, default: []].append(draft)
		}
		var work = VaultUnsavedWork()
		work.keyEdits = drafts.map { projectID, drafts in
			let sorted = drafts.sorted { $0.key < $1.key }
			let exists = names[projectID] != nil
			func edit(_ draft: VaultKeyDraft) -> VaultUnsavedWork.KeyEdit { .init(id: draft.id, edits: max(1, draft.unsavedChangeCount)) }
			return VaultUnsavedWork.KeyEdits(
				projectID: projectID,
				projectName: names[projectID] ?? sorted.first?.projectName ?? projectID,
				saveable: sorted.filter { $0.canSave && exists }.map(edit),
				needsReview: sorted.filter { !$0.canSave || !exists }.map(edit)
			)
		}
		.sorted { ranked($0.projectID, $0.projectName) < ranked($1.projectID, $1.projectName) }
		work.schemaDrafts = projectsWithSchemaDrafts.compactMap { projectID in
			guard let name = names[projectID], let draft = schemaDraft(for: projectID), !draft.isEmpty else { return nil }
			return VaultUnsavedWork.SchemaDraft(projectID: projectID, projectName: name, changeCount: draft.changeCount)
		}
		.sorted { ranked($0.projectID, $0.projectName) < ranked($1.projectID, $1.projectName) }
		work.projectSettings = projectSettingsDrafts.compactMap { projectID, draft in
			guard let name = names[projectID], !draft.isEmpty else { return nil }
			return VaultUnsavedWork.ProjectSettings(projectID: projectID, projectName: name, newName: draft.name?.text, changesIcon: draft.icon != nil)
		}
		.sorted { ranked($0.projectID, $0.projectName) < ranked($1.projectID, $1.projectName) }
		work.openSheets = openSheetWork.values
			.map { sheet in
				VaultUnsavedWork.OpenSheet(id: sheet.id, projectID: sheet.projectID,
					projectName: sheet.projectID.flatMap { names[$0] } ?? sheet.projectName, title: sheet.title, detail: sheet.detail)
			}
			.sorted {
				// A sheet of the app's own comes after every project's.
				let first = $0.projectID.map { ranked($0, names[$0] ?? $0) } ?? (.max, $0.projectName)
				let second = $1.projectID.map { ranked($0, names[$0] ?? $0) } ?? (.max, $1.projectName)
				return first != second ? first < second : $0.title < $1.title
			}
		var seen = Set<String>()
		for projectID in work.keyEdits.map(\.projectID) + work.schemaDrafts.map(\.projectID) + work.projectSettings.map(\.projectID)
			+ work.openSheets.compactMap(\.projectID)
		{
			seen.insert(projectID)
		}
		work.projectOrder = seen.sorted { ranked($0, names[$0] ?? $0) < ranked($1, names[$1] ?? $1) }
		return work
	}

	/// Whether quitting has anything to wait for or ask about.
	var hasWorkQuittingWouldLose: Bool {
		isWriting || !unsavedWork().isEmpty
	}
}
