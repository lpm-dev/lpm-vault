import CryptoKit
import Foundation
import Testing
@testable import LPMVault

/// A Vercel API that answers from memory and records what was sent.
final class FakeVercelAPI: VercelClientProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var created: [VercelVariableWrite] = []
	private var replaced: [(id: String, value: String, storage: VercelVariableWrite.Storage)] = []
	private var listings = 0
	private var projectListings = 0
	private var customListings = 0

	var account = VercelAccount(name: "Acme", slug: "acme")
	var projectList: [VercelProject] = [VercelProject(id: "prj_api", name: "demo-api", accountID: "team_acme")]
	var custom: [VercelCustomEnvironment] = []
	var variableList = VercelVariableList(variables: [], hiddenProductionCount: 0)
	var listFailure: VercelAPIError?
	/// Refuses reading the project's custom environments.
	var customFailure: VercelAPIError?
	/// Keys whose creation or replacement Vercel refuses, with the refusal.
	var refusals: [String: VercelAPIError] = [:]
	var createFailure: VercelAPIError?

	var createdWrites: [VercelVariableWrite] { lock.withLock { created } }
	var replacedValues: [(id: String, value: String, storage: VercelVariableWrite.Storage)] { lock.withLock { replaced } }
	var listingCount: Int { lock.withLock { listings } }
	var projectListingCount: Int { lock.withLock { projectListings } }
	var customListingCount: Int { lock.withLock { customListings } }
	/// Runs before each replacement is answered, as a slow Vercel would.
	var beforeReplace: (@Sendable () async -> Void)?
	/// Runs once new variables are created, as someone changing Vercel meanwhile would.
	var afterCreate: (@Sendable (FakeVercelAPI) -> Void)?

	func account(teamID: String?) async -> Result<VercelAccount, VercelAPIError> { .success(account) }
	func projects(teamID: String?) async -> Result<[VercelProject], VercelAPIError> {
		lock.withLock { projectListings += 1 }
		return .success(projectList)
	}
	func customEnvironments(projectID: String, teamID: String?) async -> Result<[VercelCustomEnvironment], VercelAPIError> {
		lock.withLock { customListings += 1 }
		if let customFailure { return .failure(customFailure) }
		return .success(custom)
	}

	func variables(projectID: String, teamID: String?) async -> Result<VercelVariableList, VercelAPIError> {
		lock.withLock { listings += 1 }
		if let listFailure { return .failure(listFailure) }
		return .success(variableList)
	}

	func create(_ writes: [VercelVariableWrite], projectID: String, teamID: String?) async -> Result<[String: Result<VercelEnvironmentVariable, VercelAPIError>], VercelAPIError> {
		if let createFailure { return .failure(createFailure) }
		lock.withLock { created.append(contentsOf: writes) }
		defer { afterCreate?(self) }
		var results: [String: Result<VercelEnvironmentVariable, VercelAPIError>] = [:]
		for write in writes {
			if let refusal = refusals[write.key] {
				results[write.key] = .failure(refusal)
			} else {
				results[write.key] = .success(VercelEnvironmentVariable(
					id: "env_\(write.key)", key: write.key, kind: write.storage == .sensitive ? .sensitive : .encrypted,
					isSecret: write.storage == .sensitive, targets: write.targets, customEnvironmentIDs: write.customEnvironmentIDs,
					gitBranch: nil, updatedAt: Date(timeIntervalSince1970: 1_760_000_100)))
			}
		}
		return .success(results)
	}

	func replace(_ variableID: String, key: String, value: String, storage: VercelVariableWrite.Storage, projectID: String, teamID: String?) async -> Result<VercelEnvironmentVariable, VercelAPIError> {
		await beforeReplace?()
		let key = variableID.replacingOccurrences(of: "env_", with: "")
		if let refusal = refusals[key] { return .failure(refusal) }
		lock.withLock { replaced.append((variableID, value, storage)) }
		return .success(VercelEnvironmentVariable(
			id: variableID, key: key, kind: storage == .sensitive ? .sensitive : .encrypted, isSecret: storage == .sensitive,
			targets: [.production], customEnvironmentIDs: [], gitBranch: nil, updatedAt: Date(timeIntervalSince1970: 1_760_000_200)))
	}
}

func vercelVariable(
	_ key: String, targets: Set<VercelEnvironmentVariable.Target> = [.production], custom: Set<String> = [],
	branch: String? = nil, secret: Bool = true, updatedAt: Date? = Date(timeIntervalSince1970: 1_760_000_000)
) -> VercelEnvironmentVariable {
	VercelEnvironmentVariable(
		id: "env_\(key)", key: key, kind: secret ? .sensitive : .encrypted, isSecret: secret, targets: targets,
		customEnvironmentIDs: custom, gitBranch: branch, updatedAt: updatedAt)
}

struct VercelPublishingTests {
	@Test("a variable applies to the environment it targets; a single Preview branch's doesn't apply to Preview")
	func applies() throws {
		let list = VercelVariableList(variables: [
			vercelVariable("PROD"),
			vercelVariable("BOTH", targets: [.production, .preview]),
			vercelVariable("BRANCH", targets: [.preview], branch: "feature-x"),
			vercelVariable("QA", targets: [], custom: ["env_qa"]),
			vercelVariable("DEV", targets: [.development], secret: false),
		], hiddenProductionCount: 0)
		let custom = [VercelCustomEnvironment(id: "env_qa", slug: "qa")]
		let production = try VercelPublishing.snapshot(list, for: .production, customEnvironments: custom).get()
		#expect(Set(production.variables.keys) == ["PROD", "BOTH"])
		#expect(production.variables["BOTH"]?.sharedWith == ["Preview"])
		#expect(production.variables["PROD"]?.storedAsSecret == true)
		#expect(production.elsewhereCount == 3)
		let preview = try VercelPublishing.snapshot(list, for: .preview, customEnvironments: custom).get()
		#expect(Set(preview.variables.keys) == ["BOTH"])
		#expect(preview.variables["BOTH"]?.sharedWith == ["Production"])
		let qa = try VercelPublishing.snapshot(list, for: .custom(id: "env_qa", name: "qa"), customEnvironments: custom).get()
		#expect(Set(qa.variables.keys) == ["QA"] && qa.variables["QA"]?.sharedWith == [])
		let development = try VercelPublishing.snapshot(list, for: .development, customEnvironments: custom).get()
		#expect(development.variables["DEV"]?.storedAsSecret == false)
	}

	@Test("a custom environment shared with others is named, and an unknown one still counts")
	func sharedCustomNames() throws {
		let list = VercelVariableList(variables: [
			vercelVariable("A", targets: [.preview], custom: ["env_qa", "env_gone"]),
		], hiddenProductionCount: 0)
		let snapshot = try VercelPublishing.snapshot(list, for: .preview, customEnvironments: [VercelCustomEnvironment(id: "env_qa", slug: "qa")]).get()
		#expect(snapshot.variables["A"]?.sharedWith == ["a custom environment", "qa"])
	}

	@Test("a production review can't be trusted while production variables are hidden; other environments can")
	func hiddenProduction() {
		let list = VercelVariableList(variables: [], hiddenProductionCount: 3)
		#expect(VercelPublishing.snapshot(list, for: .production, customEnvironments: []) == .failure(.hiddenProductionVariables(3)))
		#expect((try? VercelPublishing.snapshot(list, for: .preview, customEnvironments: []).get()) != nil)
	}

	@Test("two variables of one key in the same environment make the review ambiguous")
	func duplicates() {
		let list = VercelVariableList(variables: [
			vercelVariable("A"),
			VercelEnvironmentVariable(id: "env_A2", key: "A", kind: .encrypted, isSecret: false, targets: [.production],
				customEnvironmentIDs: [], gitBranch: nil, updatedAt: nil),
		], hiddenProductionCount: 0)
		#expect(VercelPublishing.snapshot(list, for: .production, customEnvironments: []) == .failure(.duplicateKeys(["A"])))
	}

	private typealias Item = (key: String, value: String, operation: PublishPlan.Operation, secret: Bool)

	/// What a review of `items` would send, with the variables it saw:
	/// each replacement's variable, as Vercel lists it for `environment`.
	private struct Review {
		let changes: [PublishPlan.Change]
		let reviewed: [String: PublishPlan.RemoteVariable]
		let listing: VercelVariableList

		/// The listing as Vercel's API answers it.
		var json: [String: Any] {
			["envs": listing.variables.map { variable -> [String: Any] in
				["id": variable.id, "key": variable.key, "type": variable.isSecret ? "sensitive" : "encrypted",
					"visibility": variable.isSecret ? "secret" : "config", "target": variable.targets.map(\.rawValue).sorted(), "value": "",
					"updatedAt": (variable.updatedAt?.timeIntervalSince1970 ?? 0) * 1_000]
			}]
		}
	}

	private func review(_ items: [Item], environment: VercelPublishTarget.Environment = .production) -> Review {
		let targets: Set<VercelEnvironmentVariable.Target> = switch environment {
		case .production: [.production]
		case .preview: [.preview]
		case .development: [.development]
		case .custom: []
		}
		let listing = VercelVariableList(
			variables: items.compactMap { item in
				guard case .replace(let id) = item.operation else { return nil }
				return VercelEnvironmentVariable(
					id: id, key: item.key, kind: item.secret ? .sensitive : .encrypted, isSecret: item.secret, targets: targets,
					customEnvironmentIDs: [], gitBranch: nil, updatedAt: Date(timeIntervalSince1970: 1_760_000_000))
			},
			hiddenProductionCount: 0)
		let reviewed = (try? VercelPublishing.snapshot(listing, for: environment, customEnvironments: []).get())?.variables ?? [:]
		let plan = PublishPlan(
			destination: vercelDestination(), values: Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.value) }),
			rules: ProjectEnvSchemaOverview(
				rules: items.filter { !$0.secret }.map { ProjectEnvSchemaOverview.Rule(key: $0.key, isPublic: true, source: nil, badges: []) },
				groups: []),
			check: nil, remote: reviewed,
			platform: PublishPlan.Platform(secretsStaySecret: true), history: nil, fingerprintKey: key)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		for item in items { selection.set(item.key, selected: true, confirmed: true, in: plan) }
		let changes = (try? plan.changes(for: selection, values: Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.value) }), fingerprintKey: key).get()) ?? []
		return Review(changes: changes, reviewed: reviewed, listing: listing)
	}

	/// Publishes `items` through `api`, which lists the variables the review saw.
	private func publish(_ items: [Item], to target: VercelPublishTarget, using api: FakeVercelAPI) async -> PublishReport {
		let review = review(items, environment: target.environment)
		api.variableList = review.listing
		return await VercelPublishing.publish(review.changes, to: target, reviewed: review.reviewed, using: api)
	}

	private let key = SymmetricKey(size: .bits256)

	@Test("adds go to the destination's environment only, secrets write-only and public keys readable; replaces keep the variable")
	func publishes() async throws {
		let api = FakeVercelAPI()
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .preview)
		let items: [Item] = [
			("SECRET", "s3cret\nline", .add, true),
			("NEXT_PUBLIC_URL", "https://x", .add, false),
			("API", "new", .replace(remoteID: "env_API"), true),
		]
		#expect(review(items, environment: .preview).changes.count == 3)
		let report = await publish(items, to: target, using: api)
		#expect(report.outcomes == ["SECRET": .published, "NEXT_PUBLIC_URL": .published, "API": .published])
		let writes = Dictionary(uniqueKeysWithValues: api.createdWrites.map { ($0.key, $0) })
		#expect(writes["SECRET"]?.storage == .sensitive && writes["SECRET"]?.value == "s3cret\nline")
		#expect(writes["SECRET"]?.targets == [.preview] && writes["SECRET"]?.customEnvironmentIDs.isEmpty == true)
		#expect(writes["NEXT_PUBLIC_URL"]?.storage == .encrypted)
		#expect(api.replacedValues.map(\.id) == ["env_API"] && api.replacedValues.first?.storage == .sensitive)
		let records = Dictionary(uniqueKeysWithValues: report.published.map { ($0.key, $0) })
		#expect(records["SECRET"]?.remoteID == "env_SECRET" && records["SECRET"]?.publishedAsSecret == true)
		#expect(records["NEXT_PUBLIC_URL"]?.publishedAsSecret == false)
		#expect(records["API"]?.remoteUpdatedAt == Date(timeIntervalSince1970: 1_760_000_200))
		#expect(!report.needsReconnect)
	}

	@Test("a custom environment is targeted by its ID")
	func customEnvironment() async {
		let api = FakeVercelAPI()
		let target = VercelPublishTarget(teamID: nil, accountID: "u_1", teamName: "Tolga", projectID: "prj_api",
			projectName: "demo-api", environment: .custom(id: "env_qa", name: "qa"))
		_ = await publish([("A", "1", .add, true)], to: target, using: api)
		#expect(api.createdWrites.first?.targets.isEmpty == true && api.createdWrites.first?.customEnvironmentIDs == ["env_qa"])
	}

	@Test("a refused key fails alone; a refused token stops the rest and asks to reconnect")
	func failures() async {
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .production)
		let api = FakeVercelAPI()
		api.refusals = ["B": .rejected(code: "invalid_value")]
		let report = await publish([("A", "1", .add, true), ("B", "2", .add, true), ("C", "3", .replace(remoteID: "env_C"), true)], to: target, using: api)
		#expect(report.outcomes["A"] == .published && report.outcomes["C"] == .published)
		#expect(report.outcomes["B"] == .failed("Vercel refused it (invalid_value)."))
		#expect(Set(report.published.map(\.key)) == ["A", "C"])

		let revoked = FakeVercelAPI()
		revoked.refusals = ["C": .unauthorized]
		let stopped = await publish(
			[("C", "x", .replace(remoteID: "env_C"), true)] + (1...6).map { ("K\($0)", "v", .replace(remoteID: "env_K\($0)"), true) },
			to: target, using: revoked)
		#expect(stopped.needsReconnect)
		#expect(stopped.outcomes["C"] == .failed(VercelPublishing.message(.unauthorized)))
		#expect(stopped.outcomes.values.contains(.notSent), "Replaces after the refused batch aren't sent")

		let noAdds = FakeVercelAPI()
		noAdds.createFailure = .unauthorized
		let none = await publish([("A", "1", .add, true), ("C", "3", .replace(remoteID: "env_C"), true)], to: target, using: noAdds)
		#expect(none.published.isEmpty && none.needsReconnect)
		#expect(none.outcomes["C"] == .notSent)
	}

	/// What Vercel answers a token it no longer accepts, as after the integration is uninstalled.
	static let revokedToken = PlatformHTTPStub.Reply.json(403, ["error": ["code": "forbidden", "message": "Not authorized", "invalidToken": true]])

	@Test("a revoked connection stops the publish at the first refusal, sends nothing more, and asks to reconnect")
	func revokedConnection() async throws {
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .production)
		let items: [Item] = [("NEW", "1", .add, true)] + (1...6).map { ("K\($0)", "v", .replace(remoteID: "env_K\($0)"), true) }
		let unread = review(items)
		let route = PlatformHTTPStub.platform { _ in Self.revokedToken }
		let report = await VercelPublishing.publish(
			unread.changes, to: target, reviewed: unread.reviewed,
			using: VercelClient(token: "vca_revoked", baseURL: route.baseURL, session: route.session))
		#expect(report.needsReconnect && report.published.isEmpty)
		#expect(items.allSatisfy { report.outcomes[$0.key] == .failed(VercelPublishing.message(.unauthorized)) })
		#expect(route.requests.allSatisfy { $0.method == "GET" }, "Nothing is written when Vercel refuses the token")

		let replaces = review((1...6).map { ("K\($0)", "v", .replace(remoteID: "env_K\($0)"), true) })
		let listing = PlatformHTTPStub.Reply.json(200, replaces.json)
		let replacesOnly = PlatformHTTPStub.platform { request in
			switch (request.method, request.url.path()) {
			case ("GET", "/v10/projects/prj_api/env"): listing
			case ("GET", _): .json(200, ["environments": []])
			default: Self.revokedToken
			}
		}
		let stopped = await VercelPublishing.publish(
			replaces.changes, to: target, reviewed: replaces.reviewed,
			using: VercelClient(token: "vca_revoked", baseURL: replacesOnly.baseURL, session: replacesOnly.session))
		#expect(stopped.needsReconnect)
		#expect(replacesOnly.requests.filter { $0.method == "PATCH" }.count == VercelPublishing.replaceConcurrency)
		#expect(stopped.outcomes.values.filter { $0 == .notSent }.count == 6 - VercelPublishing.replaceConcurrency)
	}

	@Test("a key the integration isn't allowed to change fails alone, and the rest are still sent")
	func permissionRefusal() async throws {
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .production)
		let review = review([("LOCKED", "1", .replace(remoteID: "env_LOCKED"), true), ("OPEN", "2", .replace(remoteID: "env_OPEN"), true)])
		let listing = PlatformHTTPStub.Reply.json(200, review.json)
		let route = PlatformHTTPStub.platform { request in
			if request.method == "GET" {
				return request.url.path().hasSuffix("/env") ? listing : .json(200, ["environments": []])
			}
			if request.url.path().hasSuffix("/env_LOCKED") {
				return .json(403, ["error": ["code": "forbidden", "message": "You don't have permission to change this variable."]])
			}
			let id = request.url.lastPathComponent
			return .json(200, ["id": id, "key": String(id.dropFirst("env_".count)), "type": "sensitive", "visibility": "secret", "target": ["production"], "value": ""])
		}
		let report = await VercelPublishing.publish(
			review.changes, to: target, reviewed: review.reviewed,
			using: VercelClient(token: "vca_1", baseURL: route.baseURL, session: route.session))
		#expect(!report.needsReconnect)
		#expect(report.outcomes["LOCKED"] == .failed(VercelPublishing.message(.forbidden)))
		#expect(report.outcomes["OPEN"] == .published)
	}

	@Test("keys in batches never sent read as not sent, not as an unreadable answer")
	func unsentBatches() async throws {
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .production)
		let calls = Counter()
		let route = PlatformHTTPStub.platform { request in
			if request.method == "GET" {
				return request.url.path().hasSuffix("/env") ? .json(200, ["envs": []]) : .json(200, ["environments": []])
			}
			calls.increment()
			guard calls.count == 1, let body = try? JSONSerialization.jsonObject(with: request.body) as? [[String: Any]] else {
				return PlatformHTTPStub.Reply(status: 200, body: Data("{not json".utf8))
			}
			return .json(201, ["created": body.map { ["id": "env_\($0["key"] as! String)", "key": $0["key"]!, "type": "sensitive", "target": ["production"]] }])
		}
		let count = VercelClient.createBatchSize * 2 + 5
		let review = review((0..<count).map { ("KEY_\($0)", "v", .add, true) })
		let report = await VercelPublishing.publish(
			review.changes, to: target, reviewed: review.reviewed,
			using: VercelClient(token: "vca_1", baseURL: route.baseURL, session: route.session))
		let outcomes = report.outcomes.values
		#expect(outcomes.filter { $0 == .published }.count == VercelClient.createBatchSize)
		#expect(outcomes.filter { $0 == .failed(VercelPublishing.message(.invalidResponse)) }.count == VercelClient.createBatchSize)
		#expect(outcomes.filter { $0 == .notSent }.count == 5)
	}

	@Test("a duplicate key's direction controls are escaped in the message")
	func escapesDuplicateKeys() {
		let list = VercelVariableList(variables: [vercelVariable("A\u{202E}B"), vercelVariable("A\u{202E}B")].enumerated().map { index, variable in
			VercelEnvironmentVariable(id: "env_\(index)", key: variable.key, kind: variable.kind, isSecret: true, targets: variable.targets,
				customEnvironmentIDs: [], gitBranch: nil, updatedAt: variable.updatedAt)
		}, hiddenProductionCount: 0)
		guard case .failure(let error) = VercelPublishing.snapshot(list, for: .production, customEnvironments: []) else {
			Issue.record("Not refused"); return
		}
		#expect(error.message.contains(#"A\u{202e}B"#) && !error.message.contains("\u{202E}"))
	}

	private static let production = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
		projectName: "demo-api", environment: .production)

	private func replacement(_ key: String) -> PublishPlan.Change {
		PublishPlan.Change(key: key, value: "new", operation: .replace(remoteID: "env_\(key)"), publishesAsSecret: true, fingerprint: Data())
	}

	@Test("sharing is compared by the environments' IDs, so a custom environment that can't be named now, or was renamed, isn't a change")
	func sharingByIdentity() async throws {
		let shared = VercelVariableList(variables: [vercelVariable("API", custom: ["env_qa"])], hiddenProductionCount: 0)
		let reviewed = try VercelPublishing.snapshot(shared, for: .production, customEnvironments: [VercelCustomEnvironment(id: "env_qa", slug: "qa")])
			.get().variables
		#expect(reviewed["API"]?.sharedWith == ["qa"])

		let unnamed = FakeVercelAPI()
		unnamed.variableList = shared
		unnamed.customFailure = .rateLimited(until: nil)
		let report = await VercelPublishing.publish([replacement("API")], to: Self.production, reviewed: reviewed, using: unnamed)
		#expect(report.outcomes["API"] == .published)

		let renamed = FakeVercelAPI()
		renamed.variableList = shared
		renamed.custom = [VercelCustomEnvironment(id: "env_qa", slug: "quality")]
		#expect(await VercelPublishing.publish([replacement("API")], to: Self.production, reviewed: reviewed, using: renamed).outcomes["API"] == .published)

		let widened = FakeVercelAPI()
		widened.variableList = VercelVariableList(variables: [vercelVariable("API", custom: ["env_qa", "env_new"])], hiddenProductionCount: 0)
		widened.custom = [VercelCustomEnvironment(id: "env_qa", slug: "qa")]
		#expect(await VercelPublishing.publish([replacement("API")], to: Self.production, reviewed: reviewed, using: widened).outcomes["API"]
			== .failed("Changed on Vercel since this review. Review again."))
		#expect(widened.replacedValues.isEmpty)
	}

	@Test("a variable Vercel doesn't say the change time of isn't replaced, and the reason says how to fix it")
	func unknownChangeTime() async throws {
		let api = FakeVercelAPI()
		api.variableList = VercelVariableList(variables: [vercelVariable("API", updatedAt: nil)], hiddenProductionCount: 0)
		let reviewed = try VercelPublishing.snapshot(api.variableList, for: .production, customEnvironments: []).get().variables
		let report = await VercelPublishing.publish([replacement("API")], to: Self.production, reviewed: reviewed, using: api)
		guard case .failed(let reason)? = report.outcomes["API"] else { Issue.record("Not refused"); return }
		#expect(reason.contains("doesn't say when") && reason.contains("Edit it once on Vercel"))
		#expect(api.replacedValues.isEmpty)
	}

	@Test("a variable changed on Vercel while new ones were sent isn't replaced: the variables are read again first")
	func rereadsBeforeReplacing() async throws {
		let api = FakeVercelAPI()
		api.variableList = VercelVariableList(variables: [vercelVariable("API")], hiddenProductionCount: 0)
		let reviewed = try VercelPublishing.snapshot(api.variableList, for: .production, customEnvironments: []).get().variables
		api.afterCreate = { api in
			api.variableList = VercelVariableList(
				variables: [vercelVariable("API", updatedAt: Date(timeIntervalSince1970: 1_760_000_900))], hiddenProductionCount: 0)
		}
		let added = PublishPlan.Change(key: "NEW", value: "1", operation: .add, publishesAsSecret: true, fingerprint: Data())
		let report = await VercelPublishing.publish([added, replacement("API")], to: Self.production, reviewed: reviewed, using: api)
		#expect(report.outcomes["NEW"] == .published)
		#expect(report.outcomes["API"] == .failed("Changed on Vercel since this review. Review again."))
		#expect(api.replacedValues.isEmpty && api.listingCount == 2)
	}

	@Test("a refusal says whether the variable was added, removed or changed on Vercel since the review")
	func driftWording() async throws {
		let api = FakeVercelAPI()
		api.variableList = VercelVariableList(variables: [vercelVariable("NEW")], hiddenProductionCount: 0)
		let added = PublishPlan.Change(key: "NEW", value: "1", operation: .add, publishesAsSecret: true, fingerprint: Data())
		let reviewed = ["GONE": PublishPlan.RemoteVariable(id: "env_GONE", updatedAt: Date(timeIntervalSince1970: 1_760_000_000))]
		let report = await VercelPublishing.publish([added, replacement("GONE")], to: Self.production, reviewed: reviewed, using: api)
		#expect(report.outcomes["NEW"] == .failed("Added on Vercel since this review. Review again."))
		#expect(report.outcomes["GONE"] == .failed("Removed on Vercel since this review. Review again."))
		#expect(api.createdWrites.isEmpty && api.replacedValues.isEmpty)
	}

	@Test("Vercel's reserved names are held back")
	func reserved() {
		#expect(VercelPublishing.reservedKeys.isSuperset(of: ["TZ", "AWS_SECRET_KEY", "NOW_REGION", "LAMBDA_TASK_ROOT"]))
		#expect(!VercelPublishing.reservedKeys.contains("AWS_REGION"), "Vercel allows the AWS SDK's own names")
	}
}

private final class Counter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	var count: Int { lock.withLock { value } }
	func increment() { lock.withLock { value += 1 } }
}
