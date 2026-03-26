import CryptoKit
import Foundation

/// E2E encryption for vault sync — 1:1 port of Rust crypto.rs.
///
/// Format is wire-compatible: data encrypted by the Rust CLI can be
/// decrypted by this Swift code, and vice versa.
///
/// ## Encryption format
/// - AES-256-GCM with 12-byte random IV
/// - Encoded as: `base64(iv):base64(ciphertext + auth_tag)`
///
/// ## Key derivation
/// - Wrapping key = SHA256("lpm-vault-wrap:" + auth_token)
/// - Per-vault AES key = random 32 bytes
/// - Wrapped key = AES-GCM encrypt(wrapping_key, aes_key)
enum VaultCrypto {

	// MARK: - Key Derivation

	/// Derive a wrapping key from the auth token.
	/// Must match Rust: `SHA256("lpm-vault-wrap:" + token)`
	static func deriveWrappingKey(authToken: String) -> SymmetricKey {
		let prefix = "lpm-vault-wrap:"
		let input = Data((prefix + authToken).utf8)
		let hash = SHA256.hash(data: input)
		return SymmetricKey(data: hash)
	}

	/// Generate a random 256-bit AES key.
	static func generateAESKey() -> SymmetricKey {
		SymmetricKey(size: .bits256)
	}

	// MARK: - Encrypt / Decrypt

	/// Encrypt data with AES-256-GCM.
	/// Returns `base64(iv):base64(ciphertext+tag)` — matches Rust format.
	static func encrypt(key: SymmetricKey, plaintext: Data) throws -> String {
		let nonce = AES.GCM.Nonce()
		let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

		let ivData = Data(nonce)
		// combined = ciphertext + tag (AES.GCM.SealedBox stores them together)
		guard let combined = sealed.combined else {
			throw CryptoError.encryptionFailed
		}
		// combined is: nonce (12) + ciphertext + tag (16)
		// We need just ciphertext + tag (skip the 12-byte nonce prefix)
		let ciphertextAndTag = combined.dropFirst(12)

		return ivData.base64EncodedString() + ":" + ciphertextAndTag.base64EncodedString()
	}

	/// Decrypt data produced by `encrypt()`.
	static func decrypt(key: SymmetricKey, encoded: String) throws -> Data {
		let parts = encoded.split(separator: ":", maxSplits: 1)
		guard parts.count == 2 else {
			throw CryptoError.invalidFormat
		}

		guard let ivData = Data(base64Encoded: String(parts[0])) else {
			throw CryptoError.invalidBase64
		}
		guard let ciphertextAndTag = Data(base64Encoded: String(parts[1])) else {
			throw CryptoError.invalidBase64
		}

		guard ivData.count == 12 else {
			throw CryptoError.invalidIVSize(ivData.count)
		}

		let nonce = try AES.GCM.Nonce(data: ivData)
		// Reconstruct the combined box: nonce + ciphertext + tag
		let combined = ivData + ciphertextAndTag
		let sealedBox = try AES.GCM.SealedBox(combined: combined)

		return try AES.GCM.open(sealedBox, using: key)
	}

	// MARK: - Key Wrapping

	/// Wrap an AES key with a wrapping key.
	static func wrapKey(wrappingKey: SymmetricKey, aesKey: SymmetricKey) throws -> String {
		let keyData = aesKey.withUnsafeBytes { Data($0) }
		return try encrypt(key: wrappingKey, plaintext: keyData)
	}

	/// Unwrap an AES key.
	static func unwrapKey(wrappingKey: SymmetricKey, wrapped: String) throws -> SymmetricKey {
		let keyData = try decrypt(key: wrappingKey, encoded: wrapped)
		guard keyData.count == 32 else {
			throw CryptoError.invalidKeySize(keyData.count)
		}
		return SymmetricKey(data: keyData)
	}

	// MARK: - High-Level Sync API

	/// Encrypt vault secrets for cloud sync.
	/// Returns `(encryptedBlob, wrappedKey)` — both base64-encoded strings.
	static func encryptForSync(
		authToken: String,
		secretsJSON: String
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		let aesKey = generateAESKey()
		let wrappingKey = deriveWrappingKey(authToken: authToken)

		let blob = try encrypt(key: aesKey, plaintext: Data(secretsJSON.utf8))
		let wrapped = try wrapKey(wrappingKey: wrappingKey, aesKey: aesKey)

		return (blob, wrapped)
	}

	/// Decrypt vault secrets from cloud sync.
	static func decryptFromSync(
		authToken: String,
		encryptedBlob: String,
		wrappedKey: String
	) throws -> String {
		let wrappingKey = deriveWrappingKey(authToken: authToken)
		let aesKey = try unwrapKey(wrappingKey: wrappingKey, wrapped: wrappedKey)
		let plaintext = try decrypt(key: aesKey, encoded: encryptedBlob)

		guard let json = String(data: plaintext, encoding: .utf8) else {
			throw CryptoError.invalidUTF8
		}
		return json
	}

	// MARK: - X25519 Org Sync (ECIES-like)

	/// Generate an X25519 keypair. Returns (privateKeyData, publicKeyData) — 32 bytes each.
	static func generateX25519Keypair() -> (privateKey: Data, publicKey: Data) {
		let privateKey = Curve25519.KeyAgreement.PrivateKey()
		return (privateKey.rawRepresentation, privateKey.publicKey.rawRepresentation)
	}

	/// Derive public key from private key bytes.
	static func x25519PublicFromPrivate(_ privateKeyData: Data) throws -> Data {
		let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
		return privateKey.publicKey.rawRepresentation
	}

	/// Wrap an AES-256 key for a recipient using ECIES-like X25519 + HKDF + AES-GCM.
	///
	/// Format: `base64(ephemeralPublic):base64(iv):base64(ciphertext+tag)`
	/// Wire-compatible with Rust `wrap_key_for_recipient`.
	static func wrapKeyForRecipient(
		aesKey: SymmetricKey,
		recipientPublicKey: Data
	) throws -> String {
		let recipientPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
		let ephemeral = Curve25519.KeyAgreement.PrivateKey()

		// ECDH → shared secret → HKDF
		let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPK)
		let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
			using: SHA256.self,
			salt: Data(),
			sharedInfo: Data("lpm-vault-org".utf8),
			outputByteCount: 32
		)

		// AES-GCM encrypt the AES key
		let aesKeyData = aesKey.withUnsafeBytes { Data($0) }
		let wrapped = try encrypt(key: derivedKey, plaintext: aesKeyData)

		// Prepend ephemeral public key
		let ephPubBase64 = ephemeral.publicKey.rawRepresentation.base64EncodedString()
		return "\(ephPubBase64):\(wrapped)"
	}

	/// Unwrap an AES-256 key using the recipient's X25519 private key.
	///
	/// Input format: `base64(ephemeralPublic):base64(iv):base64(ciphertext+tag)`
	static func unwrapKeyFromSender(
		wrapped: String,
		privateKey: Data
	) throws -> SymmetricKey {
		// Split: ephemeralPublic : iv : ciphertext+tag
		let parts = wrapped.split(separator: ":", maxSplits: 1)
		guard parts.count == 2 else { throw CryptoError.invalidFormat }

		guard let ephPubData = Data(base64Encoded: String(parts[0])) else {
			throw CryptoError.invalidBase64
		}
		guard ephPubData.count == 32 else {
			throw CryptoError.invalidKeySize(ephPubData.count)
		}

		let ephPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubData)
		let myPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)

		// ECDH → shared secret → HKDF
		let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: ephPK)
		let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
			using: SHA256.self,
			salt: Data(),
			sharedInfo: Data("lpm-vault-org".utf8),
			outputByteCount: 32
		)

		// Decrypt the AES key
		let aesEncrypted = String(parts[1])
		let aesKeyData = try decrypt(key: derivedKey, encoded: aesEncrypted)
		guard aesKeyData.count == 32 else {
			throw CryptoError.invalidKeySize(aesKeyData.count)
		}

		return SymmetricKey(data: aesKeyData)
	}

	// MARK: - X25519 Key Storage (Keychain)

	private static let x25519Account = "__x25519_private_key__"

	/// Read the stored X25519 private key from Keychain.
	static func readX25519PrivateKey() -> Data? {
		let (code, output) = runSecurity(args: [
			"find-generic-password", "-s", "dev.lpm.vault", "-a", x25519Account, "-w",
		])
		guard code == 0, !output.isEmpty else { return nil }
		return Data(base64Encoded: output)
	}

	/// Store an X25519 private key in Keychain.
	static func writeX25519PrivateKey(_ privateKey: Data) {
		let b64 = privateKey.base64EncodedString()
		runSecurity(args: ["delete-generic-password", "-s", "dev.lpm.vault", "-a", x25519Account])
		runSecurity(args: ["add-generic-password", "-A", "-s", "dev.lpm.vault", "-a", x25519Account, "-w", b64])
	}

	/// Get or create the X25519 keypair. Returns (privateKeyData, publicKeyData).
	static func getOrCreateX25519Keypair() -> (privateKey: Data, publicKey: Data) {
		if let existing = readX25519PrivateKey(), existing.count == 32 {
			if let pub_key = try? x25519PublicFromPrivate(existing) {
				return (existing, pub_key)
			}
		}

		let (priv_key, pub_key) = generateX25519Keypair()
		writeX25519PrivateKey(priv_key)
		return (priv_key, pub_key)
	}

	// MARK: - Errors

	enum CryptoError: LocalizedError {
		case encryptionFailed
		case invalidFormat
		case invalidBase64
		case invalidIVSize(Int)
		case invalidKeySize(Int)
		case invalidUTF8

		var errorDescription: String? {
			switch self {
			case .encryptionFailed:
				"Encryption failed"
			case .invalidFormat:
				"Invalid encrypted format (expected iv:ciphertext)"
			case .invalidBase64:
				"Invalid base64 encoding"
			case .invalidIVSize(let n):
				"Invalid IV size: \(n) bytes (expected 12)"
			case .invalidKeySize(let n):
				"Invalid key size: \(n) bytes (expected 32)"
			case .invalidUTF8:
				"Decrypted data is not valid UTF-8"
			}
		}
	}

	// MARK: - Private Helpers

	@discardableResult
	private static func runSecurity(args: [String]) -> (Int32, String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		process.arguments = args
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		let sem = DispatchSemaphore(value: 0)
		var exitCode: Int32 = -1
		process.terminationHandler = { p in
			exitCode = p.terminationStatus
			sem.signal()
		}

		do { try process.run() } catch { return (-1, "") }
		_ = sem.wait(timeout: .now() + 10)

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return (exitCode, output)
	}
}
