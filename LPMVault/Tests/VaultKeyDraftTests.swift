import Foundation
import Observation
import Testing

@testable import LPMVault

@Suite("Key drafts")
struct VaultKeyDraftTests {
	private let environments: [String: [String: String]] = [
		"default": ["TOKEN": "dev"],
		"staging": ["TOKEN": "stg"],
		"production": [:],
	]

	private func makeDraft() -> VaultKeyDraft {
		VaultKeyDraft(projectID: "project", projectName: "Project", key: "TOKEN", environments: environments)
	}

	@Test("untouched values follow changes made elsewhere and edited ones become conflicts")
	func externalChanges() {
		var draft = makeDraft()
		draft.setValue("mine", in: "default")
		var latest = environments
		latest["default"]?["TOKEN"] = "dev-cli"
		latest["staging"]?["TOKEN"] = "stg-cli"
		draft.receive(latest)
		#expect(draft.value(in: "staging") == "stg-cli")
		#expect(draft.changedEnvironments == ["default"])
		#expect(draft.value(in: "default") == "mine")
		#expect(draft.hasConflict)
		#expect(!draft.canSave)

		draft.keepEdit(in: "default")
		#expect(!draft.hasConflict)
		#expect(draft.canSave)
		#expect(draft.keyEdit().baseline["default"] == "dev-cli")
		#expect(draft.keyEdit().values == ["default": "mine"])
	}

	@Test("using the latest value ends a conflict, and a saved value equal to the edit needs no save")
	func conflictResolution() {
		var draft = makeDraft()
		draft.setValue("mine", in: "default")
		var latest = environments
		latest["default"]?["TOKEN"] = "dev-cli"
		draft.receive(latest)
		draft.revert("default")
		#expect(draft.value(in: "default") == "dev-cli")
		#expect(!draft.isDirty)

		draft.setValue("same", in: "staging")
		latest["staging"]?["TOKEN"] = "same"
		draft.receive(latest)
		#expect(!draft.isDirty)
		#expect(!draft.hasConflict)
	}

	@Test("an edited value whose key was deleted elsewhere is kept until added again or discarded", arguments: [true, false])
	func deletedValue(addAgain: Bool) throws {
		var draft = makeDraft()
		draft.setValue("mine", in: "staging")
		var latest = environments
		latest["staging"]?.removeValue(forKey: "TOKEN")
		draft.receive(latest)
		#expect(draft.orphanedEnvironments == ["staging"])
		#expect(draft.value(in: "staging") == "mine")
		#expect(draft.hasConflict)
		#expect(!draft.isOrphaned)

		if addAgain {
			draft.readd("staging", environments: latest)
			#expect(draft.orphanedEnvironments.isEmpty)
			#expect(draft.additions == ["staging"])
			#expect(draft.canSave)
			#expect(draft.keyEdit().values == ["staging": "mine"])
			#expect(draft.keyEdit().baseline["staging"] == nil)
			#expect(try draft.keyEdit().applied(to: latest).get()["staging"] == ["TOKEN": "mine"])
		} else {
			draft.revert("staging")
			#expect(draft.value(in: "staging") == nil)
			#expect(!draft.isDirty)
		}
	}

	@Test("clean values of a key deleted elsewhere leave the draft")
	func deletedCleanValue() {
		var draft = makeDraft()
		draft.setValue("mine", in: "default")
		var latest = environments
		latest["staging"]?.removeValue(forKey: "TOKEN")
		draft.receive(latest)
		#expect(draft.value(in: "staging") == nil)
		#expect(draft.orphanedEnvironments.isEmpty)
		#expect(draft.canSave)
	}

	@Test("an addition keeps a typed value when its environment is deleted and conflicts when the key appears there")
	func additions() {
		var draft = makeDraft()
		draft.add("production")
		draft.setValue("live", in: "production")
		#expect(draft.additions == ["production"])
		#expect(draft.changedEnvironments == ["production"])

		var withKey = environments
		withKey["production"]?["TOKEN"] = "cli"
		var conflicted = draft
		conflicted.receive(withKey)
		#expect(conflicted.additions.isEmpty)
		#expect(conflicted.values["production"]?.hasExternalConflict == true)
		#expect(conflicted.value(in: "production") == "live")

		var withoutEnvironment = environments
		withoutEnvironment.removeValue(forKey: "production")
		draft.receive(withoutEnvironment)
		#expect(draft.orphanedEnvironments == ["production"])
		#expect(draft.value(in: "production") == "live")

		var empty = makeDraft()
		empty.add("production")
		empty.receive(withoutEnvironment)
		#expect(empty.values["production"] == nil)
		#expect(!empty.isDirty)
	}

	@Test("value edits of a key or project that disappeared stay recoverable", arguments: [false, true])
	func orphans(projectRemoved: Bool) {
		var draft = makeDraft()
		draft.setValue("mine", in: "default")
		var latest = environments
		for name in latest.keys { latest[name]?.removeValue(forKey: "TOKEN") }
		draft.receive(projectRemoved ? nil : latest)
		#expect(draft.isOrphaned)
		#expect(draft.value(in: "default") == "mine")
		#expect(!draft.canSave)

		// An orphan never reattaches, even when the key comes back.
		draft.receive(environments)
		#expect(draft.isOrphaned)
		#expect(draft.value(in: "default") == "mine")
	}

	@Test("a draft that only adds a key that disappeared elsewhere keeps the added values recoverable")
	func additionOfDeletedKey() {
		var draft = makeDraft()
		draft.setValue("live", in: "production")
		draft.receive(["default": [:], "staging": [:], "production": [:]])
		#expect(draft.isOrphaned)
		#expect(draft.value(in: "production") == "live")
	}

	@Test("a rename alone of a key that disappeared has nothing to recover")
	func renameOfDeletedKey() {
		var draft = makeDraft()
		draft.name = "API_TOKEN"
		draft.receive(["default": [:], "staging": [:], "production": [:]])
		#expect(!draft.isOrphaned)
		#expect(!draft.isDirty)
	}

	@Test("one value for every environment adds the key where it is missing")
	func sameValueEverywhere() throws {
		var draft = makeDraft()
		draft.setValue("shared", in: ["default", "staging", "production"])
		#expect(draft.changedEnvironments == ["default", "production", "staging"])
		#expect(draft.additions == ["production"])
		let saved = try draft.keyEdit().applied(to: environments).get()
		#expect(saved.values.allSatisfy { $0["TOKEN"] == "shared" })
	}

	@Test("counts a rename and each changed environment as unsaved changes")
	func unsavedChanges() {
		var draft = makeDraft()
		#expect(draft.unsavedChangeCount == 0)
		draft.name = "API_TOKEN"
		draft.setValue("dev-2", in: "default")
		draft.add("production")
		#expect(draft.unsavedChangeCount == 3)
		draft.revert()
		#expect(draft.unsavedChangeCount == 0)
		#expect(draft.name == "TOKEN")
		#expect(draft.values["production"] == nil)
	}

	@Test("a draft saves once at a time and holds still while saving")
	func singleFlightSave() {
		var draft = makeDraft()
		draft.setValue("dev-2", in: "default")
		let edit = draft.beginSave()
		#expect(edit == VaultKeyEdit(key: "TOKEN", newKey: "TOKEN", baseline: ["default": "dev", "staging": "stg"], values: ["default": "dev-2"]))
		#expect(draft.beginSave() == nil)
		draft.setValue("ignored", in: "default")
		draft.name = "IGNORED"
		var latest = environments
		latest["staging"]?["TOKEN"] = "cli"
		draft.receive(latest)
		#expect(draft.value(in: "default") == "dev-2")
		#expect(draft.value(in: "staging") == "stg")
		draft.finishSave()
		#expect(draft.canSave)
	}
}

@Suite("Key draft collection")
@MainActor
struct VaultKeyDraftsTests {
	private let project = VaultProject(id: "project", name: "Project", path: "", environments: [
		"default": ["TOKEN": "dev", "OTHER": "other"],
		"staging": ["TOKEN": "stg"],
	])

	@Test("keeps drafts per key and drops one that no longer differs")
	func draftsPerKey() {
		let drafts = VaultKeyDrafts()
		drafts.edit(project, key: "TOKEN") { $0.setValue("dev-2", in: "default") }
		drafts.edit(project, key: "OTHER") { $0.name = "OTHER_KEY" }
		#expect(drafts.editedKeys(in: "project") == ["TOKEN", "OTHER"])
		drafts.edit(project, key: "TOKEN") { $0.setValue("dev", in: "default") }
		#expect(drafts.draft(VaultKeyDraft.ID(projectID: "project", key: "TOKEN")) == nil)
		#expect(drafts.editedKeys(in: "project") == ["OTHER"])
		drafts.discardAll()
		#expect(drafts.drafts.isEmpty)
		#expect(drafts.editedKeysByProject.isEmpty)
	}

	@Test("typing into a draft does not republish the edited keys")
	func keystrokesDoNotRepublishSummaries() {
		let drafts = VaultKeyDrafts()
		drafts.edit(project, key: "TOKEN") { $0.setValue("d", in: "default") }
		let changed = ObservationFlag()
		withObservationTracking {
			_ = drafts.editedKeysByProject
			_ = drafts.orphanIDs
		} onChange: {
			changed.set()
		}
		drafts.edit(project, key: "TOKEN") { $0.setValue("de", in: "default") }
		drafts.edit(project, key: "TOKEN") { $0.setValue("dev-2", in: "staging") }
		#expect(!changed.isSet)
		drafts.edit(project, key: "OTHER") { $0.setValue("x", in: "default") }
		#expect(changed.isSet)
	}

	@Test("a missing project orphans its drafts and an unloaded one leaves them as they are")
	func receiveProjects() {
		let drafts = VaultKeyDrafts()
		drafts.edit(project, key: "TOKEN") { $0.setValue("dev-2", in: "default") }
		let id = VaultKeyDraft.ID(projectID: "project", key: "TOKEN")
		drafts.receive([VaultProject(metadata: project.metadata)])
		#expect(drafts.draft(id)?.value(in: "default") == "dev-2")
		#expect(drafts.orphanIDs.isEmpty)

		drafts.receive([])
		#expect(drafts.orphanIDs == [id])
		#expect(drafts.editedKeys(in: "project").isEmpty)
		drafts.discard(id)
		#expect(drafts.orphanIDs.isEmpty)
	}

	@Test("deleting a value drops its edit, and deleting the last copy ends the draft")
	func deletingValues() {
		let drafts = VaultKeyDrafts()
		let id = VaultKeyDraft.ID(projectID: "project", key: "TOKEN")
		drafts.edit(project, key: "TOKEN") {
			$0.setValue("dev-2", in: "default")
			$0.setValue("stg-2", in: "staging")
		}
		drafts.discardEdits(deleting: "TOKEN", from: "staging", in: project)
		#expect(drafts.draft(id)?.changedEnvironments == ["default"])

		var remaining = project
		remaining.environments["staging"]?.removeValue(forKey: "TOKEN")
		drafts.discardEdits(deleting: "TOKEN", from: "default", in: remaining)
		#expect(drafts.draft(id) == nil)
		drafts.discardEdits(deleting: "OTHER", from: "default", in: project)
		#expect(drafts.drafts.isEmpty)
	}

	@Test("a failed save returns the draft to editing against the latest values")
	func failedSave() {
		let drafts = VaultKeyDrafts()
		let id = VaultKeyDraft.ID(projectID: "project", key: "TOKEN")
		drafts.edit(project, key: "TOKEN") { $0.setValue("dev-2", in: "default") }
		#expect(drafts.beginSave(id) != nil)
		#expect(drafts.beginSave(id) == nil)
		var latest = project
		latest.environments["default"]?["TOKEN"] = "cli"
		drafts.finishSave(id, succeeded: false, projects: [latest])
		#expect(drafts.draft(id)?.isSaveInFlight == false)
		#expect(drafts.draft(id)?.values["default"]?.hasExternalConflict == true)

		drafts.edit(project, key: "TOKEN") { $0.keepEdit(in: "default") }
		#expect(drafts.beginSave(id) != nil)
		drafts.finishSave(id, succeeded: true, projects: [latest])
		#expect(drafts.draft(id) == nil)
		#expect(drafts.editedKeys(in: "project").isEmpty)
	}
}

@Suite("Copy formats")
struct VaultCopyFormatTests {
	@Test("each format renders the key and value for its destination")
	func formats() {
		#expect(VaultCopyFormat.value.text(key: "API_KEY", value: "a\"b") == "a\"b")
		#expect(VaultCopyFormat.dotenv.text(key: "API_KEY", value: "a\"b") == "API_KEY=\"a\\\"b\"\n")
		#expect(VaultCopyFormat.export.text(key: "API_KEY", value: "a b") == "export API_KEY=\"a b\"\n")
		#expect(VaultCopyFormat.reference.text(key: "API_KEY", value: "secret") == "process.env.API_KEY")
		#expect(VaultCopyFormat.reference.text(key: "legacy-name/x", value: "") == "process.env[\"legacy-name/x\"]")
		#expect(!VaultCopyFormat.reference.includesValue)
	}
}

private final class ObservationFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	var isSet: Bool { lock.withLock { value } }
	func set() { lock.withLock { value = true } }
}

@Suite("Key draft descriptions")
struct VaultKeyDraftDescriptionTests {
	private func makeDraft() -> VaultKeyDraft {
		VaultKeyDraft(projectID: "project", projectName: "Project", key: "TOKEN", environments: ["default": ["TOKEN": "dev"]])
	}

	@Test("a description edit counts as a change and follows the saved one until edited")
	func descriptionDraft() {
		var draft = makeDraft()
		draft.setKeyDescription("Old", saved: "Old")
		#expect(!draft.isDirty)
		draft.setKeyDescription("New", saved: "Old")
		#expect(draft.unsavedChangeCount == 1)
		#expect(draft.keyDescriptionChange == "New")
		draft.receiveKeyDescription("New")
		#expect(draft.keyDescription == nil)
		#expect(!draft.isDirty)
	}

	@Test("an edited description that changed in lpm.json is a conflict until resolved", arguments: [true, false])
	func descriptionConflict(keepMine: Bool) {
		var draft = makeDraft()
		draft.setKeyDescription("Mine", saved: "Old")
		draft.receiveKeyDescription("Theirs")
		#expect(draft.hasConflict)
		if keepMine {
			draft.keepKeyDescription()
			#expect(draft.canSave)
			#expect(draft.keyDescriptionChange == "Mine")
		} else {
			draft.revertKeyDescription()
			#expect(!draft.isDirty)
		}
	}

	@Test("revert drops the description edit with the rest")
	func revertAll() {
		var draft = makeDraft()
		draft.name = "API_TOKEN"
		draft.setKeyDescription("New", saved: "")
		draft.revert()
		#expect(!draft.isDirty)
		#expect(draft.keyDescription == nil)
	}
}
