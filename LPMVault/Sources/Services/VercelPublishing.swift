import Foundation

/// A Vercel project's variables as one destination environment sees them,
/// for a review.
struct VercelRemoteSnapshot: Equatable, Sendable {
	/// The variables that apply to the environment, by key.
	let variables: [String: PublishPlan.RemoteVariable]
	/// Variables for other environments or branches only, which a publish leaves alone.
	let elsewhereCount: Int
}

enum VercelSnapshotError: Error, Equatable, Sendable {
	/// The connection can't see some production variables, so a review of
	/// a production destination would miss them.
	case hiddenProductionVariables(Int)
	/// More than one variable of the key applies to the environment.
	case duplicateKeys([String])

	var message: String {
		switch self {
		case .hiddenProductionVariables(let count):
			"Vercel hides \(count) production \(count == 1 ? "variable" : "variables") from LPM Vault, so a review would be incomplete. Give the LPM Vault integration access to production variables on Vercel, then review again."
		case .duplicateKeys(let keys):
			"Vercel has more than one variable for \(keys.joined(separator: ", ")) in this environment. Remove the extra one on Vercel, then review again."
		}
	}
}

/// Publishing to Vercel: what its variables mean for a review, and sending
/// the reviewed changes.
enum VercelPublishing {
	/// Names Vercel's function runtimes reserve, so a variable can't use them.
	static let reservedKeys: Set<String> = [
		"AWS_SECRET_KEY", "AWS_EXECUTION_ENV", "AWS_LAMBDA_LOG_GROUP_NAME", "AWS_LAMBDA_LOG_STREAM_NAME",
		"AWS_LAMBDA_FUNCTION_NAME", "AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "AWS_LAMBDA_FUNCTION_VERSION",
		"NOW_REGION", "TZ", "LAMBDA_TASK_ROOT", "LAMBDA_RUNTIME_DIR",
	]

	/// What Vercel accepts. It can't make a Secret readable again.
	static let platform = PublishPlan.Platform(reservedKeys: reservedKeys, secretsStaySecret: true)

	/// How many variables are replaced at once.
	static let replaceConcurrency = 4

	/// The variables of `list` that apply to `environment`. A variable for
	/// one Preview branch only doesn't apply to Preview as a whole.
	static func snapshot(
		_ list: VercelVariableList,
		for environment: VercelPublishTarget.Environment,
		customEnvironments: [VercelCustomEnvironment]
	) -> Result<VercelRemoteSnapshot, VercelSnapshotError> {
		if environment == .production, list.hiddenProductionCount > 0 {
			return .failure(.hiddenProductionVariables(list.hiddenProductionCount))
		}
		let customNames = Dictionary(customEnvironments.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
		var variables: [String: PublishPlan.RemoteVariable] = [:]
		var duplicates: Set<String> = []
		var elsewhere = 0
		for variable in list.variables {
			guard applies(variable, to: environment) else {
				elsewhere += 1
				continue
			}
			guard variables[variable.key] == nil else {
				duplicates.insert(variable.key)
				continue
			}
			variables[variable.key] = PublishPlan.RemoteVariable(
				id: variable.id,
				sharedWith: otherEnvironments(of: variable, besides: environment, customNames: customNames),
				updatedAt: variable.updatedAt,
				storedAsSecret: variable.isSecret
			)
		}
		guard duplicates.isEmpty else { return .failure(.duplicateKeys(duplicates.sorted())) }
		return .success(VercelRemoteSnapshot(variables: variables, elsewhereCount: elsewhere))
	}

	static func applies(_ variable: VercelEnvironmentVariable, to environment: VercelPublishTarget.Environment) -> Bool {
		switch environment {
		case .production: variable.targets.contains(.production)
		case .preview: variable.targets.contains(.preview) && variable.gitBranch == nil
		case .development: variable.targets.contains(.development)
		case .custom(let id, _): variable.customEnvironmentIDs.contains(id)
		}
	}

	/// The other environments a variable applies to, by name, in Vercel's order.
	private static func otherEnvironments(
		of variable: VercelEnvironmentVariable,
		besides environment: VercelPublishTarget.Environment,
		customNames: [String: String]
	) -> [String] {
		var names: [String] = []
		for (target, name) in [(VercelEnvironmentVariable.Target.production, "Production"), (.preview, "Preview"), (.development, "Development")] {
			let isDestination = switch (target, environment) {
			case (.production, .production), (.preview, .preview), (.development, .development): true
			default: false
			}
			if variable.targets.contains(target), !isDestination { names.append(name) }
		}
		var custom: [String] = []
		for id in variable.customEnvironmentIDs {
			if case .custom(let destination, _) = environment, destination == id { continue }
			custom.append(customNames[id] ?? "a custom environment")
		}
		return names + custom.sorted()
	}

	/// Sends `changes` to the target. Each key gets an outcome; a refused
	/// token or a rate limit stops what hasn't been sent yet.
	///
	/// Vercel replaces a variable by its ID without checking what it holds,
	/// so the variables are read again first: a key added, changed, removed
	/// or shared with another environment since the review isn't sent.
	static func publish(
		_ changes: [PublishPlan.Change],
		to target: VercelPublishTarget,
		reviewed: [String: PublishPlan.RemoteVariable],
		using client: any VercelClientProtocol
	) async -> PublishReport {
		var result = PublishReport()
		guard !Task.isCancelled else {
			for change in changes { result.outcomes[change.key] = .notSent }
			return result
		}
		async let listing = client.variables(projectID: target.projectID, teamID: target.teamID)
		async let customs = client.customEnvironments(projectID: target.projectID, teamID: target.teamID)
		let current: [String: PublishPlan.RemoteVariable]
		switch await listing {
		case .success(let list):
			switch snapshot(list, for: target.environment, customEnvironments: (try? await customs.get()) ?? []) {
			case .success(let value): current = value.variables
			case .failure(let error):
				for change in changes { result.outcomes[change.key] = .failed(error.message) }
				return result
			}
		case .failure(let error):
			for change in changes { result.outcomes[change.key] = .failed(message(error)) }
			result.needsReconnect = needsReconnect(error)
			return result
		}
		var ready: [PublishPlan.Change] = []
		for change in changes {
			if isUnchangedSinceReview(change, now: current[change.key], reviewed: reviewed[change.key]) {
				ready.append(change)
			} else {
				result.outcomes[change.key] = .failed("Changed on Vercel since this review. Review again.")
			}
		}

		let adds = ready.filter { $0.operation == .add }
		let replaces = ready.compactMap { change -> (PublishPlan.Change, String)? in
			if case .replace(let id) = change.operation { return (change, id) }
			return nil
		}
		var stopped = false

		if !adds.isEmpty, !Task.isCancelled {
			let writes = adds.map { change in
				VercelVariableWrite(
					key: change.key,
					value: change.value,
					storage: change.publishesAsSecret ? .sensitive : .encrypted,
					targets: targets(of: target.environment),
					customEnvironmentIDs: customIDs(of: target.environment))
			}
			switch await client.create(writes, projectID: target.projectID, teamID: target.teamID) {
			case .success(let created):
				for change in adds {
					record(created[change.key] ?? .failure(.invalidResponse), for: change, into: &result, stopped: &stopped)
				}
			case .failure(let error):
				for change in adds { result.outcomes[change.key] = .failed(message(error)) }
				stopped = stops(error)
				result.needsReconnect = needsReconnect(error)
			}
		}

		var pending = replaces[...]
		while !pending.isEmpty, !stopped, !Task.isCancelled {
			let batch = pending.prefix(replaceConcurrency)
			pending = pending.dropFirst(batch.count)
			let answers = await withTaskGroup(of: (String, Result<VercelEnvironmentVariable, VercelAPIError>).self) { group in
				for (change, id) in batch {
					group.addTask {
						(change.key, await client.replace(
							id, key: change.key, value: change.value, storage: change.publishesAsSecret ? .sensitive : .encrypted,
							projectID: target.projectID, teamID: target.teamID))
					}
				}
				var answers: [String: Result<VercelEnvironmentVariable, VercelAPIError>] = [:]
				for await (key, answer) in group { answers[key] = answer }
				return answers
			}
			for (change, _) in batch {
				record(answers[change.key] ?? .failure(.invalidResponse), for: change, into: &result, stopped: &stopped)
			}
		}
		for change in changes where result.outcomes[change.key] == nil {
			result.outcomes[change.key] = .notSent
		}
		return result
	}

	/// Whether the variable the change would write is still the one the
	/// review saw: absent for an add; for a replacement, the same ID, sharing,
	/// protection and change time, which must be known.
	private static func isUnchangedSinceReview(
		_ change: PublishPlan.Change,
		now: PublishPlan.RemoteVariable?,
		reviewed: PublishPlan.RemoteVariable?
	) -> Bool {
		switch change.operation {
		case .add:
			return now == nil
		case .replace(let id):
			guard let now, let reviewed, now.id == id, now.updatedAt != nil else { return false }
			return now == reviewed
		}
	}

	private static func record(
		_ answer: Result<VercelEnvironmentVariable, VercelAPIError>,
		for change: PublishPlan.Change,
		into result: inout PublishReport,
		stopped: inout Bool
	) {
		switch answer {
		case .success(let variable):
			result.outcomes[change.key] = .published
			result.published.append(change.published(remoteID: variable.id, remoteUpdatedAt: variable.updatedAt))
		case .failure(let error):
			result.outcomes[change.key] = .failed(message(error))
			if stops(error) { stopped = true }
			if needsReconnect(error) { result.needsReconnect = true }
		}
	}

	private static func targets(of environment: VercelPublishTarget.Environment) -> Set<VercelEnvironmentVariable.Target> {
		switch environment {
		case .production: [.production]
		case .preview: [.preview]
		case .development: [.development]
		case .custom: []
		}
	}

	private static func customIDs(of environment: VercelPublishTarget.Environment) -> Set<String> {
		if case .custom(let id, _) = environment { return [id] }
		return []
	}

	private static func stops(_ error: VercelAPIError) -> Bool {
		switch error {
		case .unauthorized, .rateLimited, .cancelled: true
		default: false
		}
	}

	private static func needsReconnect(_ error: VercelAPIError) -> Bool {
		error == .unauthorized
	}

	static func message(_ error: VercelAPIError) -> String {
		switch error {
		case .unauthorized: "Vercel no longer accepts this connection. Connect Vercel again on the Platforms page."
		case .forbidden: "The LPM Vault integration can't change this project's variables."
		case .notFound: "Vercel couldn't find the project or the variable."
		case .rateLimited: "Vercel is limiting requests. Try again in a minute."
		case .rejected(let code): "Vercel refused it (\(code))."
		case .incompleteList: "Vercel listed the variables in pages LPM Vault can't read yet."
		case .transport: "Vercel couldn't be reached."
		case .cancelled: "Cancelled."
		case .invalidResponse: "Vercel's answer couldn't be read."
		case .server(let status): "Vercel answered with HTTP \(status)."
		}
	}
}
