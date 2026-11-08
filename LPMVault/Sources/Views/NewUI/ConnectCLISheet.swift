import AppKit
import SwiftUI

struct ConnectCLISheet: View {
	static let docsURL = URL(string: "https://cli.lpm.dev/docs/dev/lpm-vault")!
	static let installURL = URL(string: "https://cli.lpm.dev/docs/installation")!

	@Bindable var store: VaultStore
	let projectId: String
	var folderPicker: @MainActor () -> URL? = Self.pickFolder
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL

	@State private var setupMode: SetupMode = .copyJSON
	@State private var status: ProjectCLILinkStatus?
	@State private var chosenFolder: String?
	@State private var linkError: ProjectCLILinkError?
	/// The folder chosen in the panel when the project around it was taken instead.
	@State private var choiceInsideProject: URL?
	@State private var isLinking = false
	@State private var copiedItem: String?
	@State private var copyResetTask: Task<Void, Never>?
	@State private var statusTask: Task<Void, Never>?
	@State private var statusGeneration = 0
	@State private var configuration = ProjectCLIConfiguration.pending
	@State var showsTaskExample = false
	/// Shows every terminal command, not just the first.
	@State private var showsAllCommands = false

	private enum SetupMode: CaseIterable {
		case copyJSON, writeFile

		var title: String {
			switch self {
			case .copyJSON: "Manual Setup"
			case .writeFile: "Write File"
			}
		}
	}

	private var guidance: ProjectCLICommands {
		ProjectCLICommands(environment: store.selectedEnvironment, configuration: configuration)
	}

	private var project: VaultProject? {
		store.projects.first { $0.id == projectId }
	}

	private var folder: String {
		chosenFolder ?? ProjectCLILink.folder(vaultId: projectId, projectPath: project?.path ?? "", defaults: store.preferences)
	}

	private var availableHeight: CGFloat {
		max(1, ((NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 80)
	}

	/// Tall enough for what's open, so nothing needs scrolling: the task example and the other commands add their own room.
	private var preferredHeight: CGFloat {
		min(640 + (showsTaskExample ? 120 : 0) + (showsAllCommands ? 68 : 0), availableHeight)
	}

	private var configJSON: String {
		"{\n  \"vault\": \"\(projectId)\"\n}"
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			ScrollView {
				// Numbered steps, in the order they're done: the folder only while none is linked.
				VStack(alignment: .leading, spacing: 22) {
					if status == .noFolder {
						VStack(alignment: .leading, spacing: 8) {
							step(1, "Choose the project folder")
							missingFolderNotice
						}
					}
					projectSection(number: status == .noFolder ? 2 : 1)
					terminalSection(number: status == .noFolder ? 3 : 2)
				}
				.padding(.horizontal, 24)
				.padding(.top, 18)
				// Room after the last step, so nothing sits half under the footer's line.
				.padding(.bottom, 24)
			}.frame(maxHeight: 720)
			footer
		}
		.frame(width: 600)
		.frame(minHeight: min(560, availableHeight), idealHeight: preferredHeight, maxHeight: preferredHeight)
		.background(VaultPalette.content)
		.onAppear(perform: refreshStatus)
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			refreshStatus()
		}
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { dismiss() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != projectId { dismiss() } }
		.onExitCommand { dismiss() }
		.onDisappear { copyResetTask?.cancel(); statusTask?.cancel() }
	}

	// MARK: - Sections

	private var header: some View {
		HStack(alignment: .top, spacing: 14) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Connect to the LPM CLI")
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Link \(Text(project?.name ?? "this project").fontWeight(.semibold).foregroundStyle(VaultPalette.textSecondary)) so the LPM CLI can use this vault.")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton { dismiss() }
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	private var missingFolderNotice: some View {
		HStack(spacing: 12) {
			VaultCardIcon(systemImage: "folder.badge.questionmark", size: 28)
			VStack(alignment: .leading, spacing: 1) {
				Text("No project folder on this Mac yet")
					.font(.system(size: 12.5, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Choose the folder that holds its package.json.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
			Spacer(minLength: 8)
			VaultBarButton(systemImage: "folder", title: "Choose Folder…", filled: true, disabled: isLinking) {
				setupMode = .writeFile
				chooseFolder()
			}
		}
		.padding(.leading, 12)
		.padding(.trailing, 10)
		.padding(.vertical, 10)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.card))
		.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
		.accessibilityElement(children: .contain)
	}

	private var vaultIDSection: some View {
		// One line: the ID is in the JSON below too, so it needs no box of its own.
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("Vault ID")
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(VaultPalette.textSecondary)
			Text(projectId)
				.font(VaultTypography.tabular(12.5, .medium))
				.foregroundStyle(VaultPalette.textSecondary)
				.lineLimit(1)
				.truncationMode(.middle)
				.textSelection(.enabled)
				.layoutPriority(1)
			Text("Identifies this project. Safe to commit.")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
			Spacer(minLength: 0)
		}
	}

	private func projectSection(number: Int) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				step(number, "Add the vault field to lpm.json")
				Spacer()
				VaultSegmentedPicker(title: "How to add the vault field", options: SetupMode.allCases.map { ($0, $0.title) }, selection: $setupMode)
			}
			vaultIDSection
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 8) {
					Text(setupMode == .copyJSON ? "./lpm.json" : displayPath)
						.font(VaultTypography.code(11))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.truncationMode(.head)
					Spacer(minLength: 8)
					switch setupMode {
					case .copyJSON:
						// One copy control throughout the sheet: its name says what it copies.
						CopyButton(isCopied: copiedItem == "json") { copy(configJSON, as: "json") }
							.accessibilityLabel(copiedItem == "json" ? "Copied JSON" : "Copy JSON")
					case .writeFile:
						writeFileAction
					}
				}
				.padding(.horizontal, Self.copyInset)
				.frame(height: 32)
				VaultHairline()
				Group {
					switch setupMode {
					case .copyJSON: jsonPreview
					case .writeFile: writeFileMessage
					}
				}
				.padding(.horizontal, 14)
				.padding(.vertical, 12)
				.frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
			}
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.codeBlock))
			.clipShape(RoundedRectangle(cornerRadius: 8))
			.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
			if setupMode == .copyJSON {
				Text("Create lpm.json if it's missing, and keep any fields it has.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			taskExample
		}
	}

	private var jsonPreview: some View {
		Text(
			"""
			{
			  \(Text("\"vault\"").foregroundStyle(VaultPalette.codeKey)): \(Text("\"\(projectId)\"").foregroundStyle(VaultPalette.codeString))
			}
			"""
		)
		.font(VaultTypography.code(12))
		.foregroundStyle(VaultPalette.codeText)
		.lineSpacing(4)
		.textSelection(.enabled)
	}

	@ViewBuilder
	private var taskExample: some View {
		if let example = ProjectCLITaskExample(vaultId: projectId, environments: project?.environmentNames ?? [], selectedEnvironment: store.selectedEnvironment, configuration: configuration) {
			VStack(alignment: .leading, spacing: 0) {
				Button { showsTaskExample.toggle() } label: {
					Label("Optional task environments", systemImage: showsTaskExample ? "chevron.down" : "chevron.right")
						.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
				}.buttonStyle(.plain).foregroundStyle(VaultPalette.textSecondary)
					.accessibilityValue(showsTaskExample ? "Expanded" : "Collapsed")
				if showsTaskExample {
					VStack(alignment: .leading, spacing: 10) {
						Text("Example using this vault's environments. Merge the env fields into your existing tasks and keep their other settings.")
							.font(.system(size: 11.5)).foregroundStyle(VaultPalette.textSecondary)
						VStack(alignment: .leading, spacing: 8) {
							HStack {
								Text("Example · lpm.json").font(VaultTypography.tabular(11))
								Spacer()
								CopyButton(isCopied: copiedItem == "task-example") { copy(example.json, as: "task-example") }
									.accessibilityLabel(copiedItem == "task-example" ? "Copied example" : "Copy example")
							}
							Text(example.json).font(VaultTypography.code(12)).textSelection(.enabled)
						}
						.padding(12).foregroundStyle(VaultPalette.codeText)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.codeBlock))
						.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
						if let warning = example.warning {
							VaultInlineWarning(text: warning)
						}
						Text("Write file only updates the vault ID. An explicit --env overrides a task's environment.")
							.font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
					}.padding(.top, 8)
				}
			}.font(.system(size: 12, weight: .medium))
		}
	}

	@ViewBuilder
	private var writeFileAction: some View {
		HStack(spacing: 12) {
			if status != .noFolder {
				TerminalBarButton(title: "Choose Folder…", systemImage: "folder") { chooseFolder() }
					.disabled(isLinking)
			}
			switch status {
			case .linked:
				Label("Linked", systemImage: "checkmark")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(VaultPalette.greenTintText)
			case .noFolder:
				EmptyView()
			case .linkedToOtherVault(let other):
				TerminalBarButton(title: "Replace Vault ID", systemImage: "square.and.pencil") { link(folder: folder, replacingVaultId: other) }
					.disabled(isLinking)
			case .notLinked:
				TerminalBarButton(title: isLinking ? "Writing…" : "Write lpm.json", systemImage: "square.and.pencil") {
					link(folder: folder)
				}
				.disabled(isLinking)
			case .unreadable, nil:
				EmptyView()
			}
		}
	}

	private var writeFileMessage: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(writeFileExplanation)
				.foregroundStyle(VaultPalette.textSecondary)
			if case .linkedToOtherVault(let other) = status, let linked = store.openableProject(id: other) {
				TerminalBarButton(title: "Open \(linked.name)", systemImage: "arrow.right.circle") {
					store.openProject(id: linked.id)
					dismiss()
				}
				.disabled(isLinking)
			}
			if let choiceInsideProject, linkError == nil {
				Text("Using the project folder around \(choiceInsideProject.lastPathComponent), as the LPM CLI does.")
					.foregroundStyle(VaultPalette.textSecondary)
			}
			if let linkError {
				Text(linkError.localizedDescription)
					.foregroundStyle(VaultPalette.redText)
			}
		}
		.font(.system(size: 12))
		.lineSpacing(2)
		.fixedSize(horizontal: false, vertical: true)
	}

	private var writeFileExplanation: String {
		switch status {
		case .linked:
			"lpm.json in this folder already links this vault."
		case .linkedToOtherVault(let other):
			if let linked = store.openableProject(id: other) {
				"lpm.json links \(linked.name) (vault \(Self.shortID(other))). Open it, or replace the link to point the CLI at this vault instead."
			} else {
				"lpm.json links vault \(Self.shortID(other)), which is not on this Mac. Replacing it points the CLI at this vault instead."
			}
		case .notLinked:
			"Adds \"vault\" to lpm.json and keeps your other settings. Creates the file if it does not exist."
		case .unreadable:
			"lpm.json in this folder cannot be read safely. Copy the JSON and add it yourself."
		case .noFolder:
			"This project has no folder on this Mac yet. Once you choose it, LPM Vault adds \"vault\" to its lpm.json."
		case nil:
			"Checking lpm.json…"
		}
	}

	private func terminalSection(number: Int) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .center, spacing: 8) {
				step(number, "Use it from the terminal")
				Text("\(status == .noFolder ? "once the project folder is linked" : "in the linked project folder") · \(VaultProject.displayName(for: guidance.environment))")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
			let commands = showsAllCommands ? guidance.commands : Array(guidance.commands.prefix(1))
			VStack(spacing: 0) {
				ForEach(Array(commands.enumerated()), id: \.element) { index, command in
					if index > 0 { VaultHairline() }
					CommandRow(command: command, isCopied: copiedItem == command) { copy(command, as: command) }
				}
			}
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.codeBlock))
			.clipShape(RoundedRectangle(cornerRadius: 8))
			.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
			// Until a folder is linked there's no lpm.json to check them against; the line under the step's title says they wait on it.
			if status != .noFolder, let warning = guidance.warning {
				VaultInlineWarning(text: warning)
			}
			let more = guidance.commands.count - 1
			if more > 0 {
				// A disclosure, as Optional task environments is, so it reads as something that opens.
				Button { showsAllCommands.toggle() } label: {
					Label(showsAllCommands ? "Show Fewer" : "Show \(more) More \(more == 1 ? "Command" : "Commands")",
						systemImage: showsAllCommands ? "chevron.down" : "chevron.right")
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(VaultPalette.textSecondary)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityValue(showsAllCommands ? "Expanded" : "Collapsed")
			}
			Text("An explicit --env overrides a script's own environment.")
				.font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var footer: some View {
		VaultSheetFooter {
			HStack(spacing: 7) {
				// The notice above the vault ID already says a folder is missing.
				if status != .noFolder {
					if let statusColor { VaultStatusDot(color: statusColor, size: 7) }
					Text(statusText)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.truncationMode(.tail)
				}
				if status != .noFolder {
					Text("·").foregroundStyle(VaultPalette.textTertiary).accessibilityHidden(true)
				}
				// Both go to lpm.dev's pages, so they're the same kind of link.
				if status == .notLinked || status == .noFolder {
					footerLink("Install LPM CLI", help: "Linking doesn't install the LPM CLI. This opens how to install it.", url: Self.installURL)
					Text("·").foregroundStyle(VaultPalette.textTertiary).accessibilityHidden(true)
				}
				footerLink("Docs", help: "How the LPM CLI reads lpm.json", url: Self.docsURL)
			}
			.help(folder.isEmpty ? "" : Self.configURL(folder).path)
		} actions: {
			// Nothing is connected yet without a folder, so the sheet only closes.
			VaultBarButton(title: status == .noFolder ? "Close" : "Done", filled: status != .noFolder, height: 30) { dismiss() }
				.keyboardShortcut(.defaultAction)
		}
	}

	private func footerLink(_ title: String, help: String, url: URL) -> some View {
		Button(title) { openURL(url) }
			.help(help)
			.buttonStyle(.plain)
			.font(.system(size: 11.5, weight: .semibold))
			.foregroundStyle(VaultPalette.accentForeground)
			.vaultPointingHand()
			.fixedSize()
	}

	// MARK: - Status

	private var statusText: String {
		switch status {
		case .linked: "Linked in lpm.json"
		case .notLinked: "Not linked to a project folder yet"
		case .linkedToOtherVault: "lpm.json links another vault"
		case .unreadable: "Cannot read lpm.json"
		case .noFolder: "No project folder on this Mac"
		case nil: "Checking lpm.json…"
		}
	}

	/// Only a state worth noticing gets a dot.
	private var statusColor: Color? {
		switch status {
		case .linked: VaultPalette.green
		case .linkedToOtherVault, .unreadable: VaultPalette.orange
		case .notLinked, .noFolder, nil: nil
		}
	}

	private var displayPath: String {
		guard !folder.isEmpty else { return "lpm.json" }
		return (Self.configURL(folder).path as NSString).abbreviatingWithTildeInPath
	}

	// MARK: - Actions

	/// A step's number and title, in the order the steps are done.
	private func step(_ number: Int, _ title: String) -> some View {
		HStack(spacing: 8) {
			Text("\(number)")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.accentText)
				.frame(width: 18, height: 18)
				.background(Circle().fill(VaultPalette.accentTint))
				.accessibilityHidden(true)
			sectionTitle(title)
				.accessibilityLabel("Step \(number): \(title)")
				.accessibilityAddTraits(.isHeader)
		}
	}

	private func sectionTitle(_ title: String) -> some View {
		Text(title)
			.font(.system(size: 13, weight: .semibold))
			.foregroundStyle(VaultPalette.textPrimary)
	}

	private func refreshStatus() {
		statusTask?.cancel()
		statusGeneration += 1
		let generation = statusGeneration
		status = nil
		configuration = .pending
		let vaultId = projectId
		let folder = folder
		statusTask = Task {
			let (resolved, config) = await BlockingWork.run {
				let snapshot = ProjectCLILink.inspect(vaultId: vaultId, folder: folder)
				return (snapshot.status, snapshot.configuration)
			}
			guard !Task.isCancelled, generation == statusGeneration, folder == self.folder else { return }
			status = resolved
			configuration = config
		}
	}

	private func link(folder target: String, replacingVaultId: String? = nil) {
		guard !isLinking else { return }
		isLinking = true
		linkError = nil
		let vaultId = projectId
		let home = store.lpmHome
		Task {
			let failure = await ProjectCLILink.linkInBackground(vaultId: vaultId, folder: target, replacingVaultId: replacingVaultId, home: home)
			isLinking = false
			linkError = failure
			refreshStatus()
			store.reloadKeyDescriptions()
		}
	}

	/// Takes the project the CLI would act on for the chosen folder: the nearest
	/// folder at or above it with a package.json or lpm.json. A folder whose
	/// .lpm is the LPM home is refused.
	private func chooseFolder() {
		guard let url = folderPicker() else { return }
		guard store.isUnlocked, store.selectedProjectId == projectId else { return }
		let home = store.lpmHome
		isLinking = true
		Task {
			let root = await BlockingWork.run { CLIFiles.projectRoot(for: url, home: home) }
			isLinking = false
			guard store.isUnlocked, store.selectedProjectId == projectId else { return }
			if root?.stateIsHome == true {
				choiceInsideProject = nil
				linkError = .folderIsLPMHome
				return
			}
			let folder = root?.url ?? url
			choiceInsideProject = folder.standardizedFileURL.path == url.standardizedFileURL.path ? nil : url
			chosenFolder = folder.path
			ProjectCLILink.rememberFolder(folder.path, vaultId: projectId, defaults: store.preferences)
			store.reloadKeyDescriptions()
			linkError = nil
			refreshStatus()
		}
	}

	private static func pickFolder() -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Choose Folder"
		panel.message = "Choose the folder that contains your project's package.json"
		guard runVaultPrivacyAwareModal(panel) == .OK else { return nil }
		return panel.url
	}

	private func copy(_ text: String, as item: String) {
		store.clipboard.copyText(text)
		copiedItem = item
		copyResetTask?.cancel()
		copyResetTask = Task {
			try? await Task.sleep(for: .seconds(1.5))
			guard !Task.isCancelled else { return }
			copiedItem = nil
		}
	}

	private static func configURL(_ folder: String) -> URL {
		ProjectCLILink.configURL(inFolder: folder)
	}

	/// How far in from the content's edge each Copy button's box ends.
	fileprivate static let copyInset: CGFloat = 12

	private static func shortID(_ id: String) -> String {
		id.count > 16 ? "\(id.prefix(8))…\(id.suffix(6))" : id
	}
}

private struct CopyButton: View {
	let isCopied: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
					.font(.system(size: 11))
				Text(isCopied ? "Copied" : "Copy")
					.font(.system(size: 12, weight: .medium))
			}
			.foregroundStyle(isCopied ? VaultPalette.greenTintText : (hovering ? VaultPalette.textPrimary : VaultPalette.textTertiary))
			.padding(.horizontal, 8)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 7).fill(hovering ? VaultPalette.controlHover : .clear))
			.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle())
		.onHover { hovering = $0 }
	}
}

private struct TerminalBarButton: View {
	let title: String
	let systemImage: String
	let action: () -> Void

	@State private var hovering = false
	@Environment(\.isEnabled) private var isEnabled

	var body: some View {
		Button(action: action) {
			HStack(spacing: 5) {
				Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium))
				Text(title).font(.system(size: 11.5, weight: .medium))
			}
			.foregroundStyle(hovering && isEnabled ? VaultPalette.textPrimary : VaultPalette.textSecondary)
			.opacity(isEnabled ? 1 : 0.5)
			.padding(.horizontal, 7)
			.frame(height: 24)
			.background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? VaultPalette.controlHover : .clear))
			.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle(cornerRadius: 6))
		.onHover { hovering = $0 }
	}
}

/// A command on one line, never wrapped inside a flag, that copies itself.
private struct CommandRow: View {
	let command: String
	let isCopied: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Text("$")
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
				Text(command)
					.font(VaultTypography.code(12))
					.foregroundStyle(VaultPalette.codeText)
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer(minLength: 8)
				// Said the way every copy control in the sheet says it.
				HStack(spacing: 6) {
					Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
						.font(.system(size: 11))
					Text(isCopied ? "Copied" : "Copy")
						.font(.system(size: 12, weight: .medium))
				}
				.foregroundStyle(isCopied ? VaultPalette.greenTintText : (hovering ? VaultPalette.textPrimary : VaultPalette.textTertiary))
				// Where a Copy button's title ends, inside its box.
				.padding(.trailing, 8)
			}
			.padding(.horizontal, ConnectCLISheet.copyInset)
			.frame(height: 34)
			.background(hovering ? VaultPalette.controlHover : .clear)
			.vaultHoverAnimation(hovering)
			.contentShape(Rectangle())
		}
		.buttonStyle(VaultPressStyle(shape: Rectangle()))
		.onHover { hovering = $0 }
		.help("Copy \(command)")
		.accessibilityLabel("Copy \(command)")
	}
}
