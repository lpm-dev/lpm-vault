import SwiftUI

struct VaultCliAccessPresentation {
	let access: VaultCliAccess?
	var help: String {
		switch access {
		case .requireApproval: "CLI access requires Touch ID or your Mac login password."
		case .automatic: "CLI access automatically injects env values."
		case nil: "CLI approval is unavailable until its policy can be read."
		}
	}
	var accessibilityValue: String {
		switch access {
		case .requireApproval: "Required"
		case .automatic: "Automatic"
		case nil: "Unavailable"
		}
	}
}

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
	let isImporting: Bool
	let isCopyingAll: Bool
	var isCopiedAll = false
	var canUseSecrets = true
	let cliAccess: VaultCliAccess?
	let isChangingCliAccess: Bool
	let onChangeCliAccess: (VaultCliAccess) -> Void
	let onCopyAll: () -> Void
	let onImport: () -> Void
	let onExport: () -> Void
	/// Keys with unsaved edits in this project.
	var editedKeys: Set<String> = []
	let onAddSecret: () -> Void
	let onCopySecret: (String, String) -> Void
	let onDeleteSecret: (String, String) -> Void
	let onResizeColumns: () -> Void

	var body: some View {
		let derived = VaultContentDerivation(
			project: project,
			snapshot: snapshot,
			selectedEnvironment: selectedEnvironment,
			mode: mode,
			filter: filter,
			searchText: searchText,
			sortOrder: sortOrder,
			revealedKeys: canUseSecrets ? revealedKeys : []
		)
		VStack(spacing: 0) {
			header(derived)
			VaultHairline()

			switch mode {
			case .matrix:
				matrix(derived)
			case .environment:
				environmentDetail(derived)
			case .schema:
				// The workspace shows the Schema page instead of this view.
				Spacer(minLength: 0)
			}

			VaultHairline()
			statusBar(derived)
		}
		.background(VaultPalette.content)
	}

	/// The first row is about the project: what it is, its CLI approval, the
	/// inspector, and a new key. The second is about what is on screen: how it is
	/// filtered or shown, and the actions on those values.
	private func header(_ derived: VaultContentDerivation) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 10) {
					headerIdentity
					Spacer(minLength: 8)
					projectActions
				}
				VStack(alignment: .leading, spacing: 10) {
					headerIdentity
					projectActions.frame(maxWidth: .infinity, alignment: .trailing)
				}
			}

			ViewThatFits(in: .horizontal) {
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
				VStack(alignment: .leading, spacing: 10) {
					HStack(spacing: 6) { viewControls }
					valueActions(compact: true, derived: derived).frame(maxWidth: .infinity, alignment: .trailing)
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 16)
		.padding(.bottom, 12)
	}

	@ViewBuilder
	private var viewControls: some View {
		if case .matrix = mode {
			ForEach(VaultWorkspaceFilter.allCases) { candidate in
				VaultFilterChip(
					title: candidate.rawValue,
					dot: candidate == .drift ? VaultPalette.orange : (candidate == .missing ? VaultPalette.red : nil),
					trailing: candidate == .drift
						? "\(snapshot.driftingKeyCount)"
						: (candidate == .missing ? "\(snapshot.missingKeyCount)" : nil),
					selected: filter == candidate
				) { filter = candidate }
			}
		} else {
			ForEach(VaultEnvironmentViewMode.allCases) { candidate in
				VaultFilterChip(title: candidate.rawValue, selected: environmentViewMode == candidate) {
					environmentViewMode = candidate
				}
			}
		}
	}

	@ViewBuilder
	private var headerIdentity: some View {
		HStack(spacing: 10) {
			if case .matrix = mode {
				Text("All variables")
					.font(.system(size: 19, weight: .bold))
					.tracking(-0.28)
					.foregroundStyle(VaultPalette.textPrimary)
				Text("\(Self.count(snapshot.allSecretKeys.count, "key")) · \(Self.count(environments.count, "env"))")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			} else {
				Text(VaultProject.displayName(for: selectedEnvironment))
					.font(VaultTypography.mono(19, .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				VaultTagBadge(
					text: selectedEnvironment == "default" ? "LOCAL" : selectedEnvironment.uppercased(),
					foreground: VaultPalette.orangeTintText,
					background: VaultPalette.orangeTint
				)
				Text(Self.count(project.secretCount(for: selectedEnvironment), "key"))
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			Toggle("CLI approval", isOn: Binding(
				get: { cliAccess == .requireApproval },
				set: { onChangeCliAccess($0 ? .requireApproval : .automatic) }
			))
			.toggleStyle(.switch)
			.controlSize(.mini)
			.font(.system(size: 11.5))
			.disabled(cliAccess == nil || isChangingCliAccess || !canUseSecrets)
			.help(VaultCliAccessPresentation(access: cliAccess).help)
			.accessibilityLabel("Require approval for CLI env access")
			.accessibilityValue(VaultCliAccessPresentation(access: cliAccess).accessibilityValue)
		}
		.lineLimit(1)
		.fixedSize(horizontal: true, vertical: false)
	}

	private var projectActions: some View {
		HStack(spacing: 6) {
			VaultOutlineButton(
				systemImage: "sidebar.right",
				help: showsInspector ? "Hide inspector" : "Show inspector",
				active: showsInspector
			) { showsInspector.toggle() }
			VaultBarButton(
				systemImage: "plus",
				title: "New key",
				filled: true,
				height: 27,
				action: onAddSecret
			)
			.accessibilityLabel("New secret")
		}
		.fixedSize()
	}

	/// Reveal acts on the keys in view; copying, importing, and exporting act on
	/// the selected environment, which their help names.
	private func valueActions(compact: Bool, derived: VaultContentDerivation) -> some View {
		let environmentName = VaultProject.displayName(for: selectedEnvironment)
		let copyTitle = isCopyingAll ? "Copying…" : (isCopiedAll ? "Copied" : "Copy all")
		let copyHelp = isCopyingAll
			? "Authenticating to copy all \(environmentName) values"
			: (isCopiedAll ? "All \(environmentName) values copied" : "Copy all \(environmentName) values")
		return HStack(spacing: 6) {
			VaultOutlineButton(
				systemImage: derived.allVisibleRevealed ? "eye.slash" : "eye",
				title: compact ? nil : "Reveal",
				help: derived.allVisibleRevealed ? "Hide all values" : "Reveal all values",
				active: derived.allVisibleRevealed,
				disabled: !canUseSecrets
			) { toggleRevealAll(derived) }
			.accessibilityLabel(derived.allVisibleRevealed ? "Hide all values" : "Reveal all values")

			VaultOutlineButton(
				systemImage: isCopiedAll && !isCopyingAll ? "checkmark" : "doc.on.doc",
				title: compact ? nil : copyTitle,
				reservedTitles: compact ? [] : ["Copy all", "Copying…", "Copied"],
				help: copyHelp,
				active: isCopiedAll && !isCopyingAll,
				disabled: isCopyingAll || !canUseSecrets,
				action: onCopyAll
			)
			.accessibilityLabel(copyHelp)
			VaultOutlineButton(
				systemImage: "square.and.arrow.down",
				help: isImporting ? "Importing into \(environmentName)" : "Import a .env file into \(environmentName)",
				disabled: isImporting,
				action: onImport
			)
			VaultOutlineButton(systemImage: "square.and.arrow.up", help: "Export \(environmentName)", disabled: !canUseSecrets, action: onExport)
		}
		.fixedSize()
	}

	private func matrix(_ derived: VaultContentDerivation) -> some View {
		GeometryReader { geometry in
			let layout = VaultTableColumnLayout(columns: [.key] + environments.map(VaultTableColumn.environment),
				available: geometry.size.width - VaultMetrics.paneDividerHitWidth, requested: columnWidths.matrix.requested)
			let tableWidth = max(geometry.size.width, layout.totalWidth + VaultMetrics.paneDividerHitWidth)

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
									selectedEnvironment: selectedEnvironment,
									layout: layout,
									tableWidth: tableWidth,
									isSelected: selectedKey == key,
									isRevealed: canUseSecrets && revealedKeys.contains(key),
									isEdited: editedKeys.contains(key),
									onSelect: { selectedKey = key; showsInspector = true },
									onReveal: { toggleReveal(key) }
								)
								.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
							}
						}
					} header: {
						VaultMatrixHeader(
							environments: environments,
							selectedEnvironment: selectedEnvironment,
							layout: layout,
							tableWidth: tableWidth,
							sortOrder: $sortOrder,
							onResize: { column, width in columnWidths.matrix.resize(column, to: width, in: layout) },
							onResizeActivity: onResizeColumns
						)
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

	@ViewBuilder
	private func environmentDetail(_ derived: VaultContentDerivation) -> some View {
		if environmentViewMode == .raw {
			rawEnvironment(derived)
		} else {
			GeometryReader { geometry in
				let layout = VaultTableColumnLayout(columns: [.key, .value, .actions],
					available: geometry.size.width - VaultMetrics.paneDividerHitWidth, requested: columnWidths.environment.requested)
				let tableWidth = max(geometry.size.width, layout.totalWidth + VaultMetrics.paneDividerHitWidth)
				ScrollView([.horizontal, .vertical]) {
					LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
						Section {
							if derived.environmentKeys.isEmpty {
								VaultTableEmptyRow(
									message: searchText.isEmpty ? "No secrets in this environment" : "No keys match your search",
									width: tableWidth
								)
							} else {
								ForEach(derived.environmentKeys, id: \.self) { key in
									VaultEnvironmentRow(
										key: key,
										value: project.value(for: key, in: selectedEnvironment) ?? "",
										layout: layout,
										tableWidth: tableWidth,
										isSelected: selectedKey == key,
										isRevealed: canUseSecrets && revealedKeys.contains(key),
										hasDrift: snapshot.hasDrift(for: key),
										isEdited: editedKeys.contains(key),
										onSelect: { selectedKey = key; showsInspector = true },
										onReveal: { toggleReveal(key) },
										onCopy: { onCopySecret(key, selectedEnvironment) },
										onEdit: { selectedKey = key; showsInspector = true },
										onDelete: { onDeleteSecret(key, selectedEnvironment) }
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

	private func rawEnvironment(_ derived: VaultContentDerivation) -> some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 7) {
				ForEach(derived.environmentKeys, id: \.self) { key in
					let isRevealed = canUseSecrets && revealedKeys.contains(key)
					let rendered = isRevealed ? (project.value(for: key, in: selectedEnvironment) ?? "") : "••••••••••••"
					Text("\(key)=\(rendered)")
						.font(VaultTypography.mono(12))
						.foregroundStyle(VaultPalette.textSecondary)
						.accessibilityLabel("\(key), value \(isRevealed ? "revealed visually" : "hidden")")
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(20)
		}
	}

	/// A narrow bar drops the sort order first, which the KEY header also shows,
	/// then the details the filter chips and row badges also show. The key count
	/// and unsaved changes always stay.
	private func statusBar(_ derived: VaultContentDerivation) -> some View {
		let count = Text(mode == .matrix
			? "\(derived.filteredKeys.count) of \(Self.count(derived.allKeys.count, "key")) shown"
			: Self.count(derived.environmentKeys.count, "key"))
		let sort = Text("sorted \(sortOrder.title)").accessibilityLabel("sorted \(sortOrder.spokenTitle)")
		let details = mode == .matrix
			? [Text("\(snapshot.driftingKeyCount) drifting"), Text("\(snapshot.missingKeyCount) missing")]
			: [Text("\(derived.environmentDriftingKeyCount) differ across environments"), Text("encrypted locally")]
		let unsaved = editedKeys.isEmpty
			? nil
			: (editedKeys.count == 1 ? "1 key with unsaved changes" : "\(editedKeys.count) keys with unsaved changes")
		return ViewThatFits(in: .horizontal) {
			statusLine([count, sort] + details, unsaved: unsaved)
			statusLine([count] + details, unsaved: unsaved)
			statusLine([count], unsaved: unsaved)
		}
		.font(.system(size: 11))
		.foregroundStyle(VaultPalette.textTertiary)
		.lineLimit(1)
		.padding(.horizontal, 20)
		.frame(height: VaultMetrics.statusBar)
		.background(VaultPalette.headerRow)
	}

	private func statusLine(_ items: [Text], unsaved: String?) -> some View {
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
		}
	}

	private static func count(_ value: Int, _ noun: String) -> String {
		"\(value) \(noun)\(value == 1 ? "" : "s")"
	}

	private func toggleRevealAll(_ derived: VaultContentDerivation) {
		guard canUseSecrets else { return }
		let keys = mode == .matrix ? derived.filteredKeys : derived.environmentKeys
		if keys.allSatisfy(revealedKeys.contains) {
			revealedKeys.subtract(keys)
		} else {
			revealedKeys.formUnion(keys)
		}
	}

	private func toggleReveal(_ key: String) {
		guard canUseSecrets else { return }
		if revealedKeys.contains(key) { revealedKeys.remove(key) } else { revealedKeys.insert(key) }
	}
}

private struct VaultMatrixHeader: View {
	let environments: [String]
	let selectedEnvironment: String
	let layout: VaultTableColumnLayout
	let tableWidth: CGFloat
	@Binding var sortOrder: VaultKeySortOrder
	let onResize: (VaultTableColumn, CGFloat) -> Void
	let onResizeActivity: () -> Void

	var body: some View {
		HStack(spacing: 0) {
			VaultKeySortHeader(order: $sortOrder)
				.frame(width: layout[.key], height: VaultMetrics.tableHeader)

			ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
				VaultHairline(axis: .vertical)
				HStack(spacing: 6) {
					VaultEnvSwatch(color: VaultPalette.environment(index))
					Text(VaultProject.displayName(for: environment))
						.font(VaultTypography.mono(11.5, .bold))
						.foregroundStyle(VaultPalette.textSecondary)
						.lineLimit(1)
					Spacer(minLength: 2)
				}
				.padding(.horizontal, 12)
				.frame(width: layout[.environment(environment)] - 1, height: VaultMetrics.tableHeader)
				.background(environment == selectedEnvironment ? VaultPalette.selectedEnvHeader : .clear)
				.accessibilityLabel("\(VaultProject.displayName(for: environment))\(environment == selectedEnvironment ? ", current environment" : "")")
			}
		}
		.frame(width: tableWidth, alignment: .leading)
		.overlay { VaultTableResizeHandles(layout: layout, onResize: onResize, onActivity: onResizeActivity) }
	}
}

private struct VaultMatrixRow: View {
	let key: String
	let project: VaultProject
	let snapshot: VaultWorkspaceSnapshot
	let environments: [String]
	let selectedEnvironment: String
	let layout: VaultTableColumnLayout
	let tableWidth: CGFloat
	let isSelected: Bool
	let isRevealed: Bool
	let isEdited: Bool
	let onSelect: () -> Void
	let onReveal: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: onSelect) {
			HStack(spacing: 0) {
				HStack(spacing: 8) {
					Text(key)
						.font(VaultTypography.mono(13, isSelected ? .bold : .regular))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
					if isEdited { VaultUnsavedBadge() }
					if snapshot.hasDrift(for: key) { VaultStatusDot(color: VaultPalette.orange).help("Values differ") }
					if snapshot.isMissingSomewhere(key) { VaultStatusDot(color: VaultPalette.red).help("Missing in an environment") }
					Spacer(minLength: 0)
				}
				.padding(.horizontal, 20)
				.frame(width: layout[.key])

				ForEach(environments, id: \.self) { environment in
					VaultHairline(color: VaultPalette.rowDivider, axis: .vertical)
					HStack(spacing: 6) {
						if project.value(for: key, in: environment) != nil {
							VaultValueText(text: isRevealed ? (project.value(for: key, in: environment) ?? "") : "••••••••••", masked: !isRevealed, size: 11.5)
						} else {
							Text("Not set").font(.system(size: 11, weight: .semibold)).foregroundStyle(VaultPalette.redText)
						}
						Spacer(minLength: 0)
					}
					.padding(.horizontal, 12)
					.frame(width: layout[.environment(environment)] - 1, height: VaultMetrics.matrixRow)
					.background(environment == selectedEnvironment ? VaultPalette.selectedEnvCell : .clear)
				}
			}
			.frame(width: tableWidth, height: VaultMetrics.matrixRow, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.frame(height: VaultMetrics.matrixRow)
		.background(isSelected ? VaultPalette.rowSelected : (hovering ? VaultPalette.rowHover : .clear))
		.contentShape(Rectangle())
		.simultaneousGesture(TapGesture(count: 2).onEnded { onReveal() })
		.onHover { hovering = $0 }
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(key), set in \(snapshot.environmentCount(for: key)) of \(environments.count) environments\(isEdited ? ", unsaved changes" : "")")
		.accessibilityValue(snapshot.hasDrift(for: key) ? "Values differ" : "Values consistent")
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.accessibilityAction(named: isRevealed ? "Hide values" : "Reveal values", onReveal)
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
			Text("VALUE").vaultSectionLabel().padding(.horizontal, 12).frame(width: layout[.value], alignment: .leading)
			Text("ACTIONS").vaultSectionLabel().padding(.trailing, 20).frame(width: layout[.actions], alignment: .trailing)
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
				.background { VaultHairline(axis: .vertical).allowsHitTesting(false) }
				.frame(height: VaultMetrics.tableHeader)
				.offset(x: boundary.position - VaultMetrics.paneDividerHitWidth / 2)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}

private struct VaultEnvironmentRow: View {
	let key: String
	let value: String
	let layout: VaultTableColumnLayout
	let tableWidth: CGFloat
	let isSelected: Bool
	let isRevealed: Bool
	let hasDrift: Bool
	let isEdited: Bool
	let onSelect: () -> Void
	let onReveal: () -> Void
	let onCopy: () -> Void
	let onEdit: () -> Void
	let onDelete: () -> Void

	@State private var hovering = false

	var body: some View {
		HStack(spacing: 0) {
			ViewThatFits(in: .horizontal) {
				keyLabel(compact: false)
				keyLabel(compact: true)
			}
			.padding(.leading, 20)
			.padding(.trailing, 12)
			.frame(width: layout[.key], alignment: .leading)

			VaultValueText(text: isRevealed ? value : "••••••••••••", masked: !isRevealed)
				.padding(.horizontal, 12)
				.frame(width: layout[.value], alignment: .leading)

			HStack(spacing: 2) {
				VaultRowIconButton(systemImage: isRevealed ? "eye.slash" : "eye", help: isRevealed ? "Hide value" : "Reveal value", action: onReveal)
				VaultRowIconButton(systemImage: "doc.on.doc", help: "Copy key and value", action: onCopy)
				VaultRowIconButton(systemImage: "pencil", help: "Edit key and value", action: onEdit)
				VaultRowIconButton(systemImage: "trash", help: "Delete from this environment", destructive: true, action: onDelete)
			}
			.padding(.trailing, 16)
			.frame(width: layout[.actions], alignment: .trailing)
		}
		.frame(width: tableWidth, height: VaultMetrics.fileRow, alignment: .leading)
		.background(isSelected ? VaultPalette.rowSelected : (hovering ? VaultPalette.rowHover : .clear))
		.contentShape(Rectangle())
		.onTapGesture(perform: onSelect)
		.onHover { hovering = $0 }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("\(key), value hidden\(isEdited ? ", unsaved changes" : "")")
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	private func keyLabel(compact: Bool) -> some View {
		HStack(spacing: 8) {
			Text(key)
				.font(VaultTypography.mono(13, isSelected ? .bold : .regular))
				.foregroundStyle(VaultPalette.textPrimary)
				.lineLimit(1)
				.layoutPriority(1)
			if isEdited {
				if compact {
					VaultStatusDot(color: VaultPalette.orange).help("Unsaved changes").accessibilityLabel("Unsaved changes")
				} else {
					VaultUnsavedBadge()
				}
			}
			if hasDrift {
				if compact {
					Image(systemName: "diamond.fill")
						.font(.system(size: 8))
						.foregroundStyle(VaultPalette.orange)
						.frame(width: 6, height: 6)
						.help("Values differ")
						.accessibilityLabel("Values differ")
				} else {
					VaultTagBadge(text: "DIFFERS", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint)
				}
			}
			Spacer(minLength: 0)
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
				Text("KEY").vaultSectionLabel(VaultPalette.textPrimary)
				Image(systemName: order == .ascending ? "arrow.up" : "arrow.down")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(VaultPalette.accentForeground)
				Text(order.title)
					.font(.system(size: 10.5))
					.foregroundStyle(VaultPalette.textTertiary)
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
	let onCreate: () -> Void
	let onImport: () -> Void

	var body: some View {
		VStack(spacing: 12) {
			VaultAppMark(size: 42)
			Text(isSearching ? "No matching env projects" : "Select an env project")
				.font(.system(size: 18, weight: .bold))
				.foregroundStyle(VaultPalette.textPrimary)
			Text(isSearching ? "Try another project or key name." : "Create a local project or import one from lpm.dev.")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
			if !isSearching {
				HStack(spacing: 8) {
					VaultBarButton(title: "Create project", filled: true, action: onCreate)
					VaultBarButton(systemImage: "cloud", title: "Import", action: onImport)
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(VaultPalette.content)
	}
}
