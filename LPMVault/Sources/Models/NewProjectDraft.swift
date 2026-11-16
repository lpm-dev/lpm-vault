import Foundation
import Observation

/// What a project created in LPM Vault starts with besides its name.
struct NewProjectSetup: Equatable, Sendable {
	/// The project's folder, whose lpm.json is linked to it once it exists;
	/// empty for none.
	var folder = ""
	var icon: ProjectIconChoice = .automatic
	/// What Settings gives every new project when nil.
	var defaults: NewProjectDefaults?
}

/// The New Project sheet's choices for a project before it exists. CLI
/// approval and local history start as Settings gives every new project.
@Observable
@MainActor
final class NewProjectDraft {
	/// The ID the project is created under, chosen up front so that a
	/// creation tried again finds the one an earlier try saved.
	let vaultId = UUID().uuidString.lowercased()
	var name = ""
	var asksBeforeCLIReads: Bool
	var keepsHistory: Bool
	private(set) var icon: ProjectIconChoice = .automatic
	private(set) var folder: ProjectFolderChoice?
	/// Why the folder last chosen couldn't be taken.
	private(set) var folderError: ProjectCLILinkError?
	private(set) var isCheckingFolder = false
	/// What the chosen folder gives a project whose icon is automatic.
	private(set) var automaticIcon: ProjectIconResolution?

	@ObservationIgnored private let store: VaultStore
	/// The image file the icon was taken from, so a new folder can take it in again.
	@ObservationIgnored private var iconFile: URL?
	@ObservationIgnored private var folderGeneration = 0
	@ObservationIgnored private var iconGeneration = 0
	@ObservationIgnored private var isDiscarded = false

	init(store: VaultStore) {
		self.store = store
		asksBeforeCLIReads = store.settings.newProjectsAskBeforeCLIReads
		keepsHistory = store.settings.newProjectsKeepHistory
	}

	var normalizedName: String? { EnvValidation.normalizedProjectName(name) }

	/// Whether the chosen folder's lpm.json keeps it from being the project's.
	var folderBlocksCreation: Bool { folder?.isTaken ?? false }

	var isImportingIcon: Bool { store.projectIcons.isImporting(vaultId) }

	var canCreate: Bool { normalizedName != nil && !isCheckingFolder && !folderBlocksCreation && !isImportingIcon }

	var setup: NewProjectSetup {
		NewProjectSetup(folder: folder?.path ?? "", icon: icon,
			defaults: NewProjectDefaults(asksBeforeCLIReads: asksBeforeCLIReads, keepsHistory: keepsHistory))
	}

	/// The icon as the project will show it: the one chosen, or the folder's
	/// while it's automatic or its image can't be drawn.
	var appearance: ProjectIconAppearance {
		let automatic = automaticIcon?.automatic.map { ProjectIconAppearance.image($0.image) } ?? .folder
		guard !icon.isAutomatic else { return automatic }
		let chosen = store.projectIcons.appearance(of: icon, for: vaultId)
		return chosen == .folder ? automatic : chosen
	}

	/// Why the last image file chosen couldn't be taken in.
	var iconFailure: ProjectIconStore.ImportFailure? { store.projectIcons.importFailure(for: vaultId) }

	// MARK: - Icon

	func useIcon(_ choice: ProjectIconChoice) {
		iconGeneration += 1
		replaceIcon(with: choice, file: nil)
	}

	/// Takes in an image file as the icon: one in the chosen folder is
	/// followed there, any other is copied into LPM Vault's folder.
	func chooseIconFile(_ url: URL) async {
		iconGeneration += 1
		await importIcon(url, generation: iconGeneration)
	}

	private func importIcon(_ url: URL, generation: Int) async {
		let icons = store.projectIcons
		guard case .success(let choice) = await icons.importImage(at: url, projectFolder: folder?.path ?? "", for: vaultId) else { return }
		guard !isDiscarded, generation == iconGeneration else {
			if choice != icon { icons.discardPreview(of: choice, for: vaultId) }
			return
		}
		replaceIcon(with: choice, file: url)
	}

	private func replaceIcon(with choice: ProjectIconChoice, file: URL?) {
		let icons = store.projectIcons
		icons.clearImportFailure(for: vaultId)
		if choice != icon { icons.discardPreview(of: icon, for: vaultId) }
		icon = choice
		iconFile = file
	}

	// MARK: - Folder

	/// Takes the project the LPM CLI acts on for `url` as the folder, unless
	/// its .lpm is the LPM home.
	func chooseFolder(_ url: URL) async {
		folderGeneration += 1
		let generation = folderGeneration
		isCheckingFolder = true
		folderError = nil
		let vaultId = vaultId
		let home = store.lpmHome
		let chosen = await BlockingWork.run { ProjectCLILink.choose(url, for: vaultId, home: home) }
		guard generation == folderGeneration, !isDiscarded else { return }
		switch chosen {
		case .success(let choice):
			await setFolder(choice, generation: generation)
		case .failure(let error):
			folderError = error
			await setFolder(nil, generation: generation)
		}
		if generation == folderGeneration { isCheckingFolder = false }
	}

	func clearFolder() async {
		folderGeneration += 1
		let generation = folderGeneration
		folderError = nil
		isCheckingFolder = true
		await setFolder(nil, generation: generation)
		if generation == folderGeneration { isCheckingFolder = false }
	}

	/// An image followed in the folder is taken in again from where it is, so
	/// the icon never names a file in a folder the project doesn't have.
	private func setFolder(_ choice: ProjectFolderChoice?, generation: Int) async {
		let moved = choice?.path != folder?.path
		folder = choice
		guard moved else { return }
		automaticIcon = nil
		if case .projectFile = icon {
			let file = iconFile
			useIcon(.automatic)
			if let file {
				await importIcon(file, generation: iconGeneration)
				guard generation == folderGeneration else { return }
			}
		}
		if let path = choice?.path {
			let resolution = await store.projectIcons.automaticIcon(inFolder: path)
			guard generation == folderGeneration, !isDiscarded else { return }
			automaticIcon = resolution
		}
	}

	// MARK: - Closing

	/// Drops what the draft prepared that no project kept, as when its sheet
	/// closes: an image copied for an icon that wasn't saved is deleted.
	func discard() {
		isDiscarded = true
		folderGeneration += 1
		iconGeneration += 1
		let icons = store.projectIcons
		if icons.choice(for: vaultId) != icon { icons.discardPreview(of: icon, for: vaultId) }
		icons.clearImportFailure(for: vaultId)
	}
}
