import Foundation

/// A Worker's secrets as a review sees them, with the version and
/// deployment it saw them in.
struct CloudflareRemoteSnapshot: Equatable, Sendable {
	let worker: CloudflareWorker
	/// The Worker's newest version, whose bindings the review read.
	let version: CloudflareVersion
	/// The deployment serving the Worker's traffic when the review read it.
	let deployment: CloudflareDeployment
	/// The Worker's secrets, each carrying the newest version's ID.
	let variables: [String: PublishPlan.RemoteVariable]
	/// The Worker's other bindings, whose names a secret can't take.
	let keys: [String: PublishPlan.RemoteKey]
	/// Why nothing can be published now; nil when keys can be.
	let hold: PublishPlan.PlaceHold?
	/// The Worker's plain and JSON variables, which share the secrets' limit.
	let otherTextBindings: Int
}

enum CloudflareReviewError: Error, Equatable, Sendable {
	case api(CloudflareAPIError)
	/// The Worker changed while it was read, more often than a review tries again.
	case changing

	var message: String {
		switch self {
		case .api(let error): CloudflarePublishing.message(error)
		case .changing: "The Worker changed on Cloudflare while LPM Vault read it. Try again in a moment."
		}
	}
}

/// Publishing to a Cloudflare Worker's secrets: what Cloudflare accepts,
/// what a Worker's versions mean for a review, and sending the reviewed
/// changes.
///
/// Cloudflare keeps no time or digest per secret. Every change to a
/// Worker, its code, settings or secrets, makes a new version, which the
/// next takes its secrets from. So a key is known unchanged only while the
/// version this Mac's publish made is the newest: a code deploy can carry
/// secrets as well, indistinguishably. A publish sends every key in one
/// request, which Cloudflare applies as one version deployed at once, and
/// refuses while the newest version doesn't serve all traffic.
enum CloudflarePublishing {
	/// The longest name Cloudflare accepts, in UTF-8 bytes.
	static let maximumKeyBytes = 2_712
	/// The largest value Cloudflare accepts, in UTF-8 bytes.
	static let maximumValueBytes = 5_120
	/// The most text bindings, secrets and plain and JSON variables together,
	/// a Worker on the Paid plan keeps; the Free plan keeps 64.
	static let bindingLimit = 128
	/// The most secrets one request changes, which Cloudflare applies at once.
	static let maximumChanges = 100
	/// How many times a review reads a Worker that changes while it's read.
	static let reviewAttempts = 3
	/// How many rate limits one publish waits out before giving up.
	static let rateLimitRetries = 3
	/// How many renewals of the connection's token one publish checks the Worker again after.
	static let maximumRenewals = 2
	/// The longest a rate limit can last for a publish to wait for it.
	static let maximumRateLimitWait: Duration = .seconds(65)
	/// How far apart Cloudflare's clock and a version's time may be when
	/// telling whether a publish made it.
	static let clockSlack: TimeInterval = 1
	/// The trigger and source a version made by this Mac's publish has.
	static let secretTrigger = "secret"
	static let apiSource = "api"

	/// How a publish waits out rate limits.
	struct Pacing: Sendable {
		var date: @Sendable () -> Date = { Date() }
		var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
	}

	/// What Cloudflare accepts at a Worker that has `otherTextBindings` plain
	/// and JSON variables beside its secrets. Every key is a secret: plain
	/// variables set outside the Worker's own configuration are replaced by
	/// its next `wrangler deploy`.
	static func platform(otherTextBindings: Int) -> PublishPlan.Platform {
		PublishPlan.Platform(
			freshness: .revision,
			maximumKeyBytes: maximumKeyBytes,
			maximumValueBytes: maximumValueBytes,
			readableKeys: [],
			combinedCapacity: .init(limit: bindingLimit, occupied: otherTextBindings),
			maximumChanges: maximumChanges)
	}

	// MARK: - Review

	/// The review's view of a Worker: its newest version and the deployment
	/// serving it, read by the Worker's ID. The secrets and other bindings
	/// come from that version itself, and the deployment, read by the
	/// Worker's name, is tied to it by the version's ID. The Worker's name and
	/// newest version are read again last, and the whole read starts over
	/// when either moved meanwhile.
	static func review(workerID: String, in account: String, using client: any CloudflareClientProtocol) async
		-> Result<CloudflareRemoteSnapshot, CloudflareReviewError>
	{
		for _ in 0..<reviewAttempts {
			guard !Task.isCancelled else { return .failure(.api(.cancelled)) }
			let worker: CloudflareWorker
			let version: CloudflareVersion
			let deployment: CloudflareDeployment
			switch await client.worker(workerID, in: account) {
			case .success(let value) where value.id == workerID: worker = value
			case .success: return .failure(.api(.invalidResponse))
			case .failure(let error): return .failure(.api(error))
			}
			switch await client.newestVersion(ofWorker: workerID, in: account) {
			case .success(let value): version = value
			case .failure(let error): return .failure(.api(error))
			}
			switch await client.activeDeployment(ofScript: worker.name, in: account) {
			case .success(let value): deployment = value
			case .failure(let error): return .failure(.api(error))
			}
			let again: CloudflareWorker
			switch await client.worker(workerID, in: account) {
			case .success(let value): again = value
			case .failure(let error): return .failure(.api(error))
			}
			let newest: CloudflareVersion
			switch await client.newestVersion(ofWorker: workerID, in: account) {
			case .success(let value): newest = value
			case .failure(let error): return .failure(.api(error))
			}
			guard again == worker, newest.id == version.id else { continue }
			return .success(snapshot(worker: worker, version: version, deployment: deployment))
		}
		return .failure(.changing)
	}

	/// What a review makes of a Worker's newest version and the deployment serving it.
	static func snapshot(worker: CloudflareWorker, version: CloudflareVersion, deployment: CloudflareDeployment) -> CloudflareRemoteSnapshot {
		var variables: [String: PublishPlan.RemoteVariable] = [:]
		var keys: [String: PublishPlan.RemoteKey] = [:]
		var otherText = 0
		for (name, kind) in version.bindings {
			switch kind {
			case .secretText:
				variables[name] = PublishPlan.RemoteVariable(id: version.id, updatedAt: version.createdAt, storedAsSecret: true)
			case .plainText, .json, .other:
				if kind.isText { otherText += 1 }
				keys[name] = PublishPlan.RemoteKey(kind: .otherBinding, storedAsSecret: false, updatedAt: nil)
			}
		}
		return CloudflareRemoteSnapshot(
			worker: worker, version: version, deployment: deployment, variables: variables, keys: keys,
			hold: hold(newest: version, deployment: deployment), otherTextBindings: otherText)
	}

	/// Why the Worker's secrets can't change now: its newest version
	/// doesn't serve all its traffic. A deployment made after the newest
	/// version serves an earlier one, as after a rollback; one made before
	/// it predates an upload that wasn't deployed.
	static func hold(newest: CloudflareVersion, deployment: CloudflareDeployment) -> PublishPlan.PlaceHold? {
		if deployment.soleVersionID == newest.id { return nil }
		if deployment.versions.count > 1 { return .versionsSplit }
		return deployment.createdAt > newest.createdAt ? .earlierVersionLive : .newestVersionNotLive
	}

	// MARK: - Publish

	/// Sends `changes` to the reviewed Worker as one request. Each key gets an outcome.
	///
	/// Right before sending, the Worker's ID must still name the reviewed
	/// script, that name must still be the Worker's, and its newest version
	/// and deployment must be the reviewed ones; otherwise nothing is sent.
	/// Cloudflare offers no conditional write, so a change in the moment
	/// between that check and the request can't be caught, though Cloudflare
	/// itself refuses while the newest version doesn't serve all traffic.
	///
	/// Once Cloudflare accepts, the Worker is read again. The new version is
	/// recorded as this publish's only when it's the reviewed one's
	/// successor, made by a secret change through the API, holding exactly
	/// the secrets Cloudflare answered with, serving all traffic, and dated
	/// within the request; otherwise the keys are recorded with no version, so
	/// the next review can't take them for known. A request that may have
	/// reached Cloudflare without an answer leaves its keys recorded as
	/// unconfirmed, and is never sent again on its own.
	static func publish(
		_ changes: [PublishPlan.Change],
		to account: String,
		reviewed: CloudflareRemoteSnapshot,
		using client: any CloudflareClientProtocol,
		pacing: Pacing = Pacing()
	) async -> PublishReport {
		var report = PublishReport()
		func finish(_ outcome: PublishOutcome) -> PublishReport {
			for change in changes where report.outcomes[change.key] == nil { report.outcomes[change.key] = outcome }
			return report
		}
		guard !changes.isEmpty else { return report }
		if let hold = reviewed.hold { return finish(.failed(holdMessage(hold))) }
		guard changes.count <= maximumChanges else {
			return finish(.failed("Cloudflare changes at most \(maximumChanges) secrets at once. Choose fewer, then publish again."))
		}
		var waits = 0
		var renewals = 0
		while true {
			guard !Task.isCancelled else { return finish(.notSent) }
			let checkedAt: Date?
			switch await precondition(reviewed, in: account, using: client) {
			case .success(let answeredAt): checkedAt = answeredAt
			case .failure(.api(.rateLimited(let until))):
				guard await wait(until: until, waits: &waits, pacing: pacing) else { return finish(.failed(message(.rateLimited(until: until)))) }
				continue
			case .failure(.api(.renewed)):
				// The token was renewed during the check: the Worker is checked again with the new one.
				renewals += 1
				guard renewals <= maximumRenewals else { return finish(.failed(message(.renewed))) }
				continue
			case .failure(.api(let error)) where needsReconnect(error):
				report.needsReconnect = true
				return finish(.failed(message(error)))
			case .failure(let error):
				return finish(.failed(error.message))
			}
			guard !Task.isCancelled else { return finish(.notSent) }
			let secrets = Dictionary(changes.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
			switch await client.updateSecrets(secrets, ofScript: reviewed.worker.name, in: account) {
			case .success(let update):
				return await accepted(update, of: changes, checkedAt: checkedAt, reviewed: reviewed, in: account, using: client, report: report)
			case .failure(.rateLimited(let until)):
				guard await wait(until: until, waits: &waits, pacing: pacing) else { return finish(.failed(message(.rateLimited(until: until)))) }
				continue
			case .failure(.renewed):
				// Not sent: the token changed since the check, which is made again with the new one.
				renewals += 1
				guard renewals <= maximumRenewals else { return finish(.failed(message(.renewed))) }
				continue
			case .failure(let error) where needsReconnect(error):
				report.needsReconnect = true
				return finish(.failed(message(error)))
			case .failure(.transport), .failure(.cancelled), .failure(.server), .failure(.invalidResponse):
				report.unconfirmed = changes.map { $0.published(remoteID: PublishPlan.unconfirmedRemoteID, remoteUpdatedAt: nil) }
				return finish(.unconfirmed("No answer came back from Cloudflare, so it may or may not have the new value. Review again."))
			case .failure(let error):
				return finish(.failed(message(error)))
			}
		}
	}

	private enum PreconditionError: Error, Equatable {
		case api(CloudflareAPIError)
		case changed(String)

		var message: String {
			switch self {
			case .api(let error): CloudflarePublishing.message(error)
			case .changed(let reason): reason
			}
		}
	}

	/// Checks the Worker is as reviewed, both ways between its ID and name;
	/// when Cloudflare last answered, on its own clock.
	private static func precondition(
		_ reviewed: CloudflareRemoteSnapshot,
		in account: String,
		using client: any CloudflareClientProtocol
	) async -> Result<Date?, PreconditionError> {
		let changed = PreconditionError.changed("The Worker changed on Cloudflare since this review. Review again.")
		switch await client.worker(reviewed.worker.id, in: account) {
		case .success(let worker) where worker == reviewed.worker: break
		case .success: return .failure(.changed("The Worker was renamed on Cloudflare since this review. Review again."))
		case .failure(let error): return .failure(.api(error))
		}
		switch await client.worker(reviewed.worker.name, in: account) {
		case .success(let worker) where worker.id == reviewed.worker.id: break
		case .success: return .failure(.changed("Another Worker has taken this Worker's name on Cloudflare. Review again."))
		case .failure(let error): return .failure(.api(error))
		}
		switch await client.newestVersion(ofWorker: reviewed.worker.id, in: account) {
		case .success(let version) where version.id == reviewed.version.id: break
		case .success: return .failure(changed)
		case .failure(let error): return .failure(.api(error))
		}
		switch await client.activeDeployment(ofScript: reviewed.worker.name, in: account) {
		case .success(let deployment) where deployment.soleVersionID == reviewed.version.id: return .success(deployment.answeredAt)
		case .success: return .failure(changed)
		case .failure(let error): return .failure(.api(error))
		}
	}

	/// The report for a request Cloudflare accepted, after reading back
	/// which Worker and version it changed.
	private static func accepted(
		_ update: CloudflareSecretsUpdate,
		of changes: [PublishPlan.Change],
		checkedAt: Date?,
		reviewed: CloudflareRemoteSnapshot,
		in account: String,
		using client: any CloudflareClientProtocol,
		report: PublishReport
	) async -> PublishReport {
		var report = report
		// The name may have moved to another Worker between the check and the
		// request. A version is recorded only once the name is known to be this Worker's.
		let version: CloudflareVersion?
		switch await client.worker(reviewed.worker.name, in: account) {
		case .success(let worker) where worker.id != reviewed.worker.id:
			for change in changes {
				report.outcomes[change.key] = .failed(
					"Cloudflare took it, but another Worker now has this Worker's name, so the secrets may have reached that one. Check both on Cloudflare.")
			}
			return report
		case .success:
			version = await madeVersion(update, checkedAt: checkedAt, reviewed: reviewed, in: account, using: client)
		case .failure:
			version = nil
		}
		for change in changes {
			guard update.names.contains(change.key) else {
				report.unconfirmed.append(change.published(remoteID: PublishPlan.unconfirmedRemoteID, remoteUpdatedAt: nil))
				report.outcomes[change.key] = .unconfirmed("Cloudflare answered without listing it, so it may or may not have the new value. Review again.")
				continue
			}
			report.published.append(change.published(remoteID: version?.id, remoteUpdatedAt: version?.createdAt))
			report.outcomes[change.key] = .published
		}
		if let version {
			let written = Set(changes.lazy.map(\.key))
			for key in reviewed.variables.keys where !written.contains(key) && update.names.contains(key) {
				report.advances.append(PublishHistory.Advance(
					key: key, from: reviewed.version.createdAt, to: version.createdAt, remoteIDs: [reviewed.version.id: version.id]))
			}
		}
		return report
	}

	/// The version a publish made, when reading the Worker back shows it
	/// beyond doubt: the reviewed version's successor, made by a secret change
	/// through the API, holding exactly the secrets Cloudflare answered with,
	/// serving all traffic, and dated between the check before the request
	/// and the answer to it. Nil otherwise.
	private static func madeVersion(
		_ update: CloudflareSecretsUpdate,
		checkedAt: Date?,
		reviewed: CloudflareRemoteSnapshot,
		in account: String,
		using client: any CloudflareClientProtocol
	) async -> CloudflareVersion? {
		guard let checkedAt, let answeredAt = update.answeredAt,
			case .success(let version) = await client.newestVersion(ofWorker: reviewed.worker.id, in: account),
			version.number == reviewed.version.number + 1, version.source == apiSource, version.trigger == secretTrigger,
			Set(version.bindings.lazy.filter { $0.value == .secretText }.map(\.key)) == update.names,
			version.createdAt >= checkedAt.addingTimeInterval(-clockSlack), version.createdAt <= answeredAt.addingTimeInterval(clockSlack),
			case .success(let deployment) = await client.activeDeployment(ofScript: reviewed.worker.name, in: account),
			deployment.soleVersionID == version.id
		else { return nil }
		return version
	}

	/// Whether a failure means the connection must be connected again: Cloudflare
	/// refused its token, or the token can't be renewed or used any more.
	private static func needsReconnect(_ error: CloudflareAPIError) -> Bool {
		switch error {
		case .unauthorized, .credentials(.expired), .credentials(.retired), .credentials(.store(.retired)): true
		default: false
		}
	}

	/// Waits out a rate limit that lifts soon enough; false when it doesn't,
	/// or the publish has waited out enough already.
	private static func wait(until: Date?, waits: inout Int, pacing: Pacing) async -> Bool {
		guard waits < rateLimitRetries, let wait = PlatformRateLimit.wait(until: until, maximum: maximumRateLimitWait, now: pacing.date()) else {
			return false
		}
		waits += 1
		do {
			try await pacing.sleep(wait)
		} catch {
			return false
		}
		return !Task.isCancelled
	}

	// MARK: - Messages

	/// Why more secrets than one publish changes can't be chosen.
	static let changeLimitMessage =
		"Cloudflare can change at most \(maximumChanges) secrets in one step. Publishing fewer leaves the rest as they are, so your Worker runs with a mix until they're published too."

	/// Why the chosen new secrets don't fit the Worker's limit on text bindings.
	static func capacityMessage(_ overflow: PublishPlan.Overflow) -> String {
		"The Worker can hold \(overflow.limit) secrets and variables together, and these would make \(overflow.existing + overflow.adding). Choose \(overflow.excess) fewer new \(overflow.excess == 1 ? "one" : "ones")."
	}

	static func holdMessage(_ hold: PublishPlan.PlaceHold) -> String {
		let state = switch hold {
		case .earlierVersionLive: "An earlier version of the Worker is serving its traffic, as after a rollback."
		case .versionsSplit: "The Worker's traffic is split between two versions."
		case .newestVersionNotLive: "A newer version of the Worker was uploaded but isn't deployed."
		}
		return "\(state) Cloudflare changes secrets only when the newest version serves all traffic. Sort it out on Cloudflare, then review again."
	}

	static func message(_ error: CloudflareAPIError) -> String {
		switch error {
		case .unauthorized:
			return "Cloudflare no longer accepts this connection, as when LPM Vault was removed under Connected Applications on Cloudflare. Connect Cloudflare again on the Platforms page."
		case .forbidden: return "This Cloudflare connection can't change this Worker, as when your role on the account doesn't allow it."
		case .notFound: return "The Worker isn't on Cloudflare any more."
		case .rateLimited(let until?) where until.timeIntervalSinceNow > 90:
			return "Cloudflare is limiting requests until \(until.formatted(date: .omitted, time: .shortened)). Try again then."
		case .rateLimited: return "Cloudflare is limiting requests. Wait a minute, then try again."
		case .refused(_, let codes) where codes.contains(where: CloudflareAPIError.newestVersionNotDeployedCodes.contains):
			return "Cloudflare changes secrets only when the Worker's newest version serves all its traffic. Sort it out on Cloudflare, then review again."
		case .refused(_, let codes) where codes.contains(CloudflareAPIError.nameTakenCode):
			return "The Worker uses one of these names for another variable or binding. Review again."
		case .refused(_, let codes) where codes.contains(CloudflareAPIError.tooManyBindingsCode):
			return "The Worker would have more secrets and variables than its plan allows. Choose fewer new ones, then publish again."
		case .refused(let status, let codes):
			return "Cloudflare refused the change (\(codes.first.map { "error \($0)" } ?? "HTTP \(status)"))."
		case .unreachable: return "Cloudflare couldn't be reached, so nothing was sent. Check your network and try again."
		case .transport: return "The connection to Cloudflare failed. Check your network and try again."
		case .cancelled: return "Cancelled."
		case .invalidResponse: return "Cloudflare returned an answer LPM Vault couldn't read."
		case .server(let status): return "Cloudflare had a problem (HTTP \(status)). Try again in a moment."
		case .moved: return "Cloudflare redirected the request, which LPM Vault doesn't follow."
		case .credentials(let error): return error.message(for: .cloudflare)
		case .renewed: return "The Cloudflare connection was renewed more than once while publishing. Review again."
		}
	}
}
