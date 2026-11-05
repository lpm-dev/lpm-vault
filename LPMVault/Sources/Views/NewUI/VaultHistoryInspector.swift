import SwiftUI

/// One history entry in the inspector: what changed in each environment,
/// with past values masked until revealed, and what can be done with it.
struct VaultHistoryInspector: View {
	let store: VaultStore
	let project: VaultProject
	@Environment(\.vaultContentObscured) private var obscured
	@State private var failure: String?

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: Date()) }

	var body: some View {
		VStack(spacing: 0) {
			if let entry = history.selectedEntry {
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						header(entry)
						VaultHairline()
						ForEach(Array(entry.environments.enumerated()), id: \.offset) { index, environment in
							environmentSection(entry, environment: environment, index: index)
						}
						if let failure {
							Text(failure)
								.font(.system(size: 12))
								.foregroundStyle(VaultPalette.redText)
								.padding(16)
						}
					}
				}
				VaultHairline()
				footer(entry)
			}
		}
		.background(VaultPalette.inspector)
		.onChange(of: history.selectedEntryID) { _, _ in failure = nil }
	}

	private func header(_ entry: HistoryEngine.Entry) -> some View {
		let badge = VaultHistoryText.badge(entry)
		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("CHANGE")
					.font(VaultTypography.sectionLabel)
					.tracking(0.6)
					.foregroundStyle(VaultPalette.textTertiary)
				Spacer()
				Button {
					history.select(nil)
				} label: {
					Image(systemName: "xmark")
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Close change details")
			}
			Text(text.describe(entry) { id in history.entries.first { $0.id == id } })
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
				.fixedSize(horizontal: false, vertical: true)
			Text(text.full(VaultHistoryText.date(entry.time)))
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
			HStack(spacing: 6) {
				VaultTagBadge(text: badge.text, foreground: badge.foreground, background: badge.warns ? VaultPalette.orangeTint : badge.background)
				if let detail = detail(entry) {
					Text(detail)
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textSecondary)
				}
			}
		}
		.padding(16)
	}

	/// "lpm.dev · acme · v14", ".env.local", "Pasted text".
	private func detail(_ entry: HistoryEngine.Entry) -> String? {
		switch entry.action {
		case "pull", "projectImport":
			var parts = ["lpm.dev"]
			if case .org(let slug)? = entry.remote { parts.append(slug) }
			if let version = entry.remoteVersion { parts.append("v\(version)") }
			return parts.joined(separator: " · ")
		case "platformPull":
			return VaultHistoryText.platform(entry.platform)
		default:
			if let file = entry.fileName { return file }
			return entry.pasted ? "Pasted text" : nil
		}
	}

	private func environmentSection(_ entry: HistoryEngine.Entry, environment: HistoryEngine.EnvironmentChange, index: Int) -> some View {
		let ordered = store.orderedEnvironmentNames(for: project)
		let color = ordered.firstIndex(of: environment.name).map { VaultPalette.environment($0) } ?? VaultPalette.textTertiary
		let keys = environment.keys ?? []
		return VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 6) {
				VaultEnvSwatch(color: color, size: 8)
				Text(environment.name)
					.font(.system(size: 12.5, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("· \((environment.keyCount ?? keys.count).counted("key"))")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
				if let note = environmentNote(environment) {
					Text(note)
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textSecondary)
				}
			}
			.accessibilityElement(children: .combine)
			if keys.isEmpty, let count = environment.keyCount {
				Text("Too large to keep: this change touched \(count.counted("key")).")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
			}
			ForEach(Array(keys.enumerated()), id: \.offset) { keyIndex, change in
				keyChange(entry, environment: environment, environmentIndex: index, change: change, keyIndex: keyIndex)
			}
		}
		.padding(16)
		.overlay(alignment: .bottom) { VaultHairline() }
	}

	private func environmentNote(_ environment: HistoryEngine.EnvironmentChange) -> String? {
		switch environment.change {
		case "created": "created"
		case "removed": "deleted"
		case "renamed": environment.renamedFrom.map { "renamed from \($0)" }
		default: nil
		}
	}

	private func keyChange(
		_ entry: HistoryEngine.Entry,
		environment: HistoryEngine.EnvironmentChange,
		environmentIndex: Int,
		change: HistoryEngine.KeyChange,
		keyIndex: Int
	) -> some View {
		let revealed = history.revealed[entry.id].flatMap { revealed in
			revealed.environments.indices.contains(environmentIndex) && revealed.environments[environmentIndex].indices.contains(keyIndex)
				? revealed.environments[environmentIndex][keyIndex] : nil
		}
		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(change.key)
					.font(VaultTypography.tabular(12.5, .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
				Spacer()
				VaultTagBadge(text: kindTitle(change), foreground: kindForeground(change), background: kindBackground(change))
			}
			if change.renamedFrom != nil || change.change != "added" {
				side("Before", kind: change.before, value: revealed?.before, entry: entry, environment: environment.name, key: change.key, sideName: "before")
			}
			if change.change != "removed" {
				side("After", kind: change.after, value: revealed?.after, entry: entry, environment: environment.name, key: change.key, sideName: "after")
			}
		}
	}

	private func kindTitle(_ change: HistoryEngine.KeyChange) -> String {
		switch change.change {
		case "added": "Added"
		case "removed": "Removed"
		case "renamed": "Renamed"
		default: "Changed"
		}
	}

	private func kindForeground(_ change: HistoryEngine.KeyChange) -> Color {
		switch change.change {
		case "added": VaultPalette.greenTintText
		case "removed": VaultPalette.redText
		default: VaultPalette.accentText
		}
	}

	private func kindBackground(_ change: HistoryEngine.KeyChange) -> Color {
		switch change.change {
		case "added": VaultPalette.greenTint
		case "removed": VaultPalette.redTint
		default: VaultPalette.accentTint
		}
	}

	/// One side of a change: masked until revealed, or why it can't be shown.
	private func side(
		_ title: String,
		kind: String,
		value: String?,
		entry: HistoryEngine.Entry,
		environment: String,
		key: String,
		sideName: String
	) -> some View {
		let unknown = VaultHistoryText.unknownSide(kind, of: entry)
		let absent = kind == "absent"
		let shown = value != nil && !obscured
		let content: VaultHistoryValueField.Content =
			if let unknown { .unknown(unknown) } else if absent { .absent } else if shown, let value { .shown(value) } else { .hidden }
		let side = title.lowercased()
		return HStack(spacing: 4) {
			Text(title)
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
				.frame(width: 44, alignment: .leading)
				.accessibilityHidden(true)
			VaultHistoryValueField(content: content, label: "\(title) value of \(key)")
			if unknown == nil && !absent {
				VaultRowIconButton(
					systemImage: shown ? "eye.slash" : "eye",
					help: shown ? "Hide the \(side) value of \(key)" : "Reveal the \(side) value of \(key)",
					disabled: obscured, compact: true
				) {
					if shown { history.hideRevealed() } else { Task { await history.reveal(entry.id) } }
				}
				VaultRowIconButton(systemImage: "doc.on.doc", help: "Copy the \(side) value of \(key)", disabled: obscured, compact: true) {
					Task { await copy(entry: entry, environment: environment, key: key, sideName: sideName) }
				}
				Menu {
					Button("Remove from History…") {
						Task { await reviewRemoval(entry: entry, environment: environment, key: key, side: sideName) }
					}
				} label: {
					Image(systemName: "ellipsis")
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.menuStyle(.borderlessButton)
				.menuIndicator(.hidden)
				.fixedSize()
				.help("More for the \(side) value of \(key)")
				.accessibilityLabel("More for the \(side) value of \(key)")
			}
		}
		.contextMenu {
			if unknown == nil && !absent {
				Button("Remove from History…") {
					Task { await reviewRemoval(entry: entry, environment: environment, key: key, side: sideName) }
				}
			}
		}
	}

	private func footer(_ entry: HistoryEngine.Entry) -> some View {
		VStack(spacing: 8) {
			Button {
				Task { await review(.environment(rollbackEnvironment(entry), entry: entry.id, side: "after")) }
			} label: {
				Label("Roll Back to This Point…", systemImage: "arrow.uturn.backward")
					.frame(maxWidth: .infinity)
			}
			.disabled(entry.environments.isEmpty)
			Button {
				Task { await review(.undo(entry: entry.id, only: nil)) }
			} label: {
				Label("Undo This Change…", systemImage: "arrow.uturn.backward.circle")
					.frame(maxWidth: .infinity)
			}
		}
		.controlSize(.large)
		.padding(16)
	}

	/// The environment Roll Back to This Point… opens on: the page's filter
	/// when the entry touched it, else the entry's first.
	private func rollbackEnvironment(_ entry: HistoryEngine.Entry) -> String {
		let names = entry.environments.map(\.name)
		if let filtered = history.filter.environment, names.contains(filtered) { return filtered }
		return names.first ?? ""
	}

	private func review(_ target: HistoryEngine.RollbackTarget) async {
		failure = await history.reviewRollback(target, in: project.id, entry: history.selectedEntry)?.description
	}

	private func reviewRemoval(entry: HistoryEngine.Entry, environment: String, key: String, side: String) async {
		failure = await history.reviewRemoval(entry: entry.id, environment: environment, key: key, side: side)?.description
	}

	private func copy(entry: HistoryEngine.Entry, environment: String, key: String, sideName: String) async {
		await history.reveal(entry.id)
		guard let value = history.revealedValue(entry: entry.id, environment: environment, key: key, side: sideName) else { return }
		store.clipboard.copy(value)
	}
}
