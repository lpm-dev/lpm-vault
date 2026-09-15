import AppKit
import SwiftUI

struct VaultWorkspaceView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured

	@State private var mode: VaultWorkspaceMode = .matrix
	@State private var filter: VaultWorkspaceFilter = .all
	@State private var environmentViewMode: VaultEnvironmentViewMode = .table
	@State private var searchText = ""
	@State private var selectedKey: String?
	@State private var revealedKeys: Set<String> = []
	@State private var showsInspector = false
	@State private var showsAccountSwitcher = false
	@State private var sidebarWidth = VaultMetrics.sidebar
	@State private var inspectorWidth = VaultMetrics.inspector

	@State private var showNewProject = false
	@State private var showCloudProjects = false
	@State private var showNewEnvironment = false
	@State private var addSecretTarget: VaultSecretTarget?
	@State private var deleteSecretTarget: VaultSecretDeleteTarget?
	@State private var deleteEnvironmentTarget: VaultEnvironmentTarget?
	@State private var clearEnvironmentTarget: VaultEnvironmentTarget?
	@State private var renameEnvironmentTarget: VaultEnvironmentTarget?
	@State private var duplicateEnvironmentTarget: VaultEnvironmentTarget?
	@State private var environmentNameDraft = ""
	@State private var projectToRename: VaultProject?
	@State private var projectNameDraft = ""
	@State private var projectToDelete: VaultProject?

	@State private var showPushConfirmation = false
	@State private var showPullConfirmation = false
	@State private var conflictTarget: VaultSyncTarget?
	@State private var showVaultIDSheet = false
	@State private var currentImportTask: Task<Void, Never>?
	@State private var currentImportID: UUID?
	@State private var exportTask: Task<Void, Never>?
	@State private var exportID: UUID?
	@State private var copyAllTask: Task<Void, Never>?
	@State private var copyAllID: UUID?

	private var project: VaultProject? { store.selectedProject }

	private var inspectorVisible: Bool {
		guard showsInspector, !store.showAuthStatus, let project else { return false }
		return store.workspaceSnapshots[project.id] != nil
	}

	private var isOrganization: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}

	var body: some View {
		workspaceDialogs
		.onReceive(NotificationCenter.default.publisher(for: .newSecret)) { _ in presentAddSecret() }
		.onChange(of: store.selectedProjectId) { _, _ in resetProjectPresentation() }
		.onChange(of: store.selectedEnvironment) { _, environment in
			exportTask?.cancel()
			exportTask = nil
			exportID = nil
			mode = mode.synchronized(to: environment)
			revealedKeys.removeAll()
		}
		.onChange(of: mode) { _, _ in revealedKeys.removeAll() }
		.onChange(of: store.selectedAccount) { _, _ in
			conflictTarget = nil
			showsAccountSwitcher = false
		}
		.onChange(of: store.lastSyncStatus) { _, value in
			if value == "conflict", let project = store.selectedProject {
				conflictTarget = VaultSyncTarget(projectId: project.id, account: store.selectedAccount)
			}
		}
		.onChange(of: isObscured) { _, obscured in
			if obscured { dismissNativeDialogsForPrivacy() }
		}
		.onDisappear {
			currentImportTask?.cancel()
			currentImportTask = nil
			currentImportID = nil
			exportTask?.cancel()
			exportTask = nil
			exportID = nil
			copyAllTask?.cancel()
			copyAllTask = nil
			copyAllID = nil
			revealedKeys.removeAll()
			selectedKey = nil
		}
	}

	private var workspaceLayout: some View {
		VStack(spacing: 0) {
			VaultTitleBarView(
				store: store,
				mode: mode,
				onShowVaultID: { showVaultIDSheet = true },
				onPull: { showPullConfirmation = true },
				onPush: { showPushConfirmation = true }
			)
			.simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
			VaultHairline(color: VaultPalette.titleBarBorder)

			GeometryReader { geometry in
				let budget = VaultPaneBudget(
					available: geometry.size.width,
					requestedSidebar: sidebarWidth,
					requestedInspector: inspectorWidth,
					showsInspector: inspectorVisible
				)

				HStack(spacing: 0) {
					VaultResizablePane(
						width: $sidebarWidth,
						bounds: budget.sidebar,
						edge: .trailing,
						dividerWidth: VaultMetrics.sidebarDivider,
						accessibilityLabel: "Resize sidebar",
						onResize: { store.recordUserActivity() }
					) {
						VaultSidebarView(
							store: store,
							snapshots: store.workspaceSnapshots,
							mode: $mode,
							filter: $filter,
							searchText: $searchText,
							showsAccountSwitcher: $showsAccountSwitcher,
							onNewProject: { showNewProject = true },
							onCloudProjects: { showCloudProjects = true },
							onNewEnvironment: { showNewEnvironment = true },
							onRenameProject: beginRenameProject,
							onDeleteProject: { projectToDelete = $0 },
							onRenameEnvironment: beginRenameEnvironment,
							onDuplicateEnvironment: beginDuplicateEnvironment,
							onClearEnvironment: { clearEnvironmentTarget = $0 },
							onDeleteEnvironment: { deleteEnvironmentTarget = $0 }
						)
					}

					Group {
						if store.showAuthStatus {
							AuthStatusView(store: store)
								.frame(maxWidth: .infinity, maxHeight: .infinity)
								.background(VaultPalette.content)
						} else if store.isLoadingSelectedProject, let project {
							VStack(spacing: 10) {
								ProgressView()
								Text("Loading \(project.name)…")
									.font(.system(size: 12))
									.foregroundStyle(VaultPalette.textTertiary)
							}
							.frame(maxWidth: .infinity, maxHeight: .infinity)
							.background(VaultPalette.content)
						} else if let project,
						let snapshot = store.workspaceSnapshots[project.id]
						{
							VaultContentView(
								project: project,
								snapshot: snapshot,
								environments: store.orderedEnvironmentNames(for: project),
								selectedEnvironment: store.selectedEnvironment,
								mode: $mode,
								filter: $filter,
								environmentViewMode: $environmentViewMode,
								searchText: searchText,
								selectedKey: $selectedKey,
								revealedKeys: $revealedKeys,
								showsInspector: $showsInspector,
								isImporting: currentImportTask != nil,
								isCopyingAll: copyAllTask != nil,
								onCopyAll: copyAll,
								onImport: importCurrentEnvironment,
								onExport: exportCurrentEnvironment,
								onAddSecret: presentAddSecret,
								onCopySecret: copySecret,
								onDeleteSecret: requestDeleteSecret
							)
						} else {
							VaultWorkspaceEmptyView(
								isSearching: !searchText.isEmpty,
								onCreate: { showNewProject = true },
								onImport: { showCloudProjects = true }
							)
						}
					}
					.frame(width: budget.content, height: geometry.size.height)
					.clipped()
					.simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })

					if inspectorVisible, let project,
						let snapshot = store.workspaceSnapshots[project.id]
					{
						VaultResizablePane(
							width: $inspectorWidth,
							bounds: budget.inspector,
							edge: .leading,
							dividerWidth: VaultMetrics.inspectorDivider,
							accessibilityLabel: "Resize inspector",
							onResize: { store.recordUserActivity() }
						) {
							VaultInspectorView(
								store: store,
								project: project,
								snapshot: snapshot,
								environments: store.orderedEnvironmentNames(for: project),
								mode: mode,
								selectedKey: selectedKey,
								revealedKeys: $revealedKeys,
								onClose: { showsInspector = false },
								onCopySecret: copySecret,
								onDeleteSecret: requestDeleteSecret
							)
						}
						.simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
					}
				}
				.frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
				.clipped()
			}
		}
		.background(VaultPalette.content)
		.frame(minWidth: 1040, minHeight: 640)
		.overlay {
			if showsAccountSwitcher {
				ZStack(alignment: .bottomLeading) {
					Rectangle()
						.fill(.clear)
						.contentShape(Rectangle())
						.onTapGesture { showsAccountSwitcher = false }
						.accessibilityHidden(true)

					VaultAccountSwitcher(
						store: store,
						isPresented: $showsAccountSwitcher
					)
					.frame(width: VaultPaneBudget.clamp(
						sidebarWidth,
						minimum: VaultMetrics.sidebarMinimum,
						maximum: VaultMetrics.sidebarMaximum
					) - 16)
					.padding(.leading, 8)
					.padding(.bottom, 56)
					.transition(.opacity.combined(with: .offset(y: 6)))
				}
			}
		}
		.ignoresSafeArea(.container, edges: .top)
		.animation(.easeOut(duration: 0.14), value: showsAccountSwitcher)
	}

	private var workspaceSheets: some View {
		workspaceLayout
		.sheet(isPresented: $showNewProject) {
			NewVaultSheet(store: store).vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: $showCloudProjects) {
			cloudProjectSheet.vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: $showNewEnvironment) {
			if let project {
				NewEnvironmentSheet(store: store, project: project)
					.vaultPrivacyProtected(isObscured)
			}
		}
		.sheet(item: $addSecretTarget) { target in
			AddSecretSheet(store: store, projectId: target.projectId, environment: target.environment)
				.vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: $showPushConfirmation) {
			pushConfirmationSheet.vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: $showPullConfirmation) {
			pullConfirmationSheet.vaultPrivacyProtected(isObscured)
		}
		.sheet(item: $conflictTarget) { target in
			conflictResolutionSheet(target).vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: $showVaultIDSheet) {
			if let project {
				VaultIDSheet(vaultId: project.id)
					.vaultPrivacyProtected(isObscured)
			}
		}
	}

	private var workspaceDialogs: some View {
		workspaceSheets
		.alert("Rename Env Project", isPresented: Binding(
			get: { projectToRename != nil },
			set: { if !$0 { projectToRename = nil } }
		)) {
			TextField("Project name", text: $projectNameDraft)
			Button("Cancel", role: .cancel) { projectToRename = nil }
			Button("Rename", action: renameProject)
				.disabled(VaultProjectRenamePolicy.normalizedName(projectNameDraft) == nil)
		}
		.alert("Rename Environment", isPresented: Binding(
			get: { renameEnvironmentTarget != nil },
			set: { if !$0 { renameEnvironmentTarget = nil } }
		)) {
			TextField("Environment name", text: $environmentNameDraft)
			Button("Cancel", role: .cancel) { renameEnvironmentTarget = nil }
			Button("Rename", action: renameEnvironment)
				.disabled(!validEnvironmentDraft)
		}
		.alert("Duplicate Environment", isPresented: Binding(
			get: { duplicateEnvironmentTarget != nil },
			set: { if !$0 { duplicateEnvironmentTarget = nil } }
		)) {
			TextField("New environment name", text: $environmentNameDraft)
			Button("Cancel", role: .cancel) { duplicateEnvironmentTarget = nil }
			Button("Duplicate", action: duplicateEnvironment)
				.disabled(!validEnvironmentDraft)
		}
		.confirmationDialog("Delete local env project?", isPresented: Binding(
			get: { projectToDelete != nil },
			set: { if !$0 { projectToDelete = nil } }
		), titleVisibility: .visible) {
			if let projectToDelete {
				Button("Delete \"\(projectToDelete.name)\" Locally", role: .destructive) {
					Task { _ = await store.deleteLocalVault(projectToDelete); self.projectToDelete = nil }
				}
			}
			Button("Cancel", role: .cancel) { projectToDelete = nil }
		} message: {
			Text("This removes the local Keychain copy. A synced cloud copy is not deleted.")
		}
		.confirmationDialog("Delete environment?", isPresented: Binding(
			get: { deleteEnvironmentTarget != nil },
			set: { if !$0 { deleteEnvironmentTarget = nil } }
		), titleVisibility: .visible) {
			if let target = deleteEnvironmentTarget {
				Button("Delete \"\(VaultProject.displayName(for: target.environment))\"", role: .destructive) {
					store.deleteEnvironment(from: target.projectId, name: target.environment)
					deleteEnvironmentTarget = nil
				}
			}
			Button("Cancel", role: .cancel) { deleteEnvironmentTarget = nil }
		}
		.confirmationDialog("Clear all secrets?", isPresented: Binding(
			get: { clearEnvironmentTarget != nil },
			set: { if !$0 { clearEnvironmentTarget = nil } }
		), titleVisibility: .visible) {
			if let target = clearEnvironmentTarget {
				Button("Clear All Secrets", role: .destructive) {
					store.clearEnvironment(in: target.projectId, name: target.environment)
					clearEnvironmentTarget = nil
				}
			}
			Button("Cancel", role: .cancel) { clearEnvironmentTarget = nil }
		}
		.confirmationDialog("Delete secret?", isPresented: Binding(
			get: { deleteSecretTarget != nil },
			set: { if !$0 { deleteSecretTarget = nil } }
		), titleVisibility: .visible) {
			if let target = deleteSecretTarget {
				Button("Delete \"\(target.key)\" from \(VaultProject.displayName(for: target.environment))", role: .destructive) {
					store.deleteSecret(
						from: target.projectId,
						environment: target.environment,
						key: target.key
					)
					revealedKeys.remove(target.key)
					if selectedKey == target.key { selectedKey = nil }
					deleteSecretTarget = nil
				}
			}
			Button("Cancel", role: .cancel) { deleteSecretTarget = nil }
		} message: {
			Text("Only the selected environment is changed.")
		}
		.alert("LPM Vault", isPresented: Binding(
			get: { store.error != nil },
			set: { if !$0 { store.error = nil } }
		)) {
			Button("OK", role: .cancel) { store.error = nil }
		} message: {
			Text(store.error ?? "An unexpected error occurred.")
		}
	}

	@ViewBuilder
	private var cloudProjectSheet: some View {
		if case .org(let slug) = store.selectedAccount {
			OrgVaultsSheet(store: store, fixedOrgSlug: slug)
		} else {
			CloudVaultsSheet(store: store)
		}
	}

	@ViewBuilder
	private var pushConfirmationSheet: some View {
		if let project {
			SyncConfirmationSheet(
				action: isOrganization ? .share : .push,
				projectName: project.name,
				keyCount: project.secretCount,
				onConfirm: {
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

	@ViewBuilder
	private var pullConfirmationSheet: some View {
		if let project {
			SyncConfirmationSheet(
				action: .pull,
				projectName: project.name,
				keyCount: project.secretCount,
				onConfirm: {
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

	@ViewBuilder
	private func conflictResolutionSheet(_ target: VaultSyncTarget) -> some View {
		if let project = store.projects.first(where: { $0.id == target.projectId }) {
			ConflictResolutionSheet(
				projectName: project.name,
				account: target.account,
				onPullAndMerge: {
					conflictTarget = nil
					Task {
						await store.recoverFromConflict(.pullAndMerge, target: target)
					}
				},
				onForcePush: {
					conflictTarget = nil
					Task {
						await store.recoverFromConflict(.forcePush, target: target)
					}
				},
				onCancel: { conflictTarget = nil }
			)
		}
	}

	private func presentAddSecret() {
		guard addSecretTarget == nil, let project else { return }
		store.recordUserActivity()
		addSecretTarget = VaultSecretTarget(projectId: project.id, environment: store.selectedEnvironment)
	}

	private func dismissSearchFocus() {
		NotificationCenter.default.post(name: .dismissVaultSearch, object: nil)
	}

	private func dismissNativeDialogsForPrivacy() {
		projectToRename = nil
		projectNameDraft = ""
		renameEnvironmentTarget = nil
		duplicateEnvironmentTarget = nil
		environmentNameDraft = ""
		projectToDelete = nil
		deleteEnvironmentTarget = nil
		clearEnvironmentTarget = nil
		deleteSecretTarget = nil
		store.error = nil
	}

	private func requestDeleteSecret(_ key: String, _ environment: String) {
		guard let project else { return }
		deleteSecretTarget = VaultSecretDeleteTarget(projectId: project.id, environment: environment, key: key)
	}

	private func copySecret(_ key: String, _ environment: String) {
		guard let value = project?.value(for: key, in: environment) else { return }
		ClipboardManager.shared.copy(ClipboardManager.dotenvText(for: [key: value]))
	}

	private func copyAll() {
		guard copyAllTask == nil, let project else { return }
		let projectID = project.id
		let environment = store.selectedEnvironment
		let requestID = UUID()
		copyAllID = requestID
		copyAllTask = Task { @MainActor in
			defer {
				if copyAllID == requestID {
					copyAllTask = nil
					copyAllID = nil
				}
			}
			let success = await store.authenticateForSensitiveAction(
				reason: "Copy all secrets to clipboard"
			)
			guard success,
				copyAllID == requestID,
				store.isUnlocked,
				store.selectedProjectId == projectID,
				store.selectedEnvironment == environment,
				let current = store.selectedProject
			else { return }
			let contents = ClipboardManager.dotenvText(
				for: current.secrets(for: environment)
			)
			ClipboardManager.shared.copy(contents, clearAfter: 15)
		}
	}

	private func importCurrentEnvironment() {
		guard let project, currentImportTask == nil else { return }
		let environment = store.selectedEnvironment
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "Import secrets into \"\(VaultProject.displayName(for: environment))\""
		guard runVaultPrivacyAwareModal(panel) == .OK, let url = panel.url else { return }

		let requestID = UUID()
		currentImportID = requestID
		currentImportTask = Task {
			let result = await store.importEnvFile(at: url, to: project.id, environment: environment)
			guard currentImportID == requestID else { return }
			currentImportTask = nil
			currentImportID = nil
			if case .failure(let error) = result, error != .cancelled {
				store.error = error.localizedDescription
			}
		}
	}

	private func exportCurrentEnvironment() {
		guard let project, exportTask == nil else { return }
		let projectID = project.id
		let environment = store.selectedEnvironment
		let panel = NSSavePanel()
		let suffix = environment == "default" ? "" : ".\(environment)"
		panel.nameFieldStringValue = ".env\(suffix)"
		panel.message = "Export \(VaultProject.displayName(for: environment))"
		guard runVaultPrivacyAwareModal(panel) == .OK, let url = panel.url else { return }
		let requestID = UUID()
		exportID = requestID
		exportTask = Task { @MainActor in
			defer {
				if VaultTaskOwnership.owns(current: exportID, request: requestID) {
					exportTask = nil
					exportID = nil
				}
			}
			do {
				try await store.exportEnvironment(
					projectId: projectID,
					environment: environment,
					to: url
				)
			} catch is CancellationError {
				return
			} catch {
				guard VaultTaskOwnership.owns(current: exportID, request: requestID),
					store.isUnlocked,
					store.selectedProjectId == projectID,
					store.selectedEnvironment == environment
				else { return }
				store.error = "Export failed. \(error.localizedDescription)"
			}
		}
	}

	private func beginRenameProject(_ project: VaultProject) {
		projectToRename = project
		projectNameDraft = project.name
	}

	private func renameProject() {
		guard let project = projectToRename,
			let normalizedName = VaultProjectRenamePolicy.normalizedName(projectNameDraft)
		else { return }
		store.renameProject(project, to: normalizedName)
		projectToRename = nil
	}

	private func beginRenameEnvironment(_ target: VaultEnvironmentTarget) {
		renameEnvironmentTarget = target
		environmentNameDraft = target.environment
	}

	private func beginDuplicateEnvironment(_ target: VaultEnvironmentTarget) {
		duplicateEnvironmentTarget = target
		environmentNameDraft = "\(target.environment)-copy"
	}

	private var validEnvironmentDraft: Bool {
		let candidate = environmentNameDraft.trimmingCharacters(in: .whitespaces)
		guard EnvValidation.isValidEnvironmentName(candidate), let project else { return false }
		return project.environments[candidate] == nil
	}

	private func renameEnvironment() {
		guard let target = renameEnvironmentTarget, validEnvironmentDraft else { return }
		let name = environmentNameDraft.trimmingCharacters(in: .whitespaces)
		store.renameEnvironment(in: target.projectId, from: target.environment, to: name)
		renameEnvironmentTarget = nil
	}

	private func duplicateEnvironment() {
		guard let target = duplicateEnvironmentTarget, validEnvironmentDraft else { return }
		let name = environmentNameDraft.trimmingCharacters(in: .whitespaces)
		store.duplicateEnvironment(in: target.projectId, from: target.environment, to: name)
		duplicateEnvironmentTarget = nil
	}

	private func resetProjectPresentation() {
		mode = .matrix
		filter = .all
		environmentViewMode = .table
		selectedKey = nil
		revealedKeys.removeAll()
		showsInspector = false
		conflictTarget = nil
		currentImportTask?.cancel()
		currentImportTask = nil
		currentImportID = nil
		exportTask?.cancel()
		exportTask = nil
		exportID = nil
		copyAllTask?.cancel()
		copyAllTask = nil
		copyAllID = nil
	}

}
