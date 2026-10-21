import AppKit
import Foundation
import os
import SwiftUI
import Testing

@testable import LPMVault

@MainActor
final class RecordingQuitPresenter: VaultQuitCoordinator.Presenter {
	var canPresent = true
	private(set) var presented: [VaultQuitCoordinator.Phase] = []
	private(set) var dismissals = 0
	var isShowing: Bool { presented.count > dismissals }

	func present(_ coordinator: VaultQuitCoordinator) -> Bool {
		guard canPresent else { return false }
		presented.append(coordinator.phase)
		return true
	}

	func dismiss() {
		dismissals += 1
	}
}

/// Holds the next Keychain write until released, and says when it's waiting.
final class KeychainWriteGate: Sendable {
	private let entered = OSAllocatedUnfairLock(initialState: false)
	private let release = DispatchSemaphore(value: 0)

	func hold(_ keychain: MockKeychainService) {
		keychain.blockNextVaultTransaction = { [self] in
			entered.withLock { $0 = true }
			release.wait()
		}
	}

	var isHolding: Bool { entered.withLock { $0 } }

	func open() { release.signal() }
}

@Suite("Quitting with unsaved work", .serialized)
@MainActor
struct VaultQuitCoordinatorTests {
	@MainActor
	final class Outcome {
		var replies: [Bool] = []
		var terminations = 0
	}

	private struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		let presenter: RecordingQuitPresenter
		let coordinator: VaultQuitCoordinator
		let outcome: Outcome
	}

	private func makeFixture(timing: VaultQuitCoordinator.Timing = .init(finishingDelay: .seconds(30), projectLoadLimit: testWaitLimit)) async throws -> Fixture {
		let keychain = MockKeychainService()
		keychain.envStorage["first"] = (name: "First", path: "", environments: ["default": ["TOKEN": "one", "PORT": "80"]])
		keychain.envStorage["second"] = (name: "Second", path: "", environments: ["default": ["URL": "a"]])
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		#expect(await store.loadProjects())
		store.isUnlocked = true
		#expect(await store.openProjectForSaving("first", timeout: testWaitLimit))
		let outcome = Outcome()
		let presenter = RecordingQuitPresenter()
		let coordinator = VaultQuitCoordinator(store: store, presenter: presenter, timing: timing,
			reply: { outcome.replies.append($0) }, terminate: { outcome.terminations += 1 })
		return Fixture(store: store, keychain: keychain, presenter: presenter, coordinator: coordinator, outcome: outcome)
	}

	private func edit(_ store: VaultStore, _ projectID: String, _ key: String, to value: String) throws {
		let project = try #require(store.projects.first { $0.id == projectID })
		store.keyDrafts.edit(project, key: key) { $0.setValue(value, in: "default") }
	}

	@Test("opening a project to save it waits until it's loaded, for each project in turn")
	func opensProjects() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		for projectID in ["second", "first", "second"] {
			#expect(await fixture.store.openProjectForSaving(projectID, timeout: testWaitLimit))
			#expect(fixture.store.selectedProjectId == projectID)
			#expect(fixture.store.selectedProject?.hasLoadedEnvironments == true)
			#expect(!fixture.store.isReloadingKeyDescriptions)
		}
		#expect(await !fixture.store.openProjectForSaving("missing", timeout: testWaitLimit))
	}

	@Test("with nothing unsaved and nothing being written, quitting goes ahead at once, with no sheet")
	func nothingUnsaved() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		for sessionEnding in [false, true] {
			#expect(fixture.coordinator.shouldTerminate(sessionEnding: sessionEnding) == .terminateNow)
		}
		#expect(fixture.presenter.presented.isEmpty)
		#expect(!fixture.coordinator.isQuitting)
	}

	@Test("a quit the app asks for is cancelled while it's decided, then asked for again, which goes ahead")
	func appQuitAsksAgain() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		try edit(fixture.store, "first", "TOKEN", to: "two")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(fixture.coordinator.isQuitting)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel, "Asking again while it's decided changes nothing")
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.outcome.replies.isEmpty)
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateNow, "The quit asked for again goes ahead")
	}

	@Test("logging out waits for the decision, and one already being made answers it", arguments: [false, true])
	func sessionEndWaits(joining: Bool) async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		try edit(fixture.store, "first", "TOKEN", to: "two")
		if joining {
			#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
			#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		}
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: true) == .terminateLater)
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: true) == .terminateCancel, "A second logout's request waits on the same answer")
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		fixture.coordinator.cancel()
		#expect(fixture.outcome.replies == [false])
		#expect(fixture.outcome.terminations == 0)
		#expect(fixture.store.keyDrafts.editedKeys(in: "first") == ["TOKEN"])
	}

	@Test("unsaved edits in two projects are listed a project at a time, and Save and quit saves each before quitting")
	func savesEveryProject() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "TOKEN", to: "two")
		try edit(store, "first", "PORT", to: "81")
		#expect(await store.openProjectForSaving("second", timeout: testWaitLimit))
		try edit(store, "second", "URL", to: "b")
		#expect(await store.openProjectForSaving("first", timeout: testWaitLimit))

		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		#expect(fixture.presenter.presented == [.reviewing])
		let items = fixture.coordinator.items
		#expect(items.map(\.projectName) == ["First", "Second"], "The selected project comes first")
		#expect(items.map(\.subject) == ["2 keys", "1 key"])
		#expect(items.first?.detail == "PORT, TOKEN · inspector edits")
		#expect(items.map(\.badge) == ["2 edits", "1 edit"])
		#expect(VaultQuitSheet.summary(of: items) == "3 edits in 2 projects haven't been saved to the Keychain.")

		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.keychain.envStorage["first"]?.environments["default"] == ["TOKEN": "two", "PORT": "81"])
		#expect(fixture.keychain.envStorage["second"]?.environments["default"] == ["URL": "b"])
		#expect(fixture.presenter.dismissals == 1)
	}

	@Test("a project's keys, the keys it can't save and its schema draft are listed together, so it opens once")
	func projectRowsTogether() {
		let first = VaultUnsavedWork.KeyEdit(id: .init(projectID: "a", key: "TOKEN"), edits: 1)
		let second = VaultUnsavedWork.KeyEdit(id: .init(projectID: "b", key: "URL"), edits: 2)
		let review = VaultUnsavedWork.KeyEdit(id: .init(projectID: "a", key: "PORT"), edits: 1)
		let sheet = VaultUnsavedWork.OpenSheet(id: UUID(), projectID: "b", projectName: "B", title: "Add variable", detail: "NEW_KEY")
		let work = VaultUnsavedWork(
			keyEdits: [
				.init(projectID: "a", projectName: "A", saveable: [first], needsReview: [review]),
				.init(projectID: "b", projectName: "B", saveable: [second], needsReview: []),
			],
			schemaDrafts: [.init(projectID: "a", projectName: "A", changeCount: 2), .init(projectID: "b", projectName: "B", changeCount: 1)],
			openSheets: [sheet],
			projectOrder: ["a", "b"]
		)
		let items = VaultQuitCoordinator.items(for: work)
		#expect(items.map(\.id) == ["keys:a", "review:a", "schema:a", "keys:b", "schema:b", "sheet:" + sheet.id.uuidString])
		#expect(VaultQuitSheet.summary(of: items) == "4 edits in 2 projects haven't been saved to the Keychain, 2 schema drafts haven't been written to lpm.json, and a sheet is still open.",
			"An edit that needs a review counts once")
		#expect(items.last?.subject == "Add variable")
		#expect(items.last?.detail == "NEW_KEY")
	}

	@Test("a key that fails leaves the project's other keys to be saved, and Retry tries only it")
	func failedKeyLeavesOthers() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "PORT", to: "81")
		try edit(store, "first", "TOKEN", to: "two")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		fixture.keychain.nextVaultTransactionError = .unexpectedStatus(-25293)
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.coordinator.phase == .failed })
		let items = fixture.coordinator.items
		#expect(items.map(\.state.isSaved) == [true, false])
		#expect(items.map(\.detail) == ["TOKEN · inspector edit", "PORT · inspector edit"])
		guard case .failed(let reason) = items.last?.state else {
			Issue.record("PORT didn't fail")
			return
		}
		#expect(reason.hasPrefix("PORT couldn't be saved: "))
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "two")
		#expect(fixture.outcome.terminations == 0)
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.keychain.envStorage["first"]?.environments["default"] == ["TOKEN": "two", "PORT": "81"])
	}

	@Test("a failed save stops quitting with each row's reason, saves the other projects, and Retry finishes")
	func failedSaveRetries() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "TOKEN", to: "two")
		#expect(await store.openProjectForSaving("second", timeout: testWaitLimit))
		try edit(store, "second", "URL", to: "b")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		fixture.keychain.nextVaultTransactionError = .unexpectedStatus(-25293)
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.coordinator.phase == .failed })
		#expect(fixture.coordinator.failedItems.map(\.projectName) == ["Second"], "The selected project, Second, saves first and fails")
		#expect(fixture.coordinator.savedCount == 1)
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "two")
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.keychain.envStorage["second"]?.environments["default"] == ["URL": "b"])
	}

	@Test("a key that changed elsewhere while it was being saved isn't counted as saved, and quitting waits for the person")
	func changedWhileSaving() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "PORT", to: "81")
		try edit(store, "first", "TOKEN", to: "two")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		// The CLI changes TOKEN after the list was shown; PORT's save reads it back, before TOKEN's turn.
		fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] = "changed-by-cli"
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.coordinator.phase == .failed })
		#expect(fixture.outcome.terminations == 0)
		#expect(fixture.coordinator.items.map(\.subject) == ["1 key", "1 key needs review"])
		#expect(fixture.coordinator.failedItems.isEmpty)
		#expect(fixture.store.keyDrafts.editedKeys(in: "first") == ["TOKEN"])
		fixture.coordinator.discardAndQuit()
		#expect(fixture.outcome.terminations == 1)
	}

	@Test("Cancel while saving stops after the key being written, and a new quit waits for that write")
	func cancelWhileSaving() async throws {
		let fixture = try await makeFixture(timing: .init(finishingDelay: .milliseconds(10), projectLoadLimit: testWaitLimit))
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "PORT", to: "81")
		try edit(store, "first", "TOKEN", to: "two")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		let gate = KeychainWriteGate()
		gate.hold(fixture.keychain)
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { gate.isHolding })
		fixture.coordinator.cancel()
		#expect(fixture.coordinator.phase == .idle)
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .finishing })
		#expect(fixture.coordinator.items.isEmpty, "The new quit waits for PORT's write before listing anything")
		gate.open()
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["PORT"] == "81")
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "one", "TOKEN wasn't saved after Cancel")
		#expect(fixture.coordinator.items.map(\.detail) == ["TOKEN · inspector edit"])
		fixture.coordinator.cancel()
		#expect(fixture.outcome.terminations == 0)
	}

	@Test("Discard all quits without saving, and Cancel keeps the app open with the edits")
	func discardAndCancel() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		try edit(fixture.store, "first", "TOKEN", to: "two")

		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		fixture.coordinator.cancel()
		#expect(fixture.outcome.terminations == 0)
		#expect(fixture.coordinator.phase == .idle)
		#expect(!fixture.coordinator.isQuitting)
		#expect(fixture.store.keyDrafts.editedKeys(in: "first") == ["TOKEN"])

		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel, "Quitting can be asked again after a cancel")
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		fixture.coordinator.discardAndQuit()
		#expect(fixture.outcome.terminations == 1)
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "one")
	}

	@Test("an edit to a key changed elsewhere is listed as needing review, counted once, and Save and quit saves the rest")
	func needsReview() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "TOKEN", to: "two")
		try edit(store, "first", "PORT", to: "81")
		var changed = try #require(store.projects.first { $0.id == "first" })
		changed.environments["default"]?["TOKEN"] = "changed-by-cli"
		store.projects = store.projects.map { $0.id == "first" ? changed : $0 }
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		#expect(fixture.coordinator.items.map(\.subject) == ["1 key", "1 key needs review"])
		#expect(fixture.coordinator.needsReviewCount == 1)
		#expect(VaultQuitSheet.summary(of: fixture.coordinator.items) == "2 edits in 1 project haven't been saved to the Keychain.")
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["PORT"] == "81")
	}

	@Test("a write already running finishes before quitting, with a sheet when it takes a moment")
	func finishesRunningWrites() async throws {
		let fixture = try await makeFixture(timing: .init(finishingDelay: .milliseconds(20), projectLoadLimit: testWaitLimit))
		defer { fixture.store.lock() }
		let store = fixture.store
		let gate = KeychainWriteGate()
		gate.hold(fixture.keychain)
		try edit(store, "first", "TOKEN", to: "two")
		let id = VaultKeyDraft.ID(projectID: "first", key: "TOKEN")
		let save = Task { try await store.saveKeyDraft(id) }
		#expect(try await waitUntil { gate.isHolding })
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.presenter.presented == [.finishing] })
		#expect(fixture.outcome.terminations == 0)
		gate.open()
		try await save.value
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "two")
		#expect(fixture.presenter.dismissals == 1)
	}

	@Test("a write that takes too long offers to quit without it, and keeps waiting until then")
	func overdueWrite() async throws {
		let fixture = try await makeFixture(timing: .init(finishingDelay: .milliseconds(10), overdueAfter: .milliseconds(50), projectLoadLimit: testWaitLimit))
		defer { fixture.store.lock() }
		let gate = KeychainWriteGate()
		gate.hold(fixture.keychain)
		let added = Task { await fixture.store.addSecret(to: "first", environment: "default", key: "ADDED", value: "v") }
		#expect(try await waitUntil { gate.isHolding })
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.isFinishingOverdue })
		#expect(fixture.coordinator.phase == .finishing)
		fixture.coordinator.discardAndQuit()
		#expect(fixture.outcome.terminations == 1)
		gate.open()
		_ = await added.value
	}

	@Test("an unsaved schema draft is listed as its own row and written to lpm.json before quitting")
	func savesSchemaDraft() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "quit-schema-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let environments = ["default": ["PORT": "3000", "RETRY": "2"]]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil })
		defer { store.lock() }
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		#expect(try await waitUntil { store.keyDescriptions["project"]?.schema?.overview != nil })
		store.editSchemaDraft(in: "project") {
			$0.set(.declared(try! LPMConfigJSON(parsing: Data(#"{"format":"integer"}"#.utf8), rejectDuplicateKeys: true)), for: .key("RETRY"))
		}
		#expect(try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil })
		let outcome = Outcome()
		let coordinator = VaultQuitCoordinator(store: store, presenter: RecordingQuitPresenter(), timing: .init(projectLoadLimit: testWaitLimit),
			reply: { outcome.replies.append($0) }, terminate: { outcome.terminations += 1 })
		#expect(coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { coordinator.phase == .reviewing })
		#expect(coordinator.items.map(\.subject) == ["Schema draft"])
		#expect(coordinator.items.first?.detail == "1 rule change · lpm.json not written")
		#expect(VaultQuitSheet.summary(of: coordinator.items) == "A schema draft hasn't been written to lpm.json.")
		coordinator.saveAndQuit()
		#expect(try await waitUntil { outcome.terminations == 1 })
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""RETRY""#))
	}

	@Test("an unsaved Project Settings edit is listed, saved before quitting, and its failure says why")
	func savesProjectSettings() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let project = try #require(fixture.store.projects.first { $0.id == "first" })
		#expect(fixture.store.editProjectSettings(of: project) { $0.name = "first-renamed" })
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel, "An unsaved name is something to lose")
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		#expect(fixture.coordinator.items.map(\.subject) == ["Project settings"])
		#expect(fixture.coordinator.items.first?.detail == "Name first-renamed · not saved")
		#expect(VaultQuitSheet.summary(of: fixture.coordinator.items) == "Project settings for 1 project haven't been saved.")
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.keychain.envStorage["first"]?.name == "first-renamed")
		#expect(fixture.store.projectSettingsDrafts.isEmpty)
	}

	@Test("a Project Settings edit that can't be saved stops quitting with the reason")
	func projectSettingsFailure() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let project = try #require(fixture.store.projects.first { $0.id == "first" })
		#expect(fixture.store.editProjectSettings(of: project) { $0.name = "   " })
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.coordinator.phase == .failed })
		#expect(fixture.coordinator.failedItems.first?.state == .failed("Enter a name for the project."))
		#expect(fixture.outcome.terminations == 0)
		#expect(!fixture.store.projectSettingsDrafts.isEmpty, "The edit stays")
		fixture.coordinator.cancel()
	}

	@Test("what an open sheet holds is listed, and quitting asks about it alone")
	func openSheetWork() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let sheet = VaultUnsavedWork.OpenSheet(id: UUID(), projectID: "first", projectName: "First", title: "Add variable", detail: "NEW_KEY")
		fixture.store.holdSheetWork(sheet)
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		#expect(fixture.coordinator.items.map(\.subject) == ["Add variable"])
		#expect(fixture.coordinator.needsReviewCount == 1)
		fixture.coordinator.cancel()
		fixture.store.releaseSheetWork(sheet.id)
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateNow)
	}

	@Test("without a window to ask in, the edits stay and the app stays open", arguments: [false, true])
	func noWindow(sessionEnding: Bool) async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		fixture.presenter.canPresent = false
		try edit(fixture.store, "first", "TOKEN", to: "two")
		_ = fixture.coordinator.shouldTerminate(sessionEnding: sessionEnding)
		#expect(try await waitUntil { !fixture.coordinator.isQuitting })
		#expect(fixture.outcome.terminations == 0)
		#expect(fixture.outcome.replies == (sessionEnding ? [false] : []))
		#expect(fixture.store.keyDrafts.editedKeys(in: "first") == ["TOKEN"])
	}

	@Test("locking while the sheet is up takes the list away, and quitting goes ahead once writes finish")
	func lockWhileDeciding() async throws {
		let fixture = try await makeFixture()
		try edit(fixture.store, "first", "TOKEN", to: "two")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		#expect(fixture.presenter.isShowing)
		fixture.store.lock()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(!fixture.presenter.isShowing)
		#expect(fixture.coordinator.items.isEmpty)
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "one")
	}

	@Test("an environment edited as Raw text is listed and saved with the rest; one with a problem line is left for quitting to discard")
	func savesRawText() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		#expect(store.beginRawTextEdit(order: ["PORT", "TOKEN"]))
		store.updateRawTextDraft(VaultEnvironmentTarget(projectId: "first", environment: "default"), text: "PORT=81\nTOKEN=one\n")
		#expect(await store.openProjectForSaving("second", timeout: testWaitLimit))
		#expect(store.beginRawTextEdit(order: ["URL"]))
		store.updateRawTextDraft(VaultEnvironmentTarget(projectId: "second", environment: "default"), text: "URL=b\nbad key=1\n")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		let rows = fixture.coordinator.items.map { "\($0.projectName) · \($0.subject) · \($0.detail)" }
		#expect(rows == ["Second · .env as Raw text · 1 changed · not saved", "First · .env as Raw text · 1 changed · not saved"])
		#expect(fixture.coordinator.items.first?.state == .needsReview("Fix its problem line in Raw text, or quitting discards it."))
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.outcome.terminations == 1 })
		#expect(fixture.keychain.envStorage["first"]?.environments["default"] == ["PORT": "81", "TOKEN": "one"])
		#expect(fixture.keychain.envStorage["second"]?.environments["default"] == ["URL": "a"])
	}

	@Test("a Raw text edit the LPM CLI changed under it isn't written over, and quitting waits")
	func rawTextChangedElsewhere() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		#expect(fixture.store.beginRawTextEdit(order: ["PORT", "TOKEN"]))
		fixture.store.updateRawTextDraft(VaultEnvironmentTarget(projectId: "first", environment: "default"), text: "PORT=81\nTOKEN=one\n")
		#expect(fixture.coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		#expect(try await waitUntil { fixture.coordinator.phase == .reviewing })
		fixture.keychain.simulateCLISet(vaultId: "first", environment: "default", key: "TOKEN", value: "from-cli")
		fixture.coordinator.saveAndQuit()
		#expect(try await waitUntil { fixture.coordinator.phase == .failed })
		#expect(fixture.coordinator.items.first?.state
			== .needsReview("It changed elsewhere since the edit; compare it in Raw text. Quitting discards it."))
		#expect(fixture.keychain.envStorage["first"]?.environments["default"] == ["PORT": "80", "TOKEN": "from-cli"])
		#expect(fixture.outcome.terminations == 0)
		fixture.coordinator.cancel()
	}
}

@Suite("Quit sheet with many projects")
@MainActor
struct VaultQuitSheetSizeTests {
	@Test("hundreds of projects with unsaved edits keep the sheet the height of a few rows, building only those shown")
	func manyRows() async throws {
		let keychain = MockKeychainService()
		let count = 500
		for index in 0..<count {
			keychain.envStorage["project-\(index)"] = (name: "Project \(index)", path: "", environments: ["default": ["TOKEN": "one"]])
		}
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		#expect(await store.loadProjects())
		store.isUnlocked = true
		defer { store.lock() }
		for project in store.projects { store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") } }
		let coordinator = VaultQuitCoordinator(store: store, presenter: RecordingQuitPresenter(), timing: .init(projectLoadLimit: testWaitLimit), terminate: {})
		#expect(coordinator.shouldTerminate(sessionEnding: false) == .terminateCancel)
		try #require(try await waitUntil { coordinator.phase == .reviewing })
		#expect(coordinator.items.count == count)
		let view = NSHostingView(rootView: VaultQuitSheet(coordinator: coordinator))
		let elapsed = ContinuousClock().measure { view.layoutSubtreeIfNeeded() }
		let height = view.fittingSize.height
		#expect(height < 700, "The sheet is \(height) points tall; laying it out took \(elapsed)")
		coordinator.cancel()
	}
}

extension VaultQuitCoordinator.ItemState {
	var isSaved: Bool { self == .saved }
}
