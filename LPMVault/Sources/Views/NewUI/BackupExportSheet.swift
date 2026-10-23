import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Exports a backup: what it holds, the passphrase that seals it, then the
/// file once it's saved. Touch ID confirms before anything is read, then the
/// person chooses where the file goes.
struct BackupExportSheet: View {
	@Bindable var store: VaultStore
	/// Where the file goes, given the name it's offered; nil when the person cancels.
	var chooseDestination: @MainActor (String) -> URL? = Self.runSavePanel
	@Environment(\.dismiss) private var dismiss

	@State private var contents = BackupExporter.Contents()
	@State private var passphrase = ""
	@State private var confirmation = ""
	/// The words of a generated passphrase while the field still holds it.
	@State private var generatedWords: [String]?
	@State private var reveals = false
	@State private var meter = BackupPassphraseMeter()
	@State private var destinationCount: Int?
	@State private var syncKeyCount: Int?
	@State private var phase: Phase = .editing
	@State private var error: String?
	@State private var task: Task<Void, Never>?
	@FocusState private var focusedField: Field?

	enum Phase: Equatable {
		case editing
		case authorizing
		case exporting
		case done(BackupExportResult)
	}

	private enum Field {
		case passphrase
		case confirmation
	}

	private var isWorking: Bool { phase == .authorizing || phase == .exporting }
	private var isGenerated: Bool { generatedWords != nil }
	private var matches: Bool { !passphrase.isEmpty && passphrase == confirmation }
	private var isStrong: Bool { isGenerated || meter.level == .strong }
	private var canExport: Bool { phase == .editing && matches && isStrong && store.canUseLocalSecrets }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			switch phase {
			case .done(let result):
				done(result)
			case .editing, .authorizing, .exporting:
				editor
			}
		}
		.frame(width: 560)
		.background(VaultPalette.content)
		.vaultUnsavedSheetWork(store, projectID: nil, projectName: "Settings", title: "Export backup", detail: passphrase.isEmpty ? nil : "A backup passphrase")
		.task {
			async let destinations = store.publishDestinationCount()
			async let keys = store.syncKeyCount()
			(destinationCount, syncKeyCount) = await (destinations, keys)
			if syncKeyCount == 0 { contents.syncKeys = false }
		}
		.onAppear { focusedField = .passphrase }
		.onDisappear(perform: discard)
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .top, spacing: 14) {
			VStack(alignment: .leading, spacing: 3) {
				Text(phase.isDone ? "Backup exported" : "Export backup")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.accessibilityAddTraits(.isHeader)
				if !phase.isDone {
					Text("One encrypted .lpmbackup file. Keep it somewhere you control — iCloud Drive, a USB key, a password manager.")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: close)
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	// MARK: - Editing

	private var editor: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 18) {
				VStack(alignment: .leading, spacing: 8) {
					Text("WHAT’S INCLUDED").vaultSectionLabel()
					includedList
					Label("Your lpm.dev login and platform logins aren’t included — you sign in again on the new Mac.", systemImage: "info.circle")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
				VStack(alignment: .leading, spacing: 8) {
					Text("PASSPHRASE").vaultSectionLabel()
					passphraseFields
				}
				warning
				if let error {
					Text(error)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.redText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.disabled(isWorking)
			.padding(24)
			VaultSheetFooter {
				Label("Touch ID confirms, then you choose where to save", systemImage: "touchid")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Cancel", height: 28, action: close)
					.keyboardShortcut(.escape, modifiers: [])
				VaultBarButton(title: phase == .exporting ? "Exporting…" : "Export…", filled: true, disabled: !canExport, height: 28, action: export)
			}
		}
	}

	private var includedList: some View {
		VStack(spacing: 0) {
			includedRow(
				"Projects & values", detail: "Always included",
				count: "\(store.projects.count.counted("project")) · \(store.projects.reduce(0) { $0 + $1.secretCount }.counted("key"))",
				isOn: nil)
			VaultHairline(color: VaultPalette.rowDivider)
			includedRow(
				"Publish destinations", detail: "Off until their platform’s login is connected on the new Mac",
				count: destinationCount.map { $0.counted("destination") }, isOn: $contents.destinations)
			VaultHairline(color: VaultPalette.rowDivider)
			includedRow("Settings & icons", detail: nil, count: nil, isOn: $contents.settingsAndIcons)
			VaultHairline(color: VaultPalette.rowDivider)
			includedRow(
				"lpm.dev sync keys",
				detail: syncKeyCount == 0 ? "None on this Mac" : "So the new Mac keeps syncing with lpm.dev",
				count: syncKeyCount.flatMap { $0 > 0 ? $0.counted("key") : nil },
				isOn: $contents.syncKeys)
				.disabled(syncKeyCount == 0)
		}
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.content))
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func includedRow(_ title: String, detail: String?, count: String?, isOn: Binding<Bool>?) -> some View {
		HStack(spacing: 12) {
			if let isOn {
				Toggle(isOn: isOn) { Text(title) }
					.toggleStyle(.checkbox)
					.labelsHidden()
			} else {
				Image(systemName: "checkmark.square.fill")
					.font(.system(size: 14))
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textPrimary)
				if let detail {
					Text(detail)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
			Spacer(minLength: 8)
			if let count {
				Text(count)
					.font(VaultTypography.tabular(12))
					.foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.accessibilityElement(children: .combine)
	}

	private var passphraseFields: some View {
		Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
			GridRow {
				fieldLabel("Passphrase")
				HStack(spacing: 8) {
					secretField("Passphrase", text: $passphrase, field: .passphrase)
						.onChange(of: passphrase) { _, typed in typedPassphrase(typed) }
					VaultBarButton(systemImage: "dice", title: "Generate", height: 34, action: generate)
				}
			}
			GridRow {
				Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
				if let words = generatedWords {
					generatedRow(words)
				} else {
					strengthRow
				}
			}
			GridRow {
				fieldLabel("Confirm")
				VStack(alignment: .leading, spacing: 4) {
					secretField("Confirm", text: $confirmation, field: .confirmation)
					if !confirmation.isEmpty && confirmation != passphrase {
						Text("The passphrases don’t match.")
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.redText)
					}
				}
			}
		}
	}

	private func fieldLabel(_ title: String) -> some View {
		Text(title)
			.font(.system(size: 13))
			.foregroundStyle(VaultPalette.textSecondary)
			.gridColumnAlignment(.trailing)
	}

	private func secretField(_ title: String, text: Binding<String>, field: Field) -> some View {
		HStack(spacing: 6) {
			Group {
				if reveals {
					TextField(title, text: text)
				} else {
					SecureField(title, text: text)
				}
			}
			.textFieldStyle(.plain)
			.font(VaultTypography.tabular(12.5))
			.foregroundStyle(VaultPalette.textPrimary)
			.autocorrectionDisabled()
			.focused($focusedField, equals: field)
			.onSubmit {
				if field == .passphrase { focusedField = .confirmation } else { export() }
			}
			if field == .passphrase {
				Button {
					reveals.toggle()
				} label: {
					Image(systemName: reveals ? "eye.slash" : "eye")
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.buttonStyle(.plain)
				.help(reveals ? "Hide passphrase" : "Show passphrase")
				.accessibilityLabel(reveals ? "Hide passphrase" : "Show passphrase")
			}
		}
		.padding(.horizontal, 11)
		.frame(height: 34)
		.vaultInputField(focused: focusedField == field)
	}

	private var strengthRow: some View {
		let segments: Int
		let color: Color
		let label: String
		switch meter.level {
		case .strong:
			(segments, color, label) = (4, VaultPalette.green, "Strong")
		case .weak(let filled):
			(segments, color, label) = (filled, VaultPalette.orange, "Weak")
		case nil:
			(segments, color, label) = (0, VaultPalette.border, passphrase.isEmpty ? "" : "Checking…")
		}
		return HStack(spacing: 6) {
			ForEach(0..<4, id: \.self) { index in
				Capsule()
					.fill(index < segments ? color : VaultPalette.border)
					.frame(height: 4)
			}
			Text(label)
				.font(.system(size: 11.5, weight: .medium))
				.foregroundStyle(meter.level == .strong ? VaultPalette.greenTintText : VaultPalette.orangeTintText)
				.frame(width: 64, alignment: .leading)
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(label.isEmpty ? "Passphrase strength" : "Passphrase strength: \(label)")
		.accessibilityValue(meter.level == .strong || label.isEmpty ? "" : "Make it longer, or use Generate")
	}

	private func generatedRow(_ words: [String]) -> some View {
		HStack(spacing: 6) {
			ForEach(Array(words.enumerated()), id: \.offset) { _, word in
				Text(word)
					.font(VaultTypography.tabular(12))
					.foregroundStyle(VaultPalette.textPrimary)
					.padding(.horizontal, 8)
					.padding(.vertical, 3)
					.background(RoundedRectangle(cornerRadius: 5).fill(VaultPalette.neutralTint))
			}
			Button {
				store.clipboard.copy(passphrase)
			} label: {
				Label("Copy", systemImage: "doc.on.doc")
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(VaultPalette.accentForeground)
			}
			.buttonStyle(.plain)
			.help("Copy the passphrase; it’s cleared from the clipboard after a while")
			.accessibilityLabel("Copy passphrase")
		}
		.accessibilityElement(children: .contain)
	}

	private var warning: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: "exclamationmark.triangle")
				.foregroundStyle(VaultPalette.orangeTintText)
				.accessibilityHidden(true)
			(Text("A lost passphrase can’t be recovered. ").bold() + Text("Nobody — not LPM, not lpm.dev — can open the file without it."))
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.orangeTintText)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.orangeTint))
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.orange.opacity(0.6), lineWidth: 1) }
		.accessibilityElement(children: .combine)
	}

	// MARK: - Done

	private func done(_ result: BackupExportResult) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 16) {
				HStack(spacing: 14) {
					Image(systemName: "doc")
						.font(.system(size: 17))
						.foregroundStyle(VaultPalette.accentForeground)
						.frame(width: 44, height: 44)
						.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.accentTint))
						.accessibilityHidden(true)
					VStack(alignment: .leading, spacing: 3) {
						Text(result.file.lastPathComponent)
							.font(VaultTypography.tabular(13).weight(.semibold))
							.foregroundStyle(VaultPalette.textPrimary)
							.lineLimit(1)
							.truncationMode(.middle)
						Text(Self.fileDetail(result))
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
							.fixedSize(horizontal: false, vertical: true)
					}
					Spacer(minLength: 8)
					VaultBarButton(systemImage: "arrow.up.forward.square", title: "Show in Finder", height: 28) {
						NSWorkspace.shared.activateFileViewerSelecting([result.file])
					}
				}
				.padding(14)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.content))
				.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
				Label("Encrypted with your passphrase. Store the passphrase separately from the file.", systemImage: "checkmark")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
				if result.summary.unusableItems > 0 {
					Text("\(result.summary.unusableItems.counted("Keychain item")) with names LPM Vault can’t use as project IDs couldn’t be included.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.orangeTintText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(24)
			VaultSheetFooter {
				Text("Last backup is now shown in Settings.")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Done", filled: true, height: 28, action: close)
					.keyboardShortcut(.defaultAction)
			}
		}
	}

	/// The file's size, where it is and what it holds:
	/// "184 KB · iCloud Drive › Backups · 12 projects, 7 destinations, settings".
	static func fileDetail(_ result: BackupExportResult) -> String {
		let summary = result.summary
		var holds = [summary.projects.counted("project")]
		if summary.removedProjects > 0 { holds.append("\(summary.removedProjects) removed from the sidebar") }
		if summary.destinations > 0 { holds.append(summary.destinations.counted("destination")) }
		if summary.syncKeys > 0 { holds.append(summary.syncKeys.counted("sync key")) }
		if summary.settings { holds.append("settings") }
		let folder = FileManager.default.componentsToDisplay(forPath: result.file.deletingLastPathComponent().path)?.suffix(2).joined(separator: " › ")
		return [ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file), folder, holds.joined(separator: ", ")]
			.compactMap { $0 }.joined(separator: " · ")
	}

	// MARK: - Actions

	private func typedPassphrase(_ typed: String) {
		if let words = generatedWords, typed != words.joined(separator: " ") {
			generatedWords = nil
		}
		if !isGenerated { meter.update(typed) }
	}

	private func generate() {
		guard case .success(let phrase) = BackupEngine.generatePassphrase() else {
			error = BackupEngine.Failure.engine(code: "backup.random_failed").message
			return
		}
		meter.reset()
		generatedWords = phrase.split(separator: " ").map(String.init)
		passphrase = phrase
		confirmation = phrase
		reveals = true
		error = nil
	}

	private func export() {
		guard canExport else { return }
		error = nil
		let contents = contents
		let passphrase = passphrase
		phase = .authorizing
		task = Task {
			defer { task = nil }
			guard let authorization = await store.authorizeBackupExport(), !Task.isCancelled else {
				if !Task.isCancelled { phase = .editing }
				return
			}
			guard let destination = chooseDestination(Self.defaultFileName(Date())) else {
				phase = .editing
				return
			}
			phase = .exporting
			do {
				let result = try await store.exportBackup(contents, passphrase: passphrase, to: destination, authorization: authorization)
				clearPassphrase()
				phase = .done(result)
			} catch is CancellationError {
				phase = .editing
			} catch let failure as BackupExporter.Failure {
				error = failure.message
				phase = .editing
			} catch {
				self.error = "The backup couldn’t be saved. \(error.localizedDescription)"
				phase = .editing
			}
		}
	}

	static func defaultFileName(_ date: Date) -> String {
		"LPM Vault \(date.formatted(.iso8601.year().month().day())).lpmbackup"
	}

	private func clearPassphrase() {
		passphrase = ""
		confirmation = ""
		generatedWords = nil
		reveals = false
		meter.reset()
	}

	private func discard() {
		task?.cancel()
		task = nil
		clearPassphrase()
	}

	private func close() {
		discard()
		dismiss()
	}

	@MainActor
	static func runSavePanel(_ name: String) -> URL? {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = name
		panel.allowedContentTypes = [UTType(filenameExtension: "lpmbackup") ?? .data]
		panel.canCreateDirectories = true
		panel.message = "Choose where to save the backup"
		guard runVaultPrivacyAwareModal(panel) == .OK else { return nil }
		return panel.url
	}
}

extension BackupExportSheet.Phase {
	var isDone: Bool {
		if case .done = self { return true }
		return false
	}
}
