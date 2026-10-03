import AppKit
import SwiftUI

struct ConnectCLISheet: View {
	static let docsURL = URL(string: "https://cli.lpm.dev/docs/dev/lpm-vault")!
	static let installURL = URL(string: "https://cli.lpm.dev/docs/installation")!

	@Bindable var store: VaultStore
	let projectId: String
	var folderPicker: @MainActor () -> URL? = Self.pickFolder
	var localFolderDefaults: UserDefaults = .standard
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL

	@State private var setupMode: SetupMode = .copyJSON
	@State private var status: ProjectCLILinkStatus?
	@State private var chosenFolder: String?
	@State private var linkError: ProjectCLILinkError?
	@State private var isLinking = false
	@State private var copiedItem: String?
	@State private var copyResetTask: Task<Void, Never>?
	@State private var statusTask: Task<Void, Never>?
	@State private var statusGeneration = 0
	@State private var configuration: LPMJSONValue?
	@State private var showsTaskExample = false

	private enum SetupMode: CaseIterable {
		case copyJSON, writeFile

		var title: String {
			switch self {
			case .copyJSON: "lpm.json"
			case .writeFile: "write file"
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
		chosenFolder ?? ProjectCLILink.folder(vaultId: projectId, projectPath: project?.path ?? "", defaults: localFolderDefaults)
	}

	private var configJSON: String {
		"{\n  \"vault\": \"\(projectId)\"\n}"
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				vaultIDSection
				projectSection
				terminalSection
			}
			.padding(.horizontal, 24)
			.padding(.top, 20)
			.padding(.bottom, 20)
			}.frame(maxHeight: 620)
			footer
		}
		.frame(width: 600)
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
			Image(systemName: "terminal")
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(VaultPalette.accentForeground)
				.frame(width: 38, height: 38)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.accentTint))
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 3) {
				Text("Connect to the LPM CLI")
					.font(.system(size: 17, weight: .bold))
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

	private var vaultIDSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				sectionTitle("Vault ID")
				Text("Identifies this project. Safe to commit.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			HStack(spacing: 8) {
				Text(projectId)
					.font(VaultTypography.mono(12.5))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
				CopyButton(isCopied: copiedItem == "vault-id") {
					copy(projectId, as: "vault-id")
				}
				.accessibilityLabel("Copy vault ID")
			}
			.padding(.leading, 12)
			.padding(.trailing, 4)
			.frame(height: 38)
			.vaultInputField(focused: false, background: VaultPalette.headerRow)
		}
	}

	private var projectSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				sectionTitle("Add it to your project")
				Spacer()
				SegmentedPicker(selection: $setupMode, options: SetupMode.allCases, title: \.title)
			}
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 8) {
					Text(setupMode == .copyJSON ? "./lpm.json" : displayPath)
						.font(VaultTypography.mono(11))
						.foregroundStyle(Color(hex: 0xAEAEB2))
						.lineLimit(1)
						.truncationMode(.head)
					Spacer(minLength: 8)
					switch setupMode {
					case .copyJSON:
						TerminalBarButton(
							title: copiedItem == "json" ? "Copied" : "Copy JSON",
							systemImage: copiedItem == "json" ? "checkmark" : "doc.on.doc"
						) { copy(configJSON, as: "json") }
					case .writeFile:
						writeFileAction
					}
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
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
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.terminal))
			.clipShape(RoundedRectangle(cornerRadius: 8))
			taskExample
		}
	}

	private var jsonPreview: some View {
		Text(
			"""
			{
			  \(Text("\"vault\"").foregroundStyle(Color(hex: 0x9FD4FF))): \(Text("\"\(projectId)\"").foregroundStyle(Color(hex: 0xC3E88D)))
			}
			"""
		)
		.font(VaultTypography.mono(12))
		.foregroundStyle(VaultPalette.terminalText)
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
				}.buttonStyle(.plain).foregroundStyle(VaultPalette.accentForeground)
					.accessibilityValue(showsTaskExample ? "Expanded" : "Collapsed")
				if showsTaskExample {
				VStack(alignment: .leading, spacing: 10) {
					Text("Example using this vault's environments. Merge the env fields into your existing tasks and keep their other settings.")
						.font(.system(size: 11.5)).foregroundStyle(VaultPalette.textSecondary)
					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Text("Example · lpm.json").font(VaultTypography.mono(11))
							Spacer()
							TerminalBarButton(title: copiedItem == "task-example" ? "Copied" : "Copy example", systemImage: "doc.on.doc") {
								copy(example.json, as: "task-example")
							}
						}
						Text(example.json).font(VaultTypography.mono(12)).textSelection(.enabled)
					}
					.padding(12).foregroundStyle(VaultPalette.terminalText)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.terminal))
					if let warning = example.warning {
						Text(warning).font(.system(size: 11)).foregroundStyle(VaultPalette.orange)
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
			TerminalBarButton(title: "Choose folder…", systemImage: "folder") { chooseFolder() }
				.disabled(isLinking)
			switch status {
			case .linked:
				Label("Linked", systemImage: "checkmark")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Color(hex: 0x75DB94))
			case .noFolder:
				EmptyView()
			case .linkedToOtherVault(let other):
				TerminalBarButton(title: "Replace vault ID", systemImage: "square.and.pencil") { link(folder: folder, replacingVaultId: other) }
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
				.foregroundStyle(VaultPalette.terminalText)
			if let linkError {
				Text(linkError.localizedDescription)
					.foregroundStyle(Color(hex: 0xFF847D))
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
			"lpm.json links vault \(Self.shortID(other)). Replacing it points the CLI at this vault instead."
		case .notLinked:
			"Adds \"vault\" to lpm.json and keeps your other settings. Creates the file if it does not exist."
		case .unreadable:
			"lpm.json in this folder cannot be read safely. Copy the JSON and add it yourself."
		case .noFolder:
			"This project has no folder on this Mac. Choose the folder that contains your package.json."
		case nil:
			"Checking lpm.json…"
		}
	}

	private var terminalSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			sectionTitle("Use it from the terminal")
			Text("Run from the linked project folder · \(VaultProject.displayName(for: guidance.environment))")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textSecondary)
			HStack(alignment: .top, spacing: 8) {
				ForEach(guidance.commands, id: \.self) { command in
					CommandCard(
						command: command,
						detail: copiedItem == command ? "Copied to the clipboard" : "Copy command"
					) { copy(command, as: command) }
				}
			}
			if let warning = guidance.warning {
				Text(warning).font(.system(size: 11)).foregroundStyle(VaultPalette.orange)
					.fixedSize(horizontal: false, vertical: true)
			}
			Text("Explicit selection overrides script settings. An empty environment falls back to default when running scripts. Linking does not install the CLI.")
				.font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var footer: some View {
		VaultSheetFooter {
			HStack(spacing: 7) {
				VaultStatusDot(color: statusColor, size: 7)
				Text(statusText)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
					.truncationMode(.tail)
				if status == .notLinked || status == .noFolder {
					Text("·").foregroundStyle(VaultPalette.textTertiary)
					Button("Install LPM CLI") { openURL(Self.installURL) }
						.buttonStyle(.plain)
						.font(.system(size: 11.5, weight: .semibold))
						.foregroundStyle(VaultPalette.accentForeground)
						.vaultPointingHand()
				}
			}
			.help(folder.isEmpty ? "" : Self.configURL(folder).path)
		} actions: {
			VaultBarButton(title: "Docs", height: 30) { openURL(Self.docsURL) }
			VaultBarButton(title: "Done", filled: true, height: 30) { dismiss() }
				.keyboardShortcut(.defaultAction)
		}
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

	private var statusColor: Color {
		switch status {
		case .linked: VaultPalette.green
		case .linkedToOtherVault, .unreadable: VaultPalette.orange
		case .notLinked, .noFolder, nil: VaultPalette.textFaint.opacity(0.5)
		}
	}

	private var displayPath: String {
		guard !folder.isEmpty else { return "lpm.json" }
		return (Self.configURL(folder).path as NSString).abbreviatingWithTildeInPath
	}

	// MARK: - Actions

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
		configuration = nil
		let vaultId = projectId
		let folder = folder
		statusTask = Task {
			let (resolved, config) = await Task.detached(priority: .userInitiated) {
				let status = ProjectCLILink.status(vaultId: vaultId, folder: folder)
				let config: LPMJSONValue?
				switch status {
				case .linked, .notLinked, .linkedToOtherVault:
					config = ProjectConfigFile.readJSON(at: ProjectCLILink.configURL(inFolder: folder))
				case .noFolder, .unreadable: config = nil
				}
				return (status, config)
			}.value
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
		Task {
			let failure = await Task.detached(priority: .userInitiated) { () -> ProjectCLILinkError? in
				do throws(ProjectCLILinkError) {
					try ProjectCLILink.link(vaultId: vaultId, folder: target, replacingVaultId: replacingVaultId)
					return nil
				} catch {
					return error
				}
			}.value
			isLinking = false
			linkError = failure
			refreshStatus()
		}
	}

	private func chooseFolder() {
		guard let url = folderPicker() else { return }
		guard store.isUnlocked, store.selectedProjectId == projectId else { return }
		chosenFolder = url.path
		ProjectCLILink.rememberFolder(url.path, vaultId: projectId, defaults: localFolderDefaults)
		linkError = nil
		refreshStatus()
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
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
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
					.font(.system(size: 11, weight: .medium))
				Text(isCopied ? "Copied" : "Copy")
					.font(.system(size: 12, weight: .semibold))
			}
			.foregroundStyle(isCopied ? VaultPalette.greenTintText : VaultPalette.textSecondary)
			.padding(.horizontal, 10)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 6).fill(hovering ? VaultPalette.sidebar : VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.vaultPointingHand()
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
				Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
				Text(title).font(.system(size: 11, weight: .semibold))
			}
			.foregroundStyle(hovering && isEnabled ? .white : Color(hex: 0xC7C7CC))
			.opacity(isEnabled ? 1 : 0.5)
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

private struct CommandCard: View {
	let command: String
	let detail: String
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			VStack(alignment: .leading, spacing: 6) {
				Text(command)
					.font(VaultTypography.mono(12, .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.fixedSize(horizontal: false, vertical: true)
				Text(detail)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineSpacing(1.5)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(.horizontal, 11)
			.padding(.vertical, 10)
			.frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
			.contentShape(Rectangle())
			.background(RoundedRectangle(cornerRadius: 8).fill(hovering ? VaultPalette.headerRow : VaultPalette.control))
			.overlay {
				RoundedRectangle(cornerRadius: 8)
					.stroke(hovering ? VaultPalette.accent.opacity(0.4) : VaultPalette.border, lineWidth: 1)
			}
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.vaultPointingHand()
		.help("Copy \(command)")
		.accessibilityLabel("Copy \(command)")
	}
}

private struct SegmentedPicker<Option: Hashable>: View {
	@Binding var selection: Option
	let options: [Option]
	let title: (Option) -> String

	init(selection: Binding<Option>, options: [Option], title: @escaping (Option) -> String) {
		_selection = selection
		self.options = options
		self.title = title
	}

	var body: some View {
		HStack(spacing: 0) {
			ForEach(Array(options.enumerated()), id: \.element) { index, option in
				if index > 0 {
					Rectangle().fill(VaultPalette.border).frame(width: 1)
				}
				let selected = option == selection
				Button { selection = option } label: {
					Text(title(option))
						.font(VaultTypography.mono(11, selected ? .bold : .regular))
						.foregroundStyle(selected ? .white : VaultPalette.masked)
						.padding(.horizontal, 9)
						.padding(.vertical, 3)
						.background(selected ? VaultPalette.strongFill : .clear)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
		.fixedSize()
		.clipShape(RoundedRectangle(cornerRadius: 6))
		.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
	}
}
