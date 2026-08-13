import SwiftUI

/// Column 3: Vault detail with vertical environment sidebar + secrets list.
struct VaultDetailView: View {
	@Bindable var store: VaultStore
	@State private var showingAddSecret = false
	@State private var showPushConfirmation = false
	@State private var showPullConfirmation = false
	@State private var showConflictResolution = false
	@State private var showVaultIDSheet = false
	@State private var localSearch = ""
	@State private var showSearch = false
	// Environment management
	@State private var showAddEnvironment = false
	@State private var newEnvName = ""
	@State private var newEnvSecrets: [String: String] = [:]
	@State private var currentEnvImportTask: Task<Void, Never>?
	@State private var currentEnvImportId: UUID?
	@State private var previewImportTask: Task<Void, Never>?
	@State private var previewImportId: UUID?
	@State private var newEnvCreationTask: Task<Void, Never>?
	@State private var newEnvCreationId: UUID?
	@State private var environmentToDelete: String?
	@State private var environmentToClear: String?
	@State private var showRenameEnvironment = false
	@State private var renameEnvTarget = ""
	@State private var renameEnvNewName = ""
	@State private var showDuplicateEnvironment = false
	@State private var duplicateEnvSource = ""
	@State private var duplicateEnvNewName = ""
	// Org share
	@State private var showOrgSharePicker = false
	@State private var showOrgPullPicker = false
	@FocusState private var isSearchFocused: Bool
	@FocusState private var isEnvNameFocused: Bool
	@FocusState private var isRenameFieldFocused: Bool
	@FocusState private var isDuplicateFieldFocused: Bool

	private var project: VaultProject? { store.selectedProject }

	private var currentSecrets: [VaultSecret] {
		guard let project else { return [] }
		return project.sortedSecrets(for: store.selectedEnvironment)
	}

	private var filteredSecrets: [VaultSecret] {
		guard !localSearch.isEmpty else { return currentSecrets }
		let query = localSearch.lowercased()
		return currentSecrets.filter {
			$0.key.lowercased().contains(query)
			// Do NOT search values — prevents shoulder surfing via search
		}
	}

	private var isOrg: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}

	var body: some View {
		Group {
			if let project {
				vaultContent(project)
			} else {
				emptyState
			}
		}
		.sheet(isPresented: $showingAddSecret) {
			if let project { AddSecretSheet(store: store, projectId: project.id) }
		}
		.sheet(isPresented: $showPushConfirmation) {
			if let project {
				SyncConfirmationSheet(
					action: isOrg ? .share : .push,
					projectName: project.name,
					keyCount: project.environments.values.reduce(0) { $0 + $1.count },
					onConfirm: { [store] in
						showPushConfirmation = false
						if case .org(let slug) = store.selectedAccount {
								Task { await store.pushToOrg(orgSlug: slug) }
							} else {
								Task { await store.pushToCloud() }
						}
					},
					onCancel: { showPushConfirmation = false }
				)
			}
		}
		.sheet(isPresented: $showPullConfirmation) {
			if let project {
				SyncConfirmationSheet(
					action: .pull,
					projectName: project.name,
					keyCount: project.environments.values.reduce(0) { $0 + $1.count },
					onConfirm: { [store] in
						showPullConfirmation = false
						if case .org(let slug) = store.selectedAccount {
								Task { await store.pullFromOrg(orgSlug: slug) }
							} else {
								Task { await store.pullFromCloud() }
						}
					},
					onCancel: { showPullConfirmation = false }
				)
			}
		}
		.sheet(isPresented: $showConflictResolution) {
			if let project {
				ConflictResolutionSheet(
					projectName: project.name,
					onPullAndMerge: { [store] in
						showConflictResolution = false
						Task { await store.pullFromCloud(); await store.pushToCloud() }
					},
					onForcePush: { [store] in
						showConflictResolution = false
						Task { await store.pushToCloud(force: true) }
					},
					onCancel: { showConflictResolution = false }
				)
			}
		}
		.sheet(isPresented: $showVaultIDSheet) {
			if let project { VaultIDSheet(vaultId: project.id) }
		}
		.onChange(of: store.lastSyncStatus) { _, newValue in
			if newValue == "conflict" { showConflictResolution = true }
		}
		.onReceive(NotificationCenter.default.publisher(for: .newSecret)) { _ in
			if project != nil { showingAddSecret = true }
		}
		.onReceive(NotificationCenter.default.publisher(for: .findSecrets)) { _ in
			guard project != nil else { return }
			showSearch = true
			isSearchFocused = true
		}
		.onChange(of: showAddEnvironment) { _, isPresented in
			if !isPresented { cancelNewEnvironmentWork() }
		}
		.onChange(of: store.selectedProjectId) { _, _ in
			currentEnvImportTask?.cancel()
			currentEnvImportTask = nil
			currentEnvImportId = nil
			cancelNewEnvironmentWork()
			showAddEnvironment = false
		}
		.onChange(of: store.isUnlocked) { _, isUnlocked in
			guard !isUnlocked else { return }
			cancelNewEnvironmentWork()
			newEnvSecrets = [:]
			showAddEnvironment = false
		}
		.onDisappear {
			currentEnvImportTask?.cancel()
			currentEnvImportTask = nil
			currentEnvImportId = nil
			cancelNewEnvironmentWork()
		}
	}

	// MARK: - Main Content

	@ViewBuilder
	private func vaultContent(_ project: VaultProject) -> some View {
		VStack(spacing: 0) {
			// Top bar: vault name + pull/push
			topBar(project)
			Divider()

			// Middle: env sidebar + secrets
			HStack(spacing: 0) {
				// Vertical env sidebar
				envSidebar(project)

				Divider()

				// Secrets area
				VStack(spacing: 0) {
					// Environment toolbar: Copy, Import, Export, Add, Search
					envToolbar(project)
					Divider()

					if showSearch {
						searchBar
						Divider()
					}

					// Secret list
					if currentSecrets.isEmpty && !showSearch {
						secretsEmptyState
					} else if filteredSecrets.isEmpty && showSearch {
						VStack {
							Text("No secrets matching \"\(localSearch)\"")
								.foregroundStyle(.secondary)
						}
						.frame(maxWidth: .infinity, maxHeight: .infinity)
					} else {
						List {
							ForEach(filteredSecrets) { secret in
								SecretRowView(
									secret: secret,
									isUnlocked: store.isUnlocked,
									onReveal: { Task { await store.unlock() } },
									onUpdate: { newValue in
										store.updateSecret(in: project.id, key: secret.key, newValue: newValue)
									},
									onDelete: {
										store.deleteSecret(from: project.id, key: secret.key)
									}
								)
							}
						}
						.id(store.selectedEnvironment)
					}
				}
			}

			Divider()
			footer(project)
		}
	}

	// MARK: - Top Bar

	private func topBar(_ project: VaultProject) -> some View {
		HStack(spacing: 8) {
			Text(project.name)
				.font(.title3)
				.fontWeight(.semibold)

			if store.isSyncing {
				ProgressView().controlSize(.small)
			}

			if let status = store.lastSyncStatus, !status.isEmpty, status != "conflict" {
				Text(status)
					.font(.caption)
					.foregroundStyle(status == "failed" ? .red : .secondary)
			}

			Spacer()

			if store.isLoggedIn {
				Button {
					showPullConfirmation = true
				} label: {
					Text("Pull")
						.font(.callout)
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(store.isSyncing)
				.keyboardShortcut("l", modifiers: [.command, .shift])

				Button {
					showPushConfirmation = true
				} label: {
					Text("Push")
						.font(.callout)
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(store.isSyncing)
				.keyboardShortcut("p", modifiers: [.command, .shift])
			}
		}
		.padding(.horizontal, 16)
		.frame(height: 40)
	}

	// MARK: - Vertical Environment Sidebar

	private func envSidebar(_ project: VaultProject) -> some View {
		let envNames = store.orderedEnvironmentNames(for: project)
		return VStack(spacing: 0) {
			// New .env button
			Button {
				newEnvName = ""
				newEnvSecrets = [:]
				showAddEnvironment = true
			} label: {
				HStack(spacing: 4) {
					Image(systemName: "plus")
						.font(.caption2)
					Text("New .env")
						.font(.caption)
				}
				.frame(maxWidth: .infinity)
				.contentShape(Rectangle())
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
			.padding(.horizontal, 8)
			.frame(height: 36)
			.popover(isPresented: $showAddEnvironment, arrowEdge: .trailing) {
				addEnvironmentPopover(project)
			}

			Divider()

			// Environment list
			ScrollView {
				VStack(spacing: 2) {
					ForEach(envNames, id: \.self) { env in
						Button {
							store.selectedEnvironment = env
						} label: {
							HStack {
								Text(VaultProject.displayName(for: env))
									.font(.system(.caption, design: .monospaced))
									.fontWeight(store.selectedEnvironment == env ? .semibold : .regular)
									.lineLimit(1)
								Spacer()
								Text("\(project.secretCount(for: env))")
									.font(.caption2)
									.foregroundStyle(.tertiary)
							}
							.padding(.horizontal, 10)
							.padding(.vertical, 6)
							.contentShape(Rectangle())
							.background(
								store.selectedEnvironment == env
									? Color.accentColor.opacity(0.15)
									: Color.clear,
								in: RoundedRectangle(cornerRadius: 6)
							)
						}
						.buttonStyle(.plain)
						.contextMenu {
							Button("Rename...") {
								renameEnvTarget = env
								renameEnvNewName = env
								showRenameEnvironment = true
							}
							Button("Duplicate...") {
								duplicateEnvSource = env
								duplicateEnvNewName = "\(env)-copy"
								showDuplicateEnvironment = true
							}
							Divider()
							let count = project.secretCount(for: env)
							Button("Clear All Secrets (\(count))") {
								environmentToClear = env
							}
							.disabled(count == 0)
							if project.environments.count > 1 {
								Button("Delete", role: .destructive) {
									environmentToDelete = env
								}
							}
						}
					}
				}
				.padding(.horizontal, 6)
				.padding(.vertical, 4)
			}
		}
		.frame(width: 120)
		.onAppear {
			if !envNames.contains(store.selectedEnvironment) {
				store.selectedEnvironment = envNames.first ?? "default"
			}
		}
		// Delete env confirmation
		.confirmationDialog("Delete environment?", isPresented: Binding(
			get: { environmentToDelete != nil },
			set: { if !$0 { environmentToDelete = nil } }
		), titleVisibility: .visible) {
			if let env = environmentToDelete {
				Button("Delete \"\(VaultProject.displayName(for: env))\"", role: .destructive) {
					store.deleteEnvironment(from: project.id, name: env)
					environmentToDelete = nil
				}
				Button("Cancel", role: .cancel) { environmentToDelete = nil }
			}
		}
		// Clear env confirmation
		.confirmationDialog("Clear all secrets?", isPresented: Binding(
			get: { environmentToClear != nil },
			set: { if !$0 { environmentToClear = nil } }
		), titleVisibility: .visible) {
			if let env = environmentToClear {
				Button("Clear All Secrets", role: .destructive) {
					store.clearEnvironment(in: project.id, name: env)
					environmentToClear = nil
				}
				Button("Cancel", role: .cancel) { environmentToClear = nil }
			}
		}
		// Rename popover
		.popover(isPresented: $showRenameEnvironment) {
			renamePopover(project)
		}
		// Duplicate popover
		.popover(isPresented: $showDuplicateEnvironment) {
			duplicatePopover(project)
		}
	}

	// MARK: - Environment Toolbar

	private func envToolbar(_ project: VaultProject) -> some View {
		HStack(spacing: 4) {
			Group {
				Button("Copy All") {
					Task {
						let success = await BiometricService().authenticate(
							reason: "Copy all secrets to clipboard"
						)
						guard success else { return }
						let envString = project.sortedSecrets(for: store.selectedEnvironment)
							.map { "\($0.key)=\($0.value)" }
							.joined(separator: "\n")
						ClipboardManager.shared.copy(envString, clearAfter: 15)
					}
				}
				Button(currentEnvImportTask == nil ? "Import" : "Importing…") {
					importIntoCurrentEnvironment(project)
				}
				.disabled(currentEnvImportTask != nil)
				Button("Export") { exportToFile() }
				Button("Add New") { showingAddSecret = true }
			}
			.buttonStyle(.bordered)
			.controlSize(.small)

			Spacer()

			Button {
				showSearch.toggle()
				if showSearch { isSearchFocused = true } else { localSearch = "" }
			} label: {
				Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
					.frame(height: 20)
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
			.help("Search (⌘F)")
		}
		.padding(.horizontal, 12)
		.frame(height: 36)
	}

	// MARK: - Search Bar

	private var searchBar: some View {
		HStack {
			Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
			TextField("Filter secrets...", text: $localSearch)
				.textFieldStyle(.plain)
				.focused($isSearchFocused)
				.onExitCommand { showSearch = false; localSearch = "" }
			if !localSearch.isEmpty {
				Button { localSearch = "" } label: {
					Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	// MARK: - Footer

	private func footer(_ project: VaultProject) -> some View {
		HStack {
			// Clickable env project ID
			Button {
				showVaultIDSheet = true
			} label: {
				Text(project.id)
					.font(.system(.caption, design: .monospaced))
					.foregroundStyle(.tertiary)
					.lineLimit(1)
			}
			.buttonStyle(.plain)
			.help("Click for env project configuration")

			Spacer()

			if let info = store.lastSyncInfo(for: project.id) {
				HStack(spacing: 4) {
					let verb = info.action == "push" ? "Pushed" : "Pulled"
					let vStr = info.version.map { "v\($0)" } ?? ""
					Text("\(verb) \(vStr) \(formatTimeAgo(info.date))")
						.font(.caption)
						.foregroundStyle(.secondary)

					switch store.syncStatus(for: project.id) {
					case .synced: Circle().fill(.green).frame(width: 6, height: 6)
					case .localChanges: Circle().fill(.orange).frame(width: 6, height: 6)
					case .neverSynced: EmptyView()
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}

	// MARK: - Empty States

	private var emptyState: some View {
		VStack(spacing: 12) {
			Image(systemName: "lock.shield")
				.font(.system(size: 48))
				.foregroundStyle(.secondary)
			Text("Select an env project")
				.font(.title2)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var secretsEmptyState: some View {
		VStack(spacing: 12) {
			Image(systemName: "key")
				.font(.system(size: 36))
				.foregroundStyle(.secondary)
			Text("No secrets yet")
				.font(.title3)
				.foregroundStyle(.secondary)
			Button("Add Secret") { showingAddSecret = true }
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: - File Operations

	private func exportToFile() {
		guard let project else { return }
		let panel = NSSavePanel()
		let envSuffix = store.selectedEnvironment == "default" ? "" : ".\(store.selectedEnvironment)"
		panel.nameFieldStringValue = ".env\(envSuffix)"
		panel.message = "Export \(store.selectedEnvironment) secrets to .env file"

		if panel.runModal() == .OK, let url = panel.url {
			let content = EnvFileCodec.format(
				project.secrets(for: store.selectedEnvironment)
			)
			do {
				try SecureFileWriter.write(Data(content.utf8), to: url)
			} catch {
				store.error = "Export failed. \(error.localizedDescription)"
			}
		}
	}

	private func importIntoCurrentEnvironment(_ project: VaultProject) {
		let environment = store.selectedEnvironment
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "Import secrets into \"\(VaultProject.displayName(for: environment))\""

		if panel.runModal() == .OK, let url = panel.url {
			let requestId = UUID()
			currentEnvImportTask?.cancel()
			currentEnvImportId = requestId
			currentEnvImportTask = Task { [store] in
				let result = await store.importEnvFile(
					at: url,
					to: project.id,
					environment: environment
				)
				guard currentEnvImportId == requestId else { return }
				currentEnvImportTask = nil
				currentEnvImportId = nil
				if case .failure(let error) = result, error != .cancelled {
					store.error = error.localizedDescription
				}
			}
		}
	}

	// MARK: - Environment Popovers

	private func addEnvironmentPopover(_ project: VaultProject) -> some View {
		let candidate = newEnvName.trimmingCharacters(in: .whitespaces)
		let isValid = EnvValidation.isValidEnvironmentName(candidate)
		return VStack(alignment: .leading, spacing: 12) {
			Text("Add Environment").font(.headline)
			TextField("Name (e.g. ci, staging)", text: $newEnvName)
				.textFieldStyle(.roundedBorder)
				.focused($isEnvNameFocused)
				.onSubmit { createEnv(for: project) }
			if !candidate.isEmpty && !isValid {
				Text("Use 1–64 ASCII letters, numbers, dots, dashes, or underscores. Do not use __index__ or '..'.")
					.font(.caption)
					.foregroundStyle(.red)
			}
			if !newEnvSecrets.isEmpty {
				HStack(spacing: 4) {
					Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
					Text("\(newEnvSecrets.count) secrets imported").font(.caption).foregroundStyle(.secondary)
				}
			}
			HStack {
				Button { importEnvFile(for: project) } label: {
					Label(
						previewImportTask == nil ? "Import .env file" : "Importing…",
						systemImage: "doc.badge.plus"
					).font(.callout)
				}
				.disabled(previewImportTask != nil || newEnvCreationTask != nil)
				Spacer()
				Button("Cancel") {
					cancelNewEnvironmentWork()
					showAddEnvironment = false
				}
				Button(newEnvCreationTask == nil ? "Create" : "Creating…") {
					createEnv(for: project)
				}
					.buttonStyle(.borderedProminent)
					.disabled(!isValid || project.environments[candidate] != nil
						|| previewImportTask != nil || newEnvCreationTask != nil)
			}
		}
		.padding()
		.frame(width: 300)
		.onAppear { isEnvNameFocused = true }
	}

	private func renamePopover(_ project: VaultProject) -> some View {
		let candidate = renameEnvNewName.trimmingCharacters(in: .whitespaces)
		let isValid = EnvValidation.isValidEnvironmentName(candidate)
		return VStack(alignment: .leading, spacing: 12) {
			Text("Rename Environment").font(.headline)
			TextField("New name", text: $renameEnvNewName)
				.textFieldStyle(.roundedBorder)
				.focused($isRenameFieldFocused)
				.onSubmit { performRename(for: project) }
			if !candidate.isEmpty && !isValid {
				Text("Use 1–64 ASCII letters, numbers, dots, dashes, or underscores. Do not use __index__ or '..'.")
					.font(.caption)
					.foregroundStyle(.red)
			}
			HStack {
				Spacer()
				Button("Cancel") { showRenameEnvironment = false }
				Button("Rename") { performRename(for: project) }
					.buttonStyle(.borderedProminent)
					.disabled(!isValid || candidate == renameEnvTarget
						|| project.environments[candidate] != nil)
			}
		}
		.padding()
		.frame(width: 280)
		.onAppear { isRenameFieldFocused = true }
	}

	private func duplicatePopover(_ project: VaultProject) -> some View {
		let candidate = duplicateEnvNewName.trimmingCharacters(in: .whitespaces)
		let isValid = EnvValidation.isValidEnvironmentName(candidate)
		return VStack(alignment: .leading, spacing: 12) {
			Text("Duplicate \"\(VaultProject.displayName(for: duplicateEnvSource))\"").font(.headline)
			TextField("New environment name", text: $duplicateEnvNewName)
				.textFieldStyle(.roundedBorder)
				.focused($isDuplicateFieldFocused)
				.onSubmit { performDuplicate(for: project) }
			if !candidate.isEmpty && !isValid {
				Text("Use 1–64 ASCII letters, numbers, dots, dashes, or underscores. Do not use __index__ or '..'.")
					.font(.caption)
					.foregroundStyle(.red)
			}
			HStack {
				Spacer()
				Button("Cancel") { showDuplicateEnvironment = false }
				Button("Duplicate") { performDuplicate(for: project) }
					.buttonStyle(.borderedProminent)
					.disabled(!isValid || project.environments[candidate] != nil)
			}
		}
		.padding()
		.frame(width: 280)
		.onAppear { isDuplicateFieldFocused = true }
	}

	private func createEnv(for project: VaultProject) {
		let name = newEnvName.trimmingCharacters(in: .whitespaces)
		guard EnvValidation.isValidEnvironmentName(name), project.environments[name] == nil else { return }
		let secrets = newEnvSecrets
		let requestId = UUID()
		newEnvCreationTask?.cancel()
		newEnvCreationId = requestId
		newEnvCreationTask = Task { [store] in
			let added = await store.addEnvironment(to: project.id, name: name, secrets: secrets)
			guard newEnvCreationId == requestId else { return }
			newEnvCreationTask = nil
			newEnvCreationId = nil
			guard added, store.isUnlocked, store.selectedProjectId == project.id else { return }
			cancelPreviewImport()
			showAddEnvironment = false
		}
	}

	private func performRename(for project: VaultProject) {
		let newName = renameEnvNewName.trimmingCharacters(in: .whitespaces)
		guard EnvValidation.isValidEnvironmentName(newName), newName != renameEnvTarget,
			project.environments[newName] == nil else { return }
		store.renameEnvironment(in: project.id, from: renameEnvTarget, to: newName)
		showRenameEnvironment = false
	}

	private func performDuplicate(for project: VaultProject) {
		let newName = duplicateEnvNewName.trimmingCharacters(in: .whitespaces)
		guard EnvValidation.isValidEnvironmentName(newName), project.environments[newName] == nil else { return }
		store.duplicateEnvironment(in: project.id, from: duplicateEnvSource, to: newName)
		showDuplicateEnvironment = false
	}

	private func importEnvFile(for project: VaultProject) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "Select an .env file to import"

		if panel.runModal() == .OK, let url = panel.url {
			let fileName = url.lastPathComponent
			if newEnvName.trimmingCharacters(in: .whitespaces).isEmpty {
				if fileName == ".env" { newEnvName = "default" }
				else if fileName.hasPrefix(".env.") { newEnvName = String(fileName.dropFirst(".env.".count)) }
				else { newEnvName = fileName }
			}
			let requestId = UUID()
			previewImportTask?.cancel()
			newEnvSecrets = [:]
			previewImportId = requestId
			previewImportTask = Task { [store] in
				let result = await store.loadEnvFilePreview(at: url, for: project.id)
				guard previewImportId == requestId, showAddEnvironment,
					store.selectedProjectId == project.id,
					store.projects.contains(where: { $0.id == project.id })
				else { return }
				previewImportTask = nil
				previewImportId = nil
				newEnvSecrets = EnvFilePreviewPresentation.replacementSecrets(for: result)
				switch result {
				case .success:
					break
				case .failure(let error) where error != .cancelled:
					store.error = error.localizedDescription
				case .failure:
					break
				}
			}
		}
	}

	private func cancelPreviewImport() {
		previewImportTask?.cancel()
		previewImportTask = nil
		previewImportId = nil
	}

	private func cancelNewEnvironmentWork() {
		newEnvCreationTask?.cancel()
		newEnvCreationTask = nil
		newEnvCreationId = nil
		cancelPreviewImport()
		newEnvSecrets = [:]
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

enum EnvFilePreviewPresentation {
	static func replacementSecrets(
		for result: Result<ImportedEnvFile, EnvFileImportError>
	) -> [String: String] {
		guard case .success(let imported) = result else { return [:] }
		return imported.secrets
	}
}
