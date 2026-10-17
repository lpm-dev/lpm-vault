import Foundation
import LPMEnv

/// libsodium sealed boxes, the form GitHub takes a secret's value in, made by
/// the bundled engine with the same sealing the LPM CLI uses.
enum SealedBox {
	/// A Curve25519 public key's length.
	static let publicKeyBytes = 32
	/// What sealing adds to a value: the ephemeral public key and the tag.
	static let overheadBytes = 48
	/// The longest value the engine seals.
	static let maximumPlaintextBytes = 64 * 1024

	/// `value` sealed to `publicKey`, the ephemeral public key then the box;
	/// nil when the key or value can't be sealed. The copy of the value made
	/// for the engine is cleared once it's sealed.
	static func seal(_ value: String, to publicKey: Data) -> Data? {
		guard lpm_env_abi_version() == 1, publicKey.count == publicKeyBytes else { return nil }
		var plaintext = Array(value.utf8)
		defer { plaintext.withUnsafeMutableBytes { bytes in if let base = bytes.baseAddress { _ = memset_s(base, bytes.count, 0, bytes.count) } } }
		guard plaintext.count <= maximumPlaintextBytes else { return nil }
		let result = publicKey.withUnsafeBytes { key in
			plaintext.withUnsafeBytes { text in
				lpm_env_seal_box(
					key.bindMemory(to: UInt8.self).baseAddress, key.count,
					text.bindMemory(to: UInt8.self).baseAddress, text.count)
			}
		}
		defer { lpm_env_release(result) }
		guard result.status == 0, let data = result.data, result.length == plaintext.count + overheadBytes else { return nil }
		return Data(bytes: data, count: result.length)
	}
}
