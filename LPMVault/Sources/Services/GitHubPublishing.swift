import Foundation

/// A GitHub scope's secrets and variables as a review sees them.
struct GitHubRemoteSnapshot: Equatable, Sendable {
	/// Each name's secret or variable, by key. Its ID names which it is.
	let variables: [String: PublishPlan.RemoteVariable]
	/// Names with both a secret and a variable.
	let keys: [String: PublishPlan.RemoteKey]
}

enum GitHubSnapshotError: Error, Equatable, Sendable {
	/// GitHub listed a secret, or a variable, more than once.
	case duplicateNames([String])

	var message: String {
		switch self {
		case .duplicateNames(let names):
			"GitHub listed \(names.lazy.map(\.escapingDirectionControls).joined(separator: ", ")) more than once. Review again."
		}
	}
}

/// Publishing to GitHub Actions: what it accepts, what its secrets and
/// variables mean for a review, and sending the reviewed changes.
///
/// A scope, a repository or one of its deployment environments, keeps
/// secrets, whose values are sealed and never shown again, and readable
/// variables, apart: a workflow reads `secrets.NAME` or `vars.NAME`. A key
/// is written where GitHub already keeps it, so a workflow reading it keeps
/// working; a new key is a secret unless the rules ask for a CI variable, as
/// the LPM CLI publishes it.
enum GitHubPublishing {
	/// Names GitHub keeps for itself.
	static let reservedPrefixes = ["GITHUB_"]
	/// GitHub's limit on a secret's or a variable's value.
	static let maximumValueBytes = 48 * 1024
	/// How many announced rate limits one write with its reads waits out
	/// before giving up.
	static let rateLimitRetries = 3
	/// How many limits GitHub doesn't say the end of one write waits out: a
	/// minute, then twice that, as GitHub asks while a limit continues.
	static let unannouncedLimitWaits = 2
	/// How many times one write starts over for a token renewed meanwhile.
	static let renewalRetries = 3
	/// What GitHub keeps in a repository's own secrets and variables, and in an environment's.
	static let repositoryCapacity = PublishPlan.Capacity(secrets: 100, variables: 500)
	static let environmentCapacity = PublishPlan.Capacity(secrets: 100, variables: 100)

	/// How a publish leaves time between writes, and waits.
	struct Pacing: Sendable {
		/// The least time GitHub asks to leave between two writes of a batch.
		static let writeInterval: Duration = .seconds(1)

		var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
		/// The wall clock, which GitHub's announced resets are on.
		var date: @Sendable () -> Date = { Date() }
		var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
	}

	/// What GitHub accepts at `scope`, with the keys the rules keep in readable variables.
	static func platform(readableKeys: Set<String>, scope: GitHubPublishTarget.Scope) -> PublishPlan.Platform {
		PublishPlan.Platform(
			reservedPrefixes: reservedPrefixes,
			acceptsKey: isAcceptedKey,
			maximumValueBytes: maximumValueBytes,
			readableKeys: readableKeys,
			protectionFollowsVariable: true,
			capacity: scope == .repository ? repositoryCapacity : environmentCapacity)
	}

	/// A name as GitHub keeps it: capital letters, digits and underscores,
	/// not starting with a digit. GitHub compares names ignoring case and
	/// stores them in capitals, so a key in other letters would be renamed.
	@Sendable static func isAcceptedKey(_ key: String) -> Bool {
		guard let first = key.utf8.first, !(first >= 0x30 && first <= 0x39), key.utf8.count <= 1_024 else { return false }
		return key.utf8.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
	}

	/// A name GitHub lists: letters, digits and underscores, read as it is and
	/// compared exactly.
	static func isRemoteName(_ name: String) -> Bool {
		!name.isEmpty && name.utf8.count <= 1_024
			&& name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
	}

	/// The remote ID a review and a history record give a secret or a
	/// variable. The record is kept by name, so the ID says only which it
	/// is: one moved between the two reads as replaced.
	static func remoteID(isSecret: Bool) -> String {
		isSecret ? "secret" : "variable"
	}

	// MARK: - Review

	/// The scope's secrets and variables, by name. A name with both is held,
	/// since a workflow could read either.
	static func snapshot(
		secrets: [GitHubValueRecord],
		variables: [GitHubValueRecord]
	) -> Result<GitHubRemoteSnapshot, GitHubSnapshotError> {
		var secretTimes: [String: Date] = [:]
		var variableTimes: [String: Date] = [:]
		var duplicates: Set<String> = []
		for secret in secrets where secretTimes.updateValue(secret.updatedAt, forKey: secret.name) != nil {
			duplicates.insert(secret.name)
		}
		for variable in variables where variableTimes.updateValue(variable.updatedAt, forKey: variable.name) != nil {
			duplicates.insert(variable.name)
		}
		guard duplicates.isEmpty else { return .failure(.duplicateNames(duplicates.sorted())) }
		var applying: [String: PublishPlan.RemoteVariable] = [:]
		var keys: [String: PublishPlan.RemoteKey] = [:]
		applying.reserveCapacity(secretTimes.count + variableTimes.count)
		for (name, updatedAt) in secretTimes {
			if let variableTime = variableTimes[name] {
				keys[name] = PublishPlan.RemoteKey(kind: .duplicated, storedAsSecret: true, updatedAt: max(updatedAt, variableTime))
			} else {
				applying[name] = PublishPlan.RemoteVariable(id: remoteID(isSecret: true), updatedAt: updatedAt, storedAsSecret: true)
			}
		}
		for (name, updatedAt) in variableTimes where secretTimes[name] == nil {
			applying[name] = PublishPlan.RemoteVariable(id: remoteID(isSecret: false), updatedAt: updatedAt, storedAsSecret: false)
		}
		return .success(GitHubRemoteSnapshot(variables: applying, keys: keys))
	}

	// MARK: - Publish

	/// Sends `changes` to the reviewed target. Each key gets an outcome.
	///
	/// Writes go one at a time, a second apart, as GitHub asks of a batch of
	/// writes. After that pause, the key is read from the scope's secrets and
	/// variables and must be as the review saw it, and right before the write
	/// the repository and the environment are checked to still be the
	/// reviewed ones, by ID under the reviewed names. A rename or a replacement
	/// since the review stops what hasn't been sent; a key added, changed,
	/// removed or moved between secrets and variables isn't sent. A rate
	/// limit waited out, or a token renewed meanwhile, starts those checks
	/// over. Each write is read back once for the time GitHub
	/// gave it; a read-back that can't answer at once leaves the time
	/// unknown, rather than take someone's later change for this one. A
	/// refused token, missing access, or a rate limit that doesn't lift stops
	/// what hasn't been sent.
	static func publish(
		_ changes: [PublishPlan.Change],
		to target: GitHubPublishTarget,
		reviewed: GitHubRemoteSnapshot,
		using client: any GitHubClientProtocol,
		seal: @Sendable (String, Data) -> Data? = SealedBox.seal,
		pacing: Pacing = Pacing()
	) async -> PublishReport {
		var report = PublishReport()
		func finish(_ reason: (PublishPlan.Change) -> PublishOutcome = { _ in .notSent }) -> PublishReport {
			for change in changes where report.outcomes[change.key] == nil { report.outcomes[change.key] = reason(change) }
			return report
		}
		var publicKey: GitHubPublicKey?
		var lastWrite: ContinuousClock.Instant?
		// Waits for a limit met by a read-back, which the next key's waits go on from.
		var carriedWaits = 0
		for (index, change) in changes.enumerated() {
			guard !Task.isCancelled else { break }
			var waits = carriedWaits
			carriedWaits = 0
			var renewals = 0
			let answer: Answer
			attempts: while true {
				switch await attempt(
					change, to: target, reviewed: reviewed, publicKey: &publicKey, using: client, seal: seal, waits: &waits,
					renewals: &renewals, pacing: pacing, lastWrite: &lastWrite)
				{
				case .done(let value):
					answer = value
					break attempts
				case .waited:
					continue
				case .replaced(let reason):
					return finish { _ in .failed(reason) }
				}
			}
			switch answer {
			case .written(let write, let readBack):
				report.published.append(change.published(remoteID: remoteID(isSecret: write.isSecret), remoteUpdatedAt: readBack.record?.updatedAt))
				report.outcomes[change.key] = readBack == .gone
					? .failed("GitHub accepted it, but it was gone when LPM Vault read it back. Check it on GitHub.")
					: .published
				switch readBack {
				case .unknown(.rateLimited(let reset)?):
					// GitHub asks for no request until a limit lifts, so the next key, when there is one, waits for it.
					guard index < changes.index(before: changes.endIndex) else { break }
					if let error = await waitOut(until: reset, waits: &carriedWaits, pacing: pacing) {
						return finish { _ in .failed(message(error, now: pacing.date())) }
					}
				case .unknown(let error?):
					report.needsReconnect = report.needsReconnect || needsReconnect(error)
					return finish { _ in .failed(message(error, now: pacing.date())) }
				case .record, .gone, .unknown(nil):
					break
				}
			case .refused(let reason):
				report.outcomes[change.key] = .failed(reason)
			case .failed(let error):
				report.outcomes[change.key] = .failed(message(error, now: pacing.date()))
				report.needsReconnect = report.needsReconnect || needsReconnect(error)
				if stops(error) { return finish() }
			}
		}
		return finish()
	}

	/// A change cleared to send: which of the scope's records it writes, and whether it creates it.
	private struct Write: Sendable {
		let change: PublishPlan.Change
		let isSecret: Bool
		let creates: Bool
	}

	/// What reading a write back found.
	private enum ReadBack: Equatable, Sendable {
		case record(GitHubValueRecord)
		/// Something removed it right after the write.
		case gone
		/// It couldn't be read at once, so its time isn't known; with the
		/// refusal or limit that stops or holds up the publish, when it was one.
		case unknown(GitHubAPIError?)

		var record: GitHubValueRecord? {
			if case .record(let record) = self { return record }
			return nil
		}
	}

	private enum Answer: Sendable {
		case written(Write, ReadBack)
		case refused(String)
		case failed(GitHubAPIError)
	}

	/// One try at sending a change.
	private enum Attempt: Sendable {
		case done(Answer)
		/// A rate limit was waited out, or the token renewed, before anything
		/// was written, so the change is tried again with every check.
		case waited
		/// The repository or environment isn't the reviewed one any more, with why.
		case replaced(String)
	}

	private enum ScopeFailure: Error, Equatable {
		case api(GitHubAPIError)
		case replaced(String)
	}

	private enum RereadFailure: Error, Equatable {
		case api(GitHubAPIError)
		/// The key isn't as the review saw it, with why.
		case refused(String)
	}

	/// Sends one change, once the pause since the last write is over and,
	/// right after it, the scope is still the reviewed one and the key as the
	/// review saw it; then reads it back.
	private static func attempt(
		_ change: PublishPlan.Change,
		to target: GitHubPublishTarget,
		reviewed: GitHubRemoteSnapshot,
		publicKey: inout GitHubPublicKey?,
		using client: any GitHubClientProtocol,
		seal: @Sendable (String, Data) -> Data?,
		waits: inout Int,
		renewals: inout Int,
		pacing: Pacing,
		lastWrite: inout ContinuousClock.Instant?
	) async -> Attempt {
		if let lastWrite {
			let since = pacing.now() - lastWrite
			if since < Pacing.writeInterval {
				do { try await pacing.sleep(Pacing.writeInterval - since) } catch { return .done(.failed(.cancelled)) }
			}
		}
		let scope = GitHubScope(repository: target.repositoryName, environment: target.scope.environmentName)
		let write: Write
		switch await reread(change, in: scope, reviewed: reviewed, using: client) {
		case .success(let value): write = value
		case .failure(.refused(let reason)):
			// A key that reads as removed, changed or moved can be its whole scope replaced, as an
			// environment's deletion takes its secrets and variables with it: that's the reason to give.
			switch await reviewedScope(of: target, using: client) {
			case .success: return .done(.refused(reason))
			case .failure(.replaced(let replaced)): return .replaced(replaced)
			case .failure(.api(let error)): return await pause(after: error, waits: &waits, renewals: &renewals, pacing: pacing)
			}
		case .failure(.api(let error)) where error == .moved || error == .notFound:
			switch await reviewedScope(of: target, using: client) {
			case .success: return await pause(after: error, waits: &waits, renewals: &renewals, pacing: pacing)
			case .failure(.replaced(let replaced)): return .replaced(replaced)
			case .failure(.api(let checkError)): return await pause(after: checkError, waits: &waits, renewals: &renewals, pacing: pacing)
			}
		case .failure(.api(let error)):
			return await pause(after: error, waits: &waits, renewals: &renewals, pacing: pacing)
		}
		if write.isSecret, publicKey == nil {
			switch await client.publicKey(of: scope) {
			case .success(let key): publicKey = key
			case .failure(let error): return await pause(after: error, waits: &waits, renewals: &renewals, pacing: pacing)
			}
		}
		// Checked last, so only the write itself follows the check. A secret is
		// also sealed to the key of the scope checked first, which GitHub refuses
		// for any scope that replaced it.
		switch await reviewedScope(of: target, using: client) {
		case .success: break
		case .failure(.replaced(let reason)): return .replaced(reason)
		case .failure(.api(let error)): return await pause(after: error, waits: &waits, renewals: &renewals, pacing: pacing)
		}
		let answer: Result<Void, GitHubAPIError>
		if write.isSecret {
			guard let publicKey, let ciphertext = seal(change.value, publicKey.key) else {
				return .done(.refused("The value couldn't be sealed for GitHub."))
			}
			answer = await client.setSecret(change.key, to: GitHubSealedSecret(ciphertext: ciphertext, keyID: publicKey.id), in: scope)
		} else if write.creates {
			answer = await client.createVariable(change.key, value: change.value, in: scope)
		} else {
			answer = await client.updateVariable(change.key, value: change.value, in: scope)
		}
		lastWrite = pacing.now()
		switch answer {
		case .success:
			return .done(.written(write, await readBack(write, in: scope, using: client)))
		case .failure(.rejected(status: 409)) where write.creates && !write.isSecret:
			// GitHub answers a variable created meanwhile with a conflict.
			return .done(.refused(Refusal.added.text))
		case .failure(let error):
			return await pause(after: error, waits: &waits, renewals: &renewals, pacing: pacing)
		}
	}

	/// `.waited` once a request GitHub held up can be sent again: after its
	/// rate limit lifts, or at once when it wasn't applied for a renewed
	/// token, as `.renewed` says. Any other error, or a wait that can't be
	/// made, is the answer.
	private static func pause(after error: GitHubAPIError, waits: inout Int, renewals: inout Int, pacing: Pacing) async -> Attempt {
		switch error {
		case .rateLimited(let reset):
			if let error = await waitOut(until: reset, waits: &waits, pacing: pacing) { return .done(.failed(error)) }
			return .waited
		case .renewed:
			// Counted apart from rate limits: a renewal says nothing of GitHub's limits.
			guard renewals < renewalRetries else { return .done(.failed(.renewed)) }
			renewals += 1
			return .waited
		default:
			return .done(.failed(error))
		}
	}

	/// The reviewed scope, by the names GitHub's paths use, once the
	/// repository with the reviewed ID still has the reviewed name, and so
	/// does the environment with the reviewed ID.
	private static func reviewedScope(of target: GitHubPublishTarget, using client: any GitHubClientProtocol) async -> Result<GitHubScope, ScopeFailure> {
		let repository: GitHubRepository
		switch await client.repository(id: target.repositoryID) {
		case .success(let value): repository = value
		case .failure(.notFound): return .failure(.replaced("\(target.repositoryName) isn't reachable on GitHub any more. Review again."))
		case .failure(let error): return .failure(.api(error))
		}
		guard repository.fullName == target.repositoryName else {
			return .failure(.replaced("\(target.repositoryName) was renamed \(repository.fullName) on GitHub since this review. Review again."))
		}
		guard case .environment(let id, let name) = target.scope else {
			return .success(GitHubScope(repository: repository.fullName, environment: nil))
		}
		switch await client.environment(named: name, of: repository.fullName) {
		case .success(let environment?) where environment.id == id && environment.name == name:
			return .success(GitHubScope(repository: repository.fullName, environment: name))
		case .success:
			return .failure(.replaced(
				"The environment \(GitHubPublishTarget.Scope.shownName(id: id, name: name)) was renamed, removed or replaced on GitHub since this review. Review again."))
		case .failure(let error): return .failure(.api(error))
		}
	}

	/// Reads a write back, once and at once: a time read after a wait or a
	/// renewal could be someone else's change.
	private static func readBack(_ write: Write, in scope: GitHubScope, using client: any GitHubClientProtocol) async -> ReadBack {
		let key = write.change.key
		let answer = write.isSecret ? await client.secret(key, in: scope) : await client.variable(key, in: scope)
		switch answer {
		case .success(let record?): return .record(record)
		case .success(nil): return .gone
		case .failure(let error): return .unknown(stops(error) ? error : nil)
		}
	}

	/// The change, cleared to send, when the scope's secret and variable for
	/// its key are as the review saw them.
	private static func reread(
		_ change: PublishPlan.Change,
		in scope: GitHubScope,
		reviewed: GitHubRemoteSnapshot,
		using client: any GitHubClientProtocol
	) async -> Result<Write, RereadFailure> {
		let key = change.key
		let secret: GitHubValueRecord?
		switch await client.secret(key, in: scope) {
		case .success(let value): secret = value
		case .failure(let error): return .failure(.api(error))
		}
		let variable: GitHubValueRecord?
		switch await client.variable(key, in: scope) {
		case .success(let value): variable = value
		case .failure(let error): return .failure(.api(error))
		}
		let current: GitHubRemoteSnapshot
		switch snapshot(secrets: secret.map { [$0] } ?? [], variables: variable.map { [$0] } ?? []) {
		case .success(let value): current = value
		case .failure(let error): return .failure(.refused(error.message))
		}
		return write(for: change, reviewed: reviewed, current: current).mapError { .refused($0.text) }
	}

	private struct Refusal: Error {
		let text: String

		static let added = Refusal(text: "Added on GitHub since this review. Review again.")
		static let changed = Refusal(text: "Changed on GitHub since this review. Review again.")
		static let removed = Refusal(text: "Removed on GitHub since this review. Review again.")
		static let duplicated = Refusal(text: "GitHub has both a secret and a variable with this name now. Remove one on GitHub, then review again.")
	}

	/// How the change can be sent, as GitHub has the key now, or why it can't
	/// be: the key must be as the review saw it. A replacement needs the same
	/// secret or variable with the same time, stored the way the change asks;
	/// an addition needs the name still free.
	private static func write(
		for change: PublishPlan.Change,
		reviewed: GitHubRemoteSnapshot,
		current: GitHubRemoteSnapshot
	) -> Result<Write, Refusal> {
		let key = change.key
		guard current.keys[key] == nil else { return .failure(.duplicated) }
		switch change.operation {
		case .replace(let id):
			guard let now = current.variables[key] else { return .failure(.removed) }
			guard let seen = reviewed.variables[key], now.id == id, seen.id == id, let time = now.updatedAt, time == seen.updatedAt,
				now.storedAsSecret == change.publishesAsSecret
			else { return .failure(.changed) }
			return .success(Write(change: change, isSecret: change.publishesAsSecret, creates: false))
		case .add:
			guard current.variables[key] == nil else { return .failure(.added) }
			return .success(Write(change: change, isSecret: change.publishesAsSecret, creates: true))
		}
	}

	/// Waits until a rate limit lifts, a moment past its announced reset,
	/// counting the wait in `waits`. A limit GitHub doesn't say the end of is
	/// waited out a minute, then twice that. Returns the error to answer with
	/// instead: the limit when no more waits are allowed or it lifts after the
	/// longest wait, or a cancellation.
	private static func waitOut(until reset: Date?, waits: inout Int, pacing: Pacing) async -> GitHubAPIError? {
		let wait: Duration
		var lifts: Date?
		if reset != nil {
			guard waits < rateLimitRetries, let limit = GitHubHTTP.rateLimitWait(until: reset, now: pacing.date()) else {
				return .rateLimited(until: reset)
			}
			(wait, lifts) = limit
		} else {
			guard waits < unannouncedLimitWaits else { return .rateLimited(until: nil) }
			wait = GitHubHTTP.unannouncedLimitWait(after: waits)
		}
		waits += 1
		do {
			try await PlatformRateLimit.waitOut(wait, until: lifts, atMost: GitHubHTTP.longestRateLimitWait, date: pacing.date, sleep: pacing.sleep)
		} catch {
			return .cancelled
		}
		return nil
	}

	/// Refusals that every later request would meet too.
	private static func stops(_ error: GitHubAPIError) -> Bool {
		switch error {
		case .unauthorized, .forbidden, .rateLimited, .cancelled, .credentials, .moved, .ssoRequired, .tooLarge: true
		case .notFound, .rejected, .transport, .timedOut, .invalidResponse, .server, .renewed: false
		}
	}

	/// Refusals that mean connecting GitHub again.
	private static func needsReconnect(_ error: GitHubAPIError) -> Bool {
		switch error {
		case .unauthorized, .credentials(.expired): true
		default: false
		}
	}

	/// Why the chosen keys don't fit in the scope: GitHub keeps only so many
	/// secrets, and readable variables, in a repository and in an environment.
	static func overflowMessage(_ overflow: PublishPlan.Overflow, scope: GitHubPublishTarget.Scope) -> String {
		let kind = overflow.isSecrets ? "secrets" : "variables"
		let place = scope == .repository ? "a repository's own" : "an environment's"
		let one = String(kind.dropLast())
		guard overflow.existing < overflow.limit else {
			let new = overflow.adding == 1 ? "the new \(one)" : "the \(overflow.adding) new \(kind)"
			return "GitHub keeps at most \(overflow.limit) of \(place) \(kind), and has \(overflow.existing) already. Leave out \(new), or remove some on GitHub."
		}
		return "GitHub keeps at most \(overflow.limit) of \(place) \(kind), and this would make \(overflow.existing + overflow.adding). Leave out \(overflow.excess) new \(overflow.excess == 1 ? one : kind)."
	}

	/// Why the person can't change the scope's secrets and variables, as the
	/// repository's role and archived state say; nil when nothing says they can't.
	static func accessRefusal(_ repository: GitHubRepository, for scope: GitHubPublishTarget.Scope) -> String? {
		guard !repository.canChange(scope) else { return nil }
		if repository.isArchived { return "\(repository.fullName) is archived on GitHub, so its secrets and variables can't change." }
		switch scope {
		case .repository: return "Your role on \(repository.fullName) can't change its secrets and variables. That needs write access."
		case .environment: return "Changing an environment's secrets and variables needs admin access to \(repository.fullName)."
		}
	}

	static func message(_ error: GitHubAPIError, now: Date = Date()) -> String {
		switch error {
		case .unauthorized: "GitHub no longer accepts this connection. Connect GitHub again on the Platforms page."
		case .forbidden:
			"GitHub refused access. Changing a repository's secrets and variables needs write access to it, and an environment's needs admin access, with LPM Vault's GitHub App installed on the repository."
		case .notFound:
			"GitHub couldn't find the repository, the environment, or the secret or variable. LPM Vault's GitHub App may not be installed on the repository."
		case .rateLimited(let reset?) where reset.timeIntervalSince(now) > 90:
			"GitHub is limiting requests until \(reset.formatted(date: .omitted, time: .shortened)). Try again then."
		case .rateLimited(nil): "GitHub is limiting requests. Try again in a few minutes."
		case .rateLimited: "GitHub is limiting requests. Try again in a minute."
		case .rejected(let status): "GitHub refused it (HTTP \(status))."
		case .transport: "GitHub couldn't be reached."
		case .cancelled: "Cancelled."
		case .invalidResponse: "GitHub's answer couldn't be read."
		case .server(let status): "GitHub answered with HTTP \(status)."
		case .credentials(let error): error.message(for: .github)
		case .moved: "The repository was renamed or moved on GitHub. Review again."
		case .renewed:
			"The GitHub connection was renewed again and again while this was sent. Try again, and if it keeps happening, connect GitHub again on the Platforms page."
		case .ssoRequired:
			"An organization's single sign-on keeps LPM Vault out. Sign in to the organization on GitHub, then connect GitHub again on the Platforms page."
		case .tooLarge(.repositories):
			"GitHub listed more repositories than LPM Vault reads at once. Install LPM Vault's GitHub App only on the repositories it publishes to."
		case .tooLarge(.environments): "GitHub listed more environments for the repository than LPM Vault reads at once."
		case .tooLarge(.secrets): "GitHub listed more secrets than LPM Vault reads at once."
		case .tooLarge(.variables): "GitHub listed more variables than LPM Vault reads at once."
		case .timedOut(.repositories):
			"GitHub took too long to list the repositories. Try again. If it keeps taking too long, install LPM Vault's GitHub App only on the repositories it publishes to."
		case .timedOut(let listing): "GitHub took too long to list \(listed(listing)). Try again."
		}
	}

	private static func listed(_ listing: GitHubAPIError.Listing) -> String {
		switch listing {
		case .repositories: "the repositories"
		case .environments: "the repository's environments"
		case .secrets: "the secrets"
		case .variables: "the variables"
		}
	}
}
