import AppKit
import SwiftUI
import Testing
import Vision

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

		@Test("a narrow window with the inspector open keeps the key count and unsaved changes whole in the status bar")
		func narrowStatusBarKeepsEssentials() async throws {
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "a", "DATABASE_URL": "b"], "production": ["TOKEN": "c"]])
			defer { store.lock() }
			let host = try await workspace(store, size: NSSize(width: 1040, height: 700))
			defer { host.window.close() }
			try clickAt(NSPoint(x: 330, y: 700 - 197), in: host)
			#expect(try await host.waitForText("VALUES"))
			try host.enterValue("unsaved-narrow-draft")
			#expect(try await host.waitForText("1 key with unsaved changes", footer: VaultMetrics.statusBar))
			#expect(try await host.waitForText("2 of 2 keys shown", footer: VaultMetrics.statusBar))
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
			#expect(try await host.waitForText("1 key with unsaved changes", footer: VaultMetrics.statusBar))
			try selectRow(0, in: host)
			#expect(try await host.waitUntil { host.value == "draft-for-token" })
			#expect(try await host.waitForText("1 unsaved change"))
		}

		@Test("the KEY header reverses the key order in both tables, and the order is remembered")
		func keyHeaderReversesOrder() async throws {
			let domain = "lpm-key-sort-test-" + UUID().uuidString
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let (store, _) = makeStore(environments: ["default": ["ALPHA": "a", "ZULU": "z"]])
			defer { store.lock() }
			let host = try await workspace(store, defaults: defaults)
			#expect(try await waitForKeyOrder(["ALPHA", "ZULU"], in: host))

			try await clickKeyHeader(in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "descending" })
			try await host.settle()
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: host))
			#expect(try await host.waitForText("sorted Z"))

			// The environment's own table uses the same order and its header reverses it too.
			try clickAt(NSPoint(x: 70, y: 603), in: host)
			#expect(try await host.waitForText("ACTIONS"))
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: host))
			try await clickKeyHeader(in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "ascending" })
			try await host.settle()
			#expect(try await waitForKeyOrder(["ALPHA", "ZULU"], in: host))
			try await clickKeyHeader(in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "descending" })
			host.window.close()

			let reopened = try await workspace(store, defaults: defaults)
			defer { reopened.window.close() }
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: reopened))
		}

		@Test("a narrow environment table keeps its sort header legible and aligned", arguments: [false, true])
		func narrowEnvironmentSortHeader(minimumContentWidth: Bool) async throws {
			let domain = "lpm-narrow-sort-test-" + UUID().uuidString
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let (store, _) = makeStore(environments: ["default": ["ALPHA": "a", "ZULU": "z"]])
			defer { store.lock() }
			let host = try await workspace(store, size: NSSize(width: 1040, height: 700), defaults: defaults)
			defer { host.window.close() }
			try clickAt(NSPoint(x: 330, y: 503), in: host)
			#expect(try await host.waitForText("VALUES"))
			if minimumContentWidth {
				let inspector = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize inspector" })
				#expect(inspector.accessibilityPerformIncrement())
				try await host.settle()
				#expect(inspector.accessibilityPerformIncrement())
				#expect(try await host.waitUntil { inspector.accessibilityValue() as? String == "338 points" })
				try await host.settle()
			}
			try clickAt(NSPoint(x: 70, y: 503), in: host)
			try await host.settle()
			let headerRegion = CGRect(x: 0.27, y: 0.7, width: 0.43, height: 0.13)
			let keyHeader = try await host.labelFrame("KEY", region: headerRegion)
			let valueHeader = try await host.labelFrame("VALUE", region: headerRegion)
			let keyRegion = keyColumnRegion(header: keyHeader, size: host.view.bounds.size)
			#expect(try await waitForKeyOrder(["ALPHA", "ZULU"], in: host, region: keyRegion))
			let firstKey = try await keyFrame("ALPHA", in: host, region: keyRegion)
			#expect(abs(keyHeader.minX - firstKey.minX) < 3)
			#expect(valueHeader.minX - keyHeader.minX >= 150)
			try clickAt(NSPoint(x: keyHeader.midX, y: keyHeader.midY), in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "descending" })
			try await host.settle()
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: host, region: keyRegion))
		}

		@Test("rendered key order tolerates text recognition's case and glyph differences")
		func recognizedKeyOrder() {
			let lines = [
				RenderedText.Line(text: "ZuIu", bounds: CGRect(x: 0.3, y: 0.5, width: 0.1, height: 0.02), labelBounds: nil),
				RenderedText.Line(text: "alpha", bounds: CGRect(x: 0.3, y: 0.6, width: 0.1, height: 0.02), labelBounds: nil),
			]
			#expect(keysFromTop(["ALPHA", "ZULU"], lines: lines) == ["ALPHA", "ZULU"])
			#expect(keysFromTop(["ZULU", "ALPHA"], lines: lines) == ["ALPHA", "ZULU"])
			#expect(keysFromTop(["ALPHA", "ZULU"], lines: Array(lines.prefix(1))) == ["ZULU"])
			#expect(keyLine("ALPHA", lines: lines)?.bounds == lines[1].bounds)
		}

		@Test("overlapping recognition cannot establish the order of two table rows", arguments: ["merged", "same height", "overlapping"])
		func combinedKeyLineCannotProveOrder(reading: String) {
			let bounds = CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.02)
			let lines = reading == "merged"
				? [RenderedText.Line(text: "ZULU ALPHA", bounds: bounds, labelBounds: nil)]
				: [
					RenderedText.Line(text: "ZULU", bounds: bounds.offsetBy(dx: 0.1, dy: reading == "overlapping" ? 0.000001 : 0), labelBounds: nil),
					RenderedText.Line(text: "ALPHA", bounds: bounds, labelBounds: nil),
				]
			#expect(keysFromTop(["ALPHA", "ZULU"], lines: lines).isEmpty)
			#expect(keysFromTop(["ZULU", "ALPHA"], lines: lines).isEmpty)
		}

		@Test("key recognition covers rows below the rendered header and excludes the footer", arguments: [NSSize(width: 1040, height: 700), NSSize(width: 1600, height: 800)])
		func keyRecognitionFollowsHeader(size: NSSize) {
			let header = CGRect(x: 301, y: size.height - 150, width: 30, height: 12)
			let region = keyColumnRegion(header: header, size: size)
			for rowY in [header.minY - 42, CGFloat(44)] {
				let row = CGRect(x: 301 / size.width, y: rowY / size.height, width: 45 / size.width, height: 13 / size.height)
				#expect(region.contains(row))
			}
			#expect(!region.contains(CGPoint(x: header.midX / size.width, y: header.midY / size.height)))
			#expect(!region.contains(CGPoint(x: header.midX / size.width, y: 15 / size.height)))
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
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString("unsaved-removed-project", forType: .string)
			try await host.click("Copy value")
			#expect(try await host.waitUntil {
				biometric.authenticationReasons == ["Copy your unsaved value"]
					&& NSPasteboard.general.string(forType: .string) == "unsaved-removed-project"
			})
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

		/// Copy confirmations stay until `copyFeedback` ends them. Preferences such
		/// as the key order are read from and saved to `defaults`.
		private func workspace(_ store: VaultStore, size: NSSize = NSSize(width: 1600, height: 800), copyFeedback: ManualCopyFeedbackTimer = ManualCopyFeedbackTimer(), defaults: UserDefaults? = nil) async throws -> SheetTestHost<some View> {
			await store.refreshCliAccess()
			let defaults = try defaults ?? #require(UserDefaults(suiteName: "workspace-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: defaults))
				.environment(\.vaultCopyFeedbackTimer, copyFeedback.timer)
				.defaultAppStorage(defaults),
				size: size, keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			try await host.settle()
			return host
		}

		/// Clicks the KEY column header, which sits between the content header and the first row.
		private func clickKeyHeader<V: View>(in host: SheetTestHost<V>) async throws {
			let label = try await host.labelFrame("KEY", region: CGRect(x: 0.15, y: 0.75, width: 0.5, height: 0.1))
			try clickAt(NSPoint(x: label.midX, y: label.midY), in: host)
		}

		private func keysFromTop(_ keys: [String], lines: [RenderedText.Line]) -> [String] {
			let matches = keys.compactMap { key in keyLine(key, lines: lines).map { (key: key, bounds: $0.bounds) } }
				.sorted { $0.bounds.midY > $1.bounds.midY }
			guard zip(matches, matches.dropFirst()).allSatisfy({ upper, lower in upper.bounds.minY > lower.bounds.maxY }) else { return [] }
			return matches.map(\.key)
		}

		private func keyLine(_ key: String, lines: [RenderedText.Line]) -> RenderedText.Line? {
			lines.first {
				let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
				return OCRText(text).contains(key) && OCRText(key).contains(text)
			}
		}

		private func keyColumnRegion(header: CGRect, size: NSSize) -> CGRect {
			CGRect(x: (header.minX - 4) / size.width, y: VaultMetrics.statusBar / size.height,
				width: (VaultMetrics.keyColumn - 20) / size.width, height: (header.minY - VaultMetrics.statusBar) / size.height)
		}

		private func waitForKeyOrder<V: View>(_ expected: [String], in host: SheetTestHost<V>, region: CGRect? = nil) async throws -> Bool {
			let keyRegion: CGRect
			if let region {
				keyRegion = region
			} else {
				let header = try await host.labelFrame("KEY", region: CGRect(x: 0.15, y: 0.75, width: 0.5, height: 0.1))
				keyRegion = keyColumnRegion(header: header, size: host.view.bounds.size)
			}
			let deadline = ContinuousClock.now.advanced(by: .seconds(10))
			while true {
				let image = try host.snapshot(host.view)
				var readings: [String] = []
				for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
					let lines = try await RenderedText.lines(in: image, level: level, region: keyRegion)
					if keysFromTop(expected, lines: lines) == expected { return true }
					readings.append("\(level): " + lines.map { "\($0.text) at \($0.bounds)" }.joined(separator: " | "))
				}
				guard ContinuousClock.now < deadline else {
					print("Expected rendered keys \(expected) in \(keyRegion). Readings: \(readings)")
					return false
				}
				try await Task.sleep(for: .milliseconds(20))
			}
		}

		private func keyFrame<V: View>(_ key: String, in host: SheetTestHost<V>, region: CGRect) async throws -> CGRect {
			let image = try host.snapshot(host.view)
			for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
				let lines = try await RenderedText.lines(in: image, level: level, region: region)
				if let box = keyLine(key, lines: lines)?.bounds {
					return CGRect(x: box.minX * host.view.bounds.width, y: box.minY * host.view.bounds.height,
						width: box.width * host.view.bounds.width, height: box.height * host.view.bounds.height)
				}
				print("Missing key \(key) in \(region), \(level): " + lines.map { "\($0.text) at \($0.bounds)" }.joined(separator: " | "))
			}
			throw CocoaError(.coderValueNotFound)
		}

		private func resizeViews(in view: NSView) -> [VaultResizeTrackingView] {
			if let divider = view as? VaultResizeTrackingView { return [divider] }
			return view.subviews.flatMap { resizeViews(in: $0) }
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
