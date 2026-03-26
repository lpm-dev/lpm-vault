import SwiftUI

struct AddProjectSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var path = ""
	@State private var detectedEnvFiles: [EnvFileInfo] = []
	@State private var existingVaultId: String?
	@State private var cloudVaultAvailable = false
	@State private var cloudVaultOrg: String?  // org slug if found via org
	@State private var checkingCloud = false
	@FocusState private var focusedField: Field?

	private enum Field {
		case name
	}

	struct EnvFileInfo: Identifiable {
		let id = UUID()
		let fileName: String
		let fullPath: String
		var selected: Bool = true
	}

	private var canCreate: Bool {
		!name.isEmpty && !path.isEmpty
	}

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Add Project")
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

			// Form
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 6) {
					Text("Project Name")
						.font(.subheadline)
						.fontWeight(.medium)
					TextField("e.g. my-api-server", text: $name)
						.textFieldStyle(.roundedBorder)
						.focused($focusedField, equals: .name)
				}

				VStack(alignment: .leading, spacing: 6) {
					Text("Project Path")
						.font(.subheadline)
						.fontWeight(.medium)
					HStack {
						TextField("Select a folder...", text: $path)
							.textFieldStyle(.roundedBorder)
							.disabled(true)
						Button("Browse...") {
							selectFolder()
						}
					}
				}

				// Cloud vault detected
				if cloudVaultAvailable, let vaultId = existingVaultId {
					HStack(spacing: 8) {
						Image(systemName: cloudVaultOrg != nil ? "building.2.fill" : "cloud.fill")
							.foregroundStyle(.blue)
						VStack(alignment: .leading, spacing: 2) {
							if let org = cloudVaultOrg {
								Text("Org vault found (\(org))")
									.font(.subheadline)
									.fontWeight(.medium)
							} else {
								Text("Cloud vault found")
									.font(.subheadline)
									.fontWeight(.medium)
							}
							Text("Vault ID: \(vaultId)")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						Text(cloudVaultOrg != nil ? "Pull from org after create" : "Will pull on create")
							.font(.caption)
							.foregroundStyle(.blue)
					}
					.padding(10)
					.background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
				}

				if checkingCloud {
					HStack {
						ProgressView().controlSize(.small)
						Text("Checking cloud...")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				// Detected .env files
				if !detectedEnvFiles.isEmpty {
					VStack(alignment: .leading, spacing: 8) {
						Text("Environment Files Found")
							.font(.subheadline)
							.fontWeight(.medium)

						ForEach($detectedEnvFiles) { $file in
							HStack {
								Image(systemName: file.selected ? "checkmark.circle.fill" : "circle")
									.foregroundStyle(file.selected ? .green : .secondary)
									.onTapGesture { file.selected.toggle() }
								Text(file.fileName)
									.font(.system(.body, design: .monospaced))
								Spacer()
								Text("Import")
									.font(.caption)
									.foregroundStyle(file.selected ? .primary : .tertiary)
							}
						}

						Text("Selected files will be imported into the vault")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}
			}
			.padding()

			Divider()

			// Actions
			HStack {
				Spacer()
				Button("Cancel") {
					dismiss()
				}

				Button(detectedEnvFiles.contains(where: { $0.selected }) ? "Create & Import" : "Create") {
					createProject()
				}
				.buttonStyle(.borderedProminent)
				.disabled(!canCreate)
				.keyboardShortcut(.return, modifiers: .command)
			}
			.padding()
		}
		.frame(width: 460)
		.onAppear {
			focusedField = .name
		}
	}

	private func selectFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.message = "Select the project directory"

		if panel.runModal() == .OK, let url = panel.url {
			path = url.path(percentEncoded: false)
			if name.isEmpty {
				name = url.lastPathComponent
			}
			detectEnvFiles(at: url)
			detectExistingVault(at: url)
		}
	}

	/// Check if lpm.json exists and has a vault ID. If so, check cloud for data.
	private func detectExistingVault(at url: URL) {
		let lpmJsonPath = url.appendingPathComponent("lpm.json")
		guard FileManager.default.fileExists(atPath: lpmJsonPath.path) else { return }

		guard let data = try? Data(contentsOf: lpmJsonPath),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let vaultId = json["vault"] as? String else { return }

		existingVaultId = vaultId

		// Also read project name from package.json if we haven't set one
		if name.isEmpty || name == url.lastPathComponent {
			let pkgJsonPath = url.appendingPathComponent("package.json")
			if let pkgData = try? Data(contentsOf: pkgJsonPath),
			   let pkg = try? JSONSerialization.jsonObject(with: pkgData) as? [String: Any],
			   let pkgName = pkg["name"] as? String {
				name = pkgName
			}
		}

		// Check cloud for this vault — personal first, then org vaults
		checkingCloud = true
		Task.detached { [store] in
			let syncService = SyncService(baseURL: store.appEnvironment.baseURL)
			guard let authToken = store.readCLIAuthTokenPublic() else {
				await MainActor.run { [self] in checkingCloud = false }
				return
			}

			// 1. Check personal vault
			let personalResult = await syncService.pull(authToken: authToken, vaultId: vaultId)
			if personalResult?.encryptedBlob != nil {
				await MainActor.run { [self] in
					checkingCloud = false
					cloudVaultAvailable = true
					cloudVaultOrg = nil
				}
				return
			}

			// 2. Check org vaults
			for org in store.userOrgs {
				let orgResult = await syncService.pullOrg(
					authToken: authToken, orgSlug: org.slug, vaultId: vaultId
				)
				if orgResult?.encryptedBlob != nil {
					await MainActor.run { [self] in
						checkingCloud = false
						cloudVaultAvailable = true
						cloudVaultOrg = org.slug
					}
					return
				}
			}

			await MainActor.run { [self] in checkingCloud = false }
		}
	}

	private func detectEnvFiles(at url: URL) {
		let fm = FileManager.default
		guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }

		detectedEnvFiles = contents
			.filter { $0.hasPrefix(".env") && !$0.hasSuffix(".example") }
			.sorted()
			.map { fileName in
				EnvFileInfo(
					fileName: fileName,
					fullPath: url.appendingPathComponent(fileName).path
				)
			}
	}

	/// Extract environment name from filename: ".env.local" → "local", ".env" → "default"
	private func envNameFromFileName(_ fileName: String) -> String {
		if fileName == ".env" { return "default" }
		let prefix = ".env."
		if fileName.hasPrefix(prefix) {
			return String(fileName.dropFirst(prefix.count))
		}
		return "default"
	}

	private func createProject() {
		// Build environments from selected .env files
		let selectedFiles = detectedEnvFiles.filter { $0.selected }
		var environments: [String: [String: String]] = [:]

		if !selectedFiles.isEmpty {
			for file in selectedFiles {
				if let content = try? String(contentsOfFile: file.fullPath, encoding: .utf8) {
					let pairs = parseEnvContent(content)
					let envName = envNameFromFileName(file.fileName)
					var envSecrets: [String: String] = [:]
					for (key, value) in pairs {
						envSecrets[key] = value
					}
					environments[envName] = envSecrets
				}
			}
		}

		// Only create empty "default" if no .env files were imported at all
		// (i.e., the user is adding a blank project)
		if environments.isEmpty {
			environments["default"] = [:]
		}
		// Remove empty environments (don't keep "default" if user imported .env.live and .env.dev)
		environments = environments.filter { !$0.value.isEmpty || environments.count == 1 }

		// If existing vault ID found, use it instead of generating new one
		if let vaultId = existingVaultId {
			// Only auto-pull for personal vaults (org vaults need the org pull button)
			let shouldAutoPull = cloudVaultAvailable && cloudVaultOrg == nil
			store.addProjectWithVaultId(
				vaultId: vaultId,
				name: name,
				path: path,
				environments: environments,
				pullAfterAdd: shouldAutoPull
			)

			// For org vaults, auto-pull from the detected org
			if cloudVaultAvailable, let orgSlug = cloudVaultOrg {
				Task.detached { [store] in
					// Wait a moment for the project to be added to the store
					try? await Task.sleep(nanoseconds: 500_000_000)
					await store.pullFromOrg(orgSlug: orgSlug)
				}
			}
		} else {
			store.addProject(name: name, path: path, environments: environments)
		}

		// Select the first environment tab
		if let firstEnv = environments.keys.sorted().first {
			store.selectedEnvironment = firstEnv
		}

		dismiss()
	}

	/// Simple .env parser (matches the Rust CLI parser behavior)
	private func parseEnvContent(_ content: String) -> [(String, String)] {
		var result: [(String, String)] = []
		for line in content.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

			let line = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
			guard let eqIndex = line.firstIndex(of: "=") else { continue }

			let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
			var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

			// Remove surrounding quotes
			if (value.hasPrefix("\"") && value.hasSuffix("\""))
				|| (value.hasPrefix("'") && value.hasSuffix("'"))
			{
				value = String(value.dropFirst().dropLast())
			}

			if !key.isEmpty {
				result.append((key, value))
			}
		}
		return result
	}
}
