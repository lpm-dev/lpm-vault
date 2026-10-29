import Foundation
import Testing

@testable import LPMVault

/// Lends a search each project's values through `base`, counting how many
/// projects' values are lent at once.
final class CountingValueSearchSource: ValueSearchSource, @unchecked Sendable {
	private let base: any ValueSearchSource
	private let lock = NSLock()
	private var lent = 0
	private var mostLent = 0
	private var lentProjects: [String] = []

	init(_ base: any ValueSearchSource) {
		self.base = base
	}

	/// The most projects whose values were lent at the same time.
	var mostLentAtOnce: Int { lock.withLock { mostLent } }
	/// Each project whose values were lent, in order.
	var reads: [String] { lock.withLock { lentProjects } }

	func withValues<T>(of projectID: String, _ body: (VaultProject) -> T) async -> Result<T?, KeychainError> {
		await base.withValues(of: projectID) { project in
			lock.withLock {
				lent += 1
				mostLent = max(mostLent, lent)
				lentProjects.append(projectID)
			}
			defer { lock.withLock { lent -= 1 } }
			return body(project)
		}
	}
}

/// Every string `value` holds, as deep as reflection reaches, leaving out
/// the store a model points back to.
func reflectedStrings(in value: Any, depth: Int = 0) -> [String] {
	if let string = value as? String { return [string] }
	guard depth < 32 else { return [] }
	return Mirror(reflecting: value).children.flatMap { child -> [String] in
		guard !["store", "_store", "_$observationRegistrar", "task", "_task"].contains(child.label ?? "") else { return [] }
		return reflectedStrings(in: child.value, depth: depth + 1)
	}
}

/// Holds a search's next Keychain read until the test lets it go.
final class ValueSearchReadGate: @unchecked Sendable {
	private let lock = NSLock()
	private let release = DispatchSemaphore(value: 0)
	private var waiting: [String] = []

	/// The projects whose reads are waiting at the gate, in order.
	var held: [String] { lock.withLock { waiting } }

	func hold(_ projectID: String) {
		lock.withLock { waiting.append(projectID) }
		release.wait()
	}

	func open() {
		release.signal()
	}
}

@Suite("Value search matching")
struct ValueSearchMatchingTests {
	@Test("a value matches only its exact bytes, never one Swift calls equal or one trimmed")
	func exactBytesOnly() throws {
		let matcher = try #require(ValueMatcher(term: "a\u{2000}b", findsContainingValues: false))
		#expect(matcher.match("a\u{2000}b") == .exact)
		#expect(matcher.match("a\u{2002}b") == nil, "U+2002 is canonically equal to U+2000, but other bytes")
		let precomposed = try #require(ValueMatcher(term: "caf\u{E9}", findsContainingValues: false))
		#expect(precomposed.match("cafe\u{301}") == nil)
		let token = try #require(ValueMatcher(term: "token", findsContainingValues: false))
		#expect(token.match(" token") == nil)
		#expect(token.match("token\n") == nil)
		#expect(token.match("Token") == nil)
		#expect(token.match("token") == .exact)
		let spaced = try #require(ValueMatcher(term: " token ", findsContainingValues: false))
		#expect(spaced.match(" token ") == .exact, "A term's own spaces are part of it")
		#expect(spaced.match("token") == nil)
	}

	@Test("values that contain the term are found only when asked")
	func containsIsOptIn() throws {
		let url = "postgres://app:p4ssw0rd!@db.example.com/app"
		let exact = try #require(ValueMatcher(term: "p4ssw0rd!", findsContainingValues: false))
		#expect(exact.match(url) == nil)
		let contains = try #require(ValueMatcher(term: "p4ssw0rd!", findsContainingValues: true))
		#expect(contains.findsContainingValues)
		#expect(contains.match(url) == .contains)
		#expect(contains.match("p4ssw0rd!") == .exact, "The value itself is still an exact match")
		#expect(contains.match("p4ssw0rd") == nil)
	}

	@Test("a value that contains the term is found wherever the term starts in it, overlaps and repeats included")
	func containsFindsEveryStart() throws {
		var state: UInt64 = 0x9E37_79B9_7F4A_7C15
		func next(_ bound: Int) -> Int {
			state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
			return Int((state >> 33) % UInt64(bound))
		}
		func text(_ count: Int) -> String { String((0..<count).map { _ in next(2) == 0 ? "a" : "b" }) }
		for _ in 0..<3_000 {
			let term = text(8 + next(5))
			let value = text(term.count + 1 + next(30))
			let matcher = try #require(ValueMatcher(term: term, findsContainingValues: true))
			#expect(matcher.match(value) == (value.contains(term) ? .contains : nil), "\(term) in \(value)")
		}
	}

	@Test("finding values that contain the term reads each byte of a value once, however repetitive", .hangLimit)
	func containsIsLinear() throws {
		let half = 8 << 20
		let term = String(repeating: "a", count: half - 1) + "b"
		let matcher = try #require(ValueMatcher(term: term, findsContainingValues: true))
		let repetitive = String(repeating: "a", count: half * 2)
		#expect(matcher.match(repetitive) == nil)
		#expect(matcher.match(repetitive + "b") == .contains)
	}

	@Test("a term shorter than eight characters never finds values that contain it")
	func containsNeedsEightCharacters() throws {
		#expect(!ValueMatcher.allowsContaining("1234567"))
		#expect(ValueMatcher.allowsContaining("12345678"))
		#expect(!ValueMatcher.allowsContaining("🔑🔑🔑🔑🔑🔑🔑"), "Characters, not bytes, are counted")
		let short = try #require(ValueMatcher(term: "secret", findsContainingValues: true))
		#expect(!short.findsContainingValues)
		#expect(short.match("my-secret-value") == nil)
	}

	@Test("empty values match nothing, and an empty term searches nothing")
	func emptyValuesIgnored() throws {
		#expect(ValueMatcher(term: "", findsContainingValues: true) == nil)
		let matcher = try #require(ValueMatcher(term: "long-enough-term", findsContainingValues: true))
		#expect(matcher.match("") == nil)
	}

	@Test("a digest tells exactly equal values from others, under a key made for one scan")
	func digestsAreKeyedPerScan() {
		let digester = ValueDigester()
		#expect(digester.digest("value") == digester.digest("value"))
		#expect(digester.digest("a\u{2000}b") != digester.digest("a\u{2002}b"))
		#expect(digester.digest("value") != digester.digest("value "))
		#expect(ValueDigester().digest("value") != digester.digest("value"), "Another scan's key gives other digests")
	}

	@Test("the environments of a key with byte for byte the same value are paired in order, empty values left out")
	func sameValueEnvironments() {
		let matches = SameValueEnvironments(
			["default": "s3cret", "staging": "other", "production": "s3cret", "preview": "s3cret", "test": "", "ci": ""],
			order: ["default", "staging", "production", "preview", "test", "ci"])
		#expect(matches.others(of: "default") == ["production", "preview"])
		#expect(matches.others(of: "production") == ["default", "preview"])
		#expect(matches.others(of: "staging").isEmpty)
		#expect(matches.others(of: "test").isEmpty, "Empty values are never the same value")
		#expect(matches.others(of: "missing").isEmpty)
		#expect(SameValueEnvironments(["default": "a\u{2000}b", "production": "a\u{2002}b"], order: ["default", "production"]).others(of: "default").isEmpty)
	}
}

@Suite("Value search wording")
struct ValueSearchWordingTests {
	private let personal = ValueSearchAccount(account: .personal, name: "Personal vault")
	private let acme = ValueSearchAccount(account: .org("acme"), name: "Acme")

	private func hit(_ project: String, _ environment: String, _ key: String, account: ValueSearchAccount? = nil,
		match: ValueSearchHit.Match = .exact) -> ValueSearchHit
	{
		ValueSearchHit(place: ValueSearchPlace(location: ValueLocation(projectID: project, environment: environment, key: key),
			projectName: project, account: account ?? personal, environmentIndex: 0), match: match)
	}

	@Test("a search's summary says how many places, projects and accounts, and what couldn't be read")
	func summaries() {
		var find = ValueSearchModel.Find(scope: .account, accountName: "Personal vault", findsContainingValues: true,
			order: ["a", "b", "c"], reached: 3, searched: 3,
			hits: [hit("a", "default", "X"), hit("a", "production", "Y"), hit("b", "default", "Z", match: .contains)], phase: .finished)
		#expect(ValueSearchWording.findSubtitle(find, termKept: true) == "3 places in 2 projects in Personal vault.")
		#expect(ValueSearchWording.matchCounts(find) == "2 exact · 1 contain it")
		#expect(ValueSearchWording.findSubtitle(find, termKept: false) == "3 places in 2 projects · from your last search. The value wasn’t kept.")
		#expect(ValueSearchWording.strip(find: find, reuse: nil) == "Value search · 3 places in 2 projects")
		find.add(ValueSearchSkip(projectID: "c", projectName: "c", account: personal, reason: .damaged))
		find.searched = 2
		#expect(ValueSearchWording.findSubtitle(find, termKept: true) == "3 places in 2 projects. 1 project couldn’t be searched.")

		let every = ValueSearchModel.Find(scope: .everyAccount, accountName: nil, findsContainingValues: false, order: ["a", "t"],
			reached: 2, searched: 2, hits: [hit("a", "default", "X"), hit("t", "default", "X", account: acme)], phase: .finished)
		#expect(ValueSearchWording.findSubtitle(every, termKept: true) == "2 places in 2 projects across 2 accounts.")
		#expect(ValueSearchWording.matchCounts(every) == nil)

		let stopped = ValueSearchModel.Find(scope: .account, accountName: "Personal vault", findsContainingValues: false,
			order: ["a", "b", "c", "d"], reached: 1, searched: 1, hits: [hit("a", "default", "X")], phase: .stopped)
		#expect(ValueSearchWording.findSubtitle(stopped, termKept: true) == "Stopped after 1 of 4 projects.")
		#expect(ValueSearchWording.stopped(unread: stopped.unread.count) == "Search stopped. 3 projects weren’t read.")
		#expect(ValueSearchWording.resultsHeading(stopped) == "Found in 1 of 4 projects · 1")
		#expect(ValueSearchWording.strip(find: stopped, reuse: nil) == "Value search · 1 place in 1 project, stopped after 1 of 4")
	}

	@Test("no matches suggests only what would read more")
	func noMatches() {
		let none = ValueSearchModel.Find(scope: .account, accountName: "Personal vault", findsContainingValues: false,
			order: ["a"], reached: 1, searched: 1, phase: .finished)
		#expect(ValueSearchWording.findSubtitle(none, termKept: true) == "Searched 1 project in Personal vault.")
		#expect(ValueSearchWording.noMatches(none, canWidenToEveryAccount: true, canWidenToContaining: true)
			== "This value isn’t stored in Personal vault. Try searching every account on this Mac, or turning on “Also find values that contain it”.")
		#expect(ValueSearchWording.noMatches(none, canWidenToEveryAccount: false, canWidenToContaining: true)
			== "This value isn’t stored in Personal vault. Try turning on “Also find values that contain it”.")
		#expect(ValueSearchWording.noMatches(none, canWidenToEveryAccount: true, canWidenToContaining: false)
			== "This value isn’t stored in Personal vault. Try searching every account on this Mac.")
		#expect(ValueSearchWording.noMatches(none, canWidenToEveryAccount: false, canWidenToContaining: false)
			== "This value isn’t stored in Personal vault.")
	}

	@Test("a search or scan that couldn't read every project speaks only for the ones it read")
	func incompleteCoverage() {
		let damaged = ValueSearchSkip(projectID: "c", projectName: "c", account: personal, reason: .damaged)
		let two = ValueSearchModel.Find(scope: .account, accountName: "Personal vault", findsContainingValues: false,
			order: ["a", "b", "c"], reached: 3, searched: 2, skips: [damaged], phase: .finished)
		#expect(ValueSearchWording.noMatches(two, canWidenToEveryAccount: false, canWidenToContaining: false)
			== "None of the 2 projects searched store this value.")
		let one = ValueSearchModel.Find(scope: .account, accountName: "Personal vault", findsContainingValues: false,
			order: ["a", "c"], reached: 2, searched: 1, skips: [damaged], phase: .finished)
		#expect(ValueSearchWording.noMatches(one, canWidenToEveryAccount: false, canWidenToContaining: false)
			== "The project searched doesn’t store this value.")

		var reuse = ValueSearchModel.Reuse(scope: .account, accountName: "Personal vault", total: 3, reached: 3, compared: 3, phase: .finished)
		#expect(ValueSearchWording.nothingReused(reuse) == "Every secret-looking value is stored under one key only.")
		reuse.skips = [damaged]
		reuse.compared = 2
		#expect(ValueSearchWording.nothingReused(reuse) == "In the 2 projects compared, every secret-looking value is stored under one key only.")
		#expect(ValueSearchWording.reuseSubtitle(reuse) == "Compared 2 projects in Personal vault. 1 project couldn’t be compared.")
	}

	@Test("a reused group is summed up without its value")
	func groups() {
		func place(_ project: String, _ environment: String, _ key: String) -> ValueSearchPlace {
			ValueSearchPlace(location: ValueLocation(projectID: project, environment: environment, key: key),
				projectName: project, account: personal, environmentIndex: 0)
		}
		let projects = ReusedValueGroup(id: 0, places: [place("a", "production", "X"), place("b", "production", "Y")], span: .projects,
			isConfiguration: false)
		#expect(ValueSearchWording.groupSummary(projects) == "2 projects · .env.production in both")
		#expect(ValueSearchWording.groupSpoken(projects) == "Shared by 2 keys across 2 projects, .env.production in both. Across projects.")
		let environments = ReusedValueGroup(id: 1, places: [place("a", "production", "X"), place("a", "staging", "X"), place("a", "default", "X")],
			span: .environments, isConfiguration: false)
		#expect(ValueSearchWording.groupSummary(environments) == "a · \(ListFormatter.localizedString(byJoining: [".env.production", ".env.staging", ".env"]))")
		#expect(ValueSearchWording.sameValue(as: ["production"]) == "Same value as .env.production.")
		#expect(ValueSearchWording.opened(ValueLocation(projectID: "b", environment: "default", key: "PAYMENTS"), projectName: "Bravo")
			== "Opened PAYMENTS in Bravo, .env")
		#expect(ValueSearchWording.sameValue(as: ["default", "production"]) == "Same value as .env and .env.production.")
		#expect(ValueSearchWording.sameValue(as: ["default", "staging", "production"])
			== "Same value in 3 other environments: .env, .env.staging, .env.production.")
	}
}

@Suite("Value secrecy")
struct ValueSecrecyTests {
	@Test("config values that repeat for good reason don't look secret, credentials do")
	func noiseFilter() {
		let rules = ValueSecrecyRules.none
		#expect(!rules.looksSecret(key: "PORT", value: "3000"))
		#expect(!rules.looksSecret(key: "DEBUG", value: "true"))
		#expect(!rules.looksSecret(key: "API_HOST", value: "localhost"))
		#expect(!rules.looksSecret(key: "DATABASE_HOST", value: "db.example.com"))
		#expect(!rules.looksSecret(key: "NODE_ENV", value: "production"))
		#expect(!rules.looksSecret(key: "SESSION_SECRET", value: ""), "An empty value is never a credential")
		#expect(rules.looksSecret(key: "SESSION_SECRET", value: "x"))
		#expect(rules.looksSecret(key: "DATABASE_URL", value: "postgres://app:p4ssw0rd@db.example.com/app"))
		#expect(rules.looksSecret(key: "SENTRY_AUTH", value: "sntrys_eyJpYXQiOjE3MDAwMDAwMDAsInVybCI6"))
		#expect(!rules.looksSecret(key: "NEXT_PUBLIC_STRIPE_KEY", value: "pk_live_51HqLyjWDarjtT1zdp7dcXZ"), "A public prefix makes it public")
		#expect(!rules.looksSecret(key: "STRIPE_PUBLISHABLE_KEY", value: "pk_live_51HqLyjWDarjtT1zdp7dcXZ"))
	}

	@Test("keys lpm.json marks secret are secret and public ones aren't, whatever they hold")
	func rulesDecide() {
		let rules = ValueSecrecyRules(overview: ProjectEnvSchemaOverview(rules: [
			.init(key: "LICENSE", isPublic: false, source: nil, badges: [], isSecret: true),
			.init(key: "WIDGET_TOKEN", isPublic: true, source: nil, badges: []),
		], groups: []))
		#expect(rules.looksSecret(key: "LICENSE", value: "abc"))
		#expect(!rules.looksSecret(key: "WIDGET_TOKEN", value: "tok_abcdefghijklmnopqrstuvwxyz"))
	}

	@Test("one value is judged as the schema's Secret suggestion judges a key holding it")
	func sameJudgmentAsTheSuggestion() {
		let cases: [(String, String)] = [
			("PORT", "3000"), ("DEBUG", "true"), ("API_HOST", "localhost"), ("APP_URL", "https://example.com/app"),
			("DATABASE_URL", "postgres://app:p4ssw0rd@db.example.com/app"), ("WEBHOOK", "https://hooks.example.com/T00/B00/XXXX"),
			("SESSION_SECRET", "s3cret"), ("API_KEY", "short"), ("API_KEY", "abcdefghijklmnopqrstuvwxyz012345"),
			("BUILD_ID", "a8f3c9e2b7d14f6a9c0e3b5d7f9a1c3e"), ("RANDOM_THING", "Zq8vK2mN9pL4xR7tW1yB6cF3hJ5"),
			("CONTACT_EMAIL", "support.team.someone@example.com"),
		]
		for (key, value) in cases {
			let suggested = ProjectEnvSchemaSuggestion.suggestions(for: key, values: [value], publicPrefix: nil)
				.contains { $0.change == .secret }
			#expect(ProjectEnvSchemaSuggestion.looksSecret(key: key, value: value) == suggested, "\(key)")
		}
	}
}

@Suite("Value search", .serialized)
@MainActor
struct ValueSearchTests {
	typealias Project = (id: String, name: String, environments: [String: [String: String]])

	@MainActor
	struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		let biometric: MockBiometricService
		let source: CountingValueSearchSource
		let domain: String

		var search: ValueSearchModel { store.valueSearch }

		func close() {
			store.lock()
			UserDefaults().removePersistentDomain(forName: domain)
		}
	}

	/// An unlocked store with `projects`, `selected` open, and `orgs` assigning
	/// projects to organizations the person belongs to.
	private func fixture(_ projects: [Project], selected: String, orgs: [String: String] = [:]) async throws -> Fixture {
		let keychain = MockKeychainService()
		for project in projects { keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments) }
		let domain = "value-search-\(UUID().uuidString)"
		let biometric = MockBiometricService()
		let store = VaultStore(keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
			preferences: try #require(UserDefaults(suiteName: domain)))
		await store.unlock()
		try #require(store.isUnlocked)
		if !orgs.isEmpty {
			store.currentUser = LPMUser(id: "user", username: "user", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil,
				orgs: Set(orgs.values).sorted().map { LPMOrg(id: "\($0)-id", slug: $0, name: $0.capitalized, avatarUrl: nil, role: "owner") })
			for (project, slug) in orgs { store.vaultOrgAssociations[project] = slug }
		}
		store.openProject(id: selected)
		try #require(try await waitUntil { store.selectedProject?.id == selected && store.selectedProject?.hasLoadedEnvironments == true })
		let source = CountingValueSearchSource(store.valueSearchSource)
		store.valueSearchSource = source
		return Fixture(store: store, keychain: keychain, biometric: biometric, source: source, domain: domain)
	}

	private func find(
		_ term: String, in fixture: Fixture, scope: ValueSearchModel.Scope = .account, containing: Bool = false
	) async throws -> ValueSearchModel.Find {
		let search = fixture.search
		search.scope = scope
		search.findsContainingValues = containing
		search.term = ExactText(term)
		search.startFind()
		await search.task?.value
		return try #require(search.find)
	}

	private func scanForReuse(in fixture: Fixture, scope: ValueSearchModel.Scope = .account) async throws -> ValueSearchModel.Reuse {
		fixture.search.scope = scope
		fixture.search.startReuse()
		await fixture.search.task?.value
		return try #require(fixture.search.reuse)
	}

	private func places(_ hits: [ValueSearchHit]) -> [String] {
		hits.map { "\($0.place.projectName) › \($0.place.location.environment) › \($0.place.location.key)" }
	}

	@Test("a search lists every place that stores the value, in the sidebar's order, reading the others one project at a time")
	func findsEveryPlace() async throws {
		let shared = "sk_live_51HqLyjWDarjtT1zdp7dcXZ"
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["DATABASE_URL": shared, "OTHER": "x"], "production": ["STRIPE_KEY": shared]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["PAYMENTS": shared, "PAYMENTS_COPY": shared + " "]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["NOPE": "other"]]),
		], selected: "alpha")
		defer { fixture.close() }
		let found = try await find(shared, in: fixture)
		#expect(found.phase == .finished)
		#expect(places(found.hits) == ["Alpha › default › DATABASE_URL", "Alpha › production › STRIPE_KEY", "Bravo › default › PAYMENTS"])
		#expect(found.hits.allSatisfy { $0.match == .exact })
		#expect(found.searched == 3)
		#expect(found.skips.isEmpty)
		#expect(fixture.source.reads == ["bravo", "charlie"], "The selected project's values are already held")
		#expect(fixture.source.mostLentAtOnce == 1)
	}

	@Test("only the values of one other project are held at a time, and neither they nor the term survive the search")
	func holdsOneProjectAtATime() async throws {
		let markers = (0..<6).map { "marker-\($0)-\(UUID().uuidString)" }
		let projects: [Project] = markers.enumerated().map { index, marker in
			(id: "p\(index)", name: "Project \(index)", environments: ["default": ["TOKEN": marker, "SHARED_SECRET": "shared-\(markers[0])"]])
		}
		let fixture = try await fixture(projects, selected: "p0")
		defer { fixture.close() }
		let found = try await find(markers[3], in: fixture)
		#expect(places(found.hits) == ["Project 3 › default › TOKEN"])
		let reuse = try await scanForReuse(in: fixture)
		#expect(reuse.reported.count == 1)
		#expect(fixture.source.reads == ["p1", "p2", "p3", "p4", "p5", "p1", "p2", "p3", "p4", "p5"])
		#expect(fixture.source.mostLentAtOnce == 1)
		fixture.search.sheetClosed()

		let left = reflectedStrings(in: fixture.search)
		#expect(!left.contains { text in markers.contains { text.contains($0) } }, "No value or term is kept")
		#expect(fixture.store.projects.filter(\.hasLoadedEnvironments).map(\.id) == ["p0"], "Only the selected project's values stay loaded")
	}

	@Test("a search's projects are named, never held: the selected one's values are lent at its turn")
	func targetsHoldNoValues() async throws {
		let marker = "marker-\(UUID().uuidString)"
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": marker]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": marker]]),
		], selected: "alpha")
		defer { fixture.close() }
		let targets = fixture.store.valueSearchTargets(everyAccount: true)
		#expect(targets.map(\.id) == ["alpha", "bravo"])
		#expect(!reflectedStrings(in: targets).contains { $0.contains(marker) }, "A search stalled on one read holds no other project's values")
		let found = try await find(marker, in: fixture)
		#expect(places(found.hits) == ["Alpha › default › TOKEN", "Bravo › default › TOKEN"])
		#expect(fixture.source.reads == ["bravo"], "The selected project's values come from the app, not the Keychain")
	}

	@Test("projects that can't be read are listed as not searched with the reason, never left out")
	func unreadableProjectsListed() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "value"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "value"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "value"]]),
			(id: "delta", name: "Delta", environments: ["default": ["TOKEN": "value"]]),
		], selected: "alpha")
		defer { fixture.close() }
		fixture.keychain.companionRefusals["bravo"] = .unsupported(feature: "history", version: 2, level: .refuse)
		fixture.keychain.companionRefusals["charlie"] = .damaged("a record is unreadable")
		fixture.keychain.unpromptedReadFailures["delta"] = .unexpectedStatus(-25300)
		let found = try await find("value", in: fixture)
		#expect(places(found.hits) == ["Alpha › default › TOKEN"])
		#expect(found.skips.map(\.projectName) == ["Bravo", "Charlie", "Delta"])
		#expect(found.skips.map(\.reason) == [.newerVersion, .damaged, .unreadable])
		#expect(found.searched + found.skips.count == found.total)

		let reuse = try await scanForReuse(in: fixture)
		#expect(reuse.skips.map(\.reason) == [.newerVersion, .damaged, .unreadable])
	}

	@Test("a search never asks for approval: a project whose values need it is listed instead of asking once per project")
	func approvalNeverAskedPerProject() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "value"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "value"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "value"]]),
		], selected: "alpha")
		defer { fixture.close() }
		fixture.keychain.projectsNeedingApproval = ["bravo", "charlie"]
		let authentications = fixture.biometric.authenticateCallCount
		let found = try await find("value", in: fixture)
		_ = try await scanForReuse(in: fixture)
		#expect(fixture.biometric.authenticateCallCount == authentications, "Unlocking asked; the search doesn't ask again")
		#expect(fixture.biometric.confirmationReasons.isEmpty)
		#expect(fixture.keychain.unpromptedProjectReads == ["bravo", "charlie", "bravo", "charlie"], "Every read is one macOS can't ask for")
		#expect(found.skips.map(\.reason) == [.unreadable, .unreadable])
	}

	@Test("a search covers the selected account by default, and every account the person belongs to when widened")
	func accountScope() async throws {
		let fixture = try await fixture([
			(id: "personal", name: "Personal", environments: ["default": ["TOKEN": "shared"]]),
			(id: "team", name: "Team project", environments: ["default": ["TOKEN": "shared"]]),
		], selected: "personal", orgs: ["team": "acme"])
		defer { fixture.close() }
		let mine = try await find("shared", in: fixture)
		#expect(places(mine.hits) == ["Personal › default › TOKEN"])
		#expect(mine.accountName == "Personal vault")
		#expect(mine.total == 1)
		let every = try await find("shared", in: fixture, scope: .everyAccount)
		#expect(places(every.hits) == ["Personal › default › TOKEN", "Team project › default › TOKEN"])
		#expect(every.hits.map(\.place.account.name) == ["Personal vault", "Acme"])
		#expect(every.accountName == nil)
		#expect(every.accountCount == 2)
	}

	@Test("locking or switching accounts cancels a running search and clears its results and term", arguments: ["lock", "account"])
	func lockAndAccountSwitchCancel(trigger: String) async throws {
		let fixture = try await fixture([
			(id: "personal", name: "Personal", environments: ["default": ["TOKEN": "shared"]]),
			(id: "second", name: "Second", environments: ["default": ["TOKEN": "shared"]]),
			(id: "team", name: "Team project", environments: ["default": ["TOKEN": "shared"]]),
		], selected: "personal", orgs: ["team": "acme"])
		defer { fixture.close() }
		let gate = ValueSearchReadGate()
		fixture.keychain.beforeUnpromptedProjectRead = { gate.hold($0) }
		let search = fixture.search
		search.isPresented = true
		search.term = ExactText("shared")
		search.startFind()
		let running = try #require(search.task)
		#expect(try await waitUntil { gate.held == ["second"] })
		#expect(search.isRunning)
		let matcher = try #require(Mirror(reflecting: search).descendant("_matcher") as? ValueMatcher)
		#expect(matcher.match("shared") == .exact)

		if trigger == "lock" { fixture.store.lock() } else { fixture.store.selectAccount(.org("acme")) }
		#expect(search.find == nil)
		#expect(search.term.text.isEmpty)
		#expect(!search.isPresented)
		#expect(matcher.match("shared") == nil, "The search waiting on a read no longer holds the term")
		gate.open()
		await running.value
		#expect(search.find == nil, "The read that was under way adds nothing")
		#expect(!search.isRunning)
	}

	@Test("locking, switching accounts or a new search lets a scan for reused values waiting on a read keep no key", arguments: ["lock", "account", "search"])
	func reuseScanKeyGoes(trigger: String) async throws {
		let fixture = try await fixture([
			(id: "personal", name: "Personal", environments: ["default": ["TOKEN": "shared-secret-value"]]),
			(id: "second", name: "Second", environments: ["default": ["TOKEN": "shared-secret-value"]]),
		], selected: "personal", orgs: ["team": "acme"])
		defer { fixture.close() }
		let gate = ValueSearchReadGate()
		fixture.keychain.beforeUnpromptedProjectRead = { gate.hold($0) }
		let search = fixture.search
		search.isPresented = true
		search.startReuse()
		let running = try #require(search.task)
		#expect(try await waitUntil { gate.held == ["second"] })
		let digester = try #require(Mirror(reflecting: search).descendant("reuseDigester") as? ValueDigester)
		#expect(digester.digest("shared-secret-value") != nil)

		switch trigger {
		case "lock": fixture.store.lock()
		case "account": fixture.store.selectAccount(.org("acme"))
		default:
			search.term = ExactText("shared-secret-value")
			search.startFind()
		}
		#expect(digester.digest("shared-secret-value") == nil, "The digests it made link to no value")
		#expect(search.reuse == nil)
		fixture.keychain.beforeUnpromptedProjectRead = nil
		gate.open()
		await running.value
		#expect(search.reuse == nil, "The read that was under way adds nothing")
	}

	@Test("opening a result in another account keeps the results it came from, and the term goes as the sheet closes")
	func openingKeepsResults() async throws {
		let fixture = try await fixture([
			(id: "personal", name: "Personal", environments: ["default": ["TOKEN": "shared"]]),
			(id: "team", name: "Team project", environments: ["staging": ["API_TOKEN": "shared"]]),
		], selected: "personal", orgs: ["team": "acme"])
		defer { fixture.close() }
		fixture.search.isPresented = true
		let found = try await find("shared", in: fixture, scope: .everyAccount)
		let team = try #require(found.hits.last)
		fixture.search.open(team.place)
		#expect(fixture.store.selectedAccount == .org("acme"))
		#expect(fixture.store.selectedProjectId == "team")
		#expect(fixture.store.selectedEnvironment == "staging")
		#expect(fixture.search.openRequest?.location == team.place.location)
		#expect(fixture.search.openRequest?.changedProject == true)
		#expect(fixture.search.find?.hits.count == 2)
		#expect(!fixture.search.isPresented)
		#expect(fixture.search.term.text.isEmpty)
		#expect(fixture.search.foundEnvironments(in: "team") == ["API_TOKEN": ["staging"]])
	}

	@Test("a result in an environment added since the project was listed opens that environment once the project is read")
	func openingNewEnvironment() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "other"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "other"]]),
		], selected: "alpha")
		defer { fixture.close() }
		fixture.keychain.envStorage["bravo"]?.environments["production"] = ["STRIPE_KEY": "sk_live_added_by_the_cli"]
		fixture.search.isPresented = true
		let found = try await find("sk_live_added_by_the_cli", in: fixture)
		let place = try #require(found.hits.first?.place)
		#expect(place.location == ValueLocation(projectID: "bravo", environment: "production", key: "STRIPE_KEY"))
		fixture.search.open(place)
		let store = fixture.store
		#expect(try await waitUntil { store.selectedProject?.hasLoadedEnvironments == true && store.selectedProjectId == "bravo" })
		#expect(store.selectedEnvironment == "production")
	}

	@Test("opening a result in another account asks first when unsaved changes would be discarded")
	func openingElsewhereAsksBeforeDiscarding() async throws {
		let fixture = try await fixture([
			(id: "personal", name: "Personal", environments: ["default": ["TOKEN": "shared"]]),
			(id: "team", name: "Team project", environments: ["staging": ["API_TOKEN": "shared"]]),
		], selected: "personal", orgs: ["team": "acme"])
		defer { fixture.close() }
		let store = fixture.store
		store.keyDrafts.edit(try #require(store.selectedProject), key: "TOKEN") { $0.setValue("a new value", in: "default") }
		let search = fixture.search
		search.isPresented = true
		let team = try #require(try await find("shared", in: fixture, scope: .everyAccount).hits.last)

		search.open(team.place)
		#expect(store.selectedAccount == .personal, "Nothing is discarded before the person answers")
		#expect(store.keyDrafts.draft(VaultKeyDraft.ID(projectID: "personal", key: "TOKEN")) != nil)
		let pending = try #require(search.pendingOpen)
		#expect(pending.accountName == "Acme")
		search.cancelPendingOpen()
		#expect(search.pendingOpen == nil)
		#expect(search.isPresented)

		search.open(team.place)
		search.confirmPendingOpen()
		#expect(store.selectedProjectId == "team")
		#expect(store.keyDrafts.draft(VaultKeyDraft.ID(projectID: "personal", key: "TOKEN")) == nil)

		let personal = try #require(search.find?.hits.first)
		search.isPresented = true
		search.open(personal.place)
		#expect(search.pendingOpen == nil, "Nothing unsaved, so nothing to ask")
		#expect(store.selectedProjectId == "personal")
	}

	@Test("a project a search couldn't read opens on its own page, where it can be repaired")
	func openUnreadProject() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "value"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "value"]]),
		], selected: "alpha")
		defer { fixture.close() }
		fixture.keychain.companionRefusals["charlie"] = .damaged("a record is unreadable")
		fixture.search.isPresented = true
		let skip = try #require(try await find("value", in: fixture).skips.first)
		fixture.search.openProject(of: skip)
		#expect(fixture.store.selectedProjectId == "charlie")
		#expect(fixture.search.openRequest?.projectID == "charlie")
		#expect(fixture.search.openRequest?.location == nil, "No key is selected in a project that couldn't be read")
		#expect(!fixture.search.isPresented)
	}

	@Test("a new search replaces the last one's results")
	func newSearchClearsResults() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["SESSION_SECRET": "s3cret"], "production": ["SESSION_SECRET": "s3cret"]]),
		], selected: "alpha")
		defer { fixture.close() }
		_ = try await find("s3cret", in: fixture)
		_ = try await scanForReuse(in: fixture)
		#expect(fixture.search.find == nil)
		_ = try await find("s3cret", in: fixture)
		#expect(fixture.search.reuse == nil)
	}

	@Test("a stopped search keeps what it found, lists what it didn't read, and continues where it stopped")
	func stopAndContinue() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "shared"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "shared"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "shared"]]),
		], selected: "alpha")
		defer { fixture.close() }
		let gate = ValueSearchReadGate()
		fixture.keychain.beforeUnpromptedProjectRead = { gate.hold($0) }
		let search = fixture.search
		search.isPresented = true
		search.term = ExactText("shared")
		search.startFind()
		let running = try #require(search.task)
		#expect(try await waitUntil { gate.held == ["bravo"] })
		search.stop()
		gate.open()
		await running.value
		let stopped = try #require(search.find)
		#expect(stopped.phase == .stopped)
		#expect(places(stopped.hits) == ["Alpha › default › TOKEN"])
		#expect(Array(stopped.unread) == ["bravo", "charlie"])
		#expect(search.canContinue)
		search.term = ExactText("shared, edited")
		#expect(!search.canContinue, "Continuing would search for another value than the field shows")
		#expect(!search.fieldHoldsLastTerm)
		search.term = ExactText("shared")
		#expect(search.canContinue)

		fixture.keychain.beforeUnpromptedProjectRead = nil
		search.continueFind()
		await search.task?.value
		let finished = try #require(search.find)
		#expect(finished.phase == .finished)
		#expect(places(finished.hits) == ["Alpha › default › TOKEN", "Bravo › default › TOKEN", "Charlie › default › TOKEN"])
		#expect(finished.reached == finished.total)
		#expect(finished.unread.isEmpty)
	}

	@Test("continuing reads the projects a search didn't reach in its own order, even after the sidebar's changes")
	func continueAfterReorder() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "shared"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "shared"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "shared"]]),
		], selected: "alpha")
		defer { fixture.close() }
		let gate = ValueSearchReadGate()
		fixture.keychain.beforeUnpromptedProjectRead = { gate.hold($0) }
		let search = fixture.search
		search.isPresented = true
		search.term = ExactText("shared")
		search.startFind()
		let first = try #require(search.task)
		#expect(try await waitUntil { gate.held == ["bravo"] })
		search.stop()
		gate.open()
		await first.value
		#expect(fixture.store.moveProject(id: "charlie", relativeTo: "bravo", placement: .before))

		search.continueFind()
		let second = try #require(search.task)
		#expect(try await waitUntil { gate.held == ["bravo", "bravo"] }, "Bravo is read first, as the search ordered it")
		search.stop()
		gate.open()
		await second.value
		let stopped = try #require(search.find)
		#expect(Array(stopped.unread) == ["bravo", "charlie"], "Neither is counted as read, so both can be continued")
		#expect(search.canContinue)
	}

	@Test("a project read again after the others lists its places where it belongs")
	func retryKeepsOrder() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "shared"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "shared"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "shared"]]),
		], selected: "alpha")
		defer { fixture.close() }
		fixture.keychain.unpromptedReadFailures["bravo"] = .unexpectedStatus(-25300)
		fixture.search.isPresented = true
		let found = try await find("shared", in: fixture)
		let skip = try #require(found.skips.first)
		fixture.keychain.unpromptedReadFailures = [:]
		fixture.search.retry(skip)
		await fixture.search.task?.value
		let retried = try #require(fixture.search.find)
		#expect(retried.phase == .finished)
		#expect(retried.skips.isEmpty)
		#expect(places(retried.hits) == ["Alpha › default › TOKEN", "Bravo › default › TOKEN", "Charlie › default › TOKEN"])
	}

	@Test("reused values are grouped riskiest first, and config that repeats for good reason is left out but counted")
	func reuseGroups() async throws {
		let databaseURL = "postgres://app:p4ssw0rd@db.example.com/app"
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: [
				"default": ["DATABASE_URL": databaseURL, "PORT": "3000", "SESSION_SECRET": "s3cret-session", "DEBUG": "true", "EMPTY": ""],
				"production": [
					"SESSION_SECRET": "s3cret-session", "PORT": "3000", "STRIPE_SIGNING_SECRET": "whsec_shared",
					"STRIPE_WEBHOOK_SECRET": "whsec_shared", "ALSO_EMPTY": "",
				],
			]),
			(id: "bravo", name: "Bravo", environments: ["production": [
				"DB_CONNECTION": databaseURL, "PORT": "3000", "DEBUG": "true", "NEXT_PUBLIC_KEY": "pk_live_same_everywhere_1234",
			]]),
			(id: "charlie", name: "Charlie", environments: ["default": [
				"NEXT_PUBLIC_KEY": "pk_live_same_everywhere_1234", "LONELY_SECRET": "only-here",
			]]),
		], selected: "alpha")
		defer { fixture.close() }
		let reuse = try await scanForReuse(in: fixture)
		#expect(reuse.phase == .finished)
		let reported = reuse.reported.map { group in group.places.map { "\($0.projectName) › \($0.location.environment) › \($0.location.key)" } }
		#expect(reported == [
			["Alpha › default › DATABASE_URL", "Bravo › production › DB_CONNECTION"],
			["Alpha › default › SESSION_SECRET", "Alpha › production › SESSION_SECRET"],
			["Alpha › production › STRIPE_SIGNING_SECRET", "Alpha › production › STRIPE_WEBHOOK_SECRET"],
		])
		#expect(reuse.reported.map(\.span) == [.projects, .environments, .environment])
		let configuration = reuse.configuration.map { $0.places.map(\.location.key) }
		#expect(configuration == [["PORT", "PORT", "PORT"], ["DEBUG", "DEBUG"], ["NEXT_PUBLIC_KEY", "NEXT_PUBLIC_KEY"]])
		#expect(!reuse.groups.contains { $0.places.contains { $0.location.key.contains("EMPTY") } }, "Empty values are never reused values")
	}

	@Test("values Swift calls equal but whose bytes differ aren't the same value")
	func reuseMatchesExactBytes() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["SESSION_SECRET": "caf\u{E9}-s3cret"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["SESSION_SECRET": "cafe\u{301}-s3cret"]]),
		], selected: "alpha")
		defer { fixture.close() }
		let reuse = try await scanForReuse(in: fixture)
		#expect(reuse.groups.isEmpty)
	}

	@Test("only places holding a value stored more than once are judged secret or not, and none after one looks secret")
	func judgesOnlyReusedValues() throws {
		let projectCount = 100
		let targets = (0..<projectCount).map { index in
			ValueSearchTarget(id: "p\(index)", name: "Project \(index)",
				account: ValueSearchAccount(account: .personal, name: "Personal vault"), environments: ["default"])
		}
		var index = ValueReuseIndex()
		for project in 0..<projectCount {
			var values = ["PORT": "3000", "SHARED_TOKEN_VALUE": "Zq8vK2mN9pL4xR7tW1yB6cF3hJ5nD0sA"]
			for key in 0..<50 { values["SETTING_\(key)"] = "p\(project)-k\(key)-Zq8vK2mN9pL4xR7tW1yB6cF3" }
			index.add(VaultProject(id: "p\(project)", name: "Project \(project)", path: "", environments: ["default": values]),
				target: project, of: targets, secrecy: .none)
		}
		let groups = index.groups(of: targets)
		#expect(groups.map(\.isConfiguration).sorted { !$0 && $1 } == [false, true])
		#expect(index.judgedPlaces == 1 + projectCount, "The token's first place, which looks secret, then every place of the port; no value stored once")
	}

	@Test("stopping a retry once its project is read keeps what the read found, and lists the project once")
	func stopAfterRetryRead() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "shared"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "shared"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "shared"]]),
		], selected: "alpha")
		defer { fixture.close() }
		fixture.keychain.unpromptedReadFailures["bravo"] = .unexpectedStatus(-25300)
		let search = fixture.search
		search.isPresented = true
		let skip = try #require(try await find("shared", in: fixture).skips.first)
		fixture.keychain.unpromptedReadFailures = [:]
		search.retry(skip)
		let running = try #require(search.task)
		// Stops in the turn after Bravo's outcome is recorded, before the retry's task ends.
		withObservationTracking { _ = search.find } onChange: {
			DispatchQueue.main.async { MainActor.assumeIsolated { search.stop() } }
		}
		await running.value
		let found = try #require(search.find)
		#expect(found.skips.isEmpty, "Bravo was read")
		#expect(places(found.hits) == ["Alpha › default › TOKEN", "Bravo › default › TOKEN", "Charlie › default › TOKEN"])
		#expect(found.searched == 3)
		#expect(found.phase == .finished)
	}

	@Test("a project deleted after a scan began isn't counted as compared")
	func deletedProjectNotCompared() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "value"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "value"]]),
			(id: "charlie", name: "Charlie", environments: ["default": ["TOKEN": "value"]]),
		], selected: "alpha")
		defer { fixture.close() }
		fixture.keychain.envStorage["charlie"] = nil
		let reuse = try await scanForReuse(in: fixture)
		#expect(reuse.total == 3)
		#expect(reuse.compared == 2)
		#expect(reuse.skips.isEmpty)
		#expect(ValueSearchWording.reuseSubtitle(reuse) == "1 group in 2 projects. Riskiest first.")
	}

	@Test("a search stopped once its last project is read has read them all")
	func stopAfterLastRead() async throws {
		let fixture = try await fixture([
			(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "shared"]]),
			(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "shared"]]),
		], selected: "alpha")
		defer { fixture.close() }
		let search = fixture.search
		search.isPresented = true
		search.term = ExactText("shared")
		search.startFind()
		let running = try #require(search.task)
		Self.stopAfterLastProject(search)
		await running.value
		let found = try #require(search.find)
		#expect(found.phase == .finished)
		#expect(found.unread.isEmpty)
		#expect(found.hits.count == 2)
	}

	/// Stops `search` in the turn after its last project's outcome is
	/// recorded, before its task ends.
	private static func stopAfterLastProject(_ search: ValueSearchModel) {
		withObservationTracking { _ = search.find } onChange: {
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let find = search.find, find.phase == .running else { return }
					if find.reached == find.total { search.stop() } else { stopAfterLastProject(search) }
				}
			}
		}
	}

	@Test("a search's results grow by appending: earlier projects' hits aren't copied or sorted again", .hangLimit)
	func findResultsAppend() {
		let account = ValueSearchAccount(account: .personal, name: "Personal vault")
		let projects = (0..<2_000).map { "p\($0)" }
		var find = ValueSearchModel.Find(scope: .account, accountName: account.name, findsContainingValues: true, order: projects)
		for project in projects {
			find.add((0..<100).map { key in
				ValueSearchHit(place: ValueSearchPlace(location: ValueLocation(projectID: project, environment: "default", key: "KEY_\(key)"),
					projectName: project, account: account, environmentIndex: 0), match: key.isMultiple(of: 4) ? .contains : .exact)
			}, from: project)
		}
		#expect(find.hits.count == 200_000)
		#expect(find.projectCount == 2_000)
		#expect(find.containingCount == 50_000)
		#expect(find.hits.first?.place.location.projectID == "p0" && find.hits.last?.place.location.projectID == "p1999")
	}

	@Test("a scan of many large projects groups in one pass", .hangLimit)
	func reuseScalesLinearly() async throws {
		let projectCount = 400
		let keysPerProject = 250
		let targets = (0..<projectCount).map { index in
			ValueSearchTarget(id: "p\(index)", name: "Project \(index)",
				account: ValueSearchAccount(account: .personal, name: "Personal vault"), environments: ["default"])
		}
		let source = InMemoryValueSearchSource(projects: Dictionary(uniqueKeysWithValues: (0..<projectCount).map { index in
			("p\(index)", VaultProject(id: "p\(index)", name: "Project \(index)", path: "", environments: ["default": Dictionary(
				uniqueKeysWithValues: (0..<keysPerProject).map { key in ("SECRET_\(key)", "value-\(key)-\(index % 2)") })]))
		}))
		let reuse = try #require(await ValueSearchScan.reuse(in: targets, from: source, secrecy: { _ in .none }) { _ in true })
		#expect(reuse.groups.count == keysPerProject * 2)
		#expect(reuse.groups.allSatisfy { $0.places.count == projectCount / 2 && $0.span == .projects })
	}
}

/// Lends values held in memory, as a test of the scan alone needs.
struct InMemoryValueSearchSource: ValueSearchSource {
	let projects: [String: VaultProject]

	func withValues<T>(of projectID: String, _ body: (VaultProject) -> T) async -> Result<T?, KeychainError> {
		.success(projects[projectID].map(body))
	}
}
