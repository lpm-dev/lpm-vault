import AppKit
import SwiftUI

enum VaultSidebarLayout {
	static let projectInset: CGFloat = 6
	static let rowInset: CGFloat = 8
	static let rowHeight: CGFloat = 31
	/// The project icon's slot, which the grip takes over on hover.
	static let projectIconWidth: CGFloat = 16
	/// How far the grip slides in. No farther than the row's padding, so it stays on the row's background.
	static let gripSlide = rowInset
	static let projectSpacing: CGFloat = 8
	static let approvalWidth: CGFloat = 11
	static let countMinimumWidth: CGFloat = 16
	static let childIconWidth: CGFloat = 12
	static let environmentSwatchSize: CGFloat = 6
	static let childIconOffset = (environmentSwatchSize - childIconWidth) / 2
	static let environmentTextOffset: CGFloat = -2
	static let childSpacing: CGFloat = 7
	static let childInset: CGFloat = 26
	static let projectLabelInset = projectInset + rowInset + projectIconWidth + projectSpacing
	static let childRowLeadingInset = projectLabelInset - childInset
	static let landingLineInset = projectInset + rowInset
}

struct VaultSidebarView: View {
	@Bindable var store: VaultStore
	let snapshots: [String: VaultWorkspaceSnapshot]
	@Binding var mode: VaultWorkspaceMode
	@Binding var filter: VaultWorkspaceFilter
	@Binding var searchText: String
	@Binding var showsAccountSwitcher: Bool

	let onNewProject: () -> Void
	let onCloudProjects: () -> Void
	let onNewEnvironment: () -> Void
	let onProjectSettings: (VaultProject) -> Void
	let onRenameProject: (VaultProject) -> Void
	let onDeleteProject: (VaultProject) -> Void
	let onRenameEnvironment: (VaultEnvironmentTarget) -> Void
	let onDuplicateEnvironment: (VaultEnvironmentTarget) -> Void
	let onClearEnvironment: (VaultEnvironmentTarget) -> Void
	let onDeleteEnvironment: (VaultEnvironmentTarget) -> Void
	/// The project drag in progress, if any. Tests pass their own to follow it.
	@State var reorder = VaultSidebarReorder()

	@FocusState private var searchFocused: Bool
	@State private var collapsedProjectIds: Set<String> = []
	@GestureState private var isReordering = false

	private var visibleProjects: [VaultProject] {
		store.visibleVaults(matching: searchText)
	}

	var body: some View {
		let derivedProjects = visibleProjects
		let order = derivedProjects.map(\.id)
		VStack(spacing: 0) {
			searchField
				.padding(.horizontal, 14)
				.padding(.top, 14)
				.padding(.bottom, 10)

			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						projectHeader

						if derivedProjects.isEmpty {
							Text(searchText.isEmpty ? "No env projects" : "No matching projects or keys")
								.font(.system(size: 12))
								.foregroundStyle(VaultPalette.textTertiary)
								.padding(.horizontal, 16)
								.padding(.vertical, 12)
						} else {
							projectGroups(derivedProjects, order: order)
						}

						if let project = store.selectedProject {
							smartViews(project)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.coordinateSpace(.named(VaultSidebarReorder.viewportSpace))
				.onGeometryChange(for: CGSize.self) { $0.size } action: { reorder.setViewportSize($0) }
				.background {
					VaultSidebarKeys(move: { moveSelectedProject(by: $0, scrolling: proxy) }, cancelDrag: {
						withAnimation(VaultSidebarReorder.settle) { reorder.cancel() }
					})
				}
			}
			.frame(maxHeight: .infinity, alignment: .top)
			.simultaneousGesture(TapGesture().onEnded { searchFocused = false })

			VaultHairline(color: VaultPalette.sidebarBorder)
			accountFooter
				.simultaneousGesture(TapGesture().onEnded { searchFocused = false })
		}
		.background(VaultPalette.sidebar)
		.onChange(of: order) { reorder.cancel(unlessShowing: order) }
		.onChange(of: store.isUnlocked) { _, unlocked in
			if !unlocked { reorder.cancel() }
		}
		.onChange(of: isReordering) { _, active in
			if !active { withAnimation(VaultSidebarReorder.settle) { reorder.end() } }
		}
		.onReceive(NotificationCenter.default.publisher(for: .findSecrets)) { _ in
			searchFocused = true
		}
		.onReceive(NotificationCenter.default.publisher(for: .dismissVaultSearch)) { _ in
			searchFocused = false
		}
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
			searchFocused = false
		}
	}

	private var searchField: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.textTertiary)

			ZStack(alignment: .leading) {
				if searchText.isEmpty {
					Text("Search projects and keys")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textFaint)
						.allowsHitTesting(false)
				}

				TextField("", text: $searchText)
					.textFieldStyle(.plain)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textPrimary)
					.focused($searchFocused)
					.onExitCommand { searchText = ""; searchFocused = false }
					.accessibilityLabel("Search projects and keys")
			}

			if searchText.isEmpty {
				Text("⌘F")
					.font(VaultTypography.mono(10))
					.foregroundStyle(VaultPalette.textFaint)
			} else {
				Button { searchText = "" } label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Clear search")
			}
		}
		.padding(.horizontal, 10)
		.frame(height: 30)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
		.overlay {
			RoundedRectangle(cornerRadius: 8)
				.stroke(searchFocused ? VaultPalette.accent.opacity(0.6) : VaultPalette.border, lineWidth: 1)
		}
	}

	private var projectHeader: some View {
		HStack(spacing: 8) {
			Text("PROJECTS").vaultSectionLabel()
			Spacer(minLength: 4)

			Button(action: onCloudProjects) {
				Image(systemName: "cloud")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(VaultPalette.accentForeground)
					.frame(width: 20, height: 20)
			}
			.buttonStyle(.plain)
			.help("Import from lpm.dev")
			.accessibilityLabel("Import env project from lpm.dev")
			.disabled(!store.isLoggedIn)

			Button(action: onNewProject) {
				HStack(spacing: 4) {
					Image(systemName: "plus").font(.system(size: 8.5, weight: .bold))
					Text("New Project").font(.system(size: 10.5, weight: .semibold))
				}
				.foregroundStyle(VaultPalette.accentForeground)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Create env project")
		}
		.padding(.leading, 16)
		.padding(.trailing, 10)
		.padding(.top, 2)
		.padding(.bottom, 6)
	}

	private func projectGroups(_ projects: [VaultProject], order: [String]) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
				VaultSidebarProjectGroup(reorder: reorder, projectId: project.id, index: index) {
					projectRow(project, order: order, index: index)
				} environments: {
					if store.selectedProjectId == project.id,
						!collapsedProjectIds.contains(project.id)
					{
						environmentRows(project)
					}
				}
				.zIndex(reorder.layer(at: index))
				.id(project.id)
			}
		}
		.coordinateSpace(.named(VaultSidebarReorder.contentSpace))
		.onGeometryChange(for: CGFloat.self) {
			$0.frame(in: .named(VaultSidebarReorder.viewportSpace)).minY
		} action: { reorder.setContentTop($0) }
		.background { VaultSidebarAutoscroll(reorder: reorder) }
	}

	private func reorderGesture(for projectId: String, in order: [String]) -> some Gesture {
		DragGesture(minimumDistance: 3, coordinateSpace: .named(VaultSidebarReorder.viewportSpace))
			.updating($isReordering) { _, active, _ in active = true }
			.onChanged { reorder.drag(projectId, in: order, from: $0.startLocation, to: $0.location) }
			.onEnded { value in
				reorder.drag(projectId, in: order, from: value.startLocation, to: value.location)
				withAnimation(VaultSidebarReorder.settle) {
					if let move = reorder.finish() {
						store.moveProject(id: move.projectId, relativeTo: move.targetId, placement: move.placement)
					}
				}
			}
	}

	private func moveSelectedProject(by step: Int, scrolling proxy: ScrollViewProxy) -> Bool {
		guard reorder.lift == nil, let projectId = store.selectedProjectId else { return false }
		let order = visibleProjects.map(\.id)
		guard let index = order.firstIndex(of: projectId), order.indices.contains(index + step) else { return false }
		let moved = withAnimation(VaultSidebarReorder.settle) {
			store.moveProject(id: projectId, relativeTo: order[index + step], placement: step < 0 ? .before : .after)
		}
		// The proxy finds a row where it's laid out now, so it waits for the new order's layout.
		if moved { Task { @MainActor in proxy.scrollTo(projectId) } }
		return moved
	}

	private func projectRow(_ project: VaultProject, order: [String], index: Int) -> some View {
		let previous = index > 0 ? order[index - 1] : nil
		let next = index + 1 < order.count ? order[index + 1] : nil
		let cliAccess = store.projectCliAccess[project.id]
		let approvalDescription = cliAccess.map {
			$0 == .requireApproval ? "CLI approval required" : "CLI access automatic"
		} ?? "CLI approval policy can't be read"
		let selected = !store.isShowingAccountPage && store.selectedProjectId == project.id
			&& (mode == .matrix || mode == .projectSettings)
		let expanded = store.selectedProjectId == project.id
			&& !collapsedProjectIds.contains(project.id)
		let lifted = reorder.lift?.projectId == project.id
		return VaultSidebarHoverReader { hovered in
			projectButton(project, selected: selected, expanded: expanded, lifted: lifted, hovered: hovered, cliAccess: cliAccess, order: order)
		}
		.help(project.name)
		.accessibilityLabel("\(project.name), \(project.secretCount) secrets, \(approvalDescription)")
		.accessibilityValue(expanded ? "Expanded" : "Collapsed")
		.accessibilityAddTraits(selected ? .isSelected : [])
		.accessibilityAction(named: "Project Settings") { onProjectSettings(project) }
		.accessibilityAction(named: "Move Up") {
			if let previous { store.moveProject(id: project.id, relativeTo: previous, placement: .before) }
		}
		.accessibilityAction(named: "Move Down") {
			if let next { store.moveProject(id: project.id, relativeTo: next, placement: .after) }
		}
		.contextMenu {
			Button("Project Settings…") { onProjectSettings(project) }
				.keyboardShortcut("i", modifiers: .command)
			Divider()
			Button("Rename…") { onRenameProject(project) }
			Button("Move Up") {
				if let previous { store.moveProject(id: project.id, relativeTo: previous, placement: .before) }
			}
			.keyboardShortcut(.upArrow, modifiers: .option)
			.disabled(previous == nil)
			Button("Move Down") {
				if let next { store.moveProject(id: project.id, relativeTo: next, placement: .after) }
			}
			.keyboardShortcut(.downArrow, modifiers: .option)
			.disabled(next == nil)
			Divider()
			Button("Delete Locally…", role: .destructive) { onDeleteProject(project) }
		}
	}

	private func projectButton(_ project: VaultProject, selected: Bool, expanded: Bool, lifted: Bool, hovered: Bool,
		cliAccess: VaultCliAccess?, order: [String]) -> some View
	{
		Button {
			if store.selectedProjectId == project.id, expanded {
				collapsedProjectIds.insert(project.id)
			} else {
				collapsedProjectIds.remove(project.id)
			}
			store.openProject(id: project.id)
			mode = .matrix
			filter = .all
		} label: {
			HStack(spacing: VaultSidebarLayout.projectSpacing) {
				VaultSidebarProjectSlot(
					icon: store.projectIcons.appearance(for: project.id),
					showsGrip: lifted || (hovered && reorder.lift == nil),
					reorder: reorder,
					projectId: project.id
				)
				Text(project.name)
					.font(.system(size: 13, weight: selected ? .semibold : .regular))
					.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textSecondary)
					.lineLimit(1)
					.frame(maxWidth: .infinity, alignment: .leading)
				VaultSidebarApprovalIndicator(access: cliAccess, selected: selected)
				Text("\(project.secretCount)")
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textTertiary)
					.frame(minWidth: VaultSidebarLayout.countMinimumWidth, alignment: .trailing)
			}
			.padding(.horizontal, VaultSidebarLayout.rowInset)
			.frame(height: VaultSidebarLayout.rowHeight)
			.background(RoundedRectangle(cornerRadius: 7).fill(selected ? VaultPalette.accentTint : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(.horizontal, VaultSidebarLayout.projectInset)
		.highPriorityGesture(reorderGesture(for: project.id, in: order))
	}

	private func environmentRows(_ project: VaultProject) -> some View {
		let environments = store.orderedEnvironmentNames(for: project)
		return LazyVStack(spacing: 1) {
			schemaRow(project)

			Button(action: onNewEnvironment) {
				HStack(spacing: VaultSidebarLayout.childSpacing) {
					Image(systemName: "plus")
						.font(.system(size: 9, weight: .bold))
						.frame(width: VaultSidebarLayout.childIconWidth)
						.offset(x: VaultSidebarLayout.childIconOffset)
					Text("New environment").font(.system(size: 10.5, weight: .semibold))
					Spacer()
				}
				.foregroundStyle(VaultPalette.accentForeground)
				.padding(.leading, VaultSidebarLayout.childRowLeadingInset)
				.padding(.trailing, VaultSidebarLayout.rowInset)
				.padding(.vertical, 5)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Add environment to \(project.name)")

			ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
				environmentRow(project, environment: environment, color: VaultPalette.environment(index))
			}
		}
		.padding(.leading, VaultSidebarLayout.childInset)
		.padding(.trailing, VaultSidebarLayout.projectInset)
		.padding(.top, 2)
		.padding(.bottom, 6)
	}

	private func schemaRow(_ project: VaultProject) -> some View {
		let selected = !store.isShowingAccountPage && mode == .schema
		let state = store.keyDescriptions[project.id]?.schema
		let count = state?.overview?.rules.count
		let unreadable = if case .unreadable? = state { true } else { false }
		let hasDraft = store.projectsWithSchemaDrafts.contains(project.id)
		return Button {
			store.openProject(id: project.id)
			mode = .schema
		} label: {
			HStack(spacing: VaultSidebarLayout.childSpacing) {
				Image(systemName: "curlybraces")
					.font(.system(size: 9, weight: .bold))
					.frame(width: VaultSidebarLayout.childIconWidth)
					.offset(x: VaultSidebarLayout.childIconOffset)
					.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
				Text("Schema")
					.font(.system(size: 11.5, weight: selected ? .semibold : .regular))
					.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textSecondary)
				if hasDraft {
					VaultStatusDot(color: VaultPalette.orange)
						.help("Unsaved rule changes")
				}
				Spacer(minLength: 4)
				if unreadable {
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 9.5))
						.foregroundStyle(VaultPalette.orange)
						.help("lpm.json can't be read")
				} else if let count, count > 0 {
					Text("\(count)")
						.font(VaultTypography.mono(10.5))
						.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
				}
			}
			.padding(.leading, VaultSidebarLayout.childRowLeadingInset)
			.padding(.trailing, VaultSidebarLayout.rowInset)
			.padding(.vertical, 5)
			.background(RoundedRectangle(cornerRadius: 6).fill(selected ? VaultPalette.accentTint : .clear))
			.overlay(alignment: .leading) {
				if selected { Rectangle().fill(VaultPalette.accent).frame(width: 2) }
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Schema")
		.accessibilityValue([unreadable ? "lpm.json can't be read" : count.map { "\($0) declared keys" }, hasDraft ? "unsaved rule changes" : nil].compactMap { $0 }.joined(separator: ", "))
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private func environmentRow(_ project: VaultProject, environment: String, color: Color) -> some View {
		let selected = !store.isShowingAccountPage && mode == .environment(environment)
		let target = VaultEnvironmentTarget(projectId: project.id, environment: environment)
		return Button {
			store.openProject(id: project.id)
			store.selectEnvironment(environment)
			mode = .environment(environment)
		} label: {
			HStack(spacing: VaultSidebarLayout.childSpacing) {
				VaultEnvSwatch(color: color, size: VaultSidebarLayout.environmentSwatchSize)
					.frame(width: VaultSidebarLayout.childIconWidth)
					.offset(x: VaultSidebarLayout.childIconOffset)
				Text(VaultProject.displayName(for: environment))
					.font(VaultTypography.mono(11.5, selected ? .bold : .regular))
					.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textSecondary)
					.lineLimit(1)
					.offset(x: VaultSidebarLayout.environmentTextOffset)
				Spacer(minLength: 4)
				Text("\(project.secretCount(for: environment))")
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
			}
			.padding(.leading, VaultSidebarLayout.childRowLeadingInset)
			.padding(.trailing, VaultSidebarLayout.rowInset)
			.padding(.vertical, 5)
			.background(RoundedRectangle(cornerRadius: 6).fill(selected ? VaultPalette.accentTint : .clear))
			.overlay(alignment: .leading) {
				if selected { Rectangle().fill(VaultPalette.accent).frame(width: 2) }
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(VaultProject.displayName(for: environment))
		.accessibilityValue("\(project.secretCount(for: environment)) secrets")
		.accessibilityAddTraits(selected ? .isSelected : [])
		.contextMenu {
			Button("Rename…") { onRenameEnvironment(target) }
			Button("Duplicate…") { onDuplicateEnvironment(target) }
			Divider()
			Button("Clear All Secrets", role: .destructive) { onClearEnvironment(target) }
				.disabled(project.secretCount(for: environment) == 0)
			if project.environmentNames.count > 1 {
				Button("Delete Environment", role: .destructive) { onDeleteEnvironment(target) }
			}
		}
	}

	private func smartViews(_ project: VaultProject) -> some View {
		let drift = snapshots[project.id]?.driftingKeyCount ?? 0
		let missing = snapshots[project.id]?.missingKeyCount ?? 0
		return VStack(alignment: .leading, spacing: 1) {
			Text("SMART VIEWS")
				.vaultSectionLabel()
				.padding(.horizontal, 16)
				.padding(.top, 16)
				.padding(.bottom, 6)

			smartViewRow(title: "Drift between envs", symbol: "diamond.fill", count: drift, tint: VaultPalette.orange, target: .drift)
				.padding(.horizontal, 8)
			smartViewRow(title: "Missing in an environment", symbol: "exclamationmark.triangle.fill", count: missing, tint: VaultPalette.red, target: .missing)
				.padding(.horizontal, 8)
			if let check = store.valueChecks[project.id] {
				let invalid = VaultValueCheckPresentation(check: check, rules: nil, project: project).invalidKeys.count
				smartViewRow(title: "Invalid values", symbol: "xmark.circle.fill", count: invalid, tint: VaultPalette.red, target: .invalid)
					.padding(.horizontal, 8)
					.help("Keys whose values fail their lpm.json rules")
			}
		}
	}

	private func smartViewRow(
		title: String,
		symbol: String,
		count: Int,
		tint: Color,
		target: VaultWorkspaceFilter
	) -> some View {
		Button {
			mode = .matrix
			filter = target
		} label: {
			HStack(spacing: 9) {
				Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint).frame(width: 14)
				Text(title).font(.system(size: 13)).foregroundStyle(VaultPalette.textSecondary)
				Spacer(minLength: 4)
				VaultCountPill(count: count, tint: tint)
			}
			.padding(.horizontal, 9)
			.padding(.vertical, 7)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("\(title), \(count)")
	}

	private var accountFooter: some View {
		Button {
			showsAccountSwitcher.toggle()
		} label: {
			HStack(spacing: 9) {
				VaultInitialsAvatar(initials: accountInitials)
				VStack(alignment: .leading, spacing: 1) {
					Text(accountName)
						.font(.system(size: 12, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(store.isLoggedIn ? "Encrypted locally · unlocked" : "Local only · unlocked")
						.font(.system(size: 10.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				Spacer(minLength: 4)
				Image(systemName: showsAccountSwitcher ? "chevron.up" : "chevron.down")
					.font(.system(size: 10, weight: .bold))
					.foregroundStyle(showsAccountSwitcher ? VaultPalette.accentForeground : VaultPalette.textTertiary)
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 12)
			.background(showsAccountSwitcher ? VaultPalette.titleBar : VaultPalette.sidebar)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Account menu, \(accountName)")
	}

	private var accountName: String {
		switch store.selectedAccount {
		case .personal: return store.currentUser?.username ?? "Personal vault"
		case .org(let slug): return store.userOrgs.first(where: { $0.slug == slug })?.name ?? slug
		}
	}

	private var accountInitials: String {
		let words = accountName.split(separator: " ")
		let result = words.prefix(2).compactMap(\.first).map(String.init).joined()
		return result.isEmpty ? "LP" : result.uppercased()
	}
}

/// Whether the pointer is over `content`. Each row keeps its own, so moving
/// between rows redraws only the two, and a row that goes away takes its
/// hover with it.
private struct VaultSidebarHoverReader<Content: View>: View {
	@ViewBuilder let content: (Bool) -> Content
	@State private var isHovered = false

	var body: some View {
		content(isHovered).onHover { isHovered = $0 }
	}
}

/// A project's icon, which the grip replaces while the pointer is over the
/// row or the project is being dragged.
private struct VaultSidebarProjectSlot: View {
	let icon: ProjectIconAppearance
	let showsGrip: Bool
	let reorder: VaultSidebarReorder
	let projectId: String

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		ZStack {
			VaultProjectIconView(appearance: icon, size: VaultSidebarLayout.projectIconWidth)
				.opacity(showsGrip ? 0 : 1)
				.animation(.easeOut(duration: reduceMotion ? 0.1 : 0.14), value: showsGrip)
			VaultSidebarGrip(reorder: reorder, projectId: projectId)
				.opacity(showsGrip ? 1 : 0)
				.offset(x: showsGrip || reduceMotion ? 0 : -VaultSidebarLayout.gripSlide)
				.animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: showsGrip)
		}
		.frame(width: VaultSidebarLayout.projectIconWidth, height: VaultSidebarLayout.projectIconWidth)
	}
}

/// The lock of a project whose CLI access needs approval, or the warning
/// that its policy can't be read; nothing when access is automatic.
private struct VaultSidebarApprovalIndicator: View {
	let access: VaultCliAccess?
	let selected: Bool

	var body: some View {
		switch access {
		case .requireApproval?:
			Image(systemName: "lock")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textTertiary)
				.frame(width: VaultSidebarLayout.approvalWidth)
				.help("CLI approval required")
				.accessibilityHidden(true)
		case .automatic?:
			EmptyView()
		case nil:
			Image(systemName: "questionmark.circle")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(VaultPalette.orangeTintText)
				.frame(width: VaultSidebarLayout.approvalWidth)
				.help("CLI approval policy can't be read")
				.accessibilityHidden(true)
		}
	}
}

private struct VaultSidebarProjectGroup<Row: View, Environments: View>: View {
	let reorder: VaultSidebarReorder
	let projectId: String
	let index: Int
	let row: Row
	let environments: Environments

	init(reorder: VaultSidebarReorder, projectId: String, index: Int,
		@ViewBuilder row: () -> Row, @ViewBuilder environments: () -> Environments) {
		self.reorder = reorder
		self.projectId = projectId
		self.index = index
		self.row = row()
		self.environments = environments()
	}

	var body: some View {
		let lifted = reorder.lift?.projectId == projectId
		let shift = lifted ? 0 : reorder.shift(at: index)
		let edge = reorder.landingEdge(at: index)
		VStack(alignment: .leading, spacing: 0) {
			row
			environments
		}
		.background {
			if lifted {
				RoundedRectangle(cornerRadius: 7)
					.fill(VaultPalette.control)
					.shadow(color: VaultPalette.shadow.opacity(0.18), radius: 8, y: 4)
					.padding(.horizontal, VaultSidebarLayout.projectInset)
			}
		}
		.overlay(alignment: edge == .bottom ? .bottom : .top) {
			if let edge {
				Capsule()
					.fill(VaultPalette.accent)
					.frame(height: 2)
					.padding(.horizontal, VaultSidebarLayout.landingLineInset)
					.offset(y: edge == .top ? -1 : 1)
					.allowsHitTesting(false)
			}
		}
		.scaleEffect(lifted ? VaultSidebarReorder.liftScale : 1)
		.offset(y: lifted ? reorder.offset : shift)
		.animation(lifted ? nil : VaultSidebarReorder.settle, value: shift)
		// Measured outside the offset, so the frame is the group's place in the list.
		.onGeometryChange(for: CGRect.self) {
			$0.frame(in: .named(VaultSidebarReorder.contentSpace))
		} action: { reorder.setFrame($0, for: projectId) }
		.onDisappear { reorder.setFrame(nil, for: projectId) }
	}
}

struct VaultAccountSwitcher: View {
	@Bindable var store: VaultStore
	@Binding var isPresented: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Text("VAULTS")
				.vaultSectionLabel()
				.padding(.horizontal, 8)
				.padding(.top, 4)
				.padding(.bottom, 5)

			accountRow(name: "Personal vault", initials: personalInitials, account: .personal, square: false)
			ForEach(store.userOrgs) { org in
				accountRow(name: org.name, initials: initials(org.name), account: .org(org.slug), square: true)
			}

			VaultHairline().padding(.horizontal, 4).padding(.vertical, 5)

			menuRow(icon: "gearshape", title: "Settings", shortcut: "⌘,") {
				store.showSettings()
				isPresented = false
			}
			menuRow(icon: "square.stack.3d.up", title: "Platforms") {
				store.showPlatforms()
				isPresented = false
			}
			menuRow(icon: "lock", title: "Lock vault", shortcut: "⌘L") {
				store.lock()
				isPresented = false
			}
		}
		.padding(6)
		.background {
			RoundedRectangle(cornerRadius: 10)
				.fill(VaultPalette.control)
				.shadow(color: VaultPalette.shadow.opacity(0.18), radius: 17, y: 14)
		}
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		.onExitCommand { isPresented = false }
	}

	private func accountRow(name: String, initials: String, account: SelectedAccount, square: Bool) -> some View {
		let selected = store.selectedAccount == account && !store.isShowingAccountPage
		return Button {
			store.selectAccount(account)
			isPresented = false
		} label: {
			HStack(spacing: 9) {
				VaultInitialsAvatar(initials: initials, size: 22, square: square)
				Text(name)
					.font(.system(size: 12.5, weight: selected ? .semibold : .regular))
					.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textPrimary)
				Spacer(minLength: 4)
				if selected {
					Image(systemName: "checkmark")
						.font(.system(size: 10, weight: .bold))
						.foregroundStyle(VaultPalette.accentForeground)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			.background(RoundedRectangle(cornerRadius: 7).fill(selected ? VaultPalette.accentTint : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private func menuRow(icon: String, title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 9) {
				Image(systemName: icon).font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary).frame(width: 14)
				Text(title).font(.system(size: 12.5)).foregroundStyle(VaultPalette.textSecondary)
				Spacer(minLength: 4)
				if let shortcut {
					Text(shortcut).font(VaultTypography.mono(10)).foregroundStyle(VaultPalette.textFaint)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	private var personalInitials: String { initials(store.currentUser?.username ?? "LP") }

	private func initials(_ name: String) -> String {
		let value = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
		return value.isEmpty ? "LP" : value.uppercased()
	}
}
