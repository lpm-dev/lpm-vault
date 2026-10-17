import CryptoKit
import Foundation
import Testing
@testable import LPMVault

/// GitHub's Actions API for tests: repositories with environments, and each
/// scope's secrets and variables with the second GitHub last wrote them.
/// A secret's sealed value is kept as sent; `opened` reads it when the
/// publish sealed it with a test sealer.
final class FakeGitHubAPI: GitHubClientProtocol, @unchecked Sendable {
	enum Operation: Hashable, Sendable {
		case listSecrets, listVariables, secret, variable, publicKey, setSecret, createVariable, updateVariable, repository, environments
	}

	struct Record: Sendable {
		var value: Data
		var updatedAt: Date
	}

	struct Scope: Sendable {
		var secrets: [String: Record] = [:]
		var variables: [String: Record] = [:]
	}

	private let lock = NSLock()
	private var repositoryNames: [String: String] = ["1296269": "northwind/storefront", "88": "northwind/api"]
	private var environmentLists: [String: [GitHubEnvironment]] = [
		"northwind/storefront": [GitHubEnvironment(id: "161088068", name: "production"), GitHubEnvironment(id: "161088069", name: "staging/eu")],
	]
	private var scopes: [String: Scope] = [:]
	private var clock = Date(timeIntervalSince1970: 1_760_000_000)
	/// Each operation's scripted answers, in order: a failure, or nil to answer as usual.
	private var failures: [Operation: [(error: GitHubAPIError, then: (@Sendable () -> Void)?)?]] = [:]
	private var dropped: Set<String> = []
	private var log: [(Operation, String)] = []
	/// Runs before each write, as when someone edits on GitHub at that moment.
	var beforeWrite: (@Sendable (FakeGitHubAPI, String) -> Void)?
	let publicKey = GitHubPublicKey(id: "568250167242549743", key: Data((0..<32).map { UInt8($0 * 3 + 1) }))

	private static func key(_ scope: GitHubScope) -> String { scope.repository + "|" + (scope.environment ?? "") }

	/// Each request, as the operation and the name it was about, in order.
	var requests: [(Operation, String)] { lock.withLock { log } }
	var writeCount: Int { requests.filter { [.setSecret, .createVariable, .updateVariable].contains($0.0) }.count }

	/// Fails the operation's next requests with `errors`, after answering `passing` of them as usual.
	func fail(_ operation: Operation, after passing: Int = 0, with errors: GitHubAPIError...) {
		lock.withLock {
			failures[operation, default: []].append(contentsOf: Array(repeating: nil, count: passing) + errors.map { ($0, nil) })
		}
	}

	/// Fails the operation's next request with `error`, running `then` as it
	/// answers, as when someone edits on GitHub while a rate limit is waited out.
	func fail(_ operation: Operation, with error: GitHubAPIError, then: @escaping @Sendable () -> Void) {
		lock.withLock { failures[operation, default: []].append((error, then)) }
	}

	func rename(_ id: String, to name: String) {
		lock.withLock {
			let old = repositoryNames[id]
			repositoryNames[id] = name
			if let old, let environments = environmentLists.removeValue(forKey: old) { environmentLists[name] = environments }
			for (key, scope) in scopes where key.hasPrefix((old ?? "") + "|") {
				scopes.removeValue(forKey: key)
				scopes[name + key.dropFirst(old?.count ?? 0)] = scope
			}
		}
	}

	func removeEnvironments(of repository: String) {
		lock.withLock { environmentLists[repository] = [] }
	}

	/// Deletes the repository's environment and makes another with the same name.
	func replaceEnvironment(of repository: String, name: String, withID id: String) {
		lock.withLock {
			environmentLists[repository] = (environmentLists[repository] ?? []).map { $0.name == name ? GitHubEnvironment(id: id, name: name) : $0 }
		}
	}

	/// Sets a secret or a variable as someone on GitHub would, one second later.
	func edit(_ name: String, secret: Bool, value: String = "edited", in scope: GitHubScope) {
		lock.withLock {
			clock.addTimeInterval(1)
			var current = scopes[Self.key(scope)] ?? Scope()
			let record = Record(value: Data(value.utf8), updatedAt: clock)
			if secret { current.secrets[name] = record } else { current.variables[name] = record }
			scopes[Self.key(scope)] = current
		}
	}

	func remove(_ name: String, secret: Bool, in scope: GitHubScope) {
		lock.withLock {
			if secret { scopes[Self.key(scope)]?.secrets[name] = nil } else { scopes[Self.key(scope)]?.variables[name] = nil }
		}
	}

	func secretValue(_ name: String, in scope: GitHubScope) -> Data? { lock.withLock { scopes[Self.key(scope)]?.secrets[name]?.value } }
	func variableValue(_ name: String, in scope: GitHubScope) -> String? {
		lock.withLock { scopes[Self.key(scope)]?.variables[name].map { String(decoding: $0.value, as: UTF8.self) } }
	}
	func names(in scope: GitHubScope) -> (secrets: Set<String>, variables: Set<String>) {
		lock.withLock {
			let current = scopes[Self.key(scope)] ?? Scope()
			return (Set(current.secrets.keys), Set(current.variables.keys))
		}
	}

	/// Names whose writes GitHub accepts but that are gone by the time they're read back.
	func dropWrites(of name: String) {
		lock.withLock { _ = dropped.insert(name) }
	}

	private func begin(_ operation: Operation, _ name: String) -> GitHubAPIError? {
		let failure = lock.withLock { () -> (error: GitHubAPIError, then: (@Sendable () -> Void)?)? in
			log.append((operation, name))
			guard var pending = failures[operation], !pending.isEmpty else { return nil }
			let failure = pending.removeFirst()
			failures[operation] = pending
			return failure ?? nil
		}
		failure?.then?()
		return failure?.error
	}

	func user() async -> Result<GitHubUser, GitHubAPIError> { .success(GitHubUser(id: "583231", login: "octocat", name: nil)) }

	func repositories() async -> Result<[GitHubRepository], GitHubAPIError> {
		if let error = begin(.repository, "*") { return .failure(error) }
		return .success(lock.withLock { repositoryNames.map { GitHubRepository(id: $0.key, fullName: $0.value, isPrivate: true) } })
	}

	func repository(id: String) async -> Result<GitHubRepository, GitHubAPIError> {
		if let error = begin(.repository, id) { return .failure(error) }
		guard let name = lock.withLock({ repositoryNames[id] }) else { return .failure(.notFound) }
		return .success(GitHubRepository(id: id, fullName: name, isPrivate: true))
	}

	func environments(of repository: String) async -> Result<[GitHubEnvironment], GitHubAPIError> {
		if let error = begin(.environments, repository) { return .failure(error) }
		return .success(lock.withLock { environmentLists[repository] ?? [] })
	}

	func secrets(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> {
		if let error = begin(.listSecrets, Self.key(scope)) { return .failure(error) }
		return .success(lock.withLock { (scopes[Self.key(scope)]?.secrets ?? [:]).map { GitHubValueRecord(name: $0.key, updatedAt: $0.value.updatedAt) } })
	}

	func secret(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		if let error = begin(.secret, name) { return .failure(error) }
		return .success(lock.withLock { scopes[Self.key(scope)]?.secrets[name].map { GitHubValueRecord(name: name, updatedAt: $0.updatedAt) } })
	}

	func publicKey(of scope: GitHubScope) async -> Result<GitHubPublicKey, GitHubAPIError> {
		if let error = begin(.publicKey, Self.key(scope)) { return .failure(error) }
		return .success(publicKey)
	}

	func setSecret(_ name: String, to sealed: GitHubSealedSecret, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		beforeWrite?(self, name)
		if let error = begin(.setSecret, name) { return .failure(error) }
		guard sealed.keyID == publicKey.id else { return .failure(.rejected(status: 422)) }
		write(name, secret: true, value: sealed.ciphertext, in: scope)
		return .success(())
	}

	func variables(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> {
		if let error = begin(.listVariables, Self.key(scope)) { return .failure(error) }
		return .success(lock.withLock { (scopes[Self.key(scope)]?.variables ?? [:]).map { GitHubValueRecord(name: $0.key, updatedAt: $0.value.updatedAt) } })
	}

	func variable(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		if let error = begin(.variable, name) { return .failure(error) }
		return .success(lock.withLock { scopes[Self.key(scope)]?.variables[name].map { GitHubValueRecord(name: name, updatedAt: $0.updatedAt) } })
	}

	func createVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		beforeWrite?(self, name)
		if let error = begin(.createVariable, name) { return .failure(error) }
		guard lock.withLock({ scopes[Self.key(scope)]?.variables[name] }) == nil else { return .failure(.rejected(status: 409)) }
		write(name, secret: false, value: Data(value.utf8), in: scope)
		return .success(())
	}

	func updateVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		beforeWrite?(self, name)
		if let error = begin(.updateVariable, name) { return .failure(error) }
		guard lock.withLock({ scopes[Self.key(scope)]?.variables[name] }) != nil else { return .failure(.notFound) }
		write(name, secret: false, value: Data(value.utf8), in: scope)
		return .success(())
	}

	private func write(_ name: String, secret: Bool, value: Data, in scope: GitHubScope) {
		lock.withLock {
			guard !dropped.contains(name) else { return }
			clock.addTimeInterval(1)
			var current = scopes[Self.key(scope)] ?? Scope()
			let record = Record(value: value, updatedAt: clock)
			if secret { current.secrets[name] = record } else { current.variables[name] = record }
			scopes[Self.key(scope)] = current
		}
	}
}

/// Seals a value for tests as "sealed:<key id byte>:<value>", so a test can read what was sent.
let testGitHubSeal: @Sendable (String, Data) -> Data? = { value, key in Data("sealed:\(key.first ?? 0):\(value)".utf8) }

struct SealedBoxTests {
	@Test("the bundled engine seals a value to a GitHub key: 48 bytes longer, with a fresh ephemeral key each time")
	func seals() throws {
		let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
		let first = try #require(SealedBox.seal("s3cr3t ✓", to: key))
		let second = try #require(SealedBox.seal("s3cr3t ✓", to: key))
		#expect(first.count == "s3cr3t ✓".utf8.count + SealedBox.overheadBytes)
		#expect(first.prefix(32) != second.prefix(32) && first != second)
		#expect(SealedBox.seal("", to: key)?.count == SealedBox.overheadBytes)
	}

	@Test("a key of the wrong length, or a value larger than the engine seals, isn't sealed")
	func refuses() {
		let key = Data(repeating: 7, count: 32)
		#expect(SealedBox.seal("x", to: Data(repeating: 7, count: 31)) == nil)
		#expect(SealedBox.seal(String(repeating: "x", count: SealedBox.maximumPlaintextBytes + 1), to: key) == nil)
		#expect(SealedBox.seal(String(repeating: "x", count: SealedBox.maximumPlaintextBytes), to: key) != nil)
	}
}

struct GitHubPublishingRulesTests {
	@Test("names are kept as GitHub keeps them: capitals, digits and underscores, not starting with a digit or GITHUB_")
	func acceptsNames() {
		for name in ["API_TOKEN", "_PRIVATE", "A1", "X"] { #expect(GitHubPublishing.isAcceptedKey(name)) }
		for name in ["api_token", "Api_Token", "1API", "API-TOKEN", "API TOKEN", ""] { #expect(!GitHubPublishing.isAcceptedKey(name)) }
		let platform = GitHubPublishing.platform(readableKeys: [])
		#expect(platform.isReserved("GITHUB_TOKEN") && !platform.isReserved("MY_GITHUB_TOKEN"))
		#expect(platform.maximumValueBytes == 48 * 1_024 && platform.protectionFollowsVariable)
	}

	@Test("a scope's secrets and variables are read by name, and a name with both is held")
	func snapshot() throws {
		let at = Date(timeIntervalSince1970: 1_760_000_100)
		let snapshot = try GitHubPublishing.snapshot(
			secrets: [GitHubValueRecord(name: "API_TOKEN", updatedAt: at), GitHubValueRecord(name: "BOTH", updatedAt: at)],
			variables: [GitHubValueRecord(name: "PUBLIC_URL", updatedAt: at), GitHubValueRecord(name: "BOTH", updatedAt: at.addingTimeInterval(5))]
		).get()
		#expect(snapshot.variables["API_TOKEN"] == PublishPlan.RemoteVariable(id: "secret", updatedAt: at, storedAsSecret: true))
		#expect(snapshot.variables["PUBLIC_URL"] == PublishPlan.RemoteVariable(id: "variable", updatedAt: at, storedAsSecret: false))
		#expect(snapshot.variables["BOTH"] == nil)
		#expect(snapshot.keys["BOTH"] == PublishPlan.RemoteKey(kind: .duplicated, storedAsSecret: true, updatedAt: at.addingTimeInterval(5)))
		#expect(GitHubPublishing.snapshot(
			secrets: [GitHubValueRecord(name: "A", updatedAt: at), GitHubValueRecord(name: "A", updatedAt: at)], variables: []
		) == .failure(.duplicateNames(["A"])))
	}
}

struct GitHubPlanTests {
	private let destination = PublishDestination(
		sourceEnvironment: "production",
		target: .github(GitHubPublishTarget(
			userID: "583231", userLogin: "octocat", repositoryID: "1296269", repositoryName: "northwind/storefront", scope: .repository)),
		createdAt: Date(timeIntervalSince1970: 1_760_000_000))
	private let key = SymmetricKey(size: .bits256)

	private func plan(
		_ values: [String: String],
		ciVariables: Set<String> = [],
		rules: ProjectEnvSchemaOverview = .empty,
		remote: [String: PublishPlan.RemoteVariable] = [:],
		remoteKeys: [String: PublishPlan.RemoteKey] = [:]
	) -> PublishPlan {
		PublishPlan(
			destination: destination, values: values, rules: rules, check: nil, remote: remote, remoteKeys: remoteKeys,
			platform: GitHubPublishing.platform(readableKeys: ciVariables), history: nil, fingerprintKey: key)
	}

	@Test("keys publish as secrets unless the rules keep them in CI variables, whatever makes them public")
	func storageFollowsCIRules() throws {
		let rules = ProjectEnvSchemaOverview(
			rules: [
				ProjectEnvSchemaOverview.Rule(key: "NEXT_PUBLIC_URL", isPublic: true, source: nil, badges: []),
				ProjectEnvSchemaOverview.Rule(key: "LOG_LEVEL", isPublic: false, source: nil, badges: [], isCIVariable: true),
			],
			groups: [])
		#expect(rules.ciVariableKeys == ["LOG_LEVEL"])
		let plan = plan(["NEXT_PUBLIC_URL": "https://x", "LOG_LEVEL": "info", "API_TOKEN": "t"], ciVariables: rules.ciVariableKeys, rules: rules)
		#expect(plan.row("NEXT_PUBLIC_URL")?.publishesAsSecret == true, "A public value is a secret on GitHub unless its rule says ci: variable")
		#expect(plan.row("LOG_LEVEL")?.publishesAsSecret == false)
		#expect(plan.row("API_TOKEN")?.publishesAsSecret == true)
		#expect(plan.rows.allSatisfy { $0.isSelectedByDefault })
	}

	@Test("a key GitHub already keeps stays where it is, so a workflow reading it keeps working")
	func existingStorageWins() {
		let at = Date(timeIntervalSince1970: 1_760_000_100)
		let plan = plan(
			["API_TOKEN": "t", "LOG_LEVEL": "info"], ciVariables: ["LOG_LEVEL"],
			remote: [
				"API_TOKEN": .init(id: "variable", updatedAt: at, storedAsSecret: false),
				"LOG_LEVEL": .init(id: "secret", updatedAt: at, storedAsSecret: true),
			])
		let token = plan.row("API_TOKEN")
		#expect(token?.publishesAsSecret == false && token?.holds == [.staysReadable] && token?.isPublishable == true)
		let level = plan.row("LOG_LEVEL")
		#expect(level?.publishesAsSecret == true && level?.staysSecret == true && level?.holds.isEmpty == true)
	}

	@Test("a name GitHub would change, keeps for itself, holds as both a secret and a variable, or a value over 48 KB can't be published")
	func blocks() {
		let plan = plan(
			["api_token": "t", "GITHUB_TOKEN": "t", "BOTH": "t", "BIG": String(repeating: "é", count: 24 * 1_024 + 1)],
			remoteKeys: ["BOTH": .init(kind: .duplicated, storedAsSecret: true, updatedAt: Date())])
		#expect(plan.row("api_token")?.holds.contains(.nameNotAccepted) == true)
		#expect(plan.row("GITHUB_TOKEN")?.holds.contains(.reserved) == true)
		#expect(plan.row("BOTH")?.holds.contains(.duplicatedOnPlatform) == true)
		#expect(plan.row("BIG")?.holds.contains(.valueTooLarge(bytes: 48 * 1_024)) == true, "GitHub counts bytes, and é is two")
		#expect(plan.rows.allSatisfy { !$0.isPublishable })
		#expect(plan.remoteOnlyCount == 0)
		#expect(self.plan([:], remoteKeys: ["BOTH": .init(kind: .duplicated, storedAsSecret: true, updatedAt: Date())]).remoteOnlyCount == 2)
	}
}

struct GitHubDestinationTests {
	private let target = GitHubPublishTarget(
		userID: "583231", userLogin: "octocat", repositoryID: "1296269", repositoryName: "northwind/storefront",
		scope: .environment(id: "161088069", name: "staging/eu"))

	@Test("a destination is where it writes by GitHub's IDs, so a rename isn't another place")
	func locationByIDs() {
		var renamed = target
		renamed.repositoryName = "northwind/shop"
		renamed.scope = .environment(id: "161088069", name: "staging")
		#expect(PublishTarget.github(renamed).location == PublishTarget.github(target).location)
		var repository = target
		repository.scope = .repository
		#expect(PublishTarget.github(repository).location != PublishTarget.github(target).location)
		#expect(PublishTarget.github(target).placeName == "northwind/storefront / Environment staging/eu")
		#expect(PublishTarget.github(target).accountName == "northwind" && PublishTarget.github(target).connectionName == "octocat")
		#expect(target.connectionID == "github.583231")
	}

	@Test("a destination round-trips through the stored records, with either scope")
	func roundTrips() throws {
		let repository = GitHubPublishTarget(
			userID: "583231", userLogin: "octocat", repositoryID: "88", repositoryName: "northwind/api", scope: .repository)
		let destinations = [
			PublishDestination(sourceEnvironment: "staging", target: .github(target), createdAt: Date(timeIntervalSince1970: 1_760_000_000)),
			PublishDestination(sourceEnvironment: "production", target: .github(repository), createdAt: Date(timeIntervalSince1970: 1_760_000_000)),
		]
		let data = try #require(PublishingRecords.encode(destinations, vaultID: "vault-1"))
		#expect(Set(try PublishingRecords.decodeDestinations(data, vaultID: "vault-1").get()) == Set(destinations))
	}

	@Test("IDs, names and environment names are checked before a destination is stored")
	func validates() {
		func invalidity(_ change: (inout GitHubPublishTarget) -> Void) -> PublishDestinationInvalidity? {
			var changed = target
			change(&changed)
			return PublishDestination(sourceEnvironment: "staging", target: .github(changed), createdAt: Date()).invalidity
		}
		#expect(invalidity { _ in } == nil)
		#expect(invalidity { $0 = GitHubPublishTarget(userID: "x", userLogin: $0.userLogin, repositoryID: $0.repositoryID, repositoryName: $0.repositoryName, scope: $0.scope) } == .targetIdentifier)
		#expect(invalidity { $0.scope = .environment(id: "01", name: "prod") } == .targetIdentifier)
		#expect(invalidity { $0.repositoryName = "northwind" } == .targetName)
		#expect(invalidity { $0.repositoryName = "north wind/x" } == .targetName)
		#expect(invalidity { $0.repositoryName = "northwind/.." } == .targetName)
		#expect(invalidity { $0.scope = .environment(id: "1", name: "a\u{0007}b") } == .targetName)
		#expect(invalidity { $0.scope = .environment(id: "1", name: String(repeating: "e", count: 256)) } == .targetName)
	}
}

struct GitHubPublishTests {
	private let scope = GitHubScope(repository: "northwind/storefront", environment: nil)
	private let target = GitHubPublishTarget(
		userID: "583231", userLogin: "octocat", repositoryID: "1296269", repositoryName: "northwind/storefront", scope: .repository)
	private let fingerprintKey = SymmetricKey(size: .bits256)

	private func change(_ key: String, _ value: String, _ operation: PublishPlan.Operation = .add, secret: Bool = true) -> PublishPlan.Change {
		PublishPlan.Change(
			key: key, value: value, operation: operation, publishesAsSecret: secret,
			fingerprint: PublishFingerprint.of(value: value, key: key, destination: UUID(), using: fingerprintKey))
	}

	private func reviewed(_ api: FakeGitHubAPI) async throws -> GitHubRemoteSnapshot {
		try GitHubPublishing.snapshot(secrets: await api.secrets(in: scope).get(), variables: await api.variables(in: scope).get()).get()
	}

	private func publish(
		_ changes: [PublishPlan.Change],
		with api: FakeGitHubAPI,
		reviewed: GitHubRemoteSnapshot,
		to target: GitHubPublishTarget? = nil
	) async -> PublishReport {
		await GitHubPublishing.publish(changes, to: target ?? self.target, reviewed: reviewed, using: api, seal: testGitHubSeal)
	}

	/// The operations a publish made after `before` requests.
	private func operations(_ api: FakeGitHubAPI, after before: Int) -> [FakeGitHubAPI.Operation] {
		api.requests.dropFirst(before).map(\.0)
	}

	@Test("secrets are sealed to the scope's key and variables written as they are, one at a time, each read back for its time")
	func publishes() async throws {
		let api = FakeGitHubAPI()
		api.edit("LOG_LEVEL", secret: false, value: "debug", in: scope)
		let reviewed = try await reviewed(api)
		let before = api.requests.count
		let report = await publish([
			change("API_TOKEN", "t0k3n"),
			change("LOG_LEVEL", "info", .replace(remoteID: "variable"), secret: false),
			change("PUBLIC_URL", "https://x", secret: false),
		], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["API_TOKEN": .published, "LOG_LEVEL": .published, "PUBLIC_URL": .published])
		#expect(api.secretValue("API_TOKEN", in: scope) == Data("sealed:\(api.publicKey.key[0]):t0k3n".utf8))
		#expect(api.variableValue("LOG_LEVEL", in: scope) == "info" && api.variableValue("PUBLIC_URL", in: scope) == "https://x")
		#expect(operations(api, after: before) == [
			.repository, .listSecrets, .listVariables, .publicKey, .setSecret, .secret, .updateVariable, .variable, .createVariable, .variable,
		], "Two list pages cost less than reading three keys each from both kinds")
		let records = Dictionary(uniqueKeysWithValues: report.published.map { ($0.key, $0) })
		#expect(records["API_TOKEN"]?.remoteID == "secret" && records["API_TOKEN"]?.publishedAsSecret == true)
		#expect(records["LOG_LEVEL"]?.remoteID == "variable" && records["LOG_LEVEL"]?.publishedAsSecret == false)
		let snapshot = try await self.reviewed(api)
		for key in ["API_TOKEN", "LOG_LEVEL", "PUBLIC_URL"] {
			#expect(records[key]?.remoteUpdatedAt == snapshot.variables[key]?.updatedAt, "The history holds the time GitHub gave the write")
		}
	}

	@Test("a few keys in a large scope are each read from both kinds before they're written, instead of listing every page")
	func readsChosenKeys() async throws {
		let api = FakeGitHubAPI()
		for index in 0..<500 { api.edit("VAR_\(index)", secret: false, in: scope) }
		let reviewed = try await reviewed(api)
		let before = api.requests.count
		let report = await publish([change("API_TOKEN", "t")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["API_TOKEN": .published])
		#expect(operations(api, after: before) == [.repository, .secret, .variable, .publicKey, .setSecret, .secret])
	}

	@Test("a key added, changed, removed or moved on GitHub since the review isn't sent, whether listed or read on its own", arguments: [false, true])
	func refusesDrift(large: Bool) async throws {
		let api = FakeGitHubAPI()
		if large { for index in 0..<600 { api.edit("VAR_\(index)", secret: false, in: scope) } }
		for name in ["CHANGED", "REMOVED", "MOVED"] { api.edit(name, secret: true, in: scope) }
		let reviewed = try await reviewed(api)
		api.edit("CHANGED", secret: true, in: scope)
		api.remove("REMOVED", secret: true, in: scope)
		api.remove("MOVED", secret: true, in: scope)
		api.edit("MOVED", secret: false, in: scope)
		api.edit("ADDED", secret: false, in: scope)
		api.edit("BOTH", secret: true, in: scope)
		api.edit("BOTH", secret: false, in: scope)
		let before = api.requests.count
		let report = await publish([
			change("CHANGED", "v", .replace(remoteID: "secret")),
			change("REMOVED", "v", .replace(remoteID: "secret")),
			change("MOVED", "v", .replace(remoteID: "secret")),
			change("ADDED", "v"),
			change("BOTH", "v"),
		], with: api, reviewed: reviewed)
		#expect(report.outcomes == [
			"CHANGED": .failed("Changed on GitHub since this review. Review again."),
			"REMOVED": .failed("Removed on GitHub since this review. Review again."),
			"MOVED": .failed("Changed on GitHub since this review. Review again."),
			"ADDED": .failed("Added on GitHub since this review. Review again."),
			"BOTH": .failed("GitHub has both a secret and a variable with this name now. Remove one on GitHub, then review again."),
		])
		#expect(api.writeCount == 0 && report.published.isEmpty)
		#expect(!operations(api, after: before).contains(.publicKey), "Nothing to seal, so no key is read")
		#expect(operations(api, after: before).contains(.listVariables) == !large, "A large scope isn't listed for five keys")
	}

	@Test("a repository renamed, or an environment replaced, since the review stops the publish before anything is sent")
	func checksIdentity() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.rename("1296269", to: "northwind/shop")
		api.rename("88", to: "northwind/storefront")
		let renamed = await publish([change("API_TOKEN", "t")], with: api, reviewed: reviewed)
		#expect(renamed.outcomes == [
			"API_TOKEN": .failed("northwind/storefront was renamed northwind/shop on GitHub since this review. Review again."),
		])
		#expect(api.writeCount == 0)

		let replaced = FakeGitHubAPI()
		replaced.replaceEnvironment(of: "northwind/storefront", name: "production", withID: "999")
		var environment = target
		environment.scope = .environment(id: "161088068", name: "production")
		let report = await publish([change("API_TOKEN", "t")], with: replaced, reviewed: reviewed, to: environment)
		#expect(report.outcomes == [
			"API_TOKEN": .failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again."),
		])
		#expect(replaced.writeCount == 0)
	}

	@Test("a write held up by a rate limit is sent once it lifts, after checking the repository and reading the key from both kinds again")
	func waitsOutRateLimit() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let before = api.requests.count
		api.fail(.setSecret, with: .rateLimited(until: Date()))
		let report = await publish([change("API_TOKEN", "t")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["API_TOKEN": .published])
		#expect(operations(api, after: before) == [
			.repository, .secret, .variable, .publicKey, .setSecret, .repository, .secret, .variable, .setSecret, .secret,
		])
	}

	@Test("a repository or environment replaced under its name while a rate limit is waited out gets nothing", arguments: [
		FakeGitHubAPI.Operation.setSecret, .publicKey, .listSecrets, .secret,
	])
	func checksIdentityAfterWait(_ limited: FakeGitHubAPI.Operation) async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.fail(limited, with: .rateLimited(until: Date())) {
			api.rename("1296269", to: "northwind/shop")
			api.rename("88", to: "northwind/storefront")
		}
		let changes = limited == .listSecrets ? [change("A", "1"), change("B", "2")] : [change("A", "1")]
		let report = await publish(changes, with: api, reviewed: reviewed)
		let renamed = "northwind/storefront was renamed northwind/shop on GitHub since this review. Review again."
		#expect(report.outcomes.values.allSatisfy { $0 == .failed(renamed) } && report.outcomes.count == changes.count)
		#expect(api.names(in: scope) == ([], []), "Repository 88 now has the reviewed name, and gets nothing")
		#expect(api.names(in: GitHubScope(repository: "northwind/shop", environment: nil)) == ([], []))

		let environments = FakeGitHubAPI()
		var target = target
		target.scope = .environment(id: "161088068", name: "production")
		let production = GitHubScope(repository: "northwind/storefront", environment: "production")
		let environmentReview = try GitHubPublishing.snapshot(
			secrets: await environments.secrets(in: production).get(), variables: await environments.variables(in: production).get()
		).get()
		environments.fail(limited, with: .rateLimited(until: Date())) {
			environments.replaceEnvironment(of: "northwind/storefront", name: "production", withID: "999")
		}
		let replaced = await publish(changes, with: environments, reviewed: environmentReview, to: target)
		#expect(replaced.outcomes == Dictionary(uniqueKeysWithValues: changes.map {
			($0.key, PublishOutcome.failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again."))
		}))
		#expect(environments.names(in: production) == ([], []))
	}

	@Test("a key the listing cleared is read again before its write once a rate limit was waited out, and refused when it changed meanwhile")
	func rereadsAfterAnyWait() async throws {
		let api = FakeGitHubAPI()
		api.edit("B", secret: true, in: scope)
		let reviewed = try await reviewed(api)
		let scope = scope
		api.fail(.publicKey, with: .rateLimited(until: Date())) { api.edit("B", secret: true, value: "theirs", in: scope) }
		let report = await publish(
			[change("A", "1"), change("B", "2", .replace(remoteID: "secret")), change("C", "3")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .published, "B": .failed("Changed on GitHub since this review. Review again."), "C": .published])
		#expect(api.secretValue("B", in: scope) == Data("theirs".utf8))
	}

	@Test("a reread whose second read waited out a rate limit reads both kinds again")
	func rereadReadsBothAfterWait() async throws {
		let api = FakeGitHubAPI()
		api.edit("A", secret: true, in: scope)
		let reviewed = try await reviewed(api)
		let scope = scope
		api.fail(.variable, with: .rateLimited(until: Date())) { api.edit("A", secret: true, value: "theirs", in: scope) }
		let report = await publish([change("A", "1", .replace(remoteID: "secret"))], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .failed("Changed on GitHub since this review. Review again.")])
		#expect(api.secretValue("A", in: scope) == Data("theirs".utf8))
	}

	@Test("a listing a rate limit interrupts isn't started again; each key is read on its own instead")
	func listingIsNotRepeated() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let before = api.requests.count
		api.fail(.listVariables, with: .rateLimited(until: Date()))
		let report = await publish([change("A", "1"), change("B", "2", secret: false)], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .published, "B": .published])
		let made = operations(api, after: before)
		#expect(made.filter { $0 == .listSecrets }.count == 1 && made.filter { $0 == .listVariables }.count == 1)
		#expect(made.filter { $0 == .variable }.count == 3, "Each key is read from both kinds, and B is read back")
	}

	@Test("a token GitHub refuses stops the publish and asks to connect again; missing access stops it too")
	func stops() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.fail(.setSecret, with: .unauthorized)
		let report = await publish([change("A", "1"), change("B", "2")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .failed(GitHubPublishing.message(.unauthorized)), "B": .notSent])
		#expect(report.needsReconnect)

		let forbidden = FakeGitHubAPI()
		forbidden.fail(.repository, with: .forbidden)
		let refused = await publish([change("A", "1")], with: forbidden, reviewed: reviewed)
		#expect(refused.outcomes == ["A": .failed(GitHubPublishing.message(.forbidden))] && !refused.needsReconnect)

		let flaky = FakeGitHubAPI()
		flaky.fail(.createVariable, with: .server(502))
		let partial = await publish([change("A", "1", secret: false), change("B", "2", secret: false)], with: flaky, reviewed: reviewed)
		#expect(partial.outcomes == ["A": .failed("GitHub answered with HTTP 502."), "B": .published], "A server error affects only its own write")
	}

	@Test("a write is read back once and at once: a rate limit leaves its time unknown, and a refused read-back stops what's left")
	func readBack() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.fail(.secret, after: 1, with: .transport)
		var report = await publish([change("A", "1")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .published])
		#expect(report.published.first?.remoteUpdatedAt == nil && report.published.first?.remoteID == "secret")

		let limited = FakeGitHubAPI()
		limited.fail(.secret, after: 1, with: .rateLimited(until: Date()))
		report = await publish([change("A", "1")], with: limited, reviewed: reviewed)
		#expect(report.outcomes == ["A": .published] && report.published.first?.remoteUpdatedAt == nil)
		#expect(limited.requests.filter { $0.0 == .secret }.count == 2, "The read before the write, then one read-back that isn't retried")

		for (error, reconnects) in [(GitHubAPIError.unauthorized, true), (.forbidden, false)] {
			let refusing = FakeGitHubAPI()
			refusing.fail(.secret, with: error)
			let stopped = await publish([change("A", "1"), change("B", "2")], with: refusing, reviewed: reviewed)
			#expect(stopped.outcomes == ["A": .published, "B": .notSent])
			#expect(stopped.published.map(\.key) == ["A"] && stopped.needsReconnect == reconnects)
			#expect(refusing.requests.map(\.0) == [.repository, .listSecrets, .listVariables, .publicKey, .setSecret, .secret], "Two keys list the scope, so the first read is A's read-back")
		}

		let vanishing = FakeGitHubAPI()
		vanishing.dropWrites(of: "B")
		let gone = await publish([change("B", "2")], with: vanishing, reviewed: reviewed)
		#expect(gone.outcomes == ["B": .failed("GitHub accepted it, but it was gone when LPM Vault read it back. Check it on GitHub.")])
		#expect(gone.published.map(\.key) == ["B"], "GitHub took the value, so the next review knows this Mac sent it")
	}

	@Test("a value that can't be sealed isn't sent")
	func sealFailure() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let report = await GitHubPublishing.publish([change("A", "1")], to: target, reviewed: reviewed, using: api, seal: { _, _ in nil })
		#expect(report.outcomes == ["A": .failed("The value couldn't be sealed for GitHub.")] && api.writeCount == 0)
	}
}

/// A GitHub that accepts only the token a test says is current, as after a renewal invalidated the last one.
final class TokenGatedGitHub: @unchecked Sendable {
	private let lock = NSLock()
	private var valid: String
	private var seen: [String] = []
	let api: FakeGitHubAPI

	init(valid: String, api: FakeGitHubAPI = FakeGitHubAPI()) {
		self.valid = valid
		self.api = api
	}

	var tokens: [String] { lock.withLock { seen } }
	func accept(_ token: String) { lock.withLock { valid = token } }

	func client(_ token: String) -> any GitHubClientProtocol {
		lock.withLock { seen.append(token) }
		return Gate(token: token, owner: self)
	}

	private struct Gate: GitHubClientProtocol {
		let token: String
		let owner: TokenGatedGitHub

		private func allowed() -> Bool { owner.lock.withLock { owner.valid == token } }
		private func gated<Value>(_ body: () async -> Result<Value, GitHubAPIError>) async -> Result<Value, GitHubAPIError> {
			allowed() ? await body() : .failure(.unauthorized)
		}

		func user() async -> Result<GitHubUser, GitHubAPIError> { await gated { await owner.api.user() } }
		func repositories() async -> Result<[GitHubRepository], GitHubAPIError> { await gated { await owner.api.repositories() } }
		func repository(id: String) async -> Result<GitHubRepository, GitHubAPIError> { await gated { await owner.api.repository(id: id) } }
		func environments(of repository: String) async -> Result<[GitHubEnvironment], GitHubAPIError> {
			await gated { await owner.api.environments(of: repository) }
		}
		func secrets(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> { await gated { await owner.api.secrets(in: scope) } }
		func secret(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
			await gated { await owner.api.secret(name, in: scope) }
		}
		func publicKey(of scope: GitHubScope) async -> Result<GitHubPublicKey, GitHubAPIError> { await gated { await owner.api.publicKey(of: scope) } }
		func setSecret(_ name: String, to sealed: GitHubSealedSecret, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
			await gated { await owner.api.setSecret(name, to: sealed, in: scope) }
		}
		func variables(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> { await gated { await owner.api.variables(in: scope) } }
		func variable(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
			await gated { await owner.api.variable(name, in: scope) }
		}
		func createVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
			await gated { await owner.api.createVariable(name, value: value, in: scope) }
		}
		func updateVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
			await gated { await owner.api.updateVariable(name, value: value, in: scope) }
		}
	}
}

struct RenewingGitHubClientTests {
	private let keychain = MockKeychainService()
	private let start = Date(timeIntervalSince1970: 1_760_000_000)
	private let scope = GitHubScope(repository: "northwind/storefront", environment: nil)

	private func connect(_ store: PlatformConnectionStore) async throws -> PlatformConnection.ID {
		let refresh = PlatformTokenRefresh(
			token: "ghr_1", accessTokenExpiresAt: start.addingTimeInterval(8 * 3_600), expiresAt: start.addingTimeInterval(86_400),
			obtainedAt: start, principalID: platformTestPrincipal)
		return try await store.save(
			.github(GitHubConnectionAccount(userID: "583231", login: "octocat", name: nil, appSlug: "lpm-vault")),
			accessToken: "ghu_1", refresh: refresh, at: start).get().id
	}

	private func renewing(to tokens: [String]) -> ScriptedTokenRefresher {
		ScriptedTokenRefresher { call, index in
			ScriptedTokenRefresher.renewed(call, access: tokens[min(index, tokens.count - 1)], refresh: "ghr_\(index + 2)", platform: "github")
		}
	}

	@Test("a request GitHub refuses after another review renewed the token is sent again with the new token, without renewing twice")
	func followsAnotherRenewal() async throws {
		let store = PlatformConnectionStore(service: keychain)
		let id = try await connect(store)
		let refresher = renewing(to: ["ghu_2"])
		let clock = TestDate(start.addingTimeInterval(60))
		let credentials = PlatformCredentials(
			store: store, refresher: refresher, session: { platformTestSession(URL(string: "http://localhost:3000")!) }, now: { clock.date })
		let github = TokenGatedGitHub(valid: "ghu_1")
		let publishing = RenewingGitHubClient(connectionID: id, credentials: credentials, make: github.client)
		#expect(try await publishing.secrets(in: scope).get().isEmpty)

		clock.date = start.addingTimeInterval(8 * 3_600 - 60)
		#expect(await credentials.accessToken(for: id) == .success("ghu_2"), "Another review renews the token")
		github.accept("ghu_2")
		#expect(try await publishing.secrets(in: scope).get().isEmpty)
		#expect(github.tokens == ["ghu_1", "ghu_1", "ghu_2"])
		#expect(refresher.calls.count == 1)
	}

	@Test("a token GitHub refuses while it still looks current, as with a wrong clock, is renewed and the request sent again")
	func renewsRefusedToken() async throws {
		let store = PlatformConnectionStore(service: keychain)
		let id = try await connect(store)
		let refresher = renewing(to: ["ghu_2"])
		let credentials = PlatformCredentials(
			store: store, refresher: refresher, session: { platformTestSession(URL(string: "http://localhost:3000")!) }, now: { [start] in start })
		let github = TokenGatedGitHub(valid: "ghu_2")
		let publishing = RenewingGitHubClient(connectionID: id, credentials: credentials, make: github.client)
		#expect(try await publishing.secrets(in: scope).get().isEmpty)
		#expect(github.tokens == ["ghu_1", "ghu_2"] && refresher.calls.count == 1)
	}

	@Test("a refused token that can't be renewed answers as GitHub refused it")
	func cannotRenew() async throws {
		let store = PlatformConnectionStore(service: keychain)
		let id = try await connect(store)
		let refresher = ScriptedTokenRefresher { _, _ in .success(.failed(code: "refresh_rejected")) }
		let credentials = PlatformCredentials(
			store: store, refresher: refresher, session: { platformTestSession(URL(string: "http://localhost:3000")!) }, now: { [start] in start })
		let github = TokenGatedGitHub(valid: "nobody")
		let publishing = RenewingGitHubClient(connectionID: id, credentials: credentials, make: github.client)
		#expect(await publishing.secrets(in: scope) == .failure(.unauthorized))
		#expect(refresher.calls.count == 1)
	}

	@Test("a refused token that needs an LPM sign-in to renew says so, without sending again")
	func renewalNeedsSignIn() async throws {
		let store = PlatformConnectionStore(service: keychain)
		let id = try await connect(store)
		let refresher = renewing(to: ["ghu_2"])
		let credentials = PlatformCredentials(store: store, refresher: refresher, session: { nil }, now: { [start] in start })
		let github = TokenGatedGitHub(valid: "ghu_2")
		let publishing = RenewingGitHubClient(connectionID: id, credentials: credentials, make: github.client)
		#expect(await publishing.secrets(in: scope) == .failure(.credentials(.signedOut)))
		#expect(github.tokens == ["ghu_1"] && refresher.calls.isEmpty)
		#expect(GitHubPublishing.message(.credentials(.signedOut)) == PlatformCredentialError.signedOut.message(for: .github))
	}
}

struct GitHubClientListTests {
	private func client(_ route: PlatformHTTPStub.Route, limits: GitHubClient.Limits = .init()) -> GitHubClient {
		GitHubClient(token: "ghu_token", baseURL: route.baseURL, session: route.session, limits: limits)
	}

	@Test("repositories come from every installation, page by page, and a repository listed twice appears once")
	func listsRepositories() async throws {
		let route = PlatformHTTPStub.platform { request in
			let page = Int(request.query["page"] ?? "1") ?? 1
			switch request.url.path {
			case "/user/installations":
				return .json(200, ["total_count": 2, "installations": [["id": 11], ["id": 12]]])
			case "/user/installations/11/repositories":
				#expect(request.query["per_page"] == "100")
				let repositories: [[String: Any]] = page == 1
					? (0..<100).map { ["id": 1_000 + $0, "full_name": "northwind/repo-\($0)", "private": true] }
					: [["id": 1_100, "full_name": "northwind/last", "private": false]]
				return .json(200, ["total_count": 101, "repositories": repositories])
			case "/user/installations/12/repositories":
				return .json(200, ["total_count": 1, "repositories": [["id": 1_100, "full_name": "northwind/last", "private": false]]])
			default:
				return .json(404, [:])
			}
		}
		let repositories = try await client(route).repositories().get()
		#expect(repositories.count == 101 && Set(repositories.map(\.id)).count == 101)
		#expect(repositories.first { $0.id == "1100" } == GitHubRepository(id: "1100", fullName: "northwind/last", isPrivate: false))
		#expect(route.requests.allSatisfy { $0.header("Authorization") == "Bearer ghu_token" })
	}

	@Test("an installation a shifting list repeats is listed once")
	func repeatedInstallation() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/user/installations":
				return .json(200, ["total_count": 3, "installations": [["id": 11], ["id": 12], ["id": 11]]])
			case "/user/installations/11/repositories":
				return .json(200, ["total_count": 1, "repositories": [["id": 1_000, "full_name": "northwind/api", "private": true]]])
			case "/user/installations/12/repositories":
				return .json(200, ["total_count": 1, "repositories": [["id": 1_001, "full_name": "acme/site", "private": true]]])
			default:
				return .json(404, [:])
			}
		}
		#expect(try await client(route).repositories().get().map(\.id) == ["1000", "1001"])
		#expect(route.requests.map(\.url.path) == ["/user/installations", "/user/installations/11/repositories", "/user/installations/12/repositories"])
	}

	@Test("a list whose total changes between pages, or holds more than it says, or never ends, fails")
	func refusesInconsistentLists() async {
		let changing = PlatformHTTPStub.platform { request in
			let page = Int(request.query["page"] ?? "1") ?? 1
			return .json(200, ["total_count": page == 1 ? 31 : 32, "variables": (0..<(page == 1 ? 30 : 1)).map { ["name": "V\($0)", "value": "x", "updated_at": "2026-10-17T10:00:00Z"] }])
		}
		#expect(await client(changing).variables(in: GitHubScope(repository: "a/b", environment: nil)) == .failure(.invalidResponse))
		let overfull = PlatformHTTPStub.platform { _ in
			.json(200, ["total_count": 1, "secrets": [["name": "A", "updated_at": "2026-10-17T10:00:00Z"], ["name": "B", "updated_at": "2026-10-17T10:00:00Z"]]])
		}
		#expect(await client(overfull).secrets(in: GitHubScope(repository: "a/b", environment: nil)) == .failure(.invalidResponse))
		let endless = PlatformHTTPStub.platform { _ in
			.json(200, ["total_count": 1_000_000, "secrets": (0..<100).map { ["name": "S\($0)", "updated_at": "2026-10-17T10:00:00Z"] }])
		}
		var limits = GitHubClient.Limits()
		limits.maximumPages = 3
		#expect(await client(endless, limits: limits).secrets(in: GitHubScope(repository: "a/b", environment: nil)) == .failure(.invalidResponse))
		#expect(endless.requests.count == 3)
	}

	@Test("an environment's secrets and variables are read under its escaped name, a variable's value never decoded")
	func readsEnvironmentScope() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath {
			case "/repos/northwind/storefront/environments/staging%2Feu/secrets":
				return .json(200, ["total_count": 1, "secrets": [["name": "API_TOKEN", "created_at": "2026-10-17T09:00:00Z", "updated_at": "2026-10-17T10:00:00Z"]]])
			case "/repos/northwind/storefront/environments/staging%2Feu/variables":
				#expect(request.query["per_page"] == "30")
				return .json(200, ["total_count": 1, "variables": [["name": "LOG_LEVEL", "value": "info", "updated_at": "2026-10-17T10:00:01Z"]]])
			default:
				return .json(404, [:])
			}
		}
		let scope = GitHubScope(repository: "northwind/storefront", environment: "staging/eu")
		let secrets = try await client(route).secrets(in: scope).get()
		let updated = try #require(PlatformTimestamp.utc("2026-10-17T10:00:00Z"))
		#expect(secrets == [GitHubValueRecord(name: "API_TOKEN", updatedAt: updated)])
		let variables = try await client(route).variables(in: scope).get()
		#expect(variables.map(\.name) == ["LOG_LEVEL"])
		#expect(route.requests.allSatisfy { $0.url.absoluteString.contains("/environments/staging%2Feu/") })
	}

	@Test("a secret is written with its sealed value and key ID, a variable with its name and value, and a missing one reads as none")
	func writes() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch (request.method, request.url.path) {
			case ("GET", "/repos/northwind/storefront/actions/secrets/public-key"):
				return .json(200, ["key_id": "568250167242549743", "key": Data(repeating: 9, count: 32).base64EncodedString()])
			case ("PUT", "/repos/northwind/storefront/actions/secrets/API_TOKEN"): return PlatformHTTPStub.Reply(status: 201, body: Data())
			case ("POST", "/repos/northwind/storefront/actions/variables"): return PlatformHTTPStub.Reply(status: 201, body: Data())
			case ("PATCH", "/repos/northwind/storefront/actions/variables/LOG_LEVEL"): return PlatformHTTPStub.Reply(status: 204, body: Data())
			case ("GET", "/repos/northwind/storefront/actions/secrets/MISSING"): return .json(404, ["message": "Not Found"])
			default: return .json(500, [:])
			}
		}
		let client = client(route)
		let scope = GitHubScope(repository: "northwind/storefront", environment: nil)
		let key = try await client.publicKey(of: scope).get()
		#expect(key == GitHubPublicKey(id: "568250167242549743", key: Data(repeating: 9, count: 32)))
		try await client.setSecret("API_TOKEN", to: GitHubSealedSecret(ciphertext: Data([1, 2, 3]), keyID: key.id), in: scope).get()
		try await client.createVariable("PUBLIC_URL", value: "https://x", in: scope).get()
		try await client.updateVariable("LOG_LEVEL", value: "info", in: scope).get()
		#expect(try await client.secret("MISSING", in: scope).get() == nil)
		let bodies = route.requests.compactMap(\.json)
		#expect(bodies.contains { $0["encrypted_value"] as? String == Data([1, 2, 3]).base64EncodedString() && $0["key_id"] as? String == key.id })
		#expect(bodies.contains { $0["name"] as? String == "PUBLIC_URL" && $0["value"] as? String == "https://x" })
		let refused = await client.setSecret("api_token", to: GitHubSealedSecret(ciphertext: Data(), keyID: "1"), in: scope)
		guard case .failure(.invalidResponse) = refused else {
			Issue.record("A name GitHub would change is never sent")
			return
		}
	}

	@Test("a repository is read by its ID with its current name, and environments by the repository's")
	func readsRepository() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/repositories/1296269": return .json(200, ["id": 1_296_269, "full_name": "northwind/shop", "private": true])
			case "/repos/northwind/shop/environments":
				return .json(200, ["total_count": 1, "environments": [["id": 161_088_068, "name": "production", "protection_rules": []]]])
			default: return .json(404, [:])
			}
		}
		let repository = try await client(route).repository(id: "1296269").get()
		#expect(repository == GitHubRepository(id: "1296269", fullName: "northwind/shop", isPrivate: true))
		#expect(try await client(route).environments(of: "northwind/shop").get() == [GitHubEnvironment(id: "161088068", name: "production")])
		#expect(await client(route).repository(id: "../x") == .failure(.invalidResponse))
	}
}
