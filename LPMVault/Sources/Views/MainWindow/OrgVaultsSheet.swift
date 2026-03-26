import SwiftUI

/// Sheet that lists shared org vaults for discovery and import.
/// Allows users to pull org vaults without needing lpm.json.
struct OrgVaultsSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var selectedOrg: String?
	@State private var orgVaults: [SyncService.OrgVaultEntry] = []
	@State private var isLoading = false
	@State private var isPulling: String?  // vault ID being pulled
	@State private var pullResult: String?

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Org Vaults")
					.font(.headline)
				Spacer()
				Button {
					dismiss()
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.keyboardShortcut(.escape, modifiers: [])
			}
			.padding()

			Divider()

			// Org selector (if multiple orgs)
			if store.userOrgs.count > 1 {
				Picker("Organization", selection: Binding(
					get: { selectedOrg ?? store.userOrgs.first?.slug ?? "" },
					set: { newValue in
						selectedOrg = newValue
						Task { await loadVaults(for: newValue) }
					}
				)) {
					ForEach(store.userOrgs) { org in
						Text(org.name).tag(org.slug)
					}
				}
				.pickerStyle(.segmented)
				.padding(.horizontal)
				.padding(.vertical, 8)

				Divider()
			}

			// Vault list
			if isLoading {
				VStack(spacing: 8) {
					ProgressView()
					Text("Loading org vaults...")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if orgVaults.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "building.2")
						.font(.system(size: 36))
						.foregroundStyle(.secondary)
					Text("No shared vaults")
						.font(.title3)
						.foregroundStyle(.secondary)
					Text("Share a vault with this org using\n`lpm env vars share --org \(selectedOrg ?? "org-slug")`\nor the Share button in the toolbar.")
						.font(.callout)
						.foregroundStyle(.tertiary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List {
					ForEach(orgVaults) { vault in
						vaultRow(vault)
					}
				}
			}

			if let result = pullResult {
				HStack {
					Image(systemName: result.contains("failed") ? "xmark.circle.fill" : "checkmark.circle.fill")
						.foregroundStyle(result.contains("failed") ? .red : .green)
					Text(result)
						.font(.callout)
				}
				.padding(.horizontal)
				.padding(.vertical, 8)
			}
		}
		.frame(width: 500, height: 400)
		.task {
			let org = store.userOrgs.first?.slug ?? ""
			selectedOrg = org
			await loadVaults(for: org)
		}
	}

	@ViewBuilder
	private func vaultRow(_ vault: SyncService.OrgVaultEntry) -> some View {
		let alreadyAdded = store.projects.contains { $0.id == vault.vaultId }

		HStack(spacing: 12) {
			Image(systemName: "lock.shield")
				.font(.title3)
				.foregroundStyle(.secondary)

			VStack(alignment: .leading, spacing: 2) {
				Text(vault.vaultId)
					.font(.system(.body, design: .monospaced))
					.lineLimit(1)

				HStack(spacing: 8) {
					if let version = vault.version {
						Text("v\(version)")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if let updated = vault.updatedAt {
						Text("updated \(formatTimeAgo(updated))")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}
			}

			Spacer()

			if alreadyAdded {
				Text("Added")
					.font(.caption)
					.foregroundStyle(.green)
			} else if isPulling == vault.vaultId {
				ProgressView()
					.controlSize(.small)
			} else {
				Button("Import") {
					Task { await importVault(vault) }
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
			}
		}
		.padding(.vertical, 4)
	}

	private func loadVaults(for orgSlug: String) async {
		guard !orgSlug.isEmpty else { return }
		isLoading = true
		let syncService = SyncService(baseURL: store.appEnvironment.baseURL)
		guard let authToken = store.readCLIAuthTokenPublic() else {
			isLoading = false
			return
		}
		orgVaults = await syncService.listOrgVaults(authToken: authToken, orgSlug: orgSlug)
		isLoading = false
	}

	private func importVault(_ vault: SyncService.OrgVaultEntry) async {
		guard let orgSlug = selectedOrg else { return }
		isPulling = vault.vaultId
		pullResult = nil

		// Create a project entry for this vault
		store.addProjectWithVaultId(
			vaultId: vault.vaultId,
			name: "org-vault-\(vault.vaultId.prefix(8))",
			path: "",
			environments: ["default": [:]]
		)

		// Wait for project to be added to store
		try? await Task.sleep(nanoseconds: 500_000_000)

		// Pull from org
		await store.pullFromOrg(orgSlug: orgSlug)

		isPulling = nil
		if store.lastSyncStatus?.contains("Pulled") == true {
			pullResult = "Imported successfully"
		} else {
			pullResult = store.error ?? "Import failed"
		}
	}

	private func formatTimeAgo(_ iso: String) -> String {
		let formatters: [ISO8601DateFormatter] = {
			let withFrac = ISO8601DateFormatter()
			withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			let plain = ISO8601DateFormatter()
			return [withFrac, plain]
		}()

		for fmt in formatters {
			if let date = fmt.date(from: iso) {
				let seconds = Int(-date.timeIntervalSinceNow)
				if seconds < 60 { return "just now" }
				let minutes = seconds / 60
				if minutes < 60 { return "\(minutes)m ago" }
				let hours = minutes / 60
				if hours < 24 { return "\(hours)h ago" }
				return "\(hours / 24)d ago"
			}
		}
		return iso
	}
}
