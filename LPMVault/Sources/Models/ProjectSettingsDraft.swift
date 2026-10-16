import Foundation

/// Unsaved Project Settings edits of a project's name and icon.
struct ProjectSettingsDraft: Equatable, Sendable {
	var name: String
	var icon: ProjectIconChoice
}

extension VaultStore {
	/// The name and icon Project Settings shows: the unsaved ones, or else the saved ones.
	func projectSettings(for project: VaultProject) -> ProjectSettingsDraft {
		projectSettingsDrafts[project.id] ?? savedProjectSettings(for: project)
	}

	func savedProjectSettings(for project: VaultProject) -> ProjectSettingsDraft {
		ProjectSettingsDraft(name: project.name, icon: projectIcons.choices[project.id] ?? .automatic)
	}

	/// Changes a project's unsaved settings; a draft that matches what's saved ends.
	func editProjectSettings(of project: VaultProject, _ change: (inout ProjectSettingsDraft) -> Void) {
		guard isUnlocked, !savingProjectSettings.contains(project.id) else { return }
		let saved = savedProjectSettings(for: project)
		var draft = projectSettingsDrafts[project.id] ?? saved
		let previousIcon = draft.icon
		change(&draft)
		if draft.icon != previousIcon, previousIcon != saved.icon { projectIcons.discardPreview(of: previousIcon) }
		projectSettingsDrafts[project.id] = draft == saved ? nil : draft
		projectSettingsErrors[project.id] = nil
		recordUserActivity()
	}

	func revertProjectSettings(of projectID: String) {
		guard !savingProjectSettings.contains(projectID) else { return }
		discardProjectSettingsDraft(projectID)
		projectSettingsErrors[projectID] = nil
	}

	/// Saves a project's unsaved name and icon. The name is saved first, as
	/// the LPM CLI shares it; when it can't be, nothing is saved and the edits stay.
	func saveProjectSettings(of projectID: String) async {
		guard isUnlocked, !savingProjectSettings.contains(projectID), let draft = projectSettingsDrafts[projectID],
			let project = projects.first(where: { $0.id == projectID })
		else { return }
		guard let name = VaultProjectRenamePolicy.normalizedName(draft.name) else {
			projectSettingsErrors[projectID] = "Enter a name for the project."
			return
		}
		savingProjectSettings.insert(projectID)
		defer { savingProjectSettings.remove(projectID) }
		projectSettingsErrors[projectID] = nil
		if name != project.name {
			let outcome = await renameProject(project, to: name)
			guard isUnlocked, projectSettingsDrafts[projectID] == draft else { return }
			switch outcome {
			case .saved: break
			case .changed:
				projectSettingsErrors[projectID] = "This env project changed in another LPM process. Review it and save again."
				return
			case .unavailable:
				projectSettingsErrors[projectID] = "The env project changed before its name was saved."
				return
			case .failed(let message):
				projectSettingsErrors[projectID] = message
				return
			}
		}
		if draft.icon != (projectIcons.choices[projectID] ?? .automatic) { projectIcons.save(draft.icon, for: projectID) }
		projectSettingsDrafts[projectID] = nil
	}

	/// Ends every unsaved Project Settings edit, as locking and switching accounts do.
	func discardAllProjectSettings() {
		for projectID in Array(projectSettingsDrafts.keys) { discardProjectSettingsDraft(projectID) }
		projectSettingsErrors.removeAll()
	}

	/// Ends the drafts of projects that are gone.
	func pruneProjectSettingsDrafts(keeping projectIDs: Set<String>) {
		for projectID in projectSettingsDrafts.keys where !projectIDs.contains(projectID) { discardProjectSettingsDraft(projectID) }
		projectSettingsErrors = projectSettingsErrors.filter { projectIDs.contains($0.key) }
	}

	private func discardProjectSettingsDraft(_ projectID: String) {
		guard let draft = projectSettingsDrafts.removeValue(forKey: projectID) else { return }
		if draft.icon != (projectIcons.choices[projectID] ?? .automatic) { projectIcons.discardPreview(of: draft.icon) }
	}
}
