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
	struct Blobs {
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
	struct Answer<Response> {
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
		let count = try length()
		guard count >= 1, count <= maximumBlobs + 1 else { throw unreadable }
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

	enum Remote: Decodable, Sendable, Equatable {
		case personal
		case org(String)

		private struct Org: Decodable { let org: String }

		init(from decoder: any Decoder) throws {
			if let org = try? Org(from: decoder) {
				self = .org(org.org)
			} else if try decoder.singleValueContainer().decode(String.self) == "personal" {
				self = .personal
			} else {
				throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown remote"))
			}
		}
	}

	struct Related: Decodable, Sendable, Equatable {
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
