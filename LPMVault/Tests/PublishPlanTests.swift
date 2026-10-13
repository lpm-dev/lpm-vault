import CryptoKit
import Foundation
import Testing

@testable import LPMVault

@Suite("Planning a publish")
struct PublishPlanTests {
	private let secret = SymmetricKey(size: .bits256)
	private let destination = vercelDestination()
	private let lastPublish = Date(timeIntervalSince1970: 1_760_000_000)
	private let remoteEdit = Date(timeIntervalSince1970: 1_760_000_000.5)

	private let values = [
		"DATABASE_URL": "postgres://new",
		"SESSION_SECRET": "session",
		"API_TOKEN": "token",
		"LOG_LEVEL": "info",
		"NEXT_PUBLIC_API_URL": "https://api.acme.io",
		"STRIPE_WEBHOOK_SECRET": "whsec_1",
	]

	private let rules = ProjectEnvSchemaOverview(
		rules: [
			rule("DATABASE_URL", secret: true), rule("SESSION_SECRET", secret: true), rule("API_TOKEN", secret: true),
			rule("LOG_LEVEL"), rule("STRIPE_WEBHOOK_SECRET", secret: true),
		],
		groups: [],
		clientPrefixes: ["NEXT_PUBLIC_"]
	)

	private var check: ProjectEnvValueCheck.Environment {
		ProjectEnvValueCheck.Environment(problems: ["STRIPE_WEBHOOK_SECRET": [.init(key: "STRIPE_WEBHOOK_SECRET", kind: .format("url"))]])
	}

	private var remote: [String: PublishPlan.RemoteVariable] {
		[
			"DATABASE_URL": .init(id: "env_db", updatedAt: lastPublish),
			"API_TOKEN": .init(id: "env_api", updatedAt: lastPublish),
			"NEXT_PUBLIC_API_URL": .init(id: "env_pub", sharedWith: ["Preview"], updatedAt: nil),
			"ONLY_ON_VERCEL_1": .init(id: "env_o1", updatedAt: nil),
			"ONLY_ON_VERCEL_2": .init(id: "env_o2", updatedAt: nil),
			"ONLY_ON_VERCEL_3": .init(id: "env_o3", updatedAt: nil),
			"ONLY_ON_VERCEL_4": .init(id: "env_o4", updatedAt: nil),
		]
	}

	private var history: PublishHistory.Entry? {
		PublishHistory().recording([
			published("DATABASE_URL", value: "postgres://old", remoteID: "env_db", updatedAt: lastPublish),
			published("API_TOKEN", value: "token", remoteID: "env_api", updatedAt: lastPublish),
		], to: destination.id, at: lastPublish).entries[destination.id]
	}

	@Test("the review plans each key from its value, rules, the platform's variables and this Mac's history")
	func review() throws {
		let plan = makePlan()
		let published = PublishTimestamp.normalized(lastPublish)
		#expect(plan.rows.map(\.key) == ["API_TOKEN", "DATABASE_URL", "LOG_LEVEL", "NEXT_PUBLIC_API_URL", "SESSION_SECRET", "STRIPE_WEBHOOK_SECRET"])

		let database = try #require(plan.row("DATABASE_URL"))
		#expect(database.operation == .replace(remoteID: "env_db"))
		#expect(database.status == .changedSincePublish(publishedAt: published))
		#expect(database.kind == .secret && database.isSelectedByDefault)

		let session = try #require(plan.row("SESSION_SECRET"))
		#expect(session.operation == .add && session.status == .notPublished && session.isSelectedByDefault)

		let token = try #require(plan.row("API_TOKEN"))
		#expect(token.status == .unchangedSincePublish(publishedAt: published))
		#expect(token.holds == [.upToDate] && !token.isSelectedByDefault && token.isPublishable)

		let level = try #require(plan.row("LOG_LEVEL"))
		#expect(level.kind == .config && level.operation == .add && level.isSelectedByDefault)

		let api = try #require(plan.row("NEXT_PUBLIC_API_URL"))
		#expect(api.kind == .public && api.operation == .replace(remoteID: "env_pub"))
		#expect(api.holds == [.sharedWith(["Preview"])] && api.needsConfirmation && api.isPublishable)

		let webhook = try #require(plan.row("STRIPE_WEBHOOK_SECRET"))
		#expect(webhook.holds == [.failsRules([.init(key: "STRIPE_WEBHOOK_SECRET", kind: .format("url"))])])

		#expect(plan.remoteOnlyCount == 4)
		let summary = plan.summary(of: PublishPlan.Selection(defaultsOf: plan))
		#expect(summary == PublishPlan.Summary(adding: 2, replacing: 1, upToDate: 1, skipped: 2))
		#expect(summary.publishing == 3)
	}

	@Test("choosing held keys counts them; a reserved name or an unusable value can't be chosen")
	func selection() {
		let check = ProjectEnvValueCheck.Environment(problems: ["LOG_LEVEL": [.init(key: "LOG_LEVEL", kind: .unusableValue)]])
		let plan = makePlan(check: check, reservedKeys: ["SESSION_SECRET"])
		#expect(plan.row("SESSION_SECRET")?.holds == [.reserved])
		#expect(plan.row("LOG_LEVEL")?.holds == [.unusableValue])
		var selection = PublishPlan.Selection(defaultsOf: plan)
		#expect(selection.keys == ["DATABASE_URL", "STRIPE_WEBHOOK_SECRET"])
		let accepted = [
			("SESSION_SECRET", true), ("LOG_LEVEL", true), ("MISSING", true),
			("API_TOKEN", true), ("NEXT_PUBLIC_API_URL", true), ("DATABASE_URL", false),
		].map { selection.set($0.0, selected: $0.1, in: plan) }
		#expect(accepted == [false, false, false, true, true, true])
		#expect(plan.summary(of: selection) == PublishPlan.Summary(adding: 1, replacing: 2, upToDate: 0, skipped: 3))
	}

	@Test("a key someone changed, replaced or removed on the platform since this Mac published it waits for a choice")
	func changedOnPlatform() throws {
		let published = PublishTimestamp.normalized(lastPublish)
		let cases: [(PublishPlan.RemoteVariable?, PublishPlan.Status, PublishPlan.Operation)] = [
			(.init(id: "env_api", updatedAt: remoteEdit), .changedOnPlatform(publishedAt: published), .replace(remoteID: "env_api")),
			(.init(id: "env_api_new", updatedAt: lastPublish), .changedOnPlatform(publishedAt: published), .replace(remoteID: "env_api_new")),
			(nil, .removedFromPlatform(publishedAt: published), .add),
		]
		for (variable, status, operation) in cases {
			var remote = remote
			remote["API_TOKEN"] = variable
			let row = try #require(makePlan(remote: remote).row("API_TOKEN"))
			#expect(row.status == status && row.operation == operation)
			#expect(row.holds == [.changedOnPlatform])
		}
	}

	@Test("without the platform's change times, a key published unchanged reads as up to date")
	func unknownRemoteTimes() throws {
		let history = PublishHistory().recording(
			[published("API_TOKEN", value: "token", remoteID: nil, updatedAt: nil)], to: destination.id, at: lastPublish
		).entries[destination.id]
		var remote = remote
		remote["API_TOKEN"] = .init(id: "env_api", updatedAt: remoteEdit)
		#expect(makePlan(remote: remote, history: history).row("API_TOKEN")?.holds == [.upToDate])
	}

	@Test("a key the person left out, or one the LPM CLI ignores, waits; each reason shows in order")
	func choices() {
		let excluded = vercelDestination(id: destination.id, excluded: ["LOG_LEVEL", "STRIPE_WEBHOOK_SECRET"])
		let check = ProjectEnvValueCheck.Environment(
			problems: ["STRIPE_WEBHOOK_SECRET": [.init(key: "STRIPE_WEBHOOK_SECRET", kind: .format("url"))]],
			ignored: ["SESSION_SECRET"]
		)
		let plan = makePlan(destination: excluded, check: check)
		#expect(plan.row("LOG_LEVEL")?.holds == [.excluded])
		#expect(plan.row("SESSION_SECRET")?.holds == [.ignoredByLPM])
		#expect(plan.row("STRIPE_WEBHOOK_SECRET")?.holds == [
			.failsRules([.init(key: "STRIPE_WEBHOOK_SECRET", kind: .format("url"))]), .excluded,
		])
	}

	@Test("keys without rules are published as secrets; a public rule or prefix makes a key public")
	func kinds() {
		let rules = ProjectEnvSchemaOverview(
			rules: [rule("SECRET", secret: true), rule("CONFIG"), rule("CLIENT", isPublic: true)], groups: [],
			clientPrefixes: ["VITE_"])
		let values = ["SECRET": "1", "CONFIG": "2", "CLIENT": "3", "VITE_URL": "4", "OTHER": "5"]
		let plan = makePlan(values: values, rules: rules, check: .some(nil), remote: [:], history: .some(nil))
		let kinds = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.key, $0.kind) })
		#expect(kinds == ["SECRET": .secret, "CONFIG": .config, "CLIENT": .public, "VITE_URL": .public, "OTHER": .undeclared])
		#expect(plan.rows.filter(\.kind.publishesAsSecret).map(\.key) == ["OTHER", "SECRET"])
	}

	@Test("rows follow the key table's order, comparing numbers by value")
	func order() {
		let plan = makePlan(values: ["KEY_10": "", "KEY_2": "", "key_1": ""], check: .some(nil), remote: [:], history: .some(nil))
		#expect(plan.rows.map(\.key) == ["key_1", "KEY_2", "KEY_10"])
	}

	@Test("the changes to send carry each chosen value, its operation and whether it's a secret")
	func changes() throws {
		let plan = makePlan()
		let changes = try plan.changes(for: PublishPlan.Selection(defaultsOf: plan), values: values, fingerprintKey: secret).get()
		#expect(changes.map(\.key) == ["DATABASE_URL", "LOG_LEVEL", "SESSION_SECRET"])
		#expect(changes.map(\.operation) == [.replace(remoteID: "env_db"), .add, .add])
		#expect(changes.map(\.value) == ["postgres://new", "info", "session"])
		#expect(changes.map(\.publishesAsSecret) == [true, false, true])
		let record = changes[0].published(remoteID: "env_db", remoteUpdatedAt: remoteEdit)
		#expect(record.fingerprint == plan.row("DATABASE_URL")?.fingerprint && record.key == "DATABASE_URL")
	}

	@Test("a value changed or removed after the review stops the publish")
	func stale() {
		let plan = makePlan()
		let selection = PublishPlan.Selection(defaultsOf: plan)
		var changed = values
		changed["LOG_LEVEL"] = "debug"
		changed.removeValue(forKey: "SESSION_SECRET")
		#expect(
			plan.changes(for: selection, values: changed, fingerprintKey: secret)
				== .failure(PublishPlan.StalePlan(keys: ["LOG_LEVEL", "SESSION_SECRET"])))
		#expect(
			plan.changes(for: selection, values: values, fingerprintKey: SymmetricKey(size: .bits256))
				== .failure(PublishPlan.StalePlan(keys: ["DATABASE_URL", "LOG_LEVEL", "SESSION_SECRET"])))
	}

	@Test("after a publish, the destination remembers the keys the person left out and the ones they chose")
	func remembersChoices() {
		let earlier = vercelDestination(id: destination.id, excluded: ["LOG_LEVEL", "GONE"])
		let plan = makePlan(destination: earlier)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		selection.set("SESSION_SECRET", selected: false, in: plan)
		selection.set("LOG_LEVEL", selected: true, in: plan)
		let after = Date(timeIntervalSince1970: 1_760_000_900)
		let updated = plan.destination(earlier, afterPublishing: selection, at: after)
		#expect(updated.excludedKeys == ["GONE", "SESSION_SECRET"])
		#expect(updated.updatedAt == after && updated.createdAt == earlier.createdAt)
	}

	private func makePlan(
		destination: PublishDestination? = nil,
		values: [String: String]? = nil,
		rules: ProjectEnvSchemaOverview? = nil,
		check: ProjectEnvValueCheck.Environment?? = .none,
		remote: [String: PublishPlan.RemoteVariable]? = nil,
		reservedKeys: Set<String> = [],
		history: PublishHistory.Entry?? = .none
	) -> PublishPlan {
		PublishPlan(
			destination: destination ?? self.destination,
			values: values ?? self.values,
			rules: rules ?? self.rules,
			check: check ?? self.check,
			remote: remote ?? self.remote,
			reservedKeys: reservedKeys,
			history: history ?? self.history,
			fingerprintKey: secret
		)
	}

	private func published(_ key: String, value: String, remoteID: String?, updatedAt: Date?) -> PublishHistory.Published {
		.init(
			key: key,
			fingerprint: PublishFingerprint.of(value: value, key: key, destination: destination.id, using: secret),
			remoteID: remoteID,
			remoteUpdatedAt: updatedAt
		)
	}
}

private func rule(_ key: String, secret: Bool = false, isPublic: Bool = false) -> ProjectEnvSchemaOverview.Rule {
	var rule = ProjectEnvSchemaOverview.Rule(key: key, isPublic: isPublic, source: nil, badges: [])
	rule.isSecret = secret
	return rule
}
