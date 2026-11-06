import Foundation
import Testing

@testable import LPMVault

@Suite("What publish destinations follow after a rollback")
struct HistoryRollbackFollowTests {
	/// `live` goes back to `production`, where `NEW` goes back to `OLD`, and
	/// `preview`, which didn't exist at the point, is offered for deletion.
	private func plan() throws -> HistoryEngine.Plan {
		let json = """
			{"kind": "undo", "point": {"entry": "e", "side": "after", "time": 1}, "generation": 1, "fingerprint": "f",
			 "environments": [
			  {"current": "live", "target": "production", "recreates": false, "offersDeletion": false, "renames": true,
			   "unnamedKeys": null, "rows": [
			    {"key": "NEW", "change": "removed", "changes": true, "current": 1, "gaps": [], "linked": ["OLD"]},
			    {"key": "OLD", "change": "added", "changes": true, "target": 2, "gaps": [], "linked": ["NEW"]},
			    {"key": "PORT", "change": "changed", "changes": true, "current": 3, "target": 4, "gaps": [], "linked": []}]},
			  {"current": "preview", "target": null, "recreates": false, "offersDeletion": true, "renames": false,
			   "unnamedKeys": null, "rows": [
			    {"key": "A", "change": "removed", "changes": true, "current": 5, "gaps": [], "linked": []}]}]}
			"""
		return try JSONDecoder().decode(HistoryEngine.Plan.self, from: Data(json.utf8))
	}

	@Test("applied whole, it deletes, renames environments and renames keys under their names after it")
	func appliedWhole() throws {
		let follow = HistoryRollbackFollow(plan: try plan(), skipped: [], keepEmpty: [])
		#expect(follow.deletedEnvironments == ["preview"])
		#expect(follow.renamedEnvironments == ["live": "production"])
		#expect(follow.renamedKeys == [.init(environment: "production", from: "NEW", to: "OLD")])
	}

	@Test("a renamed key switched off on either row isn't followed, and the environment's name still is")
	func skippedRename() throws {
		for row in [0, 1] {
			let follow = HistoryRollbackFollow(plan: try plan(), skipped: [HistoryRollbackSkip(environment: 0, row: row)], keepEmpty: [])
			#expect(follow.renamedKeys.isEmpty)
			#expect(follow.renamedEnvironments == ["live": "production"])
		}
	}

	@Test("an environment kept, or left with a key, isn't deleted")
	func keptEnvironment() throws {
		#expect(HistoryRollbackFollow(plan: try plan(), skipped: [], keepEmpty: [1]).deletedEnvironments.isEmpty)
		#expect(HistoryRollbackFollow(plan: try plan(), skipped: [HistoryRollbackSkip(environment: 1, row: 0)], keepEmpty: [])
			.deletedEnvironments.isEmpty)
	}

	@Test("it's applied once every name and deletion shows, including names that swap")
	func applied() throws {
		let follow = HistoryRollbackFollow(plan: try plan(), skipped: [], keepEmpty: [])
		#expect(follow.isApplied(to: ["production": ["OLD": "1", "PORT": "4"]]))
		#expect(!follow.isApplied(to: ["live": ["NEW": "1"], "preview": ["A": "5"]]))
		#expect(!follow.isApplied(to: ["production": ["NEW": "1"]]))
		let swap = HistoryRollbackFollow(renamedEnvironments: ["a": "b", "b": "a"])
		#expect(swap.isApplied(to: ["a": [:], "b": [:]]))
	}
}
