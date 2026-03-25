import SwiftUI

struct ProjectListView: View {
	@Bindable var store: VaultStore
	@Binding var showingAddProject: Bool

	var body: some View {
		List(selection: $store.selectedProjectId) {
			Section("Projects") {
				ForEach(store.filteredProjects) { project in
					projectRow(project)
						.tag(project.id)
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
		}
		.listStyle(.sidebar)
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
