import SwiftUI

/// Column 2: Vault list for the selected account (personal or org).
struct VaultListView: View {
	@Bindable var store: VaultStore
	@State private var showCloudVaults = false
	@State private var showNewVault = false

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
				}

				Button {
					showNewVault = true
				} label: {
					Image(systemName: "plus")
						.font(.caption)
				}
				.buttonStyle(.plain)
				.help("New vault")
			}
			.padding(.horizontal, 12)
			.frame(height: 40)

			Divider()

			// Vault list
			if store.filteredVaults.isEmpty {
				VStack(spacing: 8) {
					Image(systemName: isOrg ? "building.2" : "lock.shield")
						.font(.system(size: 28))
						.foregroundStyle(.quaternary)
					Text("No vaults")
						.font(.callout)
						.foregroundStyle(.tertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List(selection: $store.selectedProjectId) {
					ForEach(store.filteredVaults) { vault in
						vaultRow(vault)
							.tag(vault.id)
							.listRowBackground(Color.clear)
							.contextMenu {
								Button("Edit Name") {
									// TODO: inline rename
								}
								Divider()
								Button("Delete Locally") {
									store.deleteLocalVault(vault)
								}
								Button("Remove Local + Cloud", role: .destructive) {
									Task.detached { [store] in
										await store.deleteEverywhere(vault)
									}
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
		.onChange(of: store.selectedAccount) { _, _ in
			// Clear selection when switching accounts so column 3 resets
			store.selectedProjectId = nil
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
}
