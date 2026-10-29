import SwiftUI

/// Finds where a value is stored on this Mac, and which values are stored
/// in more than one place. The field stays masked and keeps no history, and
/// nothing is searched until Return, since each search reads every project.
struct ValueSearchSheet: View {
	@Bindable var store: VaultStore
	@Environment(UpdateChecker.self) private var updateChecker
	@State private var fieldFocused = false
	@State private var showsUnread = false

	private var search: ValueSearchModel { store.valueSearch }
	private var hasTerm: Bool { !search.term.text.isEmpty }
	private var accountName: String { store.valueSearchAccountName(store.selectedAccount) }
	private var scopeAccountName: String? { search.scope == .account ? accountName : nil }
	/// Whether widening to every account would read more: the person belongs to an organization.
	private var hasOtherAccounts: Bool { !store.userOrgs.isEmpty }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VStack(alignment: .leading, spacing: 14) {
				HStack(spacing: 8) {
					modePicker
					Spacer(minLength: 8)
					if hasOtherAccounts { scopePicker(label: search.mode == .find ? "Search in" : "Compare in") }
				}
				if search.mode == .find { findControls }
			}
			.padding(.horizontal, 24)
			.padding(.bottom, 14)
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					if search.mode == .find { findContent } else { reuseContent }
				}
				.padding(.horizontal, 24)
				.padding(.vertical, 2)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: .infinity)
			coverage
				.padding(.horizontal, 24)
				.padding(.vertical, 12)
			VaultSheetFooter {
				footerNote
			} actions: {
				footerActions
			}
		}
		.frame(width: 560, height: 600)
		.background(VaultPalette.content)
		.onAppear { fieldFocused = search.mode == .find }
		.onDisappear { search.sheetClosed() }
		.onChange(of: search.mode) { _, mode in fieldFocused = mode == .find }
		.onChange(of: search.find?.phase) { _, phase in announceFind(phase) }
		.onChange(of: search.reuse?.phase) { _, phase in announceReuse(phase) }
		.vaultConfirmation(item: Binding(get: { search.pendingOpen }, set: { if $0 == nil { search.cancelPendingOpen() } })) { pending in
			VaultConfirmation(
				symbol: "exclamationmark.triangle",
				title: "Discard your unsaved changes?",
				message: "Opening \(pending.name) switches to \(pending.accountName), which discards the changes you haven’t saved.",
				subject: VaultConfirmation.Subject(
					mark: .project(store.projectIcons.appearance(for: pending.projectID)),
					name: store.projects.first { $0.id == pending.projectID }?.name ?? pending.name, detail: pending.accountName),
				cancelTitle: "Keep Editing",
				actions: [.init(title: "Discard and Open", perform: search.confirmPendingOpen)])
		}
	}

	// MARK: - Header and controls

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(search.mode == .find ? "Find a value" : "Reused values")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.accessibilityAddTraits(.isHeader)
				Text(search.mode == .find
					? ValueSearchWording.findSubtitle(search.find, termKept: search.keepsTerm)
					: ValueSearchWording.reuseSubtitle(search.reuse))
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: close)
		}
		.padding(.horizontal, 24)
		.padding(.top, 18)
		.padding(.bottom, 14)
	}

	private var modePicker: some View {
		Picker("Search for", selection: Binding(get: { search.mode }, set: { search.mode = $0 })) {
			Text("Find a value").tag(ValueSearchModel.Mode.find)
			Text("Reused values").tag(ValueSearchModel.Mode.reuse)
		}
		.pickerStyle(.segmented)
		.labelsHidden()
		.fixedSize()
		.disabled(search.isRunning)
	}

	private var findControls: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 7) {
				Image(systemName: "lock.fill")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(VaultPalette.textTertiary)
					.accessibilityHidden(true)
				VaultValueField(
					text: Binding(get: { search.term.text }, set: { search.term = ExactText($0) }),
					isFocused: $fieldFocused,
					label: "Value to find",
					placeholder: "Paste a value",
					isSecure: true,
					font: .systemFont(ofSize: 12.5),
					recordsUndo: false,
					onSubmit: submit
				)
			}
			.padding(.horizontal, 9)
			.frame(height: 28)
			.vaultInputField(focused: fieldFocused)
			containsOption
		}
	}

	private var containsOption: some View {
		let allowed = ValueMatcher.allowsContaining(search.term.text)
		return HStack(spacing: 7) {
			Toggle("\(ValueSearchWording.containsOption), \(ValueMatcher.minimumContainedCharacters) characters or more", isOn: Binding(
				get: { search.findsContainingValues },
				set: { search.findsContainingValues = $0 }))
				.toggleStyle(.checkbox)
				.labelsHidden()
			// A checkbox toggles on its title too; VoiceOver hears the checkbox's own.
			Button { search.findsContainingValues.toggle() } label: {
				HStack(spacing: 7) {
					Text(ValueSearchWording.containsOption)
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(ValueSearchWording.containsMinimum)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityHidden(true)
		}
		.disabled(search.isRunning || !allowed)
		.opacity(search.isRunning || !allowed ? 0.6 : 1)
		.fixedSize()
	}

	/// Which accounts the search reads, offered only to someone in an
	/// organization: for anyone else, every account is the one they have.
	private func scopePicker(label: String) -> some View {
		HStack(spacing: 7) {
			Text(label)
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
				.fixedSize()
				.accessibilityHidden(true)
			VaultMenuField(
				title: label,
				options: [ValueSearchModel.Scope.account, .everyAccount].map {
					VaultMenuOption(value: $0, label: ValueSearchWording.scopeOption($0, accountName: accountName))
				},
				selection: Binding(get: { search.scope }, set: { if let scope = $0 { search.scope = scope } }),
				disabled: search.isRunning
			)
			.frame(minWidth: 170, maxWidth: 230)
		}
	}

	// MARK: - Finding a value

	@ViewBuilder
	private var findContent: some View {
		if let find = search.find {
			switch find.phase {
			case .running:
				progress(ValueSearchWording.searching(find), reached: find.reached, total: find.total,
					note: "Results appear as each project is read.")
				if !find.hits.isEmpty { hits(find) }
			case .stopped:
				stoppedBanner(find)
				if !find.hits.isEmpty { hits(find) }
				notSearched(find)
			case .finished:
				if find.hits.isEmpty {
					emptyState(symbol: "magnifyingglass", title: "No matches",
						detail: ValueSearchWording.noMatches(find, canWidenToEveryAccount: hasOtherAccounts,
							canWidenToContaining: search.keepsTerm && ValueMatcher.allowsContaining(search.term.text)))
				} else {
					hits(find)
				}
				notSearched(find)
			}
		} else {
			emptyState(symbol: "magnifyingglass", title: "Nothing searched yet",
				detail: ValueSearchWording.idleFind(
					projects: store.valueSearchProjectCount(everyAccount: search.scope == .everyAccount), accountName: scopeAccountName))
		}
	}

	private func hits(_ find: ValueSearchModel.Find) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			ValueSearchSectionHeading(title: ValueSearchWording.resultsHeading(find), detail: ValueSearchWording.matchCounts(find))
			ValueSearchCard {
				LazyVStack(spacing: 0) {
					ForEach(find.hits) { hit in
						if hit.id != find.hits.first?.id { VaultHairline(color: VaultPalette.rowDivider) }
						ValueSearchPlaceRow(store: store, place: hit.place, match: hit.match, showsAccount: find.scope == .everyAccount)
					}
				}
			}
		}
	}

	private func stoppedBanner(_ find: ValueSearchModel.Find) -> some View {
		HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.orangeTintText)
				.accessibilityHidden(true)
			Text(ValueSearchWording.stopped(unread: find.unread.count))
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textPrimary)
			Spacer(minLength: 8)
			if search.canContinue {
				VaultBarButton(title: "Continue", height: 24) { search.continueFind() }
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.headerRow))
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
	}

	@ViewBuilder
	private func notSearched(_ find: ValueSearchModel.Find) -> some View {
		let unread = Array(find.unread)
		if !find.skips.isEmpty || !unread.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				ValueSearchSectionHeading(title: "Not searched · \(find.skips.count + unread.count)", detail: "Shown so nothing is hidden")
				ValueSearchCard {
					ForEach(Array(find.skips.enumerated()), id: \.element.id) { index, skip in
						if index > 0 { VaultHairline(color: VaultPalette.rowDivider) }
						ValueSearchSkipRow(store: store, skip: skip, canRetry: search.canRetry, onCheckForUpdates: checkForUpdates)
					}
					if !unread.isEmpty {
						if !find.skips.isEmpty { VaultHairline(color: VaultPalette.rowDivider) }
						unreadRow(unread)
					}
				}
			}
		}
	}

	private func unreadRow(_ unread: [String]) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "stop.circle")
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textTertiary)
					.frame(width: 16)
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 1) {
					Text(ValueSearchWording.unreadTitle(unread.count))
						.font(.system(size: 13))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(ValueSearchWording.unreadDetail)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.accessibilityElement(children: .combine)
				Spacer(minLength: 8)
				Button(showsUnread ? "Hide Projects" : "Show Projects") { showsUnread.toggle() }
					.buttonStyle(.plain)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(VaultPalette.accentForeground)
					.vaultPointingHand()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.frame(minHeight: 44)
			if showsUnread {
				ForEach(unread, id: \.self) { projectID in
					VaultHairline(color: VaultPalette.rowDivider)
					HStack(spacing: 10) {
						VaultProjectIconView(appearance: store.projectIcons.appearance(for: projectID), size: 16)
						Text(store.projects.first { $0.id == projectID }?.name ?? projectID)
							.font(.system(size: 13))
							.foregroundStyle(VaultPalette.textSecondary)
							.lineLimit(1)
						Spacer(minLength: 0)
					}
					.padding(.horizontal, 12)
					.frame(height: 32)
					.accessibilityElement(children: .combine)
				}
			}
		}
	}

	// MARK: - Reused values

	@ViewBuilder
	private var reuseContent: some View {
		if let reuse = search.reuse {
			switch reuse.phase {
			case .running:
				progress(ValueSearchWording.comparing(reuse), reached: reuse.reached, total: reuse.total,
					note: "Groups appear when the scan finishes, so counts are complete.")
				emptyState(symbol: "square.on.square", title: "Nothing to show yet", detail: nil)
			case .stopped:
				emptyState(symbol: "stop.circle", title: "Scan stopped", detail: "Groups appear only when a scan finishes.")
			case .finished:
				if reuse.reported.isEmpty {
					emptyState(symbol: "checkmark.circle", title: "Nothing reused", detail: ValueSearchWording.nothingReused(reuse))
				} else {
					ForEach([ReusedValueGroup.Span.projects, .environments, .environment], id: \.self) { span in
						groupSection(span, groups: reuse.reported.filter { $0.span == span }, scope: reuse.scope)
					}
				}
				configuration(reuse)
				notCompared(reuse)
			}
		} else {
			emptyState(symbol: "square.on.square", title: "Nothing compared yet",
				detail: ValueSearchWording.idleReuse(
					projects: store.valueSearchProjectCount(everyAccount: search.scope == .everyAccount), accountName: scopeAccountName))
		}
	}

	@ViewBuilder
	private func groupSection(_ span: ReusedValueGroup.Span, groups: [ReusedValueGroup], scope: ValueSearchModel.Scope) -> some View {
		if !groups.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				ValueSearchSectionHeading(title: "\(ValueSearchWording.sectionTitle(span)) · \(groups.count)",
					detail: ValueSearchWording.sectionDetail(span))
				LazyVStack(spacing: 10) {
					ForEach(groups) { group in
						ReusedValueGroupCard(store: store, group: group, showsAccount: scope == .everyAccount)
					}
				}
			}
		}
	}

	@ViewBuilder
	private func configuration(_ reuse: ValueSearchModel.Reuse) -> some View {
		let configuration = reuse.configuration
		if !configuration.isEmpty {
			HStack(alignment: .firstTextBaseline, spacing: 7) {
				Image(systemName: "info.circle")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.accessibilityHidden(true)
				Text(ValueSearchWording.leftOut(configuration.count))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 8)
				Button(search.showsConfiguration ? "Hide" : "Show") { search.showsConfiguration.toggle() }
					.buttonStyle(.plain)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(VaultPalette.accentForeground)
					.vaultPointingHand()
					.accessibilityLabel(search.showsConfiguration ? "Hide configuration groups" : "Show configuration groups")
			}
			if search.showsConfiguration {
				VStack(alignment: .leading, spacing: 8) {
					ValueSearchSectionHeading(title: "Configuration · \(configuration.count)", detail: "repeats for good reason")
					LazyVStack(spacing: 10) {
						ForEach(configuration) { group in
							ReusedValueGroupCard(store: store, group: group, showsAccount: reuse.scope == .everyAccount)
						}
					}
				}
			}
		}
	}

	@ViewBuilder
	private func notCompared(_ reuse: ValueSearchModel.Reuse) -> some View {
		if !reuse.skips.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				ValueSearchSectionHeading(title: "Not compared · \(reuse.skips.count)", detail: "Values in these could still be reused")
				ValueSearchCard {
					ForEach(Array(reuse.skips.enumerated()), id: \.element.id) { index, skip in
						if index > 0 { VaultHairline(color: VaultPalette.rowDivider) }
						ValueSearchSkipRow(store: store, skip: skip, unreadAs: "not compared", canRetry: false, onCheckForUpdates: checkForUpdates)
					}
				}
			}
		}
	}

	// MARK: - Shared parts

	private func progress(_ status: String, reached: Int, total: Int, note: String) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(status)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textPrimary)
				Spacer(minLength: 8)
				VaultBarButton(systemImage: "stop.fill", title: "Stop", height: 24) { search.stop() }
			}
			ProgressView(value: Double(reached), total: Double(max(total, 1)))
				.progressViewStyle(.linear)
				.controlSize(.small)
				.tint(VaultPalette.accent)
				.accessibilityLabel("Progress")
				.accessibilityValue("\(reached) of \(total.counted("project"))")
			Text(note)
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
		}
	}

	private func emptyState(symbol: String, title: String, detail: String?) -> some View {
		VStack(spacing: 8) {
			Image(systemName: symbol)
				.font(.system(size: 17, weight: .medium))
				.foregroundStyle(VaultPalette.textTertiary)
				.frame(width: 40, height: 40)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.neutralTint))
				.accessibilityHidden(true)
			Text(title)
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
			if let detail {
				Text(detail)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: 340)
			}
		}
		.frame(maxWidth: .infinity, minHeight: 170)
		.accessibilityElement(children: .combine)
	}

	private var coverage: some View {
		HStack(alignment: .firstTextBaseline, spacing: 7) {
			Image(systemName: "info.circle")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
				.accessibilityHidden(true)
			Text(search.mode == .find ? ValueSearchWording.findCoverage : ValueSearchWording.reuseCoverage)
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	// MARK: - Footer

	@ViewBuilder
	private var footerNote: some View {
		let text = search.mode == .find
			? ValueSearchWording.findFooter(search.find, termKept: search.keepsTerm)
			: ValueSearchWording.reuseFooter(search.reuse)
		if search.mode == .find, search.find == nil {
			Label(text, systemImage: "lock.fill")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
		} else {
			Text(text)
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	@ViewBuilder
	private var footerActions: some View {
		if search.isRunning {
			VaultBarButton(title: "Cancel", height: 28, action: close)
				.keyboardShortcut(.cancelAction)
		} else if search.mode == .find, let find = search.find {
			if find.phase == .finished, find.hits.isEmpty, find.scope == .account, hasOtherAccounts, hasTerm {
				VaultBarButton(title: "Search Every Account", height: 28) {
					search.scope = .everyAccount
					search.startFind()
				}
			}
			if hasTerm {
				VaultBarButton(title: search.fieldHoldsLastTerm ? "Search Again" : "Search", height: 28, action: submit)
			} else {
				VaultBarButton(title: "Clear Results", height: 28) { search.clearResults() }
			}
			VaultBarButton(title: "Done", filled: true, height: 28, action: close)
				.keyboardShortcut(.cancelAction)
		} else if search.mode == .reuse, let reuse = search.reuse {
			if reuse.phase == .finished, reuse.reported.isEmpty, reuse.scope == .account, hasOtherAccounts {
				VaultBarButton(title: "Scan Every Account", height: 28) {
					search.scope = .everyAccount
					search.startReuse()
				}
			}
			VaultBarButton(title: "Scan Again", height: 28, action: submit)
			VaultBarButton(title: "Done", filled: true, height: 28, action: close)
				.keyboardShortcut(.cancelAction)
		} else {
			VaultBarButton(title: "Cancel", height: 28, action: close)
				.keyboardShortcut(.cancelAction)
			VaultBarButton(title: search.mode == .find ? "Search" : "Scan", filled: true,
				disabled: search.mode == .find && !hasTerm, height: 28, action: submit)
				.keyboardShortcut(.defaultAction)
		}
	}

	// MARK: - Actions

	private func submit() {
		switch search.mode {
		case .find:
			guard hasTerm else { return }
			showsUnread = false
			search.startFind()
		case .reuse:
			search.startReuse()
		}
	}

	private func close() {
		search.sheetClosed()
	}

	private func checkForUpdates() {
		updateChecker.checkForUpdates()
	}

	private func announceFind(_ phase: ValueSearchModel.Phase?) {
		guard let find = search.find, phase != .running else { return }
		let text = switch find.phase {
		case .finished where find.hits.isEmpty: "No matches in \(find.searched.counted("project"))"
		case .finished: "Search complete, \(ValueSearchWording.placesIn(find))"
		case .stopped: "Search stopped after \(find.reached) of \(find.total.counted("project"))"
		case .running: ""
		}
		AccessibilityNotification.Announcement(text).post()
	}

	private func announceReuse(_ phase: ValueSearchModel.Phase?) {
		guard let reuse = search.reuse, phase == .finished else { return }
		AccessibilityNotification.Announcement(
			reuse.reported.isEmpty ? "Scan complete, nothing reused" : "Scan complete, \(reuse.reported.count.counted("group"))").post()
	}
}
