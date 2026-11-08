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
	@Environment(\.vaultClock) private var clock
	@FocusState private var nameFocused: Bool
	@AccessibilityFocusState private var titleFocused: Bool
	@State private var showsIconPicker = false
	@State private var historySummary: VaultLocalHistory.Summary?
	@State private var historyReadFailed = false
	@State private var historyFailure: String?
	@State private var confirmsHistoryOff = false
	@State private var changingHistory = false

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
				// The title bar names the project and the rows below edit it, so the page starts with them.
				VStack(alignment: .leading, spacing: 20) {
					section("PROJECT") {
						nameRow
						VaultHairline()
						iconRow
						VaultHairline()
						folderRow
					}
					section("SECURITY") { cliApprovalRow }
					section("HISTORY") { historyRow }
					section("DANGER ZONE") { deleteRow }
				}
				.vaultFormColumn()
			}
		}
		.background(VaultPalette.content)
		.onAppear { store.projectIcons.beginDetailing(project.id) }
		.onDisappear { store.projectIcons.endDetailing(project.id) }
		.task(id: project.id) { await readHistory() }
		.vaultConfirmation(isPresented: $confirmsHistoryOff) {
			VaultConfirmation(
				symbol: "clock.arrow.circlepath",
				title: "Turn off local history for \(project.name)?",
				message: "LPM deletes this project’s history on this Mac and stops recording changes. Values stay as they are. Deleting means LPM Vault and the LPM CLI can’t read the history any more. Copies in Time Machine, APFS snapshots or other backups of this Mac can remain. Turning history back on starts an empty history.",
				actions: [.init(title: "Turn Off and Delete") { setHistory(enabled: false) }])
		}
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

	/// The page's place as a path: the way back is where the path starts, so
	/// the title row starts and stands as every page's does.
	private var header: some View {
		HStack(spacing: 12) {
			// The way back reads as a step on the path, lighter than the page it leads from, on the title's baseline.
			HStack(alignment: .firstTextBaseline, spacing: 7) {
				VaultBackTitle(title: "All variables", action: onBack)
				Image(systemName: "chevron.right")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
				Text("Project Settings")
					.vaultPageTitle()
					.lineLimit(1)
					.accessibilityAddTraits(.isHeader)
					.accessibilityFocused($titleFocused)
			}
			.fixedSize()
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
		.padding(.horizontal, 20)
		.frame(height: 60)
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
			// A well, not a button: filled and unedged, apart from the buttons that change it.
			VaultProjectIconView(appearance: store.projectIcons.appearance(of: settings.icon, for: project.id), size: 16)
				.frame(width: 28, height: 28)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.neutralTint))
				.padding(.trailing, 6)
			VaultBarButton(title: "Choose Icon…", disabled: isSaving, height: 28) { showsIconPicker = true }
			VaultBarButton(title: isImporting ? "Choosing…" : "Choose File…", disabled: isSaving || isImporting, height: 28, action: chooseFile)
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
				Text(displayPath).font(VaultTypography.code(12)).foregroundStyle(VaultPalette.textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
					.help(project.path)
			} else {
				Text(project.path.isEmpty ? "This project isn't linked to a folder." : "\(displayPath) can't be found.")
					.foregroundStyle(VaultPalette.redText)
			}
		} controls: {
			HStack(spacing: 6) {
				VaultBarButton(systemImage: "doc.on.doc", title: "Copy Path", disabled: project.path.isEmpty, height: 28) {
					store.clipboard.copyText(project.path)
				}
				VaultBarButton(systemImage: "folder", title: "Show in Finder", disabled: !folderExists, height: 28) { showInFinder() }
			}
		}
	}

	private var cliApprovalRow: some View {
		let access = store.selectedProjectCliAccess
		return row("CLI approval") {
			if access == nil {
				Text("The CLI approval policy can't be read.").foregroundStyle(VaultPalette.orangeTintText)
			} else {
				Text("When on, the LPM CLI asks for Touch ID or your Mac password before it reads this project's values. Changing it asks for Touch ID.")
			}
		} controls: {
			Toggle("CLI approval", isOn: Binding(
				get: { access == .requireApproval },
				set: { required in Task { await store.changeCliAccess(to: required ? .requireApproval : .automatic) } }
			))
			.toggleStyle(VaultSwitchStyle())
			.controlSize(.small)
			.disabled(access == nil || store.isChangingCliAccess || !store.canUseLocalSecrets)
			.help(VaultCliAccessPresentation(access: access).help)
			.accessibilityValue(VaultCliAccessPresentation(access: access).accessibilityValue)
		}
	}

	private var historyRow: some View {
		let line = VaultHistoryText(now: clock.now()).stateLine(
			historySummary, notRecorded: store.history.notRecorded[project.id]?.reason, readFailed: historyReadFailed)
		let state = historySummary?.state.history
		return row("Local history") {
			VStack(alignment: .leading, spacing: 6) {
				Text("Keeps an encrypted record of value changes on this Mac, so you can see and roll them back. It never leaves this Mac.")
				if let line {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text(line.text)
							.foregroundStyle(line.warns ? VaultPalette.orangeTintText : VaultPalette.textSecondary)
						if line.retries {
							Button("Try Again") { Task { await readHistory() } }
								.buttonStyle(.plain)
								.font(.system(size: 12, weight: .semibold))
								.foregroundStyle(VaultPalette.accentForeground)
								.vaultPointingHand()
						}
					}
				}
				if let crowded = store.history.crowded, state != "off" {
					Text(VaultHistoryText(now: clock.now()).crowded(crowded))
						.foregroundStyle(VaultPalette.orangeTintText)
				}
				if let historyFailure {
					Text(historyFailure).foregroundStyle(VaultPalette.redText)
				}
			}
		} controls: {
			Toggle("Local history", isOn: Binding(
				get: { historySummary?.state.history != "off" },
				set: { on in
					if on { setHistory(enabled: true) } else { confirmsHistoryOff = true }
				}
			))
			.toggleStyle(VaultSwitchStyle())
			.controlSize(.small)
			.disabled(historySummary == nil || changingHistory || !store.canUseLocalSecrets || state == "unsupported" || state == "removing")
			.help(state == "off" ? "Start keeping history with the next change" : "Turn off and delete this project’s history")
		}
	}

	private func readHistory() async {
		switch await store.history.summary(of: project.id) {
		case .success(let summary):
			historySummary = summary
			historyReadFailed = false
		case .failure:
			historyReadFailed = true
		}
	}

	private func setHistory(enabled: Bool) {
		changingHistory = true
		historyFailure = nil
		Task {
			if let error = await store.history.setEnabled(enabled, projectID: project.id) {
				historyFailure = error.description
			}
			await readHistory()
			changingHistory = false
		}
	}

	private var deleteRow: some View {
		row("Delete locally") {
			Text("Removes the project, its Keychain values and its local history from this Mac. Its folder, its lpm.json and a synced cloud copy stay.")
		} controls: {
			VaultBarButton(title: "Delete Locally…", destructive: true, disabled: isSaving, height: 28, action: onDelete)
		}
	}

	// MARK: - Layout

	private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).vaultSectionLabel().accessibilityAddTraits(.isHeader)
			VStack(spacing: 0) { content() }
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.card))
				.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border, lineWidth: 1) }
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

/// The start of a page's path, in the title's size but quieter, which goes back to it.
private struct VaultBackTitle: View {
	let title: String
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Text(title)
				.font(.system(size: 15))
				.foregroundStyle(hovering ? VaultPalette.accentForeground : VaultPalette.textSecondary)
				.lineLimit(1)
				.contentShape(Rectangle())
				.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle(cornerRadius: 5))
		.vaultPointingHand()
		.onHover { hovering = $0 }
		.help("Back to All variables")
		.accessibilityLabel("Back to all variables")
	}
}
