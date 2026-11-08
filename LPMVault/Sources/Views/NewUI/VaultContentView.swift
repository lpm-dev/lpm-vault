import SwiftUI

struct VaultCliAccessPresentation {
	let access: VaultCliAccess?
	/// Whether the item's approval attributes contradict each other, which
	/// choosing approval again sets right.
	var contradicts = false
	var help: String {
		switch access {
		case .requireApproval: "CLI access requires Touch ID or your Mac login password."
		case .automatic: "CLI access automatically injects env values."
		case nil where contradicts: "This project’s approval settings contradict each other. Turn CLI approval on to set them."
		case nil: "CLI approval is unavailable until its policy can be read."
		}
	}
	var accessibilityValue: String {
		switch access {
		case .requireApproval: "Required"
		case .automatic: "Automatic"
		case nil where contradicts: "Contradicts itself"
		case nil: "Unavailable"
		}
	}
	/// What the header's chip says.
	var title: String {
		switch access {
		case .requireApproval: "CLI approval on"
		case .automatic: "CLI approval off"
		case nil where contradicts: "CLI approval needs fixing"
		case nil: "CLI approval unknown"
		}
	}
}

/// The project's CLI approval when it needs fixing, said after the page's
/// counts. It's a setting, not a view of the table, so it only says so and
/// opens Project Settings, where it's fixed.
struct VaultCliApprovalLink: View {
	let presentation: VaultCliAccessPresentation
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Text(presentation.title)
				.font(VaultTypography.tabular(12))
				.foregroundStyle(VaultPalette.orangeTintText)
				.underline(hovering)
				.frame(height: 22)
				.contentShape(Rectangle())
				.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle(cornerRadius: 4))
		.onHover { hovering = $0 }
		.vaultPointingHand()
		.help("\(presentation.help) Change it in Project Settings.")
		.accessibilityLabel(presentation.title)
		.accessibilityValue(presentation.accessibilityValue)
		.accessibilityHint("Opens Project Settings")
	}
}

/// The coordinate space the matrix measures its sideways scroll in, outside
/// the view so a geometry reader's sendable closure can name it.
private let vaultMatrixSpace = "VaultContentView.matrix"

struct VaultContentView: View {
	let project: VaultProject
	let snapshot: VaultWorkspaceSnapshot
	let environments: [String]
	let selectedEnvironment: String
	@Binding var mode: VaultWorkspaceMode
	@Binding var filter: VaultWorkspaceFilter
	@Binding var environmentViewMode: VaultEnvironmentViewMode
	@Binding var sortOrder: VaultKeySortOrder
	let searchText: String
	@Binding var selectedKey: String?
	@Binding var revealedKeys: Set<String>
	@Binding var showsInspector: Bool
	@Binding var columnWidths: VaultProjectTableColumnWidths
	let isCopyingAll: Bool
	var isCopiedAll = false
	var canUseSecrets = true
	/// Whether the project's newer data lets its values change.
	var canEditValues = true
	let cliAccess: VaultCliAccess?
	var cliAccessContradicts = false
	let onCopyAll: () -> Void
	let onImport: () -> Void
	let onExport: () -> Void
	/// The "…" menu's items: the project's settings, folder and other actions.
	var onProjectSettings: () -> Void = {}
	/// Keys with unsaved edits in this project.
	var editedKeys: Set<String> = []
	/// Keys whose rules make them public; their values show unmasked.
	var publicKeys: Set<String> = []
	/// What the project's rules find in its values.
	var valueChecks: VaultValueCheckPresentation = .none
	let onAddSecret: () -> Void
	/// Adds a value for a declared key that has none in the selected environment.
	var onAddKey: (String) -> Void = { _ in }
	let onCopySecret: (String, String) -> Void
	let onDeleteSecret: (String, String) -> Void
	let onResizeColumns: () -> Void
	/// Copies the selected environment's lines of these keys, in Raw text.
	var onCopyLines: ([String]) -> Void = { _ in }
	/// How many lines Raw text just copied, while it says so.
	var copiedLineCount: Int?
	/// Raw text's edit of the selected environment, while there is one.
	var rawEditing: VaultRawTextEditing?
	/// Why the selected environment can't be edited as Raw text, or nil when it can.
	var rawEditBlocker: String?
	/// Edits the selected environment as Raw text, from its keys in the order given.
	var onEditRaw: ([String]) -> Void = { _ in }
	/// The last Raw text save, while it can be undone or says how undoing went.
	var rawSaved: VaultRawTextSaved?
	var onUndoRawSave: () -> Void = {}
	/// What the last value search found, while there's a result to go back to.
	var valueSearchSummary: String?
	var onShowValueSearch: () -> Void = {}
	var onClearValueSearch: () -> Void = {}
	/// The keys a value search found, each with the environments it found them in.
	var foundValues: [String: Set<String>] = [:]
	/// Finds where the stored value of a key in an environment is used.
	var onFindValue: (_ key: String, _ environment: String) -> Void = { _, _ in }

	@State private var rawSelectedLineCount = 0
	@State private var showsTransferMenu = false
	/// How far the matrix has scrolled sideways, which pins its key column.
	@State private var matrixScrollX: CGFloat = 0
	/// Where a step to a column out of view scrolls the matrix.
	@State private var matrixScrollTarget = VaultHorizontalScrollTarget()
	@State private var rowClicks = VaultRowClicks()

	var body: some View {
		let derived = VaultContentDerivation(
			project: project,
			snapshot: snapshot,
			selectedEnvironment: selectedEnvironment,
			mode: mode,
			filter: filter,
			searchText: searchText,
			sortOrder: sortOrder,
			revealedKeys: canUseSecrets ? revealedKeys : [],
			publicKeys: shownPublicKeys,
			invalidKeys: valueChecks.invalidKeys,
			unstoredKeys: mode == .matrix ? valueChecks.unstoredInvalidKeys()
				: (environmentViewMode == .table ? valueChecks.unstoredKeys(in: selectedEnvironment) : [])
		)
		let editing = showsRawText ? rawEditing : nil
		let raw = showsRawText && editing == nil ? rawText(derived) : nil
		VStack(spacing: 0) {
			header(derived)
			VaultHairline()
			if let valueSearchSummary {
				ValueSearchStrip(summary: valueSearchSummary, onShow: onShowValueSearch, onClear: onClearValueSearch)
			}

			switch mode {
			case .matrix:
				matrix(derived)
			case .environment:
				environmentDetail(derived, raw: raw, editing: editing)
			case .schema, .history, .projectSettings:
				// The workspace shows the Schema or Project Settings page instead of this view.
				Spacer(minLength: 0)
			}

			VaultHairline()
			statusBar(derived, raw: raw, editing: editing)
		}
		.background(VaultPalette.content)
	}

	/// The first row is about the project: what it is, its CLI approval, the
	/// inspector, its other actions, and a new key. The second is about what
	/// is on screen: how it is filtered or shown, and the actions on those values.
	private func header(_ derived: VaultContentDerivation) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 10) {
					headerIdentity(derived, showsApproval: true)
					Spacer(minLength: 8)
					projectButtons
				}
				// A narrow header keeps one row, giving up Project Settings' title,
				// then the CLI approval, which Project Settings still shows, then the counts.
				HStack(spacing: 10) {
					headerIdentity(derived, showsApproval: true)
					Spacer(minLength: 8)
					projectButtons(compact: true)
				}
				HStack(spacing: 10) {
					headerIdentity(derived, showsApproval: false)
					Spacer(minLength: 8)
					projectButtons(compact: true)
				}
				HStack(spacing: 10) {
					headerIdentity(derived, showsApproval: false, showsCounts: false)
					Spacer(minLength: 8)
					projectButtons(compact: true)
				}
				VStack(alignment: .leading, spacing: 10) {
					headerIdentity(derived, showsApproval: false)
					projectButtons(compact: true).frame(maxWidth: .infinity, alignment: .trailing)
				}
			}
			// The title's middle sits 30 points down, as in every page's 60-point header.
			.frame(minHeight: 32)

			if showsRawText, let rawEditing {
				ViewThatFits(in: .horizontal) {
					HStack(spacing: 6) {
						viewControls
						hint("Editing · real values shown")
						Spacer(minLength: 8)
						rawEditActions(rawEditing)
					}
					HStack(spacing: 6) {
						viewControls
						Spacer(minLength: 8)
						rawEditActions(rawEditing)
					}
				}
			} else {
				valueRow(derived)
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 14)
		.padding(.bottom, 12)
	}

	private func hint(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 12))
			.foregroundStyle(VaultPalette.textTertiary)
			.lineLimit(1)
			.fixedSize()
			.padding(.leading, 6)
	}

	private func rawEditActions(_ editing: VaultRawTextEditing) -> some View {
		HStack(spacing: 6) {
			let reviews = editing.draft.reviewsBeforeSaving
			HStack(spacing: 6) {
				// The switch says its name; the text beside it flips it too.
				Text("Review before saving")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.accessibilityHidden(true)
					.onTapGesture { if !editing.isSaving { editing.onReviewChange(!reviews) } }
				Toggle("Review before saving", isOn: Binding(get: { reviews }, set: { editing.onReviewChange($0) }))
					.toggleStyle(VaultSwitchStyle())
					.controlSize(.mini)
					.disabled(editing.isSaving)
			}
			.help(reviews
				? "Save shows what changes first, and lets you leave any of it out"
				: "Save writes the edit at once, which can be undone for \(VaultFeedbackTimer.undoSeconds) seconds")
			.padding(.trailing, 6)
			VaultBarButton(title: "Cancel", disabled: editing.isSaving, height: 28, action: editing.onCancel)
				.help("Discard this edit")
			VaultBarButton(title: editing.isSaving ? "Saving…" : "Save", shortcut: "⌘S", filled: true,
				disabled: !editing.draft.canSave || editing.isSaving, height: 28, action: editing.onSave)
				.keyboardShortcut("s", modifiers: .command)
				.help(editing.draft.check.problems.isEmpty
					? (editing.draft.changes.count == 0 ? "Nothing has changed yet" : "Save \(editing.draft.changes.summary)")
					: "Fix every problem line first")
		}
		.fixedSize()
	}

	/// Raw text's hint goes first, then Import and Export move into the More
	/// menu, then Reveal and Copy All lose their names, so a row never mixes
	/// named buttons with bare icons that do as much.
	private func valueRow(_ derived: VaultContentDerivation) -> some View {
		ViewThatFits(in: .horizontal) {
			if showsRawText {
				HStack(spacing: 6) {
					viewControls
					hint("One KEY=value per line · select and ⌘C copies real values")
					Spacer(minLength: 8)
					valueActions(compact: false, namesTransfers: true, derived: derived)
				}
			}
			HStack(spacing: 6) {
				viewControls
				Spacer(minLength: 8)
				valueActions(compact: false, namesTransfers: true, derived: derived)
			}
			HStack(spacing: 6) {
				viewControls
				Spacer(minLength: 8)
				valueActions(compact: false, derived: derived)
			}
			HStack(spacing: 6) {
				viewControls
				Spacer(minLength: 8)
				valueActions(compact: true, derived: derived)
			}
			HStack(spacing: 6) {
				viewControls(compact: true)
				Spacer(minLength: 8)
				valueActions(compact: true, derived: derived)
			}
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 6) { viewControls }
				valueActions(compact: true, derived: derived).frame(maxWidth: .infinity, alignment: .trailing)
			}
		}
	}

	private var viewControls: some View { viewControls(compact: false) }

	/// The filter chips, whose compact ones show a filter's symbol and count without its title, or
	/// the view's segments: chips always filter, and segments always switch a mode, as elsewhere.
	@ViewBuilder
	private func viewControls(compact: Bool) -> some View {
		if case .matrix = mode {
			ForEach(VaultWorkspaceFilter.allCases.filter { $0 != .invalid || valueChecks.hasCheck }) { candidate in
				switch candidate {
				case .invalid:
					VaultFilterChip(
						title: candidate.rawValue,
						symbol: VaultSmartView.invalid.symbol,
						trailing: "\(valueChecks.invalidKeys.count)",
						alert: !valueChecks.invalidKeys.isEmpty,
						compact: compact,
						selected: filter == candidate
					) { filter = candidate }
					.help("Keys whose values fail their lpm.json rules")
				default:
					VaultFilterChip(
						title: candidate.rawValue,
						symbol: candidate == .drift ? VaultSmartView.drift.symbol : (candidate == .missing ? VaultSmartView.missing.symbol : nil),
						symbolTint: candidate == .drift ? VaultSmartView.drift.tint : (candidate == .missing ? VaultSmartView.missing.tint : nil),
						trailing: candidate == .drift
							? "\(snapshot.driftingKeyCount)"
							: (candidate == .missing ? "\(snapshot.missingKeyCount)" : nil),
						compact: compact,
						selected: filter == candidate
					) { filter = candidate }
				}
			}
		} else {
			VaultSegmentedPicker(title: "View", options: VaultEnvironmentViewMode.allCases.map { ($0, $0.rawValue) },
				selection: $environmentViewMode)
		}
	}

	/// The page's title and what it counts: the project's keys, values and
	/// environments, or one environment's keys. No swatch goes before an
	/// environment's name, so every page's title starts at the same edge.
	private func identity(_ derived: VaultContentDerivation) -> (title: String, counts: String) {
		if case .matrix = mode {
			return ("All Keys",
				"\(derived.allKeys.count.counted("key")) · \(project.secretCount.counted("value")) · \(environments.count.counted("env"))")
		}
		// Every key the table lists, and how many of them it doesn't set, which lpm.json declares.
		let unset = derived.environmentUnsetCount
		return (VaultProject.displayName(for: selectedEnvironment),
			derived.environmentKeyCount.counted("key") + (unset == 0 ? "" : " · \(unset) not set"))
	}

	private func headerIdentity(_ derived: VaultContentDerivation, showsApproval: Bool, showsCounts: Bool = true) -> some View {
		let (title, counts) = identity(derived)
		// CLI approval is a setting the project's card and Project Settings show; the header names
		// it only when it needs fixing, as a fact about the project that opens where it's fixed.
		let namesApproval = showsApproval && cliAccessContradicts
		return HStack(spacing: 10) {
			Text(title)
				.vaultPageTitle()
			if showsCounts {
				HStack(spacing: 0) {
					Text(counts + (namesApproval ? " · " : ""))
						.font(VaultTypography.tabular(12))
						.foregroundStyle(VaultPalette.textTertiary)
					if namesApproval {
						VaultCliApprovalLink(presentation: VaultCliAccessPresentation(access: cliAccess, contradicts: cliAccessContradicts),
							action: onProjectSettings)
					}
				}
			}
		}
		.lineLimit(1)
		.fixedSize(horizontal: true, vertical: false)
	}

	private var projectButtons: some View { projectButtons(compact: false) }

	private func projectButtons(compact: Bool) -> some View {
		HStack(spacing: 4) {
			VaultOutlineButton(
				systemImage: "sidebar.right",
				help: showsInspector ? "Hide inspector" : "Show inspector",
				active: showsInspector,
				borderless: true
			) { showsInspector.toggle() }
			VaultOutlineButton(systemImage: "gearshape", title: compact ? nil : "Project Settings", help: "Project Settings (⌘I)", label: "Project Settings",
				borderless: true, action: onProjectSettings)
			VaultBarButton(
				systemImage: "plus",
				title: "New Key",
				filled: true,
				disabled: !canEditValues,
				action: onAddSecret
			)
			.padding(.leading, 4)
		}
		.fixedSize()
	}

	/// Reveal acts on the keys in view; copying, importing, and exporting act on
	/// the selected environment, which their help names.
	private func valueActions(compact: Bool, namesTransfers: Bool = false, derived: VaultContentDerivation) -> some View {
		let environmentName = VaultProject.displayName(for: selectedEnvironment)
		let copyTitle = isCopyingAll ? "Copying…" : (isCopiedAll ? "Copied" : "Copy All")
		let copyHelp = isCopyingAll
			? "Copying all \(environmentName) values once they’re reloaded"
			: (isCopiedAll ? "All \(environmentName) values copied" : "Copy all \(environmentName) values")
		let copyLabel = isCopyingAll
			? "Copying all \(environmentName) values"
			: (isCopiedAll ? "Copied all \(environmentName) values" : "Copy all \(environmentName) values")
		return HStack(spacing: 6) {
			VaultOutlineButton(
				systemImage: derived.allVisibleRevealed ? "eye.slash" : "eye",
				title: compact ? nil : "Reveal All",
				help: derived.allVisibleRevealed ? "Hide all values" : "Reveal all values",
				label: "Reveal all values",
				active: derived.allVisibleRevealed,
				toggles: true,
				disabled: !canUseSecrets || !derived.hasMaskableValues,
				borderless: true
			) { toggleRevealAll(derived) }

			VaultOutlineButton(
				systemImage: isCopiedAll && !isCopyingAll ? "checkmark" : "doc.on.doc",
				title: compact ? nil : copyTitle,
				reservedTitles: compact ? [] : ["Copy All", "Copying…", "Copied"],
				help: copyHelp,
				label: copyLabel,
				active: isCopiedAll && !isCopyingAll,
				disabled: isCopyingAll || !canUseSecrets,
				borderless: true,
				action: onCopyAll
			)
			if showsRawText {
				VaultOutlineButton(
					systemImage: "pencil",
					title: compact ? nil : "Edit",
					help: rawEditBlocker ?? "Edit \(environmentName) as text, with real values",
					label: "Edit \(environmentName) as text",
					disabled: rawEditBlocker != nil || !canUseSecrets || !canEditValues,
					borderless: true,
					action: { onEditRaw(rawEditOrder) }
				)
			}
			if namesTransfers {
				transferButtons(environmentName: environmentName)
			} else {
				transferMenu(environmentName: environmentName)
			}
		}
		.fixedSize()
		// The last borderless control's label ends where the filled New Key above does; its hover fill reaches past.
		.padding(.trailing, -9)
	}

	private enum Transfer: Hashable { case importing, exporting }

	/// Import and Export by name, where the row has room for them; the menu's rows say the same.
	@ViewBuilder
	private func transferButtons(environmentName: String) -> some View {
		VaultOutlineButton(
			systemImage: "tray.and.arrow.down",
			title: "Import…",
			help: "Import keys into \(environmentName)",
			label: "Import into \(environmentName)…",
			disabled: !canEditValues,
			borderless: true,
			action: onImport
		)
		VaultOutlineButton(
			systemImage: "tray.and.arrow.up",
			title: "Export…",
			help: "Export \(environmentName) to a file",
			label: "Export \(environmentName)…",
			disabled: !canUseSecrets,
			borderless: true,
			action: onExport
		)
	}

	/// Import and Export behind one button, where the row has no room to name them.
	private func transferMenu(environmentName: String) -> some View {
		VaultOutlineButton(
			systemImage: "ellipsis",
			title: nil,
			help: "Import into or export \(environmentName)",
			label: "More actions",
			active: showsTransferMenu,
			disabled: !canEditValues && !canUseSecrets,
			borderless: true
		) { showsTransferMenu.toggle() }
		.vaultPopover(isPresented: $showsTransferMenu, arrowEdge: .bottom) {
			VaultMenuList(rows: [
				.init(id: Transfer.importing, title: "Import into \(environmentName)…", isEnabled: canEditValues),
				.init(id: Transfer.exporting, title: "Export \(environmentName)…", isEnabled: canUseSecrets),
			], width: 240, label: "More actions") { choice in
				showsTransferMenu = false
				switch choice {
				case .importing: onImport()
				case .exporting: onExport()
				}
			}
		}
	}

	private func matrix(_ derived: VaultContentDerivation) -> some View {
		GeometryReader { geometry in
			// Shown values are read side by side, so their columns keep a readable width and the table scrolls instead.
			let readsValues = derived.filteredKeys.contains(where: isShown)
			let layout = matrixLayout(derived, width: geometry.size.width, readsValues: readsValues)
			let tableWidth = max(geometry.size.width, layout.totalWidth + VaultMetrics.paneDividerHitWidth)
			let hidden = layout.hiddenColumns(at: matrixScrollX)

			ScrollView([.horizontal, .vertical]) {
				LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
					Section {
						if derived.filteredKeys.isEmpty {
							VaultTableEmptyRow(
								message: searchText.isEmpty ? "No keys in this view" : "No keys match your search",
								width: tableWidth
							)
						} else {
							ForEach(derived.filteredKeys, id: \.self) { key in
								VaultMatrixRow(
									key: key,
									project: project,
									snapshot: snapshot,
									environments: environments,
									layout: layout,
									tableWidth: tableWidth,
									isSelected: selectedKey == key,
									isRevealed: isShown(key),
									isPublic: shownPublicKeys.contains(key),
									isEdited: editedKeys.contains(key),
									checks: valueChecks,
									found: foundValues[key] ?? [],
									pinnedOffset: matrixScrollX,
									onSelect: {
										if snapshot.summaries[key] == nil {
											onAddKey(key)
										} else {
											selectedKey = key
											showsInspector = true
											if rowClicks.isDoubleClick(on: key) { toggleReveal(key) }
										}
									},
									onReveal: { toggleReveal(key) },
									onFindValue: { onFindValue(key, $0) }
								)
								.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
							}
						}
					} header: {
						VaultMatrixHeader(
							environments: environments,
							layout: layout,
							tableWidth: tableWidth,
							sortOrder: $sortOrder,
							onResize: { column, width in columnWidths.matrix.resize(column, to: width, in: layout) },
							onResizeActivity: onResizeColumns,
							pinnedOffset: matrixScrollX
						)
						.background(VaultPalette.headerRow)
						.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.sidebarBorder) }
					}
				}
				.frame(width: tableWidth, alignment: .leading)
				.frame(minHeight: geometry.size.height, alignment: .top)
				.onGeometryChange(for: CGFloat.self) { max(0, -$0.frame(in: .named(vaultMatrixSpace)).minX) } action: { matrixScrollX = $0 }
				.background { VaultHorizontalScroller(target: matrixScrollTarget) }
			}
			.coordinateSpace(.named(vaultMatrixSpace))
			.defaultScrollAnchor(.topLeading)
			// Columns out of view are named at the header's edges, where a click brings the nearest one whole into view.
			.overlay(alignment: .topLeading) {
				if !hidden.before.isEmpty {
					columnStep(hidden.before.reversed(), direction: .before,
						room: layout[.key] - VaultColumnStepButton.keyHeaderWidth - 18, layout: layout)
						.padding(.trailing, 8)
						.frame(width: layout[.key] - 1, height: VaultMetrics.tableHeader, alignment: .trailing)
				}
			}
			.overlay(alignment: .topTrailing) {
				if !hidden.after.isEmpty {
					columnStep(hidden.after, direction: .after, room: roomAfterLastTitle(layout: layout, hidden: hidden.after), layout: layout)
						.padding(.trailing, 8 + geometry.size.width - layout.available)
						.frame(height: VaultMetrics.tableHeader)
				}
			}
		}
	}

	/// The control naming `hidden`, the columns out of view on one side, nearest first, which brings the nearest whole into view.
	private func columnStep(_ hidden: [VaultTableColumn], direction: VaultColumnStepButton.Direction, room: CGFloat,
		layout: VaultTableColumnLayout) -> some View {
		let environments = hidden.compactMap { column -> (name: String, color: Color)? in
			guard case .environment(let environment) = column, let index = self.environments.firstIndex(of: environment) else { return nil }
			return (VaultProject.displayName(for: environment), VaultPalette.environment(index))
		}
		return VaultColumnStepButton(direction: direction, environments: environments, room: room) {
			guard let nearest = hidden.first else { return }
			matrixScrollTarget.scroll(to: layout.offset(showing: nearest, from: matrixScrollX))
		}
	}

	/// The matrix's columns in a view `width` wide. Columns that all fit leave
	/// the last one's resize handle its strip at the edge; when some wait past
	/// it, those in view fill the view, so the last one shown ends at its edge.
	private func matrixLayout(_ derived: VaultContentDerivation, width: CGFloat, readsValues: Bool) -> VaultTableColumnLayout {
		func layout(available: CGFloat) -> VaultTableColumnLayout {
			VaultTableColumnLayout(columns: [.key] + environments.map(VaultTableColumn.environment),
				available: available, requested: columnWidths.matrix.requested,
				keyWidth: VaultTableColumnLayout.keyWidth(for: derived.allKeys, publicKeys: shownPublicKeys, marks: 3),
				valueMinimum: readsValues ? VaultMetrics.readableValueColumn : nil)
		}
		let fitted = layout(available: width - VaultMetrics.paneDividerHitWidth)
		guard columnWidths.matrix.requested.isEmpty, fitted.totalWidth > fitted.available + 0.5 else { return fitted }
		return layout(available: width)
	}

	/// The room at the header's trailing edge past the title of the last column shown whole.
	private func roomAfterLastTitle(layout: VaultTableColumnLayout, hidden: [VaultTableColumn]) -> CGFloat {
		let visibleEnd = layout.available
		guard let first = hidden.first, let index = layout.boundaries.firstIndex(where: { $0.id == first }), index > 0 else { return visibleEnd }
		let last = layout.boundaries[index - 1]
		guard case .environment(let environment) = last.id else { return visibleEnd - layout[.key] }
		let titleEnd = last.position - layout[last.id] - matrixScrollX + VaultColumnStepButton.titleInset
			+ VaultColumnStepButton.headerTitleWidth(VaultProject.displayName(for: environment))
		return visibleEnd - titleEnd - 18
	}


	@ViewBuilder
	private func environmentDetail(_ derived: VaultContentDerivation, raw: VaultRawText?, editing: VaultRawTextEditing?) -> some View {
		if let editing {
			rawEditor(editing)
		} else if let raw {
			rawEnvironment(raw)
		} else {
			GeometryReader { geometry in
				let layout = VaultTableColumnLayout(columns: [.key, .value, .actions],
					available: geometry.size.width - VaultMetrics.paneDividerHitWidth, requested: columnWidths.environment.requested,
					keyWidth: VaultTableColumnLayout.keyWidth(for: derived.environmentKeys, publicKeys: shownPublicKeys, marks: 0))
				let tableWidth = max(geometry.size.width, layout.totalWidth + VaultMetrics.paneDividerHitWidth)
				ScrollView([.horizontal, .vertical]) {
					LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
						Section {
							environmentNotes(width: tableWidth)
							if derived.environmentKeys.isEmpty {
								VaultTableEmptyRow(message: emptyEnvironmentMessage, width: tableWidth)
							} else {
								ForEach(derived.environmentKeys, id: \.self) { key in
									let stored = project.value(for: key, in: selectedEnvironment)
									VaultEnvironmentRow(
										key: key,
										value: stored,
										layout: layout,
										tableWidth: tableWidth,
										isSelected: selectedKey == key,
										isRevealed: isShown(key),
										isPublic: shownPublicKeys.contains(key),
										isEdited: editedKeys.contains(key),
										problem: valueChecks.reason(for: key, in: selectedEnvironment),
										defaultValue: valueChecks.defaultValue(of: key, in: selectedEnvironment),
										isRequired: stored == nil && valueChecks.isRequiredAndUnset(key, in: selectedEnvironment),
										onSelect: {
											if stored == nil {
												onAddKey(key)
											} else {
												selectedKey = key
												showsInspector = true
											}
										},
										onReveal: { toggleReveal(key) },
										onCopy: { onCopySecret(key, selectedEnvironment) },
										onEdit: { selectedKey = key; showsInspector = true },
										onDelete: { onDeleteSecret(key, selectedEnvironment) },
										onAdd: { onAddKey(key) },
										canEdit: canEditValues,
										isFound: foundValues[key]?.contains(selectedEnvironment) == true,
										onFindValue: { onFindValue(key, selectedEnvironment) }
									)
									.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
								}
							}
						} header: {
							VaultEnvironmentHeader(layout: layout, tableWidth: tableWidth, sortOrder: $sortOrder,
								onResize: { column, width in columnWidths.environment.resize(column, to: width, in: layout) },
								onResizeActivity: onResizeColumns)
								.background(VaultPalette.headerRow)
								.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.sidebarBorder) }
						}
					}
					.frame(width: tableWidth, alignment: .leading)
					.frame(minHeight: geometry.size.height, alignment: .top)
				}
				.defaultScrollAnchor(.topLeading)
			}
		}
	}

	private var showsRawText: Bool {
		if case .environment = mode { return environmentViewMode == .raw }
		return false
	}

	/// Every stored key of the environment, whatever the search shows, in the table's order.
	private var rawEditOrder: [String] {
		let ascending = VaultKeySortOrder.sortedAscending(project.environments[selectedEnvironment].map { Array($0.keys) } ?? [])
		return sortOrder == .ascending ? ascending : ascending.reversed()
	}

	private func rawText(_ derived: VaultContentDerivation) -> VaultRawText {
		VaultRawText(keys: derived.environmentKeys, isShown: isShown, value: { project.value(for: $0, in: selectedEnvironment) })
	}

	private func rawEnvironment(_ text: VaultRawText) -> some View {
		GeometryReader { geometry in
			VStack(alignment: .leading, spacing: 0) {
				environmentNotes(width: geometry.size.width)
				if text.lines.isEmpty {
					VaultTableEmptyRow(message: emptyEnvironmentMessage, width: geometry.size.width)
					Spacer(minLength: 0)
				} else {
					rawCard(editing: false) {
						VaultRawTextView(
							text: text,
							label: "\(VaultProject.displayName(for: selectedEnvironment)) as text",
							selectedLineCount: $rawSelectedLineCount,
							onCopy: onCopyLines
						)
						// Another environment starts unselected, at its top.
						.id("\(project.id)/\(selectedEnvironment)")
					}
				}
			}
		}
	}

	private func rawEditor(_ editing: VaultRawTextEditing) -> some View {
		let draft = editing.draft
		let name = VaultProject.displayName(for: selectedEnvironment)
		return GeometryReader { geometry in
			VStack(alignment: .leading, spacing: 0) {
				environmentNotes(width: geometry.size.width)
				if let failure = editing.failure {
					rawFailureBanner(failure, editing: editing, width: geometry.size.width)
				}
				rawCard(editing: true) {
					VStack(spacing: 0) {
						VaultRawTextEditor(
							text: draft.text,
							problems: draft.check.problems,
							problemLines: draft.check.problemLines,
							warnings: editing.characterWarnings?.pills ?? [],
							label: "\(name) as text, editing",
							isEditable: !editing.isSaving,
							onChange: editing.onChange,
							onCopy: editing.onCopy
						)
						.id("\(project.id)/\(selectedEnvironment)")
						VaultHairline()
						rawEditorFooter(editing)
					}
				}
			}
		}
	}

	private func rawEditorFooter(_ editing: VaultRawTextEditing) -> some View {
		let draft = editing.draft
		let problems = draft.check.problems
		let state = problems.isEmpty
			? (draft.changes.count == 0 ? "No changes yet" : "Ready to save: \(draft.changes.summary)")
			: "\(problems.count.counted("problem")) · Save is available once every line is valid"
		let note = "Comments, blank lines and line order aren’t kept."
		return VStack(spacing: 0) {
			HStack(spacing: 8) {
				if problems.isEmpty {
					Text(state)
				} else {
					HStack(spacing: 5) {
						Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
						Text(problems.count.counted("problem"))
					}
					.fontWeight(.semibold)
					.foregroundStyle(VaultPalette.redText)
					Text("·")
					Text("Save is available once every line is valid")
				}
				Spacer(minLength: 12)
				Text(note)
			}
			.font(.system(size: 11.5))
			.foregroundStyle(VaultPalette.textTertiary)
			.lineLimit(1)
			.padding(.horizontal, 14)
			.frame(height: 30)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("\(state). \(note)")
			// The reasons are drawn beside their lines, which VoiceOver reads as plain text.
			.accessibilityValue(problems.map(\.message).joined(separator: ". "))
			if let warnings = editing.characterWarnings { rawCharacterWarnings(editing, warnings: warnings) }
		}
		.background(VaultPalette.headerRow)
	}

	/// The lines whose values hold characters that are hard to see, which
	/// never stop a save, with the fixes a person can choose for all of them.
	private func rawCharacterWarnings(_ editing: VaultRawTextEditing, warnings: VaultRawTextCharacterWarnings) -> some View {
		let summary = warnings.lines.count == 1 ? "1 line has hidden characters" : "\(warnings.lines.count) lines have hidden characters"
		return HStack(spacing: 14) {
			HStack(spacing: 5) {
				Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
				Text(summary).fontWeight(.semibold)
				Text("· saving keeps them")
			}
			.foregroundStyle(VaultPalette.orangeTintText)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("Warning: \(summary). Saving keeps them.")
			// The reasons are drawn beside their lines, which VoiceOver reads as plain text.
			.accessibilityValue(warnings.lines.map(\.message).joined(separator: ". "))
			Spacer(minLength: 8)
			if warnings.removable {
				rawFixButton("Remove hidden characters", disabled: editing.isSaving) { editing.onFixCharacters(.removeHiddenCharacters) }
			}
			if warnings.trimmable {
				rawFixButton("Trim the ends", disabled: editing.isSaving) { editing.onFixCharacters(.trimEnds) }
			}
		}
		.font(.system(size: 11.5))
		.lineLimit(1)
		.padding(.horizontal, 14)
		.frame(height: 28)
	}

	private func rawFixButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
		Button(title, action: action)
			.buttonStyle(.plain)
			.font(.system(size: 11.5, weight: .semibold))
			.foregroundStyle(disabled ? VaultPalette.textFaint : VaultPalette.accentForeground)
			.disabled(disabled)
			.fixedSize()
			.vaultPointingHand(enabled: !disabled)
	}

	private func rawFailureBanner(_ failure: VaultRawTextFailure, editing: VaultRawTextEditing, width: CGFloat) -> some View {
		let name = VaultProject.displayName(for: selectedEnvironment)
		return HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.redText)
				.accessibilityHidden(true)
			switch failure {
			case .changed:
				Text("\(name) changed meanwhile, as by the LPM CLI, so nothing was saved. Compare your edit with its current values to save over them.")
					.lineLimit(2)
				Spacer(minLength: 8)
				Button("Compare with current values", action: editing.onCompare)
					.buttonStyle(.plain)
					.font(.system(size: 11.5, weight: .medium))
					.foregroundStyle(VaultPalette.accentForeground)
					.vaultPointingHand()
					.disabled(editing.isSaving)
			case .failed(let message):
				Text(message).lineLimit(2)
				Spacer(minLength: 0)
			}
		}
		.font(.system(size: 12))
		.foregroundStyle(VaultPalette.textSecondary)
		.padding(.horizontal, 20)
		.padding(.vertical, 8)
		.frame(width: width, alignment: .leading)
		.background(VaultPalette.redTint.opacity(0.6))
		.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
	}

	/// Raw text's card, with what was just copied or saved floating at its foot.
	private func rawCard<Content: View>(editing: Bool, @ViewBuilder content: () -> Content) -> some View {
		content()
			.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay {
				RoundedRectangle(cornerRadius: 10)
					.strokeBorder(editing ? VaultPalette.accent : VaultPalette.border, lineWidth: editing ? 1.5 : 1)
			}
			.overlay(alignment: .bottom) {
				rawToast
					.padding(.bottom, editing ? 44 : 14)
			}
			.padding(.horizontal, 20)
			.padding(.top, 12)
			.padding(.bottom, 14)
	}

	@ViewBuilder
	private var rawToast: some View {
		if let copiedLineCount {
			VaultToast {
				Image(systemName: "checkmark")
					.font(.system(size: 11, weight: .bold))
					.foregroundStyle(VaultPalette.toastConfirmation)
					.accessibilityHidden(true)
				Text("Copied \(copiedLineCount.counted("line")) ")
					+ Text("· clears in \(Int(VaultConstants.clipboardClearDelay))s").foregroundStyle(VaultPalette.toastSecondaryText)
			}
		} else if let rawSaved, rawSaved.receipt.projectId == project.id, rawSaved.receipt.environment == selectedEnvironment {
			savedToast(rawSaved)
		}
	}

	private func savedToast(_ saved: VaultRawTextSaved) -> some View {
		let name = VaultProject.displayName(for: saved.receipt.environment)
		return VaultToast(hasButton: saved.undo == .available || saved.undo == .undoing) {
			switch saved.undo {
			case .available, .undoing:
				Image(systemName: "checkmark")
					.font(.system(size: 11, weight: .bold))
					.foregroundStyle(VaultPalette.toastConfirmation)
					.accessibilityHidden(true)
				Text("Saved \(name) · \(saved.summary)")
				Button(action: onUndoRawSave) {
					Label(saved.undo == .undoing ? "Undoing…" : "Undo", systemImage: "arrow.uturn.backward")
						.font(.system(size: 12, weight: .semibold))
						.foregroundStyle(VaultPalette.toastAction)
				}
				.buttonStyle(.plain)
				.vaultPointingHand()
				.disabled(saved.undo == .undoing)
				.help("Put \(name) back as it was")
				Rectangle()
					.fill(VaultPalette.toastDivider)
					.frame(width: 1, height: 16)
					.accessibilityHidden(true)
				TimelineView(.periodic(from: saved.savedAt, by: 1)) { context in
					let left = VaultFeedbackTimer.undoSeconds - Int(context.date.timeIntervalSince(saved.savedAt))
					Text("\(max(0, left))s")
						.font(VaultTypography.tabular(11))
						.foregroundStyle(VaultPalette.toastSecondaryText)
						.accessibilityLabel("\(max(0, left)) seconds left to undo")
				}
			case .undone:
				Image(systemName: "arrow.uturn.backward")
					.font(.system(size: 11, weight: .bold))
					.foregroundStyle(VaultPalette.toastConfirmation)
					.accessibilityHidden(true)
				Text("Put \(name) back as it was")
			case .failed(let message):
				Image(systemName: "exclamationmark.triangle.fill")
					.font(.system(size: 11, weight: .bold))
					.foregroundStyle(VaultPalette.orange)
					.accessibilityHidden(true)
				Text(message)
			}
		}
	}

	/// What the environment's keys come with, in the table and in raw text:
	/// that the LPM CLI reads another environment's values, and its rules'
	/// failed groups.
	@ViewBuilder
	private func environmentNotes(width: CGFloat) -> some View {
		if valueChecks.readsDefaultEnvironment(selectedEnvironment) {
			Text("The LPM CLI reads values from .env and checks this environment’s rules.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
				.padding(.horizontal, 20)
				.frame(width: width, height: 34, alignment: .leading)
		}
		ForEach(valueChecks.groupFailures(in: selectedEnvironment)) { failure in
			VaultGroupFailureBanner(failure: failure, width: width,
				onFixInTable: environmentViewMode == .raw ? { environmentViewMode = .table } : nil)
		}
	}

	private var emptyEnvironmentMessage: String {
		if !searchText.isEmpty { return "No keys match your search" }
		return valueChecks.readsDefaultEnvironment(selectedEnvironment)
			? "No values here. The LPM CLI uses \(VaultProject.displayName(for: "default"))’s values for this environment."
			: "No secrets in this environment"
	}

	private func statusBar(_ derived: VaultContentDerivation, raw: VaultRawText?, editing: VaultRawTextEditing?) -> some View {
		var unsavedParts: [String] = []
		if !editedKeys.isEmpty {
			unsavedParts.append(editedKeys.count == 1 ? "1 key with unsaved changes" : "\(editedKeys.count) keys with unsaved changes")
		}
		// The table shows saved values; an edit of them as Raw text waits there.
		if let draft = rawEditing?.draft, editing == nil, draft.changes.count > 0 || !draft.check.problems.isEmpty {
			unsavedParts.append("Raw text edit not saved")
		}
		let unsaved = unsavedParts.isEmpty ? nil : unsavedParts.joined(separator: " · ")
		let counts = VaultSmartViewCounts(snapshot: snapshot, checks: valueChecks)
		return Group {
			if let editing {
				editStatus(editing.draft, counts: counts)
			} else if let raw {
				rawStatus(raw, unsaved: unsaved, counts: counts)
			} else {
				tableStatus(derived, unsaved: unsaved, counts: counts)
			}
		}
		.font(.system(size: 11))
		.foregroundStyle(VaultPalette.textTertiary)
		.lineLimit(1)
		.padding(.horizontal, 20)
		.frame(height: VaultMetrics.statusBar)
		.background(VaultPalette.headerRow)
	}

	/// An edit counts its lines, what saving would change and its problems.
	private func editStatus(_ draft: VaultRawTextDraft, counts: VaultSmartViewCounts) -> some View {
		var items = [Text(draft.check.lineCount.counted("line"))]
		if draft.changes.count > 0 {
			items.append(Text(draft.changes.parts.joined(separator: " · ")))
		}
		if !draft.check.problems.isEmpty {
			items.append(Text(draft.check.problems.count.counted("problem")).foregroundStyle(VaultPalette.redText))
		}
		let essential = Array(items.prefix(1)) + Array(items.dropFirst(2))
		return ViewThatFits(in: .horizontal) {
			statusLine(items, unsaved: nil, links: .full, counts: counts)
			statusLine(essential, unsaved: nil, links: .full, counts: counts)
			statusLine(essential, unsaved: nil, links: .compact, counts: counts)
			statusLine(essential, unsaved: nil, links: .hidden, counts: counts)
		}
	}

	/// Raw text counts lines, says whether their values show, and what's
	/// selected; a narrow bar keeps the count and unsaved changes.
	private func rawStatus(_ raw: VaultRawText, unsaved: String?, counts: VaultSmartViewCounts) -> some View {
		let lines = raw.lines
		let maskable = lines.filter { !shownPublicKeys.contains($0.key) }
		let revealed = maskable.lazy.filter(\.isShown).count
		var items = [Text(lines.count.counted("line"))]
		if !maskable.isEmpty {
			items.append(revealed == 0
				? Text("values masked")
				: Text(revealed == maskable.count ? "values revealed" : "some values revealed").foregroundStyle(VaultPalette.orangeTintText))
		}
		if !lines.isEmpty {
			items.append(Text(rawSelectedLineCount > 0 ? "\(rawSelectedLineCount.counted("line")) selected" : "⌘A selects all"))
		}
		return ViewThatFits(in: .horizontal) {
			statusLine(items, unsaved: unsaved, links: .full, counts: counts)
			statusLine(Array(items.prefix(2)), unsaved: unsaved, links: .full, counts: counts)
			statusLine(Array(items.prefix(1)), unsaved: unsaved, links: .full, counts: counts)
			statusLine(Array(items.prefix(1)), unsaved: unsaved, links: .compact, counts: counts)
			statusLine(Array(items.prefix(1)), unsaved: unsaved, links: .hidden, counts: counts)
		}
	}

	/// A narrow bar drops the sort order first, which the KEY header also shows,
	/// then names only the smart views' counts, then leaves them out. The key
	/// count and unsaved changes always stay.
	private func tableStatus(_ derived: VaultContentDerivation, unsaved: String?, counts: VaultSmartViewCounts) -> some View {
		// Said as All Keys says it, so the header's totals aren't repeated in other words.
		let count = Text(mode == .matrix
			? "\(derived.filteredKeys.count) of \(derived.allKeys.count.counted("key")) shown"
			: "\(derived.environmentKeys.count) of \(derived.environmentKeyCount.counted("key")) shown")
		let sort = Text("sorted \(sortOrder.title)").accessibilityLabel("sorted \(sortOrder.spokenTitle)")
		let details: [Text] = []
		return ViewThatFits(in: .horizontal) {
			statusLine([count, sort] + details, unsaved: unsaved, links: .full, counts: counts)
			statusLine([count], unsaved: unsaved, links: .full, counts: counts)
			statusLine([count], unsaved: unsaved, links: .compact, counts: counts)
			statusLine([count], unsaved: unsaved, links: .hidden, counts: counts)
		}
	}

	/// How a status line shows its links to the smart views.
	private enum StatusLinks {
		case full, compact, hidden
	}

	/// What's on the page, then the project's smart views at the trailing end,
	/// in the same place on every page.
	private func statusLine(_ items: [Text], unsaved: String?, links: StatusLinks, counts: VaultSmartViewCounts) -> some View {
		HStack(spacing: 12) {
			ForEach(items.indices, id: \.self) { index in
				if index > 0 { Text("·") }
				items[index]
			}
			if let unsaved {
				Text("·")
				Text(unsaved).foregroundStyle(VaultPalette.orangeTintText)
			}
			Spacer(minLength: 0)
			// All Keys counts these in its filter chips; elsewhere they're the project's, and say so.
			if links != .hidden, mode != .matrix {
				VaultSmartViewLinks(counts: counts, scope: "Project", compact: links == .compact) { view in
					mode = .matrix
					filter = view.filter
				}
			}
		}
	}

	/// Public values show unmasked only while secret actions are available.
	private var shownPublicKeys: Set<String> { canUseSecrets ? publicKeys : [] }

	private func isShown(_ key: String) -> Bool {
		canUseSecrets && (revealedKeys.contains(key) || publicKeys.contains(key))
	}

	private func toggleRevealAll(_ derived: VaultContentDerivation) {
		guard canUseSecrets else { return }
		let keys = (mode == .matrix ? derived.filteredKeys : derived.environmentKeys).filter { !publicKeys.contains($0) }
		if keys.allSatisfy(revealedKeys.contains) {
			revealedKeys.subtract(keys)
		} else {
			revealedKeys.formUnion(keys)
		}
	}

	private func toggleReveal(_ key: String) {
		guard canUseSecrets, !publicKeys.contains(key) else { return }
		if revealedKeys.contains(key) { revealedKeys.remove(key) } else { revealedKeys.insert(key) }
	}
}

private struct VaultMatrixHeader: View {
	let environments: [String]
	let layout: VaultTableColumnLayout
	let tableWidth: CGFloat
	@Binding var sortOrder: VaultKeySortOrder
	let onResize: (VaultTableColumn, CGFloat) -> Void
	let onResizeActivity: () -> Void
	var pinnedOffset: CGFloat = 0

	var body: some View {
		HStack(spacing: 0) {
			HStack(spacing: 0) {
				VaultKeySortHeader(order: $sortOrder)
					.frame(width: layout[.key])
				VaultTableColumnLine()
			}
			.vaultPinnedColumn(offset: pinnedOffset) { VaultPalette.headerRow }

			ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
				HStack(spacing: 7) {
					VaultEnvSwatch(color: VaultPalette.environment(index))
					Text(VaultProject.displayName(for: environment))
						.vaultColumnHeader()
						.lineLimit(1)
						.truncationMode(.tail)
					Spacer(minLength: 2)
				}
				.padding(.horizontal, 12)
				.frame(width: layout[.environment(environment)] - 1)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(VaultProject.displayName(for: environment))
				.accessibilityAddTraits(.isHeader)
				VaultTableColumnLine(hidden: environment == environments.last || layout.endsAtEdge(.environment(environment), offset: pinnedOffset))
			}
		}
		.frame(width: tableWidth, height: VaultMetrics.tableHeader, alignment: .leading)
		.overlay { VaultTableResizeHandles(layout: layout, onResize: onResize, onActivity: onResizeActivity) }
	}
}

/// Which clicks on the matrix's rows make a double-click, which reveals the
/// row's values: two on the same row within the system's double-click time.
/// A click on any other row in between starts over, as AppKit counts clicks;
/// SwiftUI's tap gesture would count the two as a double-click anyway.
@MainActor
final class VaultRowClicks {
	private var last: (key: String, time: TimeInterval)?
	private let now: () -> TimeInterval
	private let interval: TimeInterval

	init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
		interval: TimeInterval = NSEvent.doubleClickInterval) {
		self.now = now
		self.interval = interval
	}

	/// Records a click on `key`'s row; true when it completes a double-click.
	/// The click after a double-click starts a new one.
	func isDoubleClick(on key: String) -> Bool {
		let time = now()
		if let last, last.key == key, time - last.time <= interval {
			self.last = nil
			return true
		}
		last = (key, time)
		return false
	}
}

/// The line after a table column, drawn alike in the header and the rows so
/// each column's edge runs straight down the table.
private struct VaultTableColumnLine: View {
	/// Keeps the line's point but doesn't draw it: after the last column, so the
	/// table doesn't end in a sliver of an empty column, and between columns that read as one.
	var hidden = false

	var body: some View {
		VaultHairline(color: hidden ? .clear : VaultPalette.rowDivider, axis: .vertical)
	}
}

private struct VaultMatrixRow: View {
	let key: String
	let project: VaultProject
	let snapshot: VaultWorkspaceSnapshot
	let environments: [String]
	let layout: VaultTableColumnLayout
	let tableWidth: CGFloat
	let isSelected: Bool
	let isRevealed: Bool
	let isPublic: Bool
	let isEdited: Bool
	var checks: VaultValueCheckPresentation = .none
	/// The environments where a value search found the key's value.
	var found: Set<String> = []
	/// How far the table has scrolled sideways, which the key cell moves back by to stay in view.
	var pinnedOffset: CGFloat = 0
	let onSelect: () -> Void
	let onReveal: () -> Void
	var onFindValue: (_ environment: String) -> Void = { _ in }

	@State private var hovering = false

	/// The environments that store a value of the key, which a value search can look for.
	private var searchable: [String] {
		environments.filter { project.value(for: key, in: $0)?.isEmpty == false }
	}

	var body: some View {
		Button(action: onSelect) {
			HStack(spacing: 0) {
				HStack(spacing: 0) {
				HStack(spacing: 8) {
					Text(key)
						.font(VaultTypography.tabular(13, .medium))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.middle)
						.layoutPriority(1)
					if isPublic { VaultPublicBadge(compact: true) }
					if isEdited { VaultUnsavedBadge() }
					if !found.isEmpty { ValueSearchFoundBadge() }
					Spacer(minLength: 0)
					VaultKeyStatusMarks(
						invalid: checks.invalidKeys.contains(key),
						missing: snapshot.isMissingSomewhere(key),
						drifts: snapshot.hasDrift(for: key),
						slotted: true,
						emphasized: hovering || isSelected
					)
				}
				.padding(.leading, 20)
				.padding(.trailing, 14)
				.frame(width: layout[.key])
				VaultTableColumnLine()
				}
				.vaultPinnedColumn(offset: pinnedOffset) { VaultRowFill(selected: isSelected, hovering: hovering, resting: VaultPalette.content) }

				ForEach(environments, id: \.self) { environment in
					HStack(spacing: 6) {
						let stored = project.value(for: key, in: environment)
						VaultCheckedValue(
							value: stored,
							isRevealed: isRevealed,
							problem: checks.reason(for: key, in: environment),
							defaultValue: checks.defaultValue(of: key, in: environment),
							isRequired: stored == nil && checks.isRequiredAndUnset(key, in: environment),
							size: 11.5
						)
						if found.contains(environment) { ValueSearchFoundMark() }
						Spacer(minLength: 0)
					}
					.padding(.horizontal, 12)
					.frame(width: layout[.environment(environment)] - 1, height: VaultMetrics.matrixRow)
					VaultTableColumnLine(hidden: environment == environments.last || layout.endsAtEdge(.environment(environment), offset: pinnedOffset))
				}
			}
			.frame(width: tableWidth, height: VaultMetrics.matrixRow, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.frame(height: VaultMetrics.matrixRow)
		.background { VaultRowFill(selected: isSelected, hovering: hovering) }
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(key), set in \(snapshot.environmentCount(for: key)) of \(environments.count) environments\(isPublic ? ", public" : ""), values \(isRevealed ? "shown" : "hidden")\(checks.invalidKeys.contains(key) ? ", fails its rules" : "")\(isEdited ? ", unsaved changes" : "")\(found.isEmpty ? "" : ", found by value search")")
		.accessibilityValue(snapshot.hasDrift(for: key) ? "Values differ" : "Values consistent")
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.accessibilityAction(named: isRevealed ? "Hide values" : "Reveal values", onReveal)
		.accessibilityActions {
			ForEach(searchable, id: \.self) { environment in
				Button("Find where the \(VaultProject.displayName(for: environment)) value is used") { onFindValue(environment) }
			}
		}
		.contextMenu { findValueMenu }
	}

	@ViewBuilder
	private var findValueMenu: some View {
		let searchable = searchable
		if searchable.count == 1, let environment = searchable.first {
			Button("Find Where This Value Is Used") { onFindValue(environment) }
		} else if !searchable.isEmpty {
			Menu("Find Where This Value Is Used") {
				ForEach(searchable, id: \.self) { environment in
					Button(VaultProject.displayName(for: environment)) { onFindValue(environment) }
				}
			}
		}
	}
}

private struct VaultEnvironmentHeader: View {
	let layout: VaultTableColumnLayout
	let tableWidth: CGFloat
	@Binding var sortOrder: VaultKeySortOrder
	let onResize: (VaultTableColumn, CGFloat) -> Void
	let onResizeActivity: () -> Void

	var body: some View {
		HStack(spacing: 0) {
			VaultKeySortHeader(order: $sortOrder).frame(width: layout[.key])
			VaultTableColumnLine()
			Text("Value").vaultColumnHeader().padding(.horizontal, 12).frame(width: layout[.value] - 1, alignment: .leading)
			// The actions column belongs to the value: no line between them, and no header of its own on screen.
			VaultTableColumnLine(hidden: true)
			Color.clear.frame(width: layout[.actions] - 1, height: VaultMetrics.tableHeader)
				.accessibilityElement()
				.accessibilityLabel("Actions")
				.accessibilityAddTraits(.isHeader)
			VaultTableColumnLine(hidden: true)
		}
		.frame(width: tableWidth, height: VaultMetrics.tableHeader, alignment: .leading)
		.overlay { VaultTableResizeHandles(layout: layout, onResize: onResize, onActivity: onResizeActivity) }
	}
}

private struct VaultTableResizeHandles: View {
	let layout: VaultTableColumnLayout
	let onResize: (VaultTableColumn, CGFloat) -> Void
	let onActivity: () -> Void

	var body: some View {
		ZStack(alignment: .topLeading) {
			ForEach(layout.boundaries) { boundary in
				VaultPaneResizeHandle(
					width: Binding(get: { layout[boundary.id] }, set: { onResize(boundary.id, $0) }),
					bounds: VaultPaneBounds(width: layout[boundary.id], minimum: boundary.id.minimumWidth,
						maximum: .greatestFiniteMagnitude),
					edge: .trailing,
					accessibilityLabel: "Resize \(boundary.id.title) column",
					onResize: onActivity
				)
				.frame(height: VaultMetrics.tableHeader)
				// Centered on the column's line, which starts at the boundary.
				.offset(x: boundary.position - (VaultMetrics.paneDividerHitWidth - VaultMetrics.paneDivider) / 2)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}

private struct VaultEnvironmentRow: View {
	let key: String
	/// The stored value; nil for a declared key that only a rule or a default shows.
	let value: String?
	let layout: VaultTableColumnLayout
	let tableWidth: CGFloat
	let isSelected: Bool
	let isRevealed: Bool
	let isPublic: Bool
	let isEdited: Bool
	/// Why the value fails its rules, one reason per line.
	var problem: String?
	var defaultValue: String?
	var isRequired = false
	let onSelect: () -> Void
	let onReveal: () -> Void
	let onCopy: () -> Void
	let onEdit: () -> Void
	let onDelete: () -> Void
	var onAdd: () -> Void = {}
	var canEdit = true
	/// A value search found the value.
	var isFound = false
	var onFindValue: () -> Void = {}

	@State private var hovering = false

	var body: some View {
		HStack(spacing: 0) {
			ViewThatFits(in: .horizontal) {
				keyLabel(compact: false)
				keyLabel(compact: true)
			}
			.padding(.leading, 20)
			.padding(.trailing, 14)
			.frame(width: layout[.key], alignment: .leading)
			VaultTableColumnLine()

			HStack(spacing: 6) {
				VaultCheckedValue(value: value, isRevealed: isRevealed, problem: problem, defaultValue: defaultValue,
					isRequired: isRequired, showsNotSet: false, size: 12)
				if isFound { ValueSearchFoundMark() }
			}
				.padding(.horizontal, 12)
				.frame(width: layout[.value] - 1, alignment: .leading)
			VaultTableColumnLine(hidden: true)

			// The actions show on the row under the pointer and the selected row,
			// and stay in place, pressable and named, on the others.
			HStack(spacing: 2) {
				if value == nil {
					// Rests with the row's other actions; the row already says the value is missing.
					VaultOutlineButton(systemImage: "plus", title: "Add Value", help: "Add a value for \(key)", label: "Add Value for \(key)",
						disabled: !canEdit, borderless: true, resting: !showsActions, action: onAdd)
				} else {
					VaultRowIconButton(systemImage: isRevealed ? "eye.slash" : "eye", help: isRevealed ? "Hide value" : "Reveal value",
						resting: !showsActions, action: onReveal)
						.hidden(isPublic)
					VaultRowIconButton(systemImage: "doc.on.doc", help: "Copy key and value", resting: !showsActions, action: onCopy)
					VaultRowIconButton(systemImage: "pencil", help: "Edit key and value", disabled: !canEdit, resting: !showsActions, action: onEdit)
					// Set apart from the actions that only read or edit, so it isn't hit in passing.
					VaultRowIconButton(systemImage: "trash", help: "Delete from this environment", destructive: true, disabled: !canEdit,
						resting: !showsActions, action: onDelete)
						.padding(.leading, 10)
				}
			}
			.padding(.trailing, 14)
			.frame(width: layout[.actions] - 1, alignment: .trailing)
			VaultTableColumnLine(hidden: true)
		}
		.frame(width: tableWidth, height: VaultMetrics.fileRow, alignment: .leading)
		.background { VaultRowFill(selected: isSelected, hovering: hovering) }
		.contentShape(Rectangle())
		.onTapGesture(perform: onSelect)
		.onHover { hovering = $0 }
		.contextMenu {
			if value?.isEmpty == false {
				Button("Find Where This Value Is Used", action: onFindValue)
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(accessibilityText)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.accessibilityActions {
			if value?.isEmpty == false {
				Button("Find where this value is used", action: onFindValue)
			}
		}
	}

	private var accessibilityText: String {
		var parts = [key]
		if isPublic { parts.append("public") }
		if let defaultValue {
			parts.append("default \(defaultValue)")
		} else if value == nil {
			parts.append(isRequired ? "required, no value" : "no value")
		} else {
			parts.append("value \(isRevealed ? "shown" : "hidden")")
		}
		if let problem { parts.append(problem.replacingOccurrences(of: "\n", with: ", ")) }
		if isEdited { parts.append("unsaved changes") }
		if isFound { parts.append("found by value search") }
		return parts.joined(separator: ", ")
	}

	/// The actions show on the hovered and the selected row.
	private var showsActions: Bool { hovering || isSelected }

	private func keyLabel(compact: Bool) -> some View {
		HStack(spacing: 8) {
			Text(key)
				.font(VaultTypography.tabular(13, .medium))
				.foregroundStyle(VaultPalette.textPrimary)
				.lineLimit(1)
				.layoutPriority(1)
			if isPublic { VaultPublicBadge(compact: true) }
			if isEdited {
				if compact {
					VaultStatusDot(color: VaultPalette.orange).help("Unsaved changes").accessibilityLabel("Unsaved changes")
				} else {
					VaultUnsavedBadge()
				}
			}
			if isFound && !compact { ValueSearchFoundBadge() }
			Spacer(minLength: 0)
			// No marks beside the key: with one value per row, the value's cell says what's wrong
			// in words, and drift is between environments.
		}
	}
}

/// The KEY column header. Clicking it reverses the key order, like a Finder
/// column header.
struct VaultKeySortHeader: View {
	@Binding var order: VaultKeySortOrder
	@State private var hovering = false

	var body: some View {
		Button { order = order.reversed } label: {
			HStack(spacing: 6) {
				Text("Key").vaultColumnHeader()
				// The arrow says the order; the status bar spells it out.
				Image(systemName: order == .ascending ? "arrow.up" : "arrow.down")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(VaultPalette.accentForeground)
				Spacer(minLength: 0)
			}
			.padding(.leading, 20)
			.padding(.trailing, 12)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
			.background(hovering ? VaultPalette.headerHover : .clear)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help("Sort keys \(order.reversed.spokenTitle)")
		.accessibilityLabel("Key")
		.accessibilityValue("Sorted \(order.spokenTitle)")
	}
}

/// A group whose relation fails in the environment, above its members' rows.
private struct VaultGroupFailureBanner: View {
	let failure: VaultValueCheckPresentation.GroupFailure
	let width: CGFloat
	/// Shows the table, where the group's keys can be fixed, from Raw text.
	var onFixInTable: (() -> Void)?

	var body: some View {
		HStack(spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: "xmark.circle")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(VaultPalette.redText)
				Text(failure.message)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.accessibilityElement(children: .combine)
			.help(failure.message)
			Spacer(minLength: 0)
			if let onFixInTable {
				Button("Fix in table", action: onFixInTable)
					.buttonStyle(.plain)
					.font(.system(size: 11.5, weight: .medium))
					.foregroundStyle(VaultPalette.accentForeground)
					.vaultPointingHand()
					.help("Show this environment as a table, to change its values")
			}
		}
		.padding(.horizontal, 20)
		.frame(width: width, height: 34, alignment: .leading)
		.background(VaultPalette.redTint.opacity(0.6))
		.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
	}
}

private struct VaultUnsavedBadge: View {
	var body: some View {
		VaultTagBadge(text: "UNSAVED", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 9)
			.help("This key has unsaved changes in the inspector")
	}
}

private struct VaultTableEmptyRow: View {
	let message: String
	let width: CGFloat

	var body: some View {
		VStack(spacing: 8) {
			Image(systemName: "key").font(.system(size: 26)).foregroundStyle(VaultPalette.textFaint)
			Text(message).font(.system(size: 13)).foregroundStyle(VaultPalette.textTertiary)
		}
		.frame(width: width, height: 180)
	}
}

struct VaultWorkspaceEmptyView: View {
	let isSearching: Bool
	/// Whether this Mac has any project; with none, the first screen welcomes and offers a restore.
	var hasProjects = true
	let onCreate: () -> Void
	let onImport: () -> Void
	var onRestore: () -> Void = {}

	private var welcomes: Bool { !hasProjects && !isSearching }

	var body: some View {
		VStack(spacing: 12) {
			VaultAppMark(size: 42)
			Text(isSearching ? "No matching env projects" : welcomes ? "Welcome to LPM Vault" : "Select an env project")
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
			Text(isSearching
				? "Try another project or key name."
				: welcomes
					? "Your project’s environment variables, encrypted in this Mac’s Keychain and read by the LPM CLI."
					: "Create a local project or import one from lpm.dev.")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 380)
			if !isSearching {
				HStack(spacing: 8) {
					VaultBarButton(title: "Create Project", filled: true, action: onCreate)
					VaultBarButton(systemImage: "icloud.and.arrow.down", title: "Import from lpm.dev…", action: onImport)
				}
			}
			if welcomes {
				VStack(spacing: 3) {
					Button("Restore from a Backup", action: onRestore)
						.buttonStyle(.plain)
						.font(.system(size: 12.5, weight: .semibold))
						.foregroundStyle(VaultPalette.accentForeground)
						.vaultPointingHand()
					Text("Moving from another Mac? Bring your projects and settings over in one step.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.padding(.top, 6)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(VaultPalette.content)
	}
}
