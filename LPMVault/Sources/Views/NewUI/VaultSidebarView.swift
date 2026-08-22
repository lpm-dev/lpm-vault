import AppKit
import SwiftUI

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
	let onRenameProject: (VaultProject) -> Void
	let onDeleteProject: (VaultProject) -> Void
	let onRenameEnvironment: (VaultEnvironmentTarget) -> Void
	let onDuplicateEnvironment: (VaultEnvironmentTarget) -> Void
	let onClearEnvironment: (VaultEnvironmentTarget) -> Void
	let onDeleteEnvironment: (VaultEnvironmentTarget) -> Void

	@FocusState private var searchFocused: Bool

	private var visibleProjects: [VaultProject] {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !query.isEmpty else { return store.activeVaults }
		return store.activeVaults.filter { project in
			project.name.lowercased().contains(query)
				|| (snapshots[project.id]?.allSecretKeys ?? []).contains { $0.lowercased().contains(query) }
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			searchField
				.padding(.horizontal, 14)
				.padding(.top, 14)
				.padding(.bottom, 10)

			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					projectHeader

					if visibleProjects.isEmpty {
						Text(searchText.isEmpty ? "No env projects" : "No matching projects or keys")
							.font(.system(size: 12))
							.foregroundStyle(VaultPalette.textTertiary)
							.padding(.horizontal, 16)
							.padding(.vertical, 12)
					} else {
						ForEach(visibleProjects) { project in
							projectRow(project)
							if store.selectedProjectId == project.id {
								environmentRows(project)
							}
						}
					}

					if let project = store.selectedProject {
						smartViews(project)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: .infinity, alignment: .top)
			.simultaneousGesture(TapGesture().onEnded { searchFocused = false })

			VaultHairline(color: VaultPalette.sidebarBorder)
			accountFooter
				.simultaneousGesture(TapGesture().onEnded { searchFocused = false })
		}
		.background(VaultPalette.sidebar)
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
		.background(RoundedRectangle(cornerRadius: 8).fill(.white))
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
					.foregroundStyle(VaultPalette.accent)
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
				.foregroundStyle(VaultPalette.accent)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Create env project")
		}
		.padding(.leading, 16)
		.padding(.trailing, 10)
		.padding(.top, 2)
		.padding(.bottom, 6)
	}

	private func projectRow(_ project: VaultProject) -> some View {
		let selected = store.selectedProjectId == project.id && mode == .matrix
		return Button {
			store.openProject(id: project.id)
			mode = .matrix
			filter = .all
		} label: {
			HStack(spacing: 9) {
				Image(systemName: "folder")
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(selected ? VaultPalette.accent : VaultPalette.textTertiary)
				Text(project.name)
					.font(.system(size: 13, weight: selected ? .semibold : .regular))
					.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textSecondary)
					.lineLimit(1)
				Spacer(minLength: 4)
				Text("\(project.secretCount)")
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.padding(.horizontal, 9)
			.padding(.vertical, 7)
			.background(RoundedRectangle(cornerRadius: 7).fill(selected ? VaultPalette.accentTint : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 8)
		.accessibilityLabel("\(project.name), \(project.secretCount) secrets")
		.accessibilityAddTraits(selected ? .isSelected : [])
		.contextMenu {
			Button("Rename…") { onRenameProject(project) }
			Divider()
			Button("Delete Locally", role: .destructive) { onDeleteProject(project) }
		}
	}

	private func environmentRows(_ project: VaultProject) -> some View {
		let environments = store.orderedEnvironmentNames(for: project)
		return LazyVStack(spacing: 1) {
			Button(action: onNewEnvironment) {
				HStack(spacing: 6) {
					Image(systemName: "plus").font(.system(size: 9, weight: .bold))
					Text("New environment").font(.system(size: 10.5, weight: .semibold))
					Spacer()
				}
				.foregroundStyle(VaultPalette.accent)
				.padding(.horizontal, 9)
				.padding(.vertical, 5)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Add environment to \(project.name)")

			ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
				environmentRow(project, environment: environment, color: VaultPalette.environment(index))
			}
		}
		.padding(.leading, 26)
		.padding(.trailing, 8)
		.padding(.top, 2)
		.padding(.bottom, 6)
	}

	private func environmentRow(_ project: VaultProject, environment: String, color: Color) -> some View {
		let selected = mode == .environment(environment)
		let target = VaultEnvironmentTarget(projectId: project.id, environment: environment)
		return Button {
			store.openProject(id: project.id)
			store.selectEnvironment(environment)
			mode = .environment(environment)
		} label: {
			HStack(spacing: 7) {
				VaultEnvSwatch(color: color, size: 6)
				Text(VaultProject.displayName(for: environment))
					.font(VaultTypography.mono(11.5, selected ? .bold : .regular))
					.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textSecondary)
					.lineLimit(1)
				Spacer(minLength: 4)
				Text("\(project.secretCount(for: environment))")
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(selected ? VaultPalette.accent : VaultPalette.textTertiary)
			}
			.padding(.horizontal, 9)
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
			if project.environments.count > 1 {
				Button("Delete Environment", role: .destructive) { onDeleteEnvironment(target) }
			}
		}
	}

	private func smartViews(_ project: VaultProject) -> some View {
		let snapshot = snapshots[project.id] ?? VaultWorkspaceSnapshot(project: project)
		let drift = snapshot.driftingKeyCount
		let missing = snapshot.missingKeyCount
		return VStack(alignment: .leading, spacing: 1) {
			Text("SMART VIEWS")
				.vaultSectionLabel()
				.padding(.horizontal, 16)
				.padding(.top, 16)
				.padding(.bottom, 6)

			smartViewRow(title: "Drift between envs", symbol: "diamond.fill", count: drift, tint: VaultPalette.orange, target: .drift)
			smartViewRow(title: "Missing in an environment", symbol: "exclamationmark.triangle.fill", count: missing, tint: VaultPalette.red, target: .missing)
		}
		.padding(.horizontal, 8)
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
					.foregroundStyle(showsAccountSwitcher ? VaultPalette.accent : VaultPalette.textTertiary)
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
			menuRow(icon: "lock", title: "Lock vault", shortcut: "⌃⌘L") {
				store.lock()
				isPresented = false
			}
		}
		.padding(6)
		.background {
			RoundedRectangle(cornerRadius: 10)
				.fill(.white)
				.shadow(color: VaultPalette.textPrimary.opacity(0.18), radius: 17, y: 14)
		}
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		.onExitCommand { isPresented = false }
	}

	private func accountRow(name: String, initials: String, account: SelectedAccount, square: Bool) -> some View {
		let selected = store.selectedAccount == account && !store.showAuthStatus
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
						.foregroundStyle(VaultPalette.accent)
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

	private func menuRow(icon: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 9) {
				Image(systemName: icon).font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary).frame(width: 14)
				Text(title).font(.system(size: 12.5)).foregroundStyle(VaultPalette.textSecondary)
				Spacer(minLength: 4)
				Text(shortcut).font(VaultTypography.mono(10)).foregroundStyle(VaultPalette.textFaint)
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
