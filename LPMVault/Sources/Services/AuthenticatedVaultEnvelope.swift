import CryptoKit
import Foundation

enum AuthenticatedVaultEnvelopeParser {
  enum VaultOperation: String, Sendable {
    case pull = "vault.pull"
    case inspect = "vault.inspect"
    case write = "vault.write"
  }

  private static let envelopeVersion = 3
  private static let maximumRevision = Int(Int32.max)
  private static let maximumMemberCount = 10_000

  static func decodeVaultResponse(
    _ body: Data,
    statusCode: Int,
    operation: VaultOperation,
    requestNonce: String,
    vaultID: String,
    organizationSlug: String? = nil
  ) throws -> SyncService.SyncStatus {
    let envelope = try decodeEnvelope(
      body,
      operation: operation.rawValue,
      requestNonce: requestNonce
    )
    try validateVaultStatus(
      statusCode,
      operation: operation,
      outcome: envelope.outcome
    )
    let binding = try validateVaultBinding(
      envelope.binding,
      outcome: envelope.outcome,
      vaultID: vaultID,
      organizationSlug: organizationSlug
    )
    var fields = SyncFields(
      vaultID: vaultID,
      operation: operation.rawValue,
      outcome: envelope.outcome,
      envelopeVersion: envelopeVersion,
      scope: binding.scope,
      principalID: binding.principalID,
      callerUserID: binding.callerUserID,
      organizationID: binding.organizationID,
      organizationSlug: binding.organizationSlug,
      requestNonce: envelope.requestNonce
    )

    switch (operation, envelope.outcome) {
    case (.pull, "current"):
      let organizationFields = organizationSlug == nil
        ? []
        : [
          "contentKeyVersion",
          "recipientPublicKeyVersion",
          "recipientPublicKeyFingerprint",
        ]
      try envelope.data.requireExactKeys(
        [
          "encryptedBlob", "wrappedKey", "revision", "cryptoVersion", "updatedAt",
        ] + organizationFields
      )
      let encryptedBlob = try envelope.data.validString(
        "encryptedBlob",
        maximumBytes: 16 * 1024 * 1024
      )
      let wrappedKey = try envelope.data.validString("wrappedKey", maximumBytes: 4_096)
      let revision = try envelope.data.revision("revision")
      let cryptoVersion = try envelope.data.currentCryptoVersion()
      let updatedAt = try envelope.data.timestamp("updatedAt")
      fields.encryptedBlob = encryptedBlob
      fields.wrappedKey = wrappedKey
      fields.version = revision
      fields.serverVersion = revision
      fields.cryptoVersion = cryptoVersion
      fields.updatedAt = updatedAt
      if organizationSlug != nil {
        fields.contentKeyVersion = try envelope.data.revision("contentKeyVersion")
        fields.recipientPublicKeyVersion = try envelope.data.revision(
          "recipientPublicKeyVersion"
        )
        fields.recipientPublicKeyFingerprint = try envelope.data.fingerprint(
          "recipientPublicKeyFingerprint"
        )
      }
    case (.inspect, "current"):
      try envelope.data.requireExactKeys(["revision", "cryptoVersion"])
      let revision = try envelope.data.revision("revision")
      fields.version = revision
      fields.serverVersion = revision
      fields.cryptoVersion = try envelope.data.currentCryptoVersion()
    case (.pull, "missing"), (.inspect, "missing"):
      try envelope.data.requireExactKeys(["retainedRevision"])
      fields.serverVersion = try envelope.data.revision(
        "retainedRevision",
        allowZero: true
      )
      fields.code = "vault_missing"
      fields.error = "Vault not found"
    case (.pull, "memberRewrapRequired"):
      try envelope.data.requireExactKeys(["revision", "contentKeyVersion"])
      fields.serverVersion = try envelope.data.revision("revision")
      fields.contentKeyVersion = try envelope.data.revision("contentKeyVersion")
      fields.code = "vault_member_needs_rewrap"
      fields.error = "Organization env key must be rewrapped for this member"
    case (.write, "committed"):
      let required = organizationSlug == nil
        ? ["revision", "cryptoVersion", "action"]
        : ["revision", "contentKeyVersion", "cryptoVersion", "action"]
      try envelope.data.requireExactKeys(required)
      let revision = try envelope.data.revision("revision")
      fields.version = revision
      fields.serverVersion = revision
      fields.cryptoVersion = try envelope.data.currentCryptoVersion()
      let action = try envelope.data.validString("action", maximumBytes: 16)
      guard ["synced", "shared", "rotated"].contains(action) else {
        throw EnvelopeError.invalid("The authenticated env write action is invalid.")
      }
      fields.status = action
      if organizationSlug != nil {
        fields.contentKeyVersion = try envelope.data.revision("contentKeyVersion")
      }
    case (.write, "principalChanged"):
      try envelope.data.requireExactKeys([])
      fields.code = "vault_principal_changed"
      fields.error = "The authenticated principal changed"
    case (.write, "recreationIntentRequired"):
      try envelope.data.requireExactKeys(["retainedRevision"])
      fields.serverVersion = try envelope.data.revision(
        "retainedRevision",
        allowZero: true
      )
      fields.code = "vault_recreation_intent_required"
      fields.error = "Vault recreation intent is required"
    case (.write, "ciphertextRevisionMismatch"):
      try envelope.data.requireExactKeys(
        ["requiredCiphertextRevision"],
        optional: ["currentRevision", "retainedRevision"]
      )
      let requiredRevision = try envelope.data.revision("requiredCiphertextRevision")
      let current = try envelope.data.optionalRevision("currentRevision")
      let retained = try envelope.data.optionalRevision("retainedRevision", allowZero: true)
      guard (current == nil) != (retained == nil),
        let floor = current ?? retained,
        floor < maximumRevision,
        requiredRevision == floor + 1
      else {
        throw EnvelopeError.invalid("The authenticated ciphertext revision is inconsistent.")
      }
      fields.serverVersion = floor
      fields.code = "vault_ciphertext_revision_mismatch"
      fields.error = "Ciphertext revision does not follow the server revision"
    case (
      .write,
      let outcome
    ) where [
      "expectedRevisionRequired",
      "creationConflict",
      "revisionConflict",
      "memberRewrapRequired",
      "contentKeyRotationRequired",
    ].contains(outcome):
      try envelope.data.requireExactKeys(["currentRevision"])
      fields.serverVersion = try envelope.data.revision("currentRevision")
      let mapping: [String: (String, String)] = [
        "expectedRevisionRequired": (
          "vault_expected_version_required",
          "The current vault revision is required"
        ),
        "creationConflict": (
          "vault_creation_conflict",
          "The vault was created concurrently"
        ),
        "revisionConflict": (
          "vault_version_conflict",
          "The vault changed concurrently"
        ),
        "memberRewrapRequired": (
          "vault_member_needs_rewrap",
          "Organization env key must be rewrapped for this member"
        ),
        "contentKeyRotationRequired": (
          "vault_content_key_rotation_required",
          "The organization content key must be rotated"
        ),
      ]
      guard let mapped = mapping[outcome] else {
        throw EnvelopeError.invalid("The authenticated env outcome is unsupported.")
      }
      fields.code = mapped.0
      fields.error = mapped.1
    case (_, "rejected"):
      try envelope.data.requireExactKeys(["code", "message"])
      fields.code = try envelope.data.validString("code", maximumBytes: 128)
      fields.error = try envelope.data.validString("message", maximumBytes: 1_024)
    default:
      throw EnvelopeError.invalid("The authenticated env outcome is unsupported.")
    }

    return fields.statusValue
  }

  static func decodeMemberInventory(
    _ body: Data,
    statusCode: Int,
    requestNonce: String,
    organizationSlug: String,
    expectedCallerUserID: String?
  ) throws -> SyncService.MemberKeyAccess {
    let envelope = try decodeEnvelope(
      body,
      operation: "organization.memberKeys.read",
      requestNonce: requestNonce
    )
    switch (envelope.outcome, statusCode) {
    case ("current", 200): break
    case ("rejected", 403), ("rejected", 404), ("rejected", 413), ("rejected", 500):
      try validateMemberInventoryRejectionBinding(
        envelope.binding,
        organizationSlug: organizationSlug,
        expectedCallerUserID: expectedCallerUserID
      )
      try envelope.data.requireExactKeys(["code", "message"])
      _ = try envelope.data.validString("code", maximumBytes: 128)
      _ = try envelope.data.validString("message", maximumBytes: 1_024)
      throw EnvelopeError.rejected
    default:
      throw EnvelopeError.invalid("The member-key response outcome does not match its status.")
    }

    guard case .organization(
      let organizationID,
      let callerUserID,
      let responseSlug,
      nil
    ) = envelope.binding,
      responseSlug == organizationSlug,
      isCanonicalUUID(organizationID),
      isValidString(callerUserID, maximumBytes: 256),
      expectedCallerUserID.map({ $0 == callerUserID }) ?? true
    else {
      throw EnvelopeError.invalid("The member-key response binding does not match the request.")
    }
    try envelope.data.requireExactKeys(["capability", "members"])
    let capability = try envelope.data.validString("capability", maximumBytes: 64)
    let canReplaceWrappedKeys: Bool
    switch capability {
    case "replaceWrappedKeysAllowed": canReplaceWrappedKeys = true
    case "replaceWrappedKeysForbidden": canReplaceWrappedKeys = false
    default:
      throw EnvelopeError.invalid("The member-key response capability is invalid.")
    }
    let memberValues = try envelope.data.array("members")
    guard memberValues.count <= maximumMemberCount else {
      throw EnvelopeError.invalid("The member-key response is too large.")
    }
    var previousUserID: String?
    var callerCount = 0
    var members: [SyncService.MemberPublicKey] = []
    members.reserveCapacity(memberValues.count)
    for value in memberValues {
      guard case .object(let member) = value else {
        throw EnvelopeError.invalid("The member-key response contains an invalid member.")
      }
      try member.requireExactKeys(["userId", "role", "sharingKey"])
      let userID = try member.validString("userId", maximumBytes: 256)
      let role = try member.validString("role", maximumBytes: 64)
      guard previousUserID.map({ userID > $0 }) ?? true else {
        throw EnvelopeError.invalid("The member-key response is not uniquely ordered.")
      }
      previousUserID = userID
      if userID == callerUserID { callerCount += 1 }
      switch member["sharingKey"] {
      case .null:
        members.append(
          SyncService.MemberPublicKey(
            userId: userID,
            role: role,
            publicKey: nil,
            publicKeyVersion: nil,
            publicKeyFingerprint: nil,
            hasPublicKey: false,
            validatedSharingKey: nil
          )
        )
      case .object(let sharingKey):
        let key = try parseSharingKey(sharingKey, requiresTimestamps: false)
        members.append(
          SyncService.MemberPublicKey(
            userId: userID,
            role: role,
            publicKey: key.canonicalBase64,
            publicKeyVersion: key.version,
            publicKeyFingerprint: key.fingerprint,
            hasPublicKey: true,
            validatedSharingKey: key
          )
        )
      default:
        throw EnvelopeError.invalid("The member-key response contains an invalid sharing key.")
      }
    }
    guard callerCount == 1 else {
      throw EnvelopeError.invalid("The member-key response must contain the caller once.")
    }
    return SyncService.MemberKeyAccess(
      organizationID: organizationID,
      callerUserID: callerUserID,
      members: members,
      canReplaceWrappedKeys: canReplaceWrappedKeys
    )
  }

  static func decodeSharingKeyRead(
    _ body: Data,
    statusCode: Int,
    requestNonce: String,
    expectedPrincipalID: String?
  ) throws -> SyncService.PublicKeyRecord {
    let envelope = try decodeEnvelope(
      body,
      operation: "sharingKey.read",
      requestNonce: requestNonce
    )
    guard case .account(let principalID, nil, nil) = envelope.binding,
      isValidString(principalID, maximumBytes: 128),
      expectedPrincipalID.map({ $0 == principalID }) ?? true
    else {
      throw EnvelopeError.invalid("The sharing-key response principal does not match.")
    }
    switch (envelope.outcome, statusCode) {
    case ("present", 200):
      try envelope.data.requireExactKeys(["sharingKey"])
      guard case .object(let sharingKey) = envelope.data["sharingKey"] else {
        throw EnvelopeError.invalid("The sharing-key response is invalid.")
      }
      let key = try parseSharingKey(sharingKey, requiresTimestamps: true)
      return SyncService.PublicKeyRecord(
        publicKey: key.canonicalBase64,
        publicKeyVersion: key.version,
        publicKeyFingerprint: key.fingerprint,
        principalId: principalID
      )
    case ("absent", 200):
      try envelope.data.requireExactKeys([])
      return SyncService.PublicKeyRecord(
        publicKey: nil,
        publicKeyVersion: nil,
        publicKeyFingerprint: nil,
        principalId: principalID
      )
    case ("rejected", 403), ("rejected", 404), ("rejected", 500):
      try envelope.data.requireExactKeys(["code", "message"])
      _ = try envelope.data.validString("code", maximumBytes: 128)
      _ = try envelope.data.validString("message", maximumBytes: 1_024)
      throw EnvelopeError.rejected
    default:
      throw EnvelopeError.invalid("The sharing-key response outcome does not match its status.")
    }
  }

  static func decodeSharingKeyWrite(
    _ body: Data,
    statusCode: Int,
    requestNonce: String,
    expectedPrincipalID: String
  ) throws -> SyncService.PublicKeyUploadResponse {
    let envelope = try decodeEnvelope(
      body,
      operation: "sharingKey.write",
      requestNonce: requestNonce
    )
    guard case .account(let principalID, nil, nil) = envelope.binding,
      principalID == expectedPrincipalID
    else {
      throw EnvelopeError.invalid("The sharing-key write response principal does not match.")
    }
    switch (envelope.outcome, statusCode) {
    case (let outcome, 200) where ["set", "unchanged", "rotated"].contains(outcome):
      try envelope.data.requireExactKeys(["sharingKey"])
      guard case .object(let sharingKey) = envelope.data["sharingKey"] else {
        throw EnvelopeError.invalid("The sharing-key write response is invalid.")
      }
      let key = try parseSharingKey(sharingKey, requiresTimestamps: true)
      return SyncService.PublicKeyUploadResponse(
        ok: true,
        status: outcome,
        publicKeyVersion: key.version,
        publicKeyFingerprint: key.fingerprint,
        error: nil,
        code: nil,
        expectedScope: nil
      )
    case ("principalChanged", 409):
      try envelope.data.requireExactKeys([])
      return rejectedSharingKeyWrite(
        status: "principalChanged",
        code: "sharing_key_principal_changed",
        message: "The authenticated principal changed"
      )
    case ("registrationConflict", 409):
      try envelope.data.requireExactKeys(["currentVersion", "currentFingerprint"])
      let version = try envelope.data.revision("currentVersion")
      let fingerprint = try envelope.data.fingerprint("currentFingerprint")
      return SyncService.PublicKeyUploadResponse(
        ok: false,
        status: "registrationConflict",
        publicKeyVersion: version,
        publicKeyFingerprint: fingerprint,
        error: "The sharing key changed concurrently",
        code: "sharing_key_registration_conflict",
        expectedScope: nil
      )
    case ("rateLimited", 429):
      try envelope.data.requireExactKeys(["retryAfterSeconds"])
      _ = try envelope.data.revision("retryAfterSeconds")
      return rejectedSharingKeyWrite(
        status: "rateLimited",
        code: "sharing_key_rate_limited",
        message: "Sharing-key write rate limit exceeded"
      )
    case ("stepUpRequired", 403):
      try envelope.data.requireExactKeys(["requiredScope"])
      let scope = try envelope.data.validString("requiredScope", maximumBytes: 64)
      guard ["vault:public-key:set", "vault:public-key:rotate"].contains(scope) else {
        throw EnvelopeError.invalid("The sharing-key step-up scope is invalid.")
      }
      return SyncService.PublicKeyUploadResponse(
        ok: false,
        status: "stepUpRequired",
        publicKeyVersion: nil,
        publicKeyFingerprint: nil,
        error: "Sharing-key write requires step-up authorization",
        code: "sharing_key_step_up_required",
        expectedScope: scope
      )
    case ("rejected", 400), ("rejected", 401), ("rejected", 403),
      ("rejected", 409), ("rejected", 413), ("rejected", 500):
      try envelope.data.requireExactKeys(["code", "message"])
      return rejectedSharingKeyWrite(
        status: "rejected",
        code: try envelope.data.validString("code", maximumBytes: 128),
        message: try envelope.data.validString("message", maximumBytes: 1_024)
      )
    default:
      throw EnvelopeError.invalid("The sharing-key write outcome does not match its status.")
    }
  }

  private static func rejectedSharingKeyWrite(
    status: String,
    code: String,
    message: String
  ) -> SyncService.PublicKeyUploadResponse {
    SyncService.PublicKeyUploadResponse(
      ok: false,
      status: status,
      publicKeyVersion: nil,
      publicKeyFingerprint: nil,
      error: message,
      code: code,
      expectedScope: nil
    )
  }

  private static func decodeEnvelope(
    _ body: Data,
    operation: String,
    requestNonce: String
  ) throws -> WireEnvelope {
    try StrictJSONKeyValidator.validate(body)
    let envelope = try JSONDecoder().decode(WireEnvelope.self, from: body)
    guard envelope.envelopeVersion == envelopeVersion,
      envelope.operation == operation,
      envelope.requestNonce == requestNonce,
      isCanonicalRequestNonce(envelope.requestNonce)
    else {
      throw EnvelopeError.invalid("The authenticated response does not match the request.")
    }
    return envelope
  }

  private static func validateVaultStatus(
    _ statusCode: Int,
    operation: VaultOperation,
    outcome: String
  ) throws {
    let valid: Bool
    switch (operation, outcome) {
    case (.pull, "current"), (.inspect, "current"), (.write, "committed"):
      valid = statusCode == 200
    case (.pull, "missing"), (.inspect, "missing"):
      valid = statusCode == 404
    case (.pull, "memberRewrapRequired"):
      valid = statusCode == 403
    case (.write, "principalChanged"),
      (.write, "expectedRevisionRequired"),
      (.write, "recreationIntentRequired"),
      (.write, "ciphertextRevisionMismatch"),
      (.write, "creationConflict"),
      (.write, "revisionConflict"),
      (.write, "contentKeyRotationRequired"):
      valid = statusCode == 409
    case (.write, "memberRewrapRequired"):
      valid = statusCode == 403
    case (.pull, "rejected"), (.inspect, "rejected"):
      valid = [400, 402, 403, 404, 413, 426, 500].contains(statusCode)
    case (.write, "rejected"):
      valid = [400, 401, 402, 403, 404, 409, 413, 426, 500].contains(statusCode)
    default:
      valid = false
    }
    guard valid else {
      throw EnvelopeError.invalid("The authenticated env outcome does not match its status.")
    }
  }

  private static func validateVaultBinding(
    _ binding: WireBinding,
    outcome: String,
    vaultID: String,
    organizationSlug: String?
  ) throws -> ValidatedVaultBinding {
    if let organizationSlug {
      switch binding {
      case .organization(
        let principalID,
        let callerUserID,
        let responseSlug,
        .some(let responseVaultID)
      ):
        guard isCanonicalUUID(principalID),
          isValidString(callerUserID, maximumBytes: 256),
          responseSlug == organizationSlug,
          responseVaultID == vaultID
        else {
          throw EnvelopeError.invalid("The organization response binding does not match.")
        }
        return ValidatedVaultBinding(
          scope: "organization",
          principalID: principalID,
          callerUserID: callerUserID,
          organizationID: principalID,
          organizationSlug: responseSlug
        )
      case .account(let principalID, .some(let responseSlug), .some(let responseVaultID))
      where outcome == "rejected":
        guard isValidString(principalID, maximumBytes: 128),
          responseSlug == organizationSlug,
          responseVaultID == vaultID
        else {
          throw EnvelopeError.invalid("The account response binding does not match.")
        }
        return ValidatedVaultBinding(
          scope: "account",
          principalID: principalID,
          callerUserID: nil,
          organizationID: nil,
          organizationSlug: responseSlug
        )
      default:
        throw EnvelopeError.invalid("The organization response has the wrong binding scope.")
      }
    }

    guard case .personal(let principalID, let callerUserID, let responseVaultID) = binding,
      principalID == callerUserID,
      responseVaultID == vaultID,
      isValidString(principalID, maximumBytes: 128),
      isValidString(callerUserID, maximumBytes: 256)
    else {
      throw EnvelopeError.invalid("The personal response binding does not match.")
    }
    return ValidatedVaultBinding(
      scope: "personal",
      principalID: principalID,
      callerUserID: callerUserID,
      organizationID: nil,
      organizationSlug: nil
    )
  }

  private static func validateMemberInventoryRejectionBinding(
    _ binding: WireBinding,
    organizationSlug: String,
    expectedCallerUserID: String?
  ) throws {
    switch binding {
    case .account(let principalID, .some(let responseSlug), nil):
      guard responseSlug == organizationSlug,
        isValidString(principalID, maximumBytes: 128),
        expectedCallerUserID.map({ $0 == principalID }) ?? true
      else {
        throw EnvelopeError.invalid("The member-key rejection binding does not match.")
      }
    case .organization(let organizationID, let callerUserID, let responseSlug, nil):
      guard responseSlug == organizationSlug,
        isCanonicalUUID(organizationID),
        isValidString(callerUserID, maximumBytes: 256),
        expectedCallerUserID.map({ $0 == callerUserID }) ?? true
      else {
        throw EnvelopeError.invalid("The member-key rejection binding does not match.")
      }
    default:
      throw EnvelopeError.invalid("The member-key rejection binding is invalid.")
    }
  }

  private static func parseSharingKey(
    _ value: [String: LPMJSONValue],
    requiresTimestamps: Bool
  ) throws -> ValidatedSharingKey {
    let keys = requiresTimestamps
      ? ["algorithm", "publicKey", "version", "fingerprint", "createdAt", "updatedAt"]
      : ["algorithm", "publicKey", "version", "fingerprint"]
    try value.requireExactKeys(keys)
    guard try value.validString("algorithm", maximumBytes: 16) == "X25519" else {
      throw EnvelopeError.invalid("The authenticated response requires X25519.")
    }
    let encoded = try value.validString("publicKey", maximumBytes: 128)
    guard let publicKey = Data(base64Encoded: encoded),
      publicKey.count == 32,
      publicKey.base64EncodedString() == encoded
    else {
      throw EnvelopeError.invalid("The authenticated sharing key is invalid.")
    }
    do {
      try VaultCrypto.validateContributoryX25519PublicKey(publicKey)
    } catch {
      throw EnvelopeError.invalid("The authenticated sharing key is non-contributory.")
    }
    let fingerprint = try value.fingerprint("fingerprint")
    guard fingerprint == VaultCrypto.publicKeyFingerprint(publicKey) else {
      throw EnvelopeError.invalid("The authenticated sharing-key fingerprint does not match.")
    }
    if requiresTimestamps {
      _ = try value.timestamp("createdAt")
      _ = try value.timestamp("updatedAt")
    }
    return ValidatedSharingKey(
      canonicalBase64: encoded,
      rawRepresentation: publicKey,
      version: try value.revision("version"),
      fingerprint: fingerprint
    )
  }

  private static func isCanonicalRequestNonce(_ value: String) -> Bool {
    guard value.utf8.count == 43,
      value.utf8.allSatisfy({ byte in
        byte.isASCIIAlphaNumeric || byte == 45 || byte == 95
      })
    else { return false }
    let standard = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/") + "="
    guard let decoded = Data(base64Encoded: standard), decoded.count == 32 else {
      return false
    }
    return decoded.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "") == value
  }

  private static func isCanonicalUUID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }

  private static func isValidString(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty
      && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

private struct WireEnvelope: Decodable {
  let envelopeVersion: Int
  let operation: String
  let outcome: String
  let requestNonce: String
  let binding: WireBinding
  let data: [String: LPMJSONValue]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    try container.requireExactKeys([
      "envelopeVersion", "operation", "outcome", "requestNonce", "binding", "data",
    ])
    envelopeVersion = try container.decode(Int.self, forKey: "envelopeVersion")
    operation = try container.decode(String.self, forKey: "operation")
    outcome = try container.decode(String.self, forKey: "outcome")
    requestNonce = try container.decode(String.self, forKey: "requestNonce")
    binding = try container.decode(WireBinding.self, forKey: "binding")
    data = try container.decode([String: LPMJSONValue].self, forKey: "data")
  }
}

private enum WireBinding: Decodable {
  case personal(principalID: String, callerUserID: String, vaultID: String)
  case organization(
    principalID: String,
    callerUserID: String,
    organizationSlug: String,
    vaultID: String?
  )
  case account(principalID: String, organizationSlug: String?, vaultID: String?)

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let scope = try container.decode(String.self, forKey: "scope")
    switch scope {
    case "personal":
      try container.requireExactKeys(["scope", "principalId", "callerUserId", "vaultId"])
      self = .personal(
        principalID: try container.decode(String.self, forKey: "principalId"),
        callerUserID: try container.decode(String.self, forKey: "callerUserId"),
        vaultID: try container.decode(String.self, forKey: "vaultId")
      )
    case "organization":
      try container.requireExactKeys(
        ["scope", "principalId", "callerUserId", "organizationSlug"],
        optional: ["vaultId"]
      )
      self = .organization(
        principalID: try container.decode(String.self, forKey: "principalId"),
        callerUserID: try container.decode(String.self, forKey: "callerUserId"),
        organizationSlug: try container.decode(String.self, forKey: "organizationSlug"),
        vaultID: try container.decodeIfPresent(String.self, forKey: "vaultId")
      )
    case "account":
      try container.requireExactKeys(
        ["scope", "principalId"],
        optional: ["organizationSlug", "vaultId"]
      )
      self = .account(
        principalID: try container.decode(String.self, forKey: "principalId"),
        organizationSlug: try container.decodeIfPresent(String.self, forKey: "organizationSlug"),
        vaultID: try container.decodeIfPresent(String.self, forKey: "vaultId")
      )
    default:
      throw EnvelopeError.invalid("The authenticated response binding scope is unsupported.")
    }
  }
}

private struct ValidatedVaultBinding {
  let scope: String
  let principalID: String
  let callerUserID: String?
  let organizationID: String?
  let organizationSlug: String?
}

private struct SyncFields {
  let vaultID: String
  let operation: String
  let outcome: String
  let envelopeVersion: Int
  let scope: String
  let principalID: String
  let callerUserID: String?
  let organizationID: String?
  let organizationSlug: String?
  let requestNonce: String
  var version: Int?
  var cryptoVersion: Int?
  var contentKeyVersion: Int?
  var recipientPublicKeyVersion: Int?
  var recipientPublicKeyFingerprint: String?
  var status: String?
  var error: String?
  var code: String?
  var serverVersion: Int?
  var encryptedBlob: String?
  var wrappedKey: String?
  var updatedAt: String?

  init(
    vaultID: String,
    operation: String,
    outcome: String,
    envelopeVersion: Int,
    scope: String,
    principalID: String,
    callerUserID: String?,
    organizationID: String?,
    organizationSlug: String?,
    requestNonce: String
  ) {
    self.vaultID = vaultID
    self.operation = operation
    self.outcome = outcome
    self.envelopeVersion = envelopeVersion
    self.scope = scope
    self.principalID = principalID
    self.callerUserID = callerUserID
    self.organizationID = organizationID
    self.organizationSlug = organizationSlug
    self.requestNonce = requestNonce
  }

  var statusValue: SyncService.SyncStatus {
    SyncService.SyncStatus(
      vaultId: vaultID,
      version: version,
      cryptoVersion: cryptoVersion,
      contentKeyVersion: contentKeyVersion,
      recipientPublicKeyVersion: recipientPublicKeyVersion,
      recipientPublicKeyFingerprint: recipientPublicKeyFingerprint,
      status: status,
      error: error,
      code: code,
      serverVersion: serverVersion,
      hint: nil,
      encryptedBlob: encryptedBlob,
      wrappedKey: wrappedKey,
      updatedAt: updatedAt,
      envelopeVersion: envelopeVersion,
      scope: scope,
      organizationSlug: organizationSlug,
      requestNonce: requestNonce,
      principalId: principalID,
      callerUserId: callerUserID,
      organizationId: organizationID,
      operation: operation,
      outcome: outcome
    )
  }
}

private enum EnvelopeError: Error {
  case invalid(String)
  case rejected
}

private struct DynamicCodingKey: CodingKey, Hashable {
  let stringValue: String
  let intValue: Int? = nil

  init(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    return nil
  }
}

private extension KeyedDecodingContainer where Key == DynamicCodingKey {
  func requireExactKeys(_ required: [String], optional: [String] = []) throws {
    let requiredSet = Set(required)
    let allowed = requiredSet.union(optional)
    let actual = Set(allKeys.map(\.stringValue))
    guard requiredSet.isSubset(of: actual), actual.isSubset(of: allowed) else {
      throw EnvelopeError.invalid("The authenticated response has invalid fields.")
    }
  }

  func decode<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
    try decode(type, forKey: DynamicCodingKey(stringValue: key))
  }

  func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
    try decodeIfPresent(type, forKey: DynamicCodingKey(stringValue: key))
  }
}

private extension Dictionary where Key == String, Value == LPMJSONValue {
  func requireExactKeys(_ required: [String], optional: [String] = []) throws {
    let requiredSet = Set(required)
    let allowed = requiredSet.union(optional)
    let actual = Set(keys)
    guard requiredSet.isSubset(of: actual), actual.isSubset(of: allowed) else {
      throw EnvelopeError.invalid("The authenticated response data has invalid fields.")
    }
  }

  func validString(_ key: String, maximumBytes: Int) throws -> String {
    guard case .string(let value) = self[key],
      !value.isEmpty,
      value.utf8.count <= maximumBytes,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw EnvelopeError.invalid("The authenticated response contains an invalid \(key).")
    }
    return value
  }

  func revision(_ key: String, allowZero: Bool = false) throws -> Int {
    guard case .integer(let raw) = self[key], let value = Int(exactly: raw),
      value >= (allowZero ? 0 : 1), value <= Int(Int32.max)
    else {
      throw EnvelopeError.invalid("The authenticated response contains an invalid \(key).")
    }
    return value
  }

  func optionalRevision(_ key: String, allowZero: Bool = false) throws -> Int? {
    guard self[key] != nil else { return nil }
    return try revision(key, allowZero: allowZero)
  }

  func currentCryptoVersion() throws -> Int {
    let value = try revision("cryptoVersion")
    guard value == VaultCrypto.currentCryptoVersion else {
      throw EnvelopeError.invalid("The authenticated response uses an unsupported crypto version.")
    }
    return value
  }

  func timestamp(_ key: String) throws -> String {
    let value = try validString(key, maximumBytes: 128)
    guard AuthSessionTimestamp.parse(value) != nil else {
      throw EnvelopeError.invalid("The authenticated response contains an invalid \(key).")
    }
    return value
  }

  func fingerprint(_ key: String) throws -> String {
    let value = try validString(key, maximumBytes: 64)
    guard value.utf8.count == 64,
      value.utf8.allSatisfy({ byte in byte.isASCIIDigit || (97...102).contains(byte) })
    else {
      throw EnvelopeError.invalid("The authenticated response contains an invalid \(key).")
    }
    return value
  }

  func array(_ key: String) throws -> [LPMJSONValue] {
    guard case .array(let value) = self[key] else {
      throw EnvelopeError.invalid("The authenticated response contains an invalid \(key).")
    }
    return value
  }
}

private extension UInt8 {
  var isASCIIAlphaNumeric: Bool {
    isASCIIDigit || (65...90).contains(self) || (97...122).contains(self)
  }

  var isASCIIDigit: Bool {
    (48...57).contains(self)
  }
}
