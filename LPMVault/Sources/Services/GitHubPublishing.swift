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

	/// Sends `changes` to `scope`, the target's repository and environment by
	/// their current names. Each key gets an outcome. The scope's secrets and
	/// variables are listed again first, and a key added, changed, removed or
	/// moved between secrets and variables on GitHub since the review isn't
	/// sent. Writes go one at a time, as GitHub asks of a client, and each is
	/// read back for the time GitHub gave it, which the next review compares.
	/// A refused token, missing access, or a rate limit that doesn't lift
	/// stops what hasn't been sent yet.
	static func publish(
		_ changes: [PublishPlan.Change],
		to scope: GitHubScope,
		reviewed: GitHubRemoteSnapshot,
		using client: any GitHubClientProtocol,
		seal: @Sendable (String, Data) -> Data? = SealedBox.seal
	) async -> PublishReport {
		var report = PublishReport()
		func stop(_ reason: (PublishPlan.Change) -> PublishOutcome) -> PublishReport {
			for change in changes where report.outcomes[change.key] == nil { report.outcomes[change.key] = reason(change) }
			return report
		}
		guard !Task.isCancelled else { return stop { _ in .notSent } }
		var waits = 0
		let current: GitHubRemoteSnapshot
		switch await listing(scope, using: client, waits: &waits) {
		case .success(let snapshot): current = snapshot
		case .failure(.api(let error)):
			report.needsReconnect = error == .unauthorized
			return stop { _ in .failed(message(error)) }
		case .failure(.snapshot(let error)):
			return stop { _ in .failed(error.message) }
		}

		var ready: [Write] = []
		for change in changes {
			switch write(for: change, reviewed: reviewed, current: current) {
			case .success(let write): ready.append(write)
			case .failure(let refusal): report.outcomes[change.key] = .failed(refusal.text)
			}
		}

		var publicKey: GitHubPublicKey?
		if ready.contains(where: \.isSecret) {
			switch await afterRateLimits(waits: &waits, { await client.publicKey(of: scope) }) {
			case .success(let key): publicKey = key
			case .failure(let error):
				report.needsReconnect = error == .unauthorized
				return stop { _ in .failed(message(error)) }
			}
		}

		for write in ready {
			guard !Task.isCancelled else { break }
			var waits = 0
			switch await send(write, to: scope, reviewed: reviewed, publicKey: publicKey, using: client, seal: seal, waits: &waits) {
			case .written(let readBack):
				report.published.append(write.change.published(
					remoteID: remoteID(isSecret: write.isSecret), remoteUpdatedAt: readBack.record?.updatedAt))
				report.outcomes[write.change.key] = readBack == .gone
					? .failed("GitHub accepted it, but it was gone when LPM Vault read it back. Check it on GitHub.")
					: .published
			case .refused(let reason):
				report.outcomes[write.change.key] = .failed(reason)
			case .failed(let error):
				report.outcomes[write.change.key] = .failed(message(error))
				if error == .unauthorized { report.needsReconnect = true }
				if stops(error) { return stop { _ in .notSent } }
			}
		}
		return stop { _ in .notSent }
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
		/// It couldn't be read, so its time isn't known.
		case unknown

		var record: GitHubValueRecord? {
			if case .record(let record) = self { return record }
			return nil
		}
	}

	private enum Answer: Sendable {
		case written(ReadBack)
		case refused(String)
		case failed(GitHubAPIError)
	}

	private enum ListingFailure: Error, Equatable {
		case api(GitHubAPIError)
		case snapshot(GitHubSnapshotError)
	}

	private static func listing(
		_ scope: GitHubScope,
		using client: any GitHubClientProtocol,
		waits: inout Int
	) async -> Result<GitHubRemoteSnapshot, ListingFailure> {
		let secrets: [GitHubValueRecord]
		switch await afterRateLimits(waits: &waits, { await client.secrets(in: scope) }) {
		case .success(let value): secrets = value
		case .failure(let error): return .failure(.api(error))
		}
		let variables: [GitHubValueRecord]
		switch await afterRateLimits(waits: &waits, { await client.variables(in: scope) }) {
		case .success(let value): variables = value
		case .failure(let error): return .failure(.api(error))
		}
		return snapshot(secrets: secrets, variables: variables).mapError(ListingFailure.snapshot)
	}

	/// Sends one write and reads it back. A write that met a rate limit is
	/// sent again once it lifts, after reading the record again to make sure
	/// it's still as the review saw it.
	private static func send(
		_ write: Write,
		to scope: GitHubScope,
		reviewed: GitHubRemoteSnapshot,
		publicKey: GitHubPublicKey?,
		using client: any GitHubClientProtocol,
		seal: @Sendable (String, Data) -> Data?,
		waits: inout Int
	) async -> Answer {
		let key = write.change.key
		var readsFirst = false
		while true {
			if readsFirst, let answer = await reread(write, in: scope, reviewed: reviewed, using: client, waits: &waits) {
				return answer
			}
			let answer: Result<Void, GitHubAPIError>
			if write.isSecret {
				guard let publicKey, let ciphertext = seal(write.change.value, publicKey.key) else {
					return .refused("The value couldn't be sealed for GitHub.")
				}
				answer = await client.setSecret(key, to: GitHubSealedSecret(ciphertext: ciphertext, keyID: publicKey.id), in: scope)
			} else if write.creates {
				answer = await client.createVariable(key, value: write.change.value, in: scope)
			} else {
				answer = await client.updateVariable(key, value: write.change.value, in: scope)
			}
			switch answer {
			case .success:
				let readBack = await afterRateLimits(waits: &waits) {
					write.isSecret ? await client.secret(key, in: scope) : await client.variable(key, in: scope)
				}
				// The write happened even when it can't be read back; without its time, the next review can't tell whether it changed.
				switch readBack {
				case .success(let record?): return .written(.record(record))
				case .success(nil): return .written(.gone)
				case .failure: return .written(.unknown)
				}
			case .failure(.rateLimited(let reset)):
				if let error = await waitOut(until: reset, waits: &waits) { return .failed(error) }
				readsFirst = true
			case .failure(.rejected(status: 409)) where write.creates && !write.isSecret:
				// GitHub answers a variable created meanwhile with a conflict.
				return .refused(Refusal.added.text)
			case .failure(let error):
				return .failed(error)
			}
		}
	}

	/// Reads the record a write is about to replace or create again, as when
	/// a rate limit held the write up; it must still be as the review saw it.
	/// Nil when it is, else the answer to give instead of writing.
	private static func reread(
		_ write: Write,
		in scope: GitHubScope,
		reviewed: GitHubRemoteSnapshot,
		using client: any GitHubClientProtocol,
		waits: inout Int
	) async -> Answer? {
		let key = write.change.key
		let secret: GitHubValueRecord?
		switch await afterRateLimits(waits: &waits, { await client.secret(key, in: scope) }) {
		case .success(let value): secret = value
		case .failure(let error): return .failed(error)
		}
		let variable: GitHubValueRecord?
		switch await afterRateLimits(waits: &waits, { await client.variable(key, in: scope) }) {
		case .success(let value): variable = value
		case .failure(let error): return .failed(error)
		}
		let current: GitHubRemoteSnapshot
		switch snapshot(secrets: secret.map { [$0] } ?? [], variables: variable.map { [$0] } ?? []) {
		case .success(let value): current = value
		case .failure(let error): return .refused(error.message)
		}
		switch self.write(for: write.change, reviewed: reviewed, current: current) {
		case .success: return nil
		case .failure(let refusal): return .refused(refusal.text)
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

	/// The request's answer, sending it again once a rate limit lifts: GitHub
	/// applies nothing it refuses that way, so sending again is safe.
	private static func afterRateLimits<Value>(
		waits: inout Int,
		_ request: () async -> Result<Value, GitHubAPIError>
	) async -> Result<Value, GitHubAPIError> {
		while true {
			let answer = await request()
			guard case .failure(.rateLimited(let reset)) = answer else { return answer }
			if let error = await waitOut(until: reset, waits: &waits) { return .failure(error) }
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

	/// Refusals that every later request would meet too.
	private static func stops(_ error: GitHubAPIError) -> Bool {
		switch error {
		case .unauthorized, .forbidden, .rateLimited, .cancelled: true
		case .notFound, .rejected, .transport, .invalidResponse, .server: false
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
		}
	}
}
