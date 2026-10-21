import Foundation
import Testing

@testable import LPMVault

@Suite("Raw text edits in the store", .serialized)
@MainActor
struct RawTextStoreTests {
	private func makeStore(environments: [String: [String: String]] = ["default": ["A": "1", "B": "2"]])
		async throws -> (VaultStore, MockKeychainService)
	{
		let keychain = MockKeychainService()
		keychain.envStorage["p"] = (name: "Project", path: "", environments: environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		#expect(await store.loadProjects())
		store.isUnlocked = true
		#expect(await store.openProjectForSaving("p", timeout: testWaitLimit))
		return (store, keychain)
	}

	private func target(_ environment: String = "default") -> VaultEnvironmentTarget {
		VaultEnvironmentTarget(projectId: "p", environment: environment)
	}

	@Test("saving writes the edit's values as the environment's, and undoing puts them back")
	func saveAndUndo() async throws {
		let (store, keychain) = try await makeStore()
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		#expect(store.rawTextDraft(for: target())?.text == "A=1\nB=2\n")
		store.updateRawTextDraft(target(), text: "A=1\nC=3\n")
		let outcome = await store.saveRawTextDraft(target())
		let receipt = EnvironmentChangeReceipt(projectId: "p", environment: "default", before: ["A": "1", "B": "2"], after: ["A": "1", "C": "3"])
		#expect(outcome == .saved(receipt))
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "1", "C": "3"])
		#expect(store.selectedProject?.environments["default"] == ["A": "1", "C": "3"])
		#expect(store.rawTextDraft(for: target()) == nil, "A saved edit is over")
		#expect(await store.undoEnvironmentChange(receipt) == .saved)
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "1", "B": "2"])
	}

	@Test("a save finds the environment changed by the LPM CLI, writes nothing, and saves once compared with the new values")
	func changedMeanwhile() async throws {
		let (store, keychain) = try await makeStore()
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		store.updateRawTextDraft(target(), text: "A=edited\nB=2\n")
		keychain.simulateCLISet(vaultId: "p", environment: "default", key: "B", value: "from-cli")
		#expect(await store.saveRawTextDraft(target()) == .changed)
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "1", "B": "from-cli"])
		#expect(store.selectedProject?.environments["default"]?["B"] == "from-cli", "The new values are shown")
		#expect(store.rawTextDraft(for: target())?.text == "A=edited\nB=2\n", "The edit stays")
		store.rebaseRawTextDraft(target())
		#expect(store.rawTextDraft(for: target())?.changes.changed == ["A", "B"])
		#expect(await store.saveRawTextDraft(target()) == .saved(EnvironmentChangeReceipt(
			projectId: "p", environment: "default", before: ["A": "1", "B": "from-cli"], after: ["A": "edited", "B": "2"])))
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "edited", "B": "2"])
	}

	@Test("applying a review makes the changes left on, against the values it was made with, and ends the edit")
	func applyReview() async throws {
		let (store, keychain) = try await makeStore()
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		store.updateRawTextDraft(target(), text: "A=edited\nC=3\n")
		let review = try #require(store.reviewRawTextDraft(target()))
		#expect(review.changes.added == ["C"] && review.changes.changed == ["A"] && review.changes.removed == ["B"])
		#expect(await store.applyRawTextReview(review, skipping: ["B"]) == .saved(EnvironmentChangeReceipt(
			projectId: "p", environment: "default", before: ["A": "1", "B": "2"], after: ["A": "edited", "B": "2", "C": "3"])))
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "edited", "B": "2", "C": "3"])
		#expect(store.rawTextDraft(for: target()) == nil)
	}

	@Test("a review applies only to the edit and the values it was made with")
	func staleReview() async throws {
		let (store, keychain) = try await makeStore()
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		store.updateRawTextDraft(target(), text: "A=edited\nB=2\n")
		let review = try #require(store.reviewRawTextDraft(target()))
		store.updateRawTextDraft(target(), text: "A=other\nB=2\n")
		#expect(await store.applyRawTextReview(review, skipping: []) == .unavailable, "The edit changed since it was reviewed")
		let fresh = try #require(store.reviewRawTextDraft(target()))
		keychain.simulateCLISet(vaultId: "p", environment: "default", key: "B", value: "from-cli")
		#expect(await store.applyRawTextReview(fresh, skipping: []) == .changed)
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "1", "B": "from-cli"])
		#expect(store.rawTextDraft(for: target()) != nil)
		#expect(await store.applyRawTextReview(fresh, skipping: ["A"]) == .unavailable, "Leaving every change out applies nothing")
		store.updateRawTextDraft(target(), text: "A=other\nbad line\n")
		#expect(store.reviewRawTextDraft(target()) == nil, "An edit with a problem line can't be reviewed")
	}

	@Test("an edit with nothing to save, or a problem line, saves nothing")
	func unsaveable() async throws {
		let (store, keychain) = try await makeStore()
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		#expect(await store.saveRawTextDraft(target()) == .unavailable)
		store.updateRawTextDraft(target(), text: "A=2\nnot a line\n")
		#expect(await store.saveRawTextDraft(target()) == .unavailable)
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "1", "B": "2"])
	}

	@Test("unsaved key edits keep the environment from being edited as text, which would put their keys back")
	func waitsForKeyEdits() async throws {
		let (store, _) = try await makeStore()
		defer { store.lock() }
		#expect(store.rawTextEditBlocker == nil)
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "A") { $0.setValue("changed", in: "default") }
		#expect(store.rawTextEditBlocker == "Save or discard the unsaved edits of 1 key first")
		#expect(!store.beginRawTextEdit(order: ["A", "B"]))
		#expect(store.rawTextDraft(for: target()) == nil)
	}

	@Test("an edit stays while other environments are shown, and locking or another account discards it", arguments: ["lock", "account"])
	func discardedWithTheSession(ending: String) async throws {
		let (store, _) = try await makeStore(environments: ["default": ["A": "1"], "staging": ["S": "1"]])
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A"]))
		store.updateRawTextDraft(target(), text: "A=2\n")
		store.selectedEnvironment = "staging"
		store.selectedEnvironment = "default"
		#expect(store.rawTextDraft(for: target())?.text == "A=2\n")
		if ending == "lock" { store.lock() } else { store.selectedAccount = .org("other") }
		#expect(store.rawTextDraft(for: target()) == nil)
	}

	@Test("renaming an environment in the app takes its edit along, and deleting it drops the edit")
	func followsEnvironment() async throws {
		let (store, _) = try await makeStore(environments: ["default": ["A": "1"], "staging": ["S": "1"]])
		defer { store.lock() }
		store.selectedEnvironment = "staging"
		#expect(store.beginRawTextEdit(order: ["S"]))
		store.updateRawTextDraft(target("staging"), text: "S=2\n")
		store.renameEnvironment(in: "p", from: "staging", to: "qa")
		#expect(try await waitUntil { store.rawTextDraft(for: target("qa")) != nil })
		#expect(store.rawTextDraft(for: target("staging")) == nil)
		#expect(store.rawTextDraft(for: target("qa"))?.text == "S=2\n")
		#expect(store.rawTextDraft(for: target("qa"))?.target == target("qa"))
		store.deleteEnvironment(from: "p", name: "qa")
		#expect(try await waitUntil { store.rawTextDraft(for: target("qa")) == nil })
	}

	@Test("an edit that changes a value or has a problem line is unsaved work; one that changes nothing isn't")
	func unsavedWork() async throws {
		let (store, _) = try await makeStore()
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		store.updateRawTextDraft(target(), text: "A=1\nB=2\n# a note\n")
		#expect(store.unsavedWork().rawTexts.isEmpty)
		store.updateRawTextDraft(target(), text: "A=1\nB=3\n")
		#expect(store.unsavedWork().rawTexts == [.init(target: target(), projectName: "Project", summary: "1 changed", problemCount: 0,
			environmentExists: true)])
		store.updateRawTextDraft(target(), text: "A=1\nB=2\nbad line\n")
		#expect(store.unsavedWork().rawTexts.first?.problemCount == 1)
		#expect(store.hasWorkQuittingWouldLose)
	}
}
