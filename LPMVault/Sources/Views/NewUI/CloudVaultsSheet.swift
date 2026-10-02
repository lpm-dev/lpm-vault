import SwiftUI

/// Sheet that lists personal cloud vaults for discovery and import.
struct CloudVaultsSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var vaults: [CloudVaultEntry] = []
	@State private var isLoading = false
	@State private var isPulling: String?
	@State private var importTask: Task<Void, Never>?
	@State private var importID: UUID?
	@State private var importResult: ImportResult?
	@State private var loadError: String?
	@State private var loadErrorRequiresSignIn = false
	@State private var reloadID = 0

	typealias CloudVaultEntry = SyncService.RemoteProject

	private enum ImportResult {
		case success(projectId: String, message: String)
		case failure(projectId: String, message: String)

		var message: String {
			switch self {
			case .success(_, let message), .failure(_, let message): message
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
				Text("Cloud Env Projects")
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

			if isLoading {
				VStack(spacing: 8) {
					ProgressView()
					Text("Loading cloud env projects...")
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
					if loadErrorRequiresSignIn {
						Button(store.isLoggingIn ? "Waiting for browser…" : "Sign in again") {
							Task {
								if await store.login() { reloadID &+= 1 }
							}
						}
						.disabled(store.isLoggingIn)
					}
				}
			} else if vaults.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "cloud")
						.font(.system(size: 36))
						.foregroundStyle(.secondary)
					Text("No cloud env projects")
						.font(.title3)
						.foregroundStyle(.secondary)
					Text("Push a project with `lpm env push`\nor the Push button in the toolbar.")
						.font(.callout)
						.foregroundStyle(.tertiary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List {
					ForEach(vaults) { vault in
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
		.task(id: "\(store.authContextGeneration):\(reloadID)") {
			cancelImport()
			await loadVaults()
		}
		.onDisappear { cancelImport() }
	}

	@ViewBuilder
	private func vaultRow(_ vault: CloudVaultEntry) -> some View {
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
					startImport(vault)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
				.disabled(isPulling != nil)
			}
		}
		.padding(.vertical, 4)
	}

	private func loadVaults() async {
		vaults = []
		isLoading = true
		loadError = nil
		loadErrorRequiresSignIn = false
		let result = await store.listPersonalCloudProjects()
		switch result {
		case .success(let projects):
			guard !Task.isCancelled else { return }
			vaults = projects
			isLoading = false
		case .failure(.cancelled):
			return
		case .failure(let error):
			guard !Task.isCancelled else { return }
			isLoading = false
			loadErrorRequiresSignIn = error.requiresSignIn
			loadError = error.localizedDescription
		}
	}

	private func startImport(_ vault: CloudVaultEntry) {
		guard VaultTaskOwnership.canStart(current: importID), importTask == nil else { return }
		let requestID = UUID()
		isPulling = vault.vaultId
		importResult = nil
		importID = requestID
		importTask = Task { await importVault(vault, requestID: requestID) }
	}

	private func importVault(_ vault: CloudVaultEntry, requestID: UUID) async {
		let result = await store.importCloudProject(vault)
		guard !Task.isCancelled,
			VaultTaskOwnership.owns(current: importID, request: requestID)
		else { return }
		isPulling = nil
		importTask = nil
		importID = nil
		switch result {
		case .success(let imported):
			importResult = .success(
				projectId: imported.projectId,
				message: "Imported v\(imported.version) with \(imported.keyCount) keys."
			)
		case .failure(.cancelled):
			break
		case .failure(let error):
			importResult = .failure(
				projectId: vault.vaultId,
				message: error.localizedDescription
			)
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
