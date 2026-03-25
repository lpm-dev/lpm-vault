import SwiftUI

struct SecretListView: View {
	@Bindable var store: VaultStore
	@State private var showingAddSecret = false
	@State private var showDeleteProjectConfirmation = false
	@State private var localSearch = ""
	@State private var showSearch = false
	@FocusState private var isSearchFocused: Bool

	private var project: VaultProject? {
		store.selectedProject
	}

	private var currentSecrets: [VaultSecret] {
		guard let project else { return [] }
		return project.sortedSecrets(for: store.selectedEnvironment)
	}

	private var filteredSecrets: [VaultSecret] {
		guard !localSearch.isEmpty else { return currentSecrets }
		let query = localSearch.lowercased()
		return currentSecrets.filter {
			$0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
		}
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
			// Custom header bar
			customToolbar(project)
			Divider()

			// Environment tabs (only show if more than one environment)
			if project.environmentNames.count > 1 {
				environmentTabs(project)
				Divider()
			}

			// Search bar
			if showSearch {
				searchBar
				Divider()
			}

			if currentSecrets.isEmpty && !showSearch {
				emptyState
			} else if filteredSecrets.isEmpty && showSearch {
				VStack(spacing: 8) {
					Text("No secrets matching \"\(localSearch)\"")
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List {
					ForEach(filteredSecrets) { secret in
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
				.id(store.selectedEnvironment)  // Reset scroll position on tab change
			}

			Divider()
			footer(project)
		}
		.confirmationDialog(
			"Delete \"\(project.name)\"?",
			isPresented: $showDeleteProjectConfirmation,
			titleVisibility: .visible
		) {
			Button("Delete", role: .destructive) {
				store.deleteProject(project)
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This removes the project from your local vault. If synced to the cloud, the cloud copy remains and can be restored with `lpm env vars pull`.")
		}
	}

	// MARK: - Custom Toolbar

	private func customToolbar(_ project: VaultProject) -> some View {
		HStack(spacing: 8) {
			// Left: project name + delete
			Text(project.name)
				.font(.title3)
				.fontWeight(.semibold)

			ToolbarButtonGroup {
				ToolbarIconButton(icon: "trash", help: "Delete project", role: .destructive) {
					showDeleteProjectConfirmation = true
				}
			}

			Spacer()

			// Sync [pull, push]
			if store.isLoggedIn {
				ToolbarButtonGroup {
					ToolbarIconButton(icon: "arrow.down.to.line", help: "Pull from cloud") {
						store.lastSyncStatus = "Use `lpm env vars pull`"
					}
					ToolbarIconButton(icon: "arrow.up.to.line", help: "Push to cloud") {
						store.lastSyncStatus = "Use `lpm env vars push`"
					}
				}
			}

			// Data [copy, export]
			ToolbarButtonGroup {
				ToolbarIconButton(icon: "doc.on.clipboard", help: "Copy all as KEY=VALUE") {
					let envString = project.sortedSecrets(for: store.selectedEnvironment)
						.map { "\($0.key)=\($0.value)" }
						.joined(separator: "\n")
					ClipboardManager.shared.copy(envString, clearAfter: 60)
				}
				ToolbarIconButton(icon: "square.and.arrow.up", help: "Export to .env file") {
					exportToFile()
				}
			}

			// Add
			ToolbarButtonGroup {
				ToolbarIconButton(icon: "plus", help: "Add secret") {
					showingAddSecret = true
				}
			}

			// Search
			ToolbarButtonGroup {
				ToolbarIconButton(
					icon: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass",
					help: "Search secrets"
				) {
					showSearch.toggle()
					if showSearch {
						isSearchFocused = true
					} else {
						localSearch = ""
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}

	// MARK: - Environment Tabs

	private func environmentTabs(_ project: VaultProject) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 0) {
				ForEach(project.environmentNames, id: \.self) { env in
					Button {
						store.selectedEnvironment = env
					} label: {
						HStack(spacing: 4) {
							Text(env)
								.font(.subheadline)
								.fontWeight(store.selectedEnvironment == env ? .semibold : .regular)
							Text("\(project.secretCount(for: env))")
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.contentShape(Rectangle())  // Entire area is clickable
						.background(
							store.selectedEnvironment == env
								? Color.accentColor.opacity(0.15)
								: Color.clear,
							in: RoundedRectangle(cornerRadius: 6)
						)
					}
					.buttonStyle(.plain)
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 4)
		}
		.onAppear {
			// Select first environment if current selection doesn't exist in this project
			if !project.environmentNames.contains(store.selectedEnvironment) {
				store.selectedEnvironment = project.environmentNames.first ?? "default"
			}
		}
	}

	// MARK: - Search Bar

	private var searchBar: some View {
		HStack {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(.secondary)
			TextField("Filter secrets...", text: $localSearch)
				.textFieldStyle(.plain)
				.focused($isSearchFocused)
				.onExitCommand {
					showSearch = false
					localSearch = ""
				}
			if !localSearch.isEmpty {
				Button {
					localSearch = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	// MARK: - Subviews

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

	private func exportToFile() {
		guard let project else { return }
		let panel = NSSavePanel()
		let envSuffix = store.selectedEnvironment == "default" ? "" : ".\(store.selectedEnvironment)"
		panel.nameFieldStringValue = ".env\(envSuffix)"
		panel.message = "Export \(store.selectedEnvironment) secrets to .env file"

		if panel.runModal() == .OK, let url = panel.url {
			let content = project.sortedSecrets(for: store.selectedEnvironment)
				.map { secret in
					let v = secret.value
					if v.contains(" ") || v.contains("\"") || v.contains("'") || v.contains("\n") {
						return "\(secret.key)=\"\(v.replacingOccurrences(of: "\"", with: "\\\""))\""
					}
					return "\(secret.key)=\(v)"
				}
				.joined(separator: "\n") + "\n"
			try? content.write(to: url, atomically: true, encoding: .utf8)
		}
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
