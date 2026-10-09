import AppKit
import SwiftUI

struct VaultWorkspaceView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured
	@Environment(\.vaultCopyFeedbackTimer) private var copyFeedbackTimer

	@State private var mode: VaultWorkspaceMode = .matrix
	@State private var filter: VaultWorkspaceFilter = .all
	@State private var environmentViewMode: VaultEnvironmentViewMode = .table
	@AppStorage(VaultKeySortOrder.defaultsKey) private var keySortOrder = VaultKeySortOrder.ascending
	@State private var searchText = ""
	@State private var selectedKey: String?
	@State private var schemaSelection: VaultSchemaSelection?
	/// The project whose schema draft the review sheet shows.
	@State private var schemaReview: SchemaReviewTarget?
	@State private var schemaPanelSession = UUID()
	@State private var revealedKeys: Set<String> = []
	@State private var showsInspector = false
	@State private var showsAccountSwitcher = false
	@State private var sidebarWidth = VaultMetrics.sidebar
	@State private var inspectorWidth = VaultMetrics.inspector
	@State private var tableColumnWidths: [String: VaultProjectTableColumnWidths] = [:]

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
	@State private var showConnectCLISheet = false
	@State private var importReview: EnvFileImportReview?
	@State private var currentImportTask: Task<Void, Never>?
	@State private var currentImportID: UUID?
	@State private var exportTask: Task<Void, Never>?
	@State private var exportID: UUID?
	@State private var copyAllTask: Task<Void, Never>?
	@State private var copyAllID: UUID?
	@State private var copyUnsavedTask: Task<Void, Never>?
	@State private var copyUnsavedID: UUID?
	@State private var copyFeedback: VaultCopyFeedback?

	private var project: VaultProject? { store.selectedProject }

	/// What the Schema page watches for changes: lpm.json's folder, and the
	/// schemas lpm.json imports as last read, so a pull that changes only an
	/// import still rereads the rules.
	private struct SchemaWatch: Hashable {
		let folder: String
		let imports: [String]
	}

	/// What the Schema page watches; nil off the page.
	private var schemaWatch: SchemaWatch? {
		guard mode == .schema, !store.showAuthStatus, let descriptions = project.flatMap({ store.keyDescriptions[$0.id] }), !descriptions.folder.isEmpty
		else { return nil }
		return SchemaWatch(folder: descriptions.folder, imports: descriptions.importPaths)
	}

	/// Opens a selection in the Schema page's panel as a new stretch of editing.
	private func selectSchema(_ selection: VaultSchemaSelection?) {
		schemaSelection = selection
		schemaPanelSession = UUID()
	}

	/// Adds a stored key to the draft with no rules yet, and opens it. The
	/// store marks it public when a prefix makes it so.
	private func declare(_ key: String, in project: VaultProject) {
		store.editSchemaDraft(in: project.id) { $0.set(.declared(ProjectEnvSchemaRule().json), for: .key(key)) }
		selectSchema(.key(key))
	}

	/// Rereads the rules when the Schema page starts showing them, which picks
	/// up edits made meanwhile, and whenever lpm.json or a schema it imports
	/// changes while it does.
	private func watchSchemaFolder() async {
		guard let watch = schemaWatch else { return }
		store.reloadKeyDescriptions()
		for await _ in ProjectConfigWatcher.changes(inFolder: watch.folder, imports: watch.imports) {
			guard !Task.isCancelled else { return }
			store.reloadKeyDescriptions()
		}
	}

	private var hasUnsavedRecovery: Bool { !store.keyDrafts.orphanIDs.isEmpty }

	private var inspectorVisible: Bool {
		guard !store.showAuthStatus else { return false }
		if hasUnsavedRecovery { return true }
		if mode == .schema { return schemaPanelVisible }
		guard showsInspector, let project else { return false }
		return store.workspaceSnapshots[project.id] != nil
	}

	/// The Schema page's panel shows a selection while the project's rules are loaded.
	private var schemaPanelVisible: Bool {
		guard mode == .schema, schemaSelection != nil, let project, store.selectedProjectLoadFailure == nil else { return false }
		if case .loaded? = store.keyDescriptions[project.id]?.schema { return true }
		return false
	}

	private var isOrganization: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}

	var body: some View {
		workspaceDialogs
		.onReceive(NotificationCenter.default.publisher(for: .newSecret)) { _ in presentAddSecret() }
		.onChange(of: store.selectedProjectId) { _, _ in resetProjectPresentation() }
		.task(id: store.selectedProjectId) { store.reloadKeyDescriptions() }
		.task(id: schemaWatch) { await watchSchemaFolder() }
		.onChange(of: store.selectedEnvironment) { _, environment in
			resetCopyPresentation()
			importReview = nil
			currentImportTask?.cancel()
			currentImportTask = nil
			currentImportID = nil
			exportTask?.cancel()
			exportTask = nil
			exportID = nil
			mode = mode.synchronized(to: environment)
			revealedKeys.removeAll()
		}
		.onChange(of: mode) { _, _ in revealedKeys.removeAll() }
		.onChange(of: store.showAuthStatus) { _, showingSettings in
			if showingSettings { resetCopyPresentation() }
		}
		.task(id: copyFeedback?.id) {
			guard let feedbackID = copyFeedback?.id else { return }
			do { try await copyFeedbackTimer.wait() } catch { return }
			guard !Task.isCancelled, copyFeedback?.id == feedbackID else { return }
			copyFeedback = nil
		}
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
			resetCopyPresentation()
			revealedKeys.removeAll()
			selectedKey = nil
		}
	}

	private var workspaceLayout: some View {
		VStack(spacing: 0) {
			VaultTitleBarView(
				store: store,
				mode: mode,
				onConnectCLI: { showConnectCLISheet = true },
				onPull: { showPullConfirmation = true },
				onPush: { showPushConfirmation = true },
				isConnectSheetPresented: showConnectCLISheet
			)
			.simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
			VaultHairline(color: VaultPalette.titleBarBorder)
			if !isObscured, !store.showAuthStatus, let warning = store.lastSyncWarnings.first {
				metadataWarningBanner(warning)
			}
			if let refreshError = store.localStateRefreshError {
				localStateRefreshBanner(refreshError)
			}

			GeometryReader { geometry in
				let budget = VaultPaneBudget(
					available: geometry.size.width,
					requestedSidebar: sidebarWidth,
					requestedInspector: inspectorWidth,
					showsInspector: inspectorVisible
				)

				HStack(spacing: 0) {
					VaultResizablePane(width: budget.sidebar.width, edge: .trailing) {
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
						} else if let failure = store.selectedProjectLoadFailure {
							VaultLoadErrorView(failure: failure, retry: store.retrySelectedProjectLoad)
								.frame(maxWidth: .infinity, maxHeight: .infinity)
								.background(VaultPalette.content)
						} else if let project, mode == .schema {
							let rules = store.keyDescriptions[project.id]
							let draft = store.schemaDraft(for: project.id)
							VaultSchemaView(
								state: rules?.schema,
								folder: rules?.folder,
								descriptions: (try? rules?.rules.get())?.descriptions ?? [:],
								sortOrder: $keySortOrder,
								draft: draft,
								draftOverview: draft == nil ? nil : store.latestSchemaDraftEvaluation(for: project.id)?.overview,
								selection: schemaSelection,
								onSelect: selectSchema,
								canEdit: store.canEditSchema(of: project.id),
								onAddKey: { selectSchema(.newKey) },
								onAddGroup: { selectSchema(.newGroup) },
								clientPrefixCount: store.schemaClientPrefixesInEffect(for: project.id).count,
								clientPrefixes: AnyView(VaultSchemaClientPrefixesPopover(store: store, project: project) { selectSchema(.key($0)) }),
								undeclared: store.undeclaredSchemaKeys(for: project.id),
								onDeclare: { declare($0, in: project) },
								rebase: store.schemaDraftRebases[project.id],
								onDismissRebase: { store.dismissSchemaDraftRebase(in: project.id) },
								onResolveConflict: { item, keepingMine in
									store.editSchemaDraft(in: project.id) { $0.resolveConflict(item, keepingMine: keepingMine) }
								},
								onConnectCLI: { showConnectCLISheet = true },
								onRecheck: store.reloadKeyDescriptions
							)
						} else if let project,
							store.isLoadingSelectedProject || (project.hasLoadedEnvironments && store.workspaceSnapshots[project.id] == nil)
						{
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
								sortOrder: $keySortOrder,
								searchText: searchText,
								selectedKey: $selectedKey,
								revealedKeys: $revealedKeys,
								showsInspector: $showsInspector,
								columnWidths: Binding(
									get: { tableColumnWidths[project.id] ?? VaultProjectTableColumnWidths() },
									set: { tableColumnWidths[project.id] = $0 }
								),
								isImporting: currentImportTask != nil,
								isCopyingAll: copyAllTask != nil,
								isCopiedAll: copyFeedback?.target == .all(VaultSensitiveActionContext(
									projectID: project.id, environment: store.selectedEnvironment
								)),
								canUseSecrets: store.canUseLocalSecrets,
								cliAccess: store.selectedProjectCliAccess,
								isChangingCliAccess: store.isChangingCliAccess,
								onChangeCliAccess: { access in Task { await store.changeCliAccess(to: access) } },
								onCopyAll: copyAll,
								onImport: importCurrentEnvironment,
								onExport: exportCurrentEnvironment,
								editedKeys: store.keyDrafts.editedKeys(in: project.id),
								publicKeys: store.publicKeys(in: project.id),
								valueChecks: VaultValueCheckPresentation(
									check: store.valueChecks[project.id],
									rules: store.keyDescriptions[project.id]?.schema?.overview,
									project: project
								),
								onAddSecret: presentAddSecret,
								onAddKey: { presentAddSecret(key: $0, environment: store.selectedEnvironment) },
								onCopySecret: copySecret,
								onDeleteSecret: requestDeleteSecret,
								onResizeColumns: { store.recordUserActivity() }
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

					if inspectorVisible, hasUnsavedRecovery {
						VaultResizablePane(width: budget.inspector.width, edge: .leading) {
							VaultKeyRecoveryView(
								store: store,
								copied: copyFeedback?.target,
								onCopy: copyUnsavedValue,
								onDiscard: discardUnsaved
							)
						}
					} else if inspectorVisible, mode == .schema, let project, let schemaSelection {
						VaultResizablePane(width: budget.inspector.width, edge: .leading) {
							VaultSchemaPanel(
								store: store,
								project: project,
								environments: store.orderedEnvironmentNames(for: project),
								selection: schemaSelection,
								session: schemaPanelSession,
								onSelect: selectSchema,
								onFollow: { self.schemaSelection = $0 },
								onReview: { schemaReview = SchemaReviewTarget(projectID: project.id) },
								onRenamed: followRename
							)
						}
						.simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
					} else if inspectorVisible, let project {
						VaultResizablePane(width: budget.inspector.width, edge: .leading) {
							VaultInspectorView(
								store: store,
								project: project,
								environments: store.orderedEnvironmentNames(for: project),
								mode: mode,
								selectedKey: selectedKey,
								copiedEnvironment: copiedEnvironment(in: project),
								revealedKeys: $revealedKeys,
								onClose: { showsInspector = false },
								onCopy: copyValue,
								onDelete: requestDeleteSecret,
								onAddElsewhere: { key, environment in
									presentAddSecret(key: key, environment: environment)
								},
								onRenamed: followRename
							)
						}
						.simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
					}
				}
				.frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
				.clipped()
				.overlay(alignment: .topLeading) {
					ZStack(alignment: .topLeading) {
						VaultPaneResizeHandle(
							width: $sidebarWidth,
							bounds: budget.sidebar,
							edge: .trailing,
							accessibilityLabel: "Resize sidebar",
							onResize: { store.recordUserActivity() }
						)
						.padding(.leading, budget.sidebarDividerCenter - VaultMetrics.paneDividerHitWidth / 2)

						if inspectorVisible {
							VaultPaneResizeHandle(
								width: $inspectorWidth,
								bounds: budget.inspector,
								edge: .leading,
								accessibilityLabel: "Resize inspector",
								onResize: { store.recordUserActivity() }
							)
							.padding(.leading, budget.inspectorDividerCenter - VaultMetrics.paneDividerHitWidth / 2)
						}
					}
				}
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
		.sheet(item: $importReview) { review in
			EnvFileImportReviewSheet(store: store, review: review).vaultPrivacyProtected(isObscured)
		}
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
			AddVariableSheet(store: store, projectId: target.projectId, environment: target.environment, initialKey: target.initialKey)
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
		.sheet(item: $schemaReview) { target in
			if let project = store.projects.first(where: { $0.id == target.projectID }) {
				VaultSchemaReviewSheet(store: store, project: project, environments: store.orderedEnvironmentNames(for: project))
					.vaultPrivacyProtected(isObscured)
			}
		}
		.sheet(isPresented: $showConnectCLISheet) {
			if let project {
				ConnectCLISheet(store: store, projectId: project.id)
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
					deleteSecret(target)
					deleteSecretTarget = nil
				}
			}
			Button("Cancel", role: .cancel) { deleteSecretTarget = nil }
		} message: {
			if let target = deleteSecretTarget {
				Text("Only \(VaultProject.displayName(for: target.environment)) is changed.")
			}
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
		presentAddSecret(key: "", environment: store.selectedEnvironment)
	}

	private func presentAddSecret(key: String, environment: String) {
		guard addSecretTarget == nil, let project else { return }
		store.recordUserActivity()
		addSecretTarget = VaultSecretTarget(projectId: project.id, environment: environment, initialKey: key)
	}

	private func dismissSearchFocus() {
		NotificationCenter.default.post(name: .dismissVaultSearch, object: nil)
	}

	private func dismissNativeDialogsForPrivacy() {
		importReview = nil
		currentImportTask?.cancel()
		currentImportTask = nil
		currentImportID = nil
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

	/// Deletes one environment's value along with any unsaved edit of it. The key
	/// stays selected while other environments still have it.
	private func deleteSecret(_ target: VaultSecretDeleteTarget) {
		guard let project = store.projects.first(where: { $0.id == target.projectId }) else { return }
		store.keyDrafts.discardEdits(deleting: target.key, from: target.environment, in: project)
		store.deleteSecret(from: target.projectId, environment: target.environment, key: target.key)
		if !project.environments.contains(where: { $0.key != target.environment && $0.value[target.key] != nil }) {
			revealedKeys.remove(target.key)
			if selectedKey == target.key { selectedKey = nil }
		}
	}

	private func followRename(_ key: String, to newKey: String) {
		if selectedKey == key { selectedKey = newKey }
		if revealedKeys.remove(key) != nil { revealedKeys.insert(newKey) }
	}

	private func metadataWarningBanner(_ warning: SyncMetadataWarning) -> some View {
		HStack(spacing: 10) {
			Image(systemName: "exclamationmark.triangle.fill")
			VStack(alignment: .leading, spacing: 4) {
				Text(warning.message)
				Text(warning.hint)
			}
			.font(.system(size: 12))
			Spacer(minLength: 12)
			Link("Upgrade and repair", destination: URL(string: "https://lpm.dev/docs/env/local#upgrade-existing-env-schemas")!)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
		.background(VaultPalette.redTint)
	}

	private func localStateRefreshBanner(_ message: String) -> some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "exclamationmark.triangle.fill")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.red)
				Text(message)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.redText)
					.lineLimit(2)
				Spacer(minLength: 12)
				VaultBarButton(
					title: store.isRefreshingLocalState ? "Retrying…" : "Retry",
					disabled: store.isRefreshingLocalState || store.isChangingCliAccess,
					height: 24
				) { Task { await store.refreshLocalState() } }
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
			.background(VaultPalette.redTint)
			VaultHairline(color: VaultPalette.titleBarBorder)
		}
	}

	/// Copies right away, or once a refresh in progress publishes current values.
	private func copySecret(_ key: String, _ environment: String) {
		guard store.canUseLocalSecrets, !store.showAuthStatus, let projectID = project?.id else { return }
		guard store.isRefreshingLocalState else {
			copyCurrentSecret(key, environment, projectID: projectID)
			return
		}
		Task { @MainActor in
			await store.waitForLocalStateRefresh()
			copyCurrentSecret(key, environment, projectID: projectID)
		}
	}

	private func copyCurrentSecret(_ key: String, _ environment: String, projectID: String) {
		guard store.canUseLocalSecrets, !store.showAuthStatus,
			let current = store.selectedProject, current.id == projectID,
			let value = current.value(for: key, in: environment),
			ClipboardManager.shared.copy(ClipboardManager.dotenvText(for: [key: value]))
		else { return }
		copyFeedback = VaultCopyFeedback(target: .secret(projectID: projectID, environment: environment, key: key))
	}

	/// Copies what an inspector value field shows, after a refresh in progress
	/// publishes current values.
	private func copyValue(_ request: VaultValueCopy) {
		guard store.canUseLocalSecrets, !store.showAuthStatus, project?.id == request.projectID else { return }
		guard store.isRefreshingLocalState else {
			copyCurrentValue(request)
			return
		}
		Task { @MainActor in
			await store.waitForLocalStateRefresh()
			copyCurrentValue(request)
		}
	}

	private func copyCurrentValue(_ request: VaultValueCopy) {
		guard store.canUseLocalSecrets, !store.showAuthStatus,
			let current = store.selectedProject, current.id == request.projectID
		else { return }
		let draft = store.keyDrafts.draft(VaultKeyDraft.ID(projectID: request.projectID, key: request.key))
		let name = draft.map { EnvValidation.isValidVariableName($0.name) ? $0.name : $0.key } ?? request.key
		var value = ""
		if request.format.includesValue {
			guard let shown = draft?.value(in: request.environment) ?? current.value(for: request.key, in: request.environment)
			else { return }
			value = shown
		}
		guard ClipboardManager.shared.copy(request.format.text(key: name, value: value)) else { return }
		copyFeedback = VaultCopyFeedback(target: .secret(projectID: request.projectID, environment: request.environment, key: request.key))
	}

	private func copiedEnvironment(in project: VaultProject) -> String? {
		guard case .secret(let projectID, let environment, let key) = copyFeedback?.target,
			projectID == project.id, key == selectedKey
		else { return nil }
		return environment
	}

	private func copyAll() {
		guard store.canUseLocalSecrets, !store.showAuthStatus, copyAllTask == nil, let project else { return }
		let context = VaultSensitiveActionContext(projectID: project.id, environment: store.selectedEnvironment)
		let requestID = UUID()
		copyAllID = requestID
		copyFeedback = nil
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
			guard success else { return }
			// Returning from the macOS prompt can trigger a refresh; copy what it publishes.
			await store.waitForLocalStateRefresh()
			guard !store.showAuthStatus,
				copyAllID == requestID,
				context.isCurrent(in: store),
				let current = store.selectedProject
			else { return }
			let contents = ClipboardManager.dotenvText(
				for: current.secrets(for: context.environment)
			)
			if ClipboardManager.shared.copy(contents, clearAfter: 15) {
				copyFeedback = VaultCopyFeedback(target: .all(context))
			}
		}
	}

	private func importCurrentEnvironment() {
		guard let project, currentImportTask == nil, importReview == nil else { return }
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
			let result = await store.prepareEnvFileImport(at: url, to: project.id, environment: environment)
			guard currentImportID == requestID else { return }
			currentImportTask = nil
			currentImportID = nil
			switch result {
			case .success(let review): importReview = review
			case .failure(.cancelled): break
			case .failure(let error): store.error = error.localizedDescription
			}
		}
	}

	private func exportCurrentEnvironment() {
		guard store.canUseLocalSecrets, let project, exportTask == nil else { return }
		let context = VaultSensitiveActionContext(projectID: project.id, environment: store.selectedEnvironment)
		let environment = context.environment
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
					projectId: context.projectID,
					environment: environment,
					to: url
				)
			} catch is CancellationError {
				return
			} catch {
				guard VaultTaskOwnership.owns(current: exportID, request: requestID),
					context.isCurrent(in: store)
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
		importReview = nil
		mode = .matrix
		filter = .all
		environmentViewMode = .table
		selectedKey = nil
		schemaSelection = nil
		schemaReview = nil
		revealedKeys.removeAll()
		showsInspector = false
		conflictTarget = nil
		currentImportTask?.cancel()
		currentImportTask = nil
		currentImportID = nil
		exportTask?.cancel()
		exportTask = nil
		exportID = nil
		resetCopyPresentation()
	}

	/// Copies a value of an unsaved edit whose project or key is gone, after the
	/// person authenticates, as long as that edit is still shown.
	private func copyUnsavedValue(_ id: VaultKeyDraft.ID, _ environment: String) {
		guard store.isUnlocked, !store.showAuthStatus, copyUnsavedTask == nil,
			store.keyDrafts.orphanIDs.contains(id) else { return }
		let requestID = UUID()
		copyUnsavedID = requestID
		copyFeedback = nil
		copyUnsavedTask = Task { @MainActor in
			defer {
				if copyUnsavedID == requestID {
					copyUnsavedTask = nil
					copyUnsavedID = nil
				}
			}
			guard await store.authenticateForSensitiveAction(reason: "Copy your unsaved value"),
				!Task.isCancelled, copyUnsavedID == requestID,
				store.isUnlocked, !store.showAuthStatus, store.keyDrafts.orphanIDs.contains(id),
				let value = store.keyDrafts.draft(id)?.value(in: environment),
				ClipboardManager.shared.copy(value)
			else { return }
			copyFeedback = VaultCopyFeedback(target: .unsaved(id, environment: environment))
		}
	}

	private func discardUnsaved(_ id: VaultKeyDraft.ID) {
		resetCopyPresentation()
		store.keyDrafts.discard(id)
	}

	private func resetCopyPresentation() {
		copyUnsavedTask?.cancel()
		copyUnsavedTask = nil
		copyUnsavedID = nil
		copyAllTask?.cancel()
		copyAllTask = nil
		copyAllID = nil
		copyFeedback = nil
	}

}

/// The review sheet of one project's schema draft, which closes when that
/// project is no longer the one shown.
private struct SchemaReviewTarget: Identifiable {
	let projectID: String
	var id: String { projectID }
}
