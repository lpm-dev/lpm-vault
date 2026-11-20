import AppKit
import SwiftUI

/// Creates an env project: its name, icon and folder, and whether the LPM CLI
/// asks first and local history is kept, which start as Settings says.
struct NewVaultSheet: View {
	@Bindable var store: VaultStore
	private let folderPicker: @MainActor () -> URL?
	private let imagePicker: @MainActor (_ projectName: String, _ folder: String?) -> URL?

	@Environment(\.dismiss) private var dismiss
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var draft: NewProjectDraft
	@State private var isCreating = false
	@State private var awaitingApproval = false
	@State private var showsIconPicker = false
	@FocusState private var isFocused: Bool

	init(
		store: VaultStore,
		folderPicker: @escaping @MainActor () -> URL? = VaultOpenPanel.projectFolder,
		imagePicker: @escaping @MainActor (_ projectName: String, _ folder: String?) -> URL? = VaultOpenPanel.iconImage
	) {
		self.store = store
		self.folderPicker = folderPicker
		self.imagePicker = imagePicker
		_draft = State(initialValue: NewProjectDraft(store: store))
	}

	private var orgSlug: String? {
		if case .org(let slug) = store.selectedAccount { return slug }
		return nil
	}

	private var canDismiss: Bool {
		VaultCreationDismissalPolicy.canDismiss(isCreating: isCreating)
	}

	/// The name the icon picker suggests a monogram from.
	private var shownName: String { draft.normalizedName ?? "Project" }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 18) {
				header
				nameSection
				folderSection
				optionsCard
			}
			.disabled(isCreating)
			.padding(.horizontal, 24)
			.padding(.top, 20)
			.padding(.bottom, 22)

			VaultSheetFooter {
				if let orgSlug {
					Label("Will be shared with \(orgSlug)", systemImage: "building.2")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
				}
			} actions: {
				VaultBarButton(title: "Cancel", disabled: !canDismiss) { dismiss() }
					.keyboardShortcut(.escape, modifiers: [])
				VaultBarButton(title: "Create Project", filled: true, disabled: !draft.canCreate || isCreating, action: create)
					.keyboardShortcut(.defaultAction)
			}
		}
		.frame(width: 460)
		.background(VaultPalette.content)
		.interactiveDismissDisabled(!canDismiss)
		.onAppear { isFocused = true }
		.onDisappear { draft.discard() }
		.sheet(isPresented: $showsIconPicker) {
			VaultProjectIconPicker(projectName: shownName, initial: draft.icon) { draft.useIcon($0) }
				.vaultPrivacyProtected(isObscured)
		}
		.onChange(of: store.lastSyncStatus) { _, status in
			guard awaitingApproval else { return }
			switch VaultCreationDismissalPolicy.approvalAction(for: status) {
			case .dismiss:
				awaitingApproval = false
				dismiss()
			case .retry:
				awaitingApproval = false
				isCreating = false
			case .wait:
				break
			}
		}
	}

	// MARK: - Sections

	private var header: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text("New env project")
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
				.accessibilityAddTraits(.isHeader)
			Text("Create a new encrypted project in \(orgSlug ?? "your personal vault").")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var nameSection: some View {
		VStack(alignment: .leading, spacing: 7) {
			Text("PROJECT NAME").vaultSectionLabel()
			HStack(spacing: 8) {
				iconMenu
				TextField(vaultPrompt: "my-api-server", text: $draft.name)
					.textFieldStyle(.plain)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textPrimary)
					.focused($isFocused)
					.onSubmit(create)
					.padding(.horizontal, 11)
					.frame(height: Self.fieldHeight)
					.vaultInputField(focused: isFocused)
					.accessibilityLabel("Project name")
			}
			if let failure = draft.iconFailure {
				message(VaultProjectSettingsView.message(for: failure), color: VaultPalette.redText)
			}
		}
	}

	/// One menu for every way to change the icon, as in Project Settings.
	private var iconMenu: some View {
		VaultBarMenu(accessibilityLabel: "Choose icon", height: Self.fieldHeight, menuWidth: 248, rows: [
			.init(id: IconChoice.picker, title: "Symbol, Emoji or Monogram…"),
			.init(id: IconChoice.file, title: "Image File…", isEnabled: !draft.isImportingIcon),
			.init(id: IconChoice.automatic, title: "Use Automatic", detail: draft.icon.isAutomatic ? "in use" : nil,
				isEnabled: !draft.icon.isAutomatic, separated: true),
		], onChoose: chooseIcon) {
			VaultProjectIconView(appearance: draft.appearance, size: 18)
				.frame(width: 20, height: 20)
		}
		.help(iconHelp)
	}

	private enum IconChoice: Hashable {
		case picker, file, automatic
	}

	private var iconHelp: String {
		switch draft.icon {
		case .automatic:
			if case .found(let path)? = draft.automaticIcon?.detection { return "Icon: Automatic, from \(path)" }
			return "Icon: Automatic, found in the project’s folder"
		case .symbol(let name, let color): return "Icon: \(name), \(color.title)"
		case .emoji(let emoji): return "Icon: \(emoji)"
		case .monogram(let letters, let color): return "Icon: Monogram \(letters), \(color.title)"
		case .projectFile(let path): return "Icon: \(path)"
		case .storedImage(_, let name): return "Icon: \(name)"
		}
	}

	private var folderSection: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text("FOLDER").vaultSectionLabel()
				Text("Optional")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textFaint)
			}
			HStack(spacing: 8) {
				folderBox
				VaultBarButton(title: draft.folder == nil ? "Choose Folder…" : "Change Folder…", height: Self.fieldHeight) { chooseFolder() }
			}
			folderMessage
		}
	}

	private var folderBox: some View {
		HStack(spacing: 7) {
			Image(systemName: "folder")
				.font(.system(size: 11.5))
				.foregroundStyle(draft.folder == nil ? VaultPalette.textFaint : VaultPalette.textSecondary)
				.accessibilityHidden(true)
			if let folder = draft.folder {
				Text((folder.path as NSString).abbreviatingWithTildeInPath)
					.font(VaultTypography.code(12))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
					.help(folder.path)
					.frame(maxWidth: .infinity, alignment: .leading)
				Button { Task { await draft.clearFolder() } } label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textFaint)
				}
				.buttonStyle(.plain)
				.vaultPointingHand()
				.help("Don’t link a folder")
				.accessibilityLabel("Remove Folder")
			} else {
				Text("None")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.placeholder)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.padding(.horizontal, 10)
		.frame(height: Self.fieldHeight)
		.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.card))
		.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(VaultPalette.border, lineWidth: 1) }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Folder")
	}

	@ViewBuilder
	private var folderMessage: some View {
		if draft.isCheckingFolder {
			message("Checking lpm.json…")
		} else if let error = draft.folderError {
			message(error.localizedDescription, color: VaultPalette.redText)
		} else if let user = draft.folderUser {
			VStack(alignment: .leading, spacing: 8) {
				VaultInlineWarning(text: user.explanation)
				if let name = user.escapedName {
					VaultBarButton(systemImage: "arrow.right.circle", title: "Open \(name)", height: 26) {
						store.openProject(id: user.id)
						dismiss()
					}
				}
			}
		} else if let folder = draft.folder {
			switch folder.status {
			case .notLinked:
				VStack(alignment: .leading, spacing: 4) {
					if let inside = folder.chosenInside {
						message("Using the project folder around \((inside as NSString).lastPathComponent), as the LPM CLI does.")
					}
					message("Adds \"vault\" to its lpm.json, keeping its other settings, so the LPM CLI uses this project there.")
				}
			case .linked:
				message("Its lpm.json already links this project.")
			case .linkedToOtherVault(let other):
				if let linked = store.openableProject(id: other) {
					VStack(alignment: .leading, spacing: 8) {
						VaultInlineWarning(text: "Its lpm.json links \(linked.name). Choose another folder, or open \(linked.name).")
						VaultBarButton(systemImage: "arrow.right.circle", title: "Open \(linked.name)", height: 26) {
							store.openProject(id: linked.id)
							dismiss()
						}
					}
				} else {
					VaultInlineWarning(text: "Its lpm.json links vault \(Self.shortID(other)), which isn’t on this Mac. Choose another folder, or create the project without one and replace the link from Connect CLI.")
				}
			case .unreadable:
				VaultInlineWarning(text: "Its lpm.json can’t be read safely. Fix it, or choose another folder.")
			case .noFolder:
				VaultInlineWarning(text: "That folder can’t be found any more. Choose it again.")
			}
		} else {
			message("The LPM CLI uses this project in the folder you choose. You can link one later from Connect CLI.")
		}
	}

	/// What every new project asks for in Settings, chosen for this one.
	private var optionsCard: some View {
		VStack(spacing: 0) {
			optionRow("CLI approval", detail: "Asks for Touch ID or your Mac password before the LPM CLI reads this project’s values.",
				isOn: $draft.asksBeforeCLIReads)
			VaultHairline()
			optionRow("Local history", detail: "Keeps an encrypted record of value changes on this Mac, so you can see and roll them back.",
				isOn: $draft.keepsHistory)
		}
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.card))
		.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border, lineWidth: 1) }
	}

	private func optionRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
		HStack(alignment: .top, spacing: 14) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.frame(minHeight: 22, alignment: .leading)
				Text(detail)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineSpacing(1)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			Toggle(title, isOn: isOn)
				.toggleStyle(VaultSwitchStyle())
				.controlSize(.small)
				.frame(minHeight: 22)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 11)
	}

	private func message(_ text: String, color: Color = VaultPalette.textTertiary) -> some View {
		Text(text)
			.font(.system(size: 11.5))
			.foregroundStyle(color)
			.lineSpacing(1)
			.fixedSize(horizontal: false, vertical: true)
	}

	private static let fieldHeight: CGFloat = 34

	private static func shortID(_ id: String) -> String {
		id.count > 16 ? "\(id.prefix(8))…\(id.suffix(6))" : id
	}

	// MARK: - Actions

	private func chooseIcon(_ choice: IconChoice) {
		switch choice {
		case .picker: showsIconPicker = true
		case .automatic: draft.useIcon(.automatic)
		case .file:
			guard let url = imagePicker(shownName, draft.folder?.path) else { return }
			Task { await draft.chooseIconFile(url) }
		}
	}

	private func chooseFolder() {
		guard let url = folderPicker() else { return }
		Task { await draft.chooseFolder(url) }
	}

	private func create() {
		guard draft.canCreate, !isCreating, let name = draft.normalizedName else { return }
		isCreating = true
		Task {
			switch await store.createVault(name: name, orgSlug: orgSlug, vaultId: draft.vaultId, setup: draft.setup) {
			case .completed:
				dismiss()
			case .approvalRequired:
				awaitingApproval = true
			case .failed:
				isCreating = false
			}
		}
	}
}
