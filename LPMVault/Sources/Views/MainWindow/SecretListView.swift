import SwiftUI

struct SecretListView: View {
	@Bindable var store: VaultStore
	@State private var showingAddSecret = false

	private var project: VaultProject? {
		store.selectedProject
	}

	var body: some View {
		Group {
			if let project {
				secretList(project)
			} else {
				Text("No project selected")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.sheet(isPresented: $showingAddSecret) {
			if let project {
				AddSecretSheet(store: store, projectId: project.id)
			}
		}
	}

	@ViewBuilder
	private func secretList(_ project: VaultProject) -> some View {
		VStack(spacing: 0) {
			if project.secrets.isEmpty {
				emptyState
			} else {
				List {
					ForEach(project.sortedSecrets) { secret in
						SecretRowView(
							secret: secret,
							isUnlocked: store.isUnlocked,
							onReveal: { Task { await store.unlock() } },
							onUpdate: { newValue in
								store.updateSecret(
									in: project.id, key: secret.key, newValue: newValue)
							},
							onDelete: {
								store.deleteSecret(from: project.id, key: secret.key)
							}
						)
					}
				}
			}

			Divider()
			footer(project)
		}
		.toolbar {
			ToolbarItem(placement: .automatic) {
				Button {
					showingAddSecret = true
				} label: {
					Image(systemName: "plus")
				}
				.help("Add secret")
				.keyboardShortcut("n", modifiers: .command)
			}
		}
		.navigationTitle(project.name)
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			Image(systemName: "key")
				.font(.system(size: 36))
				.foregroundStyle(.secondary)
			Text("No secrets yet")
				.font(.title3)
				.foregroundStyle(.secondary)
			Button("Add Secret") {
				showingAddSecret = true
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func footer(_ project: VaultProject) -> some View {
		HStack(spacing: 16) {
			Label(
				"\(project.secretCount) secret\(project.secretCount == 1 ? "" : "s")",
				systemImage: "key"
			)
			.foregroundStyle(.secondary)

			Spacer()

			if !project.pathExists {
				Label("Path not found", systemImage: "exclamationmark.triangle")
					.foregroundStyle(.orange)
					.font(.caption)
			}

			Text(project.id.prefix(8) + "...")
				.font(.caption)
				.foregroundStyle(.tertiary)
				.help("Vault ID: \(project.id)")
		}
		.font(.caption)
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}
}
