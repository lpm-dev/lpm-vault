import CryptoKit
import Foundation
import Testing
@testable import LPMVault

/// A Coolify instance that answers from memory, keeps variables as Coolify
/// does, and records what was sent. Like Coolify, it copies a new production
/// variable of an application to its preview deployments, unlocked, unless a
/// preview variable with the key exists.
final class FakeCoolifyAPI: CoolifyClientProtocol, @unchecked Sendable {
	struct Write: Equatable {
		let method: String
		let key: String
		let value: String
		let isPreview: Bool
		let isLocked: Bool
	}

	private let lock = NSLock()
	private var stored: [CoolifyVariable] = []
	private var values: [String: String] = [:]
	private var sent: [Write] = []
	private var deletedIDs: [String] = []
	private var listings = 0
	private var resourceListings = 0
	private var clock = 1_760_000_000.0

	var team: Result<CoolifyTeam, CoolifyAPIError> = .success(CoolifyTeam(id: "0", name: "Root Team"))
	var resourceList: Result<[CoolifyResource], CoolifyAPIError> = .success([
		CoolifyResource(kind: .application, id: "app-api", name: "api", projectName: "Storefront", environmentName: "production", buildPack: "nixpacks"),
	])
	var buildPack: String? = "nixpacks"
	var listFailure: CoolifyAPIError?
	/// Writes Coolify refuses, by key and whether they're for preview deployments.
	var refusals: [String: CoolifyAPIError] = [:]
	var previewRefusals: [String: CoolifyAPIError] = [:]
	var deleteFailure: CoolifyAPIError?
	/// Runs before each listing after the first, as someone changing Coolify meanwhile would.
	var beforeLaterListing: (@Sendable (FakeCoolifyAPI) -> Void)?

	var variables: [CoolifyVariable] { lock.withLock { stored } }
	var writes: [Write] { lock.withLock { sent } }
	var deleted: [String] { lock.withLock { deletedIDs } }
	var listingCount: Int { lock.withLock { listings } }
	var resourceListingCount: Int { lock.withLock { resourceListings } }

	func value(of key: String, preview: Bool = false) -> String? {
		lock.withLock { values["\(preview).\(key)"] }
	}

	/// A variable as if someone made it in Coolify.
	@discardableResult
	func seed(_ key: String, value: String = "old", preview: Bool = false, locked: Bool = false) -> CoolifyVariable {
		lock.withLock { insert(key, value: value, preview: preview, locked: locked) }
	}

	/// Edits a variable as someone would in Coolify, which moves its time
	/// unless `keepsTime`, as an edit within the same second does.
	func edit(_ key: String, preview: Bool = false, keepsTime: Bool = false, value: String = "edited") {
		lock.withLock {
			guard let index = stored.firstIndex(where: { $0.key == key && $0.isPreview == preview }) else { return }
			values["\(preview).\(key)"] = value
			guard !keepsTime else { return }
			// An edit made a minute later, so Coolify's second-long times tell it apart.
			clock += 60
			stored[index] = variable(stored[index].id, key, preview: preview, locked: stored[index].isLocked, createdAt: stored[index].createdAt)
		}
	}

	/// A fake holding one variable updated at `time`, as Coolify writes it.
	func seeded(_ key: String, time: String) -> FakeCoolifyAPI {
		lock.withLock {
			stored.append(CoolifyVariable(id: "env-1", key: key, isPreview: false, isLocked: true, updatedAt: PlatformTimestamp.utc(time)))
		}
		return self
	}

	/// Drops every variable's times, as a Coolify that doesn't report them would.
	func forgetTimes() {
		lock.withLock {
			stored = stored.map { CoolifyVariable(id: $0.id, key: $0.key, isPreview: $0.isPreview, isLocked: $0.isLocked, updatedAt: nil) }
		}
	}

	func remove(_ key: String, preview: Bool = false) {
		lock.withLock { stored.removeAll { $0.key == key && $0.isPreview == preview } }
	}

	func team() async -> Result<CoolifyTeam, CoolifyAPIError> { team }
	func resources() async -> Result<[CoolifyResource], CoolifyAPIError> {
		lock.withLock { resourceListings += 1 }
		return resourceList
	}
	func buildPack(ofApplication id: String) async -> Result<String?, CoolifyAPIError> { .success(buildPack) }

	func variables(of resource: CoolifyPublishTarget.Resource, id: String) async -> Result<[CoolifyVariable], CoolifyAPIError> {
		let count = lock.withLock {
			listings += 1
			return listings
		}
		if count > 1 { beforeLaterListing?(self) }
		if let listFailure { return .failure(listFailure) }
		return .success(variables)
	}

	func create(_ write: CoolifyVariableWrite, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<String, CoolifyAPIError> {
		lock.withLock {
			sent.append(Write(method: "POST", key: write.key, value: write.value, isPreview: write.isPreview, isLocked: write.isLocked))
			if let refusal = (write.isPreview ? previewRefusals : refusals)[write.key] { return .failure(refusal) }
			guard !stored.contains(where: { $0.key == write.key && $0.isPreview == write.isPreview }) else { return .failure(.conflict) }
			let created = insert(write.key, value: write.value, preview: write.isPreview, locked: write.isLocked)
			if resource == .application, !write.isPreview, !stored.contains(where: { $0.key == write.key && $0.isPreview }) {
				insert(write.key, value: write.value, preview: true, locked: false)
			}
			return .success(created.id)
		}
	}

	func update(_ write: CoolifyVariableWrite, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<CoolifyVariable, CoolifyAPIError> {
		lock.withLock {
			sent.append(Write(method: "PATCH", key: write.key, value: write.value, isPreview: write.isPreview, isLocked: write.isLocked))
			if let refusal = refusals[write.key] { return .failure(refusal) }
			guard let index = stored.firstIndex(where: { $0.key == write.key && $0.isPreview == write.isPreview }) else {
				return .failure(.notFound)
			}
			stored[index] = variable(stored[index].id, write.key, preview: write.isPreview, locked: write.isLocked, createdAt: stored[index].createdAt)
			values["\(write.isPreview).\(write.key)"] = write.value
			return .success(stored[index])
		}
	}

	func delete(_ variableID: String, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<Void, CoolifyAPIError> {
		lock.withLock {
			deletedIDs.append(variableID)
			if let deleteFailure { return .failure(deleteFailure) }
			stored.removeAll { $0.id == variableID }
			return .success(())
		}
	}

	@discardableResult
	private func insert(_ key: String, value: String, preview: Bool, locked: Bool) -> CoolifyVariable {
		let created = variable("uuid-\(preview ? "preview" : "production")-\(key.lowercased().replacingOccurrences(of: "_", with: "-"))", key, preview: preview, locked: locked)
		stored.append(created)
		values["\(preview).\(key)"] = value
		return created
	}

	private func variable(_ id: String, _ key: String, preview: Bool, locked: Bool, createdAt: Date? = nil) -> CoolifyVariable {
		clock += 1
		let now = Date(timeIntervalSince1970: clock)
		return CoolifyVariable(id: id, key: key, isPreview: preview, isLocked: locked, updatedAt: now, createdAt: createdAt ?? now)
	}
}

struct CoolifyPublishingTests {
	@Test(
		"values Coolify would change on their way to an app are named, and only those",
		arguments: [
			("plain-value", []),
			("$HOME and ${PATH}", []),
			("line one\nline two", []),
			("it's", [.singleQuote]),
			("C:\\path\\", [.trailingBackslash]),
			(#"{"a":1,"b":"it's"}"#, []),
			(#"{"a":"$secret"}"#, [.unquotedJSON]),
			("[1,\n2]", [.unquotedJSON]),
			(#"{"note":"a #b"}"#, [.unquotedJSON]),
			("{not json'", [.singleQuote]),
			("{{team.DATABASE_URL}}", [.reference]),
			("postgres://{{ project.HOST }}/db", [.reference]),
			("{{vault.TOKEN}}", [.reference]),
			("{{other.X}}", []),
			("{{team.UNCLOSED", []),
			(" padded ", [.trimmed]),
			("-----BEGIN KEY-----\nabc\n-----END KEY-----\n", [.trimmed]),
			(" it's ", [.singleQuote, .trimmed]),
		] as [(String, [PublishPlan.ValueIssue])]
	)
	func valueIssues(value: String, expected: [PublishPlan.ValueIssue]) {
		#expect(CoolifyPublishing.valueIssues(value) == expected)
	}

	@Test("a duplicate key's direction controls are escaped in Coolify's message")
	func escapesDuplicateKeys() {
		let list = ["env-1", "env-2"].map {
			CoolifyVariable(id: $0, key: "A\u{202E}B", isPreview: false, isLocked: true, updatedAt: Date(timeIntervalSince1970: 1_760_000_000))
		}
		guard case .failure(let error) = CoolifyPublishing.snapshot(list, for: .production) else { Issue.record("Not refused"); return }
		#expect(error.message.contains(#"A\u{202e}B"#) && !error.message.contains("\u{202E}"))
	}

	@Test("a publish from a cancelled task reads and writes nothing")
	func cancelledPublish() async {
		let api = FakeCoolifyAPI()
		let target = CoolifyPublishTarget(
			instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: "0", teamName: "Root Team", resource: .application,
			resourceID: "app-api", resourceName: "api", projectName: "Storefront", environmentName: "production", deployments: .production)
		let change = PublishPlan.Change(key: "A", value: "1", operation: .add, publishesAsSecret: true, fingerprint: Data())
		let report = await Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return await CoolifyPublishing.publish([change], to: target, reviewed: [:], using: api)
		}.value
		#expect(report.outcomes["A"] == .notSent)
		#expect(api.listingCount == 0 && api.writes.isEmpty)
	}

	@Test("Coolify's own names are reserved where it makes them: every SERVICE_ one in a service, a compose application's routes")
	func reservedNames() {
		let service = CoolifyPublishing.platform(for: .service, buildPack: nil)
		#expect(service.isReserved("SERVICE_PASSWORD_POSTGRES") && !service.isReserved("DATABASE_URL"))
		let compose = CoolifyPublishing.platform(for: .application, buildPack: "dockercompose")
		#expect(compose.isReserved("SERVICE_URL_API") && compose.isReserved("SERVICE_FQDN_WEB") && compose.isReserved("SERVICE_NAME_DB"))
		#expect(!compose.isReserved("SERVICE_TOKEN"))
		let nixpacks = CoolifyPublishing.platform(for: .application, buildPack: "nixpacks")
		#expect(!nixpacks.isReserved("SERVICE_URL_API") && nixpacks.maximumKeyBytes == 255 && !nixpacks.secretsStaySecret)
	}

	@Test("a name Coolify can't hold, or a value it would break, can't be chosen; a trimmed or referencing value can")
	func holds() throws {
		let destination = coolifyDestination()
		let key = SymmetricKey(size: .bits256)
		let long = String(repeating: "K", count: 256)
		let plan = PublishPlan(
			destination: destination,
			values: [long: "x", "QUOTED": "it's", "PEM": "key\n", "REF": "{{team.DB}}", "SERVICE_URL_API": "x", "PLAIN": "x"],
			rules: .empty, check: nil, remote: [:],
			platform: CoolifyPublishing.platform(for: .application, buildPack: "dockercompose"),
			history: nil, fingerprintKey: key)
		#expect(plan.row(long)?.holds.first == .nameTooLong(limit: 255) && plan.row(long)?.isPublishable == false)
		#expect(plan.row("QUOTED")?.holds == [.changesValue(.singleQuote)] && plan.row("QUOTED")?.isPublishable == false)
		#expect(plan.row("SERVICE_URL_API")?.holds == [.reserved])
		for selectable in ["PEM", "REF"] {
			let row = try #require(plan.row(selectable))
			#expect(row.isPublishable && !row.isSelectedByDefault, "\(selectable)")
		}
		var selection = PublishPlan.Selection(defaultsOf: plan)
		#expect(selection.keys == ["PLAIN"])
		let choosesTrimmed = selection.set("PEM", selected: true, in: plan)
		let choosesBroken = selection.set("QUOTED", selected: true, in: plan)
		#expect(choosesTrimmed && !choosesBroken)
		#expect(selection.keys == ["PLAIN", "PEM"])
	}

	@Test("a review sees only the destination's deployments, with locked variables as secrets")
	func snapshot() throws {
		let list = [
			CoolifyVariable(id: "a", key: "API", isPreview: false, isLocked: true, updatedAt: Date(timeIntervalSince1970: 1)),
			CoolifyVariable(id: "b", key: "API", isPreview: true, isLocked: false, updatedAt: nil),
			CoolifyVariable(id: "c", key: "PREVIEW_ONLY", isPreview: true, isLocked: false, updatedAt: nil),
		]
		let production = try CoolifyPublishing.snapshot(list, for: .production).get()
		#expect(production.variables.keys.sorted() == ["API"] && production.variables["API"]?.storedAsSecret == true)
		#expect(production.elsewhereCount == 2 && production.previewKeys == ["API", "PREVIEW_ONLY"])
		let preview = try CoolifyPublishing.snapshot(list, for: .preview).get()
		#expect(preview.variables.keys.sorted() == ["API", "PREVIEW_ONLY"] && preview.variables["API"]?.id == "b")
		let doubled = list + [CoolifyVariable(id: "d", key: "API", isPreview: false, isLocked: false, updatedAt: nil)]
		#expect(CoolifyPublishing.snapshot(doubled, for: .production) == .failure(.duplicateKeys(["API"])))
	}

	// MARK: - Publish

	private func target(_ resource: CoolifyPublishTarget.Resource = .application, _ deployments: CoolifyPublishTarget.Deployments = .production) -> CoolifyPublishTarget {
		CoolifyPublishTarget(
			instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: "0", teamName: "Root Team",
			resource: resource, resourceID: resource == .application ? "app-api" : "svc-db", resourceName: "api",
			projectName: "Storefront", environmentName: "production", deployments: deployments)
	}

	private func coolifyDestination(_ target: CoolifyPublishTarget? = nil) -> PublishDestination {
		PublishDestination(sourceEnvironment: "production", target: .coolify(target ?? self.target()), createdAt: Date(timeIntervalSince1970: 1_750_000_000))
	}

	/// Reviews `values` against the fake's variables and chooses `keys`, as the Publish sheet would.
	private func changes(
		_ values: [String: String],
		secrets: Set<String> = [],
		choosing keys: Set<String>? = nil,
		api: FakeCoolifyAPI,
		target: CoolifyPublishTarget? = nil
	) async throws -> (changes: [PublishPlan.Change], reviewed: [String: PublishPlan.RemoteVariable]) {
		let target = target ?? self.target()
		let snapshot = try CoolifyPublishing.snapshot(await api.variables(of: target.resource, id: target.resourceID).get(), for: target.deployments).get()
		let rules = ProjectEnvSchemaOverview(
			rules: values.keys.map { ProjectEnvSchemaOverview.Rule(key: $0, isPublic: !secrets.contains($0), source: nil, badges: []) }, groups: [])
		let key = SymmetricKey(size: .bits256)
		let plan = PublishPlan(
			destination: coolifyDestination(target), values: values, rules: rules, check: nil, remote: snapshot.variables,
			platform: CoolifyPublishing.platform(for: target.resource, buildPack: nil), history: nil, fingerprintKey: key)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		for row in plan.rows where keys?.contains(row.key) ?? true { selection.set(row.key, selected: true, confirmed: true, in: plan) }
		return (try plan.changes(for: selection, values: values, fingerprintKey: key).get(), snapshot.variables)
	}

	@Test("new variables are created and existing ones replaced, with what Coolify accepted recorded")
	func publishes() async throws {
		let api = FakeCoolifyAPI()
		let existing = api.seed("REPLACED", locked: true)
		let (changes, reviewed) = try await changes(["NEW": "fresh", "REPLACED": "next"], secrets: ["REPLACED"], api: api)
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: api)
		#expect(report.outcomes == ["NEW": .published, "REPLACED": .published])
		#expect(api.writes.contains(.init(method: "PATCH", key: "REPLACED", value: "next", isPreview: false, isLocked: true)))
		#expect(api.writes.contains(.init(method: "POST", key: "NEW", value: "fresh", isPreview: false, isLocked: false)))
		#expect(api.value(of: "NEW") == "fresh" && api.value(of: "REPLACED") == "next")
		let records = Dictionary(uniqueKeysWithValues: report.published.map { ($0.key, $0) })
		let created = try #require(api.variables.first { $0.key == "NEW" && !$0.isPreview })
		#expect(records["NEW"]?.remoteID == created.id && records["NEW"]?.remoteUpdatedAt == created.updatedAt,
			"A new variable's time comes from reading the variables again")
		#expect(records["REPLACED"]?.remoteID == existing.id && records["REPLACED"]?.publishedAsSecret == true)
		#expect(records["REPLACED"]?.remoteUpdatedAt == api.variables.first { $0.key == "REPLACED" && !$0.isPreview }?.updatedAt)
		#expect(!report.needsReconnect)
	}

	@Test("a new production secret gets a locked copy for preview deployments first, so Coolify never makes an unlocked one")
	func locksPreviewCopy() async throws {
		let api = FakeCoolifyAPI()
		api.seed("ALREADY", value: "preview's own", preview: true)
		let (changes, reviewed) = try await changes(
			["SECRET": "s3cret", "PUBLIC_URL": "https://x", "ALREADY": "v"], secrets: ["SECRET", "ALREADY"], api: api)
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: api)
		#expect(report.outcomes.values.allSatisfy { $0 == .published })
		let previews = Dictionary(uniqueKeysWithValues: api.variables.filter(\.isPreview).map { ($0.key, $0) })
		#expect(previews["SECRET"]?.isLocked == true && api.value(of: "SECRET", preview: true) == "s3cret")
		#expect(previews["PUBLIC_URL"]?.isLocked == false, "Coolify's own copy of a readable value stays as Coolify makes it")
		#expect(api.value(of: "ALREADY", preview: true) == "preview's own", "A preview variable that already exists is left alone")
		#expect(api.writes.filter { $0.key == "SECRET" }.map(\.isPreview) == [true, false], "The locked copy comes first")
	}

	@Test("when the production variable is refused after its locked copy, the copy is removed, or the reason says it stays")
	func removesOrphanedCopy() async throws {
		let api = FakeCoolifyAPI()
		api.refusals["SECRET"] = .rejected("Validation failed.")
		let (changes, reviewed) = try await changes(["SECRET": "s3cret"], secrets: ["SECRET"], api: api)
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: api)
		#expect(report.outcomes["SECRET"] == .failed("Coolify refused it: Validation failed."))
		#expect(api.variables.isEmpty && api.deleted.count == 1)

		let stuck = FakeCoolifyAPI()
		stuck.refusals["SECRET"] = .rejected("Validation failed.")
		stuck.deleteFailure = .transport
		let again = try await self.changes(["SECRET": "s3cret"], secrets: ["SECRET"], api: stuck)
		let stuckReport = await CoolifyPublishing.publish(again.changes, to: target(), reviewed: again.reviewed, using: stuck)
		guard case .failed(let reason)? = stuckReport.outcomes["SECRET"] else { Issue.record("Not failed"); return }
		#expect(reason.contains("Its locked copy for preview deployments stays in Coolify"))
	}

	@Test("a key changed, added or removed in Coolify since the review isn't sent")
	func refusesChangesSinceReview() async throws {
		let api = FakeCoolifyAPI()
		api.seed("EDITED")
		api.seed("REMOVED")
		api.seed("KEPT")
		let (changes, reviewed) = try await changes(["EDITED": "1", "REMOVED": "2", "KEPT": "3", "ADDED": "4"], api: api)
		api.beforeLaterListing = { api in
			api.beforeLaterListing = nil
			api.edit("EDITED")
			api.remove("REMOVED")
			api.seed("ADDED", value: "someone else's")
		}
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: api)
		#expect(report.outcomes["EDITED"] == .failed("Changed in Coolify since this review. Review again."))
		#expect(report.outcomes["REMOVED"] == .failed("Removed in Coolify since this review. Review again."))
		#expect(report.outcomes["ADDED"] == .failed("Added in Coolify since this review. Review again."))
		#expect(report.outcomes["KEPT"] == .published)
		#expect(api.writes.map(\.key) == ["KEPT"] && api.value(of: "ADDED") == "someone else's")
	}

	@Test("a variable Coolify gives no time for isn't replaced, since a change to it can't be seen")
	func refusesTimelessReplace() async throws {
		let api = FakeCoolifyAPI()
		api.seed("TIMELESS")
		api.forgetTimes()
		let (planned, reviewed) = try await changes(["TIMELESS": "next"], api: api)
		#expect(planned.isEmpty, "The review holds it back")
		let id = try #require(reviewed["TIMELESS"]?.id)
		let changes = [PublishPlan.Change(key: "TIMELESS", value: "next", operation: .replace(remoteID: id), publishesAsSecret: true, fingerprint: Data())]
		api.edit("TIMELESS", keepsTime: true, value: "someone else's")
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: api)
		#expect(report.outcomes["TIMELESS"] == .failed("Coolify doesn't say when this variable last changed, so LPM Vault can't tell whether it changed since this review. Edit it once in Coolify, then review again."))
		#expect(api.writes.isEmpty && api.value(of: "TIMELESS") == "someone else's")
	}

	@Test("a new variable is recorded with the time Coolify made it, not the time of an edit made right after")
	func recordsCreationTime() async throws {
		let api = FakeCoolifyAPI()
		let (changes, reviewed) = try await changes(["NEW": "fresh"], api: api)
		api.beforeLaterListing = { api in
			if api.listingCount == 3 { api.edit("NEW") }
		}
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: api)
		let variable = try #require(api.variables.first { $0.key == "NEW" && !$0.isPreview })
		let record = try #require(report.published.first)
		#expect(variable.updatedAt != variable.createdAt, "Someone edited it after it was made")
		#expect(record.remoteUpdatedAt == variable.createdAt)
	}

	@Test("finding references takes time in proportion to a value's length, even full of unclosed ones", .hangLimit)
	func referenceScanIsLinear() {
		// A quarter of a million openings: a scan that looks for a closing after each one reads
		// the rest of the value each time, and takes over an hour; one that reads it once, a moment.
		let unclosed = String(repeating: "{{team.", count: 250_000)
		#expect(!CoolifyPublishing.containsReference(unclosed))
		let closedAtTheEnd = String(repeating: "{{team ", count: 250_000) + "}}"
		#expect(!CoolifyPublishing.containsReference(closedAtTheEnd), "Each opening before the closing is checked, and none starts a reference")
		#expect(CoolifyPublishing.containsReference(String(closedAtTheEnd.dropLast(2)) + "{{team.NAME}}"))
	}

	@Test("a refusal that echoes the value or the token shows neither")
	func refusalHidesWhatWasSent() async throws {
		let route = PlatformHTTPStub.coolify { request in
			request.method == "GET"
				? .json(200, [["uuid": "env-1", "key": "API", "is_preview": false, "is_shown_once": true, "updated_at": "2026-10-14T12:00:00.000000Z"]])
				: .json(422, ["message": "s3cret-value is not valid for 3|coolify-token", "errors": ["value": ["s3cret-value"]]])
		}
		let client = CoolifyClient(instance: try CoolifyInstance.parse(route.baseURL.absoluteString).get(), token: "3|coolify-token", session: route.session)
		let (changes, reviewed) = try await changes(["API": "s3cret-value"], secrets: ["API"], api: FakeCoolifyAPI().seeded("API", time: "2026-10-14T12:00:00.000000Z"))
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: client)
		guard case .failed(let reason)? = report.outcomes["API"] else { Issue.record("Not refused"); return }
		#expect(reason == "Coolify refused it: (value)")
		#expect(!reason.contains("s3cret-value") && !reason.contains("coolify-token"))
	}

	@Test("a refused token stops what isn't sent yet and says to reconnect; a read that fails sends nothing")
	func stopsOnRefusedToken() async throws {
		let api = FakeCoolifyAPI()
		let values = Dictionary(uniqueKeysWithValues: (1...9).map { ("KEY_\($0)", "v") })
		let (changes, reviewed) = try await changes(values, api: api)
		api.refusals = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, CoolifyAPIError.unauthorized) })
		let report = await CoolifyPublishing.publish(changes, to: target(), reviewed: reviewed, using: api)
		#expect(report.needsReconnect && report.published.isEmpty)
		#expect(api.writes.count == CoolifyPublishing.writeConcurrency, "Only the first batch went out")
		#expect(report.outcomes.values.filter { $0 == .notSent }.count == values.count - CoolifyPublishing.writeConcurrency)

		let unreadable = FakeCoolifyAPI()
		let more = try await self.changes(["A": "1"], api: unreadable)
		unreadable.listFailure = .apiDisabled
		let none = await CoolifyPublishing.publish(more.changes, to: target(), reviewed: more.reviewed, using: unreadable)
		#expect(none.outcomes == ["A": .failed(CoolifyPublishing.message(.apiDisabled))] && unreadable.writes.isEmpty)
	}

	@Test("preview deployments and services get their own variables, with no copies made")
	func previewAndService() async throws {
		let api = FakeCoolifyAPI()
		let preview = target(.application, .preview)
		let previewChanges = try await changes(["SECRET": "s"], secrets: ["SECRET"], api: api, target: preview)
		_ = await CoolifyPublishing.publish(previewChanges.changes, to: preview, reviewed: previewChanges.reviewed, using: api)
		#expect(api.writes == [.init(method: "POST", key: "SECRET", value: "s", isPreview: true, isLocked: true)])

		let services = FakeCoolifyAPI()
		let service = target(.service)
		let serviceChanges = try await changes(["SECRET": "s"], secrets: ["SECRET"], api: services, target: service)
		_ = await CoolifyPublishing.publish(serviceChanges.changes, to: service, reviewed: serviceChanges.reviewed, using: services)
		#expect(services.writes == [.init(method: "POST", key: "SECRET", value: "s", isPreview: false, isLocked: true)])
		#expect(services.variables.count == 1, "Coolify copies only an application's variables")
	}
}
