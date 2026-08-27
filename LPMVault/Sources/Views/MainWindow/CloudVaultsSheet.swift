import SwiftUI

/// Sheet that lists personal cloud vaults for discovery and import.
struct CloudVaultsSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var vaults: [CloudVaultEntry] = []
	@State private var isLoading = false
	@State private var isPulling: String?
	@State private var importTask: Task<Void, Never>?
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
		.task(id: reloadID) { await loadVaults() }
		.onDisappear { importTask?.cancel() }
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
					importTask = Task { await importVault(vault) }
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
				.disabled(isPulling != nil)
			}
		}
		.padding(.vertical, 4)
	}

	private func loadVaults() async {
		isLoading = true
		loadError = nil
		loadErrorRequiresSignIn = false
		guard let authToken = await store.currentAuthToken() else {
			guard !Task.isCancelled else { return }
			isLoading = false
			loadError = "Sign in to lpm.dev, then retry."
			return
		}

		let syncService = SyncService(baseURL: store.appEnvironment.baseURL)
		let result = await syncService.listPersonalProjects(authToken: authToken)
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

	private func importVault(_ vault: CloudVaultEntry) async {
		isPulling = vault.vaultId
		importResult = nil
		let result = await store.importCloudProject(vault)
		guard !Task.isCancelled else { return }
		isPulling = nil
		importTask = nil
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
