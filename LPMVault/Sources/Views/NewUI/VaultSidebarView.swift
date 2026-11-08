import AppKit
import SwiftUI

enum VaultSidebarLayout {
	static let projectInset: CGFloat = 6
	static let rowInset: CGFloat = 8
	static let rowHeight: CGFloat = 30
	static let childRowHeight: CGFloat = 27
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
	static let childSpacing: CGFloat = 7
	static let childInset: CGFloat = 26
	static let projectLabelInset = projectInset + rowInset + projectIconWidth + projectSpacing
	static let childRowLeadingInset = projectLabelInset - childInset
	static let landingLineInset = projectInset + rowInset
}

struct VaultSidebarView: View {
	@Bindable var store: VaultStore
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
	/// Searches stored values for the text, false when it can't now.
	var onFindAsValue: (String) -> Bool = { _ in false }
	/// The project drag in progress, if any. Tests pass their own to follow it.
	@State var reorder = VaultSidebarReorder()

	@FocusState private var searchFocused: Bool
	@State private var accountHovered = false
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
							Text(searchText.isEmpty ? "No projects yet" : "No matching projects or keys")
								.font(.system(size: 12))
								.foregroundStyle(VaultPalette.textTertiary)
								.padding(.horizontal, 16)
								.padding(.vertical, 12)
							if !searchText.isEmpty, store.isUnlocked { findAsValue }
						} else {
							projectGroups(derivedProjects, order: order)
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
			footer
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
						.foregroundStyle(VaultPalette.placeholder)
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
					.font(VaultTypography.tabular(10))
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
		.vaultSearchField(focused: searchFocused)
	}

	/// Offers to look for what was typed among stored values, as typed text
	/// that names nothing can be a pasted value. It moves into the masked
	/// field, and the search here is cleared.
	private var findAsValue: some View {
		Button {
			guard onFindAsValue(searchText) else { return }
			searchText = ""
			searchFocused = false
		} label: {
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 6) {
					Image(systemName: "text.magnifyingglass")
						.font(.system(size: 10.5, weight: .semibold))
					Text("Find it as a value…")
						.font(.system(size: 12, weight: .semibold))
				}
				.foregroundStyle(VaultPalette.accentForeground)
				Text("Searches what’s stored, not names. Opens masked.")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 12)
		.vaultPointingHand()
		.accessibilityLabel("Find it as a value…")
		.accessibilityHint("Searches what’s stored, not names. Opens masked.")
	}

	private func headerAction(_ title: String, systemImage: String, label: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 4) {
				Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
				Text(title).font(.system(size: 11, weight: .medium))
			}
			.foregroundStyle(VaultPalette.accentForeground)
			.padding(.horizontal, 6)
			.frame(height: 22)
		}
		.buttonStyle(VaultPressStyle(cornerRadius: 5))
		.vaultPointingHand()
		.accessibilityLabel(label)
	}

	private var projectHeader: some View {
		HStack(spacing: 8) {
			Text("PROJECTS").vaultSectionLabel()
			Spacer(minLength: 4)

			// The header has room for one name, so importing names itself on hover, as the footer's icons do.
			if store.isLoggedIn {
				Button(action: onCloudProjects) {
					Image(systemName: "icloud.and.arrow.down")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(VaultPalette.textTertiary)
						.frame(width: 24, height: 22)
						.contentShape(Rectangle())
				}
				.buttonStyle(VaultPressStyle(cornerRadius: 5))
				.vaultTooltip("Import from lpm.dev")
				.accessibilityLabel("Import env project from lpm.dev")
			}
			headerAction("New Project", systemImage: "plus", label: "Create env project", action: onNewProject)
		}
		// One height whether or not the lpm.dev import shows, so the list below never shifts.
		.frame(height: 24)
		.padding(.leading, 16)
		.padding(.trailing, 6)
		.padding(.top, 4)
		.padding(.bottom, 4)
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
		// The project at a glance, beside its row, once the pointer rests there; never while it's being moved.
		.vaultHoverPopover(delay: .milliseconds(400), arrowEdge: .trailing, enabled: reorder.lift == nil && store.isUnlocked) {
			VaultProjectHoverCard(store: store, project: project)
		}
		.accessibilityLabel("\(project.name), \(project.secretCount.counted("secret")), \(approvalDescription)")
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
					.foregroundStyle(selected ? VaultPalette.textPrimary : VaultPalette.textSecondary)
					.lineLimit(1)
					.frame(maxWidth: .infinity, alignment: .leading)
				VaultSidebarApprovalIndicator(access: cliAccess)
				Text("\(project.secretCount)")
					.font(VaultTypography.tabular(11))
					.foregroundStyle(VaultPalette.textTertiary)
					.help("\(project.secretCount.counted("value")) across \(project.environmentNames.count.counted("environment"))")
					.frame(minWidth: VaultSidebarLayout.countMinimumWidth, alignment: .trailing)
			}
			.padding(.horizontal, VaultSidebarLayout.rowInset)
			.frame(height: VaultSidebarLayout.rowHeight)
			.background(RoundedRectangle(cornerRadius: 7).fill(selected ? VaultPalette.sidebarSelection
				: (hovered && reorder.lift == nil ? VaultPalette.sidebarHover : .clear)))
			.vaultHoverAnimation(hovered)
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
			historyRow(project)

			ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
				environmentRow(project, environment: environment, color: VaultPalette.environment(index))
			}

			VaultSidebarHoverReader { hovered in
				Button(action: onNewEnvironment) {
					HStack(spacing: VaultSidebarLayout.childSpacing) {
						Image(systemName: "plus")
							.font(.system(size: 9.5, weight: .semibold))
							.frame(width: VaultSidebarLayout.childIconWidth)
							.offset(x: VaultSidebarLayout.childIconOffset)
						Text("New Environment").font(.system(size: 12))
						Spacer()
					}
					.foregroundStyle(hovered ? VaultPalette.accentForeground : VaultPalette.textTertiary)
					.childRow(selected: false, hovered: hovered)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Add environment to \(project.name)")
			}
		}
		.padding(.leading, VaultSidebarLayout.childInset)
		.padding(.trailing, VaultSidebarLayout.projectInset)
		.padding(.top, 2)
		.padding(.bottom, 8)
	}

	private func schemaRow(_ project: VaultProject) -> some View {
		let selected = !store.isShowingAccountPage && mode == .schema
		let state = store.keyDescriptions[project.id]?.schema
		let count = state?.overview?.rules.count
		let unreadable = if case .unreadable? = state { true } else { false }
		let hasDraft = store.projectsWithSchemaDrafts.contains(project.id)
		return VaultSidebarHoverReader { hovered in Button {
			store.openProject(id: project.id)
			mode = .schema
		} label: {
			HStack(spacing: VaultSidebarLayout.childSpacing) {
				Image(systemName: "curlybraces")
					.font(.system(size: 10, weight: .semibold))
					.frame(width: VaultSidebarLayout.childIconWidth)
					.offset(x: VaultSidebarLayout.childIconOffset)
					.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
				Text("Schema")
					.font(.system(size: 12, weight: selected ? .medium : .regular))
					.foregroundStyle(selected ? VaultPalette.textPrimary : VaultPalette.textSecondary)
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
						.font(VaultTypography.tabular(11))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
			.childRow(selected: selected, hovered: hovered)
		}
		.buttonStyle(.plain) }
		.accessibilityLabel("Schema")
		.accessibilityValue([unreadable ? "lpm.json can't be read" : count.map { $0.counted("declared key") }, hasDraft ? "unsaved rule changes" : nil].compactMap { $0 }.joined(separator: ", "))
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private func historyRow(_ project: VaultProject) -> some View {
		let selected = !store.isShowingAccountPage && mode == .history
		let history = store.history
		let showsThisProject = history.projectID == project.id
		// What's known of every project: why its last change wasn't recorded,
		// and what its listing shows; the page adds what reading found.
		let listed = store.projectCompanionStates[project.id]
		let warns = history.notRecorded[project.id] != nil
			|| listed?.features.contains { $0.name == "history" && !$0.supported } == true
			|| listed?.damage.contains { $0.repair?.feature == "history" } == true
			|| (showsThisProject && (
				["unsupported", "removing", "both"].contains(history.state?.history ?? "")
				|| history.state?.damage.isEmpty == false
				|| (history.timeline?.unreadableParts ?? 0) > 0
				|| history.timeline?.damagedTail == true))
		return VaultSidebarHoverReader { hovered in Button {
			store.openProject(id: project.id)
			mode = .history
		} label: {
			HStack(spacing: VaultSidebarLayout.childSpacing) {
				Image(systemName: "clock.arrow.circlepath")
					.font(.system(size: 10, weight: .semibold))
					.frame(width: VaultSidebarLayout.childIconWidth)
					.offset(x: VaultSidebarLayout.childIconOffset)
					.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
				Text("History")
					.font(.system(size: 12, weight: selected ? .medium : .regular))
					.foregroundStyle(selected ? VaultPalette.textPrimary : VaultPalette.textSecondary)
				if warns {
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 9.5))
						.foregroundStyle(VaultPalette.orange)
						.help("Local history needs attention")
				}
				Spacer(minLength: 4)
			}
			.childRow(selected: selected, hovered: hovered)
		}
		.buttonStyle(.plain) }
		.accessibilityLabel("History")
		.accessibilityValue(warns ? "needs attention" : "")
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private func environmentRow(_ project: VaultProject, environment: String, color: Color) -> some View {
		let selected = !store.isShowingAccountPage && mode == .environment(environment)
		let target = VaultEnvironmentTarget(projectId: project.id, environment: environment)
		return VaultSidebarHoverReader { hovered in Button {
			store.openProject(id: project.id)
			store.selectEnvironment(environment)
			mode = .environment(environment)
		} label: {
			HStack(spacing: VaultSidebarLayout.childSpacing) {
				VaultEnvSwatch(color: color, size: VaultSidebarLayout.environmentSwatchSize)
					.frame(width: VaultSidebarLayout.childIconWidth)
					.offset(x: VaultSidebarLayout.childIconOffset)
				Text(VaultProject.displayName(for: environment))
					.font(.system(size: 12, weight: selected ? .medium : .regular))
					.foregroundStyle(selected ? VaultPalette.textPrimary : VaultPalette.textSecondary)
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer(minLength: 4)
				Text("\(project.secretCount(for: environment))")
					.font(VaultTypography.tabular(11))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.childRow(selected: selected, hovered: hovered)
		}
		.buttonStyle(.plain) }
		.accessibilityLabel(VaultProject.displayName(for: environment))
		.accessibilityValue(project.secretCount(for: environment).counted("secret"))
		.accessibilityAddTraits(selected ? .isSelected : [])
		.contextMenu {
			let canEdit = store.canEditValues(of: project.id)
			Button("Rename…") { onRenameEnvironment(target) }
				.disabled(!canEdit)
			Button("Duplicate…") { onDuplicateEnvironment(target) }
				.disabled(!canEdit)
			Button("Show History") {
				store.openProject(id: project.id)
				store.history.show(project.id, environment: environment)
			}
			Divider()
			Button("Clear All Secrets", role: .destructive) { onClearEnvironment(target) }
				.disabled(!canEdit || project.secretCount(for: environment) == 0)
			if project.environmentNames.count > 1 {
				Button("Delete Environment", role: .destructive) { onDeleteEnvironment(target) }
					.disabled(!canEdit)
			}
		}
	}

	/// The app's own pages, in the sidebar so it shows where the window is
	/// while one of them takes the place of a project.
	/// Who the vault is, which opens the account menu, and the app's pages as
	/// icons that name themselves on hover.
	private var footer: some View {
		HStack(spacing: 4) {
			Button {
				showsAccountSwitcher.toggle()
			} label: {
				HStack(spacing: 8) {
					VaultInitialsAvatar(initials: accountInitials, size: 22, square: store.selectedAccount != .personal)
					Text(accountName)
						.font(.system(size: 12.5, weight: .medium))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.tail)
					Image(systemName: "chevron.up.chevron.down")
						.font(.system(size: 8.5, weight: .semibold))
						.foregroundStyle(showsAccountSwitcher ? VaultPalette.accentForeground : VaultPalette.textTertiary)
						.accessibilityHidden(true)
				}
				.padding(.leading, 5)
				.padding(.trailing, 8)
				.frame(height: 32)
				.background(RoundedRectangle(cornerRadius: 7).fill(showsAccountSwitcher || accountHovered ? VaultPalette.sidebarHover : .clear))
				.vaultHoverAnimation(accountHovered)
				.contentShape(Rectangle())
			}
			.buttonStyle(VaultPressStyle())
			.onHover { accountHovered = $0 }
			.accessibilityLabel("Account menu, \(accountName)")
			.layoutPriority(1)

			Spacer(minLength: 4)
			footerPage("Platforms", systemImage: "square.stack.3d.up", page: .platforms) { store.showPlatforms() }
			footerPage("Settings", systemImage: "gearshape", page: .settings, shortcut: "⌘,") { store.showSettings() }
		}
		.padding(.horizontal, 8)
		.frame(height: 48)
	}

	private func footerPage(_ title: String, systemImage: String, page: AccountPage, shortcut: String? = nil,
		action: @escaping () -> Void) -> some View {
		let selected = store.accountPage == page
		return VaultSidebarHoverReader { hovered in
			Button(action: action) {
				Image(systemName: systemImage)
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(selected ? VaultPalette.accentForeground : (hovered ? VaultPalette.textPrimary : VaultPalette.textSecondary))
					.frame(width: 30, height: 30)
					.background(RoundedRectangle(cornerRadius: 7).fill(selected ? VaultPalette.sidebarSelection
						: (hovered ? VaultPalette.sidebarHover : .clear)))
					.vaultHoverAnimation(hovered)
					.contentShape(Rectangle())
			}
			.buttonStyle(VaultPressStyle())
		}
		.vaultTooltip(shortcut.map { "\(title)  \($0)" } ?? title)
		.accessibilityLabel(title)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private var accountName: String {
		switch store.selectedAccount {
		case .personal: return store.currentUser?.username ?? "Personal vault"
		case .org(let slug): return store.userOrgs.first(where: { $0.slug == slug })?.name ?? slug
		}
	}

	private var accountInitials: String { VaultInitialsAvatar.initial(of: accountName) }
}

private extension View {
	/// The padding, fill and hover of a row under a project: Schema, History, an environment.
	func childRow(selected: Bool, hovered: Bool) -> some View {
		padding(.leading, VaultSidebarLayout.childRowLeadingInset)
			.padding(.trailing, VaultSidebarLayout.rowInset)
			.frame(height: VaultSidebarLayout.childRowHeight)
			.background(RoundedRectangle(cornerRadius: 6).fill(selected ? VaultPalette.sidebarSelection
				: (hovered ? VaultPalette.sidebarHover : .clear)))
			.vaultHoverAnimation(hovered)
			.contentShape(Rectangle())
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

	var body: some View {
		switch access {
		case .requireApproval?:
			Image(systemName: "lock.fill")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(VaultPalette.accentForeground)
				.frame(width: VaultSidebarLayout.approvalWidth)
				.help("CLI approval required")
				.accessibilityHidden(true)
		case .automatic?:
			EmptyView()
		case nil:
			Image(systemName: "questionmark.circle")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(VaultPalette.textFaint)
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
	/// Asks to sign out, which the workspace confirms first.
	var onSignOut: () -> Void = {}

	@State private var hovered: Choice?

	private enum Choice: Hashable {
		case account(SelectedAccount)
		case manage
		case signOut
		case signIn
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			sectionLabel("PERSONAL")
			accountRow(name: store.currentUser?.username ?? "Personal vault", initials: personalInitials, round: true, account: .personal)
			if !store.userOrgs.isEmpty {
				sectionLabel("ORGANIZATIONS").padding(.top, 6)
				ForEach(store.userOrgs) { org in
					accountRow(name: org.name, initials: VaultInitialsAvatar.initial(of: org.name), round: false, account: .org(org.slug))
				}
			}
			VaultHairline().padding(.horizontal, 8).padding(.vertical, 6)
			if store.isLoggedIn {
				menuRow("Manage account on lpm.dev", systemImage: "arrow.up.right.square", choice: .manage) {
					if let url = store.accountManagementURL { NSWorkspace.shared.open(url) }
					isPresented = false
				}
				menuRow("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right", choice: .signOut) {
					isPresented = false
					onSignOut()
				}
			} else {
				menuRow("Sign In…", systemImage: "person.crop.circle", choice: .signIn) {
					store.showSettings()
					isPresented = false
				}
			}
		}
		.padding(6)
		.background {
			RoundedRectangle(cornerRadius: 10)
				.fill(VaultPalette.control)
				.shadow(color: VaultPalette.shadow.opacity(0.12), radius: 10, y: 4)
		}
		.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border, lineWidth: 1) }
		.onExitCommand { isPresented = false }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Account menu")
	}

	private func sectionLabel(_ title: String) -> some View {
		Text(title)
			.vaultSectionLabel()
			.padding(.horizontal, 8)
			.padding(.top, 4)
			.padding(.bottom, 3)
			.accessibilityAddTraits(.isHeader)
	}

	/// A vault: the person's own in a round avatar, an organization's in a rounded square, the open one checked.
	private func accountRow(name: String, initials: String, round: Bool, account: SelectedAccount) -> some View {
		// The vault in use stays checked while Settings or Platforms shows over it.
		let selected = store.selectedAccount == account
		return Button {
			store.selectAccount(account)
			isPresented = false
		} label: {
			HStack(spacing: 10) {
				VaultInitialsAvatar(initials: initials, size: 24, square: !round)
					.accessibilityHidden(true)
				Text(name)
					.font(.system(size: 12.5, weight: selected ? .semibold : .regular))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				Spacer(minLength: 4)
				if selected {
					Image(systemName: "checkmark")
						.font(.system(size: 10, weight: .bold))
						.foregroundStyle(VaultPalette.accentForeground)
						.accessibilityHidden(true)
				}
			}
			.padding(.horizontal, 8)
			.frame(height: 34)
			.background(RoundedRectangle(cornerRadius: 6).fill(hovered == .account(account) ? VaultPalette.menuHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { inside in hover(.account(account), inside) }
		.accessibilityLabel(name)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private func menuRow(_ title: String, systemImage: String, choice: Choice, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: systemImage)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.frame(width: 24)
					.accessibilityHidden(true)
				Text(title).font(.system(size: 12.5)).foregroundStyle(VaultPalette.textPrimary)
				Spacer(minLength: 4)
			}
			.padding(.horizontal, 8)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 6).fill(hovered == choice ? VaultPalette.menuHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { inside in hover(choice, inside) }
	}

	private func hover(_ choice: Choice, _ inside: Bool) {
		if inside { hovered = choice } else if hovered == choice { hovered = nil }
	}

	private var personalInitials: String { VaultInitialsAvatar.initial(of: store.currentUser?.username ?? "Personal vault") }
}
