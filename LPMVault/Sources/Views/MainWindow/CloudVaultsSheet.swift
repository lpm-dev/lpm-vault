import SwiftUI

/// Sheet that lists personal cloud vaults for discovery and import.
struct CloudVaultsSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var vaults: [CloudVaultEntry] = []
	@State private var isLoading = false
	@State private var isPulling: String?
	@State private var pullResult: String?
	@State private var loadError: String?

	typealias CloudVaultEntry = SyncService.RemoteProject

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Cloud Env Projects")
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
					Button("Retry") { Task { await loadVaults() } }
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
		.task { await loadVaults() }
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

	private func loadVaults() async {
		isLoading = true
		loadError = nil
		guard let authToken = await store.currentAuthToken() else {
			isLoading = false
			loadError = "Sign in to lpm.dev, then retry."
			return
		}

		let syncService = SyncService(baseURL: store.appEnvironment.baseURL)
		guard let projects = await syncService.listPersonalProjects(authToken: authToken) else {
			isLoading = false
			loadError = "The server request failed. Check your connection and try again."
			return
		}
		vaults = projects
		isLoading = false
	}

	private func importVault(_ vault: CloudVaultEntry) async {
		isPulling = vault.vaultId
		pullResult = nil

		guard await store.addProjectWithVaultId(
			vaultId: vault.vaultId,
			name: vault.name ?? "env-\(vault.vaultId.prefix(8))",
			path: "",
			environments: ["default": [:]]
		) else {
			isPulling = nil
			pullResult = store.error ?? "Import failed"
			return
		}

		await store.pullFromCloud()

		isPulling = nil
		if store.lastSyncStatus?.contains("Pulled") == true {
			pullResult = "Imported successfully"
		} else {
			if let placeholder = store.projects.first(where: { $0.id == vault.vaultId }) {
				_ = await store.deleteLocalVault(placeholder)
			}
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
