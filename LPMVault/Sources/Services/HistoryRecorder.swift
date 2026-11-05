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
		precondition(status == errSecSuccess, "The system's random source failed")
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
	/// Replaces one record, verified, with the values item's access.
	func historyReplace(_ account: String, with data: Data) throws
	/// Deletes one record, verified.
	func historyDelete(_ account: String) throws
	/// Commits `writes` as one engine-checked journal transaction.
	func historyCommit(_ writes: [HistoryEngine.RecordWrite]) throws
}

/// Records one project's net change, as the LPM CLI does: never failing the
/// values write it follows, which has already committed.
enum HistoryRecorder {
	/// The most times an append plans again, after reading a part or asking
	/// admission; the engine needs at most a few.
	private static let maximumPlans = 8

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
			return .notRecorded(reason: "newerVersion", message: "A newer LPM CLI or LPM Vault keeps this project's history.")
		case "both":
			return .notRecorded(reason: "damaged", message: "This project's history is damaged.")
		case "default", "on":
			break
		default:
			return .notRecorded(reason: "failed", message: "The LPM engine read this project's history as \(state).")
		}
		if let unreadableBefore {
			return .notRecorded(reason: "failed", message: "The values it replaced couldn't be read: \(unreadableBefore)")
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
		let admission = try HistoryEngine.admission(names: storage.historyNames(), operation: .creation)
		guard admission.creation != "refused", let ringLimit = admission.ringLimit else {
			return .notRecorded(reason: "limit", message: "This Mac holds too many LPM records to start history for another project.")
		}
		guard let approval = try storage.historyApproval(vaultId: vaultId) else {
			return .notRecorded(reason: "unavailable", message: "The values' approval couldn't be confirmed.")
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
			return .notRecorded(reason: "damaged", message: "This project's history has no marker.")
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
					return .notRecorded(reason: "damaged", message: "A part of this project's history is missing.")
				}
				previous = secret(bytes)
			case .needsGrowthAdmission:
				let admission = try HistoryEngine.admission(
					names: storage.historyNames(), operation: .growth, growing: (vaultId, opened.head))
				growth = admission.growth ? .allowed : .refused
				if !admission.growth { crowded = admission.existing }
			case .write(let writes, let journal, let entry, let gap, _, _):
				if journal {
					try storage.historyCommit(writes)
				} else {
					for write in writes {
						guard let bytes = write.bytes else {
							try storage.historyDelete(write.account)
							continue
						}
						try storage.historyReplace(write.account, with: bytes.withUnsafeBytes { Data($0) })
					}
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
		return .notRecorded(reason: "failed", message: "Recording this change didn't settle.")
	}

	private struct Opened {
		let head: SecretBytes
		let key: SecretBytes
		let tail: SecretBytes?
	}

	/// The head, the key and the tail as stored now; the engine says which
	/// part is the tail.
	private static func open(_ storage: some HistoryStorage, vaultId: String, marker: SecretBytes) throws -> Opened {
		guard let head = try storage.historyRecord(account("history-head", vaultId)).map(secret),
			let key = try storage.historyRecord(account("key", vaultId)).map(secret),
			let tailPart = try HistoryEngine.check(vaultId: vaultId, marker: marker, head: head, key: key).tailPart
		else { throw HistoryEngine.Failure(code: "history.damaged", message: "This project's history head or key can't be read.") }
		let tail = try storage.historyRecord(account("history", vaultId, part: tailPart)).map(secret)
		return Opened(head: head, key: key, tail: tail)
	}

	private struct HeadParts: Decodable { let parts: [Int] }

	/// The stored history with every part the head lists, as read now.
	static func stored(_ storage: some HistoryStorage, vaultId: String, head: SecretBytes, key: SecretBytes) throws -> HistoryEngine.Stored {
		guard let parts = try? head.withUnsafeBytes({ try JSONDecoder().decode(HeadParts.self, from: Data($0)) }).parts else {
			throw HistoryEngine.Failure(code: "history.damaged", message: "This project's history head can't be read.")
		}
		var read: [(part: Int, bytes: SecretBytes?)] = []
		read.reserveCapacity(parts.count)
		for part in parts {
			read.append((part, try storage.historyRecord(account("history", vaultId, part: part)).map(secret)))
		}
		return HistoryEngine.Stored(vaultId: vaultId, head: head, key: key, parts: read)
	}

	/// Finishes a key rotation or a removal another operation left running,
	/// as every history operation does before its own.
	private static func finishRunning(_ storage: some HistoryStorage, vaultId: String, opened: Opened) throws {
		guard let approval = try storage.historyApproval(vaultId: vaultId) else {
			throw HistoryEngine.Failure(code: "history.unavailable", message: "The values' approval couldn't be confirmed.")
		}
		var stored = try stored(storage, vaultId: vaultId, head: opened.head, key: opened.key)
		let check = try HistoryEngine.maintenance(stored, step: .check(approval: approval))
		guard check.needsFinishing else { return }
		for part in check.parts {
			let rotated = try HistoryEngine.maintenance(stored, step: .rotatePart(part))
			for write in rotated.writes {
				guard let bytes = write.bytes else { continue }
				try storage.historyReplace(write.account, with: bytes.withUnsafeBytes { Data($0) })
			}
			stored = try Self.stored(storage, vaultId: vaultId, head: stored.head, key: stored.key)
		}
		let finished = try HistoryEngine.maintenance(stored, step: .finish)
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
