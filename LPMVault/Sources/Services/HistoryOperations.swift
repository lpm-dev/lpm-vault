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

/// A project's history state with its timeline, read together.
struct VaultHistoryOverview: Sendable, Equatable {
	let state: VaultHistoryState
	/// Nil while the project has no history.
	let timeline: HistoryEngine.Timeline?
}

/// Local history's reads and changes, run while the caller holds the store's
/// transaction lock. Every rule is the engine's; this only reads and commits.
enum HistoryOperations {
	/// The history's state, reading the parts the engine asks for.
	static func state(_ storage: some HistoryStorage, vaultId: String) throws -> VaultHistoryState {
		try checked(storage, vaultId: vaultId).state
	}

	/// The history's state and, when it has a head and a key, its timeline,
	/// from one read of each record: the parts the state's check reads are
	/// the timeline's too.
	static func overview(
		_ storage: some HistoryStorage, vaultId: String, filter: HistoryEngine.Filter?
	) throws -> (state: VaultHistoryState, timeline: HistoryEngine.Timeline?) {
		let checked = try checked(storage, vaultId: vaultId)
		// Only history that's on and whole has a timeline; the state says why
		// another doesn't.
		guard checked.state.history == "on", checked.state.damage.isEmpty, let head = checked.head, let key = checked.key,
			let maintained = try HistoryRecorder.maintained(storage, vaultId: vaultId, read: (head, key))
		else { return (checked.state, nil) }
		// Maintenance that did something rewrote parts the check read.
		let stored = try HistoryRecorder.stored(
			storage, vaultId: vaultId, head: maintained.head, key: maintained.key, known: maintained.changed ? [:] : checked.parts)
		return (checked.state, try HistoryEngine.timeline(stored, values: try values(storage, vaultId: vaultId), filter: filter))
	}

	/// What `state` reads: the head, the key, and the parts the check asked for.
	private static func checked(
		_ storage: some HistoryStorage, vaultId: String
	) throws -> (state: VaultHistoryState, head: SecretBytes?, key: SecretBytes?, parts: [Int: SecretBytes]) {
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
		let read = Dictionary(parts.compactMap { part in part.bytes.map { (part.part, $0) } }, uniquingKeysWith: { first, _ in first })
		return (VaultHistoryState(history: check.history, damage: check.damage ?? []), head, key, read)
	}

	/// The project's history, every part the head lists, opened as the LPM
	/// CLI opens it for reading or changing: nil before any history; refused
	/// while it's off, kept by a newer version or damaged, whatever the
	/// values allow; its key maintained first.
	static func stored(_ storage: some HistoryStorage, vaultId: String) throws -> HistoryEngine.Stored? {
		let marker = try storage.historyMarker(vaultId: vaultId).map(secret)
		switch try HistoryEngine.check(vaultId: vaultId, marker: marker, head: nil, key: nil).history {
		case "default": return nil
		case "on": break
		case "off": throw noHistory
		case "removing", "unsupported": throw newerVersion
		default: throw damaged
		}
		guard let maintained = try HistoryRecorder.maintained(storage, vaultId: vaultId) else { return nil }
		return try HistoryRecorder.stored(storage, vaultId: vaultId, head: maintained.head, key: maintained.key)
	}

	/// The timeline, newest first, or nil when the project has no history.
	static func timeline(_ storage: some HistoryStorage, vaultId: String, filter: HistoryEngine.Filter?) throws -> HistoryEngine.Timeline? {
		guard let stored = try stored(storage, vaultId: vaultId) else { return nil }
		return try HistoryEngine.timeline(stored, values: try values(storage, vaultId: vaultId), filter: filter)
	}

	/// The newest changes to `key` in each of `environments`, by their names
	/// now, at most `limit` each: the engine follows the key and each
	/// environment back through their renames, from one read of the history.
	static func keyChanges(
		_ storage: some HistoryStorage, vaultId: String, key: String, environments: [String], limit: Int
	) throws -> [String: [HistoryEngine.Entry]] {
		guard let stored = try stored(storage, vaultId: vaultId) else { return [:] }
		let values = try values(storage, vaultId: vaultId)
		var changes: [String: [HistoryEngine.Entry]] = [:]
		for environment in environments {
			let timeline = try HistoryEngine.timeline(
				stored, values: values, filter: HistoryEngine.Filter(environment: environment, exactKey: key, limit: limit))
			let entries = timeline.rows.compactMap { row -> HistoryEngine.Entry? in
				if case .entry(let entry) = row { return entry }
				return nil
			}
			if !entries.isEmpty { changes[environment] = entries }
		}
		return changes
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

	/// What a reviewed rollback leaves: the environments, and the renames
	/// back it makes, which its entry records as renames.
	struct RolledBack: Sendable, Equatable {
		let environments: [String: [String: String]]
		let renames: [HistoryEngine.Rename]
	}

	/// What a reviewed rollback leaves, which the engine refuses with
	/// `history.changed_since_review` unless the values and the plan still
	/// match the review. The caller writes it as one values write.
	static func rolledBackEnvironments(
		_ storage: some HistoryStorage,
		vaultId: String,
		target: HistoryEngine.RollbackTarget,
		fingerprint: String,
		skipped: [(environment: Int, row: Int)],
		keepEmpty: [Int]
	) throws -> RolledBack {
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
		let renames = writes.compactMap { write in
			write.renamedFrom.map { HistoryEngine.Rename.environment(from: $0, to: write.name) }
		}
		return RolledBack(environments: environments, renames: renames)
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
		// Starting writes only the head and the key, so the parts just read
		// are still the ones stored.
		let known = Dictionary(stored.parts.compactMap { part in part.bytes.map { (part.part, $0) } }, uniquingKeysWith: { first, _ in first })
		try HistoryRecorder.finishRunning(storage, vaultId: vaultId, known: known)
	}

	/// What the pass after unlock found.
	struct Upkeep: Equatable, Sendable {
		/// The service's record count after the pass's trims.
		let records: Int
		/// Parts the pass trimmed from the largest rings.
		let trimmed: Int
		/// Whether the service is still past its target, so new rings start
		/// smaller and rings can't grow.
		let crowded: Bool
		/// Whether some ring may still have fewer parts than a full one, so a
		/// later pass raises it.
		let mayBeShrunk: Bool
	}

	/// The most parts one pass after unlock trims.
	static let maximumTrimsAfterUnlock = 64

	/// The pass after unlock. While the service is past its target, it trims
	/// the largest rings, at most `maximumTrimsAfterUnlock` parts; any project
	/// may be trimmed, since the unlock's authentication covers them. Once
	/// it's well below, it raises shrunk rings back to full when `raising`,
	/// which reads every ring's head, so a caller asks only when a ring may
	/// have shrunk.
	static func upkeep(_ storage: some HistoryStorage, raising: Bool) throws -> Upkeep {
		let admission = try HistoryEngine.admission(
			names: storage.historyNames(), operation: .trim, maxTrims: maximumTrimsAfterUnlock)
		let trimmed = try HistoryRecorder.trim(storage, admission.trims).values.reduce(0, +)
		let crowded = admission.creation != "full"
		var mayBeShrunk = raising || trimmed > 0 || crowded
		if mayBeShrunk, !crowded, admission.regrow {
			mayBeShrunk = !(try raiseShrunkRings(storage, existing: admission.afterTrims))
		}
		return Upkeep(records: admission.existing - trimmed, trimmed: trimmed, crowded: crowded, mayBeShrunk: mayBeShrunk)
	}

	/// Raises every shrunk ring's limit back to full; false when a ring
	/// couldn't be read or written, so a later pass tries again.
	private static func raiseShrunkRings(_ storage: some HistoryStorage, existing: Int) throws -> Bool {
		var raisedAll = true
		for vaultId in try storage.historyRings() {
			do {
				guard let head = try storage.historyRecord(HistoryRecorder.account("history-head", vaultId)).map(secret),
					case .upkeep(let writes, let delete) = try HistoryEngine.ring(vaultId: vaultId, head: head, action: .raiseLimit(existing: existing))
				else { continue }
				try HistoryRecorder.apply(storage, writes: writes, delete: delete)
			} catch {
				raisedAll = false
			}
		}
		return raisedAll
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
	private static let newerVersion = HistoryEngine.Failure(
		code: "history.unsupported", message: "A newer LPM CLI or LPM Vault keeps this project's history. Update LPM Vault to use it.")
	private static let damaged = HistoryEngine.Failure(code: "history.damaged", message: "This project's history is damaged.")

	private static func secret(_ data: Data) -> SecretBytes {
		data.withUnsafeBytes { SecretBytes(copying: $0) }
	}
}
