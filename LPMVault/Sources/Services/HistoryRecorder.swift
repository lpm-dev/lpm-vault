import Foundation
import Security

/// What a values write records as, which every values-writing call takes.
struct VaultHistorySource: Sendable, Equatable {
	/// The engine's action names for what the app does.
	enum Action: String, Sendable {
		case set, delete, editKey, renameKey, rawEdit
		case createEnvironment, renameEnvironment, duplicateEnvironment, clearEnvironment, deleteEnvironment
		case `import`, restore, pull, projectImport, rollback, undo
	}

	let action: Action
	var detail = HistoryEngine.ChangeDetail()
	var renames: [HistoryEngine.Rename] = []
	/// The entry's ID, new for each action, so one retried can't be recorded twice.
	let id: String
	/// When the action happened, in milliseconds since 1970: the entry's time.
	let time: Int64

	init(
		_ action: Action,
		detail: HistoryEngine.ChangeDetail = .init(),
		renames: [HistoryEngine.Rename] = [],
		at date: Date = Date()
	) {
		self.action = action
		self.detail = detail
		self.renames = renames
		id = Self.newId()
		time = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
	}

	/// This source's entry, as a later change that refers to it names it.
	func related(side: String) -> HistoryEngine.Related {
		HistoryEngine.Related(id: id, side: side, time: time)
	}

	private static func newId() -> String {
		var bytes = [UInt8](repeating: 0, count: 16)
		let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		precondition(status == errSecSuccess, "The system’s random source failed")
		return bytes.map { String(format: "%02x", $0) }.joined()
	}
}

/// What history made of one operation's change to a project's values.
enum VaultHistoryOutcome: Sendable, Equatable {
	/// Nothing to record: no net change, or a change history doesn't keep.
	case nothing
	/// History is off for the project.
	case off
	/// `crowded` is the service's record count when admission gave a smaller ring.
	case recorded(entry: String?, gap: Bool, crowded: Int?)
	/// `reason` is a stable code: "damaged", "newerVersion", "limit",
	/// "unavailable", "tooManyValues" or "failed"; `message` says why.
	case notRecorded(reason: String, message: String)
}

/// What recording needs from a store, called while its transaction lock is held.
protocol HistoryStorage {
	/// The project's feature marker, as this lock scope last read or wrote it.
	func historyMarker(vaultId: String) throws -> Data?
	/// One companion record, read with the values item's approval.
	func historyRecord(_ account: String) throws -> Data?
	/// Every account name the shared service holds, from a names-only listing.
	func historyNames() throws -> [String]
	/// The access the values item verifiably has, nil when it can't be told.
	func historyApproval(vaultId: String) throws -> HistoryEngine.Approval?
	/// Replaces one record, verified, with the access its class takes: the
	/// values item's for the head and the key, open for parts.
	func historyReplace(_ account: String, with data: Data) throws
	/// Deletes one record, verified.
	func historyDelete(_ account: String) throws
	/// Commits `writes` as one engine-checked journal transaction.
	func historyCommit(_ writes: [HistoryEngine.RecordWrite]) throws
	/// The project's values item as stored, nil when it has none.
	func historyValues(vaultId: String) throws -> Data?
	/// The project's companion account names, from a names-only listing.
	func historyProjectNames(vaultId: String) throws -> [String]
	/// Commits a companion lifecycle plan, transaction by transaction.
	func historyRun(_ plan: CompanionEngine.Plan, vaultId: String) throws
	/// The projects whose rings a creation or growth in `vaultId` may trim
	/// without asking for authentication: its own, and those whose values
	/// item is readable without approval.
	func historyTrimmable(own vaultId: String) throws -> [String]
	/// The projects that have a history ring, from a names-only listing.
	func historyRings() throws -> [String]
	/// The approval the project's values item claims, read once a lock scope,
	/// which history's key maintenance follows, as the LPM CLI's does.
	func historyClaimedApproval(vaultId: String) throws -> HistoryEngine.Approval
	/// Runs `body` with reads that can't ask for approval: one that would
	/// fails instead.
	func historyWithoutApprovalPrompts<T>(_ body: () throws -> T) rethrows -> T
}

/// Records one project's net change, as the LPM CLI does: never failing the
/// values write it follows, which has already committed.
enum HistoryRecorder {
	/// The most times an append plans again, after reading a part or asking
	/// admission; the engine needs at most a few.
	private static let maximumPlans = 8
	/// The most parts one creation or growth trims, as the LPM CLI's do.
	private static let maximumTrimsPerOperation = 16

	static func record(
		_ storage: some HistoryStorage,
		vaultId: String,
		before: Data?,
		after: Data?,
		unreadableBefore: String? = nil,
		source: VaultHistorySource
	) -> VaultHistoryOutcome {
		do {
			return try recordThrowing(
				storage, vaultId: vaultId, before: before, after: after,
				unreadableBefore: unreadableBefore, source: source)
		} catch let failure as HistoryEngine.Failure {
			return .notRecorded(reason: failure.code == "history.damaged" ? "damaged" : "failed", message: failure.message)
		} catch {
			return .notRecorded(reason: "failed", message: String(describing: error))
		}
	}

	private static func recordThrowing(
		_ storage: some HistoryStorage,
		vaultId: String,
		before: Data?,
		after: Data?,
		unreadableBefore: String?,
		source: VaultHistorySource
	) throws -> VaultHistoryOutcome {
		guard let after else { return .nothing }
		if before == after, unreadableBefore == nil { return .nothing }
		let marker = try storage.historyMarker(vaultId: vaultId).map(secret)
		let state = try HistoryEngine.check(vaultId: vaultId, marker: marker, head: nil, key: nil).history
		switch state {
		case "off":
			return .off
		case "removing", "unsupported":
			return .notRecorded(reason: "newerVersion", message: "A newer LPM CLI or LPM Vault keeps this project’s history.")
		case "both":
			return .notRecorded(reason: "damaged", message: "This project’s history is damaged.")
		case "default", "on":
			break
		default:
			return .notRecorded(reason: "failed", message: "The LPM engine read this project’s history as \(state).")
		}
		if let unreadableBefore {
			return .notRecorded(reason: "failed", message: "The values it replaced couldn’t be read: \(unreadableBefore)")
		}
		guard let before else { return .nothing }
		let change = HistoryEngine.Change(
			id: source.id,
			time: source.time,
			action: source.action.rawValue,
			detail: source.detail,
			renames: source.renames)
		let beforeBytes = secret(before)
		let afterBytes = secret(after)
		if state == "default" {
			return try create(storage, vaultId: vaultId, marker: marker, change: change, before: beforeBytes, after: afterBytes)
		}
		return try append(storage, vaultId: vaultId, marker: marker, change: change, before: beforeBytes, after: afterBytes)
	}

	private static func create(
		_ storage: some HistoryStorage,
		vaultId: String,
		marker: SecretBytes?,
		change: HistoryEngine.Change,
		before: SecretBytes,
		after: SecretBytes
	) throws -> VaultHistoryOutcome {
		// The engine says first whether the change is one history keeps, as
		// the LPM CLI asks before admission: a change to no key, or one too
		// large, needs no listing, no probe and no trim. The plan's ring
		// limit and approval are placeholders; a real plan follows.
		switch try HistoryEngine.record(
			vaultId: vaultId, change: change, before: before, after: after,
			recording: .create(marker: marker, approval: .automatic, ringLimit: 1))
		{
		case .noKeyChanges, .unchanged:
			return .nothing
		case .notRecorded(let reason, let message):
			return .notRecorded(reason: reason, message: message)
		case .alreadyRecorded:
			return .recorded(entry: change.id, gap: false, crowded: nil)
		case .write, .needsPrevious, .needsGrowthAdmission:
			break
		}
		let admission = try admit(storage, vaultId: vaultId, operation: .creation).admission
		guard admission.creation != "refused", let ringLimit = admission.ringLimit else {
			return .notRecorded(reason: "limit", message: "This Mac holds too many LPM records to start history for another project.")
		}
		guard let approval = try storage.historyApproval(vaultId: vaultId) else {
			return .notRecorded(reason: "unavailable", message: "The values’ approval couldn’t be confirmed.")
		}
		let plan = try HistoryEngine.record(
			vaultId: vaultId, change: change, before: before, after: after,
			recording: .create(marker: marker, approval: approval, ringLimit: ringLimit))
		switch plan {
		case .noKeyChanges, .unchanged:
			return .nothing
		case .write(let writes, _, let entry, let gap, _, _):
			try storage.historyCommit(writes)
			return .recorded(entry: entry, gap: gap, crowded: admission.creation == "reduced" ? admission.existing : nil)
		case .notRecorded(let reason, let message):
			return .notRecorded(reason: reason, message: message)
		case .alreadyRecorded:
			return .recorded(entry: change.id, gap: false, crowded: nil)
		case .needsPrevious, .needsGrowthAdmission:
			return .notRecorded(reason: "failed", message: "The LPM engine asked for more than creating history needs.")
		}
	}

	private static func append(
		_ storage: some HistoryStorage,
		vaultId: String,
		marker: SecretBytes?,
		change: HistoryEngine.Change,
		before: SecretBytes,
		after: SecretBytes
	) throws -> VaultHistoryOutcome {
		guard let marker else {
			return .notRecorded(reason: "damaged", message: "This project’s history has no marker.")
		}
		var opened = try open(storage, vaultId: vaultId, marker: marker)
		var growth = HistoryEngine.Growth.unasked
		var previous: SecretBytes?
		var crowded: Int?
		var maintained = false
		for _ in 0..<maximumPlans {
			let plan = try HistoryEngine.record(
				vaultId: vaultId, change: change, before: before, after: after,
				recording: .append(
					marker: marker, head: opened.head, key: opened.key, tail: opened.tail,
					previous: previous, growth: growth))
			switch plan {
			case .unchanged, .noKeyChanges:
				return .nothing
			case .alreadyRecorded:
				return .recorded(entry: change.id, gap: false, crowded: nil)
			case .needsPrevious(let part):
				guard let bytes = try storage.historyRecord(account("history", vaultId, part: part)) else {
					return .notRecorded(reason: "damaged", message: "A part of this project’s history is missing.")
				}
				previous = secret(bytes)
			case .needsGrowthAdmission:
				let admitted = try admit(storage, vaultId: vaultId, operation: .growth, growing: opened.head)
				if admitted.trimmedOwn {
					// The trim rewrote this ring's head, so the append plans from it again.
					opened = try open(storage, vaultId: vaultId, marker: marker)
					previous = nil
				}
				growth = admitted.admission.growth ? .allowed : .refused
				if !admitted.admission.growth { crowded = admitted.admission.existing }
			case .write(let writes, let journal, let entry, let gap, _, _):
				if journal {
					try storage.historyCommit(writes)
				} else {
					try apply(storage, writes: writes, delete: [])
				}
				return .recorded(entry: entry, gap: gap, crowded: crowded)
			case .notRecorded("needsMaintenance", _) where !maintained:
				maintained = true
				try finishRunning(storage, vaultId: vaultId, opened: opened)
				opened = try open(storage, vaultId: vaultId, marker: marker)
				previous = nil
			case .notRecorded(let reason, let message):
				return .notRecorded(reason: reason, message: message)
			}
		}
		return .notRecorded(reason: "failed", message: "Recording this change didn’t settle.")
	}

	/// What admission allows for an operation in `vaultId`, after trimming
	/// the largest rings it may write without a prompt when the service would
	/// pass its target, as the LPM CLI does. For growth, `head` is the growing
	/// ring's, whose parts the head doesn't list are deleted first.
	private static func admit(
		_ storage: some HistoryStorage,
		vaultId: String,
		operation: HistoryEngine.AdmissionOperation,
		growing head: SecretBytes? = nil
	) throws -> (admission: HistoryEngine.Admission, trimmedOwn: Bool) {
		if let head { try deleteOrphans(storage, vaultId: vaultId, head: head) }
		let planned = try HistoryEngine.admission(
			names: storage.historyNames(), operation: operation, trimmable: storage.historyTrimmable(own: vaultId),
			maxTrims: maximumTrimsPerOperation, growing: head.map { (vaultId, $0) })
		guard !planned.trims.isEmpty else { return (planned, false) }
		let trimmed = try trim(storage, planned.trims, own: vaultId)
		// Decided again from what the trims left: a ring that can't be read
		// isn't trimmed, and its planned trims mustn't count.
		let trimmedOwn = trimmed[vaultId] != nil
		let current = trimmedOwn ? try storage.historyRecord(account("history-head", vaultId)).map(secret) : head
		let admitted = try HistoryEngine.admission(
			names: storage.historyNames(), operation: operation, trimmable: [], maxTrims: 0,
			growing: current.map { (vaultId, $0) })
		return (admitted, trimmedOwn)
	}

	/// Trims each ring admission planned, oldest part first, never below its
	/// floor. Another project's ring is read without letting macOS ask for
	/// approval, and one that can't be read or is damaged is left for its own
	/// project; trouble with `own`'s ring fails the operation. Returns how
	/// many parts each project's ring lost.
	static func trim(_ storage: some HistoryStorage, _ trims: [HistoryEngine.Trim], own: String? = nil) throws -> [String: Int] {
		var trimmed: [String: Int] = [:]
		for planned in trims {
			for _ in 0..<planned.count {
				let step: (writes: [HistoryEngine.RecordWrite], delete: [String])?
				if planned.vaultId == own {
					step = try trimStep(storage, planned)
				} else {
					step = try? storage.historyWithoutApprovalPrompts { try trimStep(storage, planned) }
				}
				guard let step else { break }
				try apply(storage, writes: step.writes, delete: step.delete)
				trimmed[planned.vaultId, default: 0] += 1
			}
		}
		return trimmed
	}

	/// What trimming `planned`'s oldest part writes and deletes, nil when the
	/// ring has nothing left to trim or its history can't be read.
	private static func trimStep(
		_ storage: some HistoryStorage, _ planned: HistoryEngine.Trim
	) throws -> (writes: [HistoryEngine.RecordWrite], delete: [String])? {
		guard let head = try storage.historyRecord(account("history-head", planned.vaultId)).map(secret) else { return nil }
		var step = try? HistoryEngine.ring(vaultId: planned.vaultId, head: head, action: .trim(floor: planned.floor, tail: nil))
		if case .needsTail? = step {
			guard let key = try storage.historyRecord(account("key", planned.vaultId)).map(secret),
				let marker = try storage.historyMarker(vaultId: planned.vaultId).map(secret),
				let tailPart = try? HistoryEngine.check(vaultId: planned.vaultId, marker: marker, head: head, key: key).tailPart
			else { return nil }
			let tail = try storage.historyRecord(account("history", planned.vaultId, part: tailPart)).map(secret)
			step = try? HistoryEngine.ring(vaultId: planned.vaultId, head: head, action: .trim(floor: planned.floor, tail: (key, tail)))
		}
		guard case .upkeep(let writes, let delete)? = step, !(writes.isEmpty && delete.isEmpty) else { return nil }
		return (writes, delete)
	}

	/// Deletes the parts of a ring its head doesn't list, which a trim that
	/// stopped before its deletion leaves.
	private static func deleteOrphans(_ storage: some HistoryStorage, vaultId: String, head: SecretBytes) throws {
		let inventory = try storage.historyProjectNames(vaultId: vaultId)
		guard case .upkeep(let writes, let delete) = try HistoryEngine.ring(vaultId: vaultId, head: head, action: .orphans(inventory: inventory))
		else { return }
		try apply(storage, writes: writes, delete: delete)
	}

	/// Writes a ring's upkeep in order, then deletes what it frees.
	static func apply(_ storage: some HistoryStorage, writes: [HistoryEngine.RecordWrite], delete: [String]) throws {
		for write in writes {
			guard let bytes = write.bytes else {
				try storage.historyDelete(write.account)
				continue
			}
			try storage.historyReplace(write.account, with: bytes.withUnsafeBytes { Data($0) })
		}
		for account in delete { try storage.historyDelete(account) }
	}

	private struct Opened {
		let head: SecretBytes
		let key: SecretBytes
		let tail: SecretBytes?
	}

	/// The head, the key and the tail as stored now, once the key is
	/// maintained; the engine says which part is the tail.
	private static func open(_ storage: some HistoryStorage, vaultId: String, marker: SecretBytes) throws -> Opened {
		guard let (head, key, _) = try maintained(storage, vaultId: vaultId),
			let tailPart = try HistoryEngine.check(vaultId: vaultId, marker: marker, head: head, key: key).tailPart
		else { throw damagedHead }
		let tail = try storage.historyRecord(account("history", vaultId, part: tailPart)).map(secret)
		return Opened(head: head, key: key, tail: tail)
	}

	/// The head and the key once the key is maintained as every LPM history
	/// operation maintains it first: a rotation or removal left running is
	/// finished, a key made while approval was off is rotated once the values
	/// claim approval, and a lowered approval is recorded. Only the head and
	/// the key are read when nothing needs doing. Nil before any history.
	/// `read` is the head and the key the caller just read, which aren't read
	/// again when nothing needs doing.
	static func maintained(
		_ storage: some HistoryStorage, vaultId: String, read: (head: SecretBytes, key: SecretBytes)? = nil
	) throws -> (head: SecretBytes, key: SecretBytes, changed: Bool)? {
		guard let read = try read ?? headAndKey(storage, vaultId: vaultId) else { return nil }
		let claimed = try storage.historyClaimedApproval(vaultId: vaultId)
		let check = try HistoryEngine.maintenance(try listed(vaultId: vaultId, read.head, read.key), step: .check(approval: claimed))
		guard check.needsFinishing || check.key != "nothing" else { return (read.head, read.key, false) }
		if check.needsFinishing { try finishRunning(storage, vaultId: vaultId) }
		guard let finished = try headAndKey(storage, vaultId: vaultId) else { throw damagedHead }
		let listed = try listed(vaultId: vaultId, finished.head, finished.key)
		let key = try HistoryEngine.maintenance(listed, step: .check(approval: claimed))
		switch key.key {
		case "lower":
			try apply(storage, writes: key.writes, delete: [])
		case "rotate":
			try storage.historyCommit(try HistoryEngine.maintenance(listed, step: .start(approval: claimed)).writes)
			try finishRunning(storage, vaultId: vaultId)
		default:
			break
		}
		guard let maintained = try headAndKey(storage, vaultId: vaultId) else { throw damagedHead }
		return (maintained.head, maintained.key, true)
	}

	private static func headAndKey(_ storage: some HistoryStorage, vaultId: String) throws -> (head: SecretBytes, key: SecretBytes)? {
		guard let head = try storage.historyRecord(account("history-head", vaultId)).map(secret) else { return nil }
		guard let key = try storage.historyRecord(account("key", vaultId)).map(secret) else { throw damagedHead }
		return (head, key)
	}

	/// The history with the parts its head lists and none of their bytes,
	/// which a check of the key needs no more than.
	private static func listed(vaultId: String, _ head: SecretBytes, _ key: SecretBytes) throws -> HistoryEngine.Stored {
		guard let parts = try? head.withUnsafeBytes({ try JSONDecoder().decode(HeadParts.self, from: Data($0)) }).parts else {
			throw damagedHead
		}
		return HistoryEngine.Stored(vaultId: vaultId, head: head, key: key, parts: parts.map { ($0, nil) })
	}

	private static let damagedHead = HistoryEngine.Failure(
		code: "history.damaged", message: "This project’s history head or key can’t be read.")

	private struct HeadParts: Decodable { let parts: [Int] }

	/// The stored history with every part the head lists, as read now; a
	/// part in `known` is taken from it instead of read again.
	static func stored(
		_ storage: some HistoryStorage,
		vaultId: String,
		head: SecretBytes,
		key: SecretBytes,
		known: [Int: SecretBytes] = [:]
	) throws -> HistoryEngine.Stored {
		guard let parts = try? head.withUnsafeBytes({ try JSONDecoder().decode(HeadParts.self, from: Data($0)) }).parts else {
			throw HistoryEngine.Failure(code: "history.damaged", message: "This project’s history head can’t be read.")
		}
		var read: [(part: Int, bytes: SecretBytes?)] = []
		read.reserveCapacity(parts.count)
		for part in parts {
			if let bytes = known[part] {
				read.append((part, bytes))
			} else {
				read.append((part, try storage.historyRecord(account("history", vaultId, part: part)).map(secret)))
			}
		}
		return HistoryEngine.Stored(vaultId: vaultId, head: head, key: key, parts: read)
	}

	/// Finishes a key rotation or a removal left running, reading the head
	/// and the key as stored now. `known` holds parts the caller has just
	/// read and nothing has changed since, which aren't read again.
	static func finishRunning(_ storage: some HistoryStorage, vaultId: String, known: [Int: SecretBytes] = [:]) throws {
		guard let head = try storage.historyRecord(account("history-head", vaultId)).map(secret),
			let key = try storage.historyRecord(account("key", vaultId)).map(secret)
		else { throw HistoryEngine.Failure(code: "history.damaged", message: "This project’s history head or key can’t be read.") }
		try finishRunning(storage, vaultId: vaultId, opened: Opened(head: head, key: key, tail: nil), known: known)
	}

	/// Finishes a key rotation or a removal another operation left running,
	/// as every history operation does before its own. Each part is read
	/// once and rotated on its own; the rotated bytes stay in memory for the
	/// step that finishes, since each write was verified as it was made.
	private static func finishRunning(
		_ storage: some HistoryStorage, vaultId: String, opened: Opened, known: [Int: SecretBytes] = [:]
	) throws {
		let approval = try storage.historyClaimedApproval(vaultId: vaultId)
		let stored = try stored(storage, vaultId: vaultId, head: opened.head, key: opened.key, known: known)
		let check = try HistoryEngine.maintenance(stored, step: .check(approval: approval))
		guard check.needsFinishing else { return }
		var parts = stored.parts
		for part in check.parts {
			guard let index = parts.firstIndex(where: { $0.part == part }) else { continue }
			let single = HistoryEngine.Stored(vaultId: vaultId, head: stored.head, key: stored.key, parts: [parts[index]])
			let rotated = try HistoryEngine.maintenance(single, step: .rotatePart(part))
			let partAccount = try account("history", vaultId, part: part)
			for write in rotated.writes {
				guard let bytes = write.bytes else { continue }
				try storage.historyReplace(write.account, with: bytes.withUnsafeBytes { Data($0) })
				if write.account == partAccount { parts[index].bytes = bytes }
			}
		}
		let rotatedStore = HistoryEngine.Stored(vaultId: vaultId, head: stored.head, key: stored.key, parts: parts)
		let finished = try HistoryEngine.maintenance(rotatedStore, step: .finish)
		try storage.historyCommit(finished.writes)
	}

	static func account(_ kind: String, _ vaultId: String, part: Int? = nil) throws -> String {
		do {
			return try CompanionEngine.accountNames([.init(role: .record, vaultId: vaultId, kind: kind, part: part)])[0]
		} catch {
			throw HistoryEngine.Failure(code: error.code, message: error.message)
		}
	}

	private static func secret(_ data: Data) -> SecretBytes {
		data.withUnsafeBytes { SecretBytes(copying: $0) }
	}
}
