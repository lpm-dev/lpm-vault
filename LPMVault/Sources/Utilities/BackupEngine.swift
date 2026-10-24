import Darwin
import Foundation
import LPMEnv

/// Backup files, sealed and opened by the bundled engine in the format the
/// LPM CLI shares: one file of env projects that only its passphrase opens.
/// Sealing and opening derive a key over 256 MiB of memory and block for a
/// fraction of a second, one at a time; run them off the main actor.
enum BackupEngine {
	/// The largest backup file the engine writes or reads.
	static let maximumFileBytes = 64 * 1024 * 1024
	/// The longest passphrase the engine takes, in UTF-8 bytes as typed.
	static let maximumPassphraseBytes = 4 * 1024

	/// zxcvbn's estimate of a passphrase, as the engine reads it.
	struct Strength: Equatable, Sendable {
		/// The guesses needed, as a power of ten.
		let guessesLog10: Double
		/// Whether a backup can be sealed with it.
		let acceptable: Bool
		/// The power of ten a passphrase needs to reach.
		let minimumGuessesLog10: Double
	}

	/// Why the engine couldn't do what was asked.
	enum Failure: Error, Equatable, Sendable {
		case passphraseEmpty
		case passphraseTooLong
		case passphraseWeak(guessesLog10: Double)
		case tooLarge
		case notABackup
		case newerFormat(version: Int)
		case damaged
		case wrongPassphrase
		/// What it holds isn't a valid backup: `reason` is the engine's code
		/// for the first problem, never the text it was about, and `offset`
		/// the payload byte where it was found, when there's one.
		case invalidContents(reason: String, offset: Int?)
		case outOfMemory
		/// The engine failed in a way that needs no detail for people.
		case engine(code: String)

		var message: String {
			switch self {
			case .passphraseEmpty: "Enter a passphrase."
			case .passphraseTooLong: "That passphrase is too long."
			case .passphraseWeak: "That passphrase is too easy to guess. Make it longer, or use Generate."
			case .tooLarge: "Backups can be at most 64 MB."
			case .notABackup: "This isn’t an LPM Vault backup."
			case .newerFormat: "This backup was made by a newer version of LPM Vault. Update LPM Vault to restore it."
			case .damaged: "This backup file is damaged or incomplete."
			case .wrongPassphrase: "That passphrase doesn’t open this file. Check it and try again — there’s no limit on attempts."
			case .invalidContents: "This backup opened, but what it holds isn’t valid."
			case .outOfMemory: "This Mac didn’t have the memory to open the backup. Close other apps and try again."
			case .engine: "The backup engine failed. Try again."
			}
		}
	}

	/// zxcvbn's estimate for `passphrase`. Quick enough to run on every
	/// keystroke after the first call, which loads zxcvbn's dictionaries.
	static func strength(of passphrase: String) -> Result<Strength, Failure> {
		let result = withPassphraseBytes(passphrase) { bytes in
			lpm_env_backup_check_passphrase(bytes.baseAddress, bytes.count)
		}
		return decodeJSON(result).flatMap { output in
			guard case .bool(let acceptable)? = output["acceptable"],
				let guesses = number(output["guessesLog10"]),
				let minimum = number(output["minimumGuessesLog10"])
			else { return .failure(.engine(code: "backup.unreadable_output")) }
			return .success(Strength(guessesLog10: guesses, acceptable: acceptable, minimumGuessesLog10: minimum))
		}
	}

	/// Six words drawn from the EFF large wordlist, separated by spaces.
	static func generatePassphrase() -> Result<String, Failure> {
		let result = lpm_env_backup_generate_passphrase()
		defer { lpm_env_release(result) }
		guard lpm_env_abi_version() == 1 else { return .failure(.engine(code: "env.abi_mismatch")) }
		guard result.status == 0, let data = result.data, result.length > 0,
			let phrase = String(bytes: UnsafeBufferPointer(start: data, count: result.length), encoding: .utf8)
		else { return .failure(refusal(of: result)) }
		return .success(phrase)
	}

	/// `payload` sealed into a backup file with `passphrase`. Blocks.
	static func seal(payload: SecretBytes, passphrase: String) -> Result<Data, Failure> {
		guard payload.count <= maximumFileBytes else { return .failure(.tooLarge) }
		let result = payload.withUnsafeBytes { payload in
			withPassphraseBytes(passphrase) { phrase in
				lpm_env_backup_seal(
					payload.bindMemory(to: UInt8.self).baseAddress, payload.count,
					phrase.baseAddress, phrase.count)
			}
		}
		defer { lpm_env_release(result) }
		guard lpm_env_abi_version() == 1 else { return .failure(.engine(code: "env.abi_mismatch")) }
		guard result.status == 0 else { return .failure(refusal(of: result)) }
		guard let data = result.data, result.length > 0, result.length <= maximumFileBytes else {
			return .failure(.engine(code: "backup.unreadable_output"))
		}
		return .success(Data(bytes: data, count: result.length))
	}

	/// The format version of a backup file, read from its header alone.
	static func inspect(_ file: Data) -> Result<Int, Failure> {
		guard file.count <= maximumFileBytes else { return .failure(.tooLarge) }
		let result = file.withUnsafeBytes { file in
			lpm_env_backup_inspect(file.bindMemory(to: UInt8.self).baseAddress, file.count)
		}
		return decodeJSON(result).flatMap { output in
			guard let version = number(output["formatVersion"]), version >= 1, version == version.rounded() else {
				return .failure(.engine(code: "backup.unreadable_output"))
			}
			return .success(Int(version))
		}
	}

	/// The payload of a backup file, checked by the engine. Blocks. It's
	/// copied out of the engine's plaintext, which the engine then zeroes.
	static func open(_ file: Data, passphrase: String) -> Result<SecretBytes, Failure> {
		guard file.count <= maximumFileBytes else { return .failure(.tooLarge) }
		var offset = 0
		var length = 0
		let result = file.withUnsafeBytes { file in
			withPassphraseBytes(passphrase) { phrase in
				lpm_env_backup_open(
					file.bindMemory(to: UInt8.self).baseAddress, file.count,
					phrase.baseAddress, phrase.count,
					&offset, &length)
			}
		}
		defer { lpm_env_release(result) }
		guard lpm_env_abi_version() == 1 else { return .failure(.engine(code: "env.abi_mismatch")) }
		guard result.status == 0 else { return .failure(refusal(of: result)) }
		guard let data = result.data, result.length <= maximumFileBytes,
			offset <= result.length, length <= result.length - offset
		else { return .failure(.engine(code: "backup.unreadable_output")) }
		return .success(SecretBytes(copying: UnsafeRawBufferPointer(start: data + offset, count: length)))
	}

	/// The payload of a backup file, checked by the engine, with its sync
	/// keys taken out before anything parses it as text. Blocks. Both are
	/// copied out of the engine's plaintext, which the engine then zeroes.
	static func openSplit(_ file: Data, passphrase: String) -> Result<(payload: SecretBytes, keys: BackupKeys), Failure> {
		guard file.count <= maximumFileBytes else { return .failure(.tooLarge) }
		var payloadOffset = 0
		var payloadLength = 0
		var keysOffset = 0
		var keysLength = 0
		let result = file.withUnsafeBytes { file in
			withPassphraseBytes(passphrase) { phrase in
				lpm_env_backup_open_split(
					file.bindMemory(to: UInt8.self).baseAddress, file.count,
					phrase.baseAddress, phrase.count,
					&payloadOffset, &payloadLength, &keysOffset, &keysLength)
			}
		}
		defer { lpm_env_release(result) }
		guard lpm_env_abi_version() == 1 else { return .failure(.engine(code: "env.abi_mismatch")) }
		guard result.status == 0 else { return .failure(refusal(of: result)) }
		guard let data = result.data, result.length <= maximumFileBytes,
			payloadOffset <= result.length, payloadLength <= result.length - payloadOffset,
			keysOffset <= result.length, keysLength <= result.length - keysOffset,
			let keys = keyRecords(UnsafeRawBufferPointer(start: data + keysOffset, count: keysLength))
		else { return .failure(.engine(code: "backup.unreadable_output")) }
		return .success((SecretBytes(copying: UnsafeRawBufferPointer(start: data + payloadOffset, count: payloadLength)), keys))
	}

	/// The sync keys `lpm_env_backup_open_split` lays out as records: each a
	/// kind byte, then an account digest and key text, or a floor's digest and
	/// version. Nil when they aren't laid out that way, or name a key twice.
	static func keyRecords(_ records: UnsafeRawBufferPointer) -> BackupKeys? {
		var keys = BackupKeys()
		var roots = Set<String>()
		var floors = Set<String>()
		var sharing: [String: (live: SecretBytes?, pending: SecretBytes?)] = [:]
		var sharingOrder: [String] = []
		var at = 0
		func take(_ count: Int) -> UnsafeRawBufferPointer? {
			guard count <= records.count - at else { return nil }
			defer { at += count }
			return UnsafeRawBufferPointer(rebasing: records[at..<at + count])
		}
		func digest() -> String? {
			guard let bytes = take(32) else { return nil }
			return String(unsafeUninitializedCapacity: 64) { text in
				for (index, byte) in bytes.enumerated() {
					text[2 * index] = lowercaseHexDigits[Int(byte >> 4)]
					text[2 * index + 1] = lowercaseHexDigits[Int(byte & 0x0f)]
				}
				return 64
			}
		}
		while at < records.count {
			guard let kind = take(1)?.first else { return nil }
			switch kind {
			case 1:
				guard let account = digest(), roots.insert(account).inserted, let key = take(64) else { return nil }
				keys.personalRoots.append(.init(account: account, key: SecretBytes(copying: key)))
			case 2, 3:
				guard let account = digest(), let key = take(44) else { return nil }
				var halves = sharing[account] ?? (nil, nil)
				if halves.live == nil, halves.pending == nil { sharingOrder.append(account) }
				if kind == 2 {
					guard halves.live == nil else { return nil }
					halves.live = SecretBytes(copying: key)
				} else {
					guard halves.pending == nil else { return nil }
					halves.pending = SecretBytes(copying: key)
				}
				sharing[account] = halves
			case 4:
				guard keys.wrappingKey == nil, let key = take(64) else { return nil }
				keys.wrappingKey = SecretBytes(copying: key)
			case 5:
				guard let name = digest(), floors.insert(name).inserted, let version = take(4) else { return nil }
				let value = version.reduce(0) { $0 << 8 | Int($1) }
				guard value > 0, value <= Int(Int32.max) else { return nil }
				keys.floors.append(.init(digest: name, version: value))
			default:
				return nil
			}
		}
		guard keys.personalRoots.count <= BackupKeys.maximumEntries, sharingOrder.count <= BackupKeys.maximumEntries,
			keys.floors.count <= BackupKeys.maximumEntries
		else { return nil }
		keys.sharingKeys = sharingOrder.map { account in
			BackupKeys.SharingKey(account: account, live: sharing[account]?.live, pending: sharing[account]?.pending)
		}
		return keys
	}

	private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

	/// Runs `body` with a copy of `passphrase`'s UTF-8 bytes, which is
	/// cleared when it returns.
	private static func withPassphraseBytes<T>(_ passphrase: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
		var bytes = Array(passphrase.utf8)
		defer { bytes.withUnsafeMutableBytes { raw in if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) } } }
		return bytes.withUnsafeBufferPointer(body)
	}

	/// A JSON output when the call succeeded, else why it didn't. Releases it.
	private static func decodeJSON(_ result: LPMEnvResult) -> Result<LPMConfigJSON, Failure> {
		defer { lpm_env_release(result) }
		guard lpm_env_abi_version() == 1 else { return .failure(.engine(code: "env.abi_mismatch")) }
		guard result.status == 0 else { return .failure(refusal(of: result)) }
		guard let output = json(result) else { return .failure(.engine(code: "backup.unreadable_output")) }
		return .success(output)
	}

	private static func number(_ value: LPMConfigJSON?) -> Double? {
		guard case .number(let text)? = value else { return nil }
		return Double(text)
	}

	private static func json(_ result: LPMEnvResult) -> LPMConfigJSON? {
		guard let data = result.data, result.length > 0, result.length <= 64 * 1024,
			let output = try? LPMConfigJSON(parsing: Data(bytes: data, count: result.length), rejectDuplicateKeys: true),
			case .object = output
		else { return nil }
		return output
	}

	/// Why a call with a nonzero status failed, from its `{code, …}` output.
	private static func refusal(of result: LPMEnvResult) -> Failure {
		guard let output = json(result), case .string(let code)? = output["code"] else {
			return .engine(code: "backup.unreadable_output")
		}
		switch code {
		case "backup.passphrase_empty": return .passphraseEmpty
		case "backup.passphrase_too_long", "backup.passphrase_not_utf8": return .passphraseTooLong
		case "backup.passphrase_weak": return .passphraseWeak(guessesLog10: number(output["guessesLog10"]) ?? 0)
		case "backup.too_large": return .tooLarge
		case "backup.not_a_backup": return .notABackup
		case "backup.newer_format":
			return .newerFormat(version: number(output["formatVersion"]).map { Int($0) } ?? 0)
		case "backup.damaged": return .damaged
		case "backup.wrong_passphrase": return .wrongPassphrase
		case "backup.invalid_contents":
			let offset = number(output["offset"]).flatMap { $0 >= 0 && $0 == $0.rounded() && $0 < 1e15 ? Int($0) : nil }
			if case .string(let reason)? = output["reason"] { return .invalidContents(reason: reason, offset: offset) }
			return .invalidContents(reason: "unknown", offset: offset)
		case "backup.out_of_memory": return .outOfMemory
		default: return .engine(code: code)
		}
	}
}
