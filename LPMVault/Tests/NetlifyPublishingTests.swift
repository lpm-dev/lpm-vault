import CryptoKit
import Foundation
import Testing
@testable import LPMVault

/// A Netlify site that answers from memory and keeps variables as Netlify
/// does: one per key, with a value per deploy context, one secret flag and
/// one change time that every write moves. It records what was sent.
final class FakeNetlifyAPI: NetlifyClientProtocol, @unchecked Sendable {
	struct Write: Equatable {
		let method: String
		let key: String
		let value: String
		let context: String
		let isSecret: Bool
	}

	private struct Stored {
		var isSecret: Bool
		var values: [NetlifyVariable.Context: (id: String, value: String)]
		var updatedAt: Date?
	}

	private let lock = NSLock()
	private var stored: [String: Stored] = [:]
	private var order: [String] = []
	private var sent: [Write] = []
	private var reads: [String] = []
	private var listings = 0
	private var siteListings = 0
	private var clock = 1_760_000_000.0
	private var nextValue = 0

	var user: Result<NetlifyUser, NetlifyAPIError> = .success(NetlifyUser(id: "5f1a2b3c4d5e6f7a8b9c0d1e", name: "Tolga", email: "tolga@example.com"))
	var siteList: Result<[NetlifySite], NetlifyAPIError> = .success([
		NetlifySite(id: "site-storefront", name: "storefront", teamID: "team_northwind", teamName: "Northwind"),
	])
	var listFailure: NetlifyAPIError?
	/// Writes Netlify refuses, by key.
	var refusals: [String: NetlifyAPIError] = [:]
	/// Keys Netlify stores readable whatever was asked.
	var storesReadable: Set<String> = []
	/// Gives every value of a variable a new ID whenever one of them is written.
	var renewsValueIDs = false
	/// Runs before each listing after the first, as someone changing Netlify meanwhile would.
	var beforeLaterListing: (@Sendable (FakeNetlifyAPI) -> Void)?
	/// Runs once, right after the next listing is answered, as someone changing Netlify just then would.
	var afterNextListing: (@Sendable (FakeNetlifyAPI) -> Void)? {
		get { lock.withLock { nextListingHook } }
		set { lock.withLock { nextListingHook = newValue } }
	}
	private var nextListingHook: (@Sendable (FakeNetlifyAPI) -> Void)?

	var writes: [Write] { lock.withLock { sent } }
	/// Keys read one at a time, in order.
	var keyReads: [String] { lock.withLock { reads } }
	var listingCount: Int { lock.withLock { listings } }
	var siteListingCount: Int { lock.withLock { siteListings } }

	func value(of key: String, in context: NetlifyVariable.Context) -> String? {
		lock.withLock { stored[key]?.values[context]?.value }
	}

	func isSecret(_ key: String) -> Bool? {
		lock.withLock { stored[key]?.isSecret }
	}

	/// A variable as if someone made it on Netlify.
	func seed(_ key: String, _ values: [NetlifyVariable.Context: String], secret: Bool = false) {
		lock.withLock {
			var variable = Stored(isSecret: secret, values: [:], updatedAt: tick())
			for (context, value) in values { variable.values[context] = (newValueID(), value) }
			if stored[key] == nil { order.append(key) }
			stored[key] = variable
		}
	}

	/// Edits a value as someone would on Netlify, which moves the variable's time.
	func edit(_ key: String, in context: NetlifyVariable.Context, value: String = "edited") {
		lock.withLock {
			guard var variable = stored[key] else { return }
			variable.values[context] = (variable.values[context]?.id ?? newValueID(), value)
			variable.updatedAt = tick()
			stored[key] = variable
		}
	}

	func markSecret(_ key: String) {
		lock.withLock {
			stored[key]?.isSecret = true
			stored[key]?.updatedAt = tick()
		}
	}

	func forgetTimes() {
		lock.withLock {
			for key in stored.keys { stored[key]?.updatedAt = nil }
		}
	}

	func remove(_ key: String) {
		lock.withLock {
			stored[key] = nil
			order.removeAll { $0 == key }
		}
	}

	func user() async -> Result<NetlifyUser, NetlifyAPIError> { user }

	func sites() async -> Result<[NetlifySite], NetlifyAPIError> {
		lock.withLock { siteListings += 1 }
		return siteList
	}

	func variables(siteID: String, teamID: String) async -> Result<[NetlifyVariable], NetlifyAPIError> {
		let count = lock.withLock {
			listings += 1
			return listings
		}
		if count > 1 { beforeLaterListing?(self) }
		if let listFailure { return .failure(listFailure) }
		let (listed, hook) = lock.withLock {
			defer { nextListingHook = nil }
			return (order.compactMap { variable($0) }, nextListingHook)
		}
		hook?(self)
		return .success(listed)
	}

	func variable(_ key: String, siteID: String, teamID: String) async -> Result<NetlifyVariable?, NetlifyAPIError> {
		lock.withLock {
			reads.append(key)
			return .success(variable(key))
		}
	}

	func create(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError> {
		lock.withLock {
			sent.append(Write(method: "POST", key: write.key, value: write.value, context: write.context.identifier, isSecret: write.isSecret))
			if let refusal = refusals[write.key] { return .failure(refusal) }
			guard stored[write.key] == nil else { return .failure(.rejected(status: 422)) }
			let secret = write.isSecret && !storesReadable.contains(write.key)
			stored[write.key] = Stored(
				isSecret: secret, values: [NetlifyVariable.Context(write.context): (newValueID(), write.value)], updatedAt: tick())
			order.append(write.key)
			return .success(variable(write.key)!)
		}
	}

	func setValue(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError> {
		lock.withLock {
			sent.append(Write(method: "PATCH", key: write.key, value: write.value, context: write.context.identifier, isSecret: write.isSecret))
			if let refusal = refusals[write.key] { return .failure(refusal) }
			guard var variable = stored[write.key] else { return .failure(.notFound) }
			let context = NetlifyVariable.Context(write.context)
			variable.values[context] = (variable.values[context]?.id ?? newValueID(), write.value)
			if renewsValueIDs {
				for (other, value) in variable.values { variable.values[other] = (newValueID(), value.value) }
			}
			variable.updatedAt = tick()
			stored[write.key] = variable
			return .success(self.variable(write.key)!)
		}
	}

	private func variable(_ key: String) -> NetlifyVariable? {
		guard let variable = stored[key] else { return nil }
		let values = variable.values
			.map { NetlifyVariable.Value(id: $0.value.id, context: $0.key) }
			.sorted { $0.id < $1.id }
		return NetlifyVariable(key: key, isSecret: variable.isSecret, values: values, updatedAt: variable.updatedAt)
	}

	private func tick() -> Date {
		clock += 1
		return Date(timeIntervalSince1970: clock)
	}

	private func newValueID() -> String {
		nextValue += 1
		return String(format: "value-%04d", nextValue)
	}
}

func netlifyTarget(_ context: NetlifyPublishTarget.Context = .production, site: String = "site-storefront") -> NetlifyPublishTarget {
	NetlifyPublishTarget(
		userID: "5f1a2b3c4d5e6f7a8b9c0d1e", userName: "Tolga", teamID: "team_northwind", teamName: "Northwind",
		siteID: site, siteName: "storefront", context: context)
}

struct NetlifyPublishingTests {
	private let fingerprintKey = SymmetricKey(size: .bits256)
	private let rules = ProjectEnvSchemaOverview(
		rules: [ProjectEnvSchemaOverview.Rule(key: "PUBLIC_URL", isPublic: true, source: nil, badges: [])], groups: [])

	private func plan(
		_ values: [String: String],
		snapshot: NetlifyRemoteSnapshot,
		context: NetlifyPublishTarget.Context = .production,
		history: PublishHistory? = nil,
		destination: PublishDestination? = nil
	) -> PublishPlan {
		PublishPlan(
			destination: destination ?? PublishDestination(sourceEnvironment: "production", target: .netlify(netlifyTarget(context)), createdAt: Date()),
			values: values, rules: rules, check: nil, remote: snapshot.variables, remoteKeys: snapshot.keys,
			platform: NetlifyPublishing.platform, history: history, fingerprintKey: fingerprintKey)
	}

	private func snapshot(_ api: FakeNetlifyAPI, _ context: NetlifyPublishTarget.Context = .production) async throws -> NetlifyRemoteSnapshot {
		try NetlifyPublishing.snapshot(try await api.variables(siteID: "site-storefront", teamID: "team_northwind").get(), for: context).get()
	}

	private func changes(_ plan: PublishPlan, _ values: [String: String], selecting keys: Set<String>? = nil) throws -> [PublishPlan.Change] {
		var selection = PublishPlan.Selection(defaultsOf: plan)
		for key in keys ?? [] { selection.set(key, selected: true, in: plan) }
		return try plan.changes(for: selection, values: values, fingerprintKey: fingerprintKey).get()
	}

	@Test("a variable applies to the context through its own value; one with a value for every context, or only for others, doesn't")
	func snapshotClassifies() async throws {
		let api = FakeNetlifyAPI()
		api.seed("OWN", [.production: "p", .deployPreview: "d"], secret: true)
		api.seed("EVERYWHERE", [.all: "a"])
		api.seed("ELSEWHERE", [.deployPreview: "d"], secret: true)
		api.seed("STAGING", [.branch("staging"): "s", .branchDeploy: "b"])
		let production = try await snapshot(api)
		#expect(Set(production.variables.keys) == ["OWN"])
		#expect(production.variables["OWN"]?.storedAsSecret == true && production.variables["OWN"]?.updatedAt != nil)
		#expect(production.keys["EVERYWHERE"]?.kind == .sameValueEverywhere && production.keys["EVERYWHERE"]?.storedAsSecret == false)
		#expect(production.keys["ELSEWHERE"]?.kind == .elsewhere && production.keys["ELSEWHERE"]?.storedAsSecret == true)
		#expect(production.keys["STAGING"]?.kind == .elsewhere)

		let staging = try await snapshot(api, .branch("staging"))
		#expect(Set(staging.variables.keys) == ["STAGING"])
		let other = try await snapshot(api, .branch("Staging"))
		#expect(other.variables.isEmpty, "Netlify's branch names are case-sensitive")
		#expect(other.keys["STAGING"]?.kind == .elsewhere)
	}

	@Test("a key listed twice, or with two values for the context, is refused with its name escaped")
	func duplicates() {
		let value = NetlifyVariable.Value(id: "v1", context: .production)
		let twice = [NetlifyVariable(key: "A\u{202E}", isSecret: false, values: [value], updatedAt: nil),
			NetlifyVariable(key: "A\u{202E}", isSecret: false, values: [], updatedAt: nil)]
		#expect(NetlifyPublishing.snapshot(twice, for: .production) == .failure(.duplicateKeys(["A\u{202E}"])))
		#expect(NetlifySnapshotError.duplicateKeys(["A\u{202E}"]).message.contains(#"A\u{202e}"#))
		let doubled = [NetlifyVariable(key: "B", isSecret: false, values: [value, NetlifyVariable.Value(id: "v2", context: .production)], updatedAt: nil)]
		#expect(NetlifyPublishing.snapshot(doubled, for: .production) == .failure(.duplicateKeys(["B"])))
	}

	@Test("Netlify's own names, names it doesn't accept, and values longer than it takes can't be published")
	func rules() async throws {
		let values = [
			"CONTEXT": "x", "_PRIVATE": "x", String(repeating: "K", count: 256): "x",
			"LONG": String(repeating: "é", count: NetlifyPublishing.maximumValueCharacters + 1),
			"FITS": String(repeating: "é", count: NetlifyPublishing.maximumValueCharacters), "API_TOKEN": "t",
		]
		let plan = plan(values, snapshot: NetlifyRemoteSnapshot(variables: [:], keys: [:]))
		#expect(plan.row("CONTEXT")?.holds.first == .reserved)
		#expect(plan.row("_PRIVATE")?.holds.first == .nameNotAccepted)
		#expect(plan.row(String(repeating: "K", count: 256))?.holds.first == .nameTooLong(limit: 255))
		#expect(plan.row("LONG")?.holds.first == .valueTooLong(limit: NetlifyPublishing.maximumValueCharacters))
		#expect(Set(PublishPlan.Selection(defaultsOf: plan).keys) == ["FITS", "API_TOKEN"])
		#expect(plan.rows.filter { !$0.isPublishable }.count == 4)
	}

	@Test("a variable with one value for every context can't be published to one of them")
	func sameValueEverywhere() async throws {
		let api = FakeNetlifyAPI()
		api.seed("DATABASE_URL", [.all: "postgres://shared"])
		let plan = plan(["DATABASE_URL": "postgres://prod"], snapshot: try await snapshot(api))
		let row = try #require(plan.row("DATABASE_URL"))
		#expect(row.holds.first == .sameValueEverywhere && !row.isPublishable && row.operation == .add)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		let chosen = selection.set("DATABASE_URL", selected: true, in: plan)
		#expect(!chosen)
	}

	@Test("variables only on Netlify that apply to the context are counted, its own or one value every context uses, and others aren't")
	func remoteOnly() async throws {
		let api = FakeNetlifyAPI()
		api.seed("OWN_ONLY", [.production: "p"])
		api.seed("EVERYWHERE_ONLY", [.all: "a"])
		api.seed("ELSEWHERE_ONLY", [.deployPreview: "d"])
		api.seed("API_TOKEN", [.all: "a"])
		#expect(plan(["API_TOKEN": "t"], snapshot: try await snapshot(api)).remoteOnlyCount == 2)
	}

	@Test("a value keeps the protection of its Netlify variable: a readable one stays readable, and is only sent when chosen")
	func protectionFollowsVariable() async throws {
		let api = FakeNetlifyAPI()
		api.seed("API_TOKEN", [.production: "old"])
		api.seed("SESSION_KEY", [.deployPreview: "d"])
		api.seed("PUBLIC_URL", [.production: "https://old"], secret: true)
		let values = ["API_TOKEN": "new", "SESSION_KEY": "s", "PUBLIC_URL": "https://new", "FRESH": "f"]
		let plan = plan(values, snapshot: try await snapshot(api))
		for key in ["API_TOKEN", "SESSION_KEY"] {
			let row = try #require(plan.row(key))
			#expect(!row.publishesAsSecret && row.holds == [.staysReadable] && row.isPublishable && !row.isSelectedByDefault)
		}
		let publicURL = try #require(plan.row("PUBLIC_URL"))
		#expect(publicURL.publishesAsSecret && publicURL.staysSecret && publicURL.holds.isEmpty)
		#expect(plan.row("FRESH")?.publishesAsSecret == true && plan.row("FRESH")?.holds.isEmpty == true)
	}

	@Test("a new key is created as a secret with Netlify's secret scopes, a readable one plainly, and existing ones get this context's value")
	func publishes() async throws {
		let api = FakeNetlifyAPI()
		api.seed("API_TOKEN", [.production: "old", .deployPreview: "preview"], secret: true)
		api.seed("SESSION_KEY", [.deployPreview: "d"], secret: true)
		let values = ["API_TOKEN": "new", "SESSION_KEY": "s", "PUBLIC_URL": "https://x", "FRESH": "f"]
		let reviewed = try await snapshot(api)
		let plan = plan(values, snapshot: reviewed)
		let sent = try changes(plan, values)
		let report = await NetlifyPublishing.publish(sent, to: netlifyTarget(), reviewed: reviewed, using: api)
		#expect(report.outcomes == ["API_TOKEN": .published, "SESSION_KEY": .published, "PUBLIC_URL": .published, "FRESH": .published])
		let methods = Dictionary(uniqueKeysWithValues: api.writes.map { ($0.key, $0.method) })
		#expect(methods == ["API_TOKEN": "PATCH", "SESSION_KEY": "PATCH", "PUBLIC_URL": "POST", "FRESH": "POST"])
		#expect(api.writes.allSatisfy { $0.context == "production" })
		#expect(api.isSecret("FRESH") == true && api.isSecret("PUBLIC_URL") == false)
		#expect(api.value(of: "API_TOKEN", in: .production) == "new" && api.value(of: "API_TOKEN", in: .deployPreview) == "preview")
		#expect(api.value(of: "SESSION_KEY", in: .production) == "s" && api.value(of: "SESSION_KEY", in: .deployPreview) == "d")
		let records = Dictionary(uniqueKeysWithValues: report.published.map { ($0.key, $0) })
		#expect(records.count == 4 && records.values.allSatisfy { $0.remoteID != nil && $0.remoteUpdatedAt != nil })
		#expect(records["FRESH"]?.publishedAsSecret == true && records["PUBLIC_URL"]?.publishedAsSecret == false)
		#expect(Set(report.advances.map(\.key)) == ["API_TOKEN", "SESSION_KEY"], "Only variables that existed move forward for other contexts")
	}

	@Test("a branch's destination writes that branch's value, beside the value branch deploys share")
	func branchValue() async throws {
		let api = FakeNetlifyAPI()
		api.seed("API_TOKEN", [.branchDeploy: "branches"], secret: true)
		let reviewed = try await snapshot(api, .branch("staging"))
		let values = ["API_TOKEN": "staging-token", "FRESH": "f"]
		let plan = plan(values, snapshot: reviewed, context: .branch("staging"))
		let report = await NetlifyPublishing.publish(try changes(plan, values), to: netlifyTarget(.branch("staging")), reviewed: reviewed, using: api)
		#expect(report.outcomes.values.allSatisfy { $0 == .published })
		#expect(api.writes.allSatisfy { $0.context == "branch:staging" })
		#expect(api.value(of: "API_TOKEN", in: .branch("staging")) == "staging-token")
		#expect(api.value(of: "API_TOKEN", in: .branchDeploy) == "branches")
	}

	@Test(
		"a key added, changed, removed, made a secret or given one value for every context on Netlify since the review isn't sent",
		arguments: ["added", "edited", "removed", "secret", "own value", "everywhere"]
	)
	func refusesDriftSinceReview(change: String) async throws {
		let api = FakeNetlifyAPI()
		api.seed("REPLACED", [.production: "old"], secret: true)
		api.seed("ELSEWHERE", [.deployPreview: "d"], secret: true)
		let values = ["NEW": "n", "REPLACED": "r", "ELSEWHERE": "e"]
		let reviewed = try await snapshot(api)
		let plan = plan(values, snapshot: reviewed)
		let affected: String
		switch change {
		case "added":
			api.seed("NEW", [.deployPreview: "someone"], secret: true)
			affected = "NEW"
		case "edited":
			api.edit("REPLACED", in: .production)
			affected = "REPLACED"
		case "removed":
			api.remove("ELSEWHERE")
			affected = "ELSEWHERE"
		case "secret":
			api.seed("ELSEWHERE", [.deployPreview: "d"], secret: false)
			affected = "ELSEWHERE"
		case "own value":
			api.edit("ELSEWHERE", in: .production)
			affected = "ELSEWHERE"
		default:
			api.seed("ELSEWHERE", [.all: "everywhere"], secret: false)
			affected = "ELSEWHERE"
		}
		let report = await NetlifyPublishing.publish(try changes(plan, values), to: netlifyTarget(), reviewed: reviewed, using: api)
		guard case .failed(let reason)? = report.outcomes[affected] else {
			Issue.record("\(affected) was sent: \(String(describing: report.outcomes[affected]))")
			return
		}
		#expect(reason.contains("since this review"))
		#expect(!api.writes.contains { $0.key == affected })
		#expect(report.outcomes.filter { $0.value == .published }.count == 2)
	}

	@Test(
		"an edit to another context made after the publish read the variables, but before it wrote, still shows for that context",
		arguments: [(false, false), (false, true), (true, false), (true, true)]
	)
	func siblingEditDuringPublish(replaces: Bool, renewsValueIDs: Bool) async throws {
		let api = FakeNetlifyAPI()
		api.renewsValueIDs = renewsValueIDs
		api.seed("API_TOKEN", replaces ? [.production: "old", .deployPreview: "p"] : [.deployPreview: "p"], secret: true)
		let listed = try await api.variables(siteID: "site-storefront", teamID: "team_northwind").get()
		let preview = try #require(listed.first?.values.first { $0.context == .deployPreview })
		let seen = try #require(listed.first?.updatedAt)
		let previewHistory = PublishHistory(publishedAt: seen, keys: ["API_TOKEN": PublishHistory.Key(
			fingerprint: Data(repeating: 1, count: PublishFingerprint.byteCount), publishedAt: seen, remoteID: preview.id,
			remoteUpdatedAt: seen, publishedAsSecret: true)])

		let reviewed = try await snapshot(api)
		let values = ["API_TOKEN": "new"]
		let plan = plan(values, snapshot: reviewed)
		api.afterNextListing = { $0.edit("API_TOKEN", in: .deployPreview, value: "someone") }
		let report = await NetlifyPublishing.publish(try changes(plan, values), to: netlifyTarget(), reviewed: reviewed, using: api)
		#expect(api.value(of: "API_TOKEN", in: .deployPreview) == "someone")
		let advanced = previewHistory.advancing(report.advances)
		#expect(advanced.keys["API_TOKEN"]?.remoteUpdatedAt == seen, "Deploy Previews still sees its variable changed on Netlify")
	}

	@Test("only a variable that other contexts share is read again right before its write")
	func rereadsSharedVariables() async throws {
		let api = FakeNetlifyAPI()
		api.seed("OWN_ONLY", [.production: "old"], secret: true)
		api.seed("SHARED", [.production: "old", .deployPreview: "p"], secret: true)
		api.seed("ELSEWHERE", [.deployPreview: "p"], secret: true)
		let values = ["OWN_ONLY": "a", "SHARED": "b", "ELSEWHERE": "c", "FRESH": "d"]
		let reviewed = try await snapshot(api)
		let report = await NetlifyPublishing.publish(try changes(plan(values, snapshot: reviewed), values), to: netlifyTarget(), reviewed: reviewed, using: api)
		#expect(report.outcomes.values.allSatisfy { $0 == .published })
		#expect(Set(api.keyReads) == ["SHARED", "ELSEWHERE"] && api.keyReads.count == 2)
		#expect(Set(report.advances.map(\.key)) == ["SHARED", "ELSEWHERE"])
	}

	@Test("a replacement Netlify gives no change time for isn't sent")
	func refusesTimelessReplace() async throws {
		let api = FakeNetlifyAPI()
		api.seed("API_TOKEN", [.production: "old"], secret: true)
		api.forgetTimes()
		let reviewed = try await snapshot(api)
		let plan = plan(["API_TOKEN": "new"], snapshot: reviewed)
		#expect(plan.row("API_TOKEN")?.holds.first == .unknownChangeTime)
		let change = PublishPlan.Change(
			key: "API_TOKEN", value: "new", operation: plan.row("API_TOKEN")!.operation, publishesAsSecret: true, fingerprint: Data())
		let report = await NetlifyPublishing.publish([change], to: netlifyTarget(), reviewed: reviewed, using: api)
		#expect(report.outcomes["API_TOKEN"].map { if case .failed(let text) = $0 { text.contains("doesn't say when") } else { false } } == true)
		#expect(api.writes.isEmpty)
	}

	@Test("a refused connection stops what hasn't been sent and asks to reconnect; a role that can't write stops too; one refused key doesn't")
	func stops() async throws {
		let values = Dictionary(uniqueKeysWithValues: (0..<10).map { ("KEY_\($0)", "v") })
		for (error, stopsLater) in [(NetlifyAPIError.unauthorized, true), (.forbidden, true), (.rejected(status: 422), false)] {
			let api = FakeNetlifyAPI()
			api.refusals["KEY_0"] = error
			let reviewed = try await snapshot(api)
			let plan = plan(values, snapshot: reviewed)
			let report = await NetlifyPublishing.publish(try changes(plan, values), to: netlifyTarget(), reviewed: reviewed, using: api)
			#expect(report.outcomes["KEY_0"] == .failed(NetlifyPublishing.message(error)))
			#expect(report.needsReconnect == (error == .unauthorized))
			let notSent = report.outcomes.values.filter { $0 == .notSent }.count
			#expect(stopsLater ? notSent == values.count - NetlifyPublishing.writeConcurrency : notSent == 0, "\(error)")
		}
	}

	@Test("a value Netlify stored readable, though sent as a secret, says so and is recorded as Netlify has it")
	func storedOtherwise() async throws {
		let api = FakeNetlifyAPI()
		api.storesReadable = ["API_TOKEN"]
		let reviewed = try await snapshot(api)
		let plan = plan(["API_TOKEN": "t"], snapshot: reviewed)
		let report = await NetlifyPublishing.publish(try changes(plan, ["API_TOKEN": "t"]), to: netlifyTarget(), reviewed: reviewed, using: api)
		#expect(report.outcomes["API_TOKEN"] == .failed("Netlify stored it readable, though LPM Vault sent it as a secret. Mark it as containing secret values on Netlify."))
		#expect(report.published.first?.publishedAsSecret == false)
	}

	@Test("a refusal names the HTTP status only, never Netlify's message, which could echo the value")
	func refusalText() {
		#expect(NetlifyPublishing.message(.rejected(status: 422)) == "Netlify refused it (HTTP 422).")
		#expect(NetlifyPublishing.message(.forbidden).contains("role"))
	}

	@Test("branch names that differ only in Unicode composition are different branches, as Git and Netlify keep them")
	func branchBytes() async throws {
		let composed = "caf\u{00E9}"
		let decomposed = "cafe\u{0301}"
		#expect(composed == decomposed, "Swift compares them as one string")
		#expect(NetlifyPublishTarget.Context.branch(composed) != .branch(decomposed))
		#expect(NetlifyVariable.Context.branch(composed) != .branch(decomposed))
		#expect(Set([NetlifyPublishTarget.Context.branch(composed), .branch(decomposed)]).count == 2)
		#expect(netlifyDestination(.branch(composed)).target.location != netlifyDestination(.branch(decomposed)).target.location)
		let api = FakeNetlifyAPI()
		api.seed("TOKEN", [.branch(composed): "a", .branch(decomposed): "b"], secret: true)
		let snapshot = try await snapshot(api, .branch(decomposed))
		#expect(snapshot.variables["TOKEN"] != nil, "Only the destination's own spelling is its value")
		let destinations = [netlifyDestination(.branch(composed)), netlifyDestination(.branch(decomposed), source: "other")]
		let data = try #require(PublishingRecords.encode(destinations, vaultID: publishTestVault))
		let decoded = try PublishingRecords.decodeDestinations(data, vaultID: publishTestVault).get()
		let branches = decoded.compactMap { if case .netlify(let target) = $0.target { target.context.branch } else { nil } }
		#expect(Set(branches.map { Array($0.utf8) }) == Set([Array(composed.utf8), Array(decomposed.utf8)]))
	}

	@Test("a write to a variable never prints its value")
	func writeRedacted() {
		let write = NetlifyVariableWrite(key: "API_TOKEN", value: "s3cret-value", context: .production, isSecret: true)
		var dumped = ""
		dump(write, to: &dumped)
		for text in [String(describing: write), String(reflecting: write), dumped] {
			#expect(!text.contains("s3cret-value"))
		}
	}

	@Test(
		"branch names Git and Netlify accept, with Netlify's trailing wildcard, are allowed; others aren't",
		arguments: [
			("staging", true), ("release/1.0", true), ("release/*", true), ("feature/día", true), ("deploy-preview", true),
			("", false), ("*", false), ("a*b", false), ("-x", false), ("/x", false), ("x/", false), ("a..b", false), ("a b", false),
			("a\u{202E}b", false), ("x.lock", false), ("a/.b", false), ("a:b", false), ("a~b", false), ("a\\b", false),
			("release.lock/staging", false), ("release.lock/*", false), ("a/b.lock/c", false), ("lockers/x", true), ("x.locks/y", true),
			(String(repeating: "b", count: 256), false),
		]
	)
	func branchNames(name: String, valid: Bool) {
		#expect(NetlifyPublishTarget.Context.isValidBranch(name) == valid)
	}
}
