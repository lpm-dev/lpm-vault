import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Local history", .serialized)
	@MainActor
	struct HistoryInteractionTests {
		private static let projectID = "history-ui"
		private static let sidebar = CGRect(x: 0, y: 0, width: 0.3, height: 1)
		private static let initial: [String: [String: String]] = ["production": ["API_KEY": "k1", "DB_URL": "db1"], "staging": ["API_KEY": "s1"]]
		private static let edited: [String: [String: String]] = ["production": ["API_KEY": "k2", "DB_URL": "db1"], "staging": ["API_KEY": "s1"]]

		/// The time the pages take as now, so "Today" holds whenever the tests run.
		private static let now = Date(timeIntervalSince1970: 1_793_800_000)

		/// my-app, created with `initial` and then with API_KEY in production
		/// changed from k1 to k2, both recorded a few minutes before `now`, on
		/// a Keychain in memory.
		private func makeStore(
			backend: InMemoryKeychainBackend = InMemoryKeychainBackend(), serviceName: String = "dev.lpm.vault.history-ui.\(UUID().uuidString)"
		) throws -> (VaultStore, KeychainService, MockBiometricService) {
			let service = KeychainService(testingService: serviceName, backend: backend)
			guard case .success = service.createEnvironments(
				vaultId: Self.projectID, projectName: "my-app", projectPath: "", environments: Self.initial,
				source: VaultHistorySource(.set, at: Self.now.addingTimeInterval(-600)))
			else { throw KeychainError.encodingFailed }
			guard case .success = service.applyVaultTransaction(
				project: .update(
					vaultId: Self.projectID, environments: Self.edited, source: VaultHistorySource(.editKey, at: Self.now.addingTimeInterval(-300))),
				data: [])
			else { throw KeychainError.encodingFailed }
			let biometric = MockBiometricService()
			let store = VaultStore(keychainService: service, biometricService: biometric, apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [try #require(try service.getProjectResult(vaultId: Self.projectID).get())]
			store.openProject(id: Self.projectID)
			return (store, service, biometric)
		}

		private func workspace(_ store: VaultStore) async throws -> SheetTestHost<some View> {
			let defaults = try #require(UserDefaults(suiteName: "history-interaction"))
			let now = Self.now
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults)
				.environment(\.vaultClock, VaultClock { now }),
				size: NSSize(width: 1024, height: 768), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots[Self.projectID] != nil })
			try await host.settle()
			return host
		}

		private func values(_ service: KeychainService) throws -> [String: [String: String]]? {
			try service.getProjectResult(vaultId: Self.projectID).get()?.environments
		}

		private func sheet<V: View>(of host: SheetTestHost<V>) async throws -> NSWindow {
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			return try #require(host.window.sheets.first)
		}

		private func openHistory<V: View>(_ host: SheetTestHost<V>) async throws {
			try await host.click("History", region: Self.sidebar)
			#expect(try await host.waitForText("Changes to my-app’s values on this Mac"))
			#expect(try await host.waitForText("Changed API_KEY"))
		}

		@Test("the History row shows the project's changes by day, and a change's values stay masked until revealed")
		func pageAndInspector() async throws {
			let (store, _, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await openHistory(host)
			let text = try await host.text()
			for expected in ["TODAY", "Set 3 keys", "2 changes kept on this Mac since", "All, 2", "LPM Vault, 2", "LPM CLI, 0"] {
				#expect(text.contains(expected), "Missing \(expected)")
			}

			try await host.click("Changed API_KEY")
			#expect(try await host.waitForText("CHANGE", exactly: true))
			let before = try await host.waitForElement(saying: "Before value of API_KEY")
			#expect(before.texts.contains("hidden"), "\(before.texts)")
			#expect(try await !host.text().contains("k1"))
			try await host.click("Copy the after value of API_KEY")
			try await host.click("Reveal the before value of API_KEY")
			#expect(try await host.waitForText("k1"))
			#expect(try await !host.text().contains("k2"), "only the side revealed shows, and copying showed nothing")
			let after = try await host.waitForElement(saying: "After value of API_KEY")
			#expect(after.texts.contains("hidden"), "\(after.texts)")

			try await host.click("Close change details")
			#expect(try await host.waitForTextToDisappear("k1"), "Closing the change forgets its values")
		}

		@Test("Undo This Change… reviews the undo, applies it as a new change, and offers to undo that")
		func undoThroughReview() async throws {
			let (store, service, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await openHistory(host)
			try await host.click("Changed API_KEY")
			try await host.click("Undo This Change…")
			let review = try await sheet(of: host)
			#expect(try await host.waitForText("Undo this change?", in: review))
			let said = try await host.text(in: review)
			for expected in ["CHANGED · 1", "API_KEY", "Value of API_KEY now", "current → after undo · values hidden"] {
				#expect(said.contains(expected), "Missing \(expected)")
			}
			#expect(!said.contains("k1") && !said.contains("k2"), "The review keeps values hidden")
			try await host.click("Undo 1 Key", in: review)
			#expect(try await host.waitUntil { (try? values(service)) == Self.initial })
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			#expect(try await host.waitForText("Undid 1 key"))
			#expect(try await host.waitForText("Undid the change from"), "The undo is a new change on the page")

			try await host.click("Undo")
			#expect(try await host.waitUntil { (try? values(service)) == Self.edited })
			#expect(try await host.waitForText("Put the values back as they were"))
		}

		@Test("a row switched off keeps its value, and with every row off there's nothing to roll back")
		func switchingRowsOff() async throws {
			let (store, service, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await openHistory(host)
			try await host.click("Set 3 keys")
			try await host.click("Roll Back to This Point…")
			let review = try await sheet(of: host)
			#expect(try await host.waitForText("Roll back production to", in: review))
			#expect(try await host.waitForText("This entry touched production and staging. A rollback acts on one.", in: review))
			#expect(try await host.text(in: review).contains("Roll Back 1 Key"))
			try await host.click("Apply API_KEY", in: review)
			#expect(try await host.waitForText("Nothing to roll back", in: review))
			try await host.click("Cancel", in: review)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			#expect(try values(service) == Self.edited)
		}

		@Test("Remove from History… removes the value after Touch ID, and the change then says it was removed")
		func removeAValue() async throws {
			let (store, _, biometric) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await openHistory(host)
			try await host.click("Changed API_KEY")
			try host.choose("Remove from History…", in: try await host.contextMenu(of: "Before value of API_KEY"))
			let review = try await sheet(of: host)
			#expect(try await host.waitForText("Remove this value from history?", in: review))
			let said = try await host.text(in: review)
			for expected in ["THIS KEY", "Touch ID follows.", "Current values don’t change."] {
				#expect(said.contains(expected), "Missing \(expected)")
			}
			try await host.click("Remove from 1 Place", in: review)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			#expect(biometric.confirmationReasons.contains { $0.contains("remove a value from local history") })
			#expect(store.history.selectedEntry?.action == "editKey", "The change stays selected")
			#expect(try await host.waitUntil {
				AccessibilityTree.visibleElements(in: host.window, of: host.view).contains {
					$0.says("Before value of API_KEY") && $0.texts.contains("Removed from history")
				}
			}, "The value it replaced reads as removed")
		}

		@Test("Show History on an environment opens the page filtered to it")
		func showHistoryForAnEnvironment() async throws {
			let (store, _, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try host.choose("Show History", in: try await host.contextMenu(of: ".env.staging", region: Self.sidebar))
			#expect(try await host.waitForText("Changes to my-app’s values on this Mac"))
			#expect(try await host.waitForText("Set 3 keys"))
			#expect(store.history.filter.environment == "staging")
			#expect(try await !host.text().contains("Changed API_KEY"), "The edit in production isn't staging's")
		}

		@Test("the key inspector lists the key's changes, rolls one back through a review with Undo, and Show All opens the page on the key")
		func keyInspectorHistory() async throws {
			let (store, service, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await host.click("API_KEY")
			#expect(try await host.waitForText("HISTORY", exactly: true))
			#expect(try await host.waitForText("Roll Back… API_KEY in production to its value before"))
			try await host.click("Roll Back… API_KEY in production to its value before")
			let review = try await sheet(of: host)
			#expect(try await host.waitForText("Roll back API_KEY in production to its value before", in: review))
			#expect(try await host.text(in: review).contains("Only this key changes."))
			try await host.click("Roll Back 1 Key", in: review)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			#expect(try await host.waitUntil { (try? values(service))?["production"]?["API_KEY"] == "k1" })
			#expect(try await host.waitForText("Rolled back 1 key"), "Undo is offered where the rollback was applied")
			try await host.click("Undo")
			#expect(try await host.waitUntil { (try? values(service)) == Self.edited })

			try await host.click("Show All changes to API_KEY")
			#expect(try await host.waitForText("Changes to my-app’s values on this Mac"))
			#expect(try await host.waitForText("Key API_KEY, remove filter"))
			#expect(store.history.filter.exactKey == "API_KEY")
		}

		@Test("Return doesn't apply a review that deletes an environment")
		func returnNeverDeletes() async throws {
			let (store, service, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await openHistory(host)
			try await host.click("Set 3 keys")
			try await host.click("Undo This Change…")
			let review = try await sheet(of: host)
			#expect(try await host.waitForText("Also delete the empty environment", in: review))
			let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: review.windowNumber, context: nil,
				characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
			#expect(!review.performKeyEquivalent(with: event), "no button takes Return")
			try await host.settle()
			#expect(host.window.sheets.first === review)
			#expect(try values(service) == Self.edited)
		}

		@Test("a change history didn't record shows on the page with a Dismiss button, and the sidebar warns before the page is opened")
		func notRecordedChange() async throws {
			let backend = InMemoryKeychainBackend()
			let serviceName = "dev.lpm.vault.history-ui.\(UUID().uuidString)"
			let (store, _, _) = try makeStore(backend: backend, serviceName: serviceName)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			// A newer version keeps this project's history, so this app can't record it.
			let markerAccount = try CompanionEngine.markerAccount(vaultId: Self.projectID)
			let marker = try #require(try backend.read(service: serviceName, account: markerAccount))
			var json = try #require(try JSONSerialization.jsonObject(with: marker) as? [String: Any])
			var features = try #require(json["features"] as? [String: Any])
			var history = try #require(features["history"] as? [String: Any])
			history["version"] = 2
			features["history"] = history
			json["features"] = features
			try backend.write(service: serviceName, account: markerAccount, data: try JSONSerialization.data(withJSONObject: json))
			#expect(await store.addSecret(to: Self.projectID, environment: "staging", key: "NEW", value: "x") == .success)
			let warning = try await host.waitForElement(saying: "needs attention", region: Self.sidebar)
			#expect(warning.says("History"), "\(warning.texts)")

			try await host.click("History", region: Self.sidebar)
			#expect(try await host.waitForText("This change wasn’t added to local history"))
			try await host.click("Dismiss")
			#expect(try await host.waitForTextToDisappear("This change wasn’t added to local history"))
		}

		@Test("a change made while the page shows appears on it")
		func pageFollowsNewChanges() async throws {
			let (store, _, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await openHistory(host)
			#expect(await store.addSecret(to: Self.projectID, environment: "staging", key: "NEW", value: "x") == .success)
			#expect(try await host.waitForText("Set NEW"))
		}

		@Test("Show History clears a key search the page had, along with its filter")
		func showHistoryClearsTheSearch() async throws {
			let (store, _, _) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await openHistory(host)
			try host.typeText("DB", placeholder: "Key name")
			#expect(try await host.waitUntil { store.history.filter.keyContains == "DB" })
			try host.choose("Show History", in: try await host.contextMenu(of: ".env.staging", region: Self.sidebar))
			#expect(try await host.waitUntil { store.history.filter.environment == "staging" })
			#expect(try await host.waitUntil { host.fieldText(placeholder: "Key name") == "" })
			#expect(store.history.filter.keyContains == "")
		}

		@Test("turning history off asks, then Touch ID, deletes it, and the page offers to turn it on again")
		func turningHistoryOff() async throws {
			let (store, service, biometric) = try makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try host.choose("Project Settings…", in: try await host.contextMenu(of: "my-app", region: Self.sidebar))
			#expect(try await host.waitForText("HISTORY", exactly: true))
			#expect(try await host.waitForText("2 changes kept since"))
			try await host.click("Local history")
			let question = try await sheet(of: host)
			#expect(try await host.waitForText("Turn off local history for my-app?", in: question))
			try await host.click("Turn Off and Delete", in: question)
			#expect(try await host.waitUntil { (try? service.historyStateResult(vaultId: Self.projectID).get().history) == "off" })
			#expect(biometric.confirmationReasons.contains { $0.contains("turn off local history") })
			#expect(try await host.waitForTextToDisappear("2 changes kept since"))

			try await host.click("History", region: Self.sidebar)
			#expect(try await host.waitForText("Local history is off for my-app"))
			try await host.click("Turn On")
			#expect(try await host.waitUntil { (try? service.historyStateResult(vaultId: Self.projectID).get().history) != "off" })
			#expect(try await host.waitForText("No changes kept yet"))
		}
	}
}
