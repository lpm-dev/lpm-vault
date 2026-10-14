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

	var account = VercelAccount(name: "Acme", slug: "acme")
	var projectList: [VercelProject] = [VercelProject(id: "prj_api", name: "demo-api", accountID: "team_acme")]
	var custom: [VercelCustomEnvironment] = []
	var variableList = VercelVariableList(variables: [], hiddenProductionCount: 0)
	var listFailure: VercelAPIError?
	/// Keys whose creation or replacement Vercel refuses, with the refusal.
	var refusals: [String: VercelAPIError] = [:]
	var createFailure: VercelAPIError?

	var createdWrites: [VercelVariableWrite] { lock.withLock { created } }
	var replacedValues: [(id: String, value: String, storage: VercelVariableWrite.Storage)] { lock.withLock { replaced } }
	var listingCount: Int { lock.withLock { listings } }
	var projectListingCount: Int { lock.withLock { projectListings } }

	func account(teamID: String?) async -> Result<VercelAccount, VercelAPIError> { .success(account) }
	func projects(teamID: String?) async -> Result<[VercelProject], VercelAPIError> {
		lock.withLock { projectListings += 1 }
		return .success(projectList)
	}
	func customEnvironments(projectID: String, teamID: String?) async -> Result<[VercelCustomEnvironment], VercelAPIError> { .success(custom) }

	func variables(projectID: String, teamID: String?) async -> Result<VercelVariableList, VercelAPIError> {
		lock.withLock { listings += 1 }
		if let listFailure { return .failure(listFailure) }
		return .success(variableList)
	}

	func create(_ writes: [VercelVariableWrite], projectID: String, teamID: String?) async -> Result<[String: Result<VercelEnvironmentVariable, VercelAPIError>], VercelAPIError> {
		if let createFailure { return .failure(createFailure) }
		lock.withLock { created.append(contentsOf: writes) }
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

	func replace(_ variableID: String, value: String, storage: VercelVariableWrite.Storage, projectID: String, teamID: String?) async -> Result<VercelEnvironmentVariable, VercelAPIError> {
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

	private func changes(_ items: [(String, String, PublishPlan.Operation, Bool)]) -> [PublishPlan.Change] {
		let plan = PublishPlan(
			destination: vercelDestination(), values: Dictionary(uniqueKeysWithValues: items.map { ($0.0, $0.1) }),
			rules: ProjectEnvSchemaOverview(
				rules: items.filter { !$0.3 }.map { ProjectEnvSchemaOverview.Rule(key: $0.0, isPublic: true, source: nil, badges: []) },
				groups: []),
			check: nil,
			remote: Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, PublishPlan.RemoteVariable)? in
				guard case .replace(let id) = item.2 else { return nil }
				return (item.0, PublishPlan.RemoteVariable(id: id, updatedAt: nil, storedAsSecret: item.3))
			}),
			platform: PublishPlan.Platform(secretsStaySecret: true), history: nil, fingerprintKey: key)
		var selection = PublishPlan.Selection(defaultsOf: plan)
		for item in items { selection.set(item.0, selected: true, in: plan) }
		return (try? plan.changes(for: selection, values: Dictionary(uniqueKeysWithValues: items.map { ($0.0, $0.1) }), fingerprintKey: key).get()) ?? []
	}

	private let key = SymmetricKey(size: .bits256)

	@Test("adds go to the destination's environment only, secrets write-only and public keys readable; replaces keep the variable")
	func publishes() async throws {
		let api = FakeVercelAPI()
		let sent = changes([
			("SECRET", "s3cret\nline", .add, true),
			("NEXT_PUBLIC_URL", "https://x", .add, false),
			("API", "new", .replace(remoteID: "env_API"), true),
		])
		#expect(sent.count == 3)
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .preview)
		let report = await VercelPublishing.publish(sent, to: target, using: api)
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
		_ = await VercelPublishing.publish(changes([("A", "1", .add, true)]), to: target, using: api)
		#expect(api.createdWrites.first?.targets.isEmpty == true && api.createdWrites.first?.customEnvironmentIDs == ["env_qa"])
	}

	@Test("a refused key fails alone; a refused token stops the rest and asks to reconnect")
	func failures() async {
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .production)
		let api = FakeVercelAPI()
		api.refusals = ["B": .rejected(code: "invalid_value", message: "Too long")]
		let sent = changes([("A", "1", .add, true), ("B", "2", .add, true), ("C", "3", .replace(remoteID: "env_C"), true)])
		let report = await VercelPublishing.publish(sent, to: target, using: api)
		#expect(report.outcomes["A"] == .published && report.outcomes["C"] == .published)
		#expect(report.outcomes["B"] == .failed("Vercel refused it: Too long"))
		#expect(Set(report.published.map(\.key)) == ["A", "C"])

		let revoked = FakeVercelAPI()
		revoked.refusals = ["C": .unauthorized]
		let replaces = changes([("C", "x", .replace(remoteID: "env_C"), true)] + (1...6).map { ("K\($0)", "v", .replace(remoteID: "env_K\($0)"), true) })
		let stopped = await VercelPublishing.publish(replaces, to: target, using: revoked)
		#expect(stopped.needsReconnect)
		#expect(stopped.outcomes["C"] == .failed(VercelPublishing.message(.unauthorized)))
		#expect(stopped.outcomes.values.contains(.notSent), "Replaces after the refused batch aren't sent")

		let noAdds = FakeVercelAPI()
		noAdds.createFailure = .unauthorized
		let none = await VercelPublishing.publish(changes([("A", "1", .add, true), ("C", "3", .replace(remoteID: "env_C"), true)]), to: target, using: noAdds)
		#expect(none.published.isEmpty && none.needsReconnect)
		#expect(none.outcomes["C"] == .notSent)
	}

	/// What Vercel answers a token it no longer accepts, as after the integration is uninstalled.
	static let revokedToken = PlatformHTTPStub.Reply.json(403, ["error": ["code": "forbidden", "message": "Not authorized", "invalidToken": true]])

	@Test("a revoked connection stops the publish at the first refusal, sends nothing more, and asks to reconnect")
	func revokedConnection() async throws {
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .production)
		let route = PlatformHTTPStub.platform { _ in Self.revokedToken }
		let client = VercelClient(token: "vca_revoked", baseURL: route.baseURL, session: route.session)
		let sent = changes([("NEW", "1", .add, true)] + (1...6).map { ("K\($0)", "v", .replace(remoteID: "env_K\($0)"), true) })
		let report = await VercelPublishing.publish(sent, to: target, using: client)
		#expect(report.needsReconnect)
		#expect(report.outcomes["NEW"] == .failed(VercelPublishing.message(.unauthorized)))
		#expect((1...6).allSatisfy { report.outcomes["K\($0)"] == .notSent })
		#expect(route.requests.count == 1, "Nothing is sent after Vercel refuses the token")
		#expect(report.published.isEmpty)

		let replacesOnly = PlatformHTTPStub.platform { _ in Self.revokedToken }
		let stopped = await VercelPublishing.publish(
			changes((1...6).map { ("K\($0)", "v", .replace(remoteID: "env_K\($0)"), true) }), to: target,
			using: VercelClient(token: "vca_revoked", baseURL: replacesOnly.baseURL, session: replacesOnly.session))
		#expect(stopped.needsReconnect && replacesOnly.requests.count == VercelPublishing.replaceConcurrency)
		#expect(stopped.outcomes.values.filter { $0 == .notSent }.count == 6 - VercelPublishing.replaceConcurrency)
	}

	@Test("a key the integration isn't allowed to change fails alone, and the rest are still sent")
	func permissionRefusal() async throws {
		let target = VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
			projectName: "demo-api", environment: .production)
		let route = PlatformHTTPStub.platform { request in
			if request.url.path().hasSuffix("/env_LOCKED") {
				return .json(403, ["error": ["code": "forbidden", "message": "You don't have permission to change this variable."]])
			}
			return .json(200, ["id": request.url.lastPathComponent, "key": "K", "type": "sensitive", "visibility": "secret", "target": ["production"], "value": ""])
		}
		let report = await VercelPublishing.publish(
			changes([("LOCKED", "1", .replace(remoteID: "env_LOCKED"), true), ("OPEN", "2", .replace(remoteID: "env_OPEN"), true)]),
			to: target, using: VercelClient(token: "vca_1", baseURL: route.baseURL, session: route.session))
		#expect(!report.needsReconnect)
		#expect(report.outcomes["LOCKED"] == .failed(VercelPublishing.message(.forbidden)))
		#expect(report.outcomes["OPEN"] == .published)
	}

	@Test("Vercel's reserved names are held back")
	func reserved() {
		#expect(VercelPublishing.reservedKeys.isSuperset(of: ["TZ", "AWS_SECRET_KEY", "NOW_REGION", "LAMBDA_TASK_ROOT"]))
		#expect(!VercelPublishing.reservedKeys.contains("AWS_REGION"), "Vercel allows the AWS SDK's own names")
	}
}
