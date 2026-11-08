import SwiftUI

/// One history entry in the inspector: what changed in each environment,
/// with past values masked until revealed, and what can be done with it.
struct VaultHistoryInspector: View {
	let store: VaultStore
	let project: VaultProject
	@Environment(\.vaultContentObscured) private var obscured
	@Environment(\.vaultClock) private var clock
	@State private var failure: String?
	/// The value whose More menu is showing.
	@State private var openMenu: String?

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: clock.now()) }

	var body: some View {
		VStack(spacing: 0) {
			if let entry = history.selectedEntry {
				// The actions follow a short change directly, and stay in reach below a long one.
				ViewThatFits(in: .vertical) {
					VStack(alignment: .leading, spacing: 0) {
						details(entry)
						VaultHairline()
						footer(entry)
						Spacer(minLength: 0)
					}
					VStack(spacing: 0) {
						ScrollView {
							details(entry).padding(.bottom, VaultMetrics.scrollEndPadding)
						}
						VaultHairline()
						footer(entry)
					}
				}
			}
		}
		.background(VaultPalette.inspector)
		.onChange(of: history.selectedEntryID) { _, _ in failure = nil }
	}

	private func details(_ entry: HistoryEngine.Entry) -> some View {
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
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func header(_ entry: HistoryEngine.Entry) -> some View {
		let badge = VaultHistoryText.badge(entry)
		// The header every inspector has: what it shows and closing; the title; where it's from.
		return VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 4) {
				Text("CHANGE").vaultSectionLabel()
				Spacer(minLength: 4)
				VaultRowIconButton(systemImage: "xmark", help: "Close change details", compact: true) {
					history.select(nil)
				}
			}
			Text(text.describe(entry) { id in history.entry(id) })
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(badge.warns ? VaultPalette.orangeTintText : VaultPalette.textPrimary)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 4)
			Text(([text.full(VaultHistoryText.date(entry.time)), badge.text] + [detail(entry)].compactMap { $0 }).joined(separator: " · "))
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 2)
		}
		.padding(.horizontal, 16)
		.padding(.top, 12)
		.padding(.bottom, 14)
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
				Text(VaultProject.displayName(for: environment.name))
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
		let before = VaultLocalHistory.Side(entry: entry.id, environment: environmentIndex, key: keyIndex, side: "before")
		let after = VaultLocalHistory.Side(entry: entry.id, environment: environmentIndex, key: keyIndex, side: "after")
		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(change.key)
					.font(VaultTypography.tabular(12.5, .medium))
					.foregroundStyle(VaultPalette.textPrimary)
				Spacer()
				VaultTagBadge(text: kindTitle(change), foreground: kindForeground(change), background: kindBackground(change))
			}
			if change.renamedFrom != nil || change.change != "added" {
				side("Before", kind: change.before, side: before, entry: entry, environment: environment.name, key: change.key)
			}
			if change.change != "removed" {
				side("After", kind: change.after, side: after, entry: entry, environment: environment.name, key: change.key)
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
		default: VaultPalette.textSecondary
		}
	}

	private func kindBackground(_ change: HistoryEngine.KeyChange) -> Color {
		switch change.change {
		case "added": VaultPalette.greenTint
		case "removed": VaultPalette.redTint
		default: VaultPalette.neutralTint
		}
	}

	/// One side of a change: masked until revealed, or why it can't be shown.
	private func side(
		_ title: String,
		kind: String,
		side valueSide: VaultLocalHistory.Side,
		entry: HistoryEngine.Entry,
		environment: String,
		key: String
	) -> some View {
		let unknown = VaultHistoryText.unknownSide(kind, of: entry)
		let absent = kind == "absent"
		let value = history.shown.contains(valueSide) ? history.value(of: valueSide) : nil
		let shown = value != nil && !obscured
		let sideName = valueSide.side
		let content: VaultHistoryValueField.Content =
			if let unknown { .unknown(unknown) } else if absent { .absent } else if shown, let value { .shown(value) } else { .hidden }
		let side = title.lowercased()
		let hasValue = unknown == nil && !absent
		return HStack(spacing: 8) {
			Text(title)
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
				.frame(width: 44, alignment: .leading)
				.accessibilityHidden(true)
			// The controls sit inside the value's box, as in the key inspector.
			HStack(spacing: 0) {
				VaultHistoryValueField(content: content, label: "\(title) value of \(key)", chromeless: hasValue)
				if hasValue {
					VaultRowIconButton(
						systemImage: shown ? "eye.slash" : "eye",
						help: shown ? "Hide the \(side) value of \(key)" : "Reveal the \(side) value of \(key)",
						disabled: obscured, compact: true
					) {
						if shown { history.hide(valueSide) } else { Task { await history.show(valueSide) } }
					}
					// Every control shows at rest, as in the key inspector, so the box's end never looks empty.
					VaultRowIconButton(systemImage: "doc.on.doc", help: "Copy the \(side) value of \(key)", disabled: obscured, compact: true, quiet: true) {
						Task { await copy(valueSide) }
					}
					let menuID = "\(environment)\u{0}\(key)\u{0}\(sideName)"
					VaultRowIconButton(systemImage: "ellipsis", help: "More for the \(side) value of \(key)", compact: true,
						active: openMenu == menuID, quiet: true) {
						openMenu = openMenu == menuID ? nil : menuID
					}
					.vaultMenu(isPresented: Binding(get: { openMenu == menuID }, set: { if !$0, openMenu == menuID { openMenu = nil } }),
						rows: [VaultMenuList<Int>.Row(id: 0, title: "Remove from History…", destructive: true)],
						width: 220, label: "More for the \(side) value of \(key)") { _ in
						Task { await reviewRemoval(entry: entry, environment: environment, key: key, side: sideName) }
					}
				}
			}
			.padding(.leading, hasValue ? 8 : 0)
			.padding(.trailing, hasValue ? 2 : 0)
			// A past value is read, not typed in, so it sits in a well rather than a field's box.
			.background {
				if hasValue {
					RoundedRectangle(cornerRadius: 6).fill(VaultPalette.codeBlock)
						.overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(VaultPalette.divider, lineWidth: 1) }
				}
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

	/// Both ways back open a review, which holds the one filled button, so neither looks like the safe default here.
	private func footer(_ entry: HistoryEngine.Entry) -> some View {
		// The narrower action first: it touches only this change.
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 6) {
				VaultBarButton(systemImage: "arrow.uturn.backward", title: "Undo This Change…", height: 30, fillsWidth: true) {
					Task { await review(.undo(entry: entry.id, only: nil)) }
				}
				footerNote("Reverses only this change and keeps the ones after it.")
			}
			VStack(alignment: .leading, spacing: 6) {
				VaultBarButton(systemImage: "clock.arrow.circlepath", title: "Roll Back to This Point…",
					disabled: entry.environments.isEmpty, height: 30, fillsWidth: true) {
					Task { await review(rollbackTarget(entry)) }
				}
				footerNote("Restores the values as they were just after this change, undoing every later one.")
			}
		}
		.padding(16)
	}

	private func footerNote(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 11))
			.foregroundStyle(VaultPalette.textTertiary)
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityHidden(true)
	}

	/// What Roll Back to This Point… opens on: the environment the page is
	/// filtered to, by its name now, since the entry may name it as it was
	/// before a rename; else the entry's first environment, as the entry names it.
	private func rollbackTarget(_ entry: HistoryEngine.Entry) -> HistoryEngine.RollbackTarget {
		if let filtered = history.filter.environment {
			return .environment(filtered, entry: entry.id, side: "after", namedNow: true)
		}
		return .environment(entry.environments.first?.name ?? "", entry: entry.id, side: "after")
	}

	private func review(_ target: HistoryEngine.RollbackTarget) async {
		failure = await history.reviewRollback(target, in: project.id, entry: history.selectedEntry)?.description
	}

	private func reviewRemoval(entry: HistoryEngine.Entry, environment: String, key: String, side: String) async {
		failure = await history.reviewRemoval(entry: entry.id, environment: environment, key: key, side: side)?.description
	}

	/// Copies a value without showing it; covering the window while it's
	/// read copies nothing.
	private func copy(_ side: VaultLocalHistory.Side) async {
		guard let value = await history.valueToCopy(side) else { return }
		store.clipboard.copy(value)
	}
}
