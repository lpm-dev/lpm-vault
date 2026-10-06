import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite("Personal project key envelopes")
struct PersonalKeyEnvelopeTests {
  private let nonce = String(repeating: "A", count: 43)

  @Test(
    "personal pulls and writes accept complete project key envelopes", arguments: [false, true])
  func personalResponsesAcceptProjectKeys(write: Bool) throws {
    let envelope = try response(write: write)
    let parsed = try parse(envelope, write: write)
    #expect(parsed.version == 3)
    #expect(parsed.personalKeys?.personalKeyScheme == 2)
    #expect(parsed.personalKeys?.personalRegistryOrigin == "https://lpm.dev")
    #expect(parsed.personalKeys?.projectKeyVersion == 1)
    #expect(parsed.personalKeys?.wrappedProjectKey == "wrapped-project-key")
  }

  @Test(
    "legacy personal responses remain valid without project key fields", arguments: [false, true])
  func legacyResponsesRemainValid(write: Bool) throws {
    var envelope = try response(write: write)
    var data = try #require(envelope["data"] as? [String: Any])
    for field in keyFields { data.removeValue(forKey: field) }
    envelope["data"] = data
    #expect(try parse(envelope, write: write).personalKeys == nil)
  }

  @Test(
    "partial, null, unsupported, and noncanonical key envelopes fail closed",
    arguments: [false, true])
  func invalidKeyFieldsAreRejected(write: Bool) throws {
    let original = try response(write: write)
    let originalData = try #require(original["data"] as? [String: Any])
    for field in keyFields {
      for value: Any? in [nil, NSNull()] {
        var envelope = original
        var data = originalData
        data[field] = value
        envelope["data"] = data
        #expect(throws: (any Error).self) { try parse(envelope, write: write) }
      }
    }
    for (field, value): (String, Any) in [
      ("personalKeyScheme", 1), ("personalKeyScheme", 3), ("personalKeyScheme", 2.5),
      ("projectKeyVersion", 0), ("projectKeyVersion", -1),
      ("projectKeyVersion", Int64(Int32.max) + 1),
      ("personalRegistryOrigin", "https://lpm.dev/"), ("personalRegistryOrigin", "https://LPM.dev"),
      ("personalRegistryOrigin", "https://lpm.dev/path"),
      ("personalRegistryOrigin", "https://user@lpm.dev"),
      ("wrappedProjectKey", ""), ("wrappedProjectKey", String(repeating: "x", count: 4097)),
      ("unknownKeyField", "unexpected"),
    ] {
      var envelope = original
      var data = originalData
      data[field] = value
      envelope["data"] = data
      #expect(throws: (any Error).self) { try parse(envelope, write: write) }
    }
  }

  @Test("organization responses reject personal project key extensions")
  func organizationResponsesRejectPersonalKeys() throws {
    var envelope = try response()
    envelope["binding"] = [
      "scope": "organization", "principalId": "00000000-0000-4000-8000-000000000001",
      "callerUserId": "user-a", "organizationSlug": "example", "vaultId": "project-a",
    ]
    var data = try #require(envelope["data"] as? [String: Any])
    data["contentKeyVersion"] = 1
    data["recipientPublicKeyVersion"] = 1
    data["recipientPublicKeyFingerprint"] = String(repeating: "a", count: 64)
    envelope["data"] = data
    #expect(throws: (any Error).self) {
      try AuthenticatedVaultEnvelopeParser.decodeVaultResponse(
        JSONSerialization.data(withJSONObject: envelope), statusCode: 200, operation: .pull,
        requestNonce: nonce, vaultID: "project-a", organizationSlug: "example")
    }
  }

  @Test("content key associated data matches the Rust and browser wire bytes")
  func associatedDataMatchesSharedContract() throws {
    let context = PersonalKeyEnvelope(
      personalKeyScheme: 2, personalRegistryOrigin: "https://lpm.dev", projectKeyVersion: 1,
      wrappedProjectKey: "")
    #expect(
      PersonalProjectCrypto.hex(
        try PersonalProjectCrypto.associatedData(
          envelope: context, principalID: "user-a", vaultID: "project-a", revision: 7))
        == "6c706d2d656e762d706572736f6e616c2d6b65790000000002020000000f68747470733a2f2f6c706d2e64657600000006757365722d610000000970726f6a6563742d6100000001000000030000000000000007"
    )
    #expect(
      try PersonalProjectCrypto.rootAccount(origin: "https://lpm.dev", principalID: "user-a")
        == "7182b6542cfabac509375892698ef0546c32cc0539fdcee3e52472977472f89a")
  }

  @Test("project and content keys authenticate registry, account, project, version, and revision")
  func encryptedKeysRejectContextSubstitution() throws {
    let root = SymmetricKey(data: Data(repeating: 7, count: 32))
    let project = try PersonalProjectCrypto.create(
      root: root, registryOrigin: "https://lpm.dev", principalID: "user-a", vaultID: "project-a",
      version: 1)
    let opened = try PersonalProjectCrypto.open(
      root: root, envelope: project.envelope, registryURL: "https://lpm.dev/api",
      principalID: "user-a", vaultID: "project-a")
    let first = try PersonalProjectCrypto.encrypt(
      project: project, plaintext: Data("first".utf8), principalID: "user-a", vaultID: "project-a",
      revision: 7)
    let second = try PersonalProjectCrypto.encrypt(
      project: project, plaintext: Data("second".utf8), principalID: "user-a", vaultID: "project-a",
      revision: 8)
    #expect(
      try PersonalProjectCrypto.decrypt(
        project: opened, encryptedBlob: first.encryptedBlob, wrappedKey: first.wrappedKey,
        principalID: "user-a", vaultID: "project-a", revision: 7, cryptoVersion: 3)
        == Data("first".utf8))
    let firstKey = try VaultCrypto.decrypt(
      key: project.key, encoded: first.wrappedKey,
      associatedData: PersonalProjectCrypto.associatedData(
        envelope: project.envelope, principalID: "user-a", vaultID: "project-a", revision: 7))
    let secondKey = try VaultCrypto.decrypt(
      key: project.key, encoded: second.wrappedKey,
      associatedData: PersonalProjectCrypto.associatedData(
        envelope: project.envelope, principalID: "user-a", vaultID: "project-a", revision: 8))
    #expect(firstKey != secondKey)
    for (origin, principal, vault) in [
      ("https://other.example", "user-a", "project-a"), ("https://lpm.dev", "user-b", "project-a"),
      ("https://lpm.dev", "user-a", "project-b"),
    ] {
      #expect(throws: (any Error).self) {
        try PersonalProjectCrypto.open(
          root: root, envelope: project.envelope, registryURL: origin, principalID: principal,
          vaultID: vault)
      }
    }
    let wrongRoot = SymmetricKey(data: Data(repeating: 8, count: 32))
    #expect(throws: (any Error).self) {
      try PersonalProjectCrypto.open(
        root: wrongRoot, envelope: project.envelope, registryURL: "https://lpm.dev",
        principalID: "user-a", vaultID: "project-a")
    }
    let rotated = PersonalKeyEnvelope(
      personalKeyScheme: 2, personalRegistryOrigin: "https://lpm.dev", projectKeyVersion: 2,
      wrappedProjectKey: project.envelope.wrappedProjectKey)
    #expect(throws: (any Error).self) {
      try PersonalProjectCrypto.open(
        root: root, envelope: rotated, registryURL: "https://lpm.dev", principalID: "user-a",
        vaultID: "project-a")
    }
    for (principal, vault, revision, cryptoVersion) in [
      ("user-b", "project-a", 7, 3), ("user-a", "project-b", 7, 3), ("user-a", "project-a", 8, 3),
      ("user-a", "project-a", 7, 2),
    ] {
      #expect(throws: (any Error).self) {
        try PersonalProjectCrypto.decrypt(
          project: opened, encryptedBlob: first.encryptedBlob, wrappedKey: first.wrappedKey,
          principalID: principal, vaultID: vault, revision: revision, cryptoVersion: cryptoVersion)
      }
    }
  }

  @Test("registry origins use canonical HTTP origins and reject credentials and decorations")
  func registryOriginsAreCanonical() throws {
    for (input, expected) in [
      ("https://LPM.dev:443/api", "https://lpm.dev"),
      ("http://localhost:80/api", "http://localhost"),
      ("https://lpm.dev:8443/api", "https://lpm.dev:8443"),
      ("https://[::1]:443/api", "https://[::1]"),
    ] {
      #expect(try PersonalProjectCrypto.registryOrigin(input) == expected)
    }
    for input in [
      "file:///tmp/a", "https://u:p@lpm.dev", "https://lpm.dev?x=y", "https://lpm.dev#fragment",
      "relative",
    ] {
      #expect(throws: (any Error).self) { try PersonalProjectCrypto.registryOrigin(input) }
    }
  }

  @Test("stored root keys require exactly 32 hexadecimal bytes")
  func rootEncodingIsStrict() throws {
    let root = try PersonalProjectCrypto.decodeRoot(Data(String(repeating: "07", count: 32).utf8))
    #expect(root.withUnsafeBytes { Data($0) } == Data(repeating: 7, count: 32))
    for encoded in [
      "", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
      String(repeating: "g", count: 64),
    ] {
      #expect(throws: (any Error).self) { try PersonalProjectCrypto.decodeRoot(Data(encoded.utf8)) }
    }
  }

  @Test("protected key checkpoints are monotonic and scoped to origin, account, and project")
  func keyCheckpointsAreMonotonicAndScoped() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    func checkpoint(
      _ origin: String = "https://lpm.dev", _ principal: String = "user-a",
      _ vault: String = "project-a", _ next: Int? = nil
    ) throws -> Int {
      try PersonalProjectCrypto.checkpoint(
        registryURL: origin, principalID: principal, vaultID: vault, advanceTo: next, homeURL: home)
    }
    #expect(try checkpoint() == 0)
    #expect(try checkpoint("https://lpm.dev", "user-a", "project-a", 2) == 2)
    #expect(try checkpoint() == 2)
    #expect(try checkpoint("https://lpm.dev", "user-a", "project-a", 2) == 2)
    #expect(throws: (any Error).self) {
      try checkpoint("https://lpm.dev", "user-a", "project-a", 1)
    }
    #expect(try checkpoint("https://other.example") == 0)
    #expect(try checkpoint("https://lpm.dev", "user-b") == 0)
    #expect(try checkpoint("https://lpm.dev", "user-a", "project-b") == 0)
    let files = try FileManager.default.contentsOfDirectory(
      at: home.appendingPathComponent(".lpm"), includingPropertiesForKeys: nil)
    #expect(files.filter { $0.lastPathComponent.hasPrefix(".env-project-key-floor-") }.count == 1)
  }

  @Test(
    "checkpoints reject symlinks, hard links, malformed data, and loose file permissions",
    arguments: ["symlink", "hardlink", "mode", "malformed", "directory", "fifo"])
  func hostileCheckpointFilesAreRejected(shape: String) throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try PersonalProjectCrypto.checkpoint(
      registryURL: "https://lpm.dev", principalID: "user-a", vaultID: "project-a", advanceTo: 1,
      homeURL: home)
    let directory = home.appendingPathComponent(".lpm")
    let floor = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
      { $0.lastPathComponent.hasPrefix(".env-project-key-floor-") })
    switch shape {
    case "symlink":
      let target = home.appendingPathComponent("target")
      try FileManager.default.moveItem(at: floor, to: target)
      try FileManager.default.createSymbolicLink(at: floor, withDestinationURL: target)
    case "hardlink":
      try FileManager.default.linkItem(at: floor, to: home.appendingPathComponent("other"))
    case "mode":
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: floor.path)
    case "malformed": try Data("0001".utf8).write(to: floor)
    case "directory":
      try FileManager.default.removeItem(at: floor)
      try FileManager.default.createDirectory(at: floor, withIntermediateDirectories: false)
    default:
      try FileManager.default.removeItem(at: floor)
      #expect(mkfifo(floor.path, 0o600) == 0)
    }
    #expect(throws: (any Error).self) {
      try PersonalProjectCrypto.checkpoint(
        registryURL: "https://lpm.dev", principalID: "user-a", vaultID: "project-a", homeURL: home)
    }
  }

  @Test("AES-GCM envelopes decrypt independently generated protocol vectors")
  func decryptsIndependentCryptoVector() throws {
    let envelope = PersonalKeyEnvelope(
      personalKeyScheme: 2, personalRegistryOrigin: "https://lpm.dev", projectKeyVersion: 1,
      wrappedProjectKey:
        "BgYGBgYGBgYGBgYG:ho6FG4W2ieY4Rv1h/lYepfDXmuXBR3QKoT6E/HHxfMgXuahCSKQPPcQKp72xBXhj")
    let project = try PersonalProjectCrypto.open(
      root: SymmetricKey(data: Data(repeating: 7, count: 32)), envelope: envelope,
      registryURL: "https://lpm.dev", principalID: "user-a", vaultID: "project-a")
    #expect(project.key.withUnsafeBytes { Data($0) } == Data(repeating: 11, count: 32))
    #expect(
      try PersonalProjectCrypto.decrypt(
        project: project,
        encryptedBlob:
          "CAgICAgICAgICAgI:dkTaWVTdeUYzCBlyueiK5ZljUeaDYZgYGJ6caONQ7+s8l2M/xHK6XsxkVvOu/IE=",
        wrappedKey:
          "BwcHBwcHBwcHBwcH:0rsH0xciIH828BVo1k2nNXK4q8DQQKlnh48mxLtzt9mCPKHRU2MULGiaMY0j6LnG",
        principalID: "user-a", vaultID: "project-a", revision: 7, cryptoVersion: 3)
        == Data("synthetic cross-language vector".utf8))
  }

  private var keyFields: [String] {
    ["personalKeyScheme", "personalRegistryOrigin", "projectKeyVersion", "wrappedProjectKey"]
  }
  private func response(write: Bool = false) throws -> [String: Any] {
    var data: [String: Any] =
      write
      ? ["revision": 3, "cryptoVersion": 3, "action": "synced"]
      : [
        "revision": 3, "cryptoVersion": 3, "encryptedBlob": "blob", "wrappedKey": "key",
        "updatedAt": "2026-10-06T20:00:00.000Z",
      ]
    data.merge([
      "personalKeyScheme": 2, "personalRegistryOrigin": "https://lpm.dev", "projectKeyVersion": 1,
      "wrappedProjectKey": "wrapped-project-key",
    ]) { _, new in new }
    return [
      "envelopeVersion": 3, "operation": write ? "vault.write" : "vault.pull",
      "outcome": write ? "committed" : "current", "requestNonce": nonce,
      "binding": [
        "scope": "personal", "principalId": "user-a", "callerUserId": "user-a",
        "vaultId": "project-a",
      ], "data": data,
    ]
  }
  private func parse(_ envelope: [String: Any], write: Bool) throws -> SyncService.SyncStatus {
    try AuthenticatedVaultEnvelopeParser.decodeVaultResponse(
      JSONSerialization.data(withJSONObject: envelope), statusCode: 200,
      operation: write ? .write : .pull, requestNonce: nonce, vaultID: "project-a")
  }
  private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    return home
  }
}
