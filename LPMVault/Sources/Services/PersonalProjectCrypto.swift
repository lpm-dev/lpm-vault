import CryptoKit
import Darwin
import Foundation
import Security

struct PersonalKeyEnvelope: Codable, Equatable, Sendable {
  let personalKeyScheme: Int
  let personalRegistryOrigin: String
  let projectKeyVersion: Int
  let wrappedProjectKey: String
}

enum PersonalProjectCrypto {
  struct Project: Sendable {
    let envelope: PersonalKeyEnvelope
    let key: SymmetricKey
  }

  enum KeyError: LocalizedError {
    case invalidContext
    case missingRoot
    case invalidRoot
    case invalidCheckpoint
    case downgrade
    case storage

    var errorDescription: String? {
      switch self {
      case .invalidContext:
        "The personal env key does not match this registry, account, or project."
      case .missingRoot:
        "This Mac does not have this account's personal env root key. Recover it from a trusted device before syncing."
      case .invalidRoot: "The stored personal env root key is invalid."
      case .invalidCheckpoint: "The personal env key checkpoint is invalid."
      case .downgrade: "The cloud personal env key is older than the trusted local checkpoint."
      case .storage: "Could not read or save the protected personal env key checkpoint."
      }
    }
  }

  static func registryOrigin(_ value: String) throws -> String {
    guard var c = URLComponents(string: value),
      let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
      ["http", "https"].contains(scheme), !host.isEmpty,
      c.user == nil, c.password == nil, c.query == nil, c.fragment == nil
    else { throw KeyError.invalidContext }
    c.scheme = scheme
    c.host = host
    c.percentEncodedPath = ""
    if scheme == "https" && c.port == 443 || scheme == "http" && c.port == 80 { c.port = nil }
    guard let origin = c.url?.absoluteString, origin.utf8.count <= 2_048 else {
      throw KeyError.invalidContext
    }
    return origin
  }

  static func rootAccount(origin: String, principalID: String) throws -> String {
    guard try registryOrigin(origin) == origin, !principalID.isEmpty,
      principalID.utf8.count <= 128
    else { throw KeyError.invalidContext }
    var frame = Data("lpm-env-personal-root-v2\0".utf8)
    for component in [origin, principalID] {
      append(UInt32(component.utf8.count), to: &frame)
      frame.append(contentsOf: component.utf8)
    }
    return hex(Data(SHA256.hash(data: frame)))
  }

  static func associatedData(
    envelope: PersonalKeyEnvelope, principalID: String, vaultID: String,
    revision: Int? = nil
  ) throws -> Data {
    guard envelope.personalKeyScheme == 2,
      try registryOrigin(envelope.personalRegistryOrigin) == envelope.personalRegistryOrigin,
      !principalID.isEmpty, principalID.utf8.count <= 128,
      !vaultID.isEmpty, vaultID.utf8.count <= 256,
      let keyVersion = UInt32(exactly: envelope.projectKeyVersion),
      keyVersion > 0, keyVersion <= Int32.max
    else { throw KeyError.invalidContext }
    var frame = Data("lpm-env-personal-key\0".utf8)
    append(UInt32(2), to: &frame)
    frame.append(revision == nil ? 1 : 2)
    for component in [envelope.personalRegistryOrigin, principalID, vaultID] {
      append(UInt32(component.utf8.count), to: &frame)
      frame.append(contentsOf: component.utf8)
    }
    append(keyVersion, to: &frame)
    if let revision {
      guard revision > 0, revision <= Int32.max else { throw KeyError.invalidContext }
      append(UInt32(VaultCrypto.currentCryptoVersion), to: &frame)
      append(UInt64(revision), to: &frame)
    }
    return frame
  }

  static func create(
    root: SymmetricKey, registryOrigin: String, principalID: String, vaultID: String,
    version: Int
  ) throws -> Project {
    let key = VaultCrypto.generateAESKey()
    let context = PersonalKeyEnvelope(
      personalKeyScheme: 2,
      personalRegistryOrigin: registryOrigin, projectKeyVersion: version, wrappedProjectKey: "")
    let wrapped = try VaultCrypto.encrypt(
      key: root, plaintext: key.withUnsafeBytes { Data($0) },
      associatedData: associatedData(envelope: context, principalID: principalID, vaultID: vaultID))
    return Project(
      envelope: PersonalKeyEnvelope(
        personalKeyScheme: 2,
        personalRegistryOrigin: registryOrigin, projectKeyVersion: version,
        wrappedProjectKey: wrapped), key: key)
  }

  static func open(
    root: SymmetricKey, envelope: PersonalKeyEnvelope, registryURL: String,
    principalID: String, vaultID: String
  ) throws -> Project {
    guard try registryOrigin(registryURL) == envelope.personalRegistryOrigin else {
      throw KeyError.invalidContext
    }
    let bytes = try VaultCrypto.decrypt(
      key: root, encoded: envelope.wrappedProjectKey,
      associatedData: associatedData(envelope: envelope, principalID: principalID, vaultID: vaultID)
    )
    guard bytes.count == 32 else { throw KeyError.invalidContext }
    return Project(envelope: envelope, key: SymmetricKey(data: bytes))
  }

  static func encrypt(
    project: Project, plaintext: Data, principalID: String, vaultID: String, revision: Int
  ) throws -> (encryptedBlob: String, wrappedKey: String) {
    let contentKey = VaultCrypto.generateAESKey()
    let blob = try VaultCrypto.encryptPayload(
      key: contentKey, plaintext: plaintext, scope: .personal,
      principalId: principalID, vaultId: vaultID, revision: revision)
    let wrapped = try VaultCrypto.encrypt(
      key: project.key, plaintext: contentKey.withUnsafeBytes { Data($0) },
      associatedData: associatedData(
        envelope: project.envelope, principalID: principalID, vaultID: vaultID, revision: revision))
    return (blob, wrapped)
  }

  static func decrypt(
    project: Project, encryptedBlob: String, wrappedKey: String, principalID: String,
    vaultID: String, revision: Int, cryptoVersion: Int
  ) throws -> Data {
    guard cryptoVersion == VaultCrypto.currentCryptoVersion else { throw KeyError.invalidContext }
    let contentKey = try VaultCrypto.decrypt(
      key: project.key, encoded: wrappedKey,
      associatedData: associatedData(
        envelope: project.envelope, principalID: principalID, vaultID: vaultID, revision: revision))
    guard contentKey.count == 32 else { throw KeyError.invalidContext }
    return try VaultCrypto.decryptPayload(
      key: SymmetricKey(data: contentKey), encoded: encryptedBlob,
      scope: .personal, principalId: principalID, vaultId: vaultID, revision: revision,
      cryptoVersion: cryptoVersion)
  }

  static func rootKey(registryURL: String, principalID: String, create: Bool) throws -> SymmetricKey
  {
    let account = try rootAccount(origin: registryOrigin(registryURL), principalID: principalID)
    let store = SharedKeychainStore(service: "dev.lpm.env-personal-root-v2")
    return try VaultKeychainTransactionLock.withLock {
      if let encoded = try store.read(account: account) { return try decodeRoot(encoded) }
      guard create else { throw KeyError.missingRoot }
      let candidate = VaultCrypto.generateAESKey()
      do {
        try store.add(
          account: account, data: Data(hex(candidate.withUnsafeBytes { Data($0) }).utf8))
      } catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {}
      guard let encoded = try store.read(account: account) else { throw KeyError.missingRoot }
      return try decodeRoot(encoded)
    }
  }

  static func decodeRoot(_ encoded: Data) throws -> SymmetricKey {
    guard let value = String(data: encoded, encoding: .utf8), value.utf8.count == 64 else {
      throw KeyError.invalidRoot
    }
    var bytes = Data(capacity: 32)
    var index = value.startIndex
    for _ in 0..<32 {
      let end = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<end], radix: 16) else { throw KeyError.invalidRoot }
      bytes.append(byte)
      index = end
    }
    return SymmetricKey(data: bytes)
  }

  static func checkpoint(
    registryURL: String, principalID: String, vaultID: String, advanceTo: Int? = nil,
    homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> Int {
    let account = try rootAccount(origin: registryOrigin(registryURL), principalID: principalID)
    guard !vaultID.isEmpty, vaultID.utf8.count <= 256 else { throw KeyError.invalidContext }
    let name =
      ".env-project-key-floor-" + hex(Data(SHA256.hash(data: Data((account + vaultID).utf8))))
    let operation = {
      let home = homeURL.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      guard home >= 0 else { throw KeyError.storage }
      defer { Darwin.close(home) }
      let directory = Darwin.openat(home, ".lpm", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard directory >= 0 else { throw KeyError.storage }
      defer { Darwin.close(directory) }
      try validateDirectory(directory, home: home)
      let descriptor = Darwin.openat(
        directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      let floor: Int
      if descriptor < 0 {
        guard errno == ENOENT else { throw KeyError.storage }
        floor = 0
      } else {
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == Darwin.geteuid(),
          metadata.st_nlink == 1, metadata.st_mode & 0o777 == 0o600,
          metadata.st_size > 0, metadata.st_size <= 10
        else { throw KeyError.invalidCheckpoint }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size) + 1)
        let count = try bytes.withUnsafeMutableBytes { buffer in
          var offset = 0
          while offset < buffer.count {
            let count = Darwin.read(
              descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw KeyError.storage }
            if count == 0 { break }
            offset += count
          }
          return offset
        }
        var path = stat()
        guard Darwin.fstatat(directory, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
          path.st_dev == metadata.st_dev, path.st_ino == metadata.st_ino,
          path.st_nlink == 1, path.st_mode & 0o777 == 0o600,
          count == metadata.st_size, let text = String(bytes: bytes.prefix(count), encoding: .utf8),
          let value = Int(text), value > 0, value <= Int32.max, String(value) == text
        else { throw KeyError.invalidCheckpoint }
        floor = value
      }
      try validateDirectory(directory, home: home)
      guard let next = advanceTo else { return floor }
      guard next >= floor, next > 0, next <= Int32.max else { throw KeyError.downgrade }
      if next > floor {
        let temporary = name + "." + UUID().uuidString
        let file = Darwin.openat(
          directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw KeyError.storage }
        defer {
          Darwin.close(file)
          Darwin.unlinkat(directory, temporary, 0)
        }
        let bytes = Data(String(next).utf8)
        try bytes.withUnsafeBytes { buffer in
          var offset = 0
          while offset < buffer.count {
            let count = Darwin.write(
              file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw KeyError.storage }
            offset += count
          }
        }
        guard Darwin.fsync(file) == 0 else { throw KeyError.storage }
        try validateDirectory(directory, home: home)
        guard Darwin.renameat(directory, temporary, directory, name) == 0,
          Darwin.fsync(directory) == 0
        else { throw KeyError.storage }
        try validateDirectory(directory, home: home)
      }
      return next
    }
    if homeURL == FileManager.default.homeDirectoryForCurrentUser {
      return try VaultKeychainTransactionLock.withLock(operation)
    }
    let lock = try VaultKeychainTransactionLock.openLockFile(homeURL: homeURL)
    defer {
      _ = flock(lock, LOCK_UN)
      _ = Darwin.close(lock)
    }
    return try operation()
  }

  private static func validateDirectory(_ directory: Int32, home: Int32) throws {
    var actual = stat()
    var path = stat()
    guard Darwin.fstat(directory, &actual) == 0,
      Darwin.fstatat(home, ".lpm", &path, AT_SYMLINK_NOFOLLOW) == 0,
      actual.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      path.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      actual.st_uid == Darwin.geteuid(), actual.st_mode & 0o777 == 0o700,
      actual.st_dev == path.st_dev, actual.st_ino == path.st_ino
    else { throw KeyError.storage }
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }

  static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

struct PersonalProjectKeyStore: Sendable {
  let root: @Sendable (String, String, Bool) throws -> SymmetricKey
  let checkpoint: @Sendable (String, String, String, Int?) throws -> Int

  static let live = PersonalProjectKeyStore(
    root: { try PersonalProjectCrypto.rootKey(registryURL: $0, principalID: $1, create: $2) },
    checkpoint: {
      try PersonalProjectCrypto.checkpoint(
        registryURL: $0, principalID: $1, vaultID: $2, advanceTo: $3)
    }
  )

  func validate(
    envelope: PersonalKeyEnvelope?, registryURL: String, principalID: String, vaultID: String
  ) throws {
    if let envelope {
      guard try PersonalProjectCrypto.registryOrigin(registryURL) == envelope.personalRegistryOrigin
      else {
        throw PersonalProjectCrypto.KeyError.invalidContext
      }
      _ = try PersonalProjectCrypto.associatedData(
        envelope: envelope, principalID: principalID, vaultID: vaultID)
    }
    guard
      (envelope?.projectKeyVersion ?? 0) >= (try checkpoint(registryURL, principalID, vaultID, nil))
    else {
      throw PersonalProjectCrypto.KeyError.downgrade
    }
  }

  func remember(envelope: PersonalKeyEnvelope, principalID: String, vaultID: String) throws {
    _ = try PersonalProjectCrypto.associatedData(
      envelope: envelope, principalID: principalID, vaultID: vaultID)
    _ = try checkpoint(
      envelope.personalRegistryOrigin, principalID, vaultID, envelope.projectKeyVersion)
  }
}
