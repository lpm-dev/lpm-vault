import SwiftUI

struct SecretListView: View {
	@Bindable var store: VaultStore
	@State private var showingAddSecret = false
	@State private var showDeleteProjectConfirmation = false
	@State private var showPushConfirmation = false
	@State private var showPullConfirmation = false
	@State private var showConflictResolution = false
	@State private var localSearch = ""
	@State private var showSearch = false
	@State private var showAddEnvironment = false
	@State private var newEnvName = ""
	@State private var newEnvSecrets: [String: String] = [:]
	@State private var environmentToDelete: String?
	@State private var environmentToClear: String?
	@State private var showRenameEnvironment = false
	@State private var renameEnvTarget = ""
	@State private var renameEnvNewName = ""
	@State private var showDuplicateEnvironment = false
	@State private var duplicateEnvSource = ""
	@State private var duplicateEnvNewName = ""
	@State private var draggedEnv: String?
	@State private var showOrgSharePicker = false
	@State private var showOrgPullPicker = false
	@FocusState private var isSearchFocused: Bool
	@FocusState private var isEnvNameFocused: Bool
	@FocusState private var isRenameFieldFocused: Bool
	@FocusState private var isDuplicateFieldFocused: Bool

	private var project: VaultProject? {
		store.selectedProject
	}

	private var currentSecrets: [VaultSecret] {
		guard let project else { return [] }
		return project.sortedSecrets(for: store.selectedEnvironment)
	}

	private var filteredSecrets: [VaultSecret] {
		guard !localSearch.isEmpty else { return currentSecrets }
		let query = localSearch.lowercased()
		return currentSecrets.filter {
			$0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
		}
	}

	var body: some View {
		Group {
			if let project {
				secretList(project)
			} else {
				Text("No project selected")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.sheet(isPresented: $showingAddSecret) {
			if let project {
				AddSecretSheet(store: store, projectId: project.id)
			}
		}
		.sheet(isPresented: $showPushConfirmation) {
			if let project {
				SyncConfirmationSheet(
					action: "push",
					projectName: project.name,
					keyCount: project.environments.values.reduce(0) { $0 + $1.count },
					onConfirm: { [store] in
						showPushConfirmation = false
						Task.detached { await store.pushToCloud() }
					},
					onCancel: { showPushConfirmation = false }
				)
			}
		}
		.sheet(isPresented: $showPullConfirmation) {
			if let project {
				SyncConfirmationSheet(
					action: "pull",
					projectName: project.name,
					keyCount: project.environments.values.reduce(0) { $0 + $1.count },
					onConfirm: { [store] in
						showPullConfirmation = false
						Task.detached { await store.pullFromCloud() }
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
						Task.detached {
							await store.pullFromCloud()
							await store.pushToCloud()
						}
					},
					onForcePush: { [store] in
						showConflictResolution = false
						Task.detached { await store.pushToCloud(force: true) }
					},
					onCancel: { showConflictResolution = false }
				)
			}
		}
		.onChange(of: store.lastSyncStatus) { _, newValue in
			if newValue == "conflict" {
				showConflictResolution = true
			}
		}
	}

	@ViewBuilder
	private func secretList(_ project: VaultProject) -> some View {
		VStack(spacing: 0) {
			// Custom header bar
			customToolbar(project)
			Divider()

			// Environment tabs
			environmentTabs(project)
			Divider()

			// Search bar
			if showSearch {
				searchBar
				Divider()
			}

			if currentSecrets.isEmpty && !showSearch {
				emptyState
			} else if filteredSecrets.isEmpty && showSearch {
				VStack(spacing: 8) {
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
								store.updateSecret(
									in: project.id, key: secret.key, newValue: newValue)
							},
							onDelete: {
								store.deleteSecret(from: project.id, key: secret.key)
							}
						)
					}
				}
				.id(store.selectedEnvironment)  // Reset scroll position on tab change
			}

			Divider()
			footer(project)
		}
		.background { keyboardShortcuts(project) }
		.confirmationDialog(
			"Remove \"\(project.name)\"?",
			isPresented: $showDeleteProjectConfirmation,
			titleVisibility: .visible
		) {
			Button("Remove from Sidebar") {
				store.removeFromSidebar(project)
			}
			Button("Delete Local Vault", role: .destructive) {
				store.deleteLocalVault(project)
			}
			Button("Delete Everywhere", role: .destructive) {
				Task.detached { [store] in await store.deleteEverywhere(project) }
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("• Remove from Sidebar — hides it, data stays. Re-add the folder to restore.\n• Delete Local — removes Keychain data. Pull from cloud to recover.\n• Delete Everywhere — removes local + cloud. Irreversible.")
		}
	}

	// MARK: - Keyboard Shortcuts

	@ViewBuilder
	private func keyboardShortcuts(_ project: VaultProject) -> some View {
		VStack {
			Button("") { showingAddSecret = true }
				.keyboardShortcut("n", modifiers: .command)
			Button("") { importIntoCurrentEnvironment(project) }
				.keyboardShortcut("i", modifiers: .command)
			Button("") {
				showSearch.toggle()
				if showSearch { isSearchFocused = true } else { localSearch = "" }
			}
			.keyboardShortcut("f", modifiers: .command)
			Button("") { exportToFile() }
				.keyboardShortcut("e", modifiers: .command)

			if store.isLoggedIn {
				Button("") { showPushConfirmation = true }
					.keyboardShortcut("p", modifiers: [.command, .shift])
				Button("") { showPullConfirmation = true }
					.keyboardShortcut("l", modifiers: [.command, .shift])
			}

			// ⌘1–9 for environment tab switching
			let envNames = store.orderedEnvironmentNames(for: project)
			ForEach(Array(envNames.prefix(9).enumerated()), id: \.offset) { idx, env in
				Button("") { store.selectedEnvironment = env }
					.keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
			}
		}
		.frame(width: 0, height: 0)
		.opacity(0)
	}

	// MARK: - Custom Toolbar

	private func customToolbar(_ project: VaultProject) -> some View {
		HStack(spacing: 8) {
			// Left: project name + delete
			Text(project.name)
				.font(.title3)
				.fontWeight(.semibold)

			ToolbarButtonGroup {
				ToolbarIconButton(icon: "trash", help: "Delete project", role: .destructive) {
					showDeleteProjectConfirmation = true
				}
			}

			Spacer()

			// Sync [pull, push]
			if store.isLoggedIn {
				ToolbarButtonGroup {
					ToolbarIconButton(icon: "arrow.down.to.line", help: "Pull from cloud (⇧⌘L)") {
						showPullConfirmation = true
					}
					.disabled(store.isSyncing)

					ToolbarIconButton(icon: "arrow.up.to.line", help: "Push to cloud (⇧⌘P)") {
						showPushConfirmation = true
					}
					.disabled(store.isSyncing)
				}

				// Org sync (only show if user has orgs)
				if !store.userOrgs.isEmpty {
					ToolbarButtonGroup {
						ToolbarIconButton(icon: "building.2", help: "Share with org") {
							if store.userOrgs.count == 1 {
								Task.detached { [store] in
									await store.pushToOrg(orgSlug: store.userOrgs[0].slug)
								}
							} else {
								showOrgSharePicker = true
							}
						}
						.disabled(store.isSyncing)
						.popover(isPresented: $showOrgSharePicker, arrowEdge: .bottom) {
							orgPicker(title: "Share with Org", action: { slug in
								showOrgSharePicker = false
								Task.detached { [store] in await store.pushToOrg(orgSlug: slug) }
							})
						}

						ToolbarIconButton(icon: "building.2.fill", help: "Pull from org") {
							if store.userOrgs.count == 1 {
								Task.detached { [store] in
									await store.pullFromOrg(orgSlug: store.userOrgs[0].slug)
								}
							} else {
								showOrgPullPicker = true
							}
						}
						.disabled(store.isSyncing)
						.popover(isPresented: $showOrgPullPicker, arrowEdge: .bottom) {
							orgPicker(title: "Pull from Org", action: { slug in
								showOrgPullPicker = false
								Task.detached { [store] in await store.pullFromOrg(orgSlug: slug) }
							})
						}
					}
				}

				if store.isSyncing {
					ProgressView()
						.controlSize(.small)
				}

				if let status = store.lastSyncStatus, !status.isEmpty {
					Text(status)
						.font(.caption)
						.foregroundStyle(status == "failed" ? .red : .secondary)
				}
			}

			// Data [copy, export, import]
			ToolbarButtonGroup {
				ToolbarIconButton(icon: "doc.on.clipboard", help: "Copy all as KEY=VALUE") {
					let envString = project.sortedSecrets(for: store.selectedEnvironment)
						.map { "\($0.key)=\($0.value)" }
						.joined(separator: "\n")
					ClipboardManager.shared.copy(envString, clearAfter: 60)
				}
				ToolbarIconButton(icon: "square.and.arrow.up", help: "Export to .env file (⌘E)") {
					exportToFile()
				}
				ToolbarIconButton(icon: "square.and.arrow.down", help: "Import from .env file (⌘I)") {
					importIntoCurrentEnvironment(project)
				}
			}

			// Add
			ToolbarButtonGroup {
				ToolbarIconButton(icon: "plus", help: "Add secret (⌘N)") {
					showingAddSecret = true
				}
			}

			// Search
			ToolbarButtonGroup {
				ToolbarIconButton(
					icon: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass",
					help: "Search secrets (⌘F)"
				) {
					showSearch.toggle()
					if showSearch {
						isSearchFocused = true
					} else {
						localSearch = ""
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}

	// MARK: - Environment Tabs

	private func environmentTabs(_ project: VaultProject) -> some View {
		let envNames = store.orderedEnvironmentNames(for: project)
		return ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 0) {
				ForEach(envNames, id: \.self) { env in
					Button {
						store.selectedEnvironment = env
					} label: {
						HStack(spacing: 4) {
							Text(VaultProject.displayName(for: env))
								.font(.system(.subheadline, design: .monospaced))
								.fontWeight(store.selectedEnvironment == env ? .semibold : .regular)
							Text("\(project.secretCount(for: env))")
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.contentShape(Rectangle())
						.background(
							store.selectedEnvironment == env
								? Color.accentColor.opacity(0.15)
								: Color.clear,
							in: RoundedRectangle(cornerRadius: 6)
						)
						.opacity(draggedEnv == env ? 0.4 : 1)
					}
					.buttonStyle(.plain)
					.draggable(env) {
						Text(VaultProject.displayName(for: env))
							.font(.system(.subheadline, design: .monospaced))
							.padding(.horizontal, 12)
							.padding(.vertical, 6)
							.background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
					}
					.dropDestination(for: String.self) { items, _ in
						guard let dropped = items.first, dropped != env else { return false }
						var order = store.orderedEnvironmentNames(for: project)
						guard let fromIdx = order.firstIndex(of: dropped),
							  let toIdx = order.firstIndex(of: env) else { return false }
						order.move(fromOffsets: IndexSet(integer: fromIdx),
								   toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
						store.saveEnvironmentOrder(for: project.id, order: order)
						return true
					}
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

						let secretCount = project.secretCount(for: env)
						Button("Clear All Secrets (\(secretCount))") {
							environmentToClear = env
						}
						.disabled(secretCount == 0)

						if project.environments.count > 1 {
							Button("Delete \"\(VaultProject.displayName(for: env))\"", role: .destructive) {
								environmentToDelete = env
							}
						}
					}
				}

				// Add environment button
				Button {
					newEnvName = ""
					newEnvSecrets = [:]
					showAddEnvironment = true
				} label: {
					Image(systemName: "plus")
						.font(.caption)
						.foregroundStyle(.secondary)
						.padding(.horizontal, 8)
						.padding(.vertical, 6)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("Add environment")
				.popover(isPresented: $showAddEnvironment, arrowEdge: .bottom) {
					addEnvironmentPopover(project)
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 4)
		}
		.onAppear {
			let envs = store.orderedEnvironmentNames(for: project)
			if !envs.contains(store.selectedEnvironment) {
				store.selectedEnvironment = envs.first ?? "default"
			}
		}
		// Delete environment confirmation
		.confirmationDialog(
			"Delete environment?",
			isPresented: Binding(
				get: { environmentToDelete != nil },
				set: { if !$0 { environmentToDelete = nil } }
			),
			titleVisibility: .visible
		) {
			if let env = environmentToDelete {
				Button("Delete \"\(VaultProject.displayName(for: env))\"", role: .destructive) {
					store.deleteEnvironment(from: project.id, name: env)
					environmentToDelete = nil
				}
				Button("Cancel", role: .cancel) { environmentToDelete = nil }
			}
		} message: {
			if let env = environmentToDelete {
				Text("This will delete the \"\(VaultProject.displayName(for: env))\" environment and all its secrets from the local vault. Push to cloud to remove it there too.")
			}
		}
		// Clear environment confirmation
		.confirmationDialog(
			"Clear all secrets?",
			isPresented: Binding(
				get: { environmentToClear != nil },
				set: { if !$0 { environmentToClear = nil } }
			),
			titleVisibility: .visible
		) {
			if let env = environmentToClear {
				Button("Clear All Secrets", role: .destructive) {
					store.clearEnvironment(in: project.id, name: env)
					environmentToClear = nil
				}
				Button("Cancel", role: .cancel) { environmentToClear = nil }
			}
		} message: {
			if let env = environmentToClear {
				Text("This will remove all secrets from the \"\(VaultProject.displayName(for: env))\" environment. The tab itself will remain.")
			}
		}
		// Rename popover
		.popover(isPresented: $showRenameEnvironment, arrowEdge: .bottom) {
			renameEnvironmentPopover(project)
		}
		// Duplicate popover
		.popover(isPresented: $showDuplicateEnvironment, arrowEdge: .bottom) {
			duplicateEnvironmentPopover(project)
		}
	}

	// MARK: - Add Environment Popover

	private func addEnvironmentPopover(_ project: VaultProject) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Add Environment")
				.font(.headline)

			TextField("Name (e.g. ci, staging)", text: $newEnvName)
				.textFieldStyle(.roundedBorder)
				.focused($isEnvNameFocused)
				.onSubmit { createEnvironment(for: project) }

			if !newEnvSecrets.isEmpty {
				HStack(spacing: 4) {
					Image(systemName: "checkmark.circle.fill")
						.foregroundStyle(.green)
					Text("\(newEnvSecrets.count) secrets imported")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			HStack {
				Button {
					importEnvFile(for: project)
				} label: {
					Label("Import .env file", systemImage: "doc.badge.plus")
						.font(.callout)
				}

				Spacer()

				Button("Cancel") {
					showAddEnvironment = false
				}

				Button("Create") {
					createEnvironment(for: project)
				}
				.buttonStyle(.borderedProminent)
				.disabled(newEnvName.trimmingCharacters(in: .whitespaces).isEmpty
					|| project.environments[newEnvName.trimmingCharacters(in: .whitespaces)] != nil)
			}

			if project.environments[newEnvName.trimmingCharacters(in: .whitespaces)] != nil
				&& !newEnvName.trimmingCharacters(in: .whitespaces).isEmpty {
				Text("Environment \"\(newEnvName.trimmingCharacters(in: .whitespaces))\" already exists")
					.font(.caption)
					.foregroundStyle(.red)
			}
		}
		.padding()
		.frame(width: 320)
		.onAppear { isEnvNameFocused = true }
	}

	// MARK: - Rename Environment Popover

	private func renameEnvironmentPopover(_ project: VaultProject) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Rename Environment")
				.font(.headline)

			TextField("New name", text: $renameEnvNewName)
				.textFieldStyle(.roundedBorder)
				.focused($isRenameFieldFocused)
				.onSubmit { performRename(for: project) }

			HStack {
				Spacer()
				Button("Cancel") {
					showRenameEnvironment = false
				}
				Button("Rename") {
					performRename(for: project)
				}
				.buttonStyle(.borderedProminent)
				.disabled(renameEnvNewName.trimmingCharacters(in: .whitespaces).isEmpty
					|| renameEnvNewName.trimmingCharacters(in: .whitespaces) == renameEnvTarget
					|| project.environments[renameEnvNewName.trimmingCharacters(in: .whitespaces)] != nil)
			}

			let trimmed = renameEnvNewName.trimmingCharacters(in: .whitespaces)
			if !trimmed.isEmpty && trimmed != renameEnvTarget && project.environments[trimmed] != nil {
				Text("Environment \"\(trimmed)\" already exists")
					.font(.caption)
					.foregroundStyle(.red)
			}
		}
		.padding()
		.frame(width: 300)
		.onAppear { isRenameFieldFocused = true }
	}

	private func performRename(for project: VaultProject) {
		let newName = renameEnvNewName.trimmingCharacters(in: .whitespaces)
		guard !newName.isEmpty, newName != renameEnvTarget else { return }
		guard project.environments[newName] == nil else { return }
		store.renameEnvironment(in: project.id, from: renameEnvTarget, to: newName)
		showRenameEnvironment = false
	}

	// MARK: - Duplicate Environment Popover

	private func duplicateEnvironmentPopover(_ project: VaultProject) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Duplicate \"\(VaultProject.displayName(for: duplicateEnvSource))\"")
				.font(.headline)

			TextField("New environment name", text: $duplicateEnvNewName)
				.textFieldStyle(.roundedBorder)
				.focused($isDuplicateFieldFocused)
				.onSubmit { performDuplicate(for: project) }

			HStack {
				Spacer()
				Button("Cancel") {
					showDuplicateEnvironment = false
				}
				Button("Duplicate") {
					performDuplicate(for: project)
				}
				.buttonStyle(.borderedProminent)
				.disabled(duplicateEnvNewName.trimmingCharacters(in: .whitespaces).isEmpty
					|| project.environments[duplicateEnvNewName.trimmingCharacters(in: .whitespaces)] != nil)
			}

			let trimmed = duplicateEnvNewName.trimmingCharacters(in: .whitespaces)
			if !trimmed.isEmpty && project.environments[trimmed] != nil {
				Text("Environment \"\(trimmed)\" already exists")
					.font(.caption)
					.foregroundStyle(.red)
			}
		}
		.padding()
		.frame(width: 300)
		.onAppear { isDuplicateFieldFocused = true }
	}

	private func performDuplicate(for project: VaultProject) {
		let newName = duplicateEnvNewName.trimmingCharacters(in: .whitespaces)
		guard !newName.isEmpty else { return }
		guard project.environments[newName] == nil else { return }
		store.duplicateEnvironment(in: project.id, from: duplicateEnvSource, to: newName)
		showDuplicateEnvironment = false
	}

	// MARK: - Org Picker

	private func orgPicker(title: String, action: @escaping (String) -> Void) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title)
				.font(.headline)

			ForEach(store.userOrgs) { org in
				Button {
					action(org.slug)
				} label: {
					HStack(spacing: 8) {
						Image(systemName: "building.2")
							.foregroundStyle(.secondary)
						VStack(alignment: .leading, spacing: 1) {
							Text(org.name)
								.fontWeight(.medium)
							Text("@\(org.slug)")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
					}
					.padding(.vertical, 4)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
		}
		.padding()
		.frame(width: 240)
	}

	private func createEnvironment(for project: VaultProject) {
		let name = newEnvName.trimmingCharacters(in: .whitespaces)
		guard !name.isEmpty else { return }
		guard project.environments[name] == nil else { return }
		store.addEnvironment(to: project.id, name: name, secrets: newEnvSecrets)
		showAddEnvironment = false
	}

	private func importEnvFile(for project: VaultProject) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "Select an .env file to import"
		panel.directoryURL = URL(fileURLWithPath: project.path)

		if panel.runModal() == .OK, let url = panel.url {
			let fileName = url.lastPathComponent
			// Auto-fill name from filename: ".env.ci" → "ci", ".env" → "default"
			if newEnvName.trimmingCharacters(in: .whitespaces).isEmpty {
				if fileName == ".env" {
					newEnvName = "default"
				} else if fileName.hasPrefix(".env.") {
					newEnvName = String(fileName.dropFirst(".env.".count))
				} else {
					newEnvName = fileName
				}
			}

			if let content = try? String(contentsOf: url, encoding: .utf8) {
				newEnvSecrets = parseEnvContent(content)
			}
		}
	}

	/// Simple .env parser (matches the Rust CLI parser behavior)
	private func parseEnvContent(_ content: String) -> [String: String] {
		var result: [String: String] = [:]
		for line in content.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

			let line = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
			guard let eqIndex = line.firstIndex(of: "=") else { continue }

			let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
			var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

			if (value.hasPrefix("\"") && value.hasSuffix("\""))
				|| (value.hasPrefix("'") && value.hasSuffix("'"))
			{
				value = String(value.dropFirst().dropLast())
			}

			if !key.isEmpty {
				result[key] = value
			}
		}
		return result
	}

	// MARK: - Search Bar

	private var searchBar: some View {
		HStack {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(.secondary)
			TextField("Filter secrets...", text: $localSearch)
				.textFieldStyle(.plain)
				.focused($isSearchFocused)
				.onExitCommand {
					showSearch = false
					localSearch = ""
				}
			if !localSearch.isEmpty {
				Button {
					localSearch = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	// MARK: - Subviews

	private var emptyState: some View {
		VStack(spacing: 12) {
			Image(systemName: "key")
				.font(.system(size: 36))
				.foregroundStyle(.secondary)
			Text("No secrets yet")
				.font(.title3)
				.foregroundStyle(.secondary)
			Button("Add Secret") {
				showingAddSecret = true
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func exportToFile() {
		guard let project else { return }
		let panel = NSSavePanel()
		let envSuffix = store.selectedEnvironment == "default" ? "" : ".\(store.selectedEnvironment)"
		panel.nameFieldStringValue = ".env\(envSuffix)"
		panel.message = "Export \(store.selectedEnvironment) secrets to .env file"

		if panel.runModal() == .OK, let url = panel.url {
			let content = project.sortedSecrets(for: store.selectedEnvironment)
				.map { secret in
					let v = secret.value
					if v.contains(" ") || v.contains("\"") || v.contains("'") || v.contains("\n") {
						return "\(secret.key)=\"\(v.replacingOccurrences(of: "\"", with: "\\\""))\""
					}
					return "\(secret.key)=\(v)"
				}
				.joined(separator: "\n") + "\n"
			try? content.write(to: url, atomically: true, encoding: .utf8)
		}
	}

	/// Import secrets from a .env file into the currently selected environment.
	/// Merges with existing secrets — new keys are added, existing keys are overwritten.
	private func importIntoCurrentEnvironment(_ project: VaultProject) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "Import secrets into \"\(VaultProject.displayName(for: store.selectedEnvironment))\""
		panel.directoryURL = URL(fileURLWithPath: project.path)

		if panel.runModal() == .OK, let url = panel.url {
			guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
			let imported = parseEnvContent(content)
			guard !imported.isEmpty else { return }
			store.importSecrets(to: project.id, secrets: imported)
		}
	}

	// MARK: - Footer

	private func footer(_ project: VaultProject) -> some View {
		HStack(spacing: 16) {
			Label(
				"\(project.secretCount) secret\(project.secretCount == 1 ? "" : "s")",
				systemImage: "key"
			)
			.foregroundStyle(.secondary)

			if let info = store.lastSyncInfo(for: project.id) {
				let verb = info.action == "push" ? "Pushed" : "Pulled"
				let versionStr = info.version.map { " v\($0)" } ?? ""
				Label("\(verb)\(versionStr) \(formatTimeAgo(info.date))", systemImage: "cloud")
					.foregroundStyle(.secondary)
			}

			Spacer()

			if !project.pathExists {
				Label("Path not found", systemImage: "exclamationmark.triangle")
					.foregroundStyle(.orange)
					.font(.caption)
			}

			Text(project.id.prefix(8) + "...")
				.font(.caption)
				.foregroundStyle(.tertiary)
				.help("Vault ID: \(project.id)")
		}
		.font(.caption)
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}

	private func formatTimeAgo(_ date: Date) -> String {
		let seconds = Int(-date.timeIntervalSinceNow)
		if seconds < 60 { return "just now" }
		let minutes = seconds / 60
		if minutes < 60 { return "\(minutes)m ago" }
		let hours = minutes / 60
		if hours < 24 { return "\(hours)h ago" }
		let days = hours / 24
		return "\(days)d ago"
	}
}
