import CryptoKit
import Darwin
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
	static let currentCryptoVersion = 2
	private static let syncAADDomain = Data("lpm-vault-sync".utf8)

	enum SyncScope: Equatable {
		case personal
		case organization(slug: String)
	}

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
		try encrypt(key: key, plaintext: plaintext, associatedData: Data())
	}

	private static func encrypt(
		key: SymmetricKey,
		plaintext: Data,
		associatedData: Data
	) throws -> String {
		let nonce = AES.GCM.Nonce()
		let sealed = try AES.GCM.seal(
			plaintext,
			using: key,
			nonce: nonce,
			authenticating: associatedData
		)

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
		try decrypt(key: key, encoded: encoded, associatedData: Data())
	}

	private static func decrypt(
		key: SymmetricKey,
		encoded: String,
		associatedData: Data
	) throws -> Data {
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

		return try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
	}

	static func syncAssociatedData(
		scope: SyncScope,
		vaultId: String,
		cryptoVersion: Int
	) throws -> Data {
		guard cryptoVersion == currentCryptoVersion else {
			throw CryptoError.unsupportedCryptoVersion(cryptoVersion)
		}

		let vaultIdData = Data(vaultId.utf8)
		let scopeByte: UInt8
		let orgSlugData: Data
		switch scope {
		case .personal:
			scopeByte = 1
			orgSlugData = Data()
		case .organization(let slug):
			scopeByte = 2
			orgSlugData = Data(slug.utf8)
		}
		guard let vaultIdLength = UInt32(exactly: vaultIdData.count),
			let orgSlugLength = UInt32(exactly: orgSlugData.count)
		else {
			throw CryptoError.contextTooLarge
		}

		var aad = syncAADDomain
		aad.append(0)
		appendUInt32(UInt32(cryptoVersion), to: &aad)
		aad.append(scopeByte)
		appendUInt32(vaultIdLength, to: &aad)
		aad.append(vaultIdData)
		appendUInt32(orgSlugLength, to: &aad)
		aad.append(orgSlugData)
		return aad
	}

	private static func appendUInt32(_ value: UInt32, to data: inout Data) {
		var bigEndian = value.bigEndian
		Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
	}

	static func encryptPayload(
		key: SymmetricKey,
		plaintext: Data,
		scope: SyncScope,
		vaultId: String
	) throws -> String {
		let aad = try syncAssociatedData(
			scope: scope,
			vaultId: vaultId,
			cryptoVersion: currentCryptoVersion
		)
		return try encrypt(key: key, plaintext: plaintext, associatedData: aad)
	}

	static func decryptPayload(
		key: SymmetricKey,
		encoded: String,
		scope: SyncScope,
		vaultId: String,
		cryptoVersion: Int
	) throws -> Data {
		switch cryptoVersion {
		case 1:
			return try decrypt(key: key, encoded: encoded)
		case currentCryptoVersion:
			let aad = try syncAssociatedData(
				scope: scope,
				vaultId: vaultId,
				cryptoVersion: cryptoVersion
			)
			return try decrypt(key: key, encoded: encoded, associatedData: aad)
		default:
			throw CryptoError.unsupportedCryptoVersion(cryptoVersion)
		}
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
	static func encryptForStableSync(
		secretsJSON: String,
		vaultId: String
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		try encryptForStableSync(
			plaintext: Data(secretsJSON.utf8),
			vaultId: vaultId,
			wrappingKey: stableWrappingKey()
		)
	}

	static func encryptForStableSync(
		plaintext: Data,
		vaultId: String
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		try encryptForStableSync(
			plaintext: plaintext,
			vaultId: vaultId,
			wrappingKey: stableWrappingKey()
		)
	}

	static func encryptForStableSync(
		secretsJSON: String,
		vaultId: String,
		wrappingKey: SymmetricKey
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		try encryptForStableSync(
			plaintext: Data(secretsJSON.utf8),
			vaultId: vaultId,
			wrappingKey: wrappingKey
		)
	}

	static func encryptForStableSync(
		plaintext: Data,
		vaultId: String,
		wrappingKey: SymmetricKey
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		let aesKey = generateAESKey()
		return (
			try encryptPayload(
				key: aesKey,
				plaintext: plaintext,
				scope: .personal,
				vaultId: vaultId
			),
			try wrapKey(wrappingKey: wrappingKey, aesKey: aesKey)
		)
	}

	/// Decrypt stable-key sync data, falling back to legacy token-derived wraps.
	static func decryptStableSync(
		authToken: String,
		encryptedBlob: String,
		wrappedKey: String,
		vaultId: String,
		cryptoVersion: Int
	) throws -> (plaintext: String, needsReencrypt: Bool) {
		let decrypted = try decryptStableSyncData(
			authToken: authToken,
			encryptedBlob: encryptedBlob,
			wrappedKey: wrappedKey,
			vaultId: vaultId,
			cryptoVersion: cryptoVersion
		)
		guard let json = String(data: decrypted.plaintext, encoding: .utf8) else {
			throw CryptoError.invalidUTF8
		}
		return (json, decrypted.needsReencrypt)
	}

	static func decryptStableSyncData(
		authToken: String,
		encryptedBlob: String,
		wrappedKey: String,
		vaultId: String,
		cryptoVersion: Int
	) throws -> (plaintext: Data, needsReencrypt: Bool) {
		guard cryptoVersion == 1 || cryptoVersion == currentCryptoVersion else {
			throw CryptoError.unsupportedCryptoVersion(cryptoVersion)
		}
		if let stableKey = try? stableWrappingKey(),
			let aesKey = try? unwrapKey(wrappingKey: stableKey, wrapped: wrappedKey)
		{
			let plaintext = try decryptPayload(
				key: aesKey,
				encoded: encryptedBlob,
				scope: .personal,
				vaultId: vaultId,
				cryptoVersion: cryptoVersion
			)
			return (plaintext, cryptoVersion == 1)
		}

		let legacyKey = deriveWrappingKey(authToken: authToken)
		let aesKey = try unwrapKey(wrappingKey: legacyKey, wrapped: wrappedKey)
		let plaintext = try decryptPayload(
			key: aesKey,
			encoded: encryptedBlob,
			scope: .personal,
			vaultId: vaultId,
			cryptoVersion: cryptoVersion
		)
		return (plaintext, true)
	}

	static func decryptStableSync(
		encryptedBlob: String,
		wrappedKey: String,
		vaultId: String,
		cryptoVersion: Int,
		wrappingKey: SymmetricKey
	) throws -> String {
		let aesKey = try unwrapKey(wrappingKey: wrappingKey, wrapped: wrappedKey)
		let plaintext = try decryptPayload(
			key: aesKey,
			encoded: encryptedBlob,
			scope: .personal,
			vaultId: vaultId,
			cryptoVersion: cryptoVersion
		)
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
	private static let x25519KeyStore = SharedKeychainStore(service: x25519Service)
	private static let wrappingKeyStore = SharedKeychainStore(service: wrappingKeyService)

	enum StableWrappingKeyFileState: Equatable {
		case absent
		case valid(Data)
		case unsafe
	}

	private static func stableWrappingKey() throws -> SymmetricKey {
		try VaultKeychainTransactionLock.withLock {
			try stableWrappingKeyUnlocked()
		}
	}

	private static func stableWrappingKeyUnlocked() throws -> SymmetricKey {
		let fileState = inspectStableWrappingKeyFile(at: wrappingKeyFileURL())
		if let key = try readStableWrappingKeyFromKeychain() {
			switch fileState {
			case .absent:
				break
			case .unsafe:
				throw CryptoError.invalidStoredKey(
					"A legacy vault wrapping-key file exists but is not a secure valid key; it was preserved."
				)
			case .valid(let legacy):
				guard legacy == key else {
					throw CryptoError.invalidStoredKey(
						"The protected and legacy-file vault wrapping keys conflict; both were preserved."
					)
				}
			}
			return SymmetricKey(data: key)
		}
		if case .valid(let key) = fileState {
			let stored = try addOrReadStableWrappingKey(key)
			guard stored == key else {
				throw CryptoError.invalidStoredKey(
					"The protected and legacy-file vault wrapping keys conflict; both were preserved."
				)
			}
			return SymmetricKey(data: key)
		}
		if case .unsafe = fileState {
			throw CryptoError.invalidStoredKey(
				"A legacy vault wrapping-key file exists but is not a secure valid key; it was preserved."
			)
		}

		var bytes = [UInt8](repeating: 0, count: 32)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			throw CryptoError.encryptionFailed
		}
		let key = Data(bytes)
		return SymmetricKey(data: try addOrReadStableWrappingKey(key))
	}

	private static func readStableWrappingKeyFromKeychain() throws -> Data? {
		guard let encoded = try wrappingKeyStore.read(account: wrappingKeyAccount) else { return nil }
		guard let hex = String(data: encoded, encoding: .utf8),
			let key = decodeWrappingKey(hex.trimmingCharacters(in: .whitespacesAndNewlines))
		else {
			throw CryptoError.invalidStoredKey("The vault wrapping key is invalid.")
		}
		return key
	}

	private static func addOrReadStableWrappingKey(_ candidate: Data) throws -> Data {
			guard candidate.count == 32 else { throw CryptoError.invalidKeySize(candidate.count) }
			let hex = candidate.map { String(format: "%02x", $0) }.joined()
			do {
				try wrappingKeyStore.add(account: wrappingKeyAccount, data: Data(hex.utf8))
				return candidate
			} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
				guard let stored = try readStableWrappingKeyFromKeychain() else {
					throw KeychainStoreError.migrationConflict
				}
				return stored
			}
		}

	private static func readStableWrappingKeyFromFile() -> Data? {
		readStableWrappingKeyFile(at: wrappingKeyFileURL())
	}

	/// Reads the legacy file fallback without following links or accepting
	/// permissions that expose the wrapping key to another local user.
	static func readStableWrappingKeyFile(at url: URL) -> Data? {
		guard case .valid(let key) = inspectStableWrappingKeyFile(at: url) else { return nil }
		return key
	}

	static func inspectStableWrappingKeyFile(at url: URL) -> StableWrappingKeyFileState {
		guard url.isFileURL else { return .unsafe }
		var pathMetadata = stat()
		let pathStatus = url.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.lstat(path, &pathMetadata)
		}
		if pathStatus != 0 {
			return errno == ENOENT ? .absent : .unsafe
		}
		guard (pathMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
			return .unsafe
		}

		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
		}
		guard descriptor >= 0 else { return .unsafe }
		defer { _ = Darwin.close(descriptor) }

		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0,
			(metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
			metadata.st_uid == Darwin.geteuid(),
			(metadata.st_mode & 0o077) == 0,
			metadata.st_size >= 0,
			metadata.st_size <= Int64(maximumWrappingKeyFileBytes)
		else { return .unsafe }

		var data = Data()
		data.reserveCapacity(Int(metadata.st_size))
		var buffer = [UInt8](repeating: 0, count: 512)
		while true {
			let count = buffer.withUnsafeMutableBytes { bytes in
				Darwin.read(descriptor, bytes.baseAddress, bytes.count)
			}
			if count == 0 { break }
			if count < 0 {
				if errno == EINTR { continue }
				return .unsafe
			}
			guard data.count + count <= maximumWrappingKeyFileBytes else { return .unsafe }
			data.append(buffer, count: count)
		}
		guard let hex = String(data: data, encoding: .utf8),
			let key = decodeWrappingKey(hex.trimmingCharacters(in: .whitespacesAndNewlines))
		else { return .unsafe }
		return .valid(key)
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

	private static func storeX25519Key(_ keyData: Data, account: String) throws {
		guard keyData.count == 32 else { throw CryptoError.invalidKeySize(keyData.count) }
		let encoded = Data(keyData.base64EncodedString().utf8)
		try x25519KeyStore.write(account: account, data: encoded)
	}

	static func readX25519PrivateKey() throws -> Data? {
		guard let encoded = try x25519KeyStore.read(account: x25519Account) else { return nil }
		guard let base64 = String(data: encoded, encoding: .utf8),
			let key = Data(base64Encoded: base64)
		else {
			throw CryptoError.invalidStoredKey("The X25519 private key is not valid base64.")
		}
		guard key.count == 32 else { throw CryptoError.invalidKeySize(key.count) }
		return key
	}

	static func writeX25519PrivateKey(_ privateKey: Data) throws {
		try storeX25519Key(privateKey, account: x25519Account)
	}

	/// Get or create the X25519 keypair. Returns (privateKeyData, publicKeyData).
		static func getOrCreateX25519Keypair() throws -> (privateKey: Data, publicKey: Data) {
		if let existing = try readX25519PrivateKey() {
			return (existing, try x25519PublicFromPrivate(existing))
		}

			let (candidate, _) = generateX25519Keypair()
			let encoded = Data(candidate.base64EncodedString().utf8)
			do {
				try x25519KeyStore.add(account: x25519Account, data: encoded)
				return (candidate, try x25519PublicFromPrivate(candidate))
			} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
				guard let winner = try readX25519PrivateKey() else {
					throw KeychainStoreError.migrationConflict
				}
				return (winner, try x25519PublicFromPrivate(winner))
			}
		}

	// MARK: - Errors

	enum CryptoError: LocalizedError {
		case encryptionFailed
		case invalidFormat
		case invalidBase64
		case invalidIVSize(Int)
		case invalidKeySize(Int)
		case invalidUTF8
		case unsupportedCryptoVersion(Int)
		case contextTooLarge
		case invalidStoredKey(String)

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
			case .unsupportedCryptoVersion(let version):
				"Unsupported vault crypto version: \(version)"
			case .contextTooLarge:
				"Vault encryption context is too large"
			case .invalidStoredKey(let message):
				message
			}
		}
	}
}
