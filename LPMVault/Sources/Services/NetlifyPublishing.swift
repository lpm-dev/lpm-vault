import Foundation

/// A Netlify site's variables as one deploy context sees them, for a review.
struct NetlifyRemoteSnapshot: Equatable, Sendable {
	/// Variables with a value of the context's own, by key.
	let variables: [String: PublishPlan.RemoteVariable]
	/// Variables without a value of the context's own, by key.
	let keys: [String: PublishPlan.RemoteKey]
}

enum NetlifySnapshotError: Error, Equatable, Sendable {
	/// More than one variable of the key, or more than one value of a key for the context.
	case duplicateKeys([String])

	var message: String {
		switch self {
		case .duplicateKeys(let keys):
			"Netlify has more than one value for \(keys.lazy.map(\.escapingDirectionControls).joined(separator: ", ")) in this deploy context. Remove the extra one on Netlify, then review again."
		}
	}
}

/// Publishing to Netlify: what it accepts, what its variables mean for a
/// review, and sending the reviewed changes.
///
/// Netlify keeps one variable per key for a whole site, with a value for each
/// deploy context, one secret flag and one change time. A publish writes only
/// its context's value, and never the value Netlify uses for every context.
enum NetlifyPublishing {
	/// Netlify's read-only variables, which it sets for every build and function.
	static let reservedKeys: Set<String> = [
		"NETLIFY", "BUILD_ID", "CONTEXT", "NETLIFY_PREVIEW_SERVER", "REPOSITORY_URL", "BRANCH", "HEAD", "COMMIT_REF",
		"CACHED_COMMIT_REF", "PULL_REQUEST", "REVIEW_ID", "URL", "DEPLOY_URL", "DEPLOY_PRIME_URL", "DEPLOY_ID", "SITE_NAME",
		"SITE_ID", "ACCOUNT_ID", "INCOMING_HOOK_TITLE", "INCOMING_HOOK_URL", "INCOMING_HOOK_BODY",
	]
	static let maximumKeyBytes = 255
	static let maximumValueCharacters = 5_000
	/// How many variables are written at once.
	static let writeConcurrency = 4

	/// What Netlify accepts. It decides whether a whole variable is a secret,
	/// so every value of it is stored that way.
	static let platform = PublishPlan.Platform(
		reservedKeys: reservedKeys,
		maximumKeyBytes: maximumKeyBytes,
		acceptsKey: isAcceptedKey,
		maximumValueCharacters: maximumValueCharacters,
		protectionFollowsVariable: true)

	/// A letter, then letters, digits and underscores, as Netlify requires.
	@Sendable static func isAcceptedKey(_ key: String) -> Bool {
		guard let first = key.utf8.first, (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) else { return false }
		return NetlifyHTTP.isPathSafeKey(key)
	}

	// MARK: - Review

	/// The site's variables as `context` sees them. A variable with a value
	/// for every context, and none of the context's own, can't take one: the
	/// review holds it rather than guess how Netlify would combine them.
	static func snapshot(
		_ variables: [NetlifyVariable],
		for context: NetlifyPublishTarget.Context
	) -> Result<NetlifyRemoteSnapshot, NetlifySnapshotError> {
		let own = NetlifyVariable.Context(context)
		var applying: [String: PublishPlan.RemoteVariable] = [:]
		var keys: [String: PublishPlan.RemoteKey] = [:]
		var seen: Set<String> = []
		var duplicates: Set<String> = []
		for variable in variables {
			guard seen.insert(variable.key).inserted else {
				duplicates.insert(variable.key)
				continue
			}
			let ownValues = variable.values.filter { $0.context == own }
			guard ownValues.count <= 1 else {
				duplicates.insert(variable.key)
				continue
			}
			if let value = ownValues.first {
				applying[variable.key] = PublishPlan.RemoteVariable(
					id: value.id, updatedAt: variable.updatedAt, storedAsSecret: variable.isSecret)
			} else {
				let everywhere = variable.values.contains { $0.context == .all }
				keys[variable.key] = PublishPlan.RemoteKey(
					kind: everywhere ? .sameValueEverywhere : .elsewhere, storedAsSecret: variable.isSecret, updatedAt: variable.updatedAt)
			}
		}
		guard duplicates.isEmpty else { return .failure(.duplicateKeys(duplicates.sorted())) }
		return .success(NetlifyRemoteSnapshot(variables: applying, keys: keys))
	}

	// MARK: - Publish

	/// Sends `changes` to the target. Each key gets an outcome. The site's
	/// variables are read again first, and a key added, changed, removed or
	/// made a secret on Netlify since the review isn't sent. A variable that
	/// also holds other contexts' values is read once more right before its
	/// write, so the time other destinations' histories move forward from is
	/// the one this write replaces. A refused token, a role that can't change
	/// variables, or a rate limit stops what hasn't been sent yet.
	static func publish(
		_ changes: [PublishPlan.Change],
		to target: NetlifyPublishTarget,
		reviewed: NetlifyRemoteSnapshot,
		using client: any NetlifyClientProtocol
	) async -> PublishReport {
		var report = PublishReport()
		guard !Task.isCancelled else {
			for change in changes { report.outcomes[change.key] = .notSent }
			return report
		}
		let current: NetlifyRemoteSnapshot
		let listed: [String: NetlifyVariable]
		switch await client.variables(siteID: target.siteID, teamID: target.teamID) {
		case .success(let list):
			switch snapshot(list, for: target.context) {
			case .success(let value):
				current = value
				listed = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
			case .failure(let error):
				for change in changes { report.outcomes[change.key] = .failed(error.message) }
				return report
			}
		case .failure(let error):
			for change in changes { report.outcomes[change.key] = .failed(message(error)) }
			report.needsReconnect = error == .unauthorized
			return report
		}

		var ready: [Write] = []
		for change in changes {
			switch write(for: change, reviewed: reviewed, current: current, listed: listed[change.key]) {
			case .success(let write): ready.append(write)
			case .failure(let reason): report.outcomes[change.key] = .failed(reason.text)
			}
		}

		var stopped = false
		var pending = ready[...]
		while !pending.isEmpty, !stopped, !Task.isCancelled {
			let batch = pending.prefix(writeConcurrency)
			pending = pending.dropFirst(batch.count)
			let answers = await withTaskGroup(of: (String, Answer).self) { group in
				for write in batch {
					group.addTask { (write.change.key, await send(write, to: target, reviewed: reviewed, using: client)) }
				}
				var answers: [String: Answer] = [:]
				for await (key, answer) in group { answers[key] = answer }
				return answers
			}
			for write in batch {
				switch answers[write.change.key] ?? .failed(.invalidResponse) {
				case .written(let variable, let sent):
					record(variable, for: sent, in: target.context, into: &report)
				case .refused(let reason):
					report.outcomes[write.change.key] = .failed(reason)
				case .failed(let error):
					report.outcomes[write.change.key] = .failed(message(error))
					if stops(error) { stopped = true }
					if error == .unauthorized { report.needsReconnect = true }
				}
			}
		}
		for change in changes where report.outcomes[change.key] == nil {
			report.outcomes[change.key] = .notSent
		}
		return report
	}

	/// A change cleared to send: whether it creates the variable, and the
	/// variable as Netlify had it just before.
	private struct Write: Sendable {
		let change: PublishPlan.Change
		let createsVariable: Bool
		let before: NetlifyVariable?

		/// Whether the variable holds values for other contexts, whose
		/// destinations' histories the write moves forward.
		func sharesVariable(with context: NetlifyPublishTarget.Context) -> Bool {
			let own = NetlifyVariable.Context(context)
			return before?.values.contains { $0.context != own } ?? false
		}
	}

	private enum Answer: Sendable {
		case written(NetlifyVariable, Write)
		case refused(String)
		case failed(NetlifyAPIError)
	}

	/// Sends one write. A variable other contexts share is read again first
	/// and must still be as the review saw it.
	private static func send(
		_ write: Write,
		to target: NetlifyPublishTarget,
		reviewed: NetlifyRemoteSnapshot,
		using client: any NetlifyClientProtocol
	) async -> Answer {
		var write = write
		if write.sharesVariable(with: target.context) {
			let fresh: NetlifyVariable?
			switch await client.variable(write.change.key, siteID: target.siteID, teamID: target.teamID) {
			case .success(let value): fresh = value
			case .failure(let error): return .failed(error)
			}
			let current: NetlifyRemoteSnapshot
			switch snapshot(fresh.map { [$0] } ?? [], for: target.context) {
			case .success(let value): current = value
			case .failure(let error): return .refused(error.message)
			}
			switch self.write(for: write.change, reviewed: reviewed, current: current, listed: fresh) {
			case .success(let confirmed): write = confirmed
			case .failure(let refusal): return .refused(refusal.text)
			}
		}
		let request = NetlifyVariableWrite(
			key: write.change.key, value: write.change.value, context: target.context, isSecret: write.change.publishesAsSecret)
		let answer = write.createsVariable
			? await client.create(request, siteID: target.siteID, teamID: target.teamID)
			: await client.setValue(request, siteID: target.siteID, teamID: target.teamID)
		switch answer {
		case .success(let variable): return .written(variable, write)
		case .failure(let error): return .failed(error)
		}
	}

	private struct Refusal: Error {
		let text: String

		static let added = Refusal(text: "Added on Netlify since this review. Review again.")
		static let changed = Refusal(text: "Changed on Netlify since this review. Review again.")
		static let removed = Refusal(text: "Removed on Netlify since this review. Review again.")
		static let unknownChangeTime = Refusal(text: "Netlify doesn't say when this variable last changed, so LPM Vault can't tell whether it changed since this review. Edit it once on Netlify, then review again.")
	}

	/// How the change can be sent, as Netlify has the key now, or why it can't
	/// be: the key must be as the review saw it. A replacement needs the same
	/// value, change time and protection; an added value needs the variable
	/// still to lack one for the context, stored the same way.
	private static func write(
		for change: PublishPlan.Change,
		reviewed: NetlifyRemoteSnapshot,
		current: NetlifyRemoteSnapshot,
		listed: NetlifyVariable?
	) -> Result<Write, Refusal> {
		let key = change.key
		switch change.operation {
		case .replace(let id):
			guard let now = current.variables[key] else {
				return .failure(current.keys[key] == nil ? .removed : .changed)
			}
			guard let seen = reviewed.variables[key], now.id == id, seen.id == id else { return .failure(.changed) }
			guard let time = now.updatedAt, let seenTime = seen.updatedAt else { return .failure(.unknownChangeTime) }
			guard time == seenTime, now.storedAsSecret == seen.storedAsSecret, now.storedAsSecret == change.publishesAsSecret else {
				return .failure(.changed)
			}
			return .success(Write(change: change, createsVariable: false, before: listed))
		case .add:
			guard current.variables[key] == nil else { return .failure(.added) }
			switch (reviewed.keys[key], current.keys[key]) {
			case (nil, nil):
				return .success(Write(change: change, createsVariable: true, before: nil))
			case (nil, _?):
				return .failure(.added)
			case (_?, nil):
				return .failure(.removed)
			case (let seen?, let now?):
				guard seen.kind == .elsewhere, now.kind == .elsewhere, seen.storedAsSecret == now.storedAsSecret,
					now.storedAsSecret == change.publishesAsSecret
				else { return .failure(.changed) }
				return .success(Write(change: change, createsVariable: false, before: listed))
			}
		}
	}

	/// Records what Netlify accepted. A value Netlify stored otherwise than
	/// asked, readable for a secret, fails with the reason, but is still
	/// recorded as Netlify has it, since the platform holds it.
	private static func record(
		_ variable: NetlifyVariable,
		for write: Write,
		in context: NetlifyPublishTarget.Context,
		into report: inout PublishReport
	) {
		let change = write.change
		let own = NetlifyVariable.Context(context)
		let valueID = variable.values.first { $0.context == own }?.id
		report.published.append(PublishHistory.Published(
			key: change.key, fingerprint: change.fingerprint, remoteID: valueID, remoteUpdatedAt: variable.updatedAt,
			publishedAsSecret: variable.isSecret))
		if let before = write.before, let from = before.updatedAt, let to = variable.updatedAt, to != from {
			let after = Dictionary(variable.values.map { ($0.context, $0.id) }, uniquingKeysWith: { first, _ in first })
			var remoteIDs: [String: String] = [:]
			for value in before.values where value.context != own {
				if let id = after[value.context] { remoteIDs[value.id] = id }
			}
			if !remoteIDs.isEmpty {
				report.advances.append(PublishHistory.Advance(key: change.key, from: from, to: to, remoteIDs: remoteIDs))
			}
		}
		if variable.isSecret != change.publishesAsSecret {
			report.outcomes[change.key] = .failed(
				variable.isSecret
					? "Netlify stored it as a secret, though LPM Vault sent it readable."
					: "Netlify stored it readable, though LPM Vault sent it as a secret. Mark it as containing secret values on Netlify.")
		} else if valueID == nil {
			report.outcomes[change.key] = .failed("Netlify accepted it, but its answer doesn't show the value for this deploy context. Check it on Netlify.")
		} else {
			report.outcomes[change.key] = .published
		}
	}

	/// Refusals that every later request would meet too.
	private static func stops(_ error: NetlifyAPIError) -> Bool {
		switch error {
		case .unauthorized, .forbidden, .rateLimited, .cancelled: true
		case .notFound, .rejected, .transport, .invalidResponse, .server: false
		}
	}

	static func message(_ error: NetlifyAPIError) -> String {
		switch error {
		case .unauthorized: "Netlify no longer accepts this connection. Connect Netlify again on the Platforms page."
		case .forbidden: "Your role on this Netlify team can't change the site's variables."
		case .notFound: "Netlify couldn't find the site or the variable."
		case .rateLimited: "Netlify is limiting requests. Try again in a minute."
		case .rejected(let status): "Netlify refused it (HTTP \(status))."
		case .transport: "Netlify couldn't be reached."
		case .cancelled: "Cancelled."
		case .invalidResponse: "Netlify's answer couldn't be read."
		case .server(let status): "Netlify answered with HTTP \(status)."
		}
	}
}
