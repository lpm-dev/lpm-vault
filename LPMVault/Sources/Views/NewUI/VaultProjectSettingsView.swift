import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A project's settings: its name and icon, which save together, its folder,
/// its CLI approval, which changes as soon as Touch ID allows it, and
/// deleting it from this Mac.
struct VaultProjectSettingsView: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	/// Focuses the name field each time it changes, as Rename does.
	var nameFocusRequest: UUID?
	let onBack: () -> Void
	let onDelete: () -> Void

	@Environment(\.vaultContentObscured) private var isObscured
	@FocusState private var nameFocused: Bool
	@AccessibilityFocusState private var titleFocused: Bool
	@State private var showsIconPicker = false

	private var settings: ProjectSettingsValues { store.projectSettings(for: project) }
	private var isImporting: Bool { store.projectIcons.isImporting(project.id) }
	private var isEdited: Bool { store.projectSettingsDrafts[project.id] != nil }
	private var isSaving: Bool { store.savingProjectSettings.contains(project.id) }
	private var nameIsValid: Bool { VaultProjectRenamePolicy.normalizedName(settings.name) != nil }
	private var folderExists: Bool { store.projectIcons.detection(for: project.id) != .folderMissing && !project.path.isEmpty }
	private var displayPath: String { (project.path as NSString).abbreviatingWithTildeInPath }

	var body: some View {
		VStack(spacing: 0) {
			header
			VaultHairline()
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					identity
					section("PROJECT") {
						nameRow
						VaultHairline(color: VaultPalette.rowDivider)
						iconRow
						VaultHairline(color: VaultPalette.rowDivider)
						folderRow
					}
					section("SECURITY") { cliApprovalRow }
					section("DANGER ZONE") { deleteRow }
				}
				.frame(maxWidth: 640, alignment: .leading)
				.padding(.horizontal, 24)
				.padding(.vertical, 20)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.background(VaultPalette.content)
		.onAppear { store.projectIcons.beginDetailing(project.id) }
		.onDisappear { store.projectIcons.endDetailing(project.id) }
		.task(id: nameFocusRequest) {
			// VoiceOver lands on the page's title, or follows focus to the name Rename edits.
			if nameFocusRequest == nil { titleFocused = true }
		}
		.sheet(isPresented: $showsIconPicker) {
			VaultProjectIconPicker(projectName: settings.name, initial: settings.icon) { choice in
				store.projectIcons.clearImportFailure(for: project.id)
				store.editProjectSettings(of: project) { $0.icon = choice }
			}
			.vaultPrivacyProtected(isObscured)
		}
	}

	// MARK: - Header

	private var header: some View {
		HStack(spacing: 12) {
			Button(action: onBack) {
				HStack(spacing: 5) {
					Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .semibold))
					Text("All variables").font(.system(size: 12.5))
				}
				.foregroundStyle(VaultPalette.accentText)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.vaultPointingHand()
			.accessibilityLabel("Back to all variables")
			Text("/").font(.system(size: 12.5)).foregroundStyle(VaultPalette.textTertiary)
				.accessibilityHidden(true)
			Text("Project Settings")
				.font(.system(size: 19, weight: .bold))
				.foregroundStyle(VaultPalette.textPrimary)
				.lineLimit(1)
				.accessibilityAddTraits(.isHeader)
				.accessibilityFocused($titleFocused)
			Spacer(minLength: 12)
			if let error = store.projectSettingsErrors[project.id] {
				Text(error)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.lineLimit(2)
					.multilineTextAlignment(.trailing)
			} else if isEdited {
				Text(isSaving ? "Saving…" : "Unsaved changes")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			if isEdited {
				VaultBarButton(title: "Revert", disabled: isSaving, height: 28) {
					store.projectIcons.clearImportFailure(for: project.id)
					store.revertProjectSettings(of: project.id)
				}
				VaultBarButton(title: "Save", filled: true, disabled: isSaving || isImporting || !nameIsValid, height: 28, action: save)
					.keyboardShortcut("s", modifiers: .command)
			}
		}
		.padding(.horizontal, 24)
		.frame(height: 58)
	}

	private var identity: some View {
		HStack(spacing: 14) {
			VaultProjectIconView(appearance: store.projectIcons.appearance(of: settings.icon, for: project.id), size: 48)
			VStack(alignment: .leading, spacing: 3) {
				Text(VaultProjectRenamePolicy.normalizedName(settings.name) ?? project.name)
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				HStack(spacing: 6) {
					Text(displayPath)
						.font(VaultTypography.tabular(11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.truncationMode(.middle)
						.textSelection(.enabled)
					if folderExists {
						VaultRowIconButton(systemImage: "arrow.up.forward.square", help: "Show in Finder") { showInFinder() }
					}
				}
			}
		}
	}

	// MARK: - Rows

	private var nameRow: some View {
		row("Name") {
			Text("Shown in the sidebar and the title bar.")
		} controls: {
			TextField("Project name", text: Binding(
				get: { settings.name },
				set: { name in store.editProjectSettings(of: project) { $0.name = name } }
			))
			.textFieldStyle(.plain)
			.font(.system(size: 12.5))
			.foregroundStyle(VaultPalette.textPrimary)
			.focused($nameFocused)
			.onAppear { if nameFocusRequest != nil { focusName() } }
			.onChange(of: nameFocusRequest) { _, request in if request != nil { focusName() } }
			.onSubmit { if isEdited, nameIsValid { save() } }
			.disabled(isSaving)
			.padding(.horizontal, 9)
			.frame(width: 240, height: 28)
			.vaultInputField(focused: nameFocused, invalid: !nameIsValid)
			.accessibilityLabel("Project name")
		}
	}

	/// Focuses the name once the update that showed the page is done: SwiftUI
	/// hands focus back to the window as the view the page replaces goes,
	/// which undoes a request made during that update.
	private func focusName() {
		DispatchQueue.main.async { nameFocused = true }
	}

	private var iconRow: some View {
		row("Project icon") {
			if let failure = store.projectIcons.importFailure(for: project.id) {
				Text(Self.message(for: failure)).foregroundStyle(VaultPalette.redText)
			} else {
				iconCaption
			}
		} controls: {
			VaultProjectIconView(appearance: store.projectIcons.appearance(of: settings.icon, for: project.id), size: 16)
				.frame(width: 28, height: 28)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
				.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
			VaultBarButton(title: "Choose icon…", disabled: isSaving, height: 28) { showsIconPicker = true }
			VaultBarButton(title: isImporting ? "Choosing…" : "Choose file…", disabled: isSaving || isImporting, height: 28, action: chooseFile)
			if !settings.icon.isAutomatic {
				VaultBarButton(title: "Reset", disabled: isSaving, height: 28) {
					store.projectIcons.clearImportFailure(for: project.id)
					store.editProjectSettings(of: project) { $0.icon = .automatic }
				}
				.help("Reset to Automatic")
			}
		}
	}

	private var iconCaption: Text {
		let icons = store.projectIcons
		let parts = Self.iconCaption(for: settings.icon, detection: icons.detection(for: project.id),
			fileFailed: icons.chosenFileFailed(settings.icon, for: project.id))
		return parts.reduce(Text("")) { caption, part in
			caption + (part.isPath ? Text(part.text).font(VaultTypography.tabular(11.5)) : Text(part.text))
		}
	}

	struct CaptionPart: Equatable {
		let text: String
		var isPath = false
	}

	/// What the icon row says the icon is, with names of files and symbols set apart.
	static func iconCaption(for icon: ProjectIconChoice, detection: ProjectIconDetection, fileFailed: Bool) -> [CaptionPart] {
		switch icon {
		case .automatic:
			switch detection {
			case .searching: return [.init(text: "Automatic")]
			case .found(let path): return [.init(text: "Automatic · "), .init(text: path, isPath: true)]
			case .notFound: return [.init(text: "Automatic · no icon found")]
			case .folderMissing: return [.init(text: "Automatic · folder not found")]
			}
		case .symbol(let name, let color):
			return [.init(text: "Icon · "), .init(text: name, isPath: true), .init(text: " · \(color.title)")]
		case .emoji(let emoji):
			return [.init(text: "Emoji · \(emoji)")]
		case .monogram(let letters, let color):
			return [.init(text: "Monogram · \(letters) · \(color.title)")]
		case .projectFile(let path):
			let caption: [CaptionPart] = [.init(text: "Image · "), .init(text: path, isPath: true)]
			return fileFailed ? caption + [.init(text: " · can't be read, so the automatic icon shows")] : caption
		case .storedImage(_, let name):
			let caption: [CaptionPart] = [.init(text: "Image · \(name)")]
			return fileFailed ? caption + [.init(text: " · missing, so the automatic icon shows")] : caption
		}
	}

	private var folderRow: some View {
		row("Folder") {
			if folderExists {
				Text(displayPath).font(VaultTypography.tabular(11.5)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
			} else {
				Text(project.path.isEmpty ? "This project isn't linked to a folder." : "\(displayPath) can't be found.")
					.foregroundStyle(VaultPalette.redText)
			}
		} controls: {
			VaultBarButton(systemImage: "folder", title: "Show in Finder", disabled: !folderExists, height: 28) { showInFinder() }
		}
	}

	private var cliApprovalRow: some View {
		let access = store.selectedProjectCliAccess
		return row("CLI approval") {
			if access == nil {
				Text("The CLI approval policy can't be read.").foregroundStyle(VaultPalette.orangeTintText)
			} else {
				Text("When on, the LPM CLI asks for Touch ID or your Mac password before reading this project's values. It's the same setting as the header switch, and changing it asks for Touch ID.")
			}
		} controls: {
			Toggle("CLI approval", isOn: Binding(
				get: { access == .requireApproval },
				set: { required in Task { await store.changeCliAccess(to: required ? .requireApproval : .automatic) } }
			))
			.toggleStyle(.switch)
			.controlSize(.small)
			.labelsHidden()
			.disabled(access == nil || store.isChangingCliAccess || !store.canUseLocalSecrets)
			.help(VaultCliAccessPresentation(access: access).help)
			.accessibilityValue(VaultCliAccessPresentation(access: access).accessibilityValue)
		}
	}

	private var deleteRow: some View {
		row("Delete locally") {
			Text("Removes the project and its Keychain values from this Mac. Its folder, its lpm.json and a synced cloud copy stay.")
		} controls: {
			VaultBarButton(title: "Delete Locally…", destructive: true, disabled: isSaving, height: 28, action: onDelete)
		}
	}

	// MARK: - Layout

	private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			Text(title).vaultSectionLabel().accessibilityAddTraits(.isHeader)
			VStack(spacing: 0) { content() }
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.sidebar))
				.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		}
	}

	private func row<Description: View, Controls: View>(
		_ title: String, @ViewBuilder description: () -> Description, @ViewBuilder controls: () -> Controls
	) -> some View {
		HStack(alignment: .top, spacing: 16) {
			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.frame(minHeight: 28, alignment: .leading)
				description()
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineSpacing(2)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			// Centered on the title's line, however short the controls are.
			HStack(spacing: 8) { controls() }
				.frame(minHeight: 28)
				.fixedSize()
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 14)
	}

	// MARK: - Actions

	private func save() {
		guard isEdited, nameIsValid, !isSaving else { return }
		nameFocused = false
		Task { await store.saveProjectSettings(of: project.id) }
	}

	private func showInFinder() {
		guard folderExists else { return }
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path, isDirectory: true)])
	}

	private func chooseFile() {
		guard !isImporting else { return }
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.image]
		panel.message = "Choose an image for \(project.name)"
		if folderExists { panel.directoryURL = URL(fileURLWithPath: project.path, isDirectory: true) }
		guard runVaultPrivacyAwareModal(panel) == .OK, let url = panel.url else { return }
		let projectID = project.id
		let folder = project.path
		let store = store
		Task {
			guard case .success(let choice) = await store.projectIcons.importImage(at: url, projectFolder: folder, for: projectID) else { return }
			// The project may be gone, locked or saving by now; a choice it can't take drops its copy.
			let applied = store.projects.first { $0.id == projectID }.map { current in
				store.editProjectSettings(of: current) { $0.icon = choice }
			} ?? false
			if !applied { store.projectIcons.discardPreview(of: choice, for: projectID) }
		}
	}

	static func message(for failure: ProjectIconStore.ImportFailure) -> String {
		switch failure {
		case .unreadable: "That file can't be read."
		case .notAnImage: "That file isn't an image LPM Vault can show."
		case .couldNotSave: "The image couldn't be copied into LPM Vault."
		}
	}
}
