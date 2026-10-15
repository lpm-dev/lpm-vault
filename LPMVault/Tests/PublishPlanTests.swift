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
			"NEXT_PUBLIC_API_URL": .init(id: "env_pub", sharedWith: ["Preview"], updatedAt: remoteEdit),
			"ONLY_ON_VERCEL_1": .init(id: "env_o1", updatedAt: nil),
			"ONLY_ON_VERCEL_2": .init(id: "env_o2", updatedAt: nil),
			"ONLY_ON_VERCEL_3": .init(id: "env_o3", updatedAt: nil),
			"ONLY_ON_VERCEL_4": .init(id: "env_o4", updatedAt: nil),
		]
	}

	private var history: PublishHistory {
		PublishHistory().recording([
			published("DATABASE_URL", value: "postgres://old", remoteID: "env_db", updatedAt: lastPublish),
			published("API_TOKEN", value: "token", remoteID: "env_api", updatedAt: lastPublish),
		], forgetting: [], at: lastPublish)
	}

	@Test("the review plans each key from its value, rules, the platform's variables and this Mac's history")
	func review() throws {
		let plan = makePlan()
		let published = PublishTimestamp.normalized(lastPublish)
		#expect(plan.rows.map(\.key) == ["API_TOKEN", "DATABASE_URL", "LOG_LEVEL", "NEXT_PUBLIC_API_URL", "SESSION_SECRET", "STRIPE_WEBHOOK_SECRET"])

		let database = try #require(plan.row("DATABASE_URL"))
		#expect(database.operation == .replace(remoteID: "env_db"))
		#expect(database.status == .init(publishedAt: published, valueChanged: true, platform: .unchanged))
		#expect(database.kind == .secret && database.isSelectedByDefault)

		let session = try #require(plan.row("SESSION_SECRET"))
		#expect(session.operation == .add && session.status == .notPublished && session.isSelectedByDefault)

		let token = try #require(plan.row("API_TOKEN"))
		#expect(token.status == .init(publishedAt: published, valueChanged: false, platform: .unchanged))
		#expect(token.holds == [.upToDate] && !token.isSelectedByDefault && token.isPublishable)

		let level = try #require(plan.row("LOG_LEVEL"))
		#expect(level.kind == .config && level.operation == .add && level.isSelectedByDefault)
		#expect(level.kind.publishesAsSecret)

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
		let plan = makePlan(check: check, platform: PublishPlan.Platform(reservedKeys: ["SESSION_SECRET"]))
		#expect(plan.row("SESSION_SECRET")?.holds == [.reserved])
		#expect(plan.row("LOG_LEVEL")?.holds == [.unusableValue])
		var selection = PublishPlan.Selection(defaultsOf: plan)
		#expect(selection.keys == ["DATABASE_URL", "STRIPE_WEBHOOK_SECRET"])
		let accepted = [
			("SESSION_SECRET", true, true), ("LOG_LEVEL", true, true), ("MISSING", true, true),
			("API_TOKEN", true, false), ("NEXT_PUBLIC_API_URL", true, true), ("DATABASE_URL", false, false),
		].map { selection.set($0.0, selected: $0.1, confirmed: $0.2, in: plan) }
		#expect(accepted == [false, false, false, true, true, true])
		#expect(plan.summary(of: selection) == PublishPlan.Summary(adding: 1, replacing: 2, upToDate: 0, skipped: 3))
	}

	@Test("a key someone changed, replaced or removed on the platform since this Mac published it waits for a choice")
	func changedOnPlatform() throws {
		let published = PublishTimestamp.normalized(lastPublish)
		let cases: [(PublishPlan.RemoteVariable?, PublishPlan.Status, PublishPlan.Operation)] = [
			(.init(id: "env_api", updatedAt: remoteEdit), .init(publishedAt: published, valueChanged: false, platform: .changed), .replace(remoteID: "env_api")),
			(.init(id: "env_api_new", updatedAt: lastPublish), .init(publishedAt: published, valueChanged: false, platform: .changed), .replace(remoteID: "env_api_new")),
			(nil, .init(publishedAt: published, valueChanged: false, platform: .removed), .add),
		]
		for (variable, status, operation) in cases {
			var remote = remote
			remote["API_TOKEN"] = variable
			let row = try #require(makePlan(remote: remote).row("API_TOKEN"))
			#expect(row.status == status && row.operation == operation)
			#expect(row.holds == [.changedOnPlatform])
		}
	}

	@Test(
		"a key whose identity or change time can't be compared isn't up to date, nor said to have changed on the platform",
		arguments: [
			(nil, Date(timeIntervalSince1970: 1_760_000_000), "env_api", Date(timeIntervalSince1970: 1_760_000_000)),
			("env_api", nil, "env_api", Date(timeIntervalSince1970: 1_760_000_000)),
			("env_api", Date(timeIntervalSince1970: 1_760_000_000), "env_api", nil),
		] as [(String?, Date?, String, Date?)]
	)
	func unknownRemoteTimes(recordedID: String?, recordedTime: Date?, remoteID: String, remoteTime: Date?) throws {
		let history = PublishHistory().recording(
			[published("API_TOKEN", value: "token", remoteID: recordedID, updatedAt: recordedTime)], forgetting: [], at: lastPublish)
		var remote = remote
		remote["API_TOKEN"] = .init(id: remoteID, updatedAt: remoteTime)
		let row = try #require(makePlan(remote: remote, history: history).row("API_TOKEN"))
		#expect(row.status.platform == .unknown && !row.status.isUpToDate && !row.isSelectedByDefault)
		#expect(row.holds == (remoteTime == nil ? [.unknownChangeTime, .unknownSincePublish] : [.unknownSincePublish]))
	}

	@Test("a variable the platform gives no change time for can't be replaced, since a change made meanwhile couldn't be caught")
	func unknownChangeTime() throws {
		let planned = makePlan(
			values: ["A": "1", "B": "2"], rules: .empty, check: .some(nil), remote: ["A": .init(id: "env_a", updatedAt: nil)], history: .some(nil))
		let row = try #require(planned.row("A"))
		#expect(row.holds == [.unknownChangeTime] && !row.isPublishable)
		var selection = PublishPlan.Selection(defaultsOf: planned)
		let accepted = selection.set("A", selected: true, confirmed: true, in: planned)
		#expect(!accepted)
		#expect(planned.row("B")?.isSelectedByDefault == true, "A new key has no change time to know")
	}

	@Test("a key whose platform time went back, or that the platform holds under another ID, reads as changed on the platform")
	func earlierRemoteTime() throws {
		let history = PublishHistory().recording(
			[published("API_TOKEN", value: "token", remoteID: "env_api", updatedAt: lastPublish)], forgetting: [], at: lastPublish)
		for variable in [
			PublishPlan.RemoteVariable(id: "env_api", updatedAt: lastPublish.addingTimeInterval(-1_000)),
			PublishPlan.RemoteVariable(id: "env_other", updatedAt: lastPublish),
		] {
			var remote = remote
			remote["API_TOKEN"] = variable
			let row = try #require(makePlan(remote: remote, history: history).row("API_TOKEN"))
			#expect(row.status.platform == .changed && row.holds == [.changedOnPlatform])
		}
	}

	@Test("a key the platform still has as this Mac published it, at the same time, reads as up to date")
	func sameRemoteTime() throws {
		let history = PublishHistory().recording(
			[published("API_TOKEN", value: "token", remoteID: "env_api", updatedAt: lastPublish)], forgetting: [], at: lastPublish)
		var remote = remote
		remote["API_TOKEN"] = .init(id: "env_api", updatedAt: lastPublish)
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

	@Test("only public keys are published readable; a public rule or prefix makes a key public")
	func kinds() {
		let rules = ProjectEnvSchemaOverview(
			rules: [rule("SECRET", secret: true), rule("CONFIG"), rule("CLIENT", isPublic: true)], groups: [],
			clientPrefixes: ["VITE_"])
		let values = ["SECRET": "1", "CONFIG": "2", "CLIENT": "3", "VITE_URL": "4", "OTHER": "5"]
		let plan = makePlan(values: values, rules: rules, check: .some(nil), remote: [:], history: .some(nil))
		let kinds = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.key, $0.kind) })
		#expect(kinds == ["SECRET": .secret, "CONFIG": .config, "CLIENT": .public, "VITE_URL": .public, "OTHER": .undeclared])
		#expect(plan.rows.filter(\.kind.publishesAsSecret).map(\.key) == ["CONFIG", "OTHER", "SECRET"])
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
		#expect(changes.map(\.publishesAsSecret) == [true, true, true])
		#expect(!String(describing: changes[0]).contains("postgres"))
		#expect(!String(reflecting: changes[0]).contains("postgres"))
		var dumped = ""
		dump(changes[0], to: &dumped)
		#expect(!dumped.contains("postgres"))
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
				== .failure(.stale(keys: ["LOG_LEVEL", "SESSION_SECRET"])))
		#expect(
			plan.changes(for: selection, values: values, fingerprintKey: SymmetricKey(size: .bits256))
				== .failure(.stale(keys: ["DATABASE_URL", "LOG_LEVEL", "SESSION_SECRET"])))
	}

	@Test("after a publish, the destination remembers the keys the person left out and the ones they chose, and forgets keys the source lost")
	func remembersChoices() {
		let earlier = vercelDestination(id: destination.id, excluded: ["LOG_LEVEL", "GONE"])
		let plan = makePlan(destination: earlier)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		selection.set("SESSION_SECRET", selected: false, in: plan)
		selection.set("LOG_LEVEL", selected: true, in: plan)
		let choices = plan.choices(for: selection)
		#expect(choices.leftOut == ["SESSION_SECRET"] && choices.chosen == ["DATABASE_URL", "LOG_LEVEL"])
		let after = Date(timeIntervalSince1970: 1_760_000_900)
		let updated = choices.applied(to: earlier, at: after)
		#expect(updated.excludedKeys == ["SESSION_SECRET"])
		#expect(updated.updatedAt == after && updated.createdAt == earlier.createdAt)
		var changedSince = earlier
		changedSince.updatedAt = earlier.updatedAt.addingTimeInterval(1)
		#expect(choices.applied(to: changedSince, at: after).excludedKeys == ["SESSION_SECRET", "GONE"])
	}

	private func makePlan(
		destination: PublishDestination? = nil,
		values: [String: String]? = nil,
		rules: ProjectEnvSchemaOverview? = nil,
		check: ProjectEnvValueCheck.Environment?? = .none,
		remote: [String: PublishPlan.RemoteVariable]? = nil,
		platform: PublishPlan.Platform = PublishPlan.Platform(),
		history: PublishHistory?? = .none
	) -> PublishPlan {
		PublishPlan(
			destination: destination ?? self.destination,
			values: values ?? self.values,
			rules: rules ?? self.rules,
			check: check ?? self.check,
			remote: remote ?? self.remote,
			platform: platform,
			history: history ?? self.history,
			fingerprintKey: secret
		)
	}

	private func published(_ key: String, value: String, remoteID: String?, updatedAt: Date?) -> PublishHistory.Published {
		.init(
			key: key,
			fingerprint: PublishFingerprint.of(value: value, key: key, destination: destination.id, using: secret),
			remoteID: remoteID,
			remoteUpdatedAt: updatedAt, publishedAsSecret: true
		)
	}
}

private func rule(_ key: String, secret: Bool = false, isPublic: Bool = false) -> ProjectEnvSchemaOverview.Rule {
	var rule = ProjectEnvSchemaOverview.Rule(key: key, isPublic: isPublic, source: nil, badges: [])
	rule.isSecret = secret
	return rule
}

@Suite("Planning a publish under review")
struct PublishPlanFindingTests {
	private let secret = SymmetricKey(size: .bits256)
	private let destination = vercelDestination()
	private let lastPublish = Date(timeIntervalSince1970: 1_760_000_000)

	@Test("a value changed here that was also changed or removed on the platform waits for a choice")
	func changedOnBothSides() {
		let history = PublishHistory().recording([
			.init(key: "A", fingerprint: PublishFingerprint.of(value: "old", key: "A", destination: destination.id, using: secret),
				remoteID: "env_a", remoteUpdatedAt: lastPublish, publishedAsSecret: true),
		], forgetting: [], at: lastPublish)
		for remote in [["A": PublishPlan.RemoteVariable(id: "env_a", updatedAt: lastPublish.addingTimeInterval(5))], [:]] {
			let plan = PublishPlan(
				destination: destination, values: ["A": "new"], rules: .empty, check: nil, remote: remote,
				history: history, fingerprintKey: secret)
			#expect(plan.row("A")?.holds == [.changedOnPlatform])
			#expect(plan.row("A")?.status.valueChanged == true)
		}
	}

	@Test("a key the platform already has counts as up to date even when it's held for another reason too")
	func upToDateCount() {
		let excluded = vercelDestination(id: destination.id, excluded: ["A"])
		let history = PublishHistory().recording([
			.init(key: "A", fingerprint: PublishFingerprint.of(value: "same", key: "A", destination: destination.id, using: secret),
				remoteID: "env_a", remoteUpdatedAt: lastPublish, publishedAsSecret: true),
		], forgetting: [], at: lastPublish)
		let plan = PublishPlan(
			destination: excluded, values: ["A": "same"], rules: .empty, check: nil,
			remote: ["A": .init(id: "env_a", updatedAt: lastPublish)], history: history, fingerprintKey: secret)
		#expect(plan.summary(of: PublishPlan.Selection(defaultsOf: plan)).upToDate == 1)
	}

	@Test("a selection made for one plan can't send another plan's changes or record its choices")
	func foreignSelection() {
		let first = plan(values: ["A": "1"])
		let second = plan(values: ["A": "1"])
		var selection = PublishPlan.Selection(defaultsOf: first)
		#expect(second.changes(for: selection, values: ["A": "1"], fingerprintKey: secret) == .failure(.foreignSelection))
		#expect(second.choices(for: selection) == PublishPlan.Choices(leftOut: [], chosen: []))
		let accepted = selection.set("A", selected: true, in: second)
		#expect(!accepted)
	}

	@Test("a key shared with other environments is chosen only with the person's confirmation")
	func confirmation() throws {
		let plan = plan(values: ["A": "1"], remote: ["A": .init(id: "env_a", sharedWith: ["Preview"], updatedAt: lastPublish)])
		var selection = PublishPlan.Selection(defaultsOf: plan)
		let unconfirmed = selection.set("A", selected: true, in: plan)
		#expect(!unconfirmed && selection.keys.isEmpty)
		let confirmed = selection.set("A", selected: true, confirmed: true, in: plan)
		#expect(confirmed && selection.keys == ["A"])
		#expect(try plan.changes(for: selection, values: ["A": "1"], fingerprintKey: secret).get().map(\.key) == ["A"])
	}

	@Test("an impossible platform time doesn't crash")
	func impossibleTimes() {
		#expect(PublishTimestamp.milliseconds(Date(timeIntervalSince1970: .infinity)) == PublishTimestamp.maximumMilliseconds)
		#expect(PublishTimestamp.milliseconds(Date(timeIntervalSince1970: .nan)) == 0)
		#expect(PublishTimestamp.milliseconds(Date(timeIntervalSince1970: -1)) == 0)
		#expect(PublishTimestamp.milliseconds(Date(timeIntervalSince1970: 1e300)) == PublishTimestamp.maximumMilliseconds)
	}

	@Test("on a platform that can't make a secret readable again, a public key it stores as a secret stays one and can be up to date")
	func secretsStaySecret() throws {
		let readable = ProjectEnvSchemaOverview(rules: [rule("A", isPublic: true)], groups: [])
		let storedSecret = ["A": PublishPlan.RemoteVariable(id: "env_a", updatedAt: lastPublish, storedAsSecret: true)]
		let fingerprint = PublishFingerprint.of(value: "same", key: "A", destination: destination.id, using: secret)
		let history = PublishHistory().recording(
			[.init(key: "A", fingerprint: fingerprint, remoteID: "env_a", remoteUpdatedAt: lastPublish, publishedAsSecret: true)],
			forgetting: [], at: lastPublish)
		let staysSecret = PublishPlan.Platform(secretsStaySecret: true)
		let staying = PublishPlan(destination: destination, values: ["A": "same"], rules: readable, check: nil,
			remote: storedSecret, platform: staysSecret, history: history, fingerprintKey: secret)
		let row = try #require(staying.row("A"))
		#expect(row.kind == .public && row.publishesAsSecret && row.staysSecret)
		#expect(row.status.isUpToDate)
		var selection = PublishPlan.Selection(defaultsOf: staying)
		selection.set("A", selected: true, in: staying)
		#expect(try staying.changes(for: selection, values: ["A": "same"], fingerprintKey: secret).get().first?.publishesAsSecret == true)

		let convertible = PublishPlan(destination: destination, values: ["A": "same"], rules: readable, check: nil,
			remote: storedSecret, history: history, fingerprintKey: secret)
		#expect(convertible.row("A")?.publishesAsSecret == false && convertible.row("A")?.status.protectionChanged == true)
		let added = PublishPlan(destination: destination, values: ["A": "same"], rules: readable, check: nil,
			remote: [:], platform: staysSecret, history: nil, fingerprintKey: secret)
		#expect(added.row("A")?.publishesAsSecret == false, "A new public key is published readable")
	}

	@Test("a value published readable that should now be a secret isn't up to date")
	func protectionChange() throws {
		let readable = ProjectEnvSchemaOverview(rules: [rule("A", isPublic: true)], groups: [])
		let secretRule = ProjectEnvSchemaOverview(rules: [rule("A", secret: true)], groups: [])
		let first = PublishPlan(destination: destination, values: ["A": "same"], rules: readable, check: nil, remote: [:],
			history: nil, fingerprintKey: secret)
		let change = try #require(try first.changes(for: .init(defaultsOf: first), values: ["A": "same"], fingerprintKey: secret).get().first)
		#expect(!change.publishesAsSecret)
		let history = PublishHistory().recording(
			[change.published(remoteID: "env_a", remoteUpdatedAt: lastPublish)], forgetting: [], at: lastPublish)
		let remote = ["A": PublishPlan.RemoteVariable(id: "env_a", updatedAt: lastPublish)]
		let plan = PublishPlan(destination: destination, values: ["A": "same"], rules: secretRule, check: nil, remote: remote,
			history: history, fingerprintKey: secret)
		let row = try #require(plan.row("A"))
		#expect(!row.status.isUpToDate && row.isSelectedByDefault)
		let unchanged = PublishPlan(destination: destination, values: ["A": "same"], rules: readable, check: nil, remote: remote,
			history: history, fingerprintKey: secret)
		#expect(unchanged.row("A")?.status.isUpToDate == true)
		// What the platform says it stores wins over this Mac's history.
		let storedReadable = ["A": PublishPlan.RemoteVariable(id: "env_a", updatedAt: lastPublish, storedAsSecret: false)]
		let secretHistory = PublishHistory().recording(
			[.init(key: "A", fingerprint: change.fingerprint, remoteID: "env_a", remoteUpdatedAt: lastPublish, publishedAsSecret: true)],
			forgetting: [], at: lastPublish)
		let reported = PublishPlan(destination: destination, values: ["A": "same"], rules: secretRule, check: nil,
			remote: storedReadable, history: secretHistory, fingerprintKey: secret)
		#expect(reported.row("A")?.status.protectionChanged == true)
		#expect(reported.row("A")?.isSelectedByDefault == true)
	}

	@Test("without rules, a value no process can receive still can't be published")
	func schemaFreeUnusableValue() {
		let plan = plan(values: ["A": "bad\u{0}value", "B": "fine"])
		#expect(plan.row("A")?.holds == [.unusableValue])
		#expect(plan.row("A")?.isPublishable == false)
		#expect(PublishPlan.Selection(defaultsOf: plan).keys == ["B"])
	}

	@Test("row lookups stay fast for large environments")
	func largePlan() {
		let values = Dictionary(uniqueKeysWithValues: (0..<5_000).map { ("KEY_\($0)", "value") })
		let plan = plan(values: values)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		let start = ContinuousClock.now
		for key in values.keys { selection.set(key, selected: false, in: plan) }
		#expect(selection.keys.isEmpty)
		#expect(ContinuousClock.now - start < .milliseconds(500))
	}

	private func plan(values: [String: String], remote: [String: PublishPlan.RemoteVariable] = [:]) -> PublishPlan {
		PublishPlan(destination: destination, values: values, rules: .empty, check: nil, remote: remote,
			history: nil, fingerprintKey: secret)
	}
}
