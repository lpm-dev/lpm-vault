import SwiftUI

struct OrgVaultSheetLoadIdentity: Hashable {
	let authGeneration: Int
	let fixedOrgSlug: String?
	let selectedOrg: String?
	let reloadID: Int

	init(
		authGeneration: Int,
		fixedOrgSlug: String?,
		selectedOrg: String?,
		reloadID: Int
	) {
		self.authGeneration = authGeneration
		self.fixedOrgSlug = fixedOrgSlug
		self.selectedOrg = fixedOrgSlug == nil ? selectedOrg : nil
		self.reloadID = reloadID
	}

	var effectiveOrgSlug: String? { fixedOrgSlug ?? selectedOrg }
}

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
	@State private var importID: UUID?
	@State private var importResult: ImportResult?
	@State private var loadError: String?
	@State private var reloadID = 0
	@State private var pendingMove: ExistingProjectMove?

	private struct ExistingProjectMove: Identifiable {
		let id = UUID()
		let project: SyncService.RemoteProject
		let identity: OrgVaultSheetLoadIdentity
	}

	private var loadIdentity: OrgVaultSheetLoadIdentity {
		OrgVaultSheetLoadIdentity(
			authGeneration: store.authContextGeneration,
			fixedOrgSlug: fixedOrgSlug,
			selectedOrg: selectedOrg,
			reloadID: reloadID
		)
	}

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
					cancelImport()
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
		.task(id: loadIdentity) {
			cancelImport()
			pendingMove = nil
			importResult = nil
			let org = loadIdentity.effectiveOrgSlug ?? store.userOrgs.first?.slug ?? ""
			if fixedOrgSlug != nil || selectedOrg == nil { selectedOrg = org }
			await loadVaults(for: org)
		}
		.onDisappear { cancelImport() }
		.sheet(item: $pendingMove) { move in
			OrgProjectMoveConfirmation(
				projectName: move.project.name ?? move.project.vaultId,
				onConfirm: {
					pendingMove = nil
					guard loadIdentity == move.identity else { return }
					startImport(move.project)
				},
				onCancel: { pendingMove = nil }
			)
		}
	}

	@ViewBuilder
	private func vaultRow(_ vault: SyncService.RemoteProject) -> some View {
		let existsLocally = store.projects.contains { $0.id == vault.vaultId }
		let alreadyAdded = existsLocally
			&& store.vaultOrgAssociations[vault.vaultId] == loadIdentity.effectiveOrgSlug

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
				Button(existsLocally ? "Move here" : "Import") {
					if existsLocally {
						pendingMove = ExistingProjectMove(project: vault, identity: loadIdentity)
					} else {
						startImport(vault)
					}
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
		orgVaults = []
		isLoading = true
		loadError = nil
		let result = await store.listOrganizationCloudProjects(orgSlug: orgSlug)
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

	private func startImport(_ vault: SyncService.RemoteProject) {
		guard VaultTaskOwnership.canStart(current: importID),
			importTask == nil,
			let orgSlug = loadIdentity.effectiveOrgSlug
		else { return }
		let requestID = UUID()
		isPulling = vault.vaultId
		importResult = nil
		importID = requestID
		importTask = Task {
			await importVault(vault, orgSlug: orgSlug, requestID: requestID)
		}
	}

	private func importVault(
		_ vault: SyncService.RemoteProject,
		orgSlug: String,
		requestID: UUID
	) async {
		let result = await store.importOrganizationProject(vault, orgSlug: orgSlug)
		guard !Task.isCancelled,
			VaultTaskOwnership.owns(current: importID, request: requestID)
		else { return }
		isPulling = nil
		importTask = nil
		importID = nil
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

	private func cancelImport() {
		importTask?.cancel()
		importTask = nil
		importID = nil
		isPulling = nil
	}

	private func formatTimeAgo(_ iso: String) -> String {
		RelativeTimestampFormatter.string(fromRFC3339: iso)
	}
}

struct OrgProjectMoveConfirmation: View {
	let projectName: String
	let onConfirm: () -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Move and merge \(projectName)?").font(.headline)
			Text("This local project will move to this organization in the sidebar.")
			Text("Cloud values replace conflicting local values. Local-only keys and previous sync history remain. Nothing is uploaded.")
			HStack {
				Spacer()
				Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
				Button("Move and merge", action: onConfirm).buttonStyle(.borderedProminent)
			}
		}
		.padding(24)
		.frame(width: 440)
	}
}
