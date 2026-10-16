import AppKit
import Foundation
import Testing

@testable import LPMVault

@MainActor
final class RecordingQuitPresenter: VaultQuitCoordinator.Presenter {
	var canPresent = true
	private(set) var presented: [VaultQuitCoordinator.Phase] = []
	private(set) var dismissals = 0

	func present(_ coordinator: VaultQuitCoordinator) -> Bool {
		presented.append(coordinator.phase)
		return canPresent
	}

	func dismiss() {
		dismissals += 1
	}
}

@Suite("Quitting with unsaved work", .serialized)
@MainActor
struct VaultQuitCoordinatorTests {
	private struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		let presenter: RecordingQuitPresenter
		let coordinator: VaultQuitCoordinator
		let replies: Replies
	}

	@MainActor
	final class Replies {
		var values: [Bool] = []
	}

	private func makeFixture(finishingDelay: Duration = .seconds(30)) async throws -> Fixture {
		let keychain = MockKeychainService()
		keychain.envStorage["first"] = (name: "First", path: "", environments: ["default": ["TOKEN": "one", "PORT": "80"]])
		keychain.envStorage["second"] = (name: "Second", path: "", environments: ["default": ["URL": "a"]])
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		#expect(await store.loadProjects())
		store.isUnlocked = true
		#expect(await store.openProjectForSaving("first"))
		let replies = Replies()
		let presenter = RecordingQuitPresenter()
		let coordinator = VaultQuitCoordinator(store: store, presenter: presenter, finishingDelay: finishingDelay) { replies.values.append($0) }
		return Fixture(store: store, keychain: keychain, presenter: presenter, coordinator: coordinator, replies: replies)
	}

	private func edit(_ store: VaultStore, _ projectID: String, _ key: String, to value: String) throws {
		let project = try #require(store.projects.first { $0.id == projectID })
		store.keyDrafts.edit(project, key: key) { $0.setValue(value, in: "default") }
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(10)
		while !condition() {
			guard ContinuousClock.now < deadline else {
				Issue.record("Timed out")
				return
			}
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	@Test("with nothing unsaved and nothing being written, quitting goes ahead without a sheet")
	func nothingUnsaved() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.replies.values == [true] }
		#expect(fixture.presenter.presented.isEmpty)
		#expect(fixture.coordinator.phase == .idle)
	}

	@Test("unsaved edits in two projects are listed, and Save and quit saves each project's before quitting")
	func savesEveryProject() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "TOKEN", to: "two")
		try edit(store, "first", "PORT", to: "81")
		#expect(await store.openProjectForSaving("second"))
		try edit(store, "second", "URL", to: "b")
		#expect(await store.openProjectForSaving("first"))

		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.coordinator.phase == .reviewing }
		#expect(fixture.presenter.presented == [.reviewing])
		let items = fixture.coordinator.items
		#expect(items.map(\.projectName) == ["First", "Second"], "The selected project comes first")
		#expect(items.map(\.subject) == ["2 keys", "1 key"])
		#expect(items.first?.detail == "PORT, TOKEN · inspector edits")
		#expect(items.map(\.badge) == ["2 edits", "1 edit"])
		#expect(VaultQuitSheet.summary(of: items) == "3 edits in 2 projects haven't been saved to the Keychain.")
		#expect(fixture.replies.values.isEmpty)

		fixture.coordinator.saveAndQuit()
		try await waitUntil { fixture.replies.values == [true] }
		#expect(fixture.keychain.envStorage["first"]?.environments["default"] == ["TOKEN": "two", "PORT": "81"])
		#expect(fixture.keychain.envStorage["second"]?.environments["default"] == ["URL": "b"])
		#expect(fixture.presenter.dismissals == 1)
	}

	@Test("a failed save stops quitting with the reason, saves the rest, and Retry finishes")
	func failedSaveRetries() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "TOKEN", to: "two")
		#expect(await store.openProjectForSaving("second"))
		try edit(store, "second", "URL", to: "b")
		fixture.keychain.failNextSaveEnvironments = true
		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.coordinator.phase == .reviewing }
		fixture.coordinator.saveAndQuit()
		try await waitUntil { fixture.coordinator.phase == .failed }
		#expect(fixture.coordinator.failedItems.map(\.projectName) == ["Second"], "The selected project, Second, saves first and fails")
		#expect(fixture.coordinator.savedCount == 1)
		#expect(fixture.replies.values.isEmpty)
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "two")
		fixture.coordinator.saveAndQuit()
		try await waitUntil { fixture.replies.values == [true] }
		#expect(fixture.keychain.envStorage["second"]?.environments["default"] == ["URL": "b"])
	}

	@Test("Discard all quits without saving, and Cancel keeps the app open with the edits")
	func discardAndCancel() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		try edit(fixture.store, "first", "TOKEN", to: "two")

		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.coordinator.phase == .reviewing }
		fixture.coordinator.cancel()
		#expect(fixture.replies.values == [false])
		#expect(fixture.coordinator.phase == .idle)
		#expect(fixture.store.keyDrafts.editedKeys(in: "first") == ["TOKEN"])

		#expect(fixture.coordinator.shouldTerminate() == .terminateLater, "Quitting can be asked again after a cancel")
		try await waitUntil { fixture.coordinator.phase == .reviewing }
		fixture.coordinator.discardAndQuit()
		#expect(fixture.replies.values == [false, true])
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "one")
	}

	@Test("an edit to a key changed elsewhere is listed as needing review, and Save and quit saves the rest")
	func needsReview() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		let store = fixture.store
		try edit(store, "first", "TOKEN", to: "two")
		try edit(store, "first", "PORT", to: "81")
		var changed = try #require(store.projects.first { $0.id == "first" })
		changed.environments["default"]?["TOKEN"] = "changed-by-cli"
		store.projects = store.projects.map { $0.id == "first" ? changed : $0 }
		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.coordinator.phase == .reviewing }
		#expect(fixture.coordinator.items.map(\.subject) == ["1 key", "1 key needs review"])
		#expect(fixture.coordinator.needsReviewCount == 1)
		fixture.coordinator.saveAndQuit()
		try await waitUntil { fixture.replies.values == [true] }
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["PORT"] == "81")
	}

	@Test("a write already running finishes before quitting, with a sheet when it takes a moment")
	func finishesRunningWrites() async throws {
		let fixture = try await makeFixture(finishingDelay: .milliseconds(20))
		defer { fixture.store.lock() }
		let store = fixture.store
		let gate = DispatchSemaphore(value: 0)
		fixture.keychain.blockNextSaveEnvironments = { gate.wait() }
		try edit(store, "first", "TOKEN", to: "two")
		let id = VaultKeyDraft.ID(projectID: "first", key: "TOKEN")
		let save = Task { try await store.saveKeyDraft(id) }
		try await waitUntil { store.keyDrafts.draft(id)?.isSaveInFlight == true }
		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.presenter.presented == [.finishing] }
		#expect(fixture.replies.values.isEmpty)
		gate.signal()
		try await save.value
		try await waitUntil { fixture.replies.values == [true] }
		#expect(fixture.keychain.envStorage["first"]?.environments["default"]?["TOKEN"] == "two")
		#expect(fixture.presenter.dismissals == 1)
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
		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview != nil }
		store.editSchemaDraft(in: "project") {
			$0.set(.declared(try! LPMConfigJSON(parsing: Data(#"{"format":"integer"}"#.utf8), rejectDuplicateKeys: true)), for: .key("RETRY"))
		}
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		let replies = Replies()
		let presenter = RecordingQuitPresenter()
		let coordinator = VaultQuitCoordinator(store: store, presenter: presenter) { replies.values.append($0) }
		#expect(coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { coordinator.phase == .reviewing }
		#expect(coordinator.items.map(\.subject) == ["Schema draft"])
		#expect(coordinator.items.first?.detail == "1 rule change · lpm.json not written")
		#expect(VaultQuitSheet.summary(of: coordinator.items) == "A schema draft hasn't been written to lpm.json.")
		coordinator.saveAndQuit()
		try await waitUntil { replies.values == [true] }
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""RETRY""#))
	}

	@Test("without a window to ask in, unsaved edits are discarded as locking does")
	func noWindow() async throws {
		let fixture = try await makeFixture()
		defer { fixture.store.lock() }
		fixture.presenter.canPresent = false
		try edit(fixture.store, "first", "TOKEN", to: "two")
		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.replies.values == [true] }
	}

	@Test("a second quit while one is deciding is refused, and a locked vault quits at once")
	func repeatedAndLocked() async throws {
		let fixture = try await makeFixture()
		try edit(fixture.store, "first", "TOKEN", to: "two")
		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		#expect(fixture.coordinator.isQuitting)
		#expect(fixture.coordinator.shouldTerminate() == .terminateCancel)
		try await waitUntil { fixture.coordinator.phase == .reviewing }
		fixture.coordinator.cancel()
		fixture.store.lock()
		#expect(fixture.coordinator.shouldTerminate() == .terminateLater)
		try await waitUntil { fixture.replies.values == [false, true] }
	}
}
