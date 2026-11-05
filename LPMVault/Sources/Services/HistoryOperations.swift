import Foundation

/// What local history says about a project, from its marker and records.
struct VaultHistoryState: Sendable, Equatable {
	/// "default" before any history, "on", "off", "removing" (a newer client
	/// is removing it), "unsupported" (a newer version) or "both" (damaged).
	let history: String
	/// History damage beyond what a listing shows, which Repair handles.
	let damage: [HistoryEngine.Damage]

	var isOn: Bool { history == "on" || history == "default" }
}

/// Local history's reads and changes, run while the caller holds the store's
/// transaction lock. Every rule is the engine's; this only reads and commits.
enum HistoryOperations {
	/// The history's state, reading the parts the engine asks for.
	static func state(_ storage: some HistoryStorage, vaultId: String) throws -> VaultHistoryState {
		let marker = try storage.historyMarker(vaultId: vaultId).map(secret)
		let head = try storage.historyRecord(HistoryRecorder.account("history-head", vaultId)).map(secret)
		let key = try storage.historyRecord(HistoryRecorder.account("key", vaultId)).map(secret)
		var parts: [(part: Int, bytes: SecretBytes?)] = []
		var check = try HistoryEngine.check(vaultId: vaultId, marker: marker, head: head, key: key, parts: parts)
		if let needed = check.needsParts {
			for part in needed {
				parts.append((part, try storage.historyRecord(HistoryRecorder.account("history", vaultId, part: part)).map(secret)))
			}
			check = try HistoryEngine.check(vaultId: vaultId, marker: marker, head: head, key: key, parts: parts)
		}
		return VaultHistoryState(history: check.history, damage: check.damage ?? [])
	}

	/// The project's history as stored, every part the head lists, or nil
	/// when it has none.
	static func stored(_ storage: some HistoryStorage, vaultId: String) throws -> HistoryEngine.Stored? {
		guard let head = try storage.historyRecord(HistoryRecorder.account("history-head", vaultId)),
			let key = try storage.historyRecord(HistoryRecorder.account("key", vaultId))
		else { return nil }
		return try HistoryRecorder.stored(storage, vaultId: vaultId, head: secret(head), key: secret(key))
	}

	/// The timeline, newest first, or nil when the project has no history.
	static func timeline(_ storage: some HistoryStorage, vaultId: String, filter: HistoryEngine.Filter?) throws -> HistoryEngine.Timeline? {
		guard let stored = try stored(storage, vaultId: vaultId) else { return nil }
		return try HistoryEngine.timeline(stored, values: try values(storage, vaultId: vaultId), filter: filter)
	}

	/// Entries with their values, as blobs of the answer.
	static func reveal(_ storage: some HistoryStorage, vaultId: String, ids: [String]) throws -> HistoryEngine.Answer<[HistoryEngine.Entry]> {
		guard let stored = try stored(storage, vaultId: vaultId) else { throw noHistory }
		return try HistoryEngine.reveal(stored, ids: ids)
	}

	/// A rollback's plan from the values stored now.
	static func planRollback(
		_ storage: some HistoryStorage,
		vaultId: String,
		target: HistoryEngine.RollbackTarget
	) throws -> HistoryEngine.Answer<HistoryEngine.Plan> {
		guard let stored = try stored(storage, vaultId: vaultId) else { throw noHistory }
		return try HistoryEngine.planRollback(stored, values: try required(values(storage, vaultId: vaultId)), target: target)
	}

	/// The environments a reviewed rollback leaves, which the engine refuses
	/// with `history.changed_since_review` unless the values and the plan
	/// still match the review. The caller writes them as one values write.
	static func rolledBackEnvironments(
		_ storage: some HistoryStorage,
		vaultId: String,
		target: HistoryEngine.RollbackTarget,
		fingerprint: String,
		skipped: [(environment: Int, row: Int)],
		keepEmpty: [Int]
	) throws -> [String: [String: String]] {
		guard let stored = try stored(storage, vaultId: vaultId) else { throw noHistory }
		let current = try required(values(storage, vaultId: vaultId))
		let writes = try HistoryEngine.applyRollback(
			stored, values: current, target: target, fingerprint: fingerprint, skipped: skipped, keepEmpty: keepEmpty)
		var environments = try current.withUnsafeBytes { bytes in
			try JSONDecoder().decode(Payload.self, from: Data(bytes)).environments
		}
		for write in writes {
			if let renamed = write.renamedFrom { environments[renamed] = nil }
			if write.values == nil { environments[write.name] = nil }
		}
		for write in writes {
			guard let values = write.values else { continue }
			environments[write.name] = Dictionary(uniqueKeysWithValues: values.map { entry in
				(entry.key, entry.value.withUnsafeBytes { String(decoding: $0, as: UTF8.self) })
			})
		}
		return environments
	}

	/// Reviews removing the value `key` had in `environment` on `side` of `entry`.
	static func reviewRemoval(
		_ storage: some HistoryStorage,
		vaultId: String,
		entry: String,
		environment: String,
		key: String,
		side: String
	) throws -> HistoryEngine.Review {
		guard let stored = try stored(storage, vaultId: vaultId) else { throw noHistory }
		return try HistoryEngine.reviewRemoval(
			stored, values: try required(values(storage, vaultId: vaultId)),
			entry: entry, environment: environment, key: key, side: side)
	}

	/// Removes the reviewed value from the places at `selection`: one journal
	/// transaction starts it, and the key rotation that follows finishes it.
	static func remove(_ storage: some HistoryStorage, vaultId: String, review: HistoryEngine.Review, selection: [Int]) throws {
		guard let stored = try stored(storage, vaultId: vaultId) else { throw noHistory }
		guard let approval = try storage.historyApproval(vaultId: vaultId) else {
			throw HistoryEngine.Failure(code: "history.unavailable", message: "The values' approval couldn't be confirmed.")
		}
		let writes = try HistoryEngine.startRemoval(
			stored, values: try required(values(storage, vaultId: vaultId)),
			review: review, selection: selection, approval: approval)
		try storage.historyCommit(writes)
		try HistoryRecorder.finishRunning(storage, vaultId: vaultId)
	}

	/// Turns history off, deleting it, or back on.
	static func setEnabled(_ storage: some HistoryStorage, vaultId: String, enabled: Bool) throws {
		let marker = try storage.historyMarker(vaultId: vaultId)
		let inventory = try storage.historyProjectNames(vaultId: vaultId)
		let plan: CompanionEngine.Plan
		do {
			plan = try CompanionEngine.plan(enabled ? .historyOn : .historyOff, vaultId: vaultId, marker: marker, inventory: inventory)
		} catch {
			throw HistoryEngine.Failure(code: error.code, message: error.message)
		}
		try storage.historyRun(plan, vaultId: vaultId)
	}

	private struct Payload: Decodable {
		let environments: [String: [String: String]]
	}

	private static func values(_ storage: some HistoryStorage, vaultId: String) throws -> SecretBytes? {
		try storage.historyValues(vaultId: vaultId).map(secret)
	}

	private static func required(_ values: SecretBytes?) throws -> SecretBytes {
		guard let values else {
			throw HistoryEngine.Failure(code: "history.no_project", message: "This project's values can't be found.")
		}
		return values
	}

	private static let noHistory = HistoryEngine.Failure(code: "history.off", message: "This project has no local history.")

	private static func secret(_ data: Data) -> SecretBytes {
		data.withUnsafeBytes { SecretBytes(copying: $0) }
	}
}
