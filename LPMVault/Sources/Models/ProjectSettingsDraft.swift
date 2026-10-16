import Foundation

/// Unsaved Project Settings edits. Only what was changed is kept, so a
/// name the LPM CLI changes meanwhile shows through when it wasn't edited.
struct ProjectSettingsDraft: Equatable, Sendable {
	/// A name typed over the saved one, which renaming expects to still be there.
	struct NameEdit: Equatable, Sendable {
		var text: String
		let base: String
	}

	var name: NameEdit?
	var icon: ProjectIconChoice?

	var isEmpty: Bool { name == nil && icon == nil }
}

/// What Project Settings shows and edits: unsaved edits over what's saved.
struct ProjectSettingsValues: Equatable, Sendable {
	var name: String
	var icon: ProjectIconChoice
}

extension VaultStore {
	/// The name and icon Project Settings shows.
	func projectSettings(for project: VaultProject) -> ProjectSettingsValues {
		let saved = savedProjectSettings(for: project)
		guard let draft = projectSettingsDrafts[project.id] else { return saved }
		return ProjectSettingsValues(name: draft.name?.text ?? saved.name, icon: draft.icon ?? saved.icon)
	}

	func savedProjectSettings(for project: VaultProject) -> ProjectSettingsValues {
		ProjectSettingsValues(name: project.name, icon: projectIcons.choice(for: project.id) ?? .automatic)
	}

	/// Changes a project's unsaved settings; a draft that matches what's saved
	/// ends. False when nothing could change, as while the settings save.
	@discardableResult
	func editProjectSettings(of project: VaultProject, _ change: (inout ProjectSettingsValues) -> Void) -> Bool {
		guard isUnlocked, !savingProjectSettings.contains(project.id) else { return false }
		let saved = savedProjectSettings(for: project)
		let before = projectSettings(for: project)
		var values = before
		change(&values)
		var draft = projectSettingsDrafts[project.id] ?? ProjectSettingsDraft()
		if values.name != before.name {
			draft.name = values.name == saved.name ? nil : .init(text: values.name, base: draft.name?.base ?? saved.name)
		}
		if values.icon != before.icon {
			if before.icon != saved.icon { projectIcons.discardPreview(of: before.icon, for: project.id) }
			draft.icon = values.icon == saved.icon ? nil : values.icon
		}
		projectSettingsDrafts[project.id] = draft.isEmpty ? nil : draft
		projectSettingsErrors[project.id] = nil
		recordUserActivity()
		return true
	}

	func revertProjectSettings(of projectID: String) {
		guard !savingProjectSettings.contains(projectID) else { return }
		discardProjectSettingsDraft(projectID)
		projectSettingsErrors[projectID] = nil
	}

	/// Saves a project's unsaved name and icon. The name is saved first, as
	/// the LPM CLI shares it; when it can't be, nothing is saved and the edits
	/// stay. A save that outlasts an account switch still finishes, and its
	/// edits end once it does.
	func saveProjectSettings(of projectID: String) async {
		guard isUnlocked, !savingProjectSettings.contains(projectID), let draft = projectSettingsDrafts[projectID],
			let project = projects.first(where: { $0.id == projectID })
		else { return }
		var name: String?
		if let edit = draft.name {
			guard let normalized = VaultProjectRenamePolicy.normalizedName(edit.text) else {
				projectSettingsErrors[projectID] = "Enter a name for the project."
				return
			}
			name = normalized
		}
		let account = selectedAccount
		savingProjectSettings.insert(projectID)
		defer {
			savingProjectSettings.remove(projectID)
			if !isUnlocked || selectedAccount != account { discardProjectSettingsDraft(projectID) }
		}
		projectSettingsErrors[projectID] = nil
		if let name, let edit = draft.name, name != project.name {
			let outcome = await renameProject(project, from: edit.base, to: name)
			guard isUnlocked else { return }
			switch outcome {
			case .saved:
				projectSettingsDrafts[projectID]?.name = nil
			case .changed:
				projectSettingsErrors[projectID] = "This env project's name changed elsewhere since you edited it. Review it and save again."
				return
			case .unavailable:
				projectSettingsErrors[projectID] = "The env project changed before its name was saved."
				return
			case .failed(let message):
				projectSettingsErrors[projectID] = message
				return
			}
		} else {
			projectSettingsDrafts[projectID]?.name = nil
		}
		if let icon = draft.icon {
			guard projectIcons.save(icon, for: projectID) else {
				projectSettingsErrors[projectID] = "This icon can't be saved. Choose another one."
				return
			}
		}
		projectSettingsDrafts[projectID] = nil
	}

	/// Ends every unsaved Project Settings edit, as locking and switching
	/// accounts do; one that's saving ends once its save does.
	func discardAllProjectSettings() {
		for projectID in Array(projectSettingsDrafts.keys) where !savingProjectSettings.contains(projectID) {
			discardProjectSettingsDraft(projectID)
		}
		projectSettingsErrors = projectSettingsErrors.filter { savingProjectSettings.contains($0.key) }
	}

	/// Ends the drafts of projects that are gone.
	func pruneProjectSettingsDrafts(keeping projectIDs: Set<String>) {
		for projectID in projectSettingsDrafts.keys where !projectIDs.contains(projectID) { discardProjectSettingsDraft(projectID) }
		projectSettingsErrors = projectSettingsErrors.filter { projectIDs.contains($0.key) }
	}

	private func discardProjectSettingsDraft(_ projectID: String) {
		guard let draft = projectSettingsDrafts.removeValue(forKey: projectID) else { return }
		if let icon = draft.icon { projectIcons.discardPreview(of: icon, for: projectID) }
	}
}
