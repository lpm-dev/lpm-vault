import Foundation
import LPMEnv

/// Local history's engine calls, decided exactly as the LPM CLI decides them.
/// Nothing here reads or writes a store.
///
/// Each call takes one frame and answers with one: JSON for everything that
/// isn't secret, and blobs, which the JSON names by index from 1, for values,
/// values payloads, the head and the key record. Blobs are `SecretBytes` both
/// ways, so every copy of a value the app holds is zeroed when released.
enum HistoryEngine {
	struct Failure: Error, Equatable, Sendable {
		let code: String
		let message: String
	}

	/// lpm_env.h's `LPM_ENV_HISTORY_INPUT_LIMIT`.
	static let inputLimit = 4 * 1024 * 1024
	/// The most blobs a frame carries.
	static let maximumBlobs = 64
	/// An answer is built from its request, so it stays near the input
	/// limit; this bounds a malformed one.
	static let outputLimit = 16 * 1024 * 1024

	private static let magic: [UInt8] = Array("LPMF".utf8)
	private static let frameVersion: UInt8 = 1

	/// The blobs of a request being built, or of an answer.
	struct Blobs: Sendable {
		private(set) var items: [SecretBytes] = []

		/// Adds `bytes` and gives the index the JSON names it by.
		@discardableResult
		mutating func add(_ bytes: SecretBytes) -> Int {
			items.append(bytes)
			return items.count
		}

		/// The blob the JSON names `index`, if there is one.
		subscript(index: Int) -> SecretBytes? {
			index >= 1 && index <= items.count ? items[index - 1] : nil
		}
	}

	/// An answer: its JSON, decoded, and its blobs.
	struct Answer<Response: Sendable>: Sendable {
		let response: Response
		let blobs: Blobs
	}

	/// Calls `function` with `request` and `blobs` framed, and decodes its answer.
	static func call<Request: Encodable, Response: Decodable>(
		_ function: (UnsafePointer<UInt8>?, Int) -> LPMEnvResult,
		_ request: Request,
		blobs: Blobs = Blobs()
	) throws(Failure) -> Answer<Response> {
		guard EnvEngineABI.matches else {
			throw Failure(code: "env.abi_mismatch", message: "The bundled LPM engine is not the version this app expects.")
		}
		let json: Data
		do { json = try JSONEncoder().encode(request) } catch {
			throw Failure(code: "history.invalid_input", message: "The request couldn't be encoded.")
		}
		let input = try frame(json: json, blobs: blobs.items)
		var result = input.withUnsafeBytes { bytes in
			function(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
		}
		defer { lpm_env_release(result) }
		guard let data = result.data, result.length > 0, result.length <= outputLimit else { throw unreadable }
		let output = UnsafeRawBufferPointer(start: data, count: result.length)
		guard result.status == 0 else { throw refusal(output) }
		let (answerJSON, answerBlobs) = try decodeFrame(output)
		lpm_env_clear_output(&result)
		do {
			return Answer(response: try JSONDecoder().decode(Response.self, from: answerJSON), blobs: answerBlobs)
		} catch {
			throw unreadable
		}
	}

	/// `json` and `blobs` as one input frame, built where it can be zeroed.
	static func frame(json: Data, blobs: [SecretBytes]) throws(Failure) -> SecretBytes {
		guard blobs.count <= maximumBlobs else { throw tooLarge }
		let total = blobs.reduce(magic.count + 1 + 4 + 4 + json.count) { $0 + 4 + $1.count }
		guard total <= inputLimit else { throw tooLarge }
		return SecretBytes(count: total) { storage in
			var offset = 0
			func put(_ bytes: UnsafeRawBufferPointer) {
				guard let source = bytes.baseAddress, !bytes.isEmpty else { return }
				storage.baseAddress!.advanced(by: offset).copyMemory(from: source, byteCount: bytes.count)
				offset += bytes.count
			}
			func putLength(_ length: Int) {
				withUnsafeBytes(of: UInt32(length).bigEndian) { put($0) }
			}
			magic.withUnsafeBytes { put($0) }
			withUnsafeBytes(of: frameVersion) { put($0) }
			putLength(1 + blobs.count)
			putLength(json.count)
			json.withUnsafeBytes { put($0) }
			for blob in blobs {
				putLength(blob.count)
				blob.withUnsafeBytes { put($0) }
			}
		}
	}

	/// An answer frame's JSON and its blobs, each copied out of the engine's
	/// buffer, which it zeroes when released.
	static func decodeFrame(_ bytes: UnsafeRawBufferPointer) throws(Failure) -> (Data, Blobs) {
		var offset = 0
		func take(_ count: Int) throws(Failure) -> UnsafeRawBufferPointer {
			guard count <= bytes.count - offset else { throw unreadable }
			defer { offset += count }
			return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count])
		}
		func length() throws(Failure) -> Int {
			let field = try take(4)
			return Int(field.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
		}
		guard try Array(take(magic.count)) == magic, try take(1)[0] == frameVersion else { throw unreadable }
		// The blob limit is the engine's for requests; an answer carries one
		// blob per value it holds, as many as its byte limit allows.
		let count = try length()
		guard count >= 1 else { throw unreadable }
		let json = Data(try take(try length()))
		var blobs = Blobs()
		for _ in 1..<count {
			blobs.add(SecretBytes(copying: try take(try length())))
		}
		guard offset == bytes.count else { throw unreadable }
		return (json, blobs)
	}

	private struct Refusal: Decodable {
		let code: String
		let message: String?
	}

	private static func refusal(_ output: UnsafeRawBufferPointer) -> Failure {
		guard let refusal = try? JSONDecoder().decode(Refusal.self, from: Data(output)) else { return unreadable }
		return Failure(code: refusal.code, message: refusal.message ?? "The LPM engine refused (\(refusal.code)).")
	}

	private static let unreadable = Failure(code: "env.engine_internal", message: "The LPM engine returned an unreadable answer.")
	private static let tooLarge = Failure(code: "history.too_large", message: "This project's history is too large to read at once.")
}

// MARK: - Reading

extension HistoryEngine {
	/// One project's history as stored: what every reading call sends.
	struct Stored: Sendable {
		let vaultId: String
		let head: SecretBytes
		let key: SecretBytes
		/// Each part the head lists, with its bytes, or nil when its account
		/// is absent.
		let parts: [(part: Int, bytes: SecretBytes?)]
	}

	/// A reading call's request: the stored history and the current values
	/// payload, then `rest`, the call's own fields, in the same object.
	private struct ReadingRequest<Rest: Encodable>: Encodable {
		struct Part: Encodable {
			let part: Int
			let blob: Int?
		}

		let vaultId: String
		let head: Int
		let key: Int
		let values: Int?
		let parts: [Part]
		let rest: Rest

		init(_ stored: Stored, values: SecretBytes?, rest: Rest, blobs: inout Blobs) {
			vaultId = stored.vaultId
			head = blobs.add(stored.head)
			key = blobs.add(stored.key)
			self.values = values.map { blobs.add($0) }
			parts = stored.parts.map { Part(part: $0.part, blob: $0.bytes.map { bytes in blobs.add(bytes) }) }
			self.rest = rest
		}

		private enum CodingKeys: String, CodingKey {
			case vaultId, head, key, values, parts
		}

		func encode(to encoder: any Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(vaultId, forKey: .vaultId)
			try container.encode(head, forKey: .head)
			try container.encode(key, forKey: .key)
			try container.encodeIfPresent(values, forKey: .values)
			try container.encode(parts, forKey: .parts)
			try rest.encode(to: encoder)
		}
	}

	struct KeyChange: Decodable, Sendable, Equatable {
		let key: String
		/// "added", "changed", "removed" or "renamed".
		let change: String
		/// "absent", "value", "digestOnly" or "removed", for each side.
		let before: String
		let after: String
		let renamedFrom: String?
	}

	struct EnvironmentChange: Decodable, Sendable, Equatable {
		let name: String
		/// "unchanged", "created", "removed" or "renamed".
		let change: String
		let renamedFrom: String?
		/// How many keys an oversized change touched, when it kept only that.
		let keyCount: Int?
		let keys: [KeyChange]?
	}

	/// Where pulled values came from: "personal", or `{"org": slug}`.
	enum Remote: Codable, Sendable, Equatable {
		case personal
		case org(String)

		private struct Org: Codable { let org: String }

		init(from decoder: any Decoder) throws {
			if let org = try? Org(from: decoder) {
				self = .org(org.org)
			} else if try decoder.singleValueContainer().decode(String.self) == "personal" {
				self = .personal
			} else {
				throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown remote"))
			}
		}

		func encode(to encoder: any Encoder) throws {
			switch self {
			case .personal:
				var container = encoder.singleValueContainer()
				try container.encode("personal")
			case .org(let slug):
				try Org(org: slug).encode(to: encoder)
			}
		}
	}

	struct Related: Codable, Sendable, Equatable {
		let id: String
		/// "before" or "after".
		let side: String
		let time: Int64
	}

	/// An entry's values, by blob index: one list per environment, in its
	/// keys' order.
	struct EntryValues: Decodable, Sendable, Equatable {
		let before: Int?
		let after: Int?
	}

	struct Entry: Decodable, Sendable, Equatable {
		/// 32 hex digits.
		let id: String
		let seq: UInt64
		/// Milliseconds since 1970.
		let time: Int64
		/// "app", "cli" or "outside".
		let actor: String
		let action: String
		/// The source group: "app", "cli", "import", "restore", "pull",
		/// "rollback" or "outside".
		let source: String
		let since: Int64?
		let valuesKept: Bool
		let oversized: Bool
		let fileName: String?
		let pasted: Bool
		let remote: Remote?
		let remoteVersion: UInt64?
		let platform: String?
		let related: Related?
		let environments: [EnvironmentChange]
		let values: [[EntryValues]]?
	}

	enum Row: Decodable, Sendable, Equatable {
		case entry(Entry)
		/// A part that couldn't be read, between the entries around it.
		case unreadable(part: Int, after: Int64?, before: Int64?)

		private struct Unreadable: Decodable {
			let unreadable: Bool
			let part: Int
			let after: Int64?
			let before: Int64?
		}

		init(from decoder: any Decoder) throws {
			if let unreadable = try? Unreadable(from: decoder), unreadable.unreadable {
				self = .unreadable(part: unreadable.part, after: unreadable.after, before: unreadable.before)
			} else {
				self = .entry(try Entry(from: decoder))
			}
		}
	}

	struct LiveGap: Decodable, Sendable, Equatable {
		struct Environment: Decodable, Sendable, Equatable {
			let name: String
			let keys: [String]
		}

		let since: Int64?
		let environments: [Environment]
	}

	struct EnvironmentName: Decodable, Sendable, Equatable {
		let name: String
		let deletedAt: Int64?
	}

	struct Timeline: Decodable, Sendable, Equatable {
		let rows: [Row]
		let liveGap: LiveGap?
		let readable: Int
		let counts: [String: Int]
		let oldest: Int64?
		let damagedTail: Bool
		let unreadableParts: Int
		let environments: [EnvironmentName]
		let keyGeneration: UInt32
	}

	struct Filter: Encodable, Sendable, Equatable {
		var environment: String?
		var exactKey: String?
		var keyContains: String?
		var source: String?
		var limit: Int?
	}

	/// The timeline, newest first, names and kinds only. `values`, the
	/// current values payload, gives the live gap.
	static func timeline(_ stored: Stored, values: SecretBytes?, filter: Filter? = nil) throws(Failure) -> Timeline {
		struct Rest: Encodable { let filter: Filter? }
		var blobs = Blobs()
		let request = ReadingRequest(stored, values: values, rest: Rest(filter: filter), blobs: &blobs)
		let answer: Answer<Timeline> = try call(lpm_env_history_timeline, request, blobs: blobs)
		return answer.response
	}

	/// Entries with their values, each side a blob of the answer.
	static func reveal(_ stored: Stored, ids: [String]) throws(Failure) -> Answer<[Entry]> {
		struct Rest: Encodable { let ids: [String] }
		struct Response: Decodable { let entries: [Entry] }
		var blobs = Blobs()
		let request = ReadingRequest(stored, values: nil, rest: Rest(ids: ids), blobs: &blobs)
		let answer: Answer<Response> = try call(lpm_env_history_reveal, request, blobs: blobs)
		return Answer(response: answer.response.entries, blobs: answer.blobs)
	}
}

// MARK: - State

extension HistoryEngine {
	struct Damage: Decodable, Sendable, Equatable {
		let kind: String
		let reason: String
		let description: String
	}

	struct Check: Decodable, Sendable, Equatable {
		/// "default", "on", "off", "removing", "unsupported" or "both".
		let history: String
		let version: Int?
		let tailPart: Int?
		/// Parts to read and pass before the check can say.
		let needsParts: [Int]?
		let damage: [Damage]?
	}

	/// What the marker says and what's damaged beyond a listing.
	static func check(
		vaultId: String,
		marker: SecretBytes?,
		head: SecretBytes?,
		key: SecretBytes?,
		parts: [(part: Int, bytes: SecretBytes?)] = []
	) throws(Failure) -> Check {
		struct Part: Encodable { let part: Int; let blob: Int? }
		struct Request: Encodable {
			let vaultId: String
			let marker: Int?
			let head: Int?
			let key: Int?
			let parts: [Part]
		}
		var blobs = Blobs()
		let request = Request(
			vaultId: vaultId,
			marker: marker.map { blobs.add($0) },
			head: head.map { blobs.add($0) },
			key: key.map { blobs.add($0) },
			parts: parts.map { Part(part: $0.part, blob: $0.bytes.map { bytes in blobs.add(bytes) }) })
		let answer: Answer<Check> = try call(lpm_env_history_check, request, blobs: blobs)
		return answer.response
	}
}

// MARK: - Writes

extension HistoryEngine {
	/// A record to write: its account and the answer blob with its bytes.
	struct Write: Decodable, Sendable, Equatable {
		let account: String
		let blob: Int
	}

	/// A record write, or a deletion, with its bytes taken out of the answer.
	struct RecordWrite: Sendable {
		let account: String
		/// nil deletes the record.
		let bytes: SecretBytes?
	}

	/// `writes` with their bytes, or nil when an index names no blob.
	static func resolve(_ writes: [Write], in blobs: Blobs) -> [RecordWrite]? {
		var resolved: [RecordWrite] = []
		resolved.reserveCapacity(writes.count)
		for write in writes {
			guard let bytes = blobs[write.blob] else { return nil }
			resolved.append(RecordWrite(account: write.account, bytes: bytes))
		}
		return resolved
	}
}

// MARK: - Recording

extension HistoryEngine {
	struct ChangeDetail: Encodable, Sendable, Equatable {
		var fileName: String?
		var pasted = false
		var remote: Remote?
		var remoteVersion: UInt64?
		var platform: String?
		var related: Related?
	}

	enum Rename: Encodable, Sendable, Equatable {
		case environment(from: String, to: String)
		case key(environment: String, from: String, to: String)

		func encode(to encoder: any Encoder) throws {
			switch self {
			case .environment(let from, let to):
				try ["environment": ["from": from, "to": to]].encode(to: encoder)
			case .key(let environment, let from, let to):
				try ["key": ["environment": environment, "from": from, "to": to]].encode(to: encoder)
			}
		}
	}

	/// One action's change, which history records as one entry.
	struct Change: Encodable, Sendable, Equatable {
		/// 32 hex digits, new for each action.
		let id: String
		/// Milliseconds since 1970.
		let time: Int64
		let action: String
		var detail = ChangeDetail()
		var renames: [Rename] = []
	}

	/// The access the values item claims, which a new key record takes.
	enum Approval: String, Encodable, Sendable {
		case automatic, `protected`, fileStore
	}

	enum Growth: String, Encodable, Sendable {
		case unasked, allowed, refused
	}

	/// Whether the change creates history or appends to it, with what each
	/// needs as stored, read in the same lock as the values.
	enum Recording: Sendable {
		case create(marker: SecretBytes?, approval: Approval, ringLimit: Int)
		case append(marker: SecretBytes, head: SecretBytes, key: SecretBytes, tail: SecretBytes?, previous: SecretBytes?, growth: Growth)
	}

	/// What recording a change comes to.
	enum Record: Sendable {
		case noKeyChanges
		case unchanged
		case alreadyRecorded
		/// Read this part, pass it as `previous` and record again.
		case needsPrevious(part: Int)
		/// Ask admission whether the ring may grow, then record again.
		case needsGrowthAdmission
		/// Write these, as one journal transaction when `journal`, else each
		/// as a verified replacement in order.
		case write(writes: [RecordWrite], journal: Bool, entry: String, gap: Bool, valuesKept: Bool, shape: String?)
		/// History doesn't record this change; `reason` is the engine's code.
		case notRecorded(reason: String, message: String)
	}

	/// Plans recording `change`, whose values were `before` and are `after`.
	static func record(vaultId: String, change: Change, before: SecretBytes, after: SecretBytes, recording: Recording) throws(Failure) -> Record {
		struct Create: Encodable {
			let marker: Int?
			let approval: Approval
			let ringLimit: Int
		}
		struct Append: Encodable {
			let marker: Int
			let head: Int
			let key: Int
			let tail: Int?
			let previous: Int?
			let growth: Growth
		}
		struct Request: Encodable {
			let vaultId: String
			let change: Change
			let before: Int
			let after: Int
			let create: Create?
			let append: Append?
		}
		struct Response: Decodable {
			let result: String
			let reason: String?
			let message: String?
			let part: Int?
			let writes: [Write]?
			let journal: Bool?
			let entry: String?
			let gap: Bool?
			let valuesKept: Bool?
			let shape: String?
		}
		var blobs = Blobs()
		let beforeIndex = blobs.add(before)
		let afterIndex = blobs.add(after)
		var create: Create?
		var append: Append?
		switch recording {
		case .create(let marker, let approval, let ringLimit):
			create = Create(marker: marker.map { blobs.add($0) }, approval: approval, ringLimit: ringLimit)
		case .append(let marker, let head, let key, let tail, let previous, let growth):
			append = Append(
				marker: blobs.add(marker), head: blobs.add(head), key: blobs.add(key),
				tail: tail.map { blobs.add($0) }, previous: previous.map { blobs.add($0) }, growth: growth)
		}
		let answer: Answer<Response> = try call(
			lpm_env_history_record,
			Request(vaultId: vaultId, change: change, before: beforeIndex, after: afterIndex, create: create, append: append),
			blobs: blobs)
		let response = answer.response
		switch response.result {
		case "noKeyChanges": return .noKeyChanges
		case "unchanged": return .unchanged
		case "alreadyRecorded": return .alreadyRecorded
		case "needsPrevious":
			guard let part = response.part else { throw unreadable }
			return .needsPrevious(part: part)
		case "needsGrowthAdmission": return .needsGrowthAdmission
		case "write":
			guard let writes = response.writes.flatMap({ resolve($0, in: answer.blobs) }), let journal = response.journal,
				let entry = response.entry, let gap = response.gap, let valuesKept = response.valuesKept
			else { throw unreadable }
			return .write(writes: writes, journal: journal, entry: entry, gap: gap, valuesKept: valuesKept, shape: response.shape)
		case "notRecorded":
			guard let reason = response.reason else { throw unreadable }
			return .notRecorded(reason: reason, message: response.message ?? reason)
		default:
			throw unreadable
		}
	}
}

// MARK: - Rollback

extension HistoryEngine {
	enum RollbackTarget: Sendable, Equatable {
		/// An environment back to its state right before or after `entry`,
		/// named as it was then, or, with `namedNow`, as it is now.
		case environment(String, entry: String, side: String, namedNow: Bool = false)
		/// One key back to its value before `entry`.
		case key(String, environment: String, entry: String)
		/// Each key `entry` changed, back to its value before it; `only`
		/// narrows it to one environment.
		case undo(entry: String, only: String?)
	}

	struct Gap: Decodable, Sendable, Equatable {
		let since: Int64?
		let until: Int64?
	}

	struct Pulled: Decodable, Sendable, Equatable {
		let remote: Remote
		let version: UInt64?
		let time: Int64
	}

	struct ChangedAgain: Decodable, Sendable, Equatable {
		let time: Int64
		let actor: String
		let action: String
	}

	struct PlanRow: Decodable, Sendable, Equatable {
		let key: String
		/// "changed", "added", "removed" or "unknown".
		let change: String
		/// Whether applying the row changes a value.
		let changes: Bool
		/// Why an unknown row's earlier value isn't known.
		let reason: String?
		/// The value now and the value the row puts back, as answer blobs.
		let current: Int?
		let target: Int?
		let gaps: [Gap]
		let pulled: Pulled?
		let changedAgain: ChangedAgain?
		/// Rows of one renamed key, which apply together.
		let linked: [String]
	}

	struct PlanEnvironment: Decodable, Sendable, Equatable {
		let current: String?
		let target: String?
		let recreates: Bool
		let offersDeletion: Bool
		let renames: Bool
		let unnamedKeys: String?
		let rows: [PlanRow]
	}

	struct Point: Decodable, Sendable, Equatable {
		let entry: String
		let side: String
		let time: Int64

		/// The point as an entry that rolls back to it names it.
		var related: Related { Related(id: entry, side: side, time: time) }
	}

	struct Plan: Decodable, Sendable, Equatable {
		let kind: String
		let point: Point
		let generation: UInt32
		let fingerprint: String
		let environments: [PlanEnvironment]
	}

	/// What applying a rollback writes: one values write that removes every
	/// `renamedFrom` and each deleted environment first, then stores the rest.
	struct RollbackWrite: Sendable {
		let name: String
		let renamedFrom: String?
		/// nil deletes the environment.
		let values: [(key: String, value: SecretBytes)]?
	}

	private struct RollbackRequest: Encodable {
		let kind: String
		let entry: String
		let environment: String?
		let key: String?
		let side: String?
		var environmentNamed: String?

		init(_ target: RollbackTarget) {
			switch target {
			case .environment(let environment, let entry, let side, let namedNow):
				(kind, self.entry, self.environment, key, self.side) = ("environment", entry, environment, nil, side)
				if namedNow { environmentNamed = "now" }
			case .key(let key, let environment, let entry):
				(kind, self.entry, self.environment, self.key, side) = ("key", entry, environment, key, nil)
			case .undo(let entry, let only):
				(kind, self.entry, environment, key, side) = ("undo", entry, only, nil, nil)
			}
		}
	}

	/// Plans rolling back to `target` from `values`, the payload now.
	static func planRollback(_ stored: Stored, values: SecretBytes, target: RollbackTarget) throws(Failure) -> Answer<Plan> {
		struct Rest: Encodable { let rollback: RollbackRequest }
		struct Response: Decodable { let plan: Plan }
		var blobs = Blobs()
		let request = ReadingRequest(stored, values: values, rest: Rest(rollback: RollbackRequest(target)), blobs: &blobs)
		let answer: Answer<Response> = try call(lpm_env_history_rollback, request, blobs: blobs)
		return Answer(response: answer.response.plan, blobs: answer.blobs)
	}

	/// Applies the plan whose fingerprint is `fingerprint`, which the engine
	/// plans again and refuses with `history.changed_since_review` unless
	/// it and `values` still match. `skipped` holds environment and row
	/// indexes; `keepEmpty` environment indexes.
	static func applyRollback(
		_ stored: Stored,
		values: SecretBytes,
		target: RollbackTarget,
		fingerprint: String,
		skipped: [(environment: Int, row: Int)] = [],
		keepEmpty: [Int] = []
	) throws(Failure) -> [RollbackWrite] {
		struct Apply: Encodable {
			let fingerprint: String
			let skipped: [[Int]]
			let keepEmpty: [Int]
		}
		struct Rest: Encodable {
			let rollback: RollbackRequest
			let apply: Apply
		}
		struct Value: Decodable { let key: String; let value: Int }
		struct Write: Decodable {
			let name: String
			let renamedFrom: String?
			let values: [Value]?
		}
		struct Response: Decodable { let writes: [Write] }
		var blobs = Blobs()
		let rest = Rest(
			rollback: RollbackRequest(target),
			apply: Apply(fingerprint: fingerprint, skipped: skipped.map { [$0.environment, $0.row] }, keepEmpty: keepEmpty))
		let request = ReadingRequest(stored, values: values, rest: rest, blobs: &blobs)
		let answer: Answer<Response> = try call(lpm_env_history_rollback, request, blobs: blobs)
		var writes: [RollbackWrite] = []
		for write in answer.response.writes {
			var values: [(key: String, value: SecretBytes)]?
			if let entries = write.values {
				var resolved: [(key: String, value: SecretBytes)] = []
				for entry in entries {
					guard let value = answer.blobs[entry.value] else { throw unreadable }
					resolved.append((entry.key, value))
				}
				values = resolved
			}
			writes.append(RollbackWrite(name: write.name, renamedFrom: write.renamedFrom, values: values))
		}
		return writes
	}
}

// MARK: - Removal

extension HistoryEngine {
	struct Occurrence: Codable, Sendable, Equatable {
		let set: Int64?
		let replaced: Int64?
	}

	struct Place: Codable, Sendable, Equatable {
		let environment: String
		let key: String
		let renamedFrom: [String]
		let renamedEnvironments: [String]
		/// "thisKey" or "otherKey".
		let group: String
		/// Whether a key holds the value now, which can't be removed.
		let current: Bool
		let occurrences: [Occurrence]
		let digests: [String]
	}

	/// A removal's review, passed back whole to start it.
	struct Review: Codable, Sendable, Equatable {
		/// The value's keyed digest, never the value.
		let value: String
		let generation: UInt32
		let keyId: String
		let places: [Place]
		let defaultSelection: [Int]
		let fingerprint: String
	}

	/// Reviews removing the value `key` had in `environment` on `side`
	/// ("before" or "after") of `entry`.
	static func reviewRemoval(
		_ stored: Stored,
		values: SecretBytes,
		entry: String,
		environment: String,
		key: String,
		side: String
	) throws(Failure) -> Review {
		struct Chosen: Encodable {
			let entry: String
			let environment: String
			let key: String
			let side: String
		}
		struct Rest: Encodable { let chosen: Chosen }
		struct Response: Decodable { let review: Review }
		var blobs = Blobs()
		let rest = Rest(chosen: Chosen(entry: entry, environment: environment, key: key, side: side))
		let request = ReadingRequest(stored, values: values, rest: rest, blobs: &blobs)
		let answer: Answer<Response> = try call(lpm_env_history_removal, request, blobs: blobs)
		return answer.response.review
	}

	/// Starts removing the reviewed value from the places at `selection`:
	/// one journal transaction, then `maintenance` finishes it.
	static func startRemoval(
		_ stored: Stored,
		values: SecretBytes,
		review: Review,
		selection: [Int],
		approval: Approval
	) throws(Failure) -> [RecordWrite] {
		struct Start: Encodable {
			let review: Review
			let selection: [Int]
			let approval: Approval
			let fingerprint: String
		}
		struct Rest: Encodable { let start: Start }
		struct Response: Decodable { let writes: [Write] }
		var blobs = Blobs()
		let rest = Rest(start: Start(review: review, selection: selection, approval: approval, fingerprint: review.fingerprint))
		let request = ReadingRequest(stored, values: values, rest: rest, blobs: &blobs)
		let answer: Answer<Response> = try call(lpm_env_history_removal, request, blobs: blobs)
		guard let writes = resolve(answer.response.writes, in: answer.blobs) else { throw unreadable }
		return writes
	}
}

// MARK: - Upkeep

extension HistoryEngine {
	enum MaintenanceStep: Sendable {
		/// Whether a rotation is running, and whether the key needs one.
		case check(approval: Approval)
		case start(approval: Approval)
		/// Rotate one part, whose bytes are in the stored parts.
		case rotatePart(Int)
		/// Every part as stored after its rotation.
		case finish
	}

	struct Maintenance: Sendable {
		let needsFinishing: Bool
		let parts: [Int]
		/// "nothing", "rotate" or "lower", for a check.
		let key: String?
		let journal: Bool
		let writes: [RecordWrite]
	}

	static func maintenance(_ stored: Stored, step: MaintenanceStep) throws(Failure) -> Maintenance {
		struct Rest: Encodable {
			let step: String
			let approval: Approval?
			let part: Int?
		}
		struct Response: Decodable {
			let needsFinishing: Bool?
			let parts: [Int]?
			let key: String?
			let journal: Bool?
			let writes: [Write]?
		}
		let rest: Rest
		switch step {
		case .check(let approval): rest = Rest(step: "check", approval: approval, part: nil)
		case .start(let approval): rest = Rest(step: "start", approval: approval, part: nil)
		case .rotatePart(let part): rest = Rest(step: "rotatePart", approval: nil, part: part)
		case .finish: rest = Rest(step: "finish", approval: nil, part: nil)
		}
		var blobs = Blobs()
		let request = ReadingRequest(stored, values: nil, rest: rest, blobs: &blobs)
		let answer: Answer<Response> = try call(lpm_env_history_maintenance, request, blobs: blobs)
		guard let writes = resolve(answer.response.writes ?? [], in: answer.blobs) else { throw unreadable }
		return Maintenance(
			needsFinishing: answer.response.needsFinishing ?? false,
			parts: answer.response.parts ?? [],
			key: answer.response.key,
			journal: answer.response.journal ?? false,
			writes: writes)
	}

	enum AdmissionOperation: String, Encodable, Sendable {
		case creation, growth, trim
	}

	struct Trim: Decodable, Sendable, Equatable {
		let vaultId: String
		let count: Int
		/// The fewest parts the trim may leave.
		let floor: Int
	}

	struct Admission: Decodable, Sendable, Equatable {
		let existing: Int
		let trims: [Trim]
		let afterTrims: Int
		/// "full", "reduced" or "refused".
		let creation: String
		/// nil when creation is refused.
		let ringLimit: Int?
		let growth: Bool
		let regrow: Bool
	}

	/// Admission from a names-only listing of the shared service. For
	/// growth, `growing` names the growing ring and its head.
	static func admission(
		names: [String],
		operation: AdmissionOperation,
		trimmable: [String]? = nil,
		maxTrims: Int? = nil,
		growing: (vaultId: String, head: SecretBytes)? = nil
	) throws(Failure) -> Admission {
		struct Request: Encodable {
			let names: [String]
			let operation: AdmissionOperation
			let trimmable: [String]?
			let maxTrims: Int?
			let vaultId: String?
			let head: Int?
		}
		var blobs = Blobs()
		let request = Request(
			names: names, operation: operation, trimmable: trimmable, maxTrims: maxTrims,
			vaultId: growing?.vaultId, head: growing.map { blobs.add($0.head) })
		let answer: Answer<Admission> = try call(lpm_env_history_admission, request, blobs: blobs)
		return answer.response
	}

	enum RingAction: Sendable {
		/// Trim the oldest part, never below `floor` parts. `tail` is the key
		/// and the tail's bytes, read when a trim to one part asks for them.
		case trim(floor: Int, tail: (key: SecretBytes, part: SecretBytes?)?)
		case raiseLimit(existing: Int)
		/// Delete the ring's parts the head doesn't list, from `inventory`.
		case orphans(inventory: [String])
	}

	enum Ring: Sendable {
		/// Read the key and the tail, then trim again with them.
		case needsTail
		/// Write these in order, then delete `delete`.
		case upkeep(writes: [RecordWrite], delete: [String])
	}

	static func ring(vaultId: String, head: SecretBytes, action: RingAction) throws(Failure) -> Ring {
		struct Tail: Encodable {
			let key: Int
			let part: Int?
		}
		struct Request: Encodable {
			let vaultId: String
			let head: Int
			let action: String
			let floor: Int?
			let tail: Tail?
			let existing: Int
			let inventory: [String]
		}
		struct Response: Decodable {
			let needsTail: Bool?
			let writes: [Write]?
			let delete: DeleteField?
		}
		var blobs = Blobs()
		let headIndex = blobs.add(head)
		let request: Request
		switch action {
		case .trim(let floor, let tail):
			let tailIndexes = tail.map { Tail(key: blobs.add($0.key), part: $0.part.map { part in blobs.add(part) }) }
			request = Request(vaultId: vaultId, head: headIndex, action: "trim", floor: floor, tail: tailIndexes, existing: 0, inventory: [])
		case .raiseLimit(let existing):
			request = Request(vaultId: vaultId, head: headIndex, action: "raiseLimit", floor: nil, tail: nil, existing: existing, inventory: [])
		case .orphans(let inventory):
			request = Request(vaultId: vaultId, head: headIndex, action: "orphans", floor: nil, tail: nil, existing: 0, inventory: inventory)
		}
		let answer: Answer<Response> = try call(lpm_env_history_ring, request, blobs: blobs)
		if answer.response.needsTail == true { return .needsTail }
		guard let writes = resolve(answer.response.writes ?? [], in: answer.blobs) else { throw unreadable }
		return .upkeep(writes: writes, delete: answer.response.delete?.names ?? [])
	}

	/// The ring's `delete`: one account name, or a list of them.
	private struct DeleteField: Decodable {
		let names: [String]

		init(from decoder: any Decoder) throws {
			let container = try decoder.singleValueContainer()
			if let one = try? container.decode(String.self) {
				names = [one]
			} else {
				names = try container.decode([String].self)
			}
		}
	}
}
