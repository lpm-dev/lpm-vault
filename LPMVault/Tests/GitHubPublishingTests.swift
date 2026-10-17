import CryptoKit
import Foundation
import Testing
@testable import LPMVault

/// GitHub's Actions API for tests: repositories with environments, and each
/// scope's secrets and variables with the second GitHub last wrote them.
/// Names are kept in capitals, as GitHub keeps them, and a request to a
/// repository's former name is redirected, as GitHub redirects it. A
/// secret's sealed value is kept as sent.
final class FakeGitHubAPI: GitHubClientProtocol, @unchecked Sendable {
	enum Operation: Hashable, Sendable {
		case listSecrets, listVariables, secret, variable, publicKey, setSecret, createVariable, updateVariable, repository, environments, environment
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
	private var formerNames: Set<String> = []
	private var access: [String: (isArchived: Bool, permission: GitHubRepository.Permission?)] = [:]
	private var listing = (hidesSSO: false, skips: false)
	/// Holds environment listings until a test opens it.
	var environmentsGate: TestGate?
	private var clock = Date(timeIntervalSince1970: 1_760_000_000)
	/// Each operation's scripted answers, in order: a failure, or nil to answer as usual.
	private var failures: [Operation: [(error: GitHubAPIError, then: (@Sendable () -> Void)?)?]] = [:]
	private var dropped: Set<String> = []
	private var log: [(Operation, String)] = []
	/// Runs before each write, as when someone edits on GitHub at that moment.
	var beforeWrite: (@Sendable (FakeGitHubAPI, String) -> Void)?
	/// Runs as each request arrives, before it's answered.
	var onRequest: (@Sendable (Operation) -> Void)?
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

	/// Fails the operation's next request, after answering `passing` of them
	/// as usual, with `error`, running `then` as it answers, as when someone
	/// edits on GitHub while a rate limit is waited out.
	func fail(_ operation: Operation, after passing: Int = 0, with error: GitHubAPIError, then: @escaping @Sendable () -> Void) {
		lock.withLock {
			failures[operation, default: []].append(contentsOf: Array(repeating: nil, count: passing) + [(error, then)])
		}
	}

	func rename(_ id: String, to name: String) {
		lock.withLock {
			let old = repositoryNames[id]
			repositoryNames[id] = name
			if let old { formerNames.insert(old) }
			formerNames.remove(name)
			if let old, let environments = environmentLists.removeValue(forKey: old) { environmentLists[name] = environments }
			for (key, scope) in scopes where key.hasPrefix((old ?? "") + "|") {
				scopes.removeValue(forKey: key)
				scopes[name + key.dropFirst(old?.count ?? 0)] = scope
			}
		}
	}

	/// Sets what the person may do with the repository, as GitHub lists it.
	func setAccess(of id: String, archived: Bool = false, permission: GitHubRepository.Permission?) {
		lock.withLock { access[id] = (archived, permission) }
	}

	/// Sets what the next repository listings say GitHub left out.
	func setListing(hidesSSO: Bool, skips: Bool) {
		lock.withLock { listing = (hidesSSO, skips) }
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
		let name = name.uppercased()
		lock.withLock {
			clock.addTimeInterval(1)
			var current = scopes[Self.key(scope)] ?? Scope()
			let record = Record(value: Data(value.utf8), updatedAt: clock)
			if secret { current.secrets[name] = record } else { current.variables[name] = record }
			scopes[Self.key(scope)] = current
		}
	}

	func remove(_ name: String, secret: Bool, in scope: GitHubScope) {
		let name = name.uppercased()
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

	/// Whether `repository` is a name a repository had before it was renamed.
	private func moved(_ repository: String) -> Bool {
		lock.withLock { formerNames.contains(repository) }
	}

	private func begin(_ operation: Operation, _ name: String) -> GitHubAPIError? {
		onRequest?(operation)
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

	func repositories() async -> Result<GitHubRepositoryList, GitHubAPIError> {
		if let error = begin(.repository, "*") { return .failure(error) }
		return .success(lock.withLock {
			GitHubRepositoryList(
				repositories: repositoryNames.map {
					GitHubRepository(
						id: $0.key, fullName: $0.value, isPrivate: true, isArchived: access[$0.key]?.isArchived ?? false,
						permission: access[$0.key]?.permission)
				},
				hidesSSORepositories: listing.hidesSSO, skipsInstallations: listing.skips)
		})
	}

	func repository(id: String) async -> Result<GitHubRepository, GitHubAPIError> {
		if let error = begin(.repository, id) { return .failure(error) }
		guard let (name, access) = lock.withLock({ repositoryNames[id].map { ($0, access[id]) } }) else { return .failure(.notFound) }
		return .success(GitHubRepository(
			id: id, fullName: name, isPrivate: true, isArchived: access?.isArchived ?? false, permission: access?.permission))
	}

	func environment(named name: String, of repository: String) async -> Result<GitHubEnvironment?, GitHubAPIError> {
		if let error = begin(.environment, name) { return .failure(error) }
		if moved(repository) { return .failure(.moved) }
		return .success(lock.withLock { environmentLists[repository]?.first { $0.name == name } })
	}

	func environments(of repository: String) async -> Result<[GitHubEnvironment], GitHubAPIError> {
		await environmentsGate?.wait()
		if let error = begin(.environments, repository) { return .failure(error) }
		if moved(repository) { return .failure(.moved) }
		return .success(lock.withLock { environmentLists[repository] ?? [] })
	}

	func secrets(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> {
		if let error = begin(.listSecrets, Self.key(scope)) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
		return .success(lock.withLock { (scopes[Self.key(scope)]?.secrets ?? [:]).map { GitHubValueRecord(name: $0.key, updatedAt: $0.value.updatedAt) } })
	}

	func secret(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		if let error = begin(.secret, name) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
		return .success(lock.withLock { scopes[Self.key(scope)]?.secrets[name].map { GitHubValueRecord(name: name, updatedAt: $0.updatedAt) } })
	}

	func publicKey(of scope: GitHubScope) async -> Result<GitHubPublicKey, GitHubAPIError> {
		if let error = begin(.publicKey, Self.key(scope)) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
		return .success(publicKey)
	}

	func setSecret(_ name: String, to sealed: GitHubSealedSecret, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		beforeWrite?(self, name)
		if let error = begin(.setSecret, name) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
		guard sealed.keyID == publicKey.id else { return .failure(.rejected(status: 422)) }
		write(name, secret: true, value: sealed.ciphertext, in: scope)
		return .success(())
	}

	func variables(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> {
		if let error = begin(.listVariables, Self.key(scope)) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
		return .success(lock.withLock { (scopes[Self.key(scope)]?.variables ?? [:]).map { GitHubValueRecord(name: $0.key, updatedAt: $0.value.updatedAt) } })
	}

	func variable(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		if let error = begin(.variable, name) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
		return .success(lock.withLock { scopes[Self.key(scope)]?.variables[name].map { GitHubValueRecord(name: name, updatedAt: $0.updatedAt) } })
	}

	func createVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		beforeWrite?(self, name)
		if let error = begin(.createVariable, name) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
		guard lock.withLock({ scopes[Self.key(scope)]?.variables[name] }) == nil else { return .failure(.rejected(status: 409)) }
		write(name, secret: false, value: Data(value.utf8), in: scope)
		return .success(())
	}

	func updateVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		beforeWrite?(self, name)
		if let error = begin(.updateVariable, name) { return .failure(error) }
		if moved(scope.repository) { return .failure(.moved) }
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

/// A publish's pacing on a clock that moves only as it sleeps, recording
/// each sleep and running `whileAsleep` during it, as when someone edits on
/// GitHub meanwhile.
final class TestPacing: @unchecked Sendable {
	/// The wall clock's time before anything sleeps.
	static let start = Date(timeIntervalSince1970: 1_760_000_000)

	private let lock = NSLock()
	private let clock = ManualClock()
	private let started: ContinuousClock.Instant
	private let whileAsleep: @Sendable () -> Void
	private var slept: [Duration] = []
	private var setBack: TimeInterval = 0
	private var nextSetBack: TimeInterval = 0

	init(whileAsleep: @escaping @Sendable () -> Void = {}) {
		self.whileAsleep = whileAsleep
		started = clock.now
	}

	var sleeps: [Duration] { lock.withLock { slept } }

	/// Sets the wall clock back by `seconds` during the next sleep, as when the Mac corrects its clock meanwhile.
	func setBackDuringNextSleep(by seconds: TimeInterval) {
		lock.withLock { nextSetBack = seconds }
	}

	var pacing: GitHubPublishing.Pacing {
		GitHubPublishing.Pacing(now: { [clock] in clock.now }, date: { [self] in
			let elapsed = started.duration(to: clock.now)
			return Self.start.addingTimeInterval(
				Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 - lock.withLock { setBack })
		}, sleep: { [self] duration in
			lock.withLock {
				slept.append(duration)
				setBack += nextSetBack
				nextSetBack = 0
			}
			whileAsleep()
			clock.advance(by: duration)
		})
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

	@Test("a low-order key, which anyone could open a box for and libsodium refuses, isn't sealed to")
	func refusesLowOrderKeys() {
		var zero = Data(repeating: 0, count: 32)
		#expect(SealedBox.seal("x", to: zero) == nil)
		zero[31] = 0x80
		#expect(SealedBox.seal("x", to: zero) == nil, "X25519 ignores the top bit")
		let order8 = Data([
			0xE0, 0xEB, 0x7A, 0x7C, 0x3B, 0x41, 0xB8, 0xAE, 0x16, 0x56, 0xE3, 0xFA, 0xF1, 0x9F, 0xC4, 0x6A,
			0xDA, 0x09, 0x8D, 0xEB, 0x9C, 0x32, 0xB1, 0xFD, 0x86, 0x62, 0x05, 0x16, 0x5F, 0x49, 0xB8, 0x00,
		])
		#expect(SealedBox.seal("x", to: order8) == nil)
	}
}

struct GitHubPublishingRulesTests {
	@Test("names are kept as GitHub keeps them: capitals, digits and underscores, not starting with a digit or GITHUB_")
	func acceptsNames() {
		for name in ["API_TOKEN", "_PRIVATE", "A1", "X"] { #expect(GitHubPublishing.isAcceptedKey(name)) }
		for name in ["api_token", "Api_Token", "1API", "API-TOKEN", "API TOKEN", ""] { #expect(!GitHubPublishing.isAcceptedKey(name)) }
		let platform = GitHubPublishing.platform(readableKeys: [], scope: .repository)
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
		remoteKeys: [String: PublishPlan.RemoteKey] = [:],
		scope: GitHubPublishTarget.Scope = .repository
	) -> PublishPlan {
		PublishPlan(
			destination: destination, values: values, rules: rules, check: nil, remote: remote, remoteKeys: remoteKeys,
			platform: GitHubPublishing.platform(readableKeys: ciVariables, scope: scope), history: nil, fingerprintKey: key)
	}

	@Test("a publish that would take a scope past the secrets or variables GitHub keeps there can't be sent until enough new ones are left out")
	func capacity() throws {
		let at = Date(timeIntervalSince1970: 1_760_000_100)
		var remote: [String: PublishPlan.RemoteVariable] = [:]
		for index in 0..<97 { remote["OLD_\(index)"] = .init(id: "secret", updatedAt: at, storedAsSecret: true) }
		remote["REPLACED"] = .init(id: "secret", updatedAt: at, storedAsSecret: true)
		var values = Dictionary(uniqueKeysWithValues: (0..<5).map { ("NEW_\($0)", "v") })
		values["REPLACED"] = "v"
		values["LEVEL"] = "info"
		let plan = plan(values, ciVariables: ["LEVEL"], remote: remote, remoteKeys: ["BOTH": .init(kind: .duplicated, storedAsSecret: true, updatedAt: at)])
		var selection = PublishPlan.Selection(defaultsOf: plan)
		#expect(plan.overflows(of: selection) == [PublishPlan.Overflow(isSecrets: true, limit: 100, existing: 99, adding: 5)])
		#expect(plan.overflows(of: selection).first?.excess == 4, "97 secrets, the replaced one and the one beside a variable, with 5 new")
		#expect(GitHubPublishing.overflowMessage(try #require(plan.overflows(of: selection).first), scope: .repository)
			== "GitHub keeps at most 100 of a repository's own secrets, and this would make 104. Leave out 4 new secrets.")
		#expect(GitHubPublishing.overflowMessage(.init(isSecrets: true, limit: 100, existing: 120, adding: 1), scope: .environment(id: "1", name: "p"))
			== "GitHub keeps at most 100 of an environment's secrets, and has 120 already. Leave out the new secret, or remove some on GitHub.")
		let summary = plan.summary(of: selection)
		#expect(summary.publishing == 7 && summary.secrets == 6 && summary.variables == 1)
		for key in ["NEW_0", "NEW_1", "NEW_2"] { selection.set(key, selected: false, in: plan) }
		#expect(plan.overflows(of: selection).first?.excess == 1)
		selection.set("NEW_3", selected: false, in: plan)
		#expect(plan.overflows(of: selection).isEmpty)

		let environment = self.plan(Dictionary(uniqueKeysWithValues: (0..<101).map { ("V_\($0)", "v") }), ciVariables: Set((0..<101).map { "V_\($0)" }), scope: .environment(id: "1", name: "production"))
		#expect(environment.overflows(of: .init(defaultsOf: environment)) == [PublishPlan.Overflow(isSecrets: false, limit: 100, existing: 0, adding: 101)])
		let repository = self.plan(Dictionary(uniqueKeysWithValues: (0..<101).map { ("V_\($0)", "v") }), ciVariables: Set((0..<101).map { "V_\($0)" }))
		#expect(repository.overflows(of: .init(defaultsOf: repository)).isEmpty, "A repository keeps 500 variables")
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

@MainActor
struct GitHubDestinationFormTests {
	@Test("each repository says whether it's private, and one whose secrets the person can't change says why and can't be chosen")
	func repositoryOptions() {
		let form = GitHubDestinationForm()
		form.repositories = .loaded([
			GitHubRepository(id: "1", fullName: "northwind/api", isPrivate: true, permission: .write),
			GitHubRepository(id: "2", fullName: "northwind/site", isPrivate: false),
			GitHubRepository(id: "3", fullName: "northwind/old", isPrivate: true, isArchived: true, permission: .admin),
			GitHubRepository(id: "4", fullName: "northwind/docs", isPrivate: false, permission: .read),
		])
		#expect(form.repositoryOptions == [
			.init(id: "1", label: "northwind/api · Private", isAvailable: true),
			.init(id: "2", label: "northwind/site · Public", isAvailable: true),
			.init(id: "3", label: "northwind/old · Private · Archived", isAvailable: false),
			.init(id: "4", label: "northwind/docs · Public · Read-only", isAvailable: false),
		])
	}

	@Test("each scope the person can't change says why: archived, read-only, or needing admin access")
	func scopeOptions() {
		let form = GitHubDestinationForm()
		form.repositories = .loaded([GitHubRepository(id: "1", fullName: "northwind/api", isPrivate: true, permission: .write)])
		form.repositoryID = "1"
		form.environments = .loaded([GitHubEnvironment(id: "10", name: "production"), GitHubEnvironment(id: "11", name: "staging\u{200B}")])
		#expect(form.scopeOptions == [
			.init(id: "repository", label: "Repository", isAvailable: true),
			.init(id: "environment:10", label: "Environment production · Needs admin access", isAvailable: false),
			.init(id: "environment:11", label: "Environment staging\\u{200b} (ID 11) · Needs admin access", isAvailable: false),
		])
		form.repositories = .loaded([GitHubRepository(id: "1", fullName: "northwind/api", isPrivate: true, permission: .admin)])
		#expect(form.scopeOptions.allSatisfy(\.isAvailable) && form.scopeOptions[1].label == "Environment production")
		form.repositories = .loaded([GitHubRepository(id: "1", fullName: "northwind/api", isPrivate: true, isArchived: true, permission: .admin)])
		#expect(form.scopeOptions.map(\.label) == [
			"Repository · Archived", "Environment production · Archived", "Environment staging\\u{200b} (ID 11) · Archived",
		])
		form.repositories = .loaded([GitHubRepository(id: "1", fullName: "northwind/api", isPrivate: true, permission: .read)])
		#expect(form.scopeOptions.map(\.label).first == "Repository · Read-only" && form.scopeOptions.allSatisfy { !$0.isAvailable })
	}

	@Test("the scope choices of a repository among many, with many environments, are made in one pass", .timeLimit(.minutes(1)))
	func scopeOptionsScale() {
		let form = GitHubDestinationForm()
		form.repositories = .loaded((0..<50_000).map { GitHubRepository(id: String($0 + 1), fullName: "northwind/repo-\($0)", isPrivate: true, permission: .write) })
		form.repositoryID = "50000"
		form.environments = .loaded((0..<50_000).map { GitHubEnvironment(id: String($0 + 1), name: "environment-\($0)") })
		let options = form.scopeOptions
		#expect(options.count == 50_001 && options.dropFirst().allSatisfy { !$0.isAvailable })
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

	@Test("an environment's name shows every character that could hide in it, so one can't pass for another")
	func showsHiddenCharacters() {
		for (name, shown) in [
			("production\u{200B}", "Environment production\\u{200b} (ID 1)"),
			("prod\u{00AD}uction", "Environment prod\\u{ad}uction (ID 1)"),
			("pro\u{FE0F}duction", "Environment pro\\u{fe0f}duction (ID 1)"),
			("production\u{00A0}eu", "Environment production\\u{a0}eu (ID 1)"),
			(" production ", "Environment \\u{20}production\\u{20} (ID 1)"),
			("production\u{3164}", "Environment production\\u{3164} (ID 1)"),
			("production\u{FFA0}", "Environment production\\u{ffa0} (ID 1)"),
			("production\u{2800}", "Environment production\\u{2800} (ID 1)"),
			("pr\u{043E}duction", "Environment pr\u{043E}duction (ID 1)"),
			("staging\\u{200b} (ID 11)", "Environment staging\\u{200b} (ID 11) (ID 1)"),
			("production (ID 3)", "Environment production (ID 3) (ID 1)"),
			("production (id 3)", "Environment production (id 3) (ID 1)"),
			("staging/eu", "Environment staging/eu"),
			("é-ünïcode prod", "Environment é-ünïcode prod (ID 1)"),
		] {
			#expect(GitHubPublishTarget.Scope.environment(id: "1", name: name).displayName == shown)
		}
	}

	@Test("no two environments show alike, whatever their names copy of an escape or an ID", arguments: [
		[("11", "staging\u{200B}"), ("12", "staging\\u{200b}"), ("13", "staging\\u{200b} (ID 11)")],
		[("1", "production"), ("2", "production\u{3164}"), ("3", "pr\u{043E}duction"), ("4", "production (ID 3)"), ("5", "production\u{2800}")],
	])
	func showsEveryEnvironmentApart(_ environments: [(String, String)]) {
		let shown = environments.map { GitHubPublishTarget.Scope.environment(id: $0.0, name: $0.1).displayName }
		#expect(Set(shown).count == shown.count, "\(shown)")
		for (environment, label) in zip(environments, shown) where environment.1.contains(where: { !$0.isASCII }) {
			#expect(label.hasSuffix(" (ID \(environment.0))"), "A name that could pass for another shows its own ID last: \(label)")
		}
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
		#expect(invalidity { $0.repositoryName = "mona-cat_octo/infra" } == nil, "A managed user owns it")
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
	private let production = GitHubScope(repository: "northwind/storefront", environment: "production")
	private let target = GitHubPublishTarget(
		userID: "583231", userLogin: "octocat", repositoryID: "1296269", repositoryName: "northwind/storefront", scope: .repository)
	private let fingerprintKey = SymmetricKey(size: .bits256)

	private var productionTarget: GitHubPublishTarget {
		var target = target
		target.scope = .environment(id: "161088068", name: "production")
		return target
	}

	private func change(_ key: String, _ value: String, _ operation: PublishPlan.Operation = .add, secret: Bool = true) -> PublishPlan.Change {
		PublishPlan.Change(
			key: key, value: value, operation: operation, publishesAsSecret: secret,
			fingerprint: PublishFingerprint.of(value: value, key: key, destination: UUID(), using: fingerprintKey))
	}

	private func reviewed(_ api: FakeGitHubAPI, in scope: GitHubScope? = nil) async throws -> GitHubRemoteSnapshot {
		let scope = scope ?? self.scope
		return try GitHubPublishing.snapshot(secrets: await api.secrets(in: scope).get(), variables: await api.variables(in: scope).get()).get()
	}

	/// A publish whose pauses between writes take no time unless `pacing` says otherwise.
	private func publish(
		_ changes: [PublishPlan.Change],
		with api: FakeGitHubAPI,
		reviewed: GitHubRemoteSnapshot,
		to target: GitHubPublishTarget? = nil,
		pacing: TestPacing = TestPacing()
	) async -> PublishReport {
		await GitHubPublishing.publish(changes, to: target ?? self.target, reviewed: reviewed, using: api, seal: testGitHubSeal, pacing: pacing.pacing)
	}

	/// The operations a publish made after `before` requests.
	private func operations(_ api: FakeGitHubAPI, after before: Int) -> [FakeGitHubAPI.Operation] {
		api.requests.dropFirst(before).map(\.0)
	}

	@Test("each write is preceded by reading the key from both kinds and, last, checking the repository, and read back for its time; the scope is never listed")
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
			.secret, .variable, .publicKey, .repository, .setSecret, .secret,
			.secret, .variable, .repository, .updateVariable, .variable,
			.secret, .variable, .repository, .createVariable, .variable,
		], "The repository is checked last before each write")
		let records = Dictionary(uniqueKeysWithValues: report.published.map { ($0.key, $0) })
		#expect(records["API_TOKEN"]?.remoteID == "secret" && records["API_TOKEN"]?.publishedAsSecret == true)
		#expect(records["LOG_LEVEL"]?.remoteID == "variable" && records["LOG_LEVEL"]?.publishedAsSecret == false)
		let snapshot = try await self.reviewed(api)
		for key in ["API_TOKEN", "LOG_LEVEL", "PUBLIC_URL"] {
			#expect(records[key]?.remoteUpdatedAt == snapshot.variables[key]?.updatedAt, "The history holds the time GitHub gave the write")
		}
	}

	@Test("an environment is checked by its ID under its name before each write, without listing the others")
	func checksEnvironmentEachWrite() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api, in: production)
		let before = api.requests.count
		let report = await publish([change("A", "1", secret: false), change("B", "2", secret: false)], with: api, reviewed: reviewed, to: productionTarget)
		#expect(report.outcomes == ["A": .published, "B": .published])
		#expect(operations(api, after: before) == [
			.secret, .variable, .repository, .environment, .createVariable, .variable,
			.secret, .variable, .repository, .environment, .createVariable, .variable,
		])
	}

	@Test("a key added, changed, removed or moved on GitHub since the review isn't sent")
	func refusesDrift() async throws {
		let api = FakeGitHubAPI()
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
		let report = await publish([change("API_TOKEN", "t")], with: replaced, reviewed: reviewed, to: productionTarget)
		#expect(report.outcomes == [
			"API_TOKEN": .failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again."),
		])
		#expect(replaced.writeCount == 0)
	}

	@Test("an environment replaced, or a repository's name reused, while its key or public key is read gets nothing: the check comes last", arguments: [
		FakeGitHubAPI.Operation.secret, .variable, .publicKey,
	])
	func checksIdentityLast(_ during: FakeGitHubAPI.Operation) async throws {
		let environments = FakeGitHubAPI()
		let reviewed = try await self.reviewed(environments, in: production)
		environments.onRequest = { operation in
			if operation == during { environments.replaceEnvironment(of: "northwind/storefront", name: "production", withID: "999") }
		}
		let replaced = await publish([change("A", "1")], with: environments, reviewed: reviewed, to: productionTarget)
		#expect(replaced.outcomes == [
			"A": .failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again."),
		])
		#expect(environments.writeCount == 0)

		let repositories = FakeGitHubAPI()
		let repositoryReview = try await self.reviewed(repositories)
		repositories.onRequest = { operation in
			if operation == during {
				repositories.rename("1296269", to: "northwind/shop")
				repositories.rename("88", to: "northwind/storefront")
			}
		}
		let reused = await publish([change("A", "1")], with: repositories, reviewed: repositoryReview)
		#expect(reused.outcomes == ["A": .failed("northwind/storefront was renamed northwind/shop on GitHub since this review. Review again.")])
		#expect(repositories.writeCount == 0)
	}

	@Test("a key changed, or the environment replaced, during the pause before its write isn't written over")
	func checksAfterPause() async throws {
		let api = FakeGitHubAPI()
		api.edit("B", secret: true, in: scope)
		let reviewed = try await reviewed(api)
		let scope = scope
		let editing = TestPacing { api.edit("B", secret: true, value: "theirs", in: scope) }
		let report = await publish([change("A", "1"), change("B", "2", .replace(remoteID: "secret"))], with: api, reviewed: reviewed, pacing: editing)
		#expect(report.outcomes == ["A": .published, "B": .failed("Changed on GitHub since this review. Review again.")])
		#expect(api.secretValue("B", in: scope) == Data("theirs".utf8) && editing.sleeps == [.seconds(1)])

		let environments = FakeGitHubAPI()
		let environmentReview = try await self.reviewed(environments, in: production)
		let replacing = TestPacing { environments.replaceEnvironment(of: "northwind/storefront", name: "production", withID: "999") }
		let replaced = await publish(
			[change("A", "1"), change("B", "2"), change("C", "3")], with: environments, reviewed: environmentReview, to: productionTarget,
			pacing: replacing)
		let gone = PublishOutcome.failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again.")
		#expect(replaced.outcomes == ["A": .published, "B": gone, "C": gone])
		#expect(environments.names(in: production).secrets == ["A"])
	}

	@Test("a write held up by a rate limit is sent once it lifts, after checking the repository and reading the key from both kinds again")
	func waitsOutRateLimit() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let before = api.requests.count
		api.fail(.setSecret, with: .rateLimited(until: TestPacing.start))
		let report = await publish([change("API_TOKEN", "t")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["API_TOKEN": .published])
		#expect(operations(api, after: before) == [
			.secret, .variable, .publicKey, .repository, .setSecret, .secret, .variable, .repository, .setSecret, .secret,
		])
	}

	@Test("a repository or environment replaced under its name while a rate limit is waited out gets nothing", arguments: [
		FakeGitHubAPI.Operation.setSecret, .publicKey, .repository, .secret, .variable,
	])
	func checksIdentityAfterWait(_ limited: FakeGitHubAPI.Operation) async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.fail(limited, with: .rateLimited(until: TestPacing.start)) {
			api.rename("1296269", to: "northwind/shop")
			api.rename("88", to: "northwind/storefront")
		}
		let report = await publish([change("A", "1"), change("B", "2")], with: api, reviewed: reviewed)
		let renamed = PublishOutcome.failed("northwind/storefront was renamed northwind/shop on GitHub since this review. Review again.")
		#expect(report.outcomes == ["A": renamed, "B": renamed])
		#expect(api.names(in: scope) == ([], []), "Repository 88 now has the reviewed name, and gets nothing")
		#expect(api.names(in: GitHubScope(repository: "northwind/shop", environment: nil)) == ([], []))

		let environments = FakeGitHubAPI()
		let environmentReview = try await self.reviewed(environments, in: production)
		environments.fail(limited == .repository ? .environment : limited, with: .rateLimited(until: TestPacing.start)) {
			environments.replaceEnvironment(of: "northwind/storefront", name: "production", withID: "999")
		}
		let replaced = await publish([change("A", "1"), change("B", "2")], with: environments, reviewed: environmentReview, to: productionTarget)
		let gone = PublishOutcome.failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again.")
		#expect(replaced.outcomes == ["A": gone, "B": gone])
		#expect(environments.names(in: production) == ([], []))
	}

	@Test("a key is read again before its write once a rate limit was waited out, and refused when it changed meanwhile")
	func rereadsAfterAnyWait() async throws {
		let api = FakeGitHubAPI()
		api.edit("B", secret: true, in: scope)
		let reviewed = try await reviewed(api)
		let scope = scope
		api.fail(.publicKey, with: .rateLimited(until: TestPacing.start)) { api.edit("B", secret: true, value: "theirs", in: scope) }
		let report = await publish(
			[change("B", "2", .replace(remoteID: "secret")), change("C", "3")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["B": .failed("Changed on GitHub since this review. Review again."), "C": .published])
		#expect(api.secretValue("B", in: scope) == Data("theirs".utf8))
	}

	@Test("a reread whose second read waited out a rate limit reads both kinds again")
	func rereadReadsBothAfterWait() async throws {
		let api = FakeGitHubAPI()
		api.edit("A", secret: true, in: scope)
		let reviewed = try await reviewed(api)
		let scope = scope
		api.fail(.variable, with: .rateLimited(until: TestPacing.start)) { api.edit("A", secret: true, value: "theirs", in: scope) }
		let report = await publish([change("A", "1", .replace(remoteID: "secret"))], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .failed("Changed on GitHub since this review. Review again.")])
		#expect(api.secretValue("A", in: scope) == Data("theirs".utf8))
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

	@Test("a write is read back once and at once: a failure leaves its time unknown, and a refused read-back stops what's left")
	func readBack() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.fail(.secret, after: 1, with: .transport)
		let report = await publish([change("A", "1")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .published])
		#expect(report.published.first?.remoteUpdatedAt == nil && report.published.first?.remoteID == "secret")
		#expect(api.requests.filter { $0.0 == .secret }.count == 2, "The read before the write, then one read-back that isn't retried")

		for (error, reconnects) in [(GitHubAPIError.unauthorized, true), (.forbidden, false)] {
			let refusing = FakeGitHubAPI()
			refusing.fail(.secret, after: 1, with: error)
			let stopped = await publish([change("A", "1"), change("B", "2")], with: refusing, reviewed: reviewed)
			#expect(stopped.outcomes == ["A": .published, "B": .failed(GitHubPublishing.message(error))], "What's left says why it wasn't sent")
			#expect(stopped.published.map(\.key) == ["A"] && stopped.needsReconnect == reconnects)
			#expect(refusing.requests.map(\.0) == [.secret, .variable, .publicKey, .repository, .setSecret, .secret])
		}

		let vanishing = FakeGitHubAPI()
		vanishing.dropWrites(of: "B")
		let gone = await publish([change("B", "2")], with: vanishing, reviewed: reviewed)
		#expect(gone.outcomes == ["B": .failed("GitHub accepted it, but it was gone when LPM Vault read it back. Check it on GitHub.")])
		#expect(gone.published.map(\.key) == ["B"], "GitHub took the value, so the next review knows this Mac sent it")
	}

	@Test("a read-back held up by a rate limit leaves its time unknown, and the next key waits for the limit, or isn't sent when it lifts too late")
	func readBackRateLimit() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let pacing = TestPacing()
		api.fail(.secret, after: 1, with: .rateLimited(until: nil))
		let report = await publish([change("A", "1"), change("B", "2")], with: api, reviewed: reviewed, pacing: pacing)
		#expect(report.outcomes == ["A": .published, "B": .published])
		#expect(report.published.first { $0.key == "A" }?.remoteUpdatedAt == nil)
		#expect(pacing.sleeps == [.seconds(60)], "A minute for the limit GitHub didn't say the end of, which also spaces the writes")

		let far = FakeGitHubAPI()
		let reset = TestPacing.start.addingTimeInterval(3_600)
		far.fail(.secret, after: 1, with: .rateLimited(until: reset))
		let stopped = await publish([change("A", "1"), change("B", "2")], with: far, reviewed: reviewed)
		#expect(stopped.outcomes == [
			"A": .published, "B": .failed(GitHubPublishing.message(.rateLimited(until: reset), now: TestPacing.start)),
		])
		#expect(far.requests.map(\.0) == [.secret, .variable, .publicKey, .repository, .setSecret, .secret], "Nothing is asked of GitHub after the limit")
	}

	@Test("a limit on the last key's read-back doesn't hold the results up: nothing is left to send")
	func lastReadBackLimit() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let pacing = TestPacing()
		api.fail(.secret, after: 1, with: .rateLimited(until: nil))
		let report = await publish([change("A", "1")], with: api, reviewed: reviewed, pacing: pacing)
		#expect(report.outcomes == ["A": .published] && report.published.first?.remoteUpdatedAt == nil)
		#expect(pacing.sleeps.isEmpty)
	}

	@Test("a limit a read-back met that goes on at the next key backs off from where it got to")
	func readBackLimitBacksOff() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let pacing = TestPacing()
		api.fail(.secret, after: 1, with: .rateLimited(until: nil))
		api.fail(.repository, after: 1, with: .rateLimited(until: nil))
		let report = await publish([change("A", "1"), change("B", "2")], with: api, reviewed: reviewed, pacing: pacing)
		#expect(report.outcomes == ["A": .published, "B": .published])
		#expect(pacing.sleeps == [.seconds(60), .seconds(120)])
	}

	@Test("a renewed token starts a write over without using its waits for rate limits, which back off from a minute")
	func renewalsApartFromLimits() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let soon = TestPacing.start.addingTimeInterval(1)
		api.fail(.setSecret, with: .rateLimited(until: soon), .rateLimited(until: soon), .rateLimited(until: soon), .renewed)
		let report = await publish([change("A", "1")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .published] && !report.needsReconnect)

		let renewed = FakeGitHubAPI()
		let pacing = TestPacing()
		renewed.fail(.setSecret, with: .renewed, .rateLimited(until: nil))
		let after = await publish([change("A", "1")], with: renewed, reviewed: reviewed, pacing: pacing)
		#expect(after.outcomes == ["A": .published])
		#expect(pacing.sleeps.contains(.seconds(60)) && !pacing.sleeps.contains(.seconds(120)))
	}

	@Test("writes are a second apart, as GitHub asks of a batch of writes")
	func pacesWrites() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let pacing = TestPacing()
		let report = await publish(
			[change("A", "1", secret: false), change("B", "2", secret: false), change("C", "3", secret: false)], with: api, reviewed: reviewed,
			pacing: pacing)
		#expect(report.outcomes.values.allSatisfy { $0 == .published })
		#expect(pacing.sleeps == [.seconds(1), .seconds(1)], "Nothing else took time, so each later write waited a full second")
	}

	@Test("a limit GitHub doesn't say the end of is waited out a minute, then twice that, then given up")
	func backsOff() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let pacing = TestPacing()
		api.fail(.setSecret, with: .rateLimited(until: nil), .rateLimited(until: nil))
		let report = await publish([change("A", "1")], with: api, reviewed: reviewed, pacing: pacing)
		#expect(report.outcomes == ["A": .published])
		#expect(pacing.sleeps == [.seconds(60), .seconds(120)])

		let limited = FakeGitHubAPI()
		let still = TestPacing()
		limited.fail(.setSecret, with: .rateLimited(until: nil), .rateLimited(until: nil), .rateLimited(until: nil))
		let given = await publish([change("A", "1"), change("B", "2")], with: limited, reviewed: reviewed, pacing: still)
		#expect(given.outcomes == ["A": .failed("GitHub is limiting requests. Try again in a few minutes."), "B": .notSent])
		#expect(still.sleeps == [.seconds(60), .seconds(120)])
	}

	@Test("an announced limit is waited out a second past its reset, by the wall clock; one too far off, or a fourth in a row, isn't")
	func waitsOutAnnouncedLimits() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		let pacing = TestPacing()
		api.fail(.setSecret, with: .rateLimited(until: TestPacing.start.addingTimeInterval(30)))
		let report = await publish([change("A", "1")], with: api, reviewed: reviewed, pacing: pacing)
		#expect(report.outcomes == ["A": .published])
		#expect(pacing.sleeps == [.seconds(31)], "A second past the reset, so the next request doesn't arrive just before it")

		let longest = FakeGitHubAPI()
		let lastMoment = TestPacing()
		longest.fail(.setSecret, with: .rateLimited(until: TestPacing.start.addingTimeInterval(65)))
		#expect(await publish([change("A", "1")], with: longest, reviewed: reviewed, pacing: lastMoment).outcomes == ["A": .published])
		#expect(lastMoment.sleeps == [.seconds(66)], "The margin doesn't push a limit inside the longest wait past it")

		let corrected = FakeGitHubAPI()
		let setBack = TestPacing()
		setBack.setBackDuringNextSleep(by: 3_600)
		corrected.fail(.setSecret, with: .rateLimited(until: TestPacing.start.addingTimeInterval(30)))
		#expect(await publish([change("A", "1")], with: corrected, reviewed: reviewed, pacing: setBack).outcomes == ["A": .published])
		#expect(setBack.sleeps.reduce(.zero, +) == GitHubHTTP.longestRateLimitWait, "A wall clock set back an hour holds the wait no longer than the longest")

		let far = FakeGitHubAPI()
		let farOff = TestPacing()
		let reset = TestPacing.start.addingTimeInterval(600)
		far.fail(.setSecret, with: .rateLimited(until: reset))
		let refused = await publish([change("A", "1")], with: far, reviewed: reviewed, pacing: farOff)
		#expect(refused.outcomes == ["A": .failed(GitHubPublishing.message(.rateLimited(until: reset), now: TestPacing.start))])
		#expect(farOff.sleeps.isEmpty)

		let repeated = FakeGitHubAPI()
		let again = TestPacing()
		let soon = TestPacing.start.addingTimeInterval(1)
		repeated.fail(.setSecret, with: .rateLimited(until: soon), .rateLimited(until: soon), .rateLimited(until: soon), .rateLimited(until: soon))
		let given = await publish([change("A", "1")], with: repeated, reviewed: reviewed, pacing: again)
		#expect(repeated.requests.filter { $0.0 == .setSecret }.count == 4, "Three limits waited out, and the fourth stops it")
		#expect(given.outcomes["A"] == .failed("GitHub is limiting requests. Try again in a minute."))
	}

	@Test("an organization's single sign-on stops the publish, saying so, without calling the connection gone")
	func stopsForSSO() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.fail(.repository, with: .ssoRequired)
		let report = await publish([change("A", "1"), change("B", "2")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .failed(GitHubPublishing.message(.ssoRequired)), "B": .notSent])
		#expect(!report.needsReconnect)
	}

	@Test("a rate limit's message says when it lifts, when that's more than a moment away")
	func rateLimitMessages() {
		let now = Date(timeIntervalSince1970: 1_760_000_000)
		let later = now.addingTimeInterval(40 * 60)
		#expect(GitHubPublishing.message(.rateLimited(until: later), now: now)
			== "GitHub is limiting requests until \(later.formatted(date: .omitted, time: .shortened)). Try again then.")
		#expect(GitHubPublishing.message(.rateLimited(until: now.addingTimeInterval(30)), now: now) == "GitHub is limiting requests. Try again in a minute.")
		#expect(GitHubPublishing.message(.rateLimited(until: nil), now: now) == "GitHub is limiting requests. Try again in a few minutes.")
	}

	@Test("a repository renamed between the check and a write gets a redirect, which stops the publish without writing to the name")
	func stopsOnRedirect() async throws {
		let api = FakeGitHubAPI()
		let reviewed = try await reviewed(api)
		api.beforeWrite = { api, _ in api.rename("1296269", to: "northwind/shop") }
		let report = await publish([change("A", "1"), change("B", "2")], with: api, reviewed: reviewed)
		#expect(report.outcomes == ["A": .failed("The repository was renamed or moved on GitHub. Review again."), "B": .notSent])
		#expect(api.names(in: GitHubScope(repository: "northwind/shop", environment: nil)) == ([], []))
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

	private var refused = 0

	var tokens: [String] { lock.withLock { seen } }
	/// How many requests GitHub refused for their token.
	var refusals: Int { lock.withLock { refused } }
	func accept(_ token: String) { lock.withLock { valid = token } }

	func client(_ token: String) -> any GitHubClientProtocol {
		lock.withLock { seen.append(token) }
		return Gate(token: token, owner: self)
	}

	private struct Gate: GitHubClientProtocol {
		let token: String
		let owner: TokenGatedGitHub

		private func allowed() -> Bool {
			owner.lock.withLock {
				if owner.valid == token { return true }
				owner.refused += 1
				return false
			}
		}
		private func gated<Value>(_ body: () async -> Result<Value, GitHubAPIError>) async -> Result<Value, GitHubAPIError> {
			allowed() ? await body() : .failure(.unauthorized)
		}

		func user() async -> Result<GitHubUser, GitHubAPIError> { await gated { await owner.api.user() } }
		func repositories() async -> Result<GitHubRepositoryList, GitHubAPIError> { await gated { await owner.api.repositories() } }
		func repository(id: String) async -> Result<GitHubRepository, GitHubAPIError> { await gated { await owner.api.repository(id: id) } }
		func environments(of repository: String) async -> Result<[GitHubEnvironment], GitHubAPIError> {
			await gated { await owner.api.environments(of: repository) }
		}
		func environment(named name: String, of repository: String) async -> Result<GitHubEnvironment?, GitHubAPIError> {
			await gated { await owner.api.environment(named: name, of: repository) }
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

	@Test("a token another review renewed is used by the next request, without renewing twice")
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
		#expect(github.tokens == ["ghu_1", "ghu_2"] && github.refusals == 0, "Each request reads the connection's token now")
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

	@Test("a token about to expire between two requests is renewed before the second, so GitHub never refuses it")
	func renewsBeforeExpiry() async throws {
		let store = PlatformConnectionStore(service: keychain)
		let id = try await connect(store)
		let refresher = renewing(to: ["ghu_2"])
		let clock = TestDate(start.addingTimeInterval(60))
		let credentials = PlatformCredentials(
			store: store, refresher: refresher, session: { platformTestSession(URL(string: "http://localhost:3000")!) }, now: { clock.date })
		let github = TokenGatedGitHub(valid: "ghu_1")
		let client = RenewingGitHubClient(connectionID: id, credentials: credentials, make: github.client)
		#expect(try await client.secrets(in: scope).get().isEmpty)
		clock.date = start.addingTimeInterval(8 * 3_600 - 60)
		github.accept("ghu_2")
		#expect(try await client.secrets(in: scope).get().isEmpty)
		#expect(github.tokens == ["ghu_1", "ghu_2"] && github.refusals == 0 && refresher.calls.count == 1)
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

/// Publishes through the renewing client, where GitHub refuses the token at
/// some request and lpm.dev renews it while someone changes GitHub.
struct GitHubPublishRenewalTests {
	private let keychain = MockKeychainService()
	private let start = Date(timeIntervalSince1970: 1_760_000_000)
	private let scope = GitHubScope(repository: "northwind/storefront", environment: nil)
	private let production = GitHubScope(repository: "northwind/storefront", environment: "production")
	private let fingerprintKey = SymmetricKey(size: .bits256)

	private func target(_ scope: GitHubPublishTarget.Scope = .repository) -> GitHubPublishTarget {
		GitHubPublishTarget(userID: "583231", userLogin: "octocat", repositoryID: "1296269", repositoryName: "northwind/storefront", scope: scope)
	}

	private func change(_ key: String, _ operation: PublishPlan.Operation = .add) -> PublishPlan.Change {
		PublishPlan.Change(
			key: key, value: "v", operation: operation, publishesAsSecret: true,
			fingerprint: PublishFingerprint.of(value: "v", key: key, destination: UUID(), using: fingerprintKey))
	}

	/// A publishing client for a GitHub connection whose token lpm.dev renews to `ghu_2`.
	private func client(
		_ github: TokenGatedGitHub,
		clock: TestDate? = nil,
		whileRenewing: @escaping @Sendable () -> Void = {}
	) async throws -> (RenewingGitHubClient, ScriptedTokenRefresher) {
		let store = PlatformConnectionStore(service: keychain)
		let refresh = PlatformTokenRefresh(
			token: "ghr_1", accessTokenExpiresAt: start.addingTimeInterval(8 * 3_600), expiresAt: start.addingTimeInterval(86_400),
			obtainedAt: start, principalID: platformTestPrincipal)
		let id = try await store.save(
			.github(GitHubConnectionAccount(userID: "583231", login: "octocat", name: nil, appSlug: "lpm-vault")),
			accessToken: "ghu_1", refresh: refresh, at: start).get().id
		let refresher = ScriptedTokenRefresher { call, _ in
			whileRenewing()
			return ScriptedTokenRefresher.renewed(call, access: "ghu_2", refresh: "ghr_2", platform: "github")
		}
		let clock = clock ?? TestDate(start)
		let credentials = PlatformCredentials(
			store: store, refresher: refresher, session: { platformTestSession(URL(string: "http://localhost:3000")!) }, now: { clock.date })
		return (RenewingGitHubClient(connectionID: id, credentials: credentials, resendsAfterRenewal: false, make: github.client), refresher)
	}

	private func reviewed(_ api: FakeGitHubAPI, in scope: GitHubScope) async throws -> GitHubRemoteSnapshot {
		try GitHubPublishing.snapshot(secrets: await api.secrets(in: scope).get(), variables: await api.variables(in: scope).get()).get()
	}

	private func publish(_ changes: [PublishPlan.Change], to target: GitHubPublishTarget, reviewed: GitHubRemoteSnapshot, using client: RenewingGitHubClient) async -> PublishReport {
		await GitHubPublishing.publish(changes, to: target, reviewed: reviewed, using: client, seal: testGitHubSeal, pacing: TestPacing().pacing)
	}

	@Test("a token renewed as a request reads it, with nothing refused, starts the checks over: an environment replaced meanwhile gets nothing")
	func checksAfterRenewalOnRead() async throws {
		let github = TokenGatedGitHub(valid: "ghu_1")
		let api = github.api
		let reviewed = try await reviewed(api, in: production)
		let clock = TestDate(start)
		let due = start.addingTimeInterval(8 * 3_600 - 60)
		api.onRequest = { operation in if operation == .variable { clock.date = due } }
		let (client, refresher) = try await client(github, clock: clock) {
			api.replaceEnvironment(of: "northwind/storefront", name: "production", withID: "999")
			github.accept("ghu_2")
		}
		let report = await publish([change("A")], to: target(.environment(id: "161088068", name: "production")), reviewed: reviewed, using: client)
		#expect(report.outcomes == ["A": .failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again.")])
		#expect(api.names(in: production) == ([], []) && refresher.calls.count == 1 && github.refusals == 0)
	}

	@Test("a token renewed as a read-back reads it leaves the write's time unknown, as someone may have changed it meanwhile")
	func readBackAfterRenewalOnRead() async throws {
		let github = TokenGatedGitHub(valid: "ghu_1")
		let api = github.api
		let reviewed = try await reviewed(api, in: scope)
		let clock = TestDate(start)
		let due = start.addingTimeInterval(8 * 3_600 - 60)
		let scope = scope
		api.onRequest = { operation in if operation == .setSecret { clock.date = due } }
		let (client, _) = try await client(github, clock: clock) {
			api.edit("A", secret: true, value: "theirs", in: scope)
			github.accept("ghu_2")
		}
		let report = await publish([change("A"), change("B")], to: target(), reviewed: reviewed, using: client)
		#expect(report.outcomes == ["A": .published, "B": .published])
		#expect(report.published.first { $0.key == "A" }?.remoteUpdatedAt == nil)
		#expect(github.refusals == 0)
	}

	@Test("an environment replaced while the token renewed, after GitHub refused it for the scope's key, gets nothing")
	func checksScopeAfterRenewal() async throws {
		let github = TokenGatedGitHub(valid: "ghu_1")
		let api = github.api
		let reviewed = try await reviewed(api, in: production)
		api.fail(.publicKey, with: .unauthorized) {
			github.accept("ghu_2")
			api.replaceEnvironment(of: "northwind/storefront", name: "production", withID: "999")
		}
		let (client, refresher) = try await client(github)
		let report = await publish([change("A")], to: target(.environment(id: "161088068", name: "production")), reviewed: reviewed, using: client)
		#expect(report.outcomes == ["A": .failed("The environment production was renamed, removed or replaced on GitHub since this review. Review again.")])
		#expect(api.names(in: production) == ([], []) && refresher.calls.count == 1)
	}

	@Test("a key changed while the token renewed, after GitHub refused its write, isn't written over")
	func rereadsAfterRenewal() async throws {
		let github = TokenGatedGitHub(valid: "ghu_1")
		let api = github.api
		api.edit("A", secret: true, in: scope)
		let reviewed = try await reviewed(api, in: scope)
		let scope = scope
		api.fail(.setSecret, with: .unauthorized) {
			github.accept("ghu_2")
			api.edit("A", secret: true, value: "theirs", in: scope)
		}
		let (client, _) = try await client(github)
		let report = await publish([change("A", .replace(remoteID: "secret"))], to: target(), reviewed: reviewed, using: client)
		#expect(report.outcomes == ["A": .failed("Changed on GitHub since this review. Review again.")])
		#expect(api.secretValue("A", in: scope) == Data("theirs".utf8))
	}

	@Test("a read-back GitHub refused until the token renewed leaves the write's time unknown, as someone may have changed it meanwhile")
	func readBackAfterRenewal() async throws {
		let github = TokenGatedGitHub(valid: "ghu_1")
		let api = github.api
		let reviewed = try await reviewed(api, in: scope)
		let scope = scope
		api.fail(.secret, after: 1, with: .unauthorized) {
			github.accept("ghu_2")
			api.edit("A", secret: true, value: "theirs", in: scope)
		}
		let (client, _) = try await client(github)
		let report = await publish([change("A"), change("B")], to: target(), reviewed: reviewed, using: client)
		#expect(report.outcomes == ["A": .published, "B": .published])
		#expect(report.published.first { $0.key == "A" }?.remoteUpdatedAt == nil)
		#expect(report.published.first { $0.key == "B" }?.remoteUpdatedAt != nil, "The renewed token carries on")
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
		let repositories = try await client(route).repositories().get().repositories
		#expect(repositories.count == 101 && Set(repositories.map(\.id)).count == 101)
		#expect(repositories.first { $0.id == "1100" } == GitHubRepository(id: "1100", fullName: "northwind/last", isPrivate: false))
		#expect(route.requests.allSatisfy { $0.header("Authorization") == "Bearer ghu_token" })
	}

	@Test("repositories are listed leniently: a malformed one is skipped, a shifting total is followed to GitHub's last page, and each says what the person may change")
	func listsRepositoriesLeniently() async throws {
		@Sendable func repository(_ id: Int, _ name: String, push: Bool = true, admin: Bool = false, archived: Bool = false) -> [String: Any] {
			[
				"id": id, "full_name": name, "private": true, "archived": archived,
				"permissions": ["admin": admin, "maintain": false, "push": push, "triage": true, "pull": true],
			]
		}
		let route = PlatformHTTPStub.platform { request in
			let page = Int(request.query["page"] ?? "1") ?? 1
			switch request.url.path {
			case "/user/installations":
				#expect(request.query["per_page"] == "100")
				return .json(200, ["total_count": 1, "installations": [["id": 11]]])
			case "/user/installations/11/repositories":
				#expect(request.query["per_page"] == "100")
				if page == 1 {
					var repositories = (0..<97).map { repository(1_000 + $0, "northwind/repo-\($0)") }
					repositories += [
						repository(2_000, "not a name"), repository(2_001, "northwind/readonly", push: false),
						repository(2_002, "northwind/old", archived: true),
					]
					return .json(200, ["total_count": 150, "repositories": repositories], headers: [
						"Link": "<https://api.github.com/user/installations/11/repositories?per_page=100&page=2>; rel=\"next\", <https://api.github.com/user/installations/11/repositories?per_page=100&page=2>; rel=\"last\"",
					])
				}
				let rest = (0..<98).map { repository(3_000 + $0, "northwind/more-\($0)") }
				return .json(200, ["total_count": 200, "repositories": [repository(2_003, "mona-cat_octo/admin", admin: true), ["id": 2_004]] + rest], headers: [
					"Link": "<https://api.github.com/user/installations/11/repositories?per_page=100&page=1>; rel=\"prev\", <https://api.github.com/user/installations/11/repositories?per_page=100&page=1>; rel=\"first\"",
				])
			default:
				return .json(404, [:])
			}
		}
		let listed = try await client(route).repositories().get()
		#expect(listed.repositories.count == 198 && !listed.hidesSSORepositories)
		let byName = Dictionary(uniqueKeysWithValues: listed.repositories.map { ($0.fullName, $0) })
		#expect(byName["northwind/repo-0"]?.permission == .write && byName["northwind/repo-0"]?.canChange(.repository) == true)
		#expect(byName["northwind/readonly"]?.permission == .read && byName["northwind/readonly"]?.canChange(.repository) == false)
		#expect(byName["northwind/old"]?.isArchived == true && byName["northwind/old"]?.canChange(.repository) == false)
		let admin = try #require(byName["mona-cat_octo/admin"], "A managed user owns it")
		#expect(admin.permission == .admin && admin.canChange(.environment(id: "1", name: "production")))
		#expect(byName["northwind/repo-0"]?.canChange(.environment(id: "1", name: "production")) == false, "An environment's secrets need admin")
		#expect(route.requests.count == 3, "GitHub's Link said the full page 2 was the last")
	}

	@Test("a list longer than LPM Vault reads says so, and one GitHub cut short for single sign-on says that")
	func reportsTooLongAndSSO() async throws {
		let endless = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/user/installations": return .json(200, ["total_count": 1, "installations": [["id": 11]]])
			default:
				let page = Int(request.query["page"] ?? "1") ?? 1
				return .json(200, ["total_count": 1_000_000, "repositories": (0..<100).map { ["id": page * 1_000 + $0, "full_name": "n/r\(page)-\($0)"] }],
					headers: ["Link": "<https://api.github.com/x?page=\(page + 1)>; rel=\"next\""])
			}
		}
		var limits = GitHubClient.Limits()
		limits.maximumPages = 3
		#expect(await client(endless, limits: limits).repositories() == .failure(.tooLarge))

		let partial = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/user/installations":
				return .json(200, ["total_count": 1, "installations": [["id": 11]]], headers: ["X-GitHub-SSO": "partial-results; organizations=21955855"])
			default: return .json(200, ["total_count": 0, "repositories": []])
			}
		}
		#expect(try await client(partial).repositories().get() == GitHubRepositoryList(repositories: [], hidesSSORepositories: true))
		let required = PlatformHTTPStub.platform { _ in
			.json(403, ["message": "Resource protected by organization SAML enforcement."], headers: [
				"X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso?authorization_request=AZSCKtL4U8yX1H3sCQIVnVgmjmon5fWxks5YrqhJgah0b2tlbl9pZM4EuMz4",
			])
		}
		#expect(await client(required).secrets(in: GitHubScope(repository: "acme/api", environment: nil)) == .failure(.ssoRequired))
		#expect(await client(required).secret("API_TOKEN", in: GitHubScope(repository: "acme/api", environment: nil)) == .failure(.ssoRequired))
	}

	@Test("a redirect, as for a repository renamed since its name was read, reads as moved")
	func readsRedirectsAsMoved() async {
		for status in [301, 302, 307, 308] {
			let route = PlatformHTTPStub.platform { _ in PlatformHTTPStub.Reply(status: status, headers: ["Location": "/repositories/1296269/environments"], body: Data()) }
			#expect(await client(route).environments(of: "northwind/storefront") == .failure(.moved))
			#expect(route.requests.count == 1)
		}
	}

	@Test("a repository without environments may answer without the list, and that's no environments")
	func readsMissingEnvironments() async throws {
		for body: [String: Any] in [["total_count": 0], [:], ["total_count": 0, "environments": []]] {
			let data = try JSONSerialization.data(withJSONObject: body)
			let route = PlatformHTTPStub.platform { _ in PlatformHTTPStub.Reply(status: 200, body: data) }
			#expect(try await client(route).environments(of: "northwind/storefront").get().isEmpty)
		}
		let missing = PlatformHTTPStub.platform { _ in .json(200, ["total_count": 2]) }
		#expect(await client(missing).environments(of: "northwind/storefront") == .failure(.invalidResponse))
	}

	@Test("an environment is read by its escaped name, and one GitHub doesn't have is none")
	func readsEnvironmentByName() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath {
			case "/repos/northwind/storefront/environments/staging%2Feu": return .json(200, ["id": 161_088_069, "name": "staging/eu"])
			default: return .json(404, ["message": "Not Found"])
			}
		}
		#expect(try await client(route).environment(named: "staging/eu", of: "northwind/storefront").get()
			== GitHubEnvironment(id: "161088069", name: "staging/eu"))
		#expect(try await client(route).environment(named: "production", of: "northwind/storefront").get() == nil)
	}

	@Test("an installation that's suspended, or refuses its repositories, is left out, saying so, and the others are listed")
	func skipsRefusedInstallations() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/user/installations":
				return .json(200, ["total_count": 5, "installations": [
					["id": 11, "suspended_at": "2026-10-01T10:00:00Z"], ["id": 12], ["id": 13], ["id": 14], ["id": 15],
				]])
			case "/user/installations/12/repositories": return .json(403, ["message": "This installation has been suspended"])
			case "/user/installations/13/repositories": return .json(404, ["message": "Not Found"])
			case "/user/installations/14/repositories":
				return .json(200, ["total_count": 1, "repositories": [["id": 1_000, "full_name": "northwind/api", "private": true]]])
			case "/user/installations/15/repositories":
				return .json(403, ["message": "Resource protected by organization SAML enforcement."], headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"])
			default: return .json(500, [:])
			}
		}
		let listed = try await client(route).repositories().get()
		#expect(listed.repositories.map(\.fullName) == ["northwind/api"])
		#expect(listed.skipsInstallations && listed.hidesSSORepositories)
		#expect(!route.requests.contains { $0.url.path == "/user/installations/11/repositories" }, "A suspended installation isn't asked")
	}

	@Test("a list that runs out of the bytes LPM Vault reads is too large, not unreadable")
	func runsOutOfBytes() async {
		let page = (0..<100).map { ["id": 1_000 + $0, "full_name": "northwind/repository-with-a-longer-name-\($0)", "private": true] as [String: Any] }
		let body = (try? JSONSerialization.data(withJSONObject: ["total_count": 1_000, "repositories": page])) ?? Data()
		let pageBytes = body.count
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/user/installations": return .json(200, ["total_count": 1, "installations": [["id": 11]]])
			default:
				return PlatformHTTPStub.Reply(
					status: 200, headers: ["Content-Type": "application/json", "Link": "<https://api.github.com/x?page=2>; rel=\"next\""], body: body)
			}
		}
		var limits = GitHubClient.Limits()
		limits.listBytes = pageBytes * 3 / 2 + 200
		#expect(await client(route, limits: limits).repositories() == .failure(.tooLarge))
	}

	@Test("a listing that runs out of time after reading pages is too large, though the late page is another installation's first")
	func runsOutOfTime() async throws {
		let deadline = TestDeadline()
		let held = DispatchSemaphore(value: 0)
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/user/installations": return .json(200, ["total_count": 1, "installations": [["id": 11]]])
			default:
				deadline.pass()
				held.wait()
				return .json(500, [:])
			}
		}
		var limits = GitHubClient.Limits()
		limits.deadlinePasses = { _ in await deadline.wait() }
		let result = await client(route, limits: limits).repositories()
		held.signal()
		#expect(result == .failure(.tooLarge))
	}

	@Test("the bodies of installations that refuse their repositories count against what a listing reads")
	func countsRefusalBodies() async {
		let refusal = String(repeating: "x", count: 300_000)
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path {
			case "/user/installations": return .json(200, ["total_count": 10, "installations": (11...20).map { ["id": $0] }])
			default: return .json(403, ["message": refusal])
			}
		}
		var limits = GitHubClient.Limits()
		limits.listBytes = 1_000_000
		#expect(await client(route, limits: limits).repositories() == .failure(.tooLarge))
		#expect(route.requests.filter { $0.url.path.hasSuffix("/repositories") }.count == 4, "Four refusals spend the budget, and nothing is asked after")
	}

	@Test("GitHub's Link decides whether a list goes on, even past a short page")
	func followsLink() async throws {
		let route = PlatformHTTPStub.platform { request in
			let page = Int(request.query["page"] ?? "1") ?? 1
			switch (request.url.path, page) {
			case ("/user/installations", _): return .json(200, ["total_count": 1, "installations": [["id": 11]]])
			case (_, 1):
				return .json(200, ["total_count": 3, "repositories": [["id": 1, "full_name": "n/a"], ["id": 2, "full_name": "n/b"]]],
					headers: ["Link": "<https://api.github.com/x?page=2>; rel=\"next\""])
			default:
				return .json(200, ["total_count": 3, "repositories": [["id": 3, "full_name": "n/c"]]])
			}
		}
		#expect(try await client(route).repositories().get().repositories.map(\.id) == ["1", "2", "3"])
	}

	@Test("a page holding more items than asked for is refused before any item is decoded")
	func boundsPageBeforeDecoding() throws {
		let data = try JSONSerialization.data(withJSONObject: ["total_count": 3_000, "repositories": (0..<3_000).map { ["id": $0] }])
		CountedItem.reset()
		#expect(throws: DecodingError.self) { try GitHubListPage<CountedItem>.decode(data, field: "repositories", lenient: true, maximumItems: 100) }
		#expect(CountedItem.decoded == 0)
		let fits = try JSONSerialization.data(withJSONObject: ["total_count": 2, "repositories": [["id": 1], ["id": 2]]])
		#expect(try GitHubListPage<CountedItem>.decode(fits, field: "repositories", lenient: false, maximumItems: 100).items.count == 2)
		#expect(CountedItem.decoded == 2)
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
		#expect(try await client(route).repositories().get().repositories.map(\.id) == ["1000", "1001"])
		#expect(route.requests.map(\.url.path) == ["/user/installations", "/user/installations/11/repositories", "/user/installations/12/repositories"])
	}

	@Test("a list of secrets or variables whose total changes between pages, or holds more than it says, fails, and one that never ends is too large")
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
		#expect(await client(endless, limits: limits).secrets(in: GitHubScope(repository: "a/b", environment: nil)) == .failure(.tooLarge))
		#expect(endless.requests.count == 3)
	}

	@Test("an environment's secrets and variables are read under its escaped name, a variable's value never decoded")
	func readsEnvironmentScope() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath {
			case "/repos/northwind/storefront/environments/staging%2Feu/secrets":
				#expect(request.query["per_page"] == "100")
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
		let bodies = Dictionary(route.requests.compactMap { request in request.json.map { (request.method, $0) } }, uniquingKeysWith: { first, _ in first })
		#expect(bodies["PUT"]?["encrypted_value"] as? String == Data([1, 2, 3]).base64EncodedString() && bodies["PUT"]?["key_id"] as? String == key.id)
		#expect(bodies["POST"]?["name"] as? String == "PUBLIC_URL" && bodies["POST"]?["value"] as? String == "https://x")
		#expect(bodies["PATCH"]?["name"] as? String == "LOG_LEVEL" && bodies["PATCH"]?["value"] as? String == "info")
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

/// A list item that counts how many were decoded.
struct CountedItem: Decodable {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var count = 0

	static var decoded: Int { lock.withLock { count } }
	static func reset() { lock.withLock { count = 0 } }

	init(from decoder: any Decoder) throws {
		Self.lock.withLock { Self.count += 1 }
	}
}

/// A listing's deadline a test passes by hand. Waiting for it returns once
/// it's passed, or when the waiting task is cancelled, as the real deadline's
/// sleep does.
final class TestDeadline: @unchecked Sendable {
	private let lock = NSLock()
	private var passed = false
	private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

	func pass() {
		let waiting = lock.withLock {
			passed = true
			defer { waiters = [:] }
			return Array(waiters.values)
		}
		for waiter in waiting { waiter.resume() }
	}

	func wait() async {
		let id = UUID()
		await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				let resumeNow = lock.withLock {
					if passed || Task.isCancelled { return true }
					waiters[id] = continuation
					return false
				}
				if resumeNow { continuation.resume() }
			}
		} onCancel: {
			lock.withLock { waiters.removeValue(forKey: id) }?.resume()
		}
	}
}
