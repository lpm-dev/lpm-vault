import SwiftUI

struct ProjectListView: View {
	@Bindable var store: VaultStore
	@Binding var showingAddProject: Bool

	var body: some View {
		List(selection: $store.selectedSidebarItem) {
			// MARK: - Projects
			Section("Projects") {
				ForEach(store.filteredProjects) { project in
					projectRow(project)
						.tag(SidebarItem.project(project.id))
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
			}

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
					}
				}

				Section("Auth") {
					Label {
						Text("@\(store.currentUser?.username ?? "")")
					} icon: {
						Image(systemName: "person.circle")
					}
					.tag(SidebarItem.authStatus)
				}
			} else if !store.isLoadingTokens {
				Section("Auth") {
					Label {
						VStack(alignment: .leading, spacing: 2) {
							Text("Not logged in")
								.foregroundStyle(.secondary)
							Text("Run `lpm login`")
								.font(.caption)
								.foregroundStyle(.tertiary)
						}
					} icon: {
						Image(systemName: "person.circle")
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.listStyle(.sidebar)
		.onChange(of: store.selectedSidebarItem) { _, newValue in
			// Sync selectedProjectId when a project is selected via SidebarItem
			if case .project(let id) = newValue {
				store.selectedProjectId = id
			}
		}
		.safeAreaInset(edge: .bottom) {
			Button {
				showingAddProject = true
			} label: {
				Label("Add Project", systemImage: "plus")
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
			}
			.buttonStyle(.plain)
		}
	}

	@ViewBuilder
	private func projectRow(_ project: VaultProject) -> some View {
		HStack {
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

	private func abbreviatePath(_ path: String) -> String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path()
		if path.hasPrefix(home) {
			return "~" + path.dropFirst(home.count)
		}
		return path
	}
}
