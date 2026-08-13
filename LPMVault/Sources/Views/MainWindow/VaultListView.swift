import SwiftUI

/// Column 2: Vault list for the selected account (personal or org).
struct VaultListView: View {
	@Bindable var store: VaultStore
	@State private var showCloudVaults = false
	@State private var showNewVault = false
	@State private var projectToRename: VaultProject?
	@State private var renameValue = ""
	@State private var projectToDelete: VaultProject?

	private var title: String {
		switch store.selectedAccount {
		case .personal: "Personal"
		case .org(let slug):
			store.userOrgs.first { $0.slug == slug }?.name ?? slug
		}
	}

	private var isOrg: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}

	private var currentOrgSlug: String? {
		if case .org(let slug) = store.selectedAccount { return slug }
		return nil
	}

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text(title)
					.font(.headline)
					.lineLimit(1)

				Spacer()

				if store.isLoggedIn {
					Button {
						showCloudVaults = true
					} label: {
						Image(systemName: "cloud")
							.font(.caption)
					}
					.buttonStyle(.plain)
					.help("Import from cloud")
					.accessibilityLabel("Import env project from cloud")
				}

				Button {
					showNewVault = true
				} label: {
					Image(systemName: "plus")
						.font(.caption)
				}
				.buttonStyle(.plain)
				.help("New env project")
				.accessibilityLabel("New env project")
			}
			.padding(.horizontal, 12)
			.frame(height: 40)

			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField("Search env projects", text: $store.searchQuery)
					.textFieldStyle(.plain)
				if !store.searchQuery.isEmpty {
					Button {
						store.searchQuery = ""
					} label: {
						Image(systemName: "xmark.circle.fill")
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Clear env project search")
				}
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
			.padding(.horizontal, 8)
			.padding(.bottom, 8)

			Divider()

			// Vault list
			if store.filteredVaults.isEmpty {
				VStack(spacing: 8) {
					Image(systemName: isOrg ? "building.2" : "lock.shield")
						.font(.system(size: 28))
						.foregroundStyle(.quaternary)
					Text("No env projects")
						.font(.callout)
						.foregroundStyle(.tertiary)
					if store.searchQuery.isEmpty {
						Button("Create Env Project") { showNewVault = true }
							.buttonStyle(.bordered)
					} else {
						Text("Try a different search.")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List(selection: Binding(
					get: { store.selectedProjectId },
					set: { store.selectProject($0) }
				)) {
					ForEach(store.filteredVaults) { vault in
						vaultRow(vault)
							.tag(vault.id)
							.listRowBackground(Color.clear)
							.accessibilityElement(children: .combine)
							.accessibilityLabel("\(vault.name), \(vault.secretCount) secrets")
							.accessibilityValue(accessibilitySyncDescription(for: vault))
							.accessibilityAddTraits(
								store.selectedProjectId == vault.id ? .isSelected : []
							)
							.contextMenu {
								Button("Edit Name") {
									projectToRename = vault
									renameValue = vault.name
								}
								Divider()
								Button("Delete Locally", role: .destructive) {
									projectToDelete = vault
								}
							}
					}
				}
				.listStyle(.sidebar)
				.scrollContentBackground(.hidden)
			}
		}
		.sheet(isPresented: $showNewVault) {
			NewVaultSheet(store: store)
		}
		.sheet(isPresented: $showCloudVaults) {
			if let slug = currentOrgSlug {
				OrgVaultsSheet(store: store, fixedOrgSlug: slug)
			} else {
				CloudVaultsSheet(store: store)
			}
		}
		.alert("Rename Env Project", isPresented: Binding(
			get: { projectToRename != nil },
			set: { if !$0 { projectToRename = nil } }
		)) {
			TextField("Project name", text: $renameValue)
			Button("Cancel", role: .cancel) { projectToRename = nil }
			Button("Rename") {
				if let projectToRename {
					store.renameProject(projectToRename, to: renameValue)
				}
				projectToRename = nil
			}
			.disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		} message: {
			Text("This changes the local name and includes it in the next sync.")
		}
		.confirmationDialog("Delete local env project?", isPresented: Binding(
			get: { projectToDelete != nil },
			set: { if !$0 { projectToDelete = nil } }
		), titleVisibility: .visible) {
			if let projectToDelete {
				Button("Delete \"\(projectToDelete.name)\" Locally", role: .destructive) {
					Task {
						_ = await store.deleteLocalVault(projectToDelete)
						self.projectToDelete = nil
					}
				}
			}
			Button("Cancel", role: .cancel) { projectToDelete = nil }
		} message: {
			Text("This removes the local Keychain copy. A synced cloud copy is not deleted.")
		}
	}

	@ViewBuilder
	private func vaultRow(_ vault: VaultProject) -> some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 4) {
					Text(vault.name)
						.fontWeight(.medium)
						.lineLimit(1)

					// Sync status dot
					switch store.syncStatus(for: vault.id) {
					case .synced:
						Circle().fill(.green).frame(width: 6, height: 6)
					case .localChanges:
						Circle().fill(.orange).frame(width: 6, height: 6)
					case .neverSynced:
						EmptyView()
					}
				}

				if let info = store.lastSyncInfo(for: vault.id) {
					Text("\(info.action == "push" ? "Pushed" : "Pulled") \(formatTimeAgo(info.date))")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
			}

			Spacer()

			Text("\(vault.secretCount)")
				.font(.caption)
				.padding(.horizontal, 6)
				.padding(.vertical, 2)
				.background(.quaternary, in: Capsule())
		}
	}

	private func formatTimeAgo(_ date: Date) -> String {
		let seconds = Int(-date.timeIntervalSinceNow)
		if seconds < 60 { return "just now" }
		let minutes = seconds / 60
		if minutes < 60 { return "\(minutes)m ago" }
		let hours = minutes / 60
		if hours < 24 { return "\(hours)h ago" }
		return "\(hours / 24)d ago"
	}

	private func accessibilitySyncDescription(for vault: VaultProject) -> String {
		let status = switch store.syncStatus(for: vault.id) {
		case .synced: "Synced"
		case .localChanges: "Local changes"
		case .neverSynced: "Never synced"
		}
		guard let info = store.lastSyncInfo(for: vault.id) else { return status }
		let action = info.action == "push" ? "Pushed" : "Pulled"
		return "\(status), \(action) \(formatTimeAgo(info.date))"
	}
}
