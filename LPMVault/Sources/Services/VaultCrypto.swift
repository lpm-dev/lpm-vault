import CryptoKit
import Foundation
import Security

/// E2E encryption for vault sync — 1:1 port of Rust crypto.rs.
///
/// Format is wire-compatible: data encrypted by the Rust CLI can be
/// decrypted by this Swift code, and vice versa.
///
/// ## Encryption format
/// - AES-256-GCM with 12-byte random IV
/// - Encoded as: `base64(iv):base64(ciphertext + auth_tag)`
///
/// ## Personal key wrapping
/// - Stable wrapping key = system Keychain item `dev.lpm.vault-key` / `wrapping-key`
/// - Per-vault AES key = random 32 bytes
/// - Token-derived wrapping remains available only for legacy migration
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

	/// Encrypt personal sync data with the stable wrapping key shared with the Rust client.
	static func encryptForStableSync(secretsJSON: String) throws -> (encryptedBlob: String, wrappedKey: String) {
		try encryptForStableSync(secretsJSON: secretsJSON, wrappingKey: stableWrappingKey())
	}

	static func encryptForStableSync(
		secretsJSON: String,
		wrappingKey: SymmetricKey
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		let aesKey = generateAESKey()
		return (
			try encrypt(key: aesKey, plaintext: Data(secretsJSON.utf8)),
			try wrapKey(wrappingKey: wrappingKey, aesKey: aesKey)
		)
	}

	/// Decrypt stable-key sync data, falling back to legacy token-derived wraps.
	static func decryptStableSync(
		authToken: String,
		encryptedBlob: String,
		wrappedKey: String
	) throws -> (plaintext: String, usedLegacyKey: Bool) {
		if let stableKey = try? stableWrappingKey(),
			let aesKey = try? unwrapKey(wrappingKey: stableKey, wrapped: wrappedKey),
			let plaintext = try? decrypt(key: aesKey, encoded: encryptedBlob),
			let json = String(data: plaintext, encoding: .utf8)
		{
			return (json, false)
		}

		return (
			try decryptFromSync(
				authToken: authToken,
				encryptedBlob: encryptedBlob,
				wrappedKey: wrappedKey
			),
			true
		)
	}

	static func decryptStableSync(
		encryptedBlob: String,
		wrappedKey: String,
		wrappingKey: SymmetricKey
	) throws -> String {
		let aesKey = try unwrapKey(wrappingKey: wrappingKey, wrapped: wrappedKey)
		let plaintext = try decrypt(key: aesKey, encoded: encryptedBlob)
		guard let json = String(data: plaintext, encoding: .utf8) else {
			throw CryptoError.invalidUTF8
		}
		return json
	}

	static func publicKeyFingerprint(_ publicKey: Data) -> String {
		SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
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

	// MARK: - X25519 Key Storage (Keychain via Security.framework)

	private static let x25519Account = "__x25519_private_key__"
	private static let x25519Service = VaultConstants.keychainService
	private static let wrappingKeyService = "dev.lpm.vault-key"
	private static let wrappingKeyAccount = "wrapping-key"
	private static let maximumWrappingKeyFileBytes = 4 * 1024

	private static func stableWrappingKey() throws -> SymmetricKey {
		if let key = readStableWrappingKeyFromKeychain() {
			try? FileManager.default.removeItem(at: wrappingKeyFileURL())
			return SymmetricKey(data: key)
		}
		if let key = readStableWrappingKeyFromFile() {
			_ = storeStableWrappingKeyInKeychain(key)
			return SymmetricKey(data: key)
		}

		var bytes = [UInt8](repeating: 0, count: 32)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			throw CryptoError.encryptionFailed
		}
		let key = Data(bytes)
		if !storeStableWrappingKeyInKeychain(key) {
			try storeStableWrappingKeyInFile(key)
		}
		return SymmetricKey(data: key)
	}

	private static func readStableWrappingKeyFromKeychain() -> Data? {
		let (status, hex) = runSecurity(args: [
			"find-generic-password", "-s", wrappingKeyService,
			"-a", wrappingKeyAccount, "-w",
		])
		guard status == 0 else { return nil }
		return decodeWrappingKey(hex)
	}

	private static func storeStableWrappingKeyInKeychain(_ key: Data) -> Bool {
		let hex = key.map { String(format: "%02x", $0) }.joined()
		return runSecurity(args: [
			"add-generic-password", "-U", "-s", wrappingKeyService,
			"-a", wrappingKeyAccount, "-w",
		], input: hex).0 == 0
	}

	private static func readStableWrappingKeyFromFile() -> Data? {
		let url = wrappingKeyFileURL()
		if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			let permissions = attributes[.posixPermissions] as? NSNumber,
			permissions.intValue & 0o777 > 0o600
		{
			return nil
		}
		guard let data = try? Data(contentsOf: url),
			data.count <= maximumWrappingKeyFileBytes,
			let hex = String(data: data, encoding: .utf8)
		else { return nil }
		return decodeWrappingKey(hex.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	private static func storeStableWrappingKeyInFile(_ key: Data) throws {
		let url = wrappingKeyFileURL()
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		let hex = key.map { String(format: "%02x", $0) }.joined()
		try Data(hex.utf8).write(to: url, options: .atomic)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: url.path
		)
	}

	private static func wrappingKeyFileURL() -> URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".lpm", isDirectory: true)
			.appendingPathComponent(".vault-key")
	}

	private static func decodeWrappingKey(_ hex: String) -> Data? {
		guard hex.count == 64 else { return nil }
		var bytes = [UInt8]()
		bytes.reserveCapacity(32)
		var index = hex.startIndex
		for _ in 0..<32 {
			let next = hex.index(index, offsetBy: 2)
			guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
			bytes.append(byte)
			index = next
		}
		return Data(bytes)
	}

	/// Store an X25519 private key in Keychain using Security.framework.
	/// Uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — no iCloud sync, no backup extraction.
	/// Compatible with Rust CLI's `keyring` crate (same service/account, Security.framework under the hood).
	private static func storeX25519Key(_ keyData: Data, account: String) throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: x25519Service,
			kSecAttrAccount as String: account,
			kSecValueData as String: keyData.base64EncodedString().data(using: .utf8)!,
			kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
		]

		// Delete existing if present
		SecItemDelete(query as CFDictionary)

		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw CryptoError.keychainWriteFailed(status)
		}
	}

	/// Load an X25519 private key from Keychain using Security.framework.
	private static func loadX25519Key(account: String) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: x25519Service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)

		guard status == errSecSuccess, let data = result as? Data else {
			return nil
		}
		// Stored as base64 string for compatibility with Rust CLI's keyring crate
		guard let b64String = String(data: data, encoding: .utf8) else { return nil }
		return Data(base64Encoded: b64String)
	}

	/// Read X25519 private key from Keychain via legacy `security` CLI (migration fallback).
	private static func readX25519PrivateKeyLegacy() -> Data? {
		let (code, output) = runSecurity(args: [
			"find-generic-password", "-s", x25519Service, "-a", x25519Account, "-w",
		])
		guard code == 0, !output.isEmpty else { return nil }
		return Data(base64Encoded: output)
	}

	/// Delete legacy `security` CLI entry for X25519 key.
	private static func deleteX25519LegacyEntry() {
		runSecurity(args: ["delete-generic-password", "-s", x25519Service, "-a", x25519Account])
	}

	/// Read the stored X25519 private key from Keychain.
	/// Tries Security.framework first, then falls back to legacy `security` CLI
	/// for backward compatibility. If found via legacy path, migrates to Security.framework.
	static func readX25519PrivateKey() -> Data? {
		// Primary path: Security.framework
		if let key = loadX25519Key(account: x25519Account) {
			return key
		}

		// Migration fallback: read from legacy `security` CLI entry
		guard let legacyKey = readX25519PrivateKeyLegacy() else { return nil }

		// Migrate: store via Security.framework and delete old entry
		do {
			try storeX25519Key(legacyKey, account: x25519Account)
			deleteX25519LegacyEntry()
		} catch {
			// Migration failed — still return the key so we don't break the user
		}

		return legacyKey
	}

	/// Store an X25519 private key in Keychain.
	static func writeX25519PrivateKey(_ privateKey: Data) {
		do {
			try storeX25519Key(privateKey, account: x25519Account)
		} catch {
			#if DEBUG
			print("VaultCrypto: failed to write X25519 key to Keychain: \(error)")
			#endif
		}
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
		case keychainWriteFailed(OSStatus)

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
			case .keychainWriteFailed(let status):
				"Failed to write to Keychain (OSStatus: \(status))"
			}
		}
	}

	// MARK: - Private Helpers

	@discardableResult
	private static func runSecurity(args: [String], input: String? = nil) -> (Int32, String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		process.arguments = args
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		let inputPipe = input.map { _ in Pipe() }
		process.standardInput = inputPipe

		do {
			try process.run()
			if let input, let inputPipe {
				inputPipe.fileHandleForWriting.write(Data((input + "\n").utf8))
				inputPipe.fileHandleForWriting.closeFile()
			}
		} catch { return (-1, "") }
		process.waitUntilExit()

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return (process.terminationStatus, output)
	}
}
