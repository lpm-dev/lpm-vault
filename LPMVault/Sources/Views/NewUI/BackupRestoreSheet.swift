import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Restores a backup: the file and its passphrase, a review of what comes
/// in, then each project as it's written. Nothing is written until the person
/// chooses Restore and authenticates.
struct BackupRestoreSheet: View {
	@Bindable var store: VaultStore
	/// Applies the app settings the store doesn't own, such as appearance.
	var applySettings: @MainActor (BackupAppSection.Settings) -> Void = { _ in }
	var chooseFile: @MainActor () -> URL? = Self.runOpenPanel
	var chooseFolder: @MainActor (String?) -> URL? = Self.runFolderPanel
	@Environment(\.dismiss) private var dismiss

	@State private var file: URL?
	@State private var fileDetail: String?
	@State private var passphrase = ""
	@State private var openError: String?
	@State private var review: BackupRestoreReview?
	@State private var choices = BackupRestoreChoices(included: [], applySettings: false)
	@State private var suggestedFolders: [String: String] = [:]
	@State private var folderErrors: [String: String] = [:]
	@State private var expanded: Set<String> = []
	@State private var finished: [BackupRestoreResult.Item] = []
	@State private var result: BackupRestoreResult?
	@State private var phase: Phase = .choosing
	@State private var task: Task<Void, Never>?
	@State private var isDropTargeted = false
	@FocusState private var passphraseFocused: Bool

	enum Phase: Equatable {
		case choosing
		case opening
		case reviewing
		case restoring
		case finished
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			switch phase {
			case .choosing, .opening: chooser
			case .reviewing: reviewer
			case .restoring, .finished: progressView
			}
		}
		.frame(width: 600)
		.frame(height: phase == .choosing || phase == .opening ? nil : 600)
		.background(VaultPalette.content)
		.vaultUnsavedSheetWork(store, projectID: nil, projectName: "Settings", title: "Restore from backup", detail: phase == .reviewing ? "A backup ready to restore" : nil)
		.onDisappear(perform: discard)
	}

	private var title: String {
		switch phase {
		case .choosing, .opening: "Restore from backup"
		case .reviewing: "Review what comes in"
		case .restoring: "Restoring…"
		case .finished: "Restore finished"
		}
	}

	private var subtitle: String {
		switch phase {
		case .choosing, .opening: "Nothing is written until you review what comes in."
		case .reviewing: "From \(review?.fileName ?? "the backup"). Nothing is written until you choose Restore."
		case .restoring: "Writing to the Keychain on this Mac. Don’t quit LPM Vault."
		case .finished: "\(finished.count.counted("item")) from \(review?.fileName ?? "the backup")."
		}
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 14) {
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.accessibilityAddTraits(.isHeader)
				Text(subtitle)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 12)
			if phase != .restoring { VaultSheetCloseButton(action: close) }
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	// MARK: - Choosing the file

	private var chooser: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 18) {
				if let file {
					HStack(spacing: 12) {
						fileTile
						VStack(alignment: .leading, spacing: 2) {
							Text(file.lastPathComponent)
								.font(VaultTypography.tabular(13).weight(.semibold))
								.foregroundStyle(VaultPalette.textPrimary)
								.lineLimit(1)
								.truncationMode(.middle)
							if let fileDetail {
								Text(fileDetail)
									.font(.system(size: 11.5))
									.foregroundStyle(VaultPalette.textTertiary)
							}
						}
						Spacer(minLength: 8)
						VaultBarButton(title: "Change…", height: 28, action: pickFile)
					}
					.padding(14)
					.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.content))
					.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
				} else {
					VStack(spacing: 10) {
						fileTile
						Text("Choose a .lpmbackup file or drop it here")
							.font(.system(size: 12.5))
							.foregroundStyle(VaultPalette.textSecondary)
						VaultBarButton(title: "Choose…", height: 28, action: pickFile)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 24)
					.background(RoundedRectangle(cornerRadius: 10).fill(isDropTargeted ? VaultPalette.accentTint : VaultPalette.sidebar))
					.overlay {
						RoundedRectangle(cornerRadius: 10)
							.stroke(isDropTargeted ? VaultPalette.accent : VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
					}
				}
				VStack(alignment: .leading, spacing: 8) {
					Text("PASSPHRASE").vaultSectionLabel()
					SecureField("Enter the backup’s passphrase", text: $passphrase)
						.textFieldStyle(.plain)
						.font(VaultTypography.tabular(12.5))
						.foregroundStyle(VaultPalette.textPrimary)
						.focused($passphraseFocused)
						.onSubmit(open)
						.padding(.horizontal, 11)
						.frame(height: 34)
						.vaultInputField(focused: passphraseFocused, invalid: openError != nil)
						.disabled(file == nil)
						.accessibilityLabel("Passphrase")
						.onChange(of: passphrase) { _, _ in openError = nil }
					if let openError {
						Text(openError)
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.redText)
							.fixedSize(horizontal: false, vertical: true)
					} else {
						Text("The six words or passphrase you set when exporting.")
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
					}
				}
			}
			.disabled(phase == .opening)
			.padding(24)
			VaultSheetFooter {
				Label("The file is decrypted on this Mac only", systemImage: "lock")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Cancel", height: 28, action: close)
					.keyboardShortcut(.escape, modifiers: [])
				VaultBarButton(
					title: phase == .opening ? "Opening…" : "Continue", filled: true,
					disabled: file == nil || passphrase.isEmpty || phase == .opening || !store.canUseLocalSecrets,
					height: 28, action: open)
			}
		}
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			guard let provider = providers.first else { return false }
			_ = provider.loadObject(ofClass: URL.self) { url, _ in
				guard let url else { return }
				Task { @MainActor in use(url) }
			}
			return true
		}
	}

	private var fileTile: some View {
		Image(systemName: "doc.badge.arrow.up")
			.font(.system(size: 16))
			.foregroundStyle(VaultPalette.accentForeground)
			.frame(width: 40, height: 40)
			.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.accentTint))
			.accessibilityHidden(true)
	}

	// MARK: - Review

	private var plan: BackupRestorePlan? { review?.plan }

	private func projects(_ match: (BackupRestorePlan.Status) -> Bool) -> [BackupRestorePlan.Project] {
		plan?.projects.filter { match($0.status) } ?? []
	}

	private var newProjects: [BackupRestorePlan.Project] { projects { $0 == .new } }
	private var hereProjects: [BackupRestorePlan.Project] {
		projects { status in
			switch status {
			case .merge, .identical: true
			default: false
			}
		}
	}
	private var unusableProjects: [BackupRestorePlan.Project] {
		projects { if case .unusable = $0 { true } else { false } }
	}

	private var restoreCount: Int {
		(plan?.projects ?? []).filter { project in
			guard choices.included.contains(project.id) else { return false }
			if case .identical = project.status { return false }
			return true
		}.count
	}

	/// Whether restoring writes a sync key or raises a floor this Mac lacks.
	private var restoresKeys: Bool {
		guard choices.restoreKeys, let keys = review?.keys else { return false }
		return keys.added > 0 || keys.floorsRaised > 0
	}

	private var reviewer: some View {
		VStack(alignment: .leading, spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					pills
					if let contents = plan?.contents {
						Text(Self.madeOn(contents))
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
					}
					if !newProjects.isEmpty {
						section("NEW", detail: "\(newProjects.count.counted("project")) · added with their keys") {
							ForEach(newProjects) { newRow($0) }
						}
					}
					if !hereProjects.isEmpty {
						section("ALREADY HERE", detail: "\(hereProjects.count.counted("project")) · merged — this Mac’s values and folder are kept") {
							ForEach(hereProjects) { hereRow($0) }
						}
					}
					if !unusableProjects.isEmpty {
						section("CAN’T BE RESTORED", detail: nil) {
							ForEach(unusableProjects) { project in
								projectLine(project, detail: { if case .unusable(let reason) = project.status { reason } else { "" } }())
							}
						}
					}
					extras
				}
				.padding(24)
			}
			.frame(maxHeight: .infinity, alignment: .top)
			VaultSheetFooter {
				Label("Touch ID or your Mac password, just before writing", systemImage: "touchid")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Back", height: 28) {
					review = nil
					phase = .choosing
				}
				VaultBarButton(
					title: restoreCount == 0 ? "Restore" : "Restore \(restoreCount.counted("item"))", filled: true,
					disabled: restoreCount == 0 && !choices.applySettings && !restoresKeys,
					height: 28, action: restore)
			}
		}
	}

	private var pills: some View {
		HStack(spacing: 6) {
			if !newProjects.isEmpty { pill("\(newProjects.count) new", accent: true) }
			if !hereProjects.isEmpty { pill("\(hereProjects.count) already here", accent: false) }
			pill("Values hidden", accent: false, systemImage: "eye.slash")
		}
	}

	private func pill(_ text: String, accent: Bool, systemImage: String? = nil) -> some View {
		HStack(spacing: 4) {
			if let systemImage { Image(systemName: systemImage).font(.system(size: 10)).accessibilityHidden(true) }
			Text(text)
		}
		.font(.system(size: 11.5, weight: .medium))
		.foregroundStyle(accent ? VaultPalette.accentText : VaultPalette.textSecondary)
		.padding(.horizontal, 8)
		.padding(.vertical, 3)
		.background(Capsule().fill(accent ? VaultPalette.accentTint : VaultPalette.neutralTint))
	}

	private func section<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Text(title).vaultSectionLabel()
				if let detail {
					Text(detail)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
			VStack(spacing: 0) { content() }
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.content))
				.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		}
	}

	private func include(_ id: String) -> Binding<Bool> {
		Binding(
			get: { choices.included.contains(id) },
			set: { if $0 { choices.included.insert(id) } else { choices.included.remove(id) } })
	}

	private func newRow(_ project: BackupRestorePlan.Project) -> some View {
		let backup = project.backup
		let folder = choices.folders[project.id]
		var details = ["\(project.keyCount.counted("key")) · \(backup.environments.count.counted("env"))"]
		if backup.hidden { details.append("removed from the sidebar on the Mac it came from") }
		if let hint = backup.folder, !backup.hidden { details.append("backup folder \(Self.abbreviated(hint))") }
		if let sync = backup.sync {
			details.append(review?.hasKey(for: sync, restoringKeys: choices.restoreKeys) == true
				? "syncs with lpm.dev"
				: "syncs with lpm.dev — paused: this Mac doesn’t have its key")
		}
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 12) {
				Toggle(isOn: include(project.id)) { Text(backup.name.escapingDirectionControls) }
					.toggleStyle(.checkbox)
					.labelsHidden()
				VStack(alignment: .leading, spacing: 2) {
					Text(backup.name.escapingDirectionControls)
						.font(.system(size: 13))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(details.joined(separator: " · ").escapingDirectionControls)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 8)
				if !backup.hidden, choices.included.contains(project.id) {
					if let folder {
						Text(Self.abbreviated(folder))
							.font(VaultTypography.tabular(11.5))
							.foregroundStyle(VaultPalette.textSecondary)
							.lineLimit(1)
							.truncationMode(.middle)
						VaultBarButton(title: "Change…", height: 26) { pickFolder(for: project) }
					} else if let suggested = suggestedFolders[project.id] {
						VaultBarButton(title: "Use this folder", height: 26) { choices.folders[project.id] = suggested }
						VaultBarButton(title: "Choose folder…", height: 26) { pickFolder(for: project) }
					} else {
						VaultBarButton(title: "Choose folder…", height: 26) { pickFolder(for: project) }
					}
				}
			}
			.accessibilityElement(children: .contain)
			if let error = folderErrors[project.id] {
				Text(error)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
	}

	private func hereRow(_ project: BackupRestorePlan.Project) -> some View {
		let name = (project.localName ?? project.backup.name).escapingDirectionControls
		switch project.status {
		case .identical:
			return AnyView(projectLine(project, detail: "\(project.keyCount.counted("key")) · all the same", badge: "Identical"))
		case .merge(let added, let differing):
			var details: [String] = []
			if added > 0 { details.append("\(added.counted("key")) from the backup added") }
			if !differing.isEmpty {
				details.append((differing.count == 1 ? "1 key differs" : "\(differing.count) keys differ") + " — choose per key")
			}
			if details.isEmpty { details.append("new environments from the backup added") }
			return AnyView(VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 12) {
					Toggle(isOn: include(project.id)) { Text(name) }
						.toggleStyle(.checkbox)
						.labelsHidden()
					VStack(alignment: .leading, spacing: 2) {
						Text(name)
							.font(.system(size: 13))
							.foregroundStyle(VaultPalette.textPrimary)
						Text(details.joined(separator: " · "))
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
					}
					Spacer(minLength: 8)
					if !differing.isEmpty, choices.included.contains(project.id) {
						Button(expanded.contains(project.id) ? "Hide keys" : "Show keys") {
							if expanded.contains(project.id) { expanded.remove(project.id) } else { expanded.insert(project.id) }
						}
						.buttonStyle(.plain)
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(VaultPalette.accentForeground)
					}
				}
				.accessibilityElement(children: .contain)
				if expanded.contains(project.id), choices.included.contains(project.id) {
					VStack(spacing: 6) {
						ForEach(differing, id: \.self) { difference in
							keyChoice(difference, in: project.id)
						}
					}
					.padding(.top, 8)
					.padding(.leading, 30)
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10))
		default:
			return AnyView(EmptyView())
		}
	}

	private func keyChoice(_ difference: BackupRestorePlan.KeyDifference, in id: String) -> some View {
		let replaces = Binding(
			get: { choices.replacing[id]?.contains(difference) == true },
			set: { replace in
				var keys = choices.replacing[id] ?? []
				if replace { keys.insert(difference) } else { keys.remove(difference) }
				choices.replacing[id] = keys
			})
		let label = difference.environment == "default"
			? difference.key : "\(difference.key) in \(VaultProject.displayName(for: difference.environment))"
		return HStack {
			Text(label)
				.font(VaultTypography.tabular(12))
				.foregroundStyle(VaultPalette.textPrimary)
			Spacer(minLength: 8)
			Picker(label, selection: replaces) {
				Text("Keep mine").tag(false)
				Text("Replace").tag(true)
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.fixedSize()
		}
	}

	private func projectLine(_ project: BackupRestorePlan.Project, detail: String, badge: String? = nil) -> some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text((project.localName ?? project.backup.name).escapingDirectionControls)
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textPrimary)
				Text(detail)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			Spacer(minLength: 8)
			if let badge {
				VaultTagBadge(text: badge.uppercased(), foreground: VaultPalette.textSecondary, background: VaultPalette.neutralTint)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.accessibilityElement(children: .combine)
	}

	private var extras: some View {
		let destinations = (plan?.projects ?? []).reduce(0) { total, project in
			total + (plan?.contents.app?.destinations[project.id]?.count ?? 0)
		}
		return VStack(alignment: .leading, spacing: 10) {
			Label("Platform logins aren’t in backups. Connect them again on the Platforms page.", systemImage: "info.circle")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
			if destinations > 0 {
				Label("\(destinations.counted("publish destination")) · off until their platform’s login is connected", systemImage: "paperplane")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			if plan?.contents.app?.settings != nil {
				Text("SETTINGS").vaultSectionLabel()
				Toggle(isOn: $choices.applySettings) {
					VStack(alignment: .leading, spacing: 2) {
						Text("Use the backup’s settings")
							.font(.system(size: 13))
							.foregroundStyle(VaultPalette.textPrimary)
						Text(store.projects.isEmpty
							? "Appearance, quit shortcut, key sort, project order and icons"
							: "Appearance, quit shortcut, key sort, project order and icons — replaces this Mac’s")
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
					}
				}
				.toggleStyle(.checkbox)
			}
			if let review, !review.plan.contents.keys.isEmpty {
				Text("LPM.DEV SYNC KEYS").vaultSectionLabel()
				Toggle(isOn: $choices.restoreKeys) {
					VStack(alignment: .leading, spacing: 2) {
						Text("Add the backup’s sync keys")
							.font(.system(size: 13))
							.foregroundStyle(VaultPalette.textPrimary)
						Text(Self.keysDetail(review.keys))
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				.toggleStyle(.checkbox)
			}
		}
	}

	/// What adding a backup's sync keys does here: "2 to add · 1 already on
	/// this Mac · 1 differs, this Mac’s kept".
	static func keysDetail(_ keys: BackupKeyStore.Review) -> String {
		var parts: [String] = []
		if keys.added > 0 { parts.append("\(keys.added) to add") }
		if keys.alreadyHere > 0 { parts.append("\(keys.alreadyHere) already on this Mac") }
		if keys.differing > 0 { parts.append(keys.differing == 1 ? "1 differs, this Mac’s kept" : "\(keys.differing) differ, this Mac’s kept") }
		if parts.isEmpty { return "Synced projects keep syncing with lpm.dev on this Mac" }
		return parts.joined(separator: " · ")
	}

	/// The restored projects whose sync stayed paused, because this Mac doesn't have their keys.
	private var pausedCount: Int {
		finished.count { item in
			guard case .restored = item.outcome else { return false }
			return store.syncPauses[item.vaultId] != nil
		}
	}

	// MARK: - Progress and summary

	private var progressView: some View {
		VStack(alignment: .leading, spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					if phase == .finished { summaryPills }
					VStack(spacing: 0) {
						ForEach(finished, id: \.vaultId) { item in
							resultLine(item)
						}
						if phase == .restoring, let current = currentProject {
							HStack(spacing: 10) {
								ProgressView().controlSize(.small)
								Text(current.escapingDirectionControls)
									.font(.system(size: 13))
									.foregroundStyle(VaultPalette.textPrimary)
								Spacer()
							}
							.padding(.horizontal, 14)
							.padding(.vertical, 10)
						}
					}
					.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.content))
					.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
					if phase == .finished {
						if let result, result.destinations > 0 {
							Text("\(result.destinations.counted("publish destination")) added. They publish once their platform’s login is connected.")
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.textTertiary)
						}
						if finished.contains(where: { if case .restored(_, _, true) = $0.outcome { true } else { false } }) {
							Text("Link each project that needs a folder from Connect CLI, once you have its folder on this Mac.")
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.textTertiary)
						}
						if let keys = result?.keys, keys.added > 0 {
							Text("\(keys.added.counted("sync key")) added. Synced projects pull lpm.dev’s latest values when you sync.")
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.textTertiary)
								.fixedSize(horizontal: false, vertical: true)
						}
						if let keyFailure = result?.keyFailure {
							Text(keyFailure)
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.redText)
								.fixedSize(horizontal: false, vertical: true)
						}
						if pausedCount > 0 {
							Text("\(pausedCount.counted("synced project")) keep\(pausedCount == 1 ? "s" : "") sync paused: this Mac doesn’t have \(pausedCount == 1 ? "its" : "their") keys. Their values work here; open one to reconnect it or keep it on this Mac only.")
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.orangeTintText)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
				}
				.padding(24)
			}
			.frame(maxHeight: .infinity, alignment: .top)
			VaultSheetFooter {
				EmptyView()
			} actions: {
				if phase == .restoring {
					VaultBarButton(title: "Cancel", height: 28) { task?.cancel() }
				} else {
					VaultBarButton(title: "Done", filled: true, height: 28, action: close)
						.keyboardShortcut(.defaultAction)
				}
			}
		}
	}

	private var currentProject: String? {
		guard let plan else { return nil }
		let done = Set(finished.map(\.vaultId))
		return plan.projects.first { !done.contains($0.id) }.map { $0.localName ?? $0.backup.name }
	}

	private var summaryPills: some View {
		let counts = Self.counts(finished)
		return HStack(spacing: 6) {
			if counts.restored > 0 { pill("\(counts.restored) restored", accent: true) }
			if counts.merged > 0 { pill("\(counts.merged) merged", accent: false) }
			if counts.skipped > 0 { pill("\(counts.skipped) skipped", accent: false) }
			if counts.needFolder > 0 { pill("\(counts.needFolder) need a folder", accent: false) }
			if counts.failed > 0 { pill("\(counts.failed) not restored", accent: false) }
		}
	}

	static func counts(_ items: [BackupRestoreResult.Item]) -> (restored: Int, merged: Int, skipped: Int, needFolder: Int, failed: Int) {
		var counts = (restored: 0, merged: 0, skipped: 0, needFolder: 0, failed: 0)
		for item in items {
			switch item.outcome {
			case .restored(_, _, let needsFolder):
				counts.restored += 1
				if needsFolder { counts.needFolder += 1 }
			case .merged: counts.merged += 1
			case .identical, .notChosen: counts.skipped += 1
			case .unusable, .changedSinceReview, .failed: counts.failed += 1
			}
		}
		return counts
	}

	private func resultLine(_ item: BackupRestoreResult.Item) -> some View {
		let (detail, badge, ok) = Self.describe(item.outcome)
		return HStack(spacing: 10) {
			Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
				.foregroundStyle(ok ? VaultPalette.green : VaultPalette.textFaint)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				Text(item.name.escapingDirectionControls)
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textPrimary)
				Text(detail)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 8)
			VaultTagBadge(text: badge.uppercased(), foreground: VaultPalette.textSecondary, background: VaultPalette.neutralTint)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.accessibilityElement(children: .combine)
	}

	/// What happened to a project, as the summary says it.
	static func describe(_ outcome: BackupRestoreOutcome) -> (detail: String, badge: String, ok: Bool) {
		switch outcome {
		case .restored(let keys, let environments, let needsFolder):
			("Restored · \(keys.counted("key")) · \(environments.counted("env"))" + (needsFolder ? " · needs a folder" : ""), "Restored", true)
		case .merged(let added, let replaced):
			("Merged · \(added.counted("key")) added, \(replaced) replaced", "Merged", true)
		case .identical: ("Identical to this Mac", "Skipped", true)
		case .notChosen: ("Not chosen", "Skipped", true)
		case .unusable(let reason): (reason, "Not restored", false)
		case .changedSinceReview: ("It changed on this Mac after the review, so it was left as it is. Restore again to review it.", "Not restored", false)
		case .failed(let reason): (reason, "Not restored", false)
		}
	}

	// MARK: - Actions

	private func pickFile() {
		guard let url = chooseFile() else { return }
		use(url)
	}

	private func use(_ url: URL) {
		guard phase == .choosing else { return }
		file = url
		openError = nil
		let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
		fileDetail = [
			values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
			values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened),
		].compactMap { $0 }.joined(separator: " · ")
		passphraseFocused = true
	}

	private func open() {
		guard let file, !passphrase.isEmpty, phase == .choosing else { return }
		openError = nil
		phase = .opening
		let passphrase = passphrase
		task = Task {
			defer { task = nil }
			do {
				let opened = try await store.openBackup(at: file, passphrase: passphrase)
				guard !Task.isCancelled else { return }
				self.passphrase = ""
				review = opened
				choices = .defaults(for: opened.plan, hasLocalProjects: !store.projects.isEmpty)
				phase = .reviewing
				await suggestFolders(for: opened.plan)
			} catch let failure as BackupRestoreFailure {
				openError = failure.message
				phase = .choosing
			} catch {
				phase = .choosing
			}
		}
	}

	/// Offers each new project's backup folder where its lpm.json links that project.
	private func suggestFolders(for plan: BackupRestorePlan) async {
		let candidates = plan.projects.compactMap { project -> (String, String)? in
			guard project.status == .new, !project.backup.hidden, let folder = project.backup.folder else { return nil }
			return (project.id, folder)
		}
		let linked = await BlockingWork.run {
			candidates.filter { ProjectCLILink.inspect(vaultId: $0.0, folder: $0.1).status == .linked }
		}
		for (id, folder) in linked { suggestedFolders[id] = folder }
	}

	private func pickFolder(for project: BackupRestorePlan.Project) {
		guard let url = chooseFolder(project.backup.folder) else { return }
		let id = project.id
		let path = url.path
		Task {
			let status = await BlockingWork.run { ProjectCLILink.inspect(vaultId: id, folder: path).status }
			switch status {
			case .linked:
				choices.folders[id] = path
				folderErrors[id] = nil
			case .linkedToOtherVault:
				folderErrors[id] = "That folder’s lpm.json links another project."
			case .notLinked, .noFolder, .unreadable:
				folderErrors[id] = "That folder’s lpm.json doesn’t link this project. Link it later from Connect CLI."
			}
		}
	}

	private func restore() {
		guard let review, phase == .reviewing else { return }
		let choices = choices
		finished = []
		phase = .restoring
		task = Task {
			defer { task = nil }
			do {
				let result = try await store.restoreBackup(review, choices: choices) { finished.append($0) }
				if let settings = result.settings { applySettings(settings) }
				self.result = result
				phase = .finished
			} catch {
				phase = finished.isEmpty ? .reviewing : .finished
			}
		}
	}

	private func discard() {
		task?.cancel()
		task = nil
		passphrase = ""
		review = nil
	}

	private func close() {
		discard()
		dismiss()
	}

	static func madeOn(_ contents: BackupContents) -> String {
		let date = contents.createdAt.formatted(date: .abbreviated, time: .shortened)
		if let device = contents.deviceName { return "Made on \(device.escapingDirectionControls), \(date)" }
		return "Made \(date)"
	}

	static func abbreviated(_ path: String) -> String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
	}

	@MainActor
	static func runOpenPanel() -> URL? {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "lpmbackup") ?? .data]
		panel.allowsMultipleSelection = false
		panel.message = "Choose a backup to restore"
		return panel.runModal() == .OK ? panel.url : nil
	}

	@MainActor
	static func runFolderPanel(_ suggested: String?) -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.message = "Choose the project’s folder"
		if let suggested { panel.directoryURL = URL(fileURLWithPath: suggested, isDirectory: true).deletingLastPathComponent() }
		return panel.runModal() == .OK ? panel.url : nil
	}
}

/// The restore sheet, applying the settings the store doesn't own through
/// the window's settings objects.
struct VaultBackupRestorePresentation: View {
	let store: VaultStore
	@Environment(VaultAppearanceSettings.self) private var appearance
	@Environment(VaultQuitSettings.self) private var quit
	@Environment(UpdateChecker.self) private var updates

	var body: some View {
		BackupRestoreSheet(store: store) { settings in
			appearance.selection = settings.appearance
			quit.selection = settings.quitShortcut
			updates.channel = settings.updateChannel
		}
	}
}
