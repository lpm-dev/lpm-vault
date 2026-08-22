import SwiftUI

struct VaultContentView: View {
	let project: VaultProject
	let snapshot: VaultWorkspaceSnapshot
	let environments: [String]
	let selectedEnvironment: String
	@Binding var mode: VaultWorkspaceMode
	@Binding var filter: VaultWorkspaceFilter
	@Binding var environmentViewMode: VaultEnvironmentViewMode
	let searchText: String
	@Binding var selectedKey: String?
	@Binding var revealedKeys: Set<String>
	@Binding var showsInspector: Bool
	let isImporting: Bool
	let isCopyingAll: Bool
	let onCopyAll: () -> Void
	let onImport: () -> Void
	let onExport: () -> Void
	let onAddSecret: () -> Void
	let onCopySecret: (String, String) -> Void
	let onDeleteSecret: (String, String) -> Void

	private var allKeys: [String] { snapshot.allSecretKeys }

	private var filteredKeys: [String] {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return allKeys.filter { key in
			let matchesFilter: Bool
			switch filter {
			case .all: matchesFilter = true
			case .drift: matchesFilter = snapshot.hasDrift(for: key)
			case .missing: matchesFilter = snapshot.isMissingSomewhere(key)
			}
			return matchesFilter && (query.isEmpty || key.lowercased().contains(query))
		}
	}

	private var environmentKeys: [String] {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return project.sortedSecrets(for: selectedEnvironment)
			.map(\.key)
			.filter { query.isEmpty || $0.lowercased().contains(query) }
	}

	private var allVisibleRevealed: Bool {
		let keys = mode == .matrix ? filteredKeys : environmentKeys
		return !keys.isEmpty && Set(keys).isSubset(of: revealedKeys)
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			VaultHairline()

			switch mode {
			case .matrix:
				matrix
			case .environment:
				environmentDetail
			}

			VaultHairline()
			statusBar
		}
		.background(VaultPalette.content)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 12) {
			ViewThatFits(in: .horizontal) {
				headerPrimaryRow(compactToolbar: false)
				headerPrimaryRow(compactToolbar: true)
				VStack(alignment: .leading, spacing: 10) {
					headerIdentity
					toolbar(compact: true)
						.frame(maxWidth: .infinity, alignment: .trailing)
				}
			}

			HStack(spacing: 6) {
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
					Spacer(minLength: 8)
					Text("Edits apply to \(VaultProject.displayName(for: selectedEnvironment))")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				} else {
					ForEach(VaultEnvironmentViewMode.allCases) { candidate in
						VaultFilterChip(title: candidate.rawValue, selected: environmentViewMode == candidate) {
							environmentViewMode = candidate
						}
					}
					Spacer(minLength: 0)
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 16)
		.padding(.bottom, 12)
	}

	private func headerPrimaryRow(compactToolbar: Bool) -> some View {
		HStack(spacing: 10) {
			headerIdentity

			Spacer(minLength: 8)
			toolbar(compact: compactToolbar)
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
				Text("\(allKeys.count) keys · \(environments.count) envs")
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
				Text("\(project.secretCount(for: selectedEnvironment)) keys")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.lineLimit(1)
		.fixedSize(horizontal: true, vertical: false)
	}

	private func toolbar(compact: Bool) -> some View {
		HStack(spacing: 6) {
			VaultOutlineButton(
				systemImage: allVisibleRevealed ? "eye.slash" : "eye",
				title: compact ? nil : "Reveal",
				help: allVisibleRevealed ? "Hide all values" : "Reveal all values",
				active: allVisibleRevealed
			) { toggleRevealAll() }
			.accessibilityLabel(allVisibleRevealed ? "Hide all values" : "Reveal all values")

			VaultOutlineButton(
				systemImage: "doc.on.doc",
				title: compact ? nil : (isCopyingAll ? "Authenticating…" : "Copy all"),
				help: isCopyingAll ? "Authenticating to copy all values" : "Copy all values",
				disabled: isCopyingAll,
				action: onCopyAll
			)
			.accessibilityLabel(isCopyingAll ? "Authenticating to copy all values" : "Copy all values")
			VaultOutlineButton(
				systemImage: "square.and.arrow.down",
				help: isImporting ? "Importing .env" : "Import .env",
				disabled: isImporting,
				action: onImport
			)
			VaultOutlineButton(systemImage: "square.and.arrow.up", help: "Export .env", action: onExport)
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
	}

	private var matrix: some View {
		GeometryReader { geometry in
			let columnCount = CGFloat(max(environments.count, 1))
			let minimumWidth = VaultMetrics.keyColumn + columnCount * VaultMetrics.environmentColumn
			let tableWidth = max(geometry.size.width, minimumWidth)
			let environmentColumnWidth = (tableWidth - VaultMetrics.keyColumn) / columnCount

			ScrollView([.horizontal, .vertical]) {
				LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
					Section {
						if filteredKeys.isEmpty {
							VaultTableEmptyRow(
								message: searchText.isEmpty ? "No keys in this view" : "No keys match your search",
								width: tableWidth
							)
						} else {
							ForEach(filteredKeys, id: \.self) { key in
								VaultMatrixRow(
									key: key,
									project: project,
									snapshot: snapshot,
									environments: environments,
									selectedEnvironment: selectedEnvironment,
									environmentColumnWidth: environmentColumnWidth,
									isSelected: selectedKey == key,
									isRevealed: revealedKeys.contains(key),
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
							environmentColumnWidth: environmentColumnWidth
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
	private var environmentDetail: some View {
		if environmentViewMode == .raw {
			rawEnvironment
		} else {
			ScrollView {
				LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
					Section {
						if environmentKeys.isEmpty {
							VaultTableEmptyRow(
								message: searchText.isEmpty ? "No secrets in this environment" : "No keys match your search",
								width: 760
							)
						} else {
							ForEach(environmentKeys, id: \.self) { key in
								VaultEnvironmentRow(
									key: key,
									value: project.value(for: key, in: selectedEnvironment) ?? "",
									isSelected: selectedKey == key,
									isRevealed: revealedKeys.contains(key),
									hasDrift: snapshot.hasDrift(for: key),
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
						VaultEnvironmentHeader()
							.background(VaultPalette.headerRow)
							.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.sidebarBorder) }
					}
				}
			}
		}
	}

	private var rawEnvironment: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 7) {
				ForEach(environmentKeys, id: \.self) { key in
					let isRevealed = revealedKeys.contains(key)
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

	private var statusBar: some View {
		HStack(spacing: 12) {
			if case .matrix = mode {
				Text("\(filteredKeys.count) of \(allKeys.count) keys shown")
				Text("·")
				Text("\(snapshot.driftingKeyCount) drifting")
				Text("·")
				Text("\(snapshot.missingKeyCount) missing")
			} else {
				Text("\(environmentKeys.count) keys")
				Text("·")
				Text("\(environmentKeys.filter(snapshot.hasDrift(for:)).count) differ across environments")
				Text("·")
				Text("encrypted locally")
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: 11))
		.foregroundStyle(VaultPalette.textTertiary)
		.lineLimit(1)
		.padding(.horizontal, 20)
		.frame(height: VaultMetrics.statusBar)
		.background(VaultPalette.headerRow)
	}

	private func toggleRevealAll() {
		let keys = mode == .matrix ? filteredKeys : environmentKeys
		if Set(keys).isSubset(of: revealedKeys) {
			revealedKeys.subtract(keys)
		} else {
			revealedKeys.formUnion(keys)
		}
	}

	private func toggleReveal(_ key: String) {
		if revealedKeys.contains(key) { revealedKeys.remove(key) } else { revealedKeys.insert(key) }
	}
}

private struct VaultMatrixHeader: View {
	let environments: [String]
	let selectedEnvironment: String
	let environmentColumnWidth: CGFloat

	var body: some View {
		LazyHStack(spacing: 0) {
			Text("KEY")
				.vaultSectionLabel()
				.padding(.horizontal, 20)
				.frame(width: VaultMetrics.keyColumn, height: VaultMetrics.tableHeader, alignment: .leading)

			ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
				VaultHairline(axis: .vertical)
				HStack(spacing: 6) {
					VaultEnvSwatch(color: VaultPalette.environment(index))
					Text(VaultProject.displayName(for: environment))
						.font(VaultTypography.mono(11.5, .bold))
						.foregroundStyle(VaultPalette.textSecondary)
						.lineLimit(1)
					Spacer(minLength: 2)
					if environment == selectedEnvironment {
						Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(VaultPalette.accent)
					}
				}
				.padding(.horizontal, 12)
				.frame(width: environmentColumnWidth - 1, height: VaultMetrics.tableHeader)
				.background(environment == selectedEnvironment ? VaultPalette.selectedEnvHeader : .clear)
				.accessibilityLabel("\(VaultProject.displayName(for: environment))\(environment == selectedEnvironment ? ", editing environment" : "")")
			}
		}
	}
}

private struct VaultMatrixRow: View {
	let key: String
	let project: VaultProject
	let snapshot: VaultWorkspaceSnapshot
	let environments: [String]
	let selectedEnvironment: String
	let environmentColumnWidth: CGFloat
	let isSelected: Bool
	let isRevealed: Bool
	let onSelect: () -> Void
	let onReveal: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: onSelect) {
			LazyHStack(spacing: 0) {
				HStack(spacing: 8) {
					Text(key)
						.font(VaultTypography.mono(13, isSelected ? .bold : .regular))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
					if snapshot.hasDrift(for: key) { VaultStatusDot(color: VaultPalette.orange).help("Values differ") }
					if snapshot.isMissingSomewhere(key) { VaultStatusDot(color: VaultPalette.red).help("Missing in an environment") }
					Spacer(minLength: 0)
				}
				.padding(.horizontal, 20)
				.frame(width: VaultMetrics.keyColumn)

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
					.frame(width: environmentColumnWidth - 1, height: VaultMetrics.matrixRow)
					.background(environment == selectedEnvironment ? VaultPalette.selectedEnvCell : .clear)
				}
			}
		}
		.buttonStyle(.plain)
		.frame(height: VaultMetrics.matrixRow)
		.background(isSelected ? VaultPalette.rowSelected : (hovering ? VaultPalette.rowHover : .clear))
		.contentShape(Rectangle())
		.simultaneousGesture(TapGesture(count: 2).onEnded { onReveal() })
		.onHover { hovering = $0 }
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(key), set in \(snapshot.environmentCount(for: key)) of \(environments.count) environments")
		.accessibilityValue(snapshot.hasDrift(for: key) ? "Values differ" : "Values consistent")
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.accessibilityAction(named: isRevealed ? "Hide values" : "Reveal values", onReveal)
	}
}

private struct VaultEnvironmentHeader: View {
	var body: some View {
		HStack(spacing: 0) {
			Text("KEY").vaultSectionLabel().padding(.leading, 20).frame(maxWidth: .infinity, alignment: .leading)
			Text("VALUE").vaultSectionLabel().frame(width: 280, alignment: .leading)
			Text("ACTIONS").vaultSectionLabel().padding(.trailing, 20).frame(width: 132, alignment: .trailing)
		}
		.frame(height: VaultMetrics.tableHeader)
	}
}

private struct VaultEnvironmentRow: View {
	let key: String
	let value: String
	let isSelected: Bool
	let isRevealed: Bool
	let hasDrift: Bool
	let onSelect: () -> Void
	let onReveal: () -> Void
	let onCopy: () -> Void
	let onEdit: () -> Void
	let onDelete: () -> Void

	@State private var hovering = false

	var body: some View {
		HStack(spacing: 0) {
			HStack(spacing: 8) {
				Text(key)
					.font(VaultTypography.mono(13, isSelected ? .bold : .regular))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				if hasDrift {
					VaultTagBadge(text: "DIFFERS", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint)
				}
				Spacer(minLength: 0)
			}
			.padding(.leading, 20)
			.frame(maxWidth: .infinity, alignment: .leading)

			VaultValueText(text: isRevealed ? value : "••••••••••••", masked: !isRevealed)
				.frame(width: 280, alignment: .leading)

			HStack(spacing: 2) {
				VaultRowIconButton(systemImage: isRevealed ? "eye.slash" : "eye", help: isRevealed ? "Hide value" : "Reveal value", action: onReveal)
				VaultRowIconButton(systemImage: "doc.on.doc", help: "Copy key and value", action: onCopy)
				VaultRowIconButton(systemImage: "pencil", help: "Edit value", action: onEdit)
				VaultRowIconButton(systemImage: "trash", help: "Delete from this environment", destructive: true, action: onDelete)
			}
			.padding(.trailing, 16)
			.frame(width: 132, alignment: .trailing)
		}
		.frame(height: VaultMetrics.fileRow)
		.background(isSelected ? VaultPalette.rowSelected : (hovering ? VaultPalette.rowHover : .clear))
		.contentShape(Rectangle())
		.onTapGesture(perform: onSelect)
		.onHover { hovering = $0 }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("\(key), value hidden")
		.accessibilityAddTraits(isSelected ? .isSelected : [])
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
