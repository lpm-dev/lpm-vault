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
	/// How many rate limits the listing, or one write with its reads, waits
	/// out before giving up.
	static let rateLimitRetries = 3

	/// What GitHub accepts, with the keys the rules keep in readable variables.
	static func platform(readableKeys: Set<String>) -> PublishPlan.Platform {
		PublishPlan.Platform(
			reservedPrefixes: reservedPrefixes,
			acceptsKey: isAcceptedKey,
			maximumValueBytes: maximumValueBytes,
			readableKeys: readableKeys,
			protectionFollowsVariable: true)
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
	/// The repository, and the environment, are first checked to still be the
	/// reviewed ones, by ID under the reviewed names, and again after every
	/// rate limit waited out, so a rename or a replacement since the review
	/// stops what hasn't been sent. Each key is then
	/// checked to be as the review saw it: by listing the scope once, when
	/// that takes fewer requests than reading each chosen key, and otherwise,
	/// as for every key written after a rate limit was waited out, by reading
	/// the key's secret and variable right before it's written. A key added,
	/// changed, removed or moved between secrets and variables since the
	/// review isn't sent. Writes go one at a time, as GitHub asks. Each is
	/// read back once for the time GitHub gave it; a read-back that can't
	/// answer at once leaves the time unknown, rather than take someone's
	/// later change for this one. A refused token, missing access, or a rate
	/// limit that doesn't lift stops what hasn't been sent.
	static func publish(
		_ changes: [PublishPlan.Change],
		to target: GitHubPublishTarget,
		reviewed: GitHubRemoteSnapshot,
		using client: any GitHubClientProtocol,
		seal: @Sendable (String, Data) -> Data? = SealedBox.seal
	) async -> PublishReport {
		var report = PublishReport()
		func finish(_ reason: (PublishPlan.Change) -> PublishOutcome = { _ in .notSent }) -> PublishReport {
			for change in changes where report.outcomes[change.key] == nil { report.outcomes[change.key] = reason(change) }
			return report
		}
		func fail(_ error: GitHubAPIError) -> PublishReport {
			report.needsReconnect = report.needsReconnect || needsReconnect(error)
			return finish { _ in .failed(message(error)) }
		}
		guard !Task.isCancelled else { return finish() }

		var waits = 0
		var scope: GitHubScope
		switch await reviewedScope(of: target, using: client, waits: &waits) {
		case .success(let value): scope = value
		case .failure(.api(let error)): return fail(error)
		case .failure(.replaced(let reason)): return finish { _ in .failed(reason) }
		}

		var current: GitHubRemoteSnapshot?
		if listingRequests(for: reviewed) < 2 * changes.count {
			switch await listing(scope, using: client) {
			case .success(let snapshot): current = snapshot
			case .failure(.api(.rateLimited(let reset))):
				// Listing again would read every page again; each key is read right before its write instead.
				if let error = await waitOut(until: reset, waits: &waits) { return fail(error) }
				switch await reviewedScope(of: target, using: client, waits: &waits) {
				case .success(let value): scope = value
				case .failure(.api(let error)): return fail(error)
				case .failure(.replaced(let reason)): return finish { _ in .failed(reason) }
				}
			case .failure(.api(let error)): return fail(error)
			case .failure(.snapshot(let error)): return finish { _ in .failed(error.message) }
			}
		}
		var cleared: [String: Write] = [:]
		if let current {
			for change in changes {
				switch write(for: change, reviewed: reviewed, current: current) {
				case .success(let write): cleared[change.key] = write
				case .failure(let refusal): report.outcomes[change.key] = .failed(refusal.text)
				}
			}
		}

		// Whether the listing still describes GitHub: no rate limit was waited out since it was read.
		var fresh = current != nil
		var publicKey: GitHubPublicKey?
		for change in changes where report.outcomes[change.key] == nil {
			guard !Task.isCancelled else { break }
			var waits = 0
			var write = fresh ? cleared[change.key] : nil
			var answer: Answer
			attempts: while true {
				switch await send(change, cleared: write, to: scope, reviewed: reviewed, publicKey: &publicKey, using: client, seal: seal, waits: &waits) {
				case .done(let value):
					answer = value
					break attempts
				case .waited:
					// GitHub may have changed anything while the limit was waited out.
					fresh = false
					write = nil
					switch await reviewedScope(of: target, using: client, waits: &waits) {
					case .success(let value): scope = value
					case .failure(.api(let error)):
						answer = .failed(error)
						break attempts
					case .failure(.replaced(let reason)): return finish { _ in .failed(reason) }
					}
				}
			}
			switch answer {
			case .written(let write, let readBack):
				report.published.append(change.published(remoteID: remoteID(isSecret: write.isSecret), remoteUpdatedAt: readBack.record?.updatedAt))
				report.outcomes[change.key] = readBack == .gone
					? .failed("GitHub accepted it, but it was gone when LPM Vault read it back. Check it on GitHub.")
					: .published
				if case .unknown(let error?) = readBack {
					report.needsReconnect = report.needsReconnect || needsReconnect(error)
					return finish()
				}
			case .refused(let reason):
				report.outcomes[change.key] = .failed(reason)
			case .failed(let error):
				report.outcomes[change.key] = .failed(message(error))
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
		/// refusal that stops the publish, when it was one.
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
		/// A rate limit was waited out before anything was written, so the change is tried again.
		case waited
	}

	private enum ListingFailure: Error, Equatable {
		case api(GitHubAPIError)
		case snapshot(GitHubSnapshotError)
	}

	private enum ScopeFailure: Error, Equatable {
		case api(GitHubAPIError)
		/// The repository or environment isn't the reviewed one any more, with why.
		case replaced(String)
	}

	/// The reviewed scope, by the names GitHub's paths use, once the
	/// repository with the reviewed ID still has the reviewed name, and so
	/// does the environment with the reviewed ID.
	/// A rate limit met on the way starts the check over once it lifts.
	private static func reviewedScope(
		of target: GitHubPublishTarget,
		using client: any GitHubClientProtocol,
		waits: inout Int
	) async -> Result<GitHubScope, ScopeFailure> {
		while true {
			let repository: GitHubRepository
			switch await client.repository(id: target.repositoryID) {
			case .success(let value): repository = value
			case .failure(.notFound):
				return .failure(.replaced("\(target.repositoryName) isn't reachable on GitHub any more. Review again."))
			case .failure(.rateLimited(let reset)):
				if let error = await waitOut(until: reset, waits: &waits) { return .failure(.api(error)) }
				continue
			case .failure(let error): return .failure(.api(error))
			}
			guard repository.fullName == target.repositoryName else {
				return .failure(.replaced("\(target.repositoryName) was renamed \(repository.fullName) on GitHub since this review. Review again."))
			}
			guard case .environment(let id, let name) = target.scope else {
				return .success(GitHubScope(repository: repository.fullName, environment: nil))
			}
			switch await client.environments(of: repository.fullName) {
			case .success(let environments):
				guard environments.contains(where: { $0.id == id && $0.name == name }) else {
					return .failure(.replaced(
						"The environment \(name.escapingDirectionControls) was renamed, removed or replaced on GitHub since this review. Review again."))
				}
				return .success(GitHubScope(repository: repository.fullName, environment: name))
			case .failure(.rateLimited(let reset)):
				// The repository was checked before the wait, so it's checked again.
				if let error = await waitOut(until: reset, waits: &waits) { return .failure(.api(error)) }
			case .failure(let error): return .failure(.api(error))
			}
		}
	}

	/// How many requests listing the scope takes, by how many secrets and
	/// variables the review saw: GitHub lists 100 secrets, or 30 variables, a page.
	private static func listingRequests(for reviewed: GitHubRemoteSnapshot) -> Int {
		let duplicated = reviewed.keys.count
		let secrets = reviewed.variables.values.lazy.filter { $0.storedAsSecret == true }.count
		let variables = reviewed.variables.count - secrets
		return max(1, (secrets + duplicated + 99) / 100) + max(1, (variables + duplicated + 29) / 30)
	}

	/// The scope's secrets and variables, listed once: a rate limit isn't
	/// waited out here, so pages already read aren't read again.
	private static func listing(_ scope: GitHubScope, using client: any GitHubClientProtocol) async -> Result<GitHubRemoteSnapshot, ListingFailure> {
		let secrets: [GitHubValueRecord]
		switch await client.secrets(in: scope) {
		case .success(let value): secrets = value
		case .failure(let error): return .failure(.api(error))
		}
		let variables: [GitHubValueRecord]
		switch await client.variables(in: scope) {
		case .success(let value): variables = value
		case .failure(let error): return .failure(.api(error))
		}
		return snapshot(secrets: secrets, variables: variables).mapError(ListingFailure.snapshot)
	}

	/// Sends one change and reads it back. A change the listing didn't clear
	/// is read again first, from both secrets and variables, and must still be
	/// as the review saw it. A rate limit met before the write is waited out
	/// and answered as `.waited`.
	private static func send(
		_ change: PublishPlan.Change,
		cleared: Write?,
		to scope: GitHubScope,
		reviewed: GitHubRemoteSnapshot,
		publicKey: inout GitHubPublicKey?,
		using client: any GitHubClientProtocol,
		seal: @Sendable (String, Data) -> Data?,
		waits: inout Int
	) async -> Attempt {
		let write: Write
		if let cleared {
			write = cleared
		} else {
			switch await reread(change, in: scope, reviewed: reviewed, using: client, waits: &waits) {
			case .cleared(let value): write = value
			case .attempt(let attempt): return attempt
			}
		}
		if write.isSecret, publicKey == nil {
			switch await client.publicKey(of: scope) {
			case .success(let key): publicKey = key
			case .failure(.rateLimited(let reset)): return await waited(until: reset, waits: &waits)
			case .failure(let error): return .done(.failed(error))
			}
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
		switch answer {
		case .success:
			return .done(.written(write, await readBack(write, in: scope, using: client)))
		case .failure(.rateLimited(let reset)):
			return await waited(until: reset, waits: &waits)
		case .failure(.rejected(status: 409)) where write.creates && !write.isSecret:
			// GitHub answers a variable created meanwhile with a conflict.
			return .done(.refused(Refusal.added.text))
		case .failure(let error):
			return .done(.failed(error))
		}
	}

	/// `.waited` once the rate limit lifts, or the error that ends the wait instead.
	private static func waited(until reset: Date?, waits: inout Int) async -> Attempt {
		if let error = await waitOut(until: reset, waits: &waits) { return .done(.failed(error)) }
		return .waited
	}

	/// Reads a write back, once and at once. A rate limit isn't waited out:
	/// a time read after a wait could be someone else's change.
	private static func readBack(_ write: Write, in scope: GitHubScope, using client: any GitHubClientProtocol) async -> ReadBack {
		let key = write.change.key
		let answer = write.isSecret ? await client.secret(key, in: scope) : await client.variable(key, in: scope)
		switch answer {
		case .success(let record?): return .record(record)
		case .success(nil): return .gone
		case .failure(let error): return .unknown(stops(error) && !isRateLimit(error) ? error : nil)
		}
	}

	private enum Reread {
		case cleared(Write)
		case attempt(Attempt)
	}

	/// Reads the change's key from the scope's secrets and variables, and
	/// clears the change when the key is still as the review saw it. A rate
	/// limit on either read is waited out and answered as `.waited`, so both
	/// are read again after it.
	private static func reread(
		_ change: PublishPlan.Change,
		in scope: GitHubScope,
		reviewed: GitHubRemoteSnapshot,
		using client: any GitHubClientProtocol,
		waits: inout Int
	) async -> Reread {
		let key = change.key
		let secret: GitHubValueRecord?
		switch await client.secret(key, in: scope) {
		case .success(let value): secret = value
		case .failure(.rateLimited(let reset)): return .attempt(await waited(until: reset, waits: &waits))
		case .failure(let error): return .attempt(.done(.failed(error)))
		}
		let variable: GitHubValueRecord?
		switch await client.variable(key, in: scope) {
		case .success(let value): variable = value
		case .failure(.rateLimited(let reset)): return .attempt(await waited(until: reset, waits: &waits))
		case .failure(let error): return .attempt(.done(.failed(error)))
		}
		let current: GitHubRemoteSnapshot
		switch snapshot(secrets: secret.map { [$0] } ?? [], variables: variable.map { [$0] } ?? []) {
		case .success(let value): current = value
		case .failure(let error): return .attempt(.done(.refused(error.message)))
		}
		switch write(for: change, reviewed: reviewed, current: current) {
		case .success(let write): return .cleared(write)
		case .failure(let refusal): return .attempt(.done(.refused(refusal.text)))
		}
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

	/// Waits until a rate limit lifts, counting the wait in `waits`. Returns
	/// the error to answer with instead: the limit when no more waits are
	/// allowed or it lifts after the longest wait, or a cancellation.
	private static func waitOut(until reset: Date?, waits: inout Int) async -> GitHubAPIError? {
		guard waits < rateLimitRetries, let wait = GitHubHTTP.rateLimitWait(until: reset) else { return .rateLimited(until: reset) }
		waits += 1
		do { try await PlatformRateLimit.waitOut(wait, until: reset) } catch { return .cancelled }
		return nil
	}

	private static func isRateLimit(_ error: GitHubAPIError) -> Bool {
		if case .rateLimited = error { return true }
		return false
	}

	/// Refusals that every later request would meet too.
	private static func stops(_ error: GitHubAPIError) -> Bool {
		switch error {
		case .unauthorized, .forbidden, .rateLimited, .cancelled, .credentials: true
		case .notFound, .rejected, .transport, .invalidResponse, .server: false
		}
	}

	/// Refusals that mean connecting GitHub again.
	private static func needsReconnect(_ error: GitHubAPIError) -> Bool {
		switch error {
		case .unauthorized, .credentials(.expired): true
		default: false
		}
	}

	static func message(_ error: GitHubAPIError) -> String {
		switch error {
		case .unauthorized: "GitHub no longer accepts this connection. Connect GitHub again on the Platforms page."
		case .forbidden:
			"GitHub refused access. LPM Vault's GitHub App may not be installed on this repository, or your role can't change its secrets and variables."
		case .notFound: "GitHub couldn't find the repository, the environment or the secret. LPM Vault's GitHub App may not be installed on it."
		case .rateLimited: "GitHub is limiting requests. Try again in a minute."
		case .rejected(let status): "GitHub refused it (HTTP \(status))."
		case .transport: "GitHub couldn't be reached."
		case .cancelled: "Cancelled."
		case .invalidResponse: "GitHub's answer couldn't be read."
		case .server(let status): "GitHub answered with HTTP \(status)."
		case .credentials(let error): error.message(for: .github)
		}
	}
}
