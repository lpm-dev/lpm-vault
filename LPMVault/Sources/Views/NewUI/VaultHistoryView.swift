import SwiftUI

/// The History page: how a project's values changed on this Mac.
struct VaultHistoryView: View {
	let store: VaultStore
	let project: VaultProject
	@Environment(\.vaultContentObscured) private var obscured
	@Environment(\.vaultClock) private var clock
	@State private var keySearch = ""
	@FocusState private var keySearchFocused: Bool
	@State private var searchTask: Task<Void, Never>?

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: clock.now()) }

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
		// A request to show this project again, filtered: a request for
		// another project changes `project`, which the task above follows.
		.onChange(of: history.showRequest) { _, _ in
			searchTask?.cancel()
			if history.projectID == project.id { Task { await history.open(project.id) } }
		}
		// The field follows the filter when opening a project or a request to
		// show one sets it.
		.onChange(of: history.filter.keyContains) { _, value in
			if keySearch != value { keySearch = value }
		}
		// A pull, a sync or the LPM CLI changed the values while the page shows.
		.onChange(of: project.environments) { _, _ in
			if history.projectID == project.id { Task { await history.reload() } }
		}
		.onChange(of: obscured) { _, covered in if covered { history.hideRevealed() } }
		.onDisappear { searchTask?.cancel() }
	}

	// MARK: - Header and filters

	private var header: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Text("History")
				.vaultPageTitle()
				.accessibilityAddTraits(.isHeader)
			Text("Changes to \(project.name)’s values on this Mac")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 20)
		.frame(height: 60)
	}

	/// Where, from what and which key, in one row: the sources are a menu,
	/// since most of them are empty for most projects.
	private var filters: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				environmentMenu
				sourceMenu
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
					TextField(vaultPrompt: "Key name", text: $keySearch)
						.textFieldStyle(.plain)
						.font(.system(size: 12.5))
						.focused($keySearchFocused)
						.accessibilityLabel("Key name")
						.onChange(of: keySearch) { _, value in search(value) }
				}
				.padding(.horizontal, 10)
				.frame(width: 220, height: 28)
				.vaultSearchField(focused: keySearchFocused)
				Spacer(minLength: 0)
			}
		}
		.padding(.horizontal, 20)
		.padding(.bottom, 12)
	}

	private var environmentMenu: some View {
		let current = history.filter.environment
		let environments = history.timeline?.environments ?? []
		let rows: [VaultMenuList<String?>.Row] = [.init(id: nil, title: "All Environments", isChecked: current == nil)]
			+ environments.enumerated().map { index, environment in
				.init(id: environment.name, title: environment.name, detail: environment.deletedAt == nil ? nil : "deleted",
					separated: index == 0, isChecked: current == environment.name)
			}
		return VaultBarMenu(accessibilityLabel: "Environment, \(current ?? "All Environments")", rows: rows, onChoose: setEnvironment) {
			Text(current ?? "All Environments")
				.font(.system(size: 12.5, weight: .medium))
		}
	}

	/// The sources a change can come from, each with how many changes it made.
	private var sourceMenu: some View {
		let selected = VaultHistoryText.sources.first { $0.0 == history.filter.source }?.1 ?? "All"
		let title = history.filter.source == nil ? "All Sources" : selected
		let selectedCount = count(history.filter.source)
		let rows = VaultHistoryText.sources.enumerated().map { index, entry in
			VaultMenuList<VaultLocalHistory.Source?>.Row(
				id: entry.0, title: entry.0 == nil ? "All Sources" : entry.1, detail: count(entry.0).map { "\($0)" },
				detailIsShortcut: true, separated: index == 1, isChecked: history.filter.source == entry.0)
		}
		return VaultBarMenu(accessibilityLabel: "Source, \(title)\(selectedCount.map { ", \($0)" } ?? "")", rows: rows) { source in
			history.filter.source = source
			Task { await history.reload() }
		} label: {
			HStack(spacing: 6) {
				Text(title).font(.system(size: 12.5, weight: .medium))
				// A count says how many changes the filter leaves, so it shows only once one does.
				if history.filter.source != nil, let selectedCount {
					Text("\(selectedCount)")
						.font(VaultTypography.tabular(11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
		}
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
		guard value != history.filter.keyContains else { return }
		let projectID = project.id
		searchTask = Task {
			try? await Task.sleep(for: .milliseconds(250))
			guard !Task.isCancelled, history.projectID == projectID else { return }
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
			// The words read as one element, and the button stays its own control.
			.accessibilityElement(children: .combine)
			if let action {
				Button(action.0, action: action.1)
					.controlSize(.small)
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 10)
		.background(VaultPalette.orangeTint)
		.accessibilityElement(children: .contain)
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
			} else if history.timeline == nil, let paused = pausedMessage {
				empty("Nothing to show while history is paused", detail: paused, action: nil)
			} else if let timeline = history.timeline, !timeline.rows.isEmpty {
				timelineList
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

	private var timelineList: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
				ForEach(history.days) { day in
					Section {
						ForEach(day.rows) { row in
							rowView(row)
							VaultHairline()
						}
					} header: {
						Text(text.day(day.start).uppercased(with: Locale.current))
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

	@ViewBuilder
	private func rowView(_ row: VaultLocalHistory.Day.Row) -> some View {
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
		let description = text.describe(entry) { id in history.entry(id) }
		let keys = VaultHistoryText.keys(entry)
		let time = text.clock(VaultHistoryText.date(entry.time))
		let environments = entry.environments.map(\.name)
		return Button {
			history.select(selected ? nil : entry.id)
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
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
						// Where a change came from reads after its time, as words, not one more chip on the row.
						Text(badge.text)
							.font(.system(size: 12))
							.foregroundStyle(badge.foreground)
							.lineLimit(1)
					}
				}
				.frame(width: 88, alignment: .leading)
				// What changed and where on the first line; which keys on the second,
				// whole names only, then how many more.
				VStack(alignment: .leading, spacing: 4) {
					HStack(spacing: 10) {
						Text(description)
							.font(.system(size: 13, weight: .medium))
							.foregroundStyle(badge.warns ? VaultPalette.orangeTintText : VaultPalette.textPrimary)
							.lineLimit(1)
							.layoutPriority(1)
						ViewThatFits(in: .horizontal) {
							environmentChips(environments, limit: environments.count)
							environmentChips(environments, limit: 2)
							environmentChips(environments, limit: 1)
						}
					}
					if !keys.isEmpty {
						ViewThatFits(in: .horizontal) {
							keyLine(keys, showing: 3).fixedSize()
							keyLine(keys, showing: 2).fixedSize()
							keyLine(keys, showing: 1).fixedSize()
							// A key name is never cut; with no room for one, the line counts them.
							Text(keys.count == 1 ? "1 key" : "\(keys.count) keys")
								.font(.system(size: 11))
								.foregroundStyle(VaultPalette.textTertiary)
						}
					}
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 10)
			.vaultRowBackground(selected: selected, resting: badge.warns ? VaultPalette.orangeTint : .clear)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("\(time), \(badge.text), \(description)\(environments.isEmpty ? "" : " in " + environments.joined(separator: ", "))")
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	/// The first `count` of `keys`, then how many more there are.
	private func keyLine(_ keys: [String], showing count: Int) -> some View {
		let shown = keys.prefix(count)
		return HStack(spacing: 6) {
			Text(shown.joined(separator: " · "))
				.font(VaultTypography.tabular(11.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.lineLimit(1)
				.truncationMode(.tail)
			if keys.count > shown.count {
				Text("+\(keys.count - shown.count) more")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize()
			}
		}
	}

	private func environmentChip(_ name: String) -> some View {
		VaultHistoryEnvironmentChip(name, in: store.orderedEnvironmentNames(for: project))
	}

	/// The first `limit` environments as chips, then how many more.
	private func environmentChips(_ environments: [String], limit: Int) -> some View {
		HStack(spacing: 6) {
			ForEach(environments.prefix(limit), id: \.self) { name in environmentChip(name) }
			if environments.count > limit {
				Text("+\((environments.count - limit).counted("env"))")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.fixedSize()
	}
}
