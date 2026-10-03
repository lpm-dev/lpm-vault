import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Workspace interaction regressions", .serialized)
	@MainActor
	struct WorkspaceInteractionTests {
		@Test("refresh keeps the mounted workspace draft and copies current CLI values")
		func refreshPreservesWorkspaceDraftAndCopiesCurrentValues() async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try clickInspectorToggle(in: host)
			try clickAt(NSPoint(x: 330, y: 603), in: host)
			try await host.settle()
			try host.enterValue("unsaved-workspace-draft")
			keychain.simulateCLISet(vaultId: "workspace", environment: "default", key: "TOKEN", value: "current-cli-value")
			await store.refreshLocalState()
			try await host.settle()
			#expect(host.value == "unsaved-workspace-draft")
			#expect(try await host.waitForText("changed outside"))
			try clickAt(NSPoint(x: 1375, y: 553), in: host)
			#expect(try await host.waitUntil { NSPasteboard.general.string(forType: .string) == "TOKEN=\"current-cli-value\"\n" })
		}

		@Test("refresh cancels copy all while authentication is pending")
		func refreshCancelsPendingCopyAll() async throws {
			let (store, biometric) = makeStore()
			let gate = AsyncStream<Void>.makeStream()
			biometric.authenticateHandlers = [{
				for await _ in gate.stream { return true }
				return false
			}]
			defer { gate.continuation.finish(); store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try clickAt(NSPoint(x: 1352, y: 723.5), in: host)
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			await store.refreshLocalState()
			gate.continuation.yield(())
			try await host.settle()
			#expect(try await !host.text().contains("Copied"))
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
			let host = try await workspace(store)
			defer { host.window.close() }
			let revealFrame = try await host.labelFrame("Reveal")
			try clickAt(NSPoint(x: 1352, y: 723.5), in: host)
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			try await host.settle()
			#expect(abs(try await host.labelFrame("Reveal").minX - revealFrame.minX) < 0.75)
			gate.continuation.yield(())
			try await host.settle()
			#expect(try await host.text().contains("Copied"))
			#expect(abs(try await host.labelFrame("Reveal").minX - revealFrame.minX) < 0.75)
			#expect(try await host.waitForText("Copy all"))
		}

		@Test("inspector copy visibly confirms success without moving Reveal")
		func inspectorCopyFeedback() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try clickInspectorToggle(in: host)
			try clickAt(NSPoint(x: 330, y: 603), in: host)
			try await host.settle()
			let region = CGRect(x: 0.8, y: 0, width: 0.2, height: 1)
			let revealFrame = try await host.labelFrame("Reveal", region: region)
			try clickAt(NSPoint(x: 1375, y: 553), in: host)
			try await host.settle()
			#expect(try await host.text().contains("Copied"))
			#expect(abs(try await host.labelFrame("Reveal", region: region).minX - revealFrame.minX) < 0.75)
			try await Task.sleep(for: .seconds(2.1))
			#expect(try await !host.text().contains("Copied"))
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
			try clickAt(NSPoint(x: 1352, y: 723.5), in: host)
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
			let host = try await workspace(store)
			defer { host.window.close() }
			try clickAt(NSPoint(x: 330, y: 603), in: host)
			try await host.settle()
			try clickAt(NSPoint(x: 1375, y: 553), in: host)
			try await Task.sleep(for: .seconds(1.2))
			try clickAt(NSPoint(x: 1375, y: 553), in: host)
			try await Task.sleep(for: .seconds(1.2))
			#expect(try await host.text().contains("Copied"))
			try await Task.sleep(for: .seconds(1))
			#expect(try await !host.text().contains("Copied"))
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

		private func workspace(_ store: VaultStore) async throws -> SheetTestHost<some View> {
			await store.refreshCliAccess()
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!)),
				size: NSSize(width: 1600, height: 800), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			try await host.settle()
			return host
		}

		private func clickInspectorToggle<V: View>(in host: SheetTestHost<V>) throws {
			try clickAt(NSPoint(x: host.view.bounds.width - 129.5, y: 723.5), in: host)
		}

		private func clickAt<V: View>(_ point: NSPoint, in host: SheetTestHost<V>) throws {
			for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
				let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
					timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
					context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
				host.window.sendEvent(event)
			}
		}
	}
}
