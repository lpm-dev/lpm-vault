import Foundation
import Observation

/// Unsaved edits to one key of a project: its name and its value in each
/// environment.
///
/// The draft follows changes made elsewhere. Values the person has not edited
/// update to the latest saved value. An edited value that changed elsewhere
/// becomes a conflict, and an edited value whose environment or key disappeared
/// is kept so it can be added again, copied, or discarded.
struct VaultKeyDraft: Equatable, Sendable {
	struct ID: Hashable, Sendable {
		let projectID: String
		let key: String
	}

	let id: ID
	let projectName: String
	var name: String
	/// Value drafts for every environment that has the key, plus additions.
	private(set) var values: [String: VaultSecretEditDraft]
	/// Environments the draft adds the key to.
	private(set) var additions: Set<String> = []
	/// Edited environments whose saved value disappeared elsewhere.
	private(set) var orphanedEnvironments: Set<String> = []
	/// The project or every copy of the key disappeared while the draft had
	/// value edits, which are kept so they can be copied.
	private(set) var isOrphaned = false
	private(set) var isSaveInFlight = false
	/// The key's description in `lpm.json`, once the person edits it.
	private(set) var keyDescription: VaultSecretEditDraft?

	init(projectID: String, projectName: String, key: String, environments: [String: [String: String]]) {
		id = ID(projectID: projectID, key: key)
		self.projectName = projectName
		name = key
		values = environments.compactMapValues { $0[key].map(VaultSecretEditDraft.init(value:)) }
	}

	var key: String { id.key }
	var isRenamed: Bool { name != key }

	/// Environments whose value the draft changes, adds, or keeps after it disappeared.
	var changedEnvironments: [String] {
		values.compactMap { environment, draft in
			draft.isDirty || additions.contains(environment) ? environment : nil
		}
		.sorted()
	}

	var unsavedChangeCount: Int {
		(isRenamed ? 1 : 0) + changedEnvironments.count + (keyDescription?.isDirty == true ? 1 : 0)
	}
	var isDirty: Bool { unsavedChangeCount > 0 }
	var hasConflict: Bool {
		isOrphaned || !orphanedEnvironments.isEmpty || values.values.contains(where: \.hasExternalConflict)
			|| keyDescription?.hasExternalConflict == true
	}
	/// The description to save, when the person changed it.
	var keyDescriptionChange: String? {
		guard let keyDescription, keyDescription.isDirty else { return nil }
		return keyDescription.draft
	}
	var canSave: Bool { isDirty && !hasConflict && !isSaveInFlight }

	func value(in environment: String) -> String? { values[environment]?.draft }

	mutating func setValue(_ value: String, in environment: String) {
		guard !isSaveInFlight else { return }
		if values[environment] == nil {
			values[environment] = VaultSecretEditDraft(value: "")
			additions.insert(environment)
		}
		values[environment]?.draft = value
	}

	/// Gives every listed environment the same value, adding the key where it is missing.
	mutating func setValue(_ value: String, in environments: [String]) {
		for environment in environments { setValue(value, in: environment) }
	}

	/// Starts adding the key to an environment that does not have it.
	mutating func add(_ environment: String) {
		guard !isSaveInFlight, values[environment] == nil else { return }
		values[environment] = VaultSecretEditDraft(value: "")
		additions.insert(environment)
	}

	/// Drops this environment's edit: an addition is removed, a changed value
	/// returns to its latest saved value, and a kept orphaned value is discarded.
	mutating func revert(_ environment: String) {
		guard !isSaveInFlight else { return }
		if additions.contains(environment) || orphanedEnvironments.contains(environment) {
			values.removeValue(forKey: environment)
			additions.remove(environment)
			orphanedEnvironments.remove(environment)
		} else {
			values[environment]?.revert()
		}
	}

	/// Resolves a conflict in favor of the person's edit, which then replaces the
	/// value saved elsewhere.
	mutating func keepEdit(in environment: String) {
		guard !isSaveInFlight else { return }
		values[environment]?.keepDraft()
	}

	/// Edits the description, starting from `saved`, the one in `lpm.json`.
	mutating func setKeyDescription(_ text: String, saved: String) {
		guard !isSaveInFlight else { return }
		if keyDescription == nil { keyDescription = VaultSecretEditDraft(value: saved) }
		keyDescription?.draft = text
	}

	/// Drops the description edit, so the one in `lpm.json` shows again.
	mutating func revertKeyDescription() {
		guard !isSaveInFlight else { return }
		keyDescription = nil
	}

	/// Resolves a description conflict in favor of the person's edit.
	mutating func keepKeyDescription() {
		guard !isSaveInFlight else { return }
		keyDescription?.keepDraft()
	}

	/// Applies the description now saved in `lpm.json`: an untouched one follows
	/// it, and an edited one that changed there becomes a conflict.
	mutating func receiveKeyDescription(_ saved: String) {
		guard !isSaveInFlight, !isOrphaned, keyDescription != nil else { return }
		keyDescription?.receiveExternalValue(saved)
		if keyDescription?.isDirty == false, keyDescription?.hasExternalConflict == false { keyDescription = nil }
	}

	/// Keeps an orphaned value by adding the key to that environment again.
	mutating func readd(_ environment: String, environments: [String: [String: String]]) {
		guard !isSaveInFlight, orphanedEnvironments.contains(environment), environments[environment] != nil,
			let kept = values[environment]?.draft
		else { return }
		orphanedEnvironments.remove(environment)
		values[environment] = VaultSecretEditDraft(value: "")
		values[environment]?.draft = kept
		additions.insert(environment)
	}

	mutating func revert() {
		guard !isSaveInFlight else { return }
		name = key
		keyDescription = nil
		for environment in additions.union(orphanedEnvironments) {
			values.removeValue(forKey: environment)
		}
		additions.removeAll()
		orphanedEnvironments.removeAll()
		for environment in values.keys { values[environment]?.revert() }
	}

	/// Applies the latest saved state of the project, or nil when the project is gone.
	mutating func receive(_ environments: [String: [String: String]]?) {
		guard !isSaveInFlight, !isOrphaned else { return }
		guard let environments else {
			abandon()
			return
		}
		for (environment, draft) in values {
			if let latest = environments[environment]?[key] {
				// An addition keeps its empty baseline, so a saved value that appeared
				// elsewhere conflicts with the person's value instead of replacing it.
				additions.remove(environment)
				orphanedEnvironments.remove(environment)
				values[environment]?.receiveExternalValue(latest)
			} else if additions.contains(environment) {
				if environments[environment] == nil {
					additions.remove(environment)
					if draft.draft.isEmpty {
						values.removeValue(forKey: environment)
					} else {
						orphanedEnvironments.insert(environment)
					}
				}
			} else if !orphanedEnvironments.contains(environment) {
				if draft.isDirty {
					orphanedEnvironments.insert(environment)
				} else {
					values.removeValue(forKey: environment)
				}
			}
		}
		for (environment, secrets) in environments where values[environment] == nil {
			if let latest = secrets[key] { values[environment] = VaultSecretEditDraft(value: latest) }
		}
		if !environments.values.contains(where: { $0[key] != nil }) {
			abandon()
		}
	}

	/// Ends a draft whose key is gone: edited values are kept as an orphan, and a
	/// draft with nothing else to keep, such as a rename or a description, becomes clean.
	private mutating func abandon() {
		if changedEnvironments.isEmpty {
			name = key
			keyDescription = nil
		} else {
			isOrphaned = true
		}
	}

	/// The save this draft describes, from the latest values it has received.
	func keyEdit() -> VaultKeyEdit {
		var baseline: [String: String?] = [:]
		for (environment, draft) in values where !additions.contains(environment) && !orphanedEnvironments.contains(environment) {
			baseline[environment] = draft.baseline
		}
		var changed: [String: String] = [:]
		for environment in changedEnvironments { changed[environment] = values[environment]?.draft }
		return VaultKeyEdit(key: key, newKey: name, baseline: baseline, values: changed)
	}

	mutating func beginSave() -> VaultKeyEdit? {
		guard canSave else { return nil }
		isSaveInFlight = true
		return keyEdit()
	}

	mutating func finishSave() {
		isSaveInFlight = false
	}
}

/// Unsaved key drafts of the unlocked session, by project and key. Drafts stay
/// while the person moves between keys, environments, and projects, and end
/// when saved, reverted, locked, or when the account changes.
@Observable
@MainActor
final class VaultKeyDrafts {
	private(set) var drafts: [VaultKeyDraft.ID: VaultKeyDraft] = [:]
	/// Keys with unsaved edits, by project. Unlike `drafts`, this changes only when
	/// a key gains or loses edits, so views that show it skip keystroke updates.
	private(set) var editedKeysByProject: [String: Set<String>] = [:]
	/// Drafts that can no longer be saved because their project or key is gone.
	private(set) var orphanIDs: [VaultKeyDraft.ID] = []

	func draft(_ id: VaultKeyDraft.ID) -> VaultKeyDraft? { drafts[id] }

	func editedKeys(in projectID: String) -> Set<String> {
		editedKeysByProject[projectID] ?? []
	}

	/// Changes a key's draft, starting one from the project when there is none.
	/// A draft that no longer differs from the saved state is dropped.
	func edit(_ project: VaultProject, key: String, _ change: (inout VaultKeyDraft) -> Void) {
		let id = VaultKeyDraft.ID(projectID: project.id, key: key)
		var draft = drafts[id] ?? VaultKeyDraft(projectID: project.id, projectName: project.name, key: key, environments: project.environments)
		change(&draft)
		store(draft)
	}

	/// Drops the unsaved edits that deleting `key` from `environment` replaces:
	/// that environment's edit, or the whole draft when it held the last copy.
	func discardEdits(deleting key: String, from environment: String, in project: VaultProject) {
		let id = VaultKeyDraft.ID(projectID: project.id, key: key)
		guard drafts[id] != nil else { return }
		if project.environments.contains(where: { $0.key != environment && $0.value[key] != nil }) {
			edit(project, key: key) { $0.revert(environment) }
		} else {
			discard(id)
		}
	}

	func discard(_ id: VaultKeyDraft.ID) {
		drafts.removeValue(forKey: id)
		publishSummaries()
	}

	func discardAll() {
		guard !drafts.isEmpty else { return }
		drafts.removeAll()
		publishSummaries()
	}

	func beginSave(_ id: VaultKeyDraft.ID) -> VaultKeyEdit? {
		guard var draft = drafts[id], let edit = draft.beginSave() else { return nil }
		drafts[id] = draft
		return edit
	}

	/// Ends a save. A successful save leaves nothing unsaved, so the draft ends; a
	/// failed one returns to editing against the latest saved state.
	func finishSave(_ id: VaultKeyDraft.ID, succeeded: Bool, projects: [VaultProject]) {
		guard var draft = drafts[id] else { return }
		if succeeded {
			discard(id)
			return
		}
		draft.finishSave()
		receive(into: &draft, from: projects)
		store(draft)
	}

	/// Applies the descriptions now saved in a project's `lpm.json`.
	func receiveKeyDescriptions(_ descriptions: [String: String], in projectID: String) {
		for var draft in drafts.values where draft.id.projectID == projectID && draft.keyDescription != nil {
			draft.receiveKeyDescription(descriptions[draft.key] ?? "")
			store(draft)
		}
	}

	/// Applies the latest saved projects. Projects whose values are not loaded
	/// leave their drafts as they are.
	func receive(_ projects: [VaultProject]) {
		guard !drafts.isEmpty else { return }
		for var draft in drafts.values {
			receive(into: &draft, from: projects)
			store(draft)
		}
	}

	private func receive(into draft: inout VaultKeyDraft, from projects: [VaultProject]) {
		if let project = projects.first(where: { $0.id == draft.id.projectID }) {
			if project.hasLoadedEnvironments { draft.receive(project.environments) }
		} else {
			draft.receive(nil)
		}
	}

	private func store(_ draft: VaultKeyDraft) {
		if draft.isDirty || draft.isSaveInFlight || draft.isOrphaned || draft.hasConflict {
			drafts[draft.id] = draft
		} else {
			drafts.removeValue(forKey: draft.id)
		}
		publishSummaries()
	}

	private func publishSummaries() {
		var edited: [String: Set<String>] = [:]
		var orphans: [VaultKeyDraft.ID] = []
		for draft in drafts.values {
			if draft.isOrphaned {
				orphans.append(draft.id)
			} else if draft.isDirty {
				edited[draft.id.projectID, default: []].insert(draft.key)
			}
		}
		orphans.sort { ($0.projectID, $0.key) < ($1.projectID, $1.key) }
		if edited != editedKeysByProject { editedKeysByProject = edited }
		if orphans != orphanIDs { orphanIDs = orphans }
	}
}
