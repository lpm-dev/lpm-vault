import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Workspace interaction regressions", .serialized)
	@MainActor
	struct WorkspaceInteractionTests {
		@Test("inspector copy uses the latest refresh and copies what the field shows", arguments: [false, true])
		func inspectorCopyAfterRefresh(edited: Bool) async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			if edited { try host.enterValue("unsaved-workspace-draft") }
			keychain.simulateCLISet(vaultId: "workspace", environment: "default", key: "TOKEN", value: "current-cli-value")
			await store.refreshLocalState()
			try await host.settle()
			#expect(host.value == (edited ? "unsaved-workspace-draft" : "current-cli-value"))
			try host.click(.copy)
			#expect(try await host.waitUntil {
				NSPasteboard.general.string(forType: .string) == (edited ? "unsaved-workspace-draft" : "current-cli-value")
			})
			if edited { #expect(try await host.waitForText("Changed outside the editor")) }
		}

		@Test("Esc in the sidebar search stays with the search while the inspector is open")
		func escapeInSearchKeepsInspector() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			#expect(try await host.waitForText("VALUES"))
			// The search field is the topmost text field in the window.
			try host.escapeWhileEditing(fieldAt: 0, secure: false)
			try await host.settle()
			#expect(try await host.text().contains("VALUES"))
		}

		@Test("the table's key column lines up with the header when a narrow window opens the inspector", arguments: [false, true])
		func narrowTableAlignment(inspectorOpen: Bool) async throws {
			let (store, _) = makeStore(environments: [
				"default": ["TOKEN": "a", "DATABASE_URL": "b"], "staging": ["TOKEN": "c"], "production": ["DATABASE_URL": "d"],
			])
			defer { store.lock() }
			await store.refreshCliAccess()
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!)),
				size: NSSize(width: 1040, height: 700), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			try await host.settle()
			if inspectorOpen {
				try clickAt(NSPoint(x: 330, y: 700 - 197), in: host)
				#expect(try await host.waitForText("VALUES"))
			}
			let title = try await host.labelFrame("All variables")
			let keyColumn = try await host.labelFrame("KEY", region: CGRect(x: 0.25, y: 0.6, width: 0.4, height: 0.25))
			#expect(abs(keyColumn.minX - title.minX) < 3, "KEY starts at \(keyColumn.minX), the title at \(title.minX)")
		}

		@Test("unsaved edits stay with their key while the person selects other keys")
		func draftsFollowTheirKey() async throws {
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "fixture-value", "ZETA": "zeta-value"]])
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.enterValue("draft-for-token")
			try await host.settle()
			try selectRow(1, in: host)
			#expect(try await host.waitUntil { host.value == "zeta-value" })
			#expect(try await host.waitForText("UNSAVED"))
			#expect(try await host.text().contains("1 key with unsaved changes"))
			try selectRow(0, in: host)
			#expect(try await host.waitUntil { host.value == "draft-for-token" })
			#expect(try await host.waitForText("1 unsaved change"))
		}

		@Test("an edit whose environment disappears stays in its card until discarded", arguments: ["environment", "rename"])
		func removedEnvironmentKeepsEdit(removal: String) async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "default-value"], "staging": ["TOKEN": "staging-value"]], keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.enterValue("unsaved-removed-target", at: 1)
			#expect(try await host.waitForText("1 unsaved change"))
			let values = keychain.envStorage["workspace"]?.environments.removeValue(forKey: "staging")
			if removal == "rename" { keychain.envStorage["workspace"]?.environments["renamed"] = values }
			await store.refreshLocalState()
			try await host.settle()
			// The small red message is read unreliably on CI; its action and the draft's state are not.
			#expect(try await host.waitForText("Discard"))
			#expect(store.keyDrafts.draft(VaultKeyDraft.ID(projectID: "workspace", key: "TOKEN"))?.orphanedEnvironments == ["staging"])
			#expect(host.secureValues.contains("unsaved-removed-target"))
			try host.returnWhileEditing("value", modifiers: [])
			try await host.settle()
			#expect(keychain.envStorage["workspace"]?.environments["staging"] == nil)
			#expect(keychain.envStorage["workspace"]?.environments["default"]?["TOKEN"] == "default-value")
			// Kept values of a deleted environment follow the project's environments.
			try host.click(.copy, ofValueAt: removal == "rename" ? 2 : 1)
			#expect(try await host.waitUntil { NSPasteboard.general.string(forType: .string) == "unsaved-removed-target" })
			try await host.click("Discard")
			try await host.settle()
			#expect(try await !host.text().contains("deleted outside the editor"))
			#expect(!host.secureValues.contains("unsaved-removed-target"))
		}

		@Test("unsaved edits of a removed project stay recoverable, even after it returns", arguments: [false, true])
		func removedProjectKeepsEdits(hiddenInSettings: Bool) async throws {
			let keychain = MockKeychainService()
			let (store, biometric) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.enterValue("unsaved-removed-project")
			try await host.settle()
			if hiddenInSettings { store.showSettings(); try await host.settle() }
			let saved = keychain.envStorage.removeValue(forKey: "workspace")
			await store.refreshLocalState()
			try await host.settle()
			keychain.envStorage["workspace"] = saved
			await store.refreshLocalState()
			store.openProject(id: "workspace")
			#expect(try await host.waitForText("UNSAVED EDITS"))
			#expect(try await host.waitForText("deleted outside the editor"))
			try await host.click("Copy value")
			#expect(try await host.waitUntil { NSPasteboard.general.string(forType: .string) == "unsaved-removed-project" })
			#expect(biometric.authenticationReasons == ["Copy your unsaved value"])
			#expect(try await host.waitForText("Copied"))
			#expect(keychain.envStorage["workspace"]?.environments["default"]?["TOKEN"] == "fixture-value")
			try await host.click("Discard")
			try await host.settle()
			#expect(try await !host.text().contains("UNSAVED EDITS"))
			#expect(store.keyDrafts.drafts.isEmpty)
		}

		@Test("copying a recovered edit cancels when its context disappears", arguments: ["settings", "discard", "account", "lock"])
		func recoveredCopyCancelsOnContextChange(transition: String) async throws {
			let keychain = MockKeychainService()
			let (store, biometric) = makeStore(keychain: keychain)
			let gate = AsyncStream<Void>.makeStream()
			biometric.authenticateHandlers = [{
				for await _ in gate.stream { return true }
				return false
			}]
			defer { gate.continuation.finish(); store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.enterValue("draft-must-not-copy")
			try await host.settle()
			keychain.envStorage.removeValue(forKey: "workspace")
			await store.refreshLocalState()
			#expect(try await host.waitForText("UNSAVED EDITS"))
			try await host.click("Copy value")
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			#expect(biometric.authenticationReasons == ["Copy your unsaved value"])
			switch transition {
			case "settings": store.showSettings()
			case "discard": try await host.click("Discard")
			case "account": store.selectedAccount = .org("other")
			default: store.lock()
			}
			gate.continuation.yield(())
			try await host.settle()
			#expect(NSPasteboard.general.string(forType: .string) != "draft-must-not-copy")
		}

		@Test("copy all copies refreshed values when authentication reactivates the app")
		func copyAllWaitsForRefreshDuringAuthentication() async throws {
			let keychain = MockKeychainService()
			let (store, biometric) = makeStore(keychain: keychain)
			let gate = AsyncStream<Void>.makeStream()
			biometric.authenticateHandlers = [{
				for await _ in gate.stream { return true }
				return false
			}]
			defer { gate.continuation.finish(); store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await host.click("Copy all")
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			// The macOS prompt can deactivate the app; returning from it refreshes local state.
			keychain.simulateCLISet(vaultId: "workspace", environment: "default", key: "TOKEN", value: "cli-updated")
			let refresh = Task { await store.refreshLocalState() }
			gate.continuation.yield(())
			await refresh.value
			#expect(try await host.waitUntil { NSPasteboard.general.string(forType: .string) == "TOKEN=\"cli-updated\"\n" })
			#expect(try await host.waitForText("Copied"))
		}

		@Test("a failed refresh pauses secret actions behind a retry banner")
		func failedRefreshShowsRetryBanner() async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			keychain.failProjectReads = true
			await store.refreshLocalState()
			#expect(try await host.waitForText("Couldn't reload changes from the LPM CLI"))
			#expect(!store.canUseLocalSecrets)
			let view = host.view
			let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
			view.cacheDisplay(in: view.bounds, to: bitmap)
			Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "workspace-refresh-failed.png")
			keychain.failProjectReads = false
			try await host.click("Retry")
			#expect(try await host.waitUntil { store.canUseLocalSecrets })
			try await host.settle()
			#expect(try await !host.text().contains("Couldn't reload changes"))
		}

		@Test("revealed values stay revealed across a refresh")
		func revealedValuesSurviveRefresh() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await host.click("Reveal")
			#expect(try await host.waitForText("fixture-value"))
			await store.refreshLocalState()
			try await host.settle()
			#expect(try await host.text().contains("fixture-value"))
		}

		@Test("copy all keeps the toolbar stationary and confirms success")
		func copyAllFeedbackAndLayout() async throws {
			let (store, biometric) = makeStore()
			let gate = AsyncStream<Void>.makeStream()
			biometric.authenticateHandlers = [{
				for await _ in gate.stream { return true }
				return false
			}]
			defer { gate.continuation.finish(); store.lock() }
			let copyFeedback = ManualCopyFeedbackTimer()
			let host = try await workspace(store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			let revealFrame = try await host.labelFrame("Reveal")
			try await host.click("Copy all")
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			try await host.settle()
			#expect(abs(try await host.labelFrame("Reveal").minX - revealFrame.minX) < 0.75)
			gate.continuation.yield(())
			try await host.settle()
			#expect(try await host.waitForText("Copied"))
			#expect(abs(try await host.labelFrame("Reveal").minX - revealFrame.minX) < 0.75)
			copyFeedback.expire()
			#expect(try await host.waitForText("Copy all"))
		}

		@Test("inspector copy confirms success in its value card until the confirmation ends")
		func inspectorCopyFeedback() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let copyFeedback = ManualCopyFeedbackTimer()
			let host = try await workspace(store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.click(.copy)
			#expect(try await host.waitUntil { NSPasteboard.general.string(forType: .string) == "fixture-value" })
			#expect(try await host.waitForText("Copied"))
			copyFeedback.expire()
			#expect(try await host.waitForTextToDisappear("Copied"))
		}

		@Test("denied or cancelled copy all never confirms success", arguments: ["denied", "settings", "environment", "project", "lock"])
		func unsuccessfulCopyHasNoSuccessFeedback(transition: String) async throws {
			let (store, biometric) = makeStore(environments: ["default": ["TOKEN": "fixture-value"], "production": ["TOKEN": "other-value"]], additionalProject: true)
			let gate = AsyncStream<Void>.makeStream()
			biometric.authenticateHandlers = [{
				for await _ in gate.stream { return transition != "denied" }
				return false
			}]
			defer { gate.continuation.finish(); store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await host.click("Copy all")
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			switch transition {
			case "settings": store.showSettings()
			case "environment": store.selectEnvironment("production")
			case "project": store.openProject(id: "other")
			case "lock": store.lock()
			default: break
			}
			try await host.settle()
			gate.continuation.yield(())
			try await host.settle()
			#expect(try await !host.text().contains("Copied"))
			if transition == "settings" {
				store.openProject(id: "workspace")
				try await host.settle()
				#expect(try await !host.text().contains("Copied"))
			}
		}

		@Test("repeated inspector copies restart the confirmation interval")
		func repeatedCopyRestartsFeedback() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let copyFeedback = ManualCopyFeedbackTimer()
			let host = try await workspace(store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.click(.copy)
			#expect(try await host.waitUntil { copyFeedback.started == 1 })
			try host.click(.copy)
			#expect(try await host.waitUntil { copyFeedback.started == 2 })
			#expect(try await host.waitForText("Copied"))
			copyFeedback.expire()
			#expect(try await host.waitForTextToDisappear("Copied"))
		}

		@Test("a selected project never shows the selection prompt while its snapshot is pending")
		func pendingSnapshotDoesNotShowEmptySelection() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			#expect(store.workspaceSnapshots["workspace"] == nil)
			#expect(!store.isLoadingSelectedProject)
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!)),
				size: NSSize(width: 1600, height: 800), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			let initialImage = try host.snapshot(host.view)
			let lines = try await RenderedText.lines(in: initialImage, level: .accurate)
			#expect(!lines.contains { $0.text.contains("Select an env project") })
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			#expect(try await host.waitForText("All variables"))
		}

		@Test("settings removes project and environment selection while retaining navigation context", arguments: [false, true])
		func settingsHasNoProjectSelection(environmentSelected: Bool) async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			let inset: CGFloat = environmentSelected ? 29 : 12
			let rowMidY: CGFloat = environmentSelected ? 603 : 657
			if environmentSelected {
				try clickAt(NSPoint(x: 70, y: 603), in: host)
				try await host.settle()
			}
			#expect(try host.rowIsHighlighted(inset: inset, rowMidY: rowMidY))
			store.showSettings()
			try await host.settle()
			#expect(try !host.rowIsHighlighted(inset: inset, rowMidY: rowMidY))
			#expect(store.selectedProjectId == "workspace")
			store.openProject(id: "workspace")
			try await host.settle()
			#expect(!store.showAuthStatus)
		}

		private func makeStore(environments: [String: [String: String]] = ["default": ["TOKEN": "fixture-value"]], additionalProject: Bool = false, keychain: MockKeychainService = MockKeychainService()) -> (VaultStore, MockBiometricService) {
			let biometric = MockBiometricService()
			let project = VaultProject(id: "workspace", name: "Workspace", path: "",
				environments: environments)
			keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: biometric,
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			if additionalProject {
				let other = VaultProject(id: "other", name: "Other", path: "", environments: ["default": ["SECOND": "second-value"]])
				keychain.envStorage[other.id] = (name: other.name, path: "", environments: other.environments)
				store.projects.append(other)
			}
			store.openProject(id: project.id)
			return (store, biometric)
		}

		/// Copy confirmations stay until `copyFeedback` ends them.
		private func workspace(_ store: VaultStore, copyFeedback: ManualCopyFeedbackTimer = ManualCopyFeedbackTimer()) async throws -> SheetTestHost<some View> {
			await store.refreshCliAccess()
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!))
				.environment(\.vaultCopyFeedbackTimer, copyFeedback.timer),
				size: NSSize(width: 1600, height: 800), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			try await host.settle()
			return host
		}

		/// Selects the key in the matrix row at `index`, which opens the inspector.
		private func selectRow<V: View>(_ index: Int, in host: SheetTestHost<V>) throws {
			try clickAt(NSPoint(x: 330, y: 603 - CGFloat(index) * VaultMetrics.matrixRow), in: host)
		}

		private func clickAt<V: View>(_ point: NSPoint, in host: SheetTestHost<V>) throws {
			try NativeTestClick.send(to: host.window, at: point)
		}
	}
}
