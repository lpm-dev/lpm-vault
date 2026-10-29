import AppKit
import SwiftUI

struct VaultWorkspaceView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured
	@Environment(\.vaultCopyFeedbackTimer) private var copyFeedbackTimer
	@Environment(\.vaultImportUndoTimer) private var undoTimer

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
	@State private var shownMenu: WorkspaceMenu?
	@State private var sidebarWidth = VaultMetrics.sidebar
	@State private var inspectorWidth = VaultMetrics.inspector
	@State private var tableColumnWidths: [String: VaultProjectTableColumnWidths] = [:]

	@State private var showNewProject = false
	@State private var showBackupRestore = false
	@State private var showCloudProjects = false
	@State private var showNewEnvironment = false
	@State private var addSecretTarget: VaultSecretTarget?
	@State private var deleteSecretTarget: VaultSecretDeleteTarget?
	@State private var deleteEnvironmentTarget: VaultEnvironmentTarget?
	@State private var clearEnvironmentTarget: VaultEnvironmentTarget?
	@State private var renameEnvironmentTarget: VaultEnvironmentTarget?
	@State private var duplicateEnvironmentTarget: VaultEnvironmentTarget?
	@State private var environmentNameDraft = ""
	@State private var projectToDelete: VaultProject?
	/// An exit from a restore's sync pause, waiting for the person to confirm it.
	@State private var pauseExit: VaultSyncPauseExit?
	@State private var companionRepair: CompanionRepairRequest?
	@State private var isCheckingSharingKey = false
	/// The project whose settings open once it's selected.
	@State private var pendingProjectSettings: String?
	/// Focuses the Project Settings name field each time it changes.
	@State private var projectNameFocusRequest: UUID?

	@State private var showPushConfirmation = false
	@State private var showPullConfirmation = false
	@State private var conflictTarget: VaultSyncTarget?
	@State private var showConnectCLISheet = false
	@State private var publishSession: PublishSession?
	@State private var importRequest: EnvImportRequest?
	@State private var isImportDropTargeted = false
	@State private var hostWindow = VaultHostWindow()
	@State private var exportTask: Task<Void, Never>?
	@State private var exportNotice: ExportNotice?
	@State private var exportID: UUID?
	@State private var copyAllTask: Task<Void, Never>?
	@State private var copyAllID: UUID?
	@State private var copyLinesTask: Task<Void, Never>?
	/// Why the last save of each Raw text edit wrote nothing.
	@State private var rawTextFailures: [VaultEnvironmentTarget: VaultRawTextFailure] = [:]
	@State private var rawTextSaved: VaultRawTextSaved?
	@State private var rawTextReview: VaultRawTextReview?
	@State private var copyFeedback: VaultCopyFeedback?

	private var project: VaultProject? { store.selectedProject }

	/// What the Schema page watches for changes: lpm.json's folder, and the
	/// schemas lpm.json imports as last read, so a pull that changes only an
	/// import still rereads the rules.
	private struct SchemaWatch: Hashable {
		let folder: String
		let imports: [String]
	}

	/// What the selected project's icon depends on in its folder.
	private struct IconWatch: Hashable {
		let projectID: String
		let folder: String
		let paths: [String]
	}

	private var iconWatch: IconWatch? {
		guard store.isUnlocked, let project, !project.path.isEmpty else { return nil }
		return IconWatch(projectID: project.id, folder: project.path, paths: store.projectIcons.watchedPaths(for: project.id))
	}

	/// What the Schema page watches; nil off the page.
	private var schemaWatch: SchemaWatch? {
		guard mode == .schema, !store.isShowingAccountPage, let descriptions = project.flatMap({ store.keyDescriptions[$0.id] }), !descriptions.folder.isEmpty
		else { return nil }
		return SchemaWatch(folder: descriptions.folder, imports: descriptions.importPaths)
	}

	/// Opens a selection in the Schema page's panel as a new stretch of editing.
	private func selectSchema(_ selection: VaultSchemaSelection?) {
		schemaSelection = selection
		schemaPanelSession = UUID()
	}

	/// Keys whose stored values fail their rules: by the draft's latest
	/// evaluation while there's a draft, and by lpm.json's rules while the
	/// draft has none, such as while the LPM CLI rejects it.
	private func schemaFailures(in project: VaultProject) -> [String: [String]] {
		let draftCheck = store.schemaDraft(for: project.id) == nil ? nil : store.latestSchemaDraftEvaluation(for: project.id)?.check
		let check = draftCheck ?? store.valueChecks[project.id]
		return check.map { VaultSchemaView.failures(in: $0, environments: store.orderedEnvironmentNames(for: project)) } ?? [:]
	}

	/// ⌘S with the side panel closed: opens the review when there's a draft
	/// and nothing blocks it; returns whether it did.
	private func reviewSchemaFromPage(in project: VaultProject) -> Bool {
		guard !schemaPanelVisible, (store.schemaDraft(for: project.id)?.changeCount ?? 0) > 0, store.canEditSchema(of: project.id),
			VaultSchemaEditorFooter.blocker(store: store, projectID: project.id, item: nil)?.blocksReview != true
		else { return false }
		schemaReview = SchemaReviewTarget(projectID: project.id)
		return true
	}

	/// Moves the side panel's selection through `rows`, the table's order. A
	/// key or group being added keeps the panel: what's typed there isn't
	/// in the draft yet.
	private func moveSchemaSelection(by offset: Int, through rows: [VaultSchemaSelection]) -> Bool {
		if schemaSelection == .newKey || schemaSelection == .newGroup { return false }
		guard let next = VaultSchemaView.row(offset, from: schemaSelection, in: rows) else { return false }
		if next != schemaSelection { selectSchema(next) }
		return true
	}

	private func undoSchemaDraft(in project: VaultProject, redo: Bool) -> Bool {
		if redo {
			guard store.canRedoSchemaDraft(in: project.id) else { return false }
			store.redoSchemaDraft(in: project.id)
		} else {
			guard store.canUndoSchemaDraft(in: project.id) else { return false }
			store.undoSchemaDraft(in: project.id)
		}
		return true
	}

	/// Declares every stored key that can be declared, in one draft change.
	/// The store marks each public when a prefix makes it so.
	private func declareAll(in project: VaultProject) {
		guard store.valueChecks[project.id] != nil else { return }
		let keys = VaultStore.StoredSchemaKey.declarableTogether(store.undeclaredSchemaKeys(for: project.id))
		guard keys.count <= ProjectEnvSchemaRule.maximumKeys else { return }
		store.editSchemaDraft(in: project.id) { draft in
			draft.set(keys.map { (item: .key($0), declaration: .declared(ProjectEnvSchemaRule().json)) })
		}
	}

	/// Opens a key on the Schema page; one lpm.json doesn't declare is
	/// declared first when it can be.
	private func openSchemaRules(of key: String, in project: VaultProject) {
		mode = .schema
		let stored = store.canEditSchema(of: project.id) && store.valueChecks[project.id] != nil ? store.undeclaredSchemaKey(key, for: project.id) : nil
		let declarable = stored.map { !$0.isIgnored && $0.conflict == nil } ?? false
		if declarable { declare(key, in: project) } else { selectSchema(.key(key)) }
	}

	/// Adds a stored key to the draft with no rules yet, and opens it. The
	/// store marks it public when a prefix makes it so.
	private func declare(_ key: String, in project: VaultProject) {
		store.editSchemaDraft(in: project.id) { $0.set(.declared(ProjectEnvSchemaRule().json), for: .key(key)) }
		selectSchema(.key(key))
	}

	/// Rereads the rules once the Schema page is watching them, which picks
	/// up edits made meanwhile, and whenever lpm.json or a schema it imports
	/// changes while it does.
	private func watchSchemaFolder() async {
		guard let watch = schemaWatch else { return }
		for await _ in ProjectConfigWatcher.changes(inFolder: watch.folder, imports: watch.imports) {
			guard !Task.isCancelled else { return }
			store.reloadKeyDescriptions()
		}
	}

	private var hasUnsavedRecovery: Bool { !store.keyDrafts.orphanIDs.isEmpty }

	private var inspectorVisible: Bool {
		guard !store.isShowingAccountPage else { return false }
		if hasUnsavedRecovery { return true }
		if mode == .schema { return schemaPanelVisible }
		if mode == .projectSettings { return false }
		guard showsInspector, let project else { return false }
		return store.workspaceSnapshots[project.id] != nil
	}

	/// The Schema page's panel shows a selection while the project's rules are loaded.
	private var schemaPanelVisible: Bool {
		guard mode == .schema, schemaSelection != nil, !hasUnsavedRecovery, let project, store.selectedProjectLoadFailure == nil else { return false }
		if case .loaded? = store.keyDescriptions[project.id]?.schema { return true }
		return false
	}

	private var isOrganization: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}

	var body: some View {
		valueSearchHandling
		.onReceive(NotificationCenter.default.publisher(for: .newSecret)) { _ in presentAddSecret() }
		.onReceive(NotificationCenter.default.publisher(for: .importVariables)) { _ in presentImport() }
		.onReceive(NotificationCenter.default.publisher(for: .showProjectSettings)) { _ in
			if let project { openProjectSettings(project, focusingName: false) }
		}
		.onChange(of: store.selectedProjectId) { _, _ in resetProjectPresentation() }
		.task(id: store.selectedProjectId) { store.reloadKeyDescriptions() }
		.task(id: schemaWatch) { await watchSchemaFolder() }
		.task(id: iconWatch) {
			// Redraws the selected project's icon whenever a file it can come from changes.
			if let iconWatch { await store.projectIcons.watch(iconWatch.projectID) }
		}
		.onChange(of: store.selectedEnvironment) { _, environment in
			resetCopyPresentation()
			rawTextSaved = nil
			exportTask?.cancel()
			exportTask = nil
			exportID = nil
			mode = mode.synchronized(to: environment)
			revealedKeys.removeAll()
			shownMenu = nil
		}
		.onChange(of: mode) { _, _ in
			revealedKeys.removeAll()
			shownMenu = nil
		}
		.onChange(of: store.isShowingAccountPage) { _, showingAccount in
			shownMenu = nil
			if showingAccount { resetCopyPresentation() }
		}
		.task(id: rawTextSaved.map { RawTextSavedPhase(id: $0.id, undo: $0.undo) }) {
			guard let saved = rawTextSaved else { return }
			let timer = switch saved.undo {
			case .available, .failed: undoTimer
			case .undone: copyFeedbackTimer
			case .undoing: nil as VaultFeedbackTimer?
			}
			guard let timer else { return }
			do { try await timer.wait() } catch { return }
			guard !Task.isCancelled, rawTextSaved?.id == saved.id, rawTextSaved?.undo == saved.undo else { return }
			rawTextSaved = nil
		}
		.task(id: copyFeedback?.id) {
			guard let feedbackID = copyFeedback?.id else { return }
			do { try await copyFeedbackTimer.wait() } catch { return }
			guard !Task.isCancelled, copyFeedback?.id == feedbackID else { return }
			copyFeedback = nil
		}
		.onChange(of: store.selectedAccount) { _, _ in
			conflictTarget = nil
			shownMenu = nil
		}
		.onChange(of: publishMenuDestinations.isEmpty) { _, empty in
			if empty { shows(.publish).wrappedValue = false }
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
				isConnectSheetPresented: showConnectCLISheet,
				onPublish: { publishSession = store.makePublishSession(for: $0) },
				showsPublishMenu: shows(.publish)
			)
			.simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
			VaultHairline(color: VaultPalette.titleBarBorder)
			if !isObscured, !store.isShowingAccountPage, let warning = store.lastSyncWarnings.first {
				metadataWarningBanner(warning)
			}
			if let refreshError = store.localStateRefreshError {
				localStateRefreshBanner(refreshError)
			}
			if !isObscured, !store.isShowingAccountPage, let project, let pause = store.syncPauses[project.id] {
				syncPausedBanner(project, pause)
			}
			if !isObscured, !store.isShowingAccountPage, let project {
				companionBanners(for: project)
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
							mode: $mode,
							filter: $filter,
							searchText: $searchText,
							showsAccountSwitcher: shows(.account),
							onNewProject: { showNewProject = true },
							onCloudProjects: { showCloudProjects = true },
							onNewEnvironment: { showNewEnvironment = true },
							onProjectSettings: { openProjectSettings($0, focusingName: false) },
							onRenameProject: { openProjectSettings($0, focusingName: true) },
							onDeleteProject: { projectToDelete = $0 },
							onRenameEnvironment: beginRenameEnvironment,
							onDuplicateEnvironment: beginDuplicateEnvironment,
							onClearEnvironment: { clearEnvironmentTarget = $0 },
							onDeleteEnvironment: { deleteEnvironmentTarget = $0 }
						)
					}

					Group {
						if store.accountPage == .settings {
							VaultSettingsPage(store: store)
								.frame(maxWidth: .infinity, maxHeight: .infinity)
								.background(VaultPalette.content)
						} else if store.accountPage == .platforms {
							PlatformsView(store: store)
								.frame(maxWidth: .infinity, maxHeight: .infinity)
								.background(VaultPalette.content)
						} else if let project, mode == .projectSettings {
							VaultProjectSettingsView(
								store: store,
								project: project,
								nameFocusRequest: projectNameFocusRequest,
								onBack: { mode = .matrix },
								onDelete: { projectToDelete = project }
							)
							.id(project.id)
							.frame(maxWidth: .infinity, maxHeight: .infinity)
						} else if let failure = store.selectedProjectLoadFailure {
							VaultLoadErrorView(failure: failure, retry: retry(after: failure))
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
								storedKeyCount: store.workspaceSnapshots[project.id]?.allSecretKeys.count ?? 0,
								failures: schemaFailures(in: project),
								saveFailed: VaultSchemaEditorFooter.saveFailure(store: store, projectID: project.id) != nil,
								saving: store.savingSchemaDrafts.contains(project.id),
								blocker: draft == nil || schemaPanelVisible || rules?.schema?.overview == nil ? nil
									: VaultSchemaEditorFooter.blocker(store: store, projectID: project.id, item: nil),
								onReview: { schemaReview = SchemaReviewTarget(projectID: project.id) },
								onDiscardAll: { store.discardSchemaDraft(in: project.id) },
								onUndo: { undoSchemaDraft(in: project, redo: $0) },
								onMove: moveSchemaSelection,
								onClosePanel: {
									guard schemaPanelVisible else { return false }
									selectSchema(nil)
									return true
								},
								panelOpen: schemaPanelVisible,
								onReviewShortcut: { reviewSchemaFromPage(in: project) },
								onDeclareAll: { declareAll(in: project) },
								undeclared: store.undeclaredSchemaKeys(for: project.id),
								storedKeysChecked: store.valueChecks[project.id] != nil,
								onDeclare: { declare($0, in: project) },
								rebase: store.schemaDraftRebases[project.id],
								onDismissRebase: { store.dismissSchemaDraftRebase(in: project.id) },
								onResolveConflict: { item, keepingMine in
									store.editSchemaDraft(in: project.id) { $0.resolveConflict(item, keepingMine: keepingMine) }
								},
								smartViews: store.workspaceSnapshots[project.id].map {
									VaultSmartViewCounts(snapshot: $0,
										checks: VaultValueCheckPresentation(check: store.valueChecks[project.id], rules: nil, project: project))
								},
								onOpenSmartView: { view in
									mode = .matrix
									filter = view.filter
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
							contentView(project, snapshot: snapshot)
						} else {
							VaultWorkspaceEmptyView(
								isSearching: !searchText.isEmpty,
								hasProjects: !store.projects.isEmpty,
								onCreate: { showNewProject = true },
								onImport: { showCloudProjects = true },
								onRestore: { showBackupRestore = true }
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
								onRenamed: followRename,
								onOpenRules: { openSchemaRules(of: $0, in: project) }
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
		.environment(\.vaultSchemaKeysSuspended, shownMenu != nil)
		.background(VaultHostWindowReader(host: hostWindow))
		.dropDestination(for: URL.self) { urls, _ in importDropped(urls) } isTargeted: { isImportDropTargeted = $0 }
		.overlay {
			if isImportDropTargeted, canPresentImport, let project {
				importDropHighlight(into: project)
			}
		}
		.animation(.easeOut(duration: 0.12), value: isImportDropTargeted)
		.overlay {
			if shownMenu == .account {
				ZStack(alignment: .bottomLeading) {
					VaultMenuBackdrop { shows(.account).wrappedValue = false }

					VaultAccountSwitcher(
						store: store,
						isPresented: shows(.account)
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
		.overlayPreferenceValue(VaultPublishButtonAnchor.self) { anchor in
			if shownMenu == .publish, let anchor, !publishMenuDestinations.isEmpty {
				GeometryReader { proxy in
					let button = proxy[anchor]
					ZStack(alignment: .topLeading) {
						VaultMenuBackdrop { shows(.publish).wrappedValue = false }

						VaultPublishMenu(
							summaries: publishMenuDestinations,
							isPresented: shows(.publish),
							onPublish: { publishSession = store.makePublishSession(for: $0) },
							onPlatforms: { store.showPlatforms() }
						)
						.padding(.leading, max(8, min(button.maxX, proxy.size.width - 8) - VaultPublishMenu.width))
						.padding(.top, button.maxY + 6)
						.transition(.opacity.combined(with: .offset(y: -4)))
					}
				}
			}
		}
		.ignoresSafeArea(.container, edges: .top)
		.animation(.easeOut(duration: 0.14), value: shownMenu == .account)
		.animation(.easeOut(duration: 0.12), value: shownMenu == .publish)
	}

	/// The menus shown over the workspace, one at a time, as menus are.
	private enum WorkspaceMenu {
		case account, publish
	}

	/// Whether `menu` shows. Showing it closes the other; closing it leaves the other alone.
	private func shows(_ menu: WorkspaceMenu) -> Binding<Bool> {
		Binding(
			get: { shownMenu == menu },
			set: { shown in
				if shown {
					shownMenu = menu
				} else if shownMenu == menu {
					shownMenu = nil
				}
			})
	}

	/// The saved destinations the Publish menu lists: the selected project's, while Publish… shows.
	private var publishMenuDestinations: [PublishDestinationSummary] {
		guard let project, !store.isShowingAccountPage else { return [] }
		return store.publishDestinations[project.id] ?? []
	}

	private var workspaceSheets: some View {
		workspaceLayout
		.sheet(item: $importRequest) { request in
			EnvImportSheet(store: store, projectID: request.projectID, environment: request.environment, file: request.file)
				.vaultPrivacyProtected(isObscured)
		}
		.sheet(item: $rawTextReview) { review in
			VaultRawTextReviewSheet(store: store, review: review) { receipt, summary in
				rawTextSaved = VaultRawTextSaved(receipt: receipt, summary: summary, savedAt: Date())
			}
			.vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: $showNewProject) {
			NewVaultSheet(store: store).vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: $showBackupRestore) {
			VaultBackupRestorePresentation(store: store).vaultPrivacyProtected(isObscured)
		}
		.onChange(of: store.isUnlocked) { _, unlocked in
			if !unlocked { showBackupRestore = false }
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
		.sheet(item: $publishSession) { session in
			PublishSheet(store: store, session: session)
				.vaultPrivacyProtected(isObscured)
		}
		.sheet(isPresented: Binding(
			get: { store.valueSearch.isPresented },
			set: { if !$0 { store.valueSearch.sheetClosed() } }
		)) {
			ValueSearchSheet(store: store).vaultPrivacyProtected(isObscured)
		}
	}

	private var valueSearchHandling: some View {
		workspaceDialogs
			.onReceive(NotificationCenter.default.publisher(for: .findValue)) { _ in presentValueSearch(.find) }
			.onReceive(NotificationCenter.default.publisher(for: .findReusedValues)) { _ in presentValueSearch(.reuse) }
			.onChange(of: store.valueSearch.openRequest) { _, request in
				// One that changed the project waits for the project's reset.
				if let request, !request.changedProject { showOpenedValue(request) }
			}
	}

	private var workspaceDialogs: some View {
		workspaceSheets
		.vaultPrompt(item: $renameEnvironmentTarget) { target in
			VaultPrompt(
				symbol: "pencil",
				title: "Rename \(VaultProject.displayName(for: target.environment))",
				message: "The environment keeps its keys and values.",
				problem: environmentNameProblem(renaming: target.environment),
				placeholder: "Environment name",
				text: $environmentNameDraft,
				confirmTitle: "Rename",
				canConfirm: validEnvironmentDraft,
				confirm: renameEnvironment)
		}
		.vaultPrompt(item: $duplicateEnvironmentTarget) { target in
			VaultPrompt(
				symbol: "plus.square.on.square",
				title: "Duplicate \(VaultProject.displayName(for: target.environment))",
				message: "The copy starts with the same keys and values.",
				problem: environmentNameProblem(renaming: nil),
				placeholder: "New environment name",
				text: $environmentNameDraft,
				confirmTitle: "Duplicate",
				canConfirm: validEnvironmentDraft,
				confirm: duplicateEnvironment)
		}
		.vaultConfirmation(item: $projectToDelete) { project in
			VaultConfirmation(
				symbol: "trash",
				title: "Delete this project locally?",
				message: "Removes the project and its Keychain values from this Mac. Its folder, its lpm.json and a synced cloud copy stay.",
				subject: .init(
					mark: .project(store.projectIcons.appearance(for: project.id)), name: project.name,
					detail: project.path.isEmpty ? nil : (project.path as NSString).abbreviatingWithTildeInPath),
				actions: [.init(title: "Delete Locally") { Task { _ = await store.deleteLocalVault(project) } }])
		}
		.vaultConfirmation(item: $pauseExit) { exit in
			pauseExitConfirmation(exit)
		}
		.vaultConfirmation(item: $companionRepair) { request in
			let project = store.projects.first { $0.id == request.projectId }
			let subject = VaultConfirmation.Subject(
				mark: .project(store.projectIcons.appearance(for: request.projectId)),
				name: project?.name ?? request.projectId)
			return request.presentation.repairConfirmation(subject: subject) {
				Task { await store.repairCompanionData(projectId: request.projectId, reviewed: request.state) }
			}
		}
		.vaultConfirmation(item: $deleteEnvironmentTarget) { target in
			VaultConfirmation(
				symbol: "trash",
				title: "Delete this environment?",
				message: "The environment and its values leave this Mac's Keychain. The project's other environments stay as they are.",
				subject: environmentSubject(target),
				actions: [.init(title: "Delete Environment") { store.deleteEnvironment(from: target.projectId, name: target.environment) }])
		}
		.vaultConfirmation(item: $clearEnvironmentTarget) { target in
			VaultConfirmation(
				symbol: "eraser",
				title: "Clear every key from this environment?",
				message: "Its keys and values leave this Mac's Keychain, and the environment stays, empty. The project's other environments stay as they are.",
				subject: environmentSubject(target),
				actions: [.init(title: "Clear All Secrets") { store.clearEnvironment(in: target.projectId, name: target.environment) }])
		}
		.vaultConfirmation(item: $deleteSecretTarget) { target in
			VaultConfirmation(
				symbol: "trash",
				title: "Delete this key?",
				message: "Only \(VaultProject.displayName(for: target.environment)) is changed.",
				subject: .init(
					mark: .symbol("key"), name: target.key,
					detail: "\(VaultProject.displayName(for: target.environment)) · \(store.projects.first { $0.id == target.projectId }?.name ?? "")"),
				actions: [.init(title: "Delete Key") { deleteSecret(target) }])
		}
		.vaultConfirmation(item: Binding(
			get: { store.error.map(ShownError.init) },
			set: { if $0 == nil { store.error = nil } }
		)) { shown in
			VaultConfirmation(
				symbol: "exclamationmark.triangle",
				tone: .warning,
				title: "LPM Vault couldn't finish that",
				message: shown.message,
				cancelTitle: nil,
				actions: [.init(title: "OK") {}])
		}
		.vaultConfirmation(item: $exportNotice) { notice in
			VaultConfirmation(
				symbol: "exclamationmark.triangle",
				tone: .warning,
				title: "Exported \(notice.file), but check git",
				message: notice.warnings.joined(separator: "\n"),
				cancelTitle: nil,
				actions: [.init(title: "OK") {}])
		}
	}

	/// How a failed load is retried; never when the project's newer data
	/// stopped it, which the banner above explains and retrying can't change.
	private func retry(after failure: VaultLoadFailure) -> (() -> Void)? {
		failure.isCompanion ? nil : { store.retrySelectedProjectLoad() }
	}

	/// What `project`'s newer data means here, and what finishing an
	/// interrupted change to it did.
	@ViewBuilder
	private func companionBanners(for project: VaultProject) -> some View {
		if let state = store.projectCompanionStates[project.id],
			let presentation = CompanionStatePresentation(state, unfinished: store.projectCompanionUnfinished[project.id])
		{
			VaultCompanionBanner(
				presentation: presentation,
				isRepairing: store.isRepairingCompanionData,
				isRetrying: store.isRefreshingLocalState,
				onRepair: { companionRepair = CompanionRepairRequest(projectId: project.id, state: state, presentation: presentation) },
				onRetry: { Task { await store.refreshLocalState() } })
		}
		if let notice = store.companionNotices[project.id] {
			VaultCompanionNoticeBanner(presentation: CompanionNoticePresentation(notice)) {
				store.dismissCompanionNotice(for: project.id)
			}
		}
	}

	/// A repair of one project's damaged newer data, waiting for the person's
	/// answer, bound to the state they reviewed.
	private struct CompanionRepairRequest: Identifiable {
		let id = UUID()
		let projectId: String
		let state: CompanionEngine.Assessment
		let presentation: CompanionStatePresentation
	}

	/// An exit from a restore's sync pause for one project.
	private struct VaultSyncPauseExit: Identifiable {
		enum Choice {
			/// Replace lpm.dev's copy under this Mac's keys.
			case reconnect
			case keepOnThisMac
		}

		let projectId: String
		let choice: Choice
		var id: String { "\(projectId)/\(choice)" }
	}

	private struct ShownError: Identifiable {
		let message: String
		var id: String { message }
	}

	/// What the user should know about a finished export, such as an ignore rule git couldn't confirm.
	private struct ExportNotice: Identifiable {
		let file: String
		let warnings: [String]
		var id: String { file + warnings.joined() }
	}

	/// An environment the confirmation acts on, as the sidebar shows it: its color, its name, its keys and its project.
	private func environmentSubject(_ target: VaultEnvironmentTarget) -> VaultConfirmation.Subject {
		let project = store.projects.first { $0.id == target.projectId }
		let index = project.flatMap { store.orderedEnvironmentNames(for: $0).firstIndex(of: target.environment) } ?? 0
		let keys = project?.secretCount(for: target.environment).counted("key")
		return .init(
			mark: .environment(VaultPalette.environment(index)), name: VaultProject.displayName(for: target.environment),
			detail: [keys, project?.name].compactMap { $0 }.joined(separator: " · "))
	}

	/// Why the name typed can't be used, if it can't; a rename's own name isn't taken.
	private func environmentNameProblem(renaming current: String?) -> String? {
		let candidate = environmentNameDraft.trimmingCharacters(in: .whitespaces)
		if !candidate.isEmpty, !EnvValidation.isValidEnvironmentName(candidate) {
			return "Use 1–64 ASCII letters, numbers, dots, dashes, or underscores. Do not use __index__ or '..'."
		}
		if candidate != current, project?.environments[candidate] != nil { return "That environment already exists." }
		return nil
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

	private func syncPausedBanner(_ project: VaultProject, _ pause: VaultSyncPause) -> some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "pause.circle.fill")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.orange)
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 2) {
					Text("Sync paused · values work on this Mac")
						.font(.system(size: 12, weight: .semibold))
					Text(pause.scope == "organization"
						? VaultStore.missingSharingKeyGuidance
						: "This Mac doesn’t have the key to lpm.dev’s copy. Reconnect replaces that copy with this Mac’s values, under this Mac’s keys.")
						.font(.system(size: 11.5))
						.fixedSize(horizontal: false, vertical: true)
				}
				.foregroundStyle(VaultPalette.orangeTintText)
				.accessibilityElement(children: .combine)
				Spacer(minLength: 12)
				VaultBarButton(title: "Keep on this Mac only…", height: 24) {
					pauseExit = VaultSyncPauseExit(projectId: project.id, choice: .keepOnThisMac)
				}
				if pause.scope == "organization" {
					VaultBarButton(title: isCheckingSharingKey ? "Checking…" : "Check again", disabled: isCheckingSharingKey, height: 24) {
						checkSharingKey(for: project.id)
					}
				} else {
					VaultBarButton(title: "Reconnect…", filled: true, disabled: store.isSyncing, height: 24) {
						pauseExit = VaultSyncPauseExit(projectId: project.id, choice: .reconnect)
					}
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
			.background(VaultPalette.orangeTint)
			VaultHairline(color: VaultPalette.titleBarBorder)
		}
	}

	private func checkSharingKey(for projectId: String) {
		isCheckingSharingKey = true
		Task {
			await store.resumePausedOrganizationProject(projectId: projectId)
			isCheckingSharingKey = false
		}
	}

	private func pauseExitConfirmation(_ exit: VaultSyncPauseExit) -> VaultConfirmation {
		let project = store.projects.first { $0.id == exit.projectId }
		let name = project?.name ?? exit.projectId
		let subject = VaultConfirmation.Subject(
			mark: .project(store.projectIcons.appearance(for: exit.projectId)), name: name,
			detail: project.map { $0.secretCount.counted("key") })
		switch exit.choice {
		case .reconnect:
			return VaultConfirmation(
				symbol: "arrow.triangle.2.circlepath",
				title: "Replace lpm.dev’s copy of this project?",
				message: "This Mac can’t open lpm.dev’s copy, so this Mac’s values replace it, under this Mac’s keys. Changes made on lpm.dev or another device since the backup are lost. Other devices that sync it need this Mac’s keys, which a backup from this Mac carries. CI loses access: lpm.dev revokes the project’s read tokens and turns off its OIDC policies.",
				subject: subject,
				actions: [.init(title: "Replace and Reconnect") { Task { await store.reconnectPausedProject(projectId: exit.projectId) } }])
		case .keepOnThisMac:
			let organization = store.syncPauses[exit.projectId]?.orgSlug
			return VaultConfirmation(
				symbol: "laptopcomputer",
				tone: .standard,
				title: "Keep this project on this Mac only?",
				message: organization.map { "It leaves \($0.escapingDirectionControls) on this Mac and stops syncing. The organization’s copy on lpm.dev stays as it is." }
					?? "It stops syncing with lpm.dev. lpm.dev’s copy stays as it is, and this Mac keeps its values.",
				subject: subject,
				actions: [.init(title: "Keep on This Mac Only") { Task { await store.keepOnThisMacOnly(projectId: exit.projectId) } }])
		}
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
		guard store.canUseLocalSecrets, !store.isShowingAccountPage, let projectID = project?.id else { return }
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
		guard store.canUseLocalSecrets, !store.isShowingAccountPage,
			let current = store.selectedProject, current.id == projectID,
			let value = current.value(for: key, in: environment),
			store.clipboard.copy(ClipboardManager.dotenvText(for: [key: value]))
		else { return }
		copyFeedback = VaultCopyFeedback(target: .secret(projectID: projectID, environment: environment, key: key))
	}

	/// Copies what an inspector value field shows, after a refresh in progress
	/// publishes current values.
	private func copyValue(_ request: VaultValueCopy) {
		guard store.canUseLocalSecrets, !store.isShowingAccountPage, project?.id == request.projectID else { return }
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
		guard store.canUseLocalSecrets, !store.isShowingAccountPage,
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
		guard store.clipboard.copy(request.format.text(key: name, value: value)) else { return }
		copyFeedback = VaultCopyFeedback(target: .secret(projectID: request.projectID, environment: request.environment, key: request.key))
	}

	private func copiedEnvironment(in project: VaultProject) -> String? {
		guard case .secret(let projectID, let environment, let key) = copyFeedback?.target,
			projectID == project.id, key == selectedKey
		else { return nil }
		return environment
	}

	/// Copies the selected environment as a .env file, at once, or once a
	/// refresh in progress publishes current values.
	private func copyAll() {
		guard store.canUseLocalSecrets, !store.isShowingAccountPage, copyAllTask == nil, let project else { return }
		let context = VaultSensitiveActionContext(projectID: project.id, environment: store.selectedEnvironment)
		copyFeedback = nil
		guard store.isRefreshingLocalState else { return copyCurrentEnvironment(context) }
		let requestID = UUID()
		copyAllID = requestID
		copyAllTask = Task { @MainActor in
			defer {
				if copyAllID == requestID {
					copyAllTask = nil
					copyAllID = nil
				}
			}
			await store.waitForLocalStateRefresh()
			guard copyAllID == requestID else { return }
			copyCurrentEnvironment(context)
		}
	}

	private func copyCurrentEnvironment(_ context: VaultSensitiveActionContext) {
		guard store.canUseLocalSecrets, !store.isShowingAccountPage, context.isCurrent(in: store),
			let current = store.selectedProject,
			store.clipboard.copy(ClipboardManager.dotenvText(for: current.secrets(for: context.environment)))
		else { return }
		copyFeedback = VaultCopyFeedback(target: .all(context))
	}

	/// Copies Raw text's lines of `keys`, with their current values, at once
	/// or once a refresh in progress publishes them.
	private func copyLines(_ keys: [String]) {
		guard store.canUseLocalSecrets, !store.isShowingAccountPage, !keys.isEmpty, let project else { return }
		let context = VaultSensitiveActionContext(projectID: project.id, environment: store.selectedEnvironment)
		copyLinesTask?.cancel()
		copyLinesTask = nil
		guard store.isRefreshingLocalState else { return copyCurrentLines(keys, context) }
		copyLinesTask = Task { @MainActor in
			await store.waitForLocalStateRefresh()
			guard !Task.isCancelled else { return }
			copyLinesTask = nil
			copyCurrentLines(keys, context)
		}
	}

	private func copyCurrentLines(_ keys: [String], _ context: VaultSensitiveActionContext) {
		guard store.canUseLocalSecrets, !store.isShowingAccountPage, context.isCurrent(in: store),
			let current = store.selectedProject
		else { return }
		let lines = keys.compactMap { key in
			current.value(for: key, in: context.environment).map { EnvFileCodec.formatLine(key: key, value: $0) + "\n" }
		}
		guard !lines.isEmpty, store.clipboard.copy(lines.joined()) else { return }
		copyFeedback = VaultCopyFeedback(target: .lines(context, count: lines.count))
	}

	private func rawTextEditing(in project: VaultProject) -> VaultRawTextEditing? {
		let target = VaultEnvironmentTarget(projectId: project.id, environment: store.selectedEnvironment)
		guard let draft = store.rawTextDraft(for: target) else { return nil }
		return VaultRawTextEditing(
			draft: draft,
			characterWarnings: store.rawTextCharacterWarnings[target],
			isSaving: store.isSavingRawText(target),
			failure: rawTextFailures[target],
			onChange: { store.updateRawTextDraft(target, text: $0) },
			onCancel: {
				store.discardRawTextDraft(target)
				rawTextFailures[target] = nil
			},
			onSave: { saveRawText(target) },
			onReviewChange: { store.setRawTextReview(target, on: $0) },
			onCompare: {
				store.rebaseRawTextDraft(target)
				rawTextFailures[target] = nil
			},
			onCopy: { copyEditedText($0, in: target) },
			onFixCharacters: { store.fixRawTextCharacters(target, $0) }
		)
	}

	/// Shows what a Raw text edit changes, or saves it at once when its review
	/// is turned off; then offers to undo it for a short while.
	private func saveRawText(_ target: VaultEnvironmentTarget) {
		guard let draft = store.rawTextDraft(for: target), draft.canSave, !store.isSavingRawText(target) else { return }
		rawTextFailures[target] = nil
		rawTextSaved = nil
		copyFeedback = nil
		if draft.reviewsBeforeSaving {
			guard !hostWindow.hasAttachedSheet else { return }
			rawTextReview = store.reviewRawTextDraft(target)
			return
		}
		let summary = draft.changes.summary
		Task { @MainActor in
			switch await store.saveRawTextDraft(target) {
			case .saved(let receipt): rawTextSaved = VaultRawTextSaved(receipt: receipt, summary: summary, savedAt: Date())
			case .changed: rawTextFailures[target] = .changed
			case .unavailable: break
			case .failed(let message): rawTextFailures[target] = .failed(message)
			}
		}
	}

	private func undoRawTextSave() {
		guard var saved = rawTextSaved, saved.undo == .available else { return }
		saved.undo = .undoing
		rawTextSaved = saved
		let name = VaultProject.displayName(for: saved.receipt.environment)
		Task { @MainActor in
			let outcome = await store.undoEnvironmentChange(saved.receipt)
			guard rawTextSaved?.id == saved.id else { return }
			switch outcome {
			case .saved: rawTextSaved?.undo = .undone
			case .changed: rawTextSaved?.undo = .failed("\(name) changed after the save, so it can't be undone.")
			case .unavailable: rawTextSaved = nil
			case .failed(let message): rawTextSaved?.undo = .failed(message)
			}
		}
	}

	/// Copies what was cut or copied in Raw text's editor, as every copy of values is.
	private func copyEditedText(_ text: String, in target: VaultEnvironmentTarget) {
		guard store.isUnlocked, !text.isEmpty, store.clipboard.copy(text) else { return }
		let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
		copyFeedback = VaultCopyFeedback(target: .lines(VaultSensitiveActionContext(projectID: target.projectId,
			environment: target.environment), count: max(1, lines)))
	}

	private func copiedLineCount(in project: VaultProject) -> Int? {
		guard case .lines(let context, let count) = copyFeedback?.target,
			context.projectID == project.id, context.environment == store.selectedEnvironment
		else { return nil }
		return count
	}

	/// Whether Import opens: on a project's page, with nothing else in front of the window.
	private var canPresentImport: Bool {
		store.isUnlocked && !store.isShowingAccountPage && project != nil && importRequest == nil && !hostWindow.hasAttachedSheet
	}

	/// Opens the import sheet for the selected environment, reading `file` when one was dropped.
	private func presentImport(file: URL? = nil) {
		guard canPresentImport, let project else { return }
		store.recordUserActivity()
		shownMenu = nil
		importRequest = EnvImportRequest(projectID: project.id, environment: store.selectedEnvironment, file: file)
	}

	/// A file dropped anywhere on the window opens the import sheet reading it.
	private func importDropped(_ urls: [URL]) -> Bool {
		guard canPresentImport, case .success(let file) = EnvImportDrop.file(in: urls) else { return false }
		presentImport(file: file)
		return true
	}

	private func importDropHighlight(into project: VaultProject) -> some View {
		ZStack {
			RoundedRectangle(cornerRadius: 12)
				.fill(VaultPalette.accent.opacity(0.06))
			RoundedRectangle(cornerRadius: 12)
				.strokeBorder(VaultPalette.accent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
			Label("Import into \(project.name)", systemImage: "arrow.down.doc")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(.white)
				.padding(.horizontal, 14)
				.padding(.vertical, 9)
				.background(Capsule().fill(VaultPalette.accent))
		}
		.padding(10)
		.allowsHitTesting(false)
		.transition(.opacity)
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
				let warnings = try await store.exportEnvironment(
					projectId: context.projectID,
					environment: environment,
					to: url
				)
				guard !warnings.isEmpty, VaultTaskOwnership.owns(current: exportID, request: requestID),
					context.isCurrent(in: store)
				else { return }
				exportNotice = ExportNotice(file: url.lastPathComponent, warnings: warnings)
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

	/// Opens a project's settings, selecting it first; Rename also focuses its name.
	private func openProjectSettings(_ target: VaultProject, focusingName: Bool) {
		guard store.isUnlocked else { return }
		// Selecting another project resets the page, so it reopens on this one once selected.
		pendingProjectSettings = store.selectedProjectId == target.id ? nil : target.id
		store.openProject(id: target.id)
		guard store.selectedProjectId == target.id else {
			pendingProjectSettings = nil
			return
		}
		projectNameFocusRequest = focusingName ? UUID() : nil
		mode = .projectSettings
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
		companionRepair = nil
		importRequest = nil
		rawTextSaved = nil
		mode = pendingProjectSettings != nil && pendingProjectSettings == store.selectedProjectId ? .projectSettings : .matrix
		pendingProjectSettings = nil
		filter = .all
		environmentViewMode = .table
		selectedKey = nil
		schemaSelection = nil
		schemaReview = nil
		revealedKeys.removeAll()
		showsInspector = false
		shownMenu = nil
		conflictTarget = nil
		exportTask?.cancel()
		exportTask = nil
		exportID = nil
		resetCopyPresentation()
		if let request = store.valueSearch.openRequest, request.changedProject { showOpenedValue(request) }
	}

	private func contentView(_ project: VaultProject, snapshot: VaultWorkspaceSnapshot) -> some View {
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
			isCopyingAll: copyAllTask != nil,
			isCopiedAll: copyFeedback?.target == .all(VaultSensitiveActionContext(
				projectID: project.id, environment: store.selectedEnvironment
			)),
			canUseSecrets: store.canUseLocalSecrets,
			canEditValues: store.canEditValues(of: project.id),
			cliAccess: store.selectedProjectCliAccess,
			cliAccessContradicts: store.selectedProjectCliAccessContradicts,
			isChangingCliAccess: store.isChangingCliAccess,
			onChangeCliAccess: { access in Task { await store.changeCliAccess(to: access) } },
			onCopyAll: copyAll,
			onImport: { presentImport() },
			onExport: exportCurrentEnvironment,
			onProjectSettings: { openProjectSettings(project, focusingName: false) },
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
			onResizeColumns: { store.recordUserActivity() },
			onCopyLines: copyLines,
			copiedLineCount: copiedLineCount(in: project),
			rawEditing: rawTextEditing(in: project),
			rawEditBlocker: store.rawTextEditBlocker,
			onEditRaw: { store.beginRawTextEdit(order: $0) },
			rawSaved: rawTextSaved,
			onUndoRawSave: undoRawTextSave,
			valueSearchSummary: store.valueSearch.isPresented ? nil
				: ValueSearchWording.strip(find: store.valueSearch.find, reuse: store.valueSearch.reuse),
			onShowValueSearch: { presentValueSearch(store.valueSearch.find == nil ? .reuse : .find) },
			onClearValueSearch: { store.valueSearch.clearResults() },
			foundValues: store.valueSearch.foundEnvironments(in: project.id),
			onFindValue: { key, environment in store.valueSearch.findStoredValue(of: key, in: environment) }
		)
	}

	/// Opens the value search sheet in `mode`, unless another sheet is showing.
	private func presentValueSearch(_ mode: ValueSearchModel.Mode) {
		guard store.isUnlocked, store.valueSearch.isPresented || !hostWindow.hasAttachedSheet else { return }
		store.recordUserActivity()
		store.valueSearch.present(mode)
	}

	/// Shows the place a value search result opened: its environment, with
	/// the key selected in the inspector and nothing filtering it out.
	private func showOpenedValue(_ request: ValueSearchModel.OpenRequest) {
		guard store.selectedProjectId == request.location.projectID else { return }
		searchText = ""
		filter = .all
		mode = .environment(request.location.environment)
		selectedKey = request.location.key
		showsInspector = true
		store.valueSearch.finishOpening(request)
	}

	/// Copies a value of an unsaved edit whose project or key is gone.
	private func copyUnsavedValue(_ id: VaultKeyDraft.ID, _ environment: String) {
		guard store.isUnlocked, !store.isShowingAccountPage, store.keyDrafts.orphanIDs.contains(id),
			let value = store.keyDrafts.draft(id)?.value(in: environment),
			store.clipboard.copy(value)
		else { return }
		copyFeedback = VaultCopyFeedback(target: .unsaved(id, environment: environment))
	}

	private func discardUnsaved(_ id: VaultKeyDraft.ID) {
		resetCopyPresentation()
		store.keyDrafts.discard(id)
	}

	private func resetCopyPresentation() {
		copyLinesTask?.cancel()
		copyLinesTask = nil
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
