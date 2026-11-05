import SwiftUI

/// The History page: how a project's values changed on this Mac.
struct VaultHistoryView: View {
	let store: VaultStore
	let project: VaultProject
	@Environment(\.vaultContentObscured) private var obscured
	@State private var keySearch = ""
	@State private var searchTask: Task<Void, Never>?

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: Date()) }

	var body: some View {
		VStack(spacing: 0) {
			header
			if history.state?.history != "off" {
				filters
				VaultHairline()
			}
			banners
			content
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.overlay(alignment: .bottom) {
					rollbackToast.padding(.bottom, 14)
				}
			if let timeline = history.timeline, history.state?.history != "off" {
				VaultHairline()
				Text(text.status(timeline))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 20)
					.frame(height: VaultMetrics.statusBar)
			}
		}
		.background(VaultPalette.content)
		.task(id: project.id) { await history.open(project.id) }
		.onChange(of: obscured) { _, covered in if covered { history.hideRevealed() } }
		.onDisappear { searchTask?.cancel() }
	}

	// MARK: - Header and filters

	private var header: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("History")
				.font(.system(size: 20, weight: .bold))
				.foregroundStyle(VaultPalette.textPrimary)
				.accessibilityAddTraits(.isHeader)
			Text("Changes to \(project.name)’s values on this Mac")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.top, 14)
		.padding(.bottom, 10)
	}

	private var filters: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				environmentMenu
				if let key = history.filter.exactKey {
					VaultFilterChip(title: key, symbol: "key", trailing: "×", selected: true) {
						history.filter.exactKey = nil
						Task { await history.reload() }
					}
					.help("Show every key again")
					.accessibilityLabel("Key \(key), remove filter")
				}
				HStack(spacing: 6) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.accessibilityHidden(true)
					TextField("Key name", text: $keySearch)
						.textFieldStyle(.plain)
						.font(.system(size: 12.5))
						.accessibilityLabel("Key name")
						.onChange(of: keySearch) { _, value in search(value) }
				}
				.padding(.horizontal, 9)
				.frame(width: 220, height: 28)
				.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.control))
				.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
				Spacer(minLength: 0)
			}
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 6) {
					ForEach(VaultHistoryText.sources, id: \.1) { source, title in
						VaultFilterChip(
							title: title,
							trailing: count(source).map(String.init),
							selected: history.filter.source == source
						) {
							history.filter.source = source
							Task { await history.reload() }
						}
						.accessibilityLabel(count(source).map { "\(title), \($0)" } ?? title)
					}
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.bottom, 10)
	}

	private var environmentMenu: some View {
		Menu {
			Button("All environments") { setEnvironment(nil) }
			if let environments = history.timeline?.environments, !environments.isEmpty {
				Divider()
				ForEach(environments, id: \.name) { environment in
					Button(environment.deletedAt == nil ? environment.name : "\(environment.name) (deleted)") {
						setEnvironment(environment.name)
					}
				}
			}
		} label: {
			Text(history.filter.environment ?? "All environments")
				.font(.system(size: 12.5))
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.padding(.horizontal, 9)
		.frame(height: 28)
		.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.control))
		.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
		.accessibilityLabel("Environment, \(history.filter.environment ?? "All environments")")
	}

	private func count(_ source: VaultLocalHistory.Source?) -> Int? {
		guard let counts = history.timeline?.counts else { return nil }
		guard let source else { return counts.values.reduce(0, +) }
		return counts[source.rawValue] ?? 0
	}

	private func setEnvironment(_ name: String?) {
		history.filter.environment = name
		Task { await history.reload() }
	}

	/// Reads history again once typing pauses, not on every keystroke.
	private func search(_ value: String) {
		searchTask?.cancel()
		searchTask = Task {
			try? await Task.sleep(for: .milliseconds(250))
			guard !Task.isCancelled else { return }
			history.filter.keyContains = value
			await history.reload()
		}
	}

	// MARK: - Banners

	@ViewBuilder
	private var banners: some View {
		if let notRecorded = history.notRecorded[project.id] {
			banner(
				"This change wasn’t added to local history: \(notRecorded.message)", detail: nil,
				action: ("Dismiss", { history.dismissNotRecorded(project.id) }))
		}
		if let paused = pausedMessage {
			banner(paused, detail: nil, action: nil)
		}
		if let crowded = history.crowded {
			banner(text.crowded(crowded), detail: nil, action: nil)
		}
		if let timeline = history.timeline {
			if timeline.unreadableParts > 0 || timeline.damagedTail {
				banner("Part of this project’s history couldn’t be read.", detail: nil, action: ("Try Again", { Task { await history.reload() } }))
			}
			if let gap = timeline.liveGap {
				let keys = gap.environments.flatMap(\.keys)
				let since = gap.since.map { " \(text.since(VaultHistoryText.date($0)))" } ?? ""
				banner(
					"Changed outside local history\(since)\(keys.isEmpty ? "" : " · " + keys.joined(separator: " · "))",
					detail: "An LPM CLI or LPM Vault that doesn’t record history made this change, or a change was interrupted.",
					action: nil)
			}
		}
	}

	private var pausedMessage: String? {
		switch history.state?.history {
		case "unsupported", "removing": "Recorded by a newer version of LPM. Update LPM Vault to see it."
		case "both": "Paused — this project’s history is damaged."
		default: (history.state?.damage.isEmpty == false) ? "Paused — this project’s history is damaged." : nil
		}
	}

	// MARK: - Undo

	@ViewBuilder
	private var rollbackToast: some View {
		if let applied = history.applied, applied.projectID == project.id {
			VaultToast(hasButton: applied.undo == .available || applied.undo == .undoing) {
				switch applied.undo {
				case .available, .undoing:
					Image(systemName: "checkmark")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.toastConfirmation)
						.accessibilityHidden(true)
					Text(applied.keys == 0
						? (applied.isUndo ? "Undid the change" : "Rolled back")
						: "\(applied.isUndo ? "Undid" : "Rolled back") \(applied.keys.counted("key"))")
					Button {
						Task { await history.undoApplied() }
					} label: {
						Label(applied.undo == .undoing ? "Undoing…" : "Undo", systemImage: "arrow.uturn.backward")
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(VaultPalette.toastAction)
					}
					.buttonStyle(.plain)
					.vaultPointingHand()
					.disabled(applied.undo == .undoing)
					.help(applied.isUndo ? "Put back what the undo replaced" : "Put back what the rollback replaced")
					Rectangle()
						.fill(VaultPalette.toastDivider)
						.frame(width: 1, height: 16)
						.accessibilityHidden(true)
					TimelineView(.periodic(from: applied.savedAt, by: 1)) { context in
						let left = max(0, VaultFeedbackTimer.undoSeconds - Int(context.date.timeIntervalSince(applied.savedAt)))
						Text("\(left)s")
							.font(VaultTypography.tabular(11))
							.foregroundStyle(VaultPalette.toastSecondaryText)
							.accessibilityLabel("\(left) seconds left to undo")
					}
				case .undone:
					Image(systemName: "arrow.uturn.backward")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.toastConfirmation)
						.accessibilityHidden(true)
					Text("Put the values back as they were")
				case .reviewing:
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.orange)
						.accessibilityHidden(true)
					Text("Not everything can be put back exactly, so review the undo")
				case .failed(let message):
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.orange)
						.accessibilityHidden(true)
					Text(message)
				}
			}
		}
	}

	private func banner(_ title: String, detail: String?, action: (String, () -> Void)?) -> some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: "exclamationmark.triangle")
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(VaultPalette.orange)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.system(size: 12.5, weight: .semibold))
					.foregroundStyle(VaultPalette.orangeTintText)
				if let detail {
					Text(detail)
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.orangeTintText)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			if let action {
				Button(action.0, action: action.1)
					.controlSize(.small)
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 10)
		.background(VaultPalette.orangeTint)
		.accessibilityElement(children: .combine)
	}

	// MARK: - Content

	@ViewBuilder
	private var content: some View {
		switch history.phase {
		case .idle:
			reading
		case .loading where history.timeline == nil && history.state == nil:
			reading
		case .failed(let message):
			empty("Local history couldn’t be read", detail: message, action: ("Try Again", { Task { await history.reload() } }))
		default:
			if history.state?.history == "off" {
				empty(
					"Local history is off for \(project.name)",
					detail: "Turn it on to keep a record of value changes on this Mac. It starts with the next change.",
					action: ("Turn On", { Task { _ = await history.setEnabled(true, projectID: project.id) } }))
			} else if let timeline = history.timeline, !timeline.rows.isEmpty {
				timelineList(timeline)
			} else if history.timeline != nil {
				empty("No changes match", detail: "Try another environment, key or source.", action: nil)
			} else {
				empty("No changes kept yet", detail: "History starts with the next change to a value in \(project.name).", action: nil)
			}
		}
	}

	private var reading: some View {
		ProgressView()
			.controlSize(.small)
			.accessibilityLabel("Reading local history")
	}

	private func empty(_ title: String, detail: String, action: (String, () -> Void)?) -> some View {
		VStack(spacing: 8) {
			Image(systemName: "clock.arrow.circlepath")
				.font(.system(size: 26, weight: .light))
				.foregroundStyle(VaultPalette.textTertiary)
				.accessibilityHidden(true)
			Text(title)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
			Text(detail)
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 360)
			if let action {
				Button(action.0, action: action.1)
					.padding(.top, 4)
			}
		}
		.padding(24)
	}

	private func timelineList(_ timeline: HistoryEngine.Timeline) -> some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
				ForEach(days(timeline.rows), id: \.title) { day in
					Section {
						ForEach(day.rows) { row in
							rowView(row)
							VaultHairline()
						}
					} header: {
						Text(day.title.uppercased(with: Locale.current))
							.font(VaultTypography.sectionLabel)
							.tracking(0.6)
							.foregroundStyle(VaultPalette.textTertiary)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.horizontal, 20)
							.padding(.vertical, 6)
							.background(VaultPalette.headerRow)
							.accessibilityAddTraits(.isHeader)
					}
				}
			}
		}
	}

	private struct Row: Identifiable {
		let id: String
		let row: HistoryEngine.Row
	}

	private struct Day {
		let title: String
		var rows: [Row]
	}

	private func days(_ rows: [HistoryEngine.Row]) -> [Day] {
		var days: [Day] = []
		for (index, row) in rows.enumerated() {
			let time: Int64
			let id: String
			switch row {
			case .entry(let entry): (time, id) = (entry.time, entry.id)
			case .unreadable(let part, let after, let before): (time, id) = (before ?? after ?? 0, "unreadable-\(part)-\(index)")
			}
			let title = text.day(VaultHistoryText.date(time))
			if days.last?.title == title {
				days[days.count - 1].rows.append(Row(id: id, row: row))
			} else {
				days.append(Day(title: title, rows: [Row(id: id, row: row)]))
			}
		}
		return days
	}

	@ViewBuilder
	private func rowView(_ row: Row) -> some View {
		switch row.row {
		case .entry(let entry):
			entryRow(entry)
		case .unreadable(_, let after, let before):
			let bounds = [after, before].compactMap { $0 }.map { text.dayAndMonth(VaultHistoryText.date($0)) }
			HStack(spacing: 12) {
				Image(systemName: "exclamationmark.triangle")
					.foregroundStyle(VaultPalette.orange)
					.frame(width: 60, alignment: .leading)
					.accessibilityHidden(true)
				Text("Part of this project’s history couldn’t be read\(bounds.count == 2 ? " · \(bounds[0]) to \(bounds[1])" : "")")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.orangeTintText)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 12)
			.background(VaultPalette.orangeTint)
			.accessibilityElement(children: .combine)
		}
	}

	private func entryRow(_ entry: HistoryEngine.Entry) -> some View {
		let selected = history.selectedEntryID == entry.id
		let badge = VaultHistoryText.badge(entry)
		let description = text.describe(entry) { id in history.entries.first { $0.id == id } }
		let keys = VaultHistoryText.keys(entry)
		let shownKeys = Array(keys.prefix(3))
		let time = text.clock(VaultHistoryText.date(entry.time))
		let environments = entry.environments.map(\.name)
		return Button {
			history.select(selected ? nil : entry.id)
		} label: {
			HStack(alignment: .center, spacing: 12) {
				Text(time)
					.font(VaultTypography.tabular(12.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.frame(width: 52, alignment: .leading)
				Group {
					if badge.warns {
						Label(badge.text, systemImage: "exclamationmark.triangle")
							.font(.system(size: 10.5, weight: .bold))
							.foregroundStyle(badge.foreground)
							.labelStyle(.titleAndIcon)
					} else {
						VaultTagBadge(text: badge.text, foreground: badge.foreground, background: badge.background)
					}
				}
				.frame(width: 88, alignment: .leading)
				VStack(alignment: .leading, spacing: 4) {
					Text(description)
						.font(.system(size: 12.5))
						.foregroundStyle(badge.warns ? VaultPalette.orangeTintText : VaultPalette.textPrimary)
						.lineLimit(1)
					HStack(spacing: 6) {
						ForEach(environments.prefix(2), id: \.self) { name in environmentChip(name) }
						if environments.count > 2 {
							Text("+\(environments.count - 2) envs")
								.font(.system(size: 11))
								.foregroundStyle(VaultPalette.textTertiary)
						}
						Text(shownKeys.joined(separator: " · "))
							.font(VaultTypography.tabular(11.5))
							.foregroundStyle(VaultPalette.textSecondary)
							.lineLimit(1)
						if keys.count > shownKeys.count {
							Text("+\(keys.count - shownKeys.count) more")
								.font(.system(size: 11))
								.foregroundStyle(VaultPalette.textTertiary)
						}
					}
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 9)
			.background(selected ? VaultPalette.rowSelected : (badge.warns ? VaultPalette.orangeTint : .clear))
			.overlay(alignment: .leading) {
				if selected { Rectangle().fill(VaultPalette.accent).frame(width: 3) }
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("\(time), \(badge.text), \(description)\(environments.isEmpty ? "" : " in " + environments.joined(separator: ", "))")
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private func environmentChip(_ name: String) -> some View {
		VaultHistoryEnvironmentChip(name, in: store.orderedEnvironmentNames(for: project))
	}
}
