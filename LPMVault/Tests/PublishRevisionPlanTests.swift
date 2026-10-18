import CryptoKit
import Foundation
import Testing

@testable import LPMVault

@Suite("Planning a publish to a place the platform versions as a whole")
struct PublishRevisionPlanTests {
	private let secret = SymmetricKey(size: .bits256)
	private let destination = vercelDestination()
	private let published = Date(timeIntervalSince1970: 1_760_000_000)
	private let revised = Date(timeIntervalSince1970: 1_760_000_100)
	private let current = "0f0e2c3a-6d1b-4f7e-9a3c-5b8d7e6f1a20"
	private let earlier = "7a1c9e2d-3b4f-4a6e-8d0c-1e2f3a4b5c6d"
	private let rules = ProjectEnvSchemaOverview(rules: [], groups: [])

	private var revision: PublishPlan.Platform { PublishPlan.Platform(freshness: .revision) }

	@Test("a key is known unchanged only while the version this Mac's publish made is still the newest")
	func knownOnlyAtTheRecordedVersion() throws {
		let history = record([
			("KEPT", "same", current),
			("OLDER", "same", earlier),
			("REMOVED", "same", current),
		])
		let plan = makePlan(
			values: ["KEPT": "same", "OLDER": "same", "REMOVED": "same", "NEW": "fresh"],
			remote: [
				"KEPT": .init(id: current, updatedAt: revised, storedAsSecret: true),
				"OLDER": .init(id: current, updatedAt: revised, storedAsSecret: true),
				"NEW": .init(id: current, updatedAt: nil, storedAsSecret: true),
			],
			history: history)

		let kept = try #require(plan.row("KEPT"))
		#expect(kept.status.platform == .unchanged && kept.status.isUpToDate && kept.holds == [.upToDate])

		let older = try #require(plan.row("OLDER"))
		#expect(older.status.platform == .unknown, "a later version may have changed it, which the platform can't say")
		#expect(older.holds == [.unknownSincePublish] && !older.isSelectedByDefault && older.isPublishable)

		let removed = try #require(plan.row("REMOVED"))
		#expect(removed.status.platform == .removed && removed.holds.contains(.changedOnPlatform))

		let new = try #require(plan.row("NEW"))
		#expect(new.operation == .replace(remoteID: current) && new.holds.isEmpty && new.isSelectedByDefault,
			"a version's time stands for every key in it, so an unknown time per key doesn't hold one")
	}

	@Test("a key this Mac sent without an answer reads as possibly published, on any platform")
	func unconfirmedPublish() throws {
		let history = record([("SENT", "new", PublishPlan.unconfirmedRemoteID)])
		for platform in [revision, PublishPlan.Platform()] {
			let plan = makePlan(
				values: ["SENT": "new"],
				remote: ["SENT": .init(id: current, updatedAt: revised, storedAsSecret: true)],
				platform: platform,
				history: history)
			let row = try #require(plan.row("SENT"))
			#expect(row.status.platform == .unknown && !row.status.valueChanged)
			#expect(row.holds == [.unconfirmedPublish] && !row.isSelectedByDefault && row.isPublishable)
		}
	}

	@Test("nothing is chosen or chosen later while another version serves the place")
	func placeHoldStopsEveryKey() throws {
		for hold in [PublishPlan.PlaceHold.earlierVersionLive, .versionsSplit, .newestVersionNotLive] {
			let plan = makePlan(values: ["A": "1", "B": "2"], remote: [:], placeHold: hold)
			#expect(plan.placeHold == hold)
			var selection = PublishPlan.Selection(defaultsOf: plan)
			#expect(selection.keys.isEmpty)
			let chose = selection.set("A", selected: true, in: plan)
			#expect(!chose)
			#expect(plan.summary(of: selection).publishing == 0)
		}
	}

	@Test("a name the platform uses for another kind of binding can't be published, and isn't counted as one of its variables")
	func nameTakenByAnotherBinding() throws {
		let plan = makePlan(
			values: ["CLASH": "value", "FREE": "value"],
			remote: [:],
			remoteKeys: [
				"CLASH": .init(kind: .otherBinding, storedAsSecret: false, updatedAt: nil),
				"KV_BINDING": .init(kind: .otherBinding, storedAsSecret: false, updatedAt: nil),
			])
		let clash = try #require(plan.row("CLASH"))
		#expect(clash.holds.contains(.nameTaken) && !clash.isPublishable && !clash.isSelectedByDefault)
		#expect(PublishPlan.Hold.nameTaken.blocksPublishing)
		#expect(try #require(plan.row("FREE")).isSelectedByDefault)
		#expect(plan.remoteOnlyCount == 0)
	}

	@Test("a platform that counts secrets and variables together counts the other bindings its place holds")
	func combinedCapacity() throws {
		var platform = revision
		platform.combinedCapacity = .init(limit: 5, occupied: 2)
		let remote: [String: PublishPlan.RemoteVariable] = [
			"A": .init(id: current, updatedAt: revised, storedAsSecret: true),
			"B": .init(id: current, updatedAt: revised, storedAsSecret: true),
		]
		let plan = makePlan(values: ["A": "1", "N1": "2", "N2": "3"], remote: remote, platform: platform)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		#expect(selection.keys == ["A", "N1", "N2"])
		let overflow = try #require(plan.overflows(of: selection).first)
		#expect(overflow == PublishPlan.Overflow(isSecrets: true, limit: 5, existing: 4, adding: 2, isCombined: true))
		#expect(overflow.excess == 1, "2 secrets and 2 other bindings, with 2 new; the replaced key keeps its place")
		selection.set("N2", selected: false, in: plan)
		#expect(plan.overflows(of: selection).isEmpty)
	}

	@Test("a publish can't change more keys than the platform changes at once, and keys left out to fit aren't remembered")
	func changeLimit() throws {
		var platform = revision
		platform.maximumChanges = 2
		let plan = makePlan(values: ["A": "1", "B": "2", "C": "3"], remote: [:], platform: platform)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		#expect(plan.changeLimitExcess(of: selection) == 1)
		selection.set("C", selected: false, in: plan)
		#expect(plan.changeLimitExcess(of: selection) == nil)
		#expect(plan.choices(for: selection).leftOut.isEmpty,
			"C was left out to fit the limit, not to stay out of later publishes")

		let fitting = makePlan(values: ["A": "1", "B": "2"], remote: [:], platform: platform)
		var chosen = PublishPlan.Selection(defaultsOf: fitting)
		chosen.set("B", selected: false, in: fitting)
		#expect(fitting.changeLimitExcess(of: chosen) == nil)
		#expect(fitting.choices(for: chosen).leftOut == ["B"])
	}

	private func makePlan(
		values: [String: String],
		remote: [String: PublishPlan.RemoteVariable],
		remoteKeys: [String: PublishPlan.RemoteKey] = [:],
		platform: PublishPlan.Platform? = nil,
		history: PublishHistory? = nil,
		placeHold: PublishPlan.PlaceHold? = nil
	) -> PublishPlan {
		PublishPlan(
			destination: destination,
			values: values,
			rules: rules,
			check: nil,
			remote: remote,
			remoteKeys: remoteKeys,
			platform: platform ?? revision,
			history: history,
			placeHold: placeHold,
			fingerprintKey: secret)
	}

	private func record(_ keys: [(key: String, value: String, remoteID: String)]) -> PublishHistory {
		PublishHistory().recording(
			keys.map {
				PublishHistory.Published(
					key: $0.key,
					fingerprint: PublishFingerprint.of(value: $0.value, key: $0.key, destination: destination.id, using: secret),
					remoteID: $0.remoteID, remoteUpdatedAt: published, publishedAsSecret: true)
			},
			forgetting: [], at: published)
	}
}

@MainActor
@Suite("Showing why a key is held")
struct PublishRowDetailTests {
	private let secret = SymmetricKey(size: .bits256)
	private let published = Date(timeIntervalSince1970: 1_760_000_000)

	@Test("a key that could overwrite a change made on the platform says so, whatever reason comes first")
	func overwriteRiskAlwaysShows() throws {
		let destination = vercelDestination(excluded: ["LEFT_OUT"])
		let history = PublishHistory().recording(
			["LEFT_OUT", "FAILING"].map {
				PublishHistory.Published(
					key: $0, fingerprint: PublishFingerprint.of(value: "old", key: $0, destination: destination.id, using: secret),
					remoteID: $0 == "LEFT_OUT" ? nil : "env_failing", remoteUpdatedAt: published, publishedAsSecret: true)
			},
			forgetting: [], at: published)
		let plan = PublishPlan(
			destination: destination,
			values: ["LEFT_OUT": "new", "FAILING": "new"],
			rules: ProjectEnvSchemaOverview(rules: [], groups: []),
			check: ProjectEnvValueCheck.Environment(problems: ["FAILING": [.init(key: "FAILING", kind: .format("url"))]]),
			remote: [
				"LEFT_OUT": .init(id: "env_left", updatedAt: published),
				"FAILING": .init(id: "env_failing", updatedAt: published.addingTimeInterval(5)),
			],
			history: history,
			fingerprintKey: secret)
		let review = PublishSession.Review(
			destination: destination, stored: destination, isSaved: true, needsSave: false, plan: plan,
			selection: PublishPlan.Selection(defaultsOf: plan), fingerprintKey: secret, lastPublishedAt: published,
			rules: .known(ProjectEnvSchemaOverview(rules: [], groups: [])), hasValueCheck: true,
			ruleNotes: ["FAILING": "must be a URL"], remote: [:], remoteKeys: [:])

		let leftOut = try #require(plan.row("LEFT_OUT"))
		#expect(leftOut.holds == [.excluded, .unknownSincePublish] && leftOut.isPublishable)
		let leftOutDetail = PublishSheet.detail(leftOut, review: review)
		#expect(leftOutDetail.contains("Left out last time"))
		#expect(leftOutDetail.contains("Vercel doesn't say whether it changed since you published it"))

		let failing = try #require(plan.row("FAILING"))
		#expect(failing.holds.first.map { if case .failsRules = $0 { true } else { false } } == true)
		#expect(failing.holds.contains(.changedOnPlatform) && failing.isPublishable)
		#expect(PublishSheet.detail(failing, review: review).contains("Changed on Vercel since you published it"))
	}
}

@Suite("Reporting keys sent without an answer")
struct PublishUnconfirmedResultsTests {
	@Test("the results count keys sent without an answer apart, as ones the platform may have, and ask for another review")
	func summaryCountsUnconfirmed() {
		let destination = vercelDestination()
		let unanswered = PublishOutcome.unconfirmed("No answer came back.")
		let results = PublishSession.Results(
			destination: destination,
			rows: [
				.init(key: "A", outcome: .published, isSecret: true, isStored: true),
				.init(key: "B", outcome: unanswered, isSecret: true, isStored: false),
				.init(key: "C", outcome: unanswered, isSecret: true, isStored: false),
			],
			needsReconnect: false, recordFailure: nil)
		#expect(results.publishedCount == 1 && results.unconfirmedCount == 2)
		#expect(results.summary == "Published 1 of 3 variables. 2 more were sent without an answer, so Vercel may have them. Review again to see.")

		let one = PublishSession.Results(
			destination: destination, rows: [.init(key: "B", outcome: unanswered, isSecret: true, isStored: false)],
			needsReconnect: false, recordFailure: nil)
		#expect(one.summary == "Published 0 of 1 variable. 1 more was sent without an answer, so Vercel may have it. Review again to see.")
	}
}
