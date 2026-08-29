import SwiftUI

/// Sheet that lists shared org vaults for discovery and import.
/// Allows users to pull org vaults without needing lpm.json.
struct OrgVaultsSheet: View {
	@Bindable var store: VaultStore
	var fixedOrgSlug: String? = nil  // When set, skip org selector
	@Environment(\.dismiss) private var dismiss
	@State private var selectedOrg: String?
	@State private var orgVaults: [SyncService.RemoteProject] = []
	@State private var isLoading = false
	@State private var isPulling: String?  // vault ID being pulled
	@State private var importTask: Task<Void, Never>?
	@State private var importResult: ImportResult?
	@State private var loadError: String?
	@State private var reloadID = 0

	private enum ImportResult {
		case success(String)
		case failure(String)

		var message: String {
			switch self {
			case .success(let message), .failure(let message): message
			}
		}

		var succeeded: Bool {
			if case .success = self { return true }
			return false
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Organization Env Projects")
					.font(.headline)
				Spacer()
				Button {
					importTask?.cancel()
					dismiss()
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.keyboardShortcut(.escape, modifiers: [])
				.accessibilityLabel("Close")
			}
			.padding()

			Divider()

			// Org selector (only if no fixed org and multiple orgs)
			if fixedOrgSlug == nil && store.userOrgs.count > 1 {
				Picker("Organization", selection: Binding(
					get: { selectedOrg ?? store.userOrgs.first?.slug ?? "" },
					set: { newValue in
						selectedOrg = newValue
					}
				)) {
					ForEach(store.userOrgs) { org in
						Text(org.name).tag(org.slug)
					}
				}
				.pickerStyle(.segmented)
				.disabled(isPulling != nil)
				.padding(.horizontal)
				.padding(.vertical, 8)

				Divider()
			}

			// Vault list
			if isLoading {
				VStack(spacing: 8) {
					ProgressView()
					Text("Loading organization env projects...")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if let loadError {
				ContentUnavailableView {
					Label("Could Not Load Env Projects", systemImage: "exclamationmark.triangle")
				} description: {
					Text(loadError)
				} actions: {
					Button("Retry") { reloadID &+= 1 }
				}
			} else if orgVaults.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "building.2")
						.font(.system(size: 36))
						.foregroundStyle(.secondary)
					Text("No shared env projects")
						.font(.title3)
						.foregroundStyle(.secondary)
					Text("Share a project with this organization using\n`lpm env share --org \(selectedOrg ?? "org-slug")`\nor the Share button in the toolbar.")
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

			if let result = importResult {
				HStack {
					Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
						.foregroundStyle(result.succeeded ? .green : .red)
					Text(result.message)
						.font(.callout)
				}
				.accessibilityElement(children: .combine)
				.accessibilityLabel(result.succeeded ? "Import succeeded" : "Import failed")
				.accessibilityValue(result.message)
				.padding(.horizontal)
				.padding(.vertical, 8)
			}
		}
		.frame(minWidth: 500, minHeight: 400)
		.task(id: "\(selectedOrg ?? ""):\(reloadID)") {
			let org = fixedOrgSlug ?? selectedOrg ?? store.userOrgs.first?.slug ?? ""
			if selectedOrg == nil { selectedOrg = org }
			await loadVaults(for: org)
		}
		.onDisappear { importTask?.cancel() }
	}

	@ViewBuilder
	private func vaultRow(_ vault: SyncService.RemoteProject) -> some View {
		let alreadyAdded = store.projects.contains { $0.id == vault.vaultId }

		HStack(spacing: 12) {
			Image(systemName: "lock.shield")
				.font(.title3)
				.foregroundStyle(.secondary)

			VStack(alignment: .leading, spacing: 2) {
				Text(vault.name ?? vault.vaultId)
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
				ProgressView("Importing")
					.controlSize(.small)
			} else {
				Button("Import") {
					importTask = Task { await importVault(vault) }
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
				.disabled(isPulling != nil)
			}
		}
		.padding(.vertical, 4)
	}

	private func loadVaults(for orgSlug: String) async {
		guard !orgSlug.isEmpty else { return }
		isLoading = true
		loadError = nil
		let syncService = SyncService.shared(baseURL: store.appEnvironment.baseURL)
		guard let authToken = await store.currentAuthToken() else {
			guard !Task.isCancelled else { return }
			isLoading = false
			loadError = "Sign in to lpm.dev, then retry."
			return
		}
		let result = await syncService.listOrgProjects(authToken: authToken, orgSlug: orgSlug)
		switch result {
		case .success(let projects):
			guard !Task.isCancelled else { return }
			orgVaults = projects
			isLoading = false
		case .failure(.cancelled):
			return
		case .failure(let error):
			guard !Task.isCancelled else { return }
			isLoading = false
			loadError = error.localizedDescription
		}
	}

	private func importVault(_ vault: SyncService.RemoteProject) async {
		guard let orgSlug = selectedOrg else { return }
		isPulling = vault.vaultId
		importResult = nil
		let result = await store.importOrganizationProject(vault, orgSlug: orgSlug)
		guard !Task.isCancelled else { return }
		isPulling = nil
		importTask = nil
		switch result {
		case .success(let imported):
			importResult = .success(
				"Imported v\(imported.version) with \(imported.keyCount) keys."
			)
		case .failure(.cancelled):
			break
		case .failure(let error):
			importResult = .failure(error.localizedDescription)
		}
	}

	private func formatTimeAgo(_ iso: String) -> String {
		RelativeTimestampFormatter.string(fromRFC3339: iso)
	}
}
