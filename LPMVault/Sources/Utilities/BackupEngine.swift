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
