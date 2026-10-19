import CryptoKit
import Foundation
import Testing

@testable import LPMVault

/// A Worker as Cloudflare keeps it, answering as the API did in the probe:
/// every secret change makes one version, deployed at once, and is refused
/// while the newest version doesn't serve all traffic.
final class CloudflareWorkerSimulator: CloudflareClientProtocol, @unchecked Sendable {
	static let account = CloudflareFixture.account
	static let workerID = CloudflareFixture.workerID

	private let lock = NSLock()
	private var state: State
	private var log: [String] = []
	/// Runs before a secrets change is applied, as another client's change would land.
	var beforeUpdate: (@Sendable (CloudflareWorkerSimulator) -> Void)?
	/// Answers a secrets change in place of applying it, when set; the
	/// change is still applied first when `appliesBeforeFailing` is set.
	var updateFailure: CloudflareAPIError?
	var appliesBeforeFailing = false
	/// Answers a secrets change as Cloudflare would without making the version, which a successful one always makes.
	var answersWithoutVersion = false
	/// Answers each read of the kind with the next failure, while any are left.
	var readFailures: [String: [CloudflareAPIError]] = [:]
	/// Whether answers carry Cloudflare's `Date`.
	var answersWithDate = true

	struct State {
		var worker: CloudflareWorker
		/// Other Workers by name, as when one takes this Worker's name.
		var others: [String: CloudflareWorker] = [:]
		var versions: [CloudflareVersion]
		var deployment: CloudflareDeployment
		var clock: Date
	}

	init(secrets: Set<String> = [], others: [String: CloudflareBindingKind] = [:]) {
		let start = Date(timeIntervalSince1970: 1_792_297_000)
		var bindings = others
		for name in secrets { bindings[name] = .secretText }
		let first = CloudflareVersion(
			id: UUID().uuidString.lowercased(), number: 7, createdAt: start, source: "wrangler", trigger: "upload", bindings: bindings)
		state = State(
			worker: CloudflareWorker(id: Self.workerID, name: "api"),
			versions: [first],
			deployment: CloudflareDeployment(
				id: UUID().uuidString.lowercased(), createdAt: start, trigger: "upload", versions: [.init(versionID: first.id, percentage: 100)],
				answeredAt: nil),
			clock: start.addingTimeInterval(10))
	}

	var calls: [String] { lock.withLock { log } }
	var newest: CloudflareVersion { lock.withLock { state.versions.last! } }
	var versionCount: Int { lock.withLock { state.versions.count } }

	func edit(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }

	/// Another client's version, made as the given source and trigger, and deployed unless `deployed` is false.
	func addVersion(source: String = "wrangler", trigger: String = "version_upload", secrets: [String]? = nil, deployed: Bool = true) {
		edit { state in
			state.clock.addTimeInterval(5)
			let previous = state.versions.last!
			var bindings = previous.bindings
			if let secrets { for name in secrets { bindings[name] = .secretText } }
			let version = CloudflareVersion(
				id: UUID().uuidString.lowercased(), number: previous.number + 1, createdAt: state.clock, source: source, trigger: trigger,
				bindings: bindings)
			state.versions.append(version)
			if deployed {
				state.deployment = CloudflareDeployment(
					id: UUID().uuidString.lowercased(), createdAt: state.clock, trigger: "deployment",
					versions: [.init(versionID: version.id, percentage: 100)], answeredAt: nil)
			}
		}
	}

	/// Deploys an earlier version, as a rollback does.
	func rollBack() {
		edit { state in
			state.clock.addTimeInterval(5)
			let earlier = state.versions[state.versions.count - 2]
			state.deployment = CloudflareDeployment(
				id: UUID().uuidString.lowercased(), createdAt: state.clock, trigger: "deployment",
				versions: [.init(versionID: earlier.id, percentage: 100)], answeredAt: nil)
		}
	}

	private func record(_ call: String) -> CloudflareAPIError? {
		lock.withLock {
			log.append(call)
			let kind = String(call.prefix { $0 != " " })
			guard var failures = readFailures[kind], !failures.isEmpty else { return nil }
			let failure = failures.removeFirst()
			readFailures[kind] = failures
			return failure
		}
	}

	private var answeredAt: Date? { answersWithDate ? lock.withLock { state.clock } : nil }

	func worker(_ idOrName: String, in account: String) async -> Result<CloudflareWorker, CloudflareAPIError> {
		if let failure = record("worker \(idOrName)") { return .failure(failure) }
		return lock.withLock {
			if let other = state.others[idOrName] { return .success(other) }
			if idOrName == state.worker.id || idOrName == state.worker.name { return .success(state.worker) }
			return .failure(.notFound)
		}
	}

	func newestVersion(ofWorker id: String, in account: String) async -> Result<CloudflareVersion, CloudflareAPIError> {
		if let failure = record("newest \(id)") { return .failure(failure) }
		return .success(newest)
	}

	func activeDeployment(ofScript name: String, in account: String) async -> Result<CloudflareDeployment, CloudflareAPIError> {
		if let failure = record("deployment \(name)") { return .failure(failure) }
		let date = answeredAt
		return lock.withLock {
			guard name == state.worker.name else { return .failure(.notFound) }
			var deployment = state.deployment
			deployment = CloudflareDeployment(
				id: deployment.id, createdAt: deployment.createdAt, trigger: deployment.trigger, versions: deployment.versions, answeredAt: date)
			return .success(deployment)
		}
	}

	func updateSecrets(_ secrets: [String: String], ofScript name: String, in account: String) async
		-> Result<CloudflareSecretsUpdate, CloudflareAPIError>
	{
		_ = record("update \(secrets.keys.sorted().joined(separator: ","))")
		beforeUpdate?(self)
		if let updateFailure, !appliesBeforeFailing { return .failure(updateFailure) }
		let result: Result<CloudflareSecretsUpdate, CloudflareAPIError> = lock.withLock {
			guard name == state.worker.name else { return .failure(.notFound) }
			if answersWithoutVersion {
				let names = Set(state.versions.last!.bindings.lazy.filter { $0.value == .secretText }.map(\.key)).union(secrets.keys)
				return .success(CloudflareSecretsUpdate(names: names, answeredAt: state.clock.addingTimeInterval(0.4)))
			}
			guard state.deployment.soleVersionID == state.versions.last!.id else {
				return .failure(.refused(status: 400, codes: [10_215]))
			}
			state.clock.addTimeInterval(1)
			let previous = state.versions.last!
			var bindings = previous.bindings
			for key in secrets.keys {
				if let kind = bindings[key], kind != .secretText { return .failure(.refused(status: 400, codes: [10_053])) }
				bindings[key] = .secretText
			}
			let version = CloudflareVersion(
				id: UUID().uuidString.lowercased(), number: previous.number + 1, createdAt: state.clock, source: "api", trigger: "secret",
				bindings: bindings)
			state.versions.append(version)
			state.deployment = CloudflareDeployment(
				id: UUID().uuidString.lowercased(), createdAt: state.clock, trigger: "secret",
				versions: [.init(versionID: version.id, percentage: 100)], answeredAt: nil)
			let names = Set(bindings.lazy.filter { $0.value == .secretText }.map(\.key))
			return .success(CloudflareSecretsUpdate(names: names, answeredAt: answersWithDate ? state.clock.addingTimeInterval(0.4) : nil))
		}
		if let updateFailure { return .failure(updateFailure) }
		return result
	}
}

@Suite("Publishing to a Cloudflare Worker")
struct CloudflarePublishingTests {
	private typealias Simulator = CloudflareWorkerSimulator
	private let secret = SymmetricKey(size: .bits256)
	private let destination = vercelDestination()
	private let account = Simulator.account
	private let workerID = Simulator.workerID

	private func review(_ worker: Simulator) async throws -> CloudflareRemoteSnapshot {
		try await CloudflarePublishing.review(workerID: workerID, in: account, using: worker).get()
	}

	private func change(_ key: String, _ value: String, replace: Bool = false) -> PublishPlan.Change {
		PublishPlan.Change(
			key: key, value: value, operation: replace ? .replace(remoteID: "x") : .add, publishesAsSecret: true,
			fingerprint: PublishFingerprint.of(value: value, key: key, destination: destination.id, using: secret))
	}

	// MARK: Review

	@Test("a review takes the Worker's secrets and other bindings from its newest version, tied to the deployment serving it")
	func reviewReadsNewestVersion() async throws {
		let worker = Simulator(secrets: ["API_TOKEN", "DATABASE_URL"], others: ["CLASH_VAR": .plainText, "CONFIG": .json, "CACHE": .other])
		let snapshot = try await review(worker)
		let newest = worker.newest
		#expect(snapshot.worker == CloudflareWorker(id: workerID, name: "api"))
		#expect(snapshot.version == newest && snapshot.hold == nil)
		#expect(snapshot.variables == [
			"API_TOKEN": .init(id: newest.id, updatedAt: newest.createdAt, storedAsSecret: true),
			"DATABASE_URL": .init(id: newest.id, updatedAt: newest.createdAt, storedAsSecret: true),
		])
		#expect(Set(snapshot.keys.keys) == ["CLASH_VAR", "CONFIG", "CACHE"] && snapshot.keys.values.allSatisfy { $0.kind == .otherBinding })
		#expect(snapshot.otherTextBindings == 2, "Plain and JSON variables share the secrets' limit; a KV binding doesn't")
		#expect(worker.calls == ["worker \(workerID)", "newest \(workerID)", "deployment api", "worker \(workerID)", "newest \(workerID)"])
	}

	@Test("a review holds the Worker whose newest version doesn't serve all its traffic, saying which way")
	func reviewHolds() async throws {
		let split = Simulator(secrets: ["A"])
		split.addVersion()
		split.edit { state in
			let ids = state.versions.suffix(2).map(\.id)
			state.deployment = CloudflareDeployment(
				id: UUID().uuidString.lowercased(), createdAt: state.clock, trigger: "deployment",
				versions: [.init(versionID: ids[0], percentage: 50), .init(versionID: ids[1], percentage: 50)], answeredAt: nil)
		}
		#expect(try await review(split).hold == .versionsSplit)

		let rolledBack = Simulator(secrets: ["A"])
		rolledBack.addVersion()
		rolledBack.rollBack()
		#expect(try await review(rolledBack).hold == .earlierVersionLive)

		let uploaded = Simulator(secrets: ["A"])
		uploaded.addVersion(deployed: false)
		#expect(try await review(uploaded).hold == .newestVersionNotLive)
	}

	@Test("a Worker that changes while it's read is read again, and a review gives up after three tries")
	func reviewRetries() async throws {
		let worker = Simulator(secrets: ["A"])
		let once = FlakySimulator(base: worker, changingReads: 1)
		let snapshot = try await CloudflarePublishing.review(workerID: workerID, in: account, using: once).get()
		#expect(snapshot.version == worker.newest)
		#expect(worker.calls.filter { $0 == "deployment api" }.count == 2)
		let always = FlakySimulator(base: Simulator(secrets: ["A"]), changingReads: .max)
		#expect(await CloudflarePublishing.review(workerID: workerID, in: account, using: always) == .failure(.changing))
	}

	// MARK: Publish

	@Test("a publish checks the Worker both ways and its deployment, sends one request, and records the version it made")
	func publishRecordsItsVersion() async throws {
		let worker = Simulator(secrets: ["KEPT", "REPLACED"])
		let reviewed = try await review(worker)
		let report = await CloudflarePublishing.publish(
			[change("REPLACED", "new", replace: true), change("ADDED", "fresh")], to: account, reviewed: reviewed, using: worker)
		let made = worker.newest
		#expect(made.number == reviewed.version.number + 1)
		#expect(report.outcomes == ["REPLACED": .published, "ADDED": .published] && !report.needsReconnect)
		#expect(report.published.map(\.remoteID) == [made.id, made.id])
		#expect(report.published.map(\.remoteUpdatedAt) == [made.createdAt, made.createdAt].map(PublishTimestamp.normalized))
		#expect(report.unconfirmed.isEmpty)
		#expect(report.advances == [
			PublishHistory.Advance(key: "KEPT", from: reviewed.version.createdAt, to: made.createdAt, remoteIDs: [reviewed.version.id: made.id])
		], "A key the publish left alone kept its value in the new version")
		#expect(worker.calls.suffix(8) == [
			"worker \(workerID)", "worker api", "newest \(workerID)", "deployment api", "update ADDED,REPLACED",
			"worker api", "newest \(workerID)", "deployment api",
		])
	}

	@Test("a publish to a Worker with plain and JSON variables records the version it made, read from Cloudflare's own answers")
	func publishBesideOtherTextBindings() async throws {
		let api = CloudflareHTTPWorker()
		let client = CloudflareClient(token: "cf_token", baseURL: api.route.baseURL.appending(path: "client/v4"), session: api.route.session)
		let reviewed = try await CloudflarePublishing.review(workerID: CloudflareFixture.workerID, in: account, using: client).get()
		#expect(reviewed.otherTextBindings == 2)
		let report = await CloudflarePublishing.publish([change("NEW_KEY", "fresh")], to: account, reviewed: reviewed, using: client)
		#expect(report.outcomes == ["NEW_KEY": .published])
		#expect(report.published.map(\.remoteID) == [CloudflareHTTPWorker.madeVersionID])
		#expect(report.advances.map(\.key) == ["API_TOKEN"], "The secret the publish left alone kept its value in the new version")
		#expect(api.patches == 1)
	}

	@Test("a publish over a key known at the reviewed version keeps it known, and one left out stays known too")
	func historyFollowsPublishes() async throws {
		let worker = Simulator()
		var history = PublishHistory()
		let platform = CloudflarePublishing.platform(otherTextBindings: 0)
		func plan(_ values: [String: String], _ snapshot: CloudflareRemoteSnapshot) -> PublishPlan {
			PublishPlan(
				destination: destination, values: values, rules: ProjectEnvSchemaOverview(rules: [], groups: []), check: nil,
				remote: snapshot.variables, remoteKeys: snapshot.keys, platform: platform, history: history, placeHold: snapshot.hold,
				fingerprintKey: secret)
		}
		let date = Date(timeIntervalSince1970: 1_792_300_000)
		var snapshot = try await review(worker)
		var report = await CloudflarePublishing.publish([change("A", "1"), change("B", "2")], to: account, reviewed: snapshot, using: worker)
		history = history.recording(report.published, forgetting: [], at: date).advancing(report.advances)

		snapshot = try await review(worker)
		var planned = plan(["A": "1", "B": "3"], snapshot)
		#expect(try #require(planned.row("A")).holds == [.upToDate])
		#expect(try #require(planned.row("B")).isSelectedByDefault)
		report = await CloudflarePublishing.publish([change("B", "3", replace: true)], to: account, reviewed: snapshot, using: worker)
		history = history.recording(report.published, forgetting: [], at: date.addingTimeInterval(60)).advancing(report.advances)

		snapshot = try await review(worker)
		planned = plan(["A": "1", "B": "3"], snapshot)
		#expect(try #require(planned.row("A")).holds == [.upToDate], "B's publish kept A, and said so")
		#expect(try #require(planned.row("B")).holds == [.upToDate])

		worker.addVersion()
		snapshot = try await review(worker)
		planned = plan(["A": "1", "B": "3"], snapshot)
		#expect(try #require(planned.row("A")).holds == [.unknownSincePublish], "A code deploy can carry secrets too")
		#expect(try #require(planned.row("A")).isPublishable)
	}

	@Test("a change on Cloudflare since the review, a rename, or another Worker taking the name stops the publish before anything is sent")
	func preconditionsStopThePublish() async throws {
		let cases: [(String, (Simulator) -> Void)] = [
			("newer version", { $0.addVersion() }),
			("renamed", { $0.edit { state in state.worker = CloudflareWorker(id: state.worker.id, name: "api-renamed") } }),
			("renamed, and the name taken", { worker in
				worker.edit { state in
					state.worker = CloudflareWorker(id: state.worker.id, name: "api-old")
					state.others["api"] = CloudflareWorker(id: "0123456789abcdef0123456789abcdef", name: "api")
				}
			}),
			("name answering for another Worker", { worker in
				worker.edit { state in state.others["api"] = CloudflareWorker(id: "0123456789abcdef0123456789abcdef", name: "api") }
			}),
			("rolled back", { worker in
				worker.addVersion()
				worker.rollBack()
			}),
		]
		for (name, change) in cases {
			let worker = Simulator(secrets: ["A"])
			let reviewed = try await review(worker)
			change(worker)
			let report = await CloudflarePublishing.publish([self.change("A", "2", replace: true)], to: account, reviewed: reviewed, using: worker)
			#expect(!worker.calls.contains { $0.hasPrefix("update") }, "\(name): nothing is sent")
			guard case .failed? = report.outcomes["A"] else {
				Issue.record("\(name): \(String(describing: report.outcomes["A"]))")
				continue
			}
			#expect(report.published.isEmpty && report.unconfirmed.isEmpty)
		}
	}

	@Test("a held Worker, or more than Cloudflare changes at once, is refused before anything is read")
	func refusesHeldAndOversizedPublishes() async throws {
		let held = Simulator(secrets: ["A"])
		held.addVersion(deployed: false)
		let reviewed = try await review(held)
		let calls = held.calls.count
		let report = await CloudflarePublishing.publish([change("A", "1")], to: account, reviewed: reviewed, using: held)
		#expect(report.outcomes["A"] == .failed(CloudflarePublishing.holdMessage(.newestVersionNotLive)))
		#expect(held.calls.count == calls)

		let worker = Simulator()
		let fresh = try await review(worker)
		let many = (0...CloudflarePublishing.maximumChanges).map { change("KEY_\($0)", "v") }
		let tooMany = await CloudflarePublishing.publish(many, to: account, reviewed: fresh, using: worker)
		#expect(tooMany.outcomes.count == many.count && tooMany.outcomes.values.allSatisfy { if case .failed = $0 { true } else { false } })
		#expect(!worker.calls.contains { $0.hasPrefix("update") })
	}

	@Test("the version a publish made is recorded only when reading back shows it beyond doubt", arguments: Attribution.allCases)
	func attribution(_ doubt: Attribution) async throws {
		let worker = Simulator(secrets: ["A"])
		let reviewed = try await review(worker)
		let client: any CloudflareClientProtocol
		switch doubt {
		case .anotherVersionFirst:
			worker.beforeUpdate = { $0.addVersion(source: "api", trigger: "secret") }
			client = worker
		case .anotherVersionAfter:
			client = AfterSimulator(base: worker, afterUpdate: { $0.addVersion(source: "dash", trigger: "version_upload") })
		case .noDate:
			worker.answersWithDate = false
			client = worker
		case .identityUnread:
			client = AfterSimulator(base: worker, failsIdentityAfterUpdate: true)
		case .laterLookalike:
			worker.answersWithoutVersion = true
			client = AfterSimulator(base: worker, afterUpdate: { $0.addVersion(source: "api", trigger: "secret", secrets: ["A"]) })
		}
		let report = await CloudflarePublishing.publish([change("A", "2", replace: true)], to: account, reviewed: reviewed, using: client)
		#expect(report.outcomes["A"] == .published, "\(doubt)")
		#expect(report.published.map(\.remoteID) == [nil], "\(doubt): recorded with no version, so the next review can't take it for known")
		#expect(report.advances.isEmpty)
	}

	enum Attribution: CaseIterable, Sendable {
		/// Another client's secret change lands between the check and the request.
		case anotherVersionFirst
		/// Another client's version lands before the read-back.
		case anotherVersionAfter
		/// Cloudflare's answers carry no Date to date the version by.
		case noDate
		/// The Worker's name can't be read back after the request.
		case identityUnread
		/// The answer came without its version, and another client's matching version was made a while after it.
		case laterLookalike
	}

	@Test("another Worker taking the name between the check and the request is reported, and nothing is recorded as this Worker's")
	func nameTakenDuringRequest() async throws {
		let worker = Simulator(secrets: ["A"])
		let reviewed = try await review(worker)
		let client = AfterSimulator(base: worker, takesNameAfterUpdate: true)
		let report = await CloudflarePublishing.publish([change("A", "2", replace: true)], to: account, reviewed: reviewed, using: client)
		guard case .failed(let message)? = report.outcomes["A"] else {
			Issue.record("\(String(describing: report.outcomes["A"]))")
			return
		}
		#expect(message.contains("another Worker now has this Worker's name"))
		#expect(report.published.isEmpty && report.advances.isEmpty)
	}

	@Test("a request that may have reached Cloudflare without an answer is recorded unconfirmed and never sent again on its own",
		arguments: [CloudflareAPIError.transport, .server(502), .invalidResponse, .cancelled])
	func unansweredRequest(_ error: CloudflareAPIError) async throws {
		let worker = Simulator(secrets: ["A"])
		let reviewed = try await review(worker)
		worker.updateFailure = error
		worker.appliesBeforeFailing = true
		let report = await CloudflarePublishing.publish([change("A", "2", replace: true), change("B", "3")], to: account, reviewed: reviewed, using: worker)
		#expect(report.outcomes.values.allSatisfy { if case .unconfirmed = $0 { true } else { false } })
		#expect(report.published.isEmpty)
		#expect(report.unconfirmed.map(\.key).sorted() == ["A", "B"])
		#expect(report.unconfirmed.allSatisfy { $0.remoteID == PublishPlan.unconfirmedRemoteID })
		#expect(worker.calls.filter { $0.hasPrefix("update") }.count == 1)
	}

	@Test("refusals change nothing and say why; a refused token asks to connect again; a connection never made sent nothing")
	func refusals() async throws {
		let expectations: [(CloudflareAPIError, String, Bool)] = [
			(.refused(status: 400, codes: [10_215]), "newest version serves all its traffic", false),
			(.refused(status: 400, codes: [10_053]), "another variable or binding", false),
			(.refused(status: 400, codes: [10_055]), "more secrets and variables than its plan allows", false),
			(.refused(status: 400, codes: [10_100]), "error 10100", false),
			(.unauthorized, "Connect Cloudflare again", true),
			(.forbidden, "can't change this Worker", false),
			(.unreachable, "nothing was sent", false),
		]
		for (error, text, reconnect) in expectations {
			let worker = Simulator(secrets: ["A"])
			let reviewed = try await review(worker)
			worker.updateFailure = error
			let report = await CloudflarePublishing.publish([change("A", "2", replace: true)], to: account, reviewed: reviewed, using: worker)
			guard case .failed(let message)? = report.outcomes["A"] else {
				Issue.record("\(error): \(String(describing: report.outcomes["A"]))")
				continue
			}
			#expect(message.contains(text), "\(error): \(message)")
			#expect(report.needsReconnect == reconnect)
			#expect(report.published.isEmpty && report.unconfirmed.isEmpty)
		}
	}

	@Test("a rate limit is waited out and the Worker checked again before sending; one that lasts too long gives up")
	func rateLimits() async throws {
		final class Sleeps: @unchecked Sendable {
			let lock = NSLock()
			var slept: [Duration] = []
		}
		let now = Date(timeIntervalSince1970: 1_792_300_000)
		let sleeps = Sleeps()
		let pacing = CloudflarePublishing.Pacing(date: { now }, sleep: { duration in sleeps.lock.withLock { sleeps.slept.append(duration) } })

		let worker = Simulator(secrets: ["A"])
		let reviewed = try await review(worker)
		worker.readFailures = ["deployment": [.rateLimited(until: now.addingTimeInterval(3))]]
		let client = AfterSimulator(base: worker, limitsFirstUpdate: now.addingTimeInterval(4))
		let report = await CloudflarePublishing.publish([change("A", "2", replace: true)], to: account, reviewed: reviewed, using: client, pacing: pacing)
		#expect(report.outcomes["A"] == .published)
		#expect(sleeps.lock.withLock { sleeps.slept } == [.seconds(3), .seconds(4)])
		#expect(worker.calls.filter { $0 == "deployment api" }.count == 5, "the review, the limited check, the check before each request, and the read-back")
		#expect(worker.calls.filter { $0.hasPrefix("update") }.count == 1, "A request refused for its rate limit wasn't applied, so it's sent once more")

		let longer = Simulator(secrets: ["A"])
		let again = try await review(longer)
		longer.updateFailure = .rateLimited(until: now.addingTimeInterval(600))
		let refused = await CloudflarePublishing.publish([change("A", "2", replace: true)], to: account, reviewed: again, using: longer, pacing: pacing)
		guard case .failed(let message)? = refused.outcomes["A"] else {
			Issue.record("\(String(describing: refused.outcomes["A"]))")
			return
		}
		#expect(message.contains("limiting requests"))
	}

	@Test("Cloudflare's platform: every key a secret, its name and value limits, its combined limit and one request's limit")
	func platform() {
		let platform = CloudflarePublishing.platform(otherTextBindings: 3)
		#expect(platform.freshness == .revision && platform.readableKeys == [])
		#expect(platform.maximumKeyBytes == 2_712 && platform.maximumValueBytes == 5_120)
		#expect(platform.combinedCapacity == .init(limit: 128, occupied: 3) && platform.maximumChanges == 100)
		#expect(platform.isReserved("CF_PAGES") == false)
	}
}

/// A Worker that gets a new version while its first `changingReads` reviews read its deployment.
private final class FlakySimulator: CloudflareClientProtocol, @unchecked Sendable {
	let base: CloudflareWorkerSimulator
	let changingReads: Int
	private let lock = NSLock()
	private var deploymentReads = 0

	init(base: CloudflareWorkerSimulator, changingReads: Int) {
		self.base = base
		self.changingReads = changingReads
	}

	func worker(_ idOrName: String, in account: String) async -> Result<CloudflareWorker, CloudflareAPIError> {
		await base.worker(idOrName, in: account)
	}

	func newestVersion(ofWorker id: String, in account: String) async -> Result<CloudflareVersion, CloudflareAPIError> {
		await base.newestVersion(ofWorker: id, in: account)
	}

	func activeDeployment(ofScript name: String, in account: String) async -> Result<CloudflareDeployment, CloudflareAPIError> {
		let result = await base.activeDeployment(ofScript: name, in: account)
		let reads = lock.withLock {
			deploymentReads += 1
			return deploymentReads
		}
		if reads <= changingReads { base.addVersion() }
		return result
	}

	func updateSecrets(_ secrets: [String: String], ofScript name: String, in account: String) async
		-> Result<CloudflareSecretsUpdate, CloudflareAPIError>
	{
		await base.updateSecrets(secrets, ofScript: name, in: account)
	}
}

/// A Worker that changes once a secrets request is answered, or refuses
/// the first one for a rate limit.
private final class AfterSimulator: CloudflareClientProtocol, @unchecked Sendable {
	let base: CloudflareWorkerSimulator
	let afterUpdate: @Sendable (CloudflareWorkerSimulator) -> Void
	let failsIdentityAfterUpdate: Bool
	let takesNameAfterUpdate: Bool
	/// When set, the first request is refused for a rate limit lifting then.
	let limitsFirstUpdate: Date?
	private let lock = NSLock()
	private var updated = false
	private var limited = false

	init(
		base: CloudflareWorkerSimulator,
		failsIdentityAfterUpdate: Bool = false,
		takesNameAfterUpdate: Bool = false,
		limitsFirstUpdate: Date? = nil,
		afterUpdate: @escaping @Sendable (CloudflareWorkerSimulator) -> Void = { _ in }
	) {
		self.base = base
		self.afterUpdate = afterUpdate
		self.failsIdentityAfterUpdate = failsIdentityAfterUpdate
		self.takesNameAfterUpdate = takesNameAfterUpdate
		self.limitsFirstUpdate = limitsFirstUpdate
	}

	func worker(_ idOrName: String, in account: String) async -> Result<CloudflareWorker, CloudflareAPIError> {
		let after = lock.withLock { updated }
		if after, failsIdentityAfterUpdate { return .failure(.transport) }
		if after, takesNameAfterUpdate, idOrName == "api" {
			return .success(CloudflareWorker(id: "0123456789abcdef0123456789abcdef", name: "api"))
		}
		return await base.worker(idOrName, in: account)
	}

	func newestVersion(ofWorker id: String, in account: String) async -> Result<CloudflareVersion, CloudflareAPIError> {
		await base.newestVersion(ofWorker: id, in: account)
	}

	func activeDeployment(ofScript name: String, in account: String) async -> Result<CloudflareDeployment, CloudflareAPIError> {
		await base.activeDeployment(ofScript: name, in: account)
	}

	func updateSecrets(_ secrets: [String: String], ofScript name: String, in account: String) async
		-> Result<CloudflareSecretsUpdate, CloudflareAPIError>
	{
		if let limitsFirstUpdate {
			let first = lock.withLock {
				defer { limited = true }
				return !limited
			}
			if first { return .failure(.rateLimited(until: limitsFirstUpdate)) }
		}
		let result = await base.updateSecrets(secrets, ofScript: name, in: account)
		lock.withLock { updated = true }
		afterUpdate(base)
		return result
	}
}

/// A Worker with a secret beside a plain and a JSON variable, answering over
/// HTTP as Cloudflare does: a secrets change makes the next version, deployed
/// at once, and its answer lists the Worker's plain and JSON variables too.
private final class CloudflareHTTPWorker: Sendable {
	static let madeVersionID = "5f0e3c1a-7b2d-4e8f-9a6b-1c2d3e4f5a6b"
	private static let madeDeploymentID = "0b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e"

	private final class Patches: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0
		var value: Int { lock.withLock { count } }
		func add() { lock.withLock { count += 1 } }
	}

	private let patched = Patches()
	let route: PlatformHTTPStub.Route

	var patches: Int { patched.value }

	init() {
		route = PlatformHTTPStub.platform { [patched] request in Self.answer(request, patched: patched) }
	}

	private static func answer(_ request: PlatformHTTPStub.Request, patched: Patches) -> PlatformHTTPStub.Reply {
		typealias Fixture = CloudflareFixture
		let path = request.url.path()
		let workers = "/client/v4/accounts/\(Fixture.account)/workers/workers/"
		let script = "/client/v4/accounts/\(Fixture.account)/workers/scripts/\(Fixture.workerName)/"
		var bindings: [[String: Any]] = [
			["name": "API_TOKEN", "type": "secret_text"], ["name": "CLASH_VAR", "type": "plain_text", "text": "plain"],
			["name": "JSON_VAR", "type": "json", "json": ["a": 1]],
		]
		func reply(_ result: Any) -> PlatformHTTPStub.Reply {
			.json(200, Fixture.envelope(result), headers: ["Date": patched.value == 0 ? "Sun, 18 Oct 2026 04:20:00 GMT" : "Sun, 18 Oct 2026 04:20:01 GMT"])
		}
		switch (request.method, path) {
		case ("GET", workers + Fixture.workerID), ("GET", workers + Fixture.workerName):
			return reply(Fixture.worker())
		case ("GET", workers + Fixture.workerID + "/versions"):
			guard patched.value > 0 else { return reply([Fixture.version(bindings: bindings)]) }
			bindings.append(["name": "NEW_KEY", "type": "secret_text"])
			return reply([Fixture.version(id: madeVersionID, number: 26, createdOn: "2026-10-18T04:20:00.612345Z", bindings: bindings)])
		case ("GET", script + "deployments"):
			guard patched.value > 0 else { return reply(["deployments": [Fixture.deployment()]]) }
			return reply(["deployments": [
				Fixture.deployment(id: madeDeploymentID, createdOn: "2026-10-18T04:20:00.698765Z", versions: [(madeVersionID, 100)]),
				Fixture.deployment(),
			]])
		case ("PATCH", script + "secrets-bulk"):
			patched.add()
			return reply([
				"API_TOKEN": ["name": "API_TOKEN", "type": "secret_text"], "NEW_KEY": ["name": "NEW_KEY", "type": "secret_text"],
				"CLASH_VAR": ["name": "CLASH_VAR", "type": "plain_text"], "JSON_VAR": ["name": "JSON_VAR", "type": "json"],
			])
		default:
			return .json(404, Fixture.refusal([7003]))
		}
	}
}
