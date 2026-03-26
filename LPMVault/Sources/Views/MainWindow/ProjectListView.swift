import SwiftUI

struct ProjectListView: View {
	@Bindable var store: VaultStore
	@Binding var showingAddProject: Bool
	@Binding var showingOrgVaults: Bool

	var body: some View {
		List(selection: $store.selectedSidebarItem) {
			// MARK: - Tokens
			if store.isLoggedIn {
				Section("Tokens") {
					Label {
						HStack {
							Text("Personal")
							Spacer()
							if !store.personalTokens.isEmpty {
								Text("\(store.personalTokens.count)")
									.font(.caption)
									.padding(.horizontal, 6)
									.padding(.vertical, 2)
									.background(.quaternary, in: Capsule())
							}
						}
					} icon: {
						Image(systemName: "key")
					}
					.tag(SidebarItem.personalTokens)
					.listRowBackground(Color.clear)

					ForEach(store.userOrgs) { org in
						Label {
							HStack {
								Text(org.name)
								Spacer()
								if let count = store.orgTokens[org.slug]?.count, count > 0 {
									Text("\(count)")
										.font(.caption)
										.padding(.horizontal, 6)
										.padding(.vertical, 2)
										.background(.quaternary, in: Capsule())
								}
							}
						} icon: {
							Image(systemName: "building.2")
						}
						.tag(SidebarItem.orgTokens(org.slug))
						.listRowBackground(Color.clear)
					}
				}
			} else if !store.isLoadingTokens {
				Section("Auth") {
					Button {
						Task { await store.login() }
					} label: {
						Label {
							VStack(alignment: .leading, spacing: 2) {
								Text(store.isLoggingIn ? "Signing in..." : "Sign In")
									.foregroundStyle(store.isLoggingIn ? .secondary : .primary)
								if store.isLoggingIn {
									Text("Check your browser")
										.font(.caption)
										.foregroundStyle(.tertiary)
								}
							}
						} icon: {
							if store.isLoggingIn {
								ProgressView()
									.controlSize(.small)
							} else {
								Image(systemName: "person.circle")
									.foregroundStyle(.secondary)
							}
						}
					}
					.buttonStyle(.plain)
					.disabled(store.isLoggingIn)
				}
			}

			// MARK: - Projects
			Section {
				ForEach(store.filteredProjects) { project in
					projectRow(project)
						.tag(SidebarItem.project(project.id))
						.listRowBackground(Color.clear)
						.contextMenu {
							Button("Show in Finder") {
								if project.pathExists {
									NSWorkspace.shared.selectFile(
										nil,
										inFileViewerRootedAtPath: project.path
									)
								}
							}
							.disabled(!project.pathExists)

							Divider()

							Button("Delete Project", role: .destructive) {
								store.deleteProject(project)
							}
						}
				}
			} header: {
				HStack {
					Text("Projects")
					Spacer()
					if store.isLoggedIn && !store.userOrgs.isEmpty {
						Button {
							showingOrgVaults = true
						} label: {
							HStack(spacing: 2) {
								Image(systemName: "building.2")
								Text("Org")
							}
							.font(.caption)
						}
						.buttonStyle(.plain)
						.help("Import from org vault")
					}
					Button {
						showingAddProject = true
					} label: {
						HStack(spacing: 2) {
							Image(systemName: "plus")
							Text("Add")
						}
						.font(.caption)
					}
					.buttonStyle(.plain)
					.help("Add project")
					.padding(.trailing, 8)
				}
			}
		}
		.listStyle(.sidebar)
		.scrollContentBackground(.hidden)
		.onChange(of: store.selectedSidebarItem) { _, newValue in
			// Sync selectedProjectId when a project is selected via SidebarItem
			if case .project(let id) = newValue {
				store.selectedProjectId = id
			}
		}
		.safeAreaInset(edge: .top, spacing: 0) {
			// Padding for traffic lights
			Color.clear.frame(height: 28)
		}
		.safeAreaInset(edge: .bottom) {
			// User footer with lock
			userFooter
		}
	}

	// MARK: - User Footer

	private var userFooter: some View {
		HStack(spacing: 8) {
			Button {
				store.selectedSidebarItem = .authStatus
			} label: {
				HStack(spacing: 6) {
					userAvatar
					if let username = store.currentUser?.username {
						Text("@\(username)")
							.font(.callout)
							.lineLimit(1)
					} else {
						Text("Not logged in")
							.font(.callout)
							.foregroundStyle(.secondary)
					}
				}
			}
			.buttonStyle(.plain)

			if store.appEnvironment == .development {
				Text("DEV")
					.font(.system(size: 9, weight: .bold, design: .monospaced))
					.foregroundStyle(.white)
					.padding(.horizontal, 5)
					.padding(.vertical, 2)
					.background(.orange, in: RoundedRectangle(cornerRadius: 4))
					.help("Connected to localhost:3000")
			}

			Spacer()

			Button {
				store.lock()
			} label: {
				Image(systemName: "lock.open.fill")
					.font(.system(size: 14))
			}
			.buttonStyle(.plain)
			.help("Lock vault")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.contextMenu {
			if store.appEnvironment == .production {
				Button("Switch to Development Server") {
					store.switchEnvironment(to: .development)
				}
			} else {
				Button("Switch to Production Server") {
					store.switchEnvironment(to: .production)
				}
			}
		}
	}

	@ViewBuilder
	private var userAvatar: some View {
		if let avatarUrl = store.currentUser?.avatarUrl,
			let url = URL(string: avatarUrl)
		{
			AsyncImage(url: url) { image in
				image
					.resizable()
					.scaledToFill()
			} placeholder: {
				Image(systemName: "person.circle.fill")
					.font(.system(size: 20))
			}
			.frame(width: 20, height: 20)
			.clipShape(Circle())
		} else {
			Image(systemName: "person.circle.fill")
				.font(.system(size: 20))
		}
	}

	// MARK: - Rows

	@ViewBuilder
	private func projectRow(_ project: VaultProject) -> some View {
		HStack(spacing: 8) {
			Image(systemName: "folder")
				.foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 4) {
					Text(project.name)
						.fontWeight(.medium)
					if !project.pathExists {
						Image(systemName: "exclamationmark.triangle.fill")
							.font(.caption2)
							.foregroundStyle(.orange)
							.help("Project path not found: \(project.path)")
					}
					syncStatusDot(for: project.id)
				}
				Text(abbreviatePath(project.path))
					.font(.caption)
					.foregroundStyle(.tertiary)
					.lineLimit(1)
			}
			Spacer()
			Text("\(project.secretCount)")
				.font(.caption)
				.padding(.horizontal, 6)
				.padding(.vertical, 2)
				.background(.quaternary, in: Capsule())
		}
	}

	@ViewBuilder
	private func syncStatusDot(for vaultId: String) -> some View {
		switch store.syncStatus(for: vaultId) {
		case .synced:
			Circle()
				.fill(.green)
				.frame(width: 6, height: 6)
				.help("Synced with cloud")
		case .localChanges:
			Circle()
				.fill(.orange)
				.frame(width: 6, height: 6)
				.help("Local changes not pushed")
		case .neverSynced:
			EmptyView()
		}
	}

	private func abbreviatePath(_ path: String) -> String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path()
		if path.hasPrefix(home) {
			return "~" + path.dropFirst(home.count)
		}
		return path
	}
}

// MARK: - Color Hex Extension

extension Color {
	init(hex: UInt, opacity: Double = 1.0) {
		self.init(
			red: Double((hex >> 16) & 0xFF) / 255.0,
			green: Double((hex >> 8) & 0xFF) / 255.0,
			blue: Double(hex & 0xFF) / 255.0,
			opacity: opacity
		)
	}
}
