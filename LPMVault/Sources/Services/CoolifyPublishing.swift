import Foundation

/// A Coolify resource's variables as one destination sees them, for a review.
struct CoolifyRemoteSnapshot: Equatable, Sendable {
	/// The variables of the destination's deployments, by key.
	let variables: [String: PublishPlan.RemoteVariable]
	/// Keys of the application's preview deployments.
	let previewKeys: Set<String>
	/// Variables of the application's other deployments, which a publish leaves alone.
	let elsewhereCount: Int
}

enum CoolifySnapshotError: Error, Equatable, Sendable {
	/// More than one variable of the key belongs to the deployments.
	case duplicateKeys([String])

	var message: String {
		switch self {
		case .duplicateKeys(let keys):
			"Coolify has more than one variable for \(keys.joined(separator: ", ")) here. Remove the extra one in Coolify, then review again."
		}
	}
}

/// Publishing to Coolify: what it accepts, what its variables mean for a
/// review, and sending the reviewed changes.
///
/// Coolify writes variables by key, so a publish first reads them again and
/// sends nothing for a key that changed since the review.
enum CoolifyPublishing {
	/// Coolify's longest variable name.
	static let maximumKeyBytes = 255
	/// How many variables are written at once.
	static let writeConcurrency = 4

	/// What Coolify accepts for `resource`. Coolify makes the variables of a
	/// docker compose application's routes, and every `SERVICE_` variable of a
	/// service, itself. `buildPack` is an application's.
	static func platform(for resource: CoolifyPublishTarget.Resource, buildPack: String?) -> PublishPlan.Platform {
		let prefixes: [String] = switch resource {
		case .service: ["SERVICE_"]
		case .application where buildPack == "dockercompose": ["SERVICE_FQDN_", "SERVICE_URL_", "SERVICE_NAME_"]
		case .application: []
		}
		return PublishPlan.Platform(reservedPrefixes: prefixes, maximumKeyBytes: maximumKeyBytes, valueIssues: valueIssues)
	}

	// MARK: - Values

	/// What Coolify does to `value` before an app gets it. Coolify trims a
	/// value when saving it, replaces `{{…}}` references to its shared
	/// variables, and writes the value in single quotes, except for a JSON
	/// object or array, which it writes without quotes.
	static func valueIssues(_ value: String) -> [PublishPlan.ValueIssue] {
		var issues: [PublishPlan.ValueIssue] = []
		let stored = value.trimmingCharacters(in: trimmedCharacters)
		if isJSONContainer(stored) {
			if stored.contains(where: { $0 == "$" || $0.isNewline }) || stored.contains(" #") || stored.contains("\t#") {
				issues.append(.unquotedJSON)
			}
		} else {
			if stored.contains("'") { issues.append(.singleQuote) }
			if stored.hasSuffix("\\") { issues.append(.trailingBackslash) }
		}
		if containsReference(stored) { issues.append(.reference) }
		if stored.utf8.count != value.utf8.count { issues.append(.trimmed) }
		return issues
	}

	/// The characters PHP's `trim` removes.
	private static let trimmedCharacters = CharacterSet(charactersIn: " \t\n\r\0\u{0B}")

	/// Coolify's `{{team.X}}`, `{{project.X}}`, `{{environment.X}}`,
	/// `{{server.X}}` and `{{vault.X}}` references. Spaces around the name
	/// count, as they do in Coolify.
	static func containsReference(_ value: String) -> Bool {
		var rest = value[...]
		while let open = rest.range(of: "{{") {
			let inner = rest[open.upperBound...].drop { $0 == " " || $0 == "\t" || $0.isNewline }
			if referencePrefixes.contains(where: { inner.hasPrefix($0) }), inner.contains("}}") { return true }
			rest = rest[open.upperBound...]
		}
		return false
	}

	private static let referencePrefixes = ["team.", "project.", "environment.", "server.", "vault."]

	private static func isJSONContainer(_ value: String) -> Bool {
		guard let first = value.first, first == "{" || first == "[" else { return false }
		return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) != nil
	}

	// MARK: - Review

	/// The variables of `list` that belong to `deployments`.
	static func snapshot(
		_ list: [CoolifyVariable],
		for deployments: CoolifyPublishTarget.Deployments
	) -> Result<CoolifyRemoteSnapshot, CoolifySnapshotError> {
		let preview = deployments == .preview
		var variables: [String: PublishPlan.RemoteVariable] = [:]
		var previewKeys: Set<String> = []
		var duplicates: Set<String> = []
		var elsewhere = 0
		for variable in list {
			if variable.isPreview { previewKeys.insert(variable.key) }
			guard variable.isPreview == preview else {
				elsewhere += 1
				continue
			}
			guard variables[variable.key] == nil else {
				duplicates.insert(variable.key)
				continue
			}
			variables[variable.key] = PublishPlan.RemoteVariable(
				id: variable.id, updatedAt: variable.updatedAt, storedAsSecret: variable.isLocked)
		}
		guard duplicates.isEmpty else { return .failure(.duplicateKeys(duplicates.sorted())) }
		return .success(CoolifyRemoteSnapshot(variables: variables, previewKeys: previewKeys, elsewhereCount: elsewhere))
	}

	// MARK: - Publish

	/// Sends `changes` to the target. Each key gets an outcome. A key that
	/// changed in Coolify since the review isn't sent, and a refused token or
	/// a rate limit stops what hasn't been sent yet.
	///
	/// Coolify copies a new production variable of an application to its
	/// preview deployments, unlocked. For a secret, a locked copy is made
	/// first, which stops Coolify making its own.
	static func publish(
		_ changes: [PublishPlan.Change],
		to target: CoolifyPublishTarget,
		reviewed: [String: PublishPlan.RemoteVariable],
		using client: any CoolifyClientProtocol
	) async -> PublishReport {
		var report = PublishReport()
		let current: CoolifyRemoteSnapshot
		switch await client.variables(of: target.resource, id: target.resourceID) {
		case .success(let list):
			switch snapshot(list, for: target.deployments) {
			case .success(let value): current = value
			case .failure(let error):
				for change in changes { report.outcomes[change.key] = .failed(error.message) }
				return report
			}
		case .failure(let error):
			for change in changes { report.outcomes[change.key] = .failed(message(error)) }
			report.needsReconnect = error == .unauthorized
			return report
		}

		var ready: [PublishPlan.Change] = []
		for change in changes {
			if let reason = changedSinceReview(change, now: current.variables[change.key], reviewed: reviewed[change.key]) {
				report.outcomes[change.key] = .failed(reason)
			} else {
				ready.append(change)
			}
		}

		var written: [String: Written] = [:]
		var stopped = false
		var pending = ready[...]
		while !pending.isEmpty, !stopped, !Task.isCancelled {
			let batch = pending.prefix(writeConcurrency)
			pending = pending.dropFirst(batch.count)
			let answers = await withTaskGroup(of: (String, Result<Written, WriteFailure>).self) { group in
				for change in batch {
					let locksCopy = target.resource == .application && target.deployments == .production
						&& change.operation == .add && change.publishesAsSecret && !current.previewKeys.contains(change.key)
					group.addTask { (change.key, await write(change, to: target, lockingPreviewCopy: locksCopy, using: client)) }
				}
				var answers: [String: Result<Written, WriteFailure>] = [:]
				for await (key, answer) in group { answers[key] = answer }
				return answers
			}
			for change in batch {
				switch answers[change.key] ?? .failure(WriteFailure(error: .invalidResponse)) {
				case .success(let variable):
					report.outcomes[change.key] = .published
					written[change.key] = variable
				case .failure(let failure):
					report.outcomes[change.key] = .failed(failure.message)
					if stops(failure.error) { stopped = true }
					if failure.error == .unauthorized { report.needsReconnect = true }
				}
			}
		}
		for change in changes where report.outcomes[change.key] == nil {
			report.outcomes[change.key] = .notSent
		}

		// An application answers a new variable with its UUID only, so its time comes from reading the variables again.
		var times: [String: Date] = [:]
		if written.values.contains(where: { $0.updatedAt == nil }),
			case .success(let list) = await client.variables(of: target.resource, id: target.resourceID)
		{
			let preview = target.deployments == .preview
			for variable in list where variable.isPreview == preview && written[variable.key]?.id == variable.id {
				times[variable.id] = variable.updatedAt
			}
		}
		for change in changes {
			guard let variable = written[change.key] else { continue }
			report.published.append(change.published(remoteID: variable.id, remoteUpdatedAt: variable.updatedAt ?? times[variable.id]))
		}
		return report
	}

	/// Why the change no longer matches what Coolify has, or nil when it does.
	private static func changedSinceReview(
		_ change: PublishPlan.Change,
		now: PublishPlan.RemoteVariable?,
		reviewed: PublishPlan.RemoteVariable?
	) -> String? {
		switch change.operation {
		case .add:
			return now == nil ? nil : "Added in Coolify since this review. Review again."
		case .replace(let id):
			guard let now else { return "Removed in Coolify since this review. Review again." }
			guard now.id == id, now.updatedAt == reviewed?.updatedAt else { return "Changed in Coolify since this review. Review again." }
			return nil
		}
	}

	private struct Written: Sendable {
		let id: String
		/// Nil for a variable Coolify only named.
		let updatedAt: Date?
	}

	private struct WriteFailure: Error, Sendable {
		let error: CoolifyAPIError
		/// A locked copy for preview deployments was made and couldn't be removed again.
		var leftCopy = false

		var message: String {
			let reason = CoolifyPublishing.message(error)
			return leftCopy ? "\(reason) Its locked copy for preview deployments stays in Coolify." : reason
		}
	}

	private static func write(
		_ change: PublishPlan.Change,
		to target: CoolifyPublishTarget,
		lockingPreviewCopy: Bool,
		using client: any CoolifyClientProtocol
	) async -> Result<Written, WriteFailure> {
		let write = CoolifyVariableWrite(
			key: change.key, value: change.value, isPreview: target.deployments == .preview, isLocked: change.publishesAsSecret)
		if case .replace = change.operation {
			return await client.update(write, in: target.resource, id: target.resourceID)
				.map { Written(id: $0.id, updatedAt: $0.updatedAt) }
				.mapError { WriteFailure(error: $0) }
		}
		var copyID: String?
		if lockingPreviewCopy {
			let copy = CoolifyVariableWrite(key: change.key, value: change.value, isPreview: true, isLocked: true)
			switch await client.create(copy, in: target.resource, id: target.resourceID) {
			case .success(let id): copyID = id
			// A preview variable appeared since the variables were read, so Coolify won't copy this one.
			case .failure(.conflict): break
			case .failure(let error): return .failure(WriteFailure(error: error))
			}
		}
		switch await client.create(write, in: target.resource, id: target.resourceID) {
		case .success(let id):
			return .success(Written(id: id, updatedAt: nil))
		case .failure(let error):
			var failure = WriteFailure(error: error)
			if let copyID, case .failure = await client.delete(copyID, in: target.resource, id: target.resourceID) {
				failure.leftCopy = true
			}
			return .failure(failure)
		}
	}

	/// Refusals that every later request would meet too.
	private static func stops(_ error: CoolifyAPIError) -> Bool {
		switch error {
		case .unauthorized, .apiDisabled, .addressNotAllowed, .missingPermission, .roleTooLow, .rateLimited, .redirected,
			.untrustedCertificate, .cancelled:
			true
		case .forbidden, .notFound, .conflict, .rejected, .transport, .invalidResponse, .server:
			false
		}
	}

	static func message(_ error: CoolifyAPIError) -> String {
		switch error {
		case .unauthorized: "Coolify no longer accepts this connection's token. Connect Coolify again on the Platforms page."
		case .apiDisabled: "Coolify's API is turned off. Turn on API access in Coolify's Settings → Advanced."
		case .addressNotAllowed: "Coolify doesn't accept API requests from this Mac's address. Add it to Allowed API IPs in Coolify's Settings → Advanced."
		case .missingPermission: "The connection's token can't change variables. Create a token with the Write permission, then connect Coolify again."
		case .roleTooLow: "Only the team's admins and owners can change variables through the API."
		case .forbidden: "Coolify refused to change this resource's variables."
		case .notFound: "Coolify couldn't find the resource or the variable."
		case .conflict: "Coolify already has this variable. Review again."
		case .rateLimited: "Coolify is limiting requests. Try again in a minute."
		case .rejected(let message) where !message.isEmpty: "Coolify refused it: \(message)"
		case .rejected: "Coolify refused it."
		case .redirected: "Coolify's address redirected the request, so it wasn't sent."
		case .untrustedCertificate: "This Mac doesn't trust Coolify's certificate, so nothing was sent."
		case .transport: "Coolify couldn't be reached."
		case .cancelled: "Cancelled."
		case .invalidResponse: "Coolify's answer couldn't be read."
		case .server(let status): "Coolify answered with HTTP \(status)."
		}
	}
}
