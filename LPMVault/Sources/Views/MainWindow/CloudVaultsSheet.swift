import SwiftUI

/// Sheet that lists personal cloud vaults for discovery and import.
struct CloudVaultsSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var vaults: [CloudVaultEntry] = []
	@State private var isLoading = false
	@State private var isPulling: String?
	@State private var pullResult: String?

	struct CloudVaultEntry: Identifiable, Decodable {
		let vaultId: String
		let version: Int?
		let updatedAt: String?

		var id: String { vaultId }
	}

	private struct ListResponse: Decodable {
		let vaults: [CloudVaultEntry]
	}

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Cloud Vaults")
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
					Text("Loading cloud vaults...")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if vaults.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "cloud")
						.font(.system(size: 36))
						.foregroundStyle(.secondary)
					Text("No cloud vaults")
						.font(.title3)
						.foregroundStyle(.secondary)
					Text("Push a vault with `lpm env vars push`\nor the Push button in the toolbar.")
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

	private func loadVaults() async {
		isLoading = true
		guard let authToken = store.readCLIAuthTokenPublic() else {
			isLoading = false
			return
		}

		let syncService = SyncService(baseURL: store.appEnvironment.baseURL)
		guard let url = URL(string: "/api/vaults", relativeTo: store.appEnvironment.baseURL) else {
			isLoading = false
			return
		}

		var request = URLRequest(url: url)
		request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

		do {
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
				isLoading = false
				return
			}
			let result = try JSONDecoder().decode(ListResponse.self, from: data)
			vaults = result.vaults
		} catch {
			// silent fail
		}
		isLoading = false
	}

	private func importVault(_ vault: CloudVaultEntry) async {
		isPulling = vault.vaultId
		pullResult = nil

		store.addProjectWithVaultId(
			vaultId: vault.vaultId,
			name: "vault-\(vault.vaultId.prefix(8))",
			path: "",
			environments: ["default": [:]],
			pullAfterAdd: true
		)

		// Wait for pull to complete
		try? await Task.sleep(nanoseconds: 2_000_000_000)

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
