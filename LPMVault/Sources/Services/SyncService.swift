import Foundation
import Security

indirect enum LPMJSONValue: Codable, Equatable, Sendable {
  case object([String: LPMJSONValue])
  case array([LPMJSONValue])
  case string(String)
  case integer(Int64)
  case number(Decimal)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Decimal.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: LPMJSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([LPMJSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value."
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

final class SyncService: @unchecked Sendable {
  typealias ResponseSignatureVerifier = @Sendable (HTTPURLResponse, Data, Bool) -> Bool

  enum AuthenticatedResponse<Value: Sendable>: Sendable {
    case response(Value?)
    case unauthorized

    var value: Value? {
      guard case .response(let value) = self else { return nil }
      return value
    }
  }

  private final class RetainedServices: @unchecked Sendable {
    let lock = NSLock()
    var values: [URL: SyncService] = [:]
  }

  private static let retainedServices = RetainedServices()

  static func shared(baseURL: URL = VaultConstants.apiBaseURL) -> SyncService {
    retainedServices.lock.withLock {
      if let retained = retainedServices.values[baseURL] { return retained }
      let service = SyncService(baseURL: baseURL)
      retainedServices.values[baseURL] = service
      return service
    }
  }

  private let apiBaseURL: URL
  private let session: URLSession
  private let responseSignatureVerifier: ResponseSignatureVerifier
  static let maximumVaultResponseBytes = 16 * 1024 * 1024
  private let maximumResponseBytes = 10 * 1024 * 1024
  private static let envelopeVersion = 3
  private static let requestNonceHeader = "X-LPM-Vault-Request-Nonce"

  init(
    baseURL: URL = VaultConstants.apiBaseURL,
    session: URLSession? = nil,
    responseSignatureVerifier: @escaping ResponseSignatureVerifier = { response, body, required in
      PinnedSessionDelegate.verifyResponseSignature(
        response,
        body: body,
        requireSignature: required
      )
    }
  ) {
    apiBaseURL = baseURL
    self.responseSignatureVerifier = responseSignatureVerifier
    self.session =
      session
      ?? URLSession(
        configuration: BoundedHTTPResponse.ephemeralConfiguration(
          requestTimeout: 30,
          resourceTimeout: 120
        ),
        delegate: PinnedSessionDelegate(),
        delegateQueue: nil
      )
  }

  struct SyncStatus: Sendable {
    let operation: String?
    let outcome: String?
    let vaultId: String?
    let version: Int?
    let cryptoVersion: Int?
    let envelopeVersion: Int?
    let scope: String?
    let principalId: String?
    let callerUserId: String?
    let organizationId: String?
    let userId: String?
    let organizationSlug: String?
    let requestNonce: String?
    let contentKeyVersion: Int?
    let recipientPublicKeyVersion: Int?
    let recipientPublicKeyFingerprint: String?
    let status: String?
    let error: String?
    let code: String?
    let serverVersion: Int?
    let hint: String?
    let encryptedBlob: String?
    let wrappedKey: String?
    let updatedAt: String?

    init(
      vaultId: String?,
      version: Int?,
      cryptoVersion: Int?,
      contentKeyVersion: Int?,
      recipientPublicKeyVersion: Int?,
      recipientPublicKeyFingerprint: String?,
      status: String?,
      error: String?,
      code: String?,
      serverVersion: Int?,
      hint: String?,
      encryptedBlob: String?,
      wrappedKey: String?,
      updatedAt: String?,
      envelopeVersion: Int? = nil,
      scope: String? = nil,
      organizationSlug: String? = nil,
      requestNonce: String? = nil,
      principalId: String? = nil,
      callerUserId: String? = nil,
      organizationId: String? = nil,
      userId: String? = nil,
      operation: String? = nil,
      outcome: String? = nil
	) {
      self.operation = operation
      self.outcome = outcome
      self.vaultId = vaultId
      self.version = version
      self.cryptoVersion = cryptoVersion
      self.envelopeVersion = envelopeVersion
      self.scope = scope
      self.principalId = principalId
      self.userId = userId
      self.organizationSlug = organizationSlug
      self.requestNonce = requestNonce
      self.contentKeyVersion = contentKeyVersion
      self.recipientPublicKeyVersion = recipientPublicKeyVersion
      self.recipientPublicKeyFingerprint = recipientPublicKeyFingerprint
      self.status = status
      self.error = error
      self.code = code
      self.serverVersion = serverVersion
      self.hint = hint
      self.encryptedBlob = encryptedBlob
      self.wrappedKey = wrappedKey
      self.updatedAt = updatedAt
      self.callerUserId = callerUserId
      self.organizationId = organizationId
    }

    var displayError: String? {
      guard let error else { return nil }
      guard let hint, !hint.isEmpty else { return error }
      return "\(error)\n\nHint: \(hint)"
    }
  }

  enum VersionPreflight: Sendable {
    case found(SyncStatus)
    case notFound
  }

  struct RemoteProject: Decodable, Identifiable {
    let vaultId: String
    let name: String?
    let version: Int?
    let updatedAt: String?
    let updatedBy: String?

    var id: String { vaultId }
  }

  enum ProjectListError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case invalidRequest
    case transport
    case unauthorized
    case sessionNotAuthorized
    case forbidden
    case rateLimited
    case server(Int)
    case invalidResponse
    case invalidPagination

    var requiresSignIn: Bool {
      self == .unauthorized || self == .sessionNotAuthorized
    }

    var errorDescription: String? {
      switch self {
      case .cancelled:
        "The request was cancelled."
      case .invalidRequest:
        "LPM Vault could not create the cloud request."
      case .transport:
        "Could not reach lpm.dev. Check your connection and try again."
      case .unauthorized:
        "Your lpm.dev session expired. Sign in again."
      case .sessionNotAuthorized:
        "This lpm.dev session cannot access cloud env projects. Sign in again to create a current session."
      case .forbidden:
        "Your lpm.dev account is not allowed to access these cloud env projects."
      case .rateLimited:
        "lpm.dev received too many requests. Wait a moment and retry."
      case .server(let status):
        "lpm.dev could not load env projects (HTTP \(status)). Try again later."
      case .invalidResponse:
        "lpm.dev returned an invalid env project response."
      case .invalidPagination:
        "lpm.dev returned invalid env project pagination data."
      }
    }
  }

  struct MemberPublicKey: Sendable {
    let userId: String
    let role: String
    let publicKey: String?
    let publicKeyVersion: Int?
    let publicKeyFingerprint: String?
    let hasPublicKey: Bool
    let validatedSharingKey: ValidatedSharingKey?

    init(
      userId: String,
      role: String,
      publicKey: String?,
      publicKeyVersion: Int?,
      publicKeyFingerprint: String?,
      hasPublicKey: Bool,
      validatedSharingKey: ValidatedSharingKey? = nil
    ) {
      self.userId = userId
      self.role = role
      self.publicKey = publicKey
      self.publicKeyVersion = publicKeyVersion
      self.publicKeyFingerprint = publicKeyFingerprint
      self.hasPublicKey = hasPublicKey
      self.validatedSharingKey = validatedSharingKey
    }
  }

  struct MemberKeyAccess: Sendable {
    let organizationID: String
    let callerUserID: String
    let members: [MemberPublicKey]
    let canReplaceWrappedKeys: Bool

    init(
      organizationID: String,
      callerUserID: String = "",
      members: [MemberPublicKey],
      canReplaceWrappedKeys: Bool
    ) {
      self.organizationID = organizationID
      self.callerUserID = callerUserID
      self.members = members
      self.canReplaceWrappedKeys = canReplaceWrappedKeys
    }
  }

  struct PublicKeyRecord: Decodable, Sendable, Equatable {
    let principalId: String?
    let publicKey: String?
    let publicKeyVersion: Int?
    let publicKeyFingerprint: String?

    init(
      publicKey: String?,
      publicKeyVersion: Int?,
      publicKeyFingerprint: String?,
      principalId: String? = nil
    ) {
      self.principalId = principalId
      self.publicKey = publicKey
      self.publicKeyVersion = publicKeyVersion
      self.publicKeyFingerprint = publicKeyFingerprint
    }
  }

  struct PublicKeyUploadResponse: Decodable, Sendable {
    let ok: Bool?
    let status: String?
    let publicKeyVersion: Int?
    let publicKeyFingerprint: String?
    let error: String?
    let code: String?
    let expectedScope: String?
  }

  struct WrappedMemberKey: Encodable, Sendable {
    let userId: String
    let wrappedKey: String
    let publicKeyVersion: Int
    let publicKeyFingerprint: String
  }

  private struct OrganizationPushBody: Encodable, Sendable {
    let encryptedBlob: String
    let cryptoVersion: Int
    let ciphertextRevision: Int
    let expectedOrganizationId: String
    let expectedCallerUserId: String
    let wrappedKeys: [WrappedMemberKey]?
    let expectedVersion: Int?
    let name: String?
    let schema: LPMJSONValue?
  }

  func pushAuthenticated(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int? = nil,
    force: Bool = false,
    recreateMissing: Bool = false,
    name: String? = nil,
    schema: LPMJSONValue? = nil
  ) async -> AuthenticatedResponse<SyncStatus> {
    let prepared = await preparePushAuthenticated(
      authToken: authToken,
      expectedPrincipalId: expectedPrincipalId,
      vaultId: vaultId,
      encryptedBlob: encryptedBlob,
      wrappedKey: wrappedKey,
      expectedVersion: expectedVersion,
      force: force,
      recreateMissing: recreateMissing,
      name: name,
      schema: schema
    )
    return await prepared.start().value()
  }

  func preparePushAuthenticated(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int? = nil,
    force: Bool = false,
    recreateMissing: Bool = false,
    name: String? = nil,
    schema: LPMJSONValue? = nil
  ) async -> PreparedRemoteOperation<AuthenticatedResponse<SyncStatus>> {
    await Task.detached(priority: .userInitiated) { [self] in
      preparedPushAuthenticated(
        authToken: authToken,
        expectedPrincipalId: expectedPrincipalId,
        vaultId: vaultId,
        encryptedBlob: encryptedBlob,
        wrappedKey: wrappedKey,
        expectedVersion: expectedVersion,
        force: force,
        recreateMissing: recreateMissing,
        name: name,
        schema: schema
      )
    }.value
  }

  private func preparedPushAuthenticated(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int?,
    force: Bool,
    recreateMissing: Bool,
    name: String?,
    schema: LPMJSONValue?
  ) -> PreparedRemoteOperation<AuthenticatedResponse<SyncStatus>> {
    guard let url = endpoint(["api", "vaults", vaultId, "sync"]) else {
      return .completed(.response(nil))
    }
    let previousRevision = expectedVersion ?? 0
    guard previousRevision >= 0, previousRevision < Int(Int32.max) else {
      return .completed(.response(nil))
    }
    var body: [String: LPMJSONValue] = [
      "encryptedBlob": .string(encryptedBlob),
      "wrappedKey": .string(wrappedKey),
      "cryptoVersion": .integer(Int64(VaultCrypto.currentCryptoVersion)),
      "ciphertextRevision": .integer(Int64(previousRevision + 1)),
      "expectedPrincipalId": .string(expectedPrincipalId),
    ]
    if let expectedVersion { body["expectedVersion"] = .integer(Int64(expectedVersion)) }
    if force { body["force"] = .bool(true) }
    if recreateMissing { body["recreateMissing"] = .bool(true) }
    if let name, !name.isEmpty { body["name"] = .string(name) }
    if let schema { body["schema"] = schema }
    return prepareSyncRequest(
      url: url,
      method: "POST",
      token: authToken,
      body: LPMJSONValue.object(body),
      vaultId: vaultId,
      scope: .personal,
      policy: .write
    )
  }

  func push(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int? = nil,
    force: Bool = false,
    recreateMissing: Bool = false,
    name: String? = nil,
    schema: LPMJSONValue? = nil
  ) async -> SyncStatus? {
    await pushAuthenticated(
      authToken: authToken,
      expectedPrincipalId: expectedPrincipalId,
      vaultId: vaultId,
      encryptedBlob: encryptedBlob,
      wrappedKey: wrappedKey,
      expectedVersion: expectedVersion,
      force: force,
      recreateMissing: recreateMissing,
      name: name,
      schema: schema
    ).value
  }

  func pullAuthenticated(
    authToken: String,
    vaultId: String
  ) async -> AuthenticatedResponse<SyncStatus> {
    guard let url = endpoint(["api", "vaults", vaultId, "sync"]) else {
      return .response(nil)
    }
    return await syncRequest(
      url: url,
      method: "GET",
      token: authToken,
      vaultId: vaultId,
      scope: .personal,
      policy: .pull
    )
  }

  func versionPreflightAuthenticated(
    authToken: String,
    vaultId: String
  ) async -> AuthenticatedResponse<VersionPreflight> {
    guard let endpoint = endpoint(["api", "vaults", vaultId, "sync"]),
      var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      let nonce = Self.requestNonce()
    else { return .response(nil) }
    components.queryItems = [URLQueryItem(name: "versionOnly", value: "true")]
    guard let url = components.url else { return .response(nil) }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    request.setValue(nonce, forHTTPHeaderField: Self.requestNonceHeader)
    do {
      let (data, response) = try await BoundedHTTPResponse.load(
        for: request,
        using: session,
        maximumBytes: Self.maximumVaultResponseBytes
      )
      guard let http = response as? HTTPURLResponse else { return .response(nil) }
      if http.statusCode == 401,
        http.value(forHTTPHeaderField: "X-LPM-Response-Key-ID") == nil,
        http.value(forHTTPHeaderField: "X-LPM-Response-Signature") == nil
      {
        return .unauthorized
      }
      guard responseSignatureVerifier(http, data, true),
        let status = try? AuthenticatedVaultEnvelopeParser.decodeVaultResponse(
          data,
          statusCode: http.statusCode,
          operation: .inspect,
          requestNonce: nonce,
          vaultID: vaultId
        )
      else { return .response(nil) }
      if (200..<300).contains(http.statusCode) { return .response(.found(status)) }
      if http.statusCode == 404, status.outcome == "missing" {
        return .response(.notFound)
      }
      return .response(nil)
    } catch {
      return .response(nil)
    }
  }

  func pull(authToken: String, vaultId: String) async -> SyncStatus? {
    await pullAuthenticated(authToken: authToken, vaultId: vaultId).value
  }

  func pushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String? = nil,
    schema: LPMJSONValue? = nil
  ) async -> AuthenticatedResponse<SyncStatus> {
    let prepared = await preparePushOrgAuthenticated(
      authToken: authToken,
      orgSlug: orgSlug,
      expectedOrganizationID: expectedOrganizationID,
      expectedCallerUserID: expectedCallerUserID,
      vaultId: vaultId,
      encryptedBlob: encryptedBlob,
      wrappedKeys: wrappedKeys,
      expectedVersion: expectedVersion,
      name: name,
      schema: schema
    )
    return await prepared.start().value()
  }

  func preparePushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String? = nil,
    schema: LPMJSONValue? = nil
  ) async -> PreparedRemoteOperation<AuthenticatedResponse<SyncStatus>> {
    await Task.detached(priority: .userInitiated) { [self] in
      preparedPushOrgAuthenticated(
        authToken: authToken,
        orgSlug: orgSlug,
        expectedOrganizationID: expectedOrganizationID,
        expectedCallerUserID: expectedCallerUserID,
        vaultId: vaultId,
        encryptedBlob: encryptedBlob,
        wrappedKeys: wrappedKeys,
        expectedVersion: expectedVersion,
        name: name,
        schema: schema
      )
    }.value
  }

  func startPushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String? = nil,
    schema: LPMJSONValue? = nil
  ) -> StartedRemoteOperation<AuthenticatedResponse<SyncStatus>> {
    preparedPushOrgAuthenticated(
      authToken: authToken,
      orgSlug: orgSlug,
      expectedOrganizationID: expectedOrganizationID,
      expectedCallerUserID: expectedCallerUserID,
      vaultId: vaultId,
      encryptedBlob: encryptedBlob,
      wrappedKeys: wrappedKeys,
      expectedVersion: expectedVersion,
      name: name,
      schema: schema
    ).start()
  }

  private func preparedPushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) -> PreparedRemoteOperation<AuthenticatedResponse<SyncStatus>> {
    guard let url = endpoint(["api", "orgs", orgSlug, "vaults", vaultId]) else {
      return .completed(.response(nil))
    }
    let previousRevision = expectedVersion ?? 0
    guard previousRevision >= 0, previousRevision < Int(Int32.max) else {
      return .completed(.response(nil))
    }
    let body = OrganizationPushBody(
      encryptedBlob: encryptedBlob,
      cryptoVersion: VaultCrypto.currentCryptoVersion,
      ciphertextRevision: previousRevision + 1,
      expectedOrganizationId: expectedOrganizationID,
      expectedCallerUserId: expectedCallerUserID,
      wrappedKeys: wrappedKeys,
      expectedVersion: expectedVersion,
      name: name.flatMap { $0.isEmpty ? nil : $0 },
      schema: schema
    )
    return prepareSyncRequest(
      url: url,
      method: "POST",
      token: authToken,
      body: body,
      vaultId: vaultId,
      scope: .organization(slug: orgSlug),
      policy: .write
    )
  }

  func pushOrg(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String? = nil,
    schema: LPMJSONValue? = nil
  ) async -> SyncStatus? {
    await pushOrgAuthenticated(
      authToken: authToken,
      orgSlug: orgSlug,
      expectedOrganizationID: expectedOrganizationID,
      expectedCallerUserID: expectedCallerUserID,
      vaultId: vaultId,
      encryptedBlob: encryptedBlob,
      wrappedKeys: wrappedKeys,
      expectedVersion: expectedVersion,
      name: name,
      schema: schema
    ).value
  }

  func pullOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    vaultId: String
  ) async -> AuthenticatedResponse<SyncStatus> {
    guard let url = endpoint(["api", "orgs", orgSlug, "vaults", vaultId]) else {
      return .response(nil)
    }
    return await syncRequest(
      url: url,
      method: "GET",
      token: authToken,
      vaultId: vaultId,
      scope: .organization(slug: orgSlug),
      policy: .pull
    )
  }

  func pullOrg(authToken: String, orgSlug: String, vaultId: String) async -> SyncStatus? {
    await pullOrgAuthenticated(
      authToken: authToken,
      orgSlug: orgSlug,
      vaultId: vaultId
    ).value
  }

  func getOrgMemberKeyAccessAuthenticated(
    authToken: String,
    expectedCallerUserID: String,
    orgSlug: String
  ) async -> AuthenticatedResponse<MemberKeyAccess> {
    guard let url = endpoint(["api", "orgs", orgSlug, "members", "public-keys"]) else {
      return .response(nil)
    }
    return await authenticatedEnvelopeRequest(
      url: url,
      method: "GET",
      token: authToken,
      maximumBytes: maximumResponseBytes
    ) { data, statusCode, nonce in
      try AuthenticatedVaultEnvelopeParser.decodeMemberInventory(
        data,
        statusCode: statusCode,
        requestNonce: nonce,
        organizationSlug: orgSlug,
        expectedCallerUserID: expectedCallerUserID
      )
    }
  }

  func getOrgMemberKeyAccess(
    authToken: String,
    expectedCallerUserID: String,
    orgSlug: String
  ) async -> MemberKeyAccess? {
    await getOrgMemberKeyAccessAuthenticated(
      authToken: authToken,
      expectedCallerUserID: expectedCallerUserID,
      orgSlug: orgSlug
    ).value
  }

  func getMyPublicKeyAuthenticated(
    authToken: String,
    expectedPrincipalId: String
  ) async -> AuthenticatedResponse<PublicKeyRecord> {
    guard let url = endpoint(["api", "users", "me", "public-key"]) else {
      return .response(nil)
    }
    return await authenticatedEnvelopeRequest(
      url: url,
      method: "GET",
      token: authToken
    ) { data, statusCode, nonce in
      try AuthenticatedVaultEnvelopeParser.decodeSharingKeyRead(
        data,
        statusCode: statusCode,
        requestNonce: nonce,
        expectedPrincipalID: expectedPrincipalId
      )
    }
  }

  func getMyPublicKey(
    authToken: String,
    expectedPrincipalId: String
  ) async -> PublicKeyRecord? {
    await getMyPublicKeyAuthenticated(
      authToken: authToken,
      expectedPrincipalId: expectedPrincipalId
    ).value
  }

  func uploadPublicKey(
    authToken: String,
    expectedPrincipalId: String,
    publicKey: String,
    stepUpProof: String? = nil
  ) async -> PublicKeyUploadResponse? {
    guard let url = endpoint(["api", "users", "me", "public-key"]) else { return nil }
    var headers: [String: String] = [:]
    if let stepUpProof { headers["X-LPM-Step-Up-Proof"] = stepUpProof }
    let writeResponse = await authenticatedEnvelopeRequest(
      url: url,
      method: "POST",
      token: authToken,
      body: .object([
        "publicKey": .string(publicKey),
        "expectedPrincipalId": .string(expectedPrincipalId),
      ]),
      headers: headers
    ) { data, statusCode, nonce in
      try AuthenticatedVaultEnvelopeParser.decodeSharingKeyWrite(
        data,
        statusCode: statusCode,
        requestNonce: nonce,
        expectedPrincipalID: expectedPrincipalId
      )
    }.value
    guard let writeResponse else { return nil }
    guard writeResponse.ok == true else { return writeResponse }
    guard case .response(let authoritative) = await getMyPublicKeyAuthenticated(
      authToken: authToken,
      expectedPrincipalId: expectedPrincipalId
    ),
      authoritative?.publicKey == publicKey,
      authoritative?.publicKeyVersion == writeResponse.publicKeyVersion,
      authoritative?.publicKeyFingerprint == writeResponse.publicKeyFingerprint
    else { return nil }
    return writeResponse
  }

  func listPersonalProjects(authToken: String) async -> Result<[RemoteProject], ProjectListError> {
    await listProjects(authToken: authToken, path: ["api", "vaults"])
  }

  func listOrgProjects(authToken: String, orgSlug: String) async -> Result<
    [RemoteProject], ProjectListError
  > {
    await listProjects(authToken: authToken, path: ["api", "orgs", orgSlug, "vaults"])
  }

  private struct ProjectPage: Decodable {
    let vaults: [RemoteProject]
    let nextCursor: String?
  }

  private struct ErrorEnvelope: Decodable {
    let error: String?
  }

  private func listProjects(
    authToken: String,
    path: [String]
  ) async -> Result<[RemoteProject], ProjectListError> {
    guard var url = endpoint(path) else { return .failure(.invalidRequest) }
    var projects: [RemoteProject] = []
    var seenProjectIDs: Set<String> = []
    var cursor: String?
    var seenCursors: Set<String> = []
    var responseBytes = 0

    for _ in 0..<101 {
      if let cursor {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        guard let nextURL = components?.url else { return .failure(.invalidRequest) }
        url = nextURL
      }
      let remainingBytes = maximumResponseBytes - responseBytes
      guard remainingBytes > 0 else { return .failure(.invalidResponse) }
      let page: ProjectPage
      switch await loadProjectPage(
        url: url,
        authToken: authToken,
        maximumBytes: remainingBytes
      ) {
      case .success(let loaded):
        page = loaded.page
        responseBytes += loaded.byteCount
      case .failure(let error):
        return .failure(error)
      }
      guard projects.count + page.vaults.count <= 10_000 else {
        return .failure(.invalidPagination)
      }
      guard page.vaults.allSatisfy({ seenProjectIDs.insert($0.vaultId).inserted }) else {
        return .failure(.invalidPagination)
      }
      projects.append(contentsOf: page.vaults)
      guard let nextCursor = page.nextCursor else { return .success(projects) }
      guard !nextCursor.isEmpty, nextCursor.count <= 160,
        seenCursors.insert(nextCursor).inserted
      else { return .failure(.invalidPagination) }
      cursor = nextCursor
    }
    return .failure(.invalidPagination)
  }

  private func loadProjectPage(
    url: URL,
    authToken: String,
    maximumBytes: Int
  ) async -> Result<(page: ProjectPage, byteCount: Int), ProjectListError> {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await BoundedHTTPResponse.load(
        for: request,
        using: session,
        maximumBytes: maximumBytes
      )
      guard let http = response as? HTTPURLResponse else {
        return .failure(.invalidResponse)
      }
      switch http.statusCode {
      case 200..<300:
        guard let page = try? JSONDecoder().decode(ProjectPage.self, from: data) else {
          return .failure(.invalidResponse)
        }
        return .success((page, data.count))
      case 401:
        return .failure(.unauthorized)
      case 403:
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let normalized = envelope?.error?.lowercased() ?? ""
        if normalized.contains("requires a cli session")
          || normalized.contains("run `lpm login`")
        {
          return .failure(.sessionNotAuthorized)
        }
        return .failure(.forbidden)
      case 429:
        return .failure(.rateLimited)
      default:
        return .failure(.server(http.statusCode))
      }
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch is BoundedHTTPResponse.LoadError {
      return .failure(.invalidResponse)
    } catch {
      return .failure(.transport)
    }
  }

  private func endpoint(_ pathSegments: [String]) -> URL? {
    var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
    let encodedPath =
      pathSegments
      .map { segment in
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) ?? ""
      }
      .joined(separator: "/")
    components?.percentEncodedPath = "/\(encodedPath)"
    components?.query = nil
    components?.fragment = nil
    return components?.url
  }

  private enum EnvelopeScope: Sendable {
    case personal
    case organization(slug: String)

    var isPersonal: Bool {
      if case .personal = self { return true }
      return false
    }

    var organizationSlug: String? {
      guard case .organization(let slug) = self else { return nil }
      return slug
    }
  }

  private enum EnvelopePolicy: Sendable, Equatable {
    case pull
    case write
    case versionOnly

    var operation: String {
      switch self {
      case .pull: "vault.pull"
      case .write: "vault.write"
      case .versionOnly: "vault.inspect"
      }
    }

    var successOutcome: String {
      switch self {
      case .pull, .versionOnly: "current"
      case .write: "committed"
      }
    }

    var vaultOperation: AuthenticatedVaultEnvelopeParser.VaultOperation {
      switch self {
      case .pull: .pull
      case .write: .write
      case .versionOnly: .inspect
      }
    }
  }

  private func syncRequest(
    url: URL,
    method: String,
    token: String,
    body: LPMJSONValue? = nil,
    vaultId: String,
    scope: EnvelopeScope,
    policy: EnvelopePolicy
  ) async -> AuthenticatedResponse<SyncStatus> {
    await startSyncRequest(
      url: url,
      method: method,
      token: token,
      body: body,
      vaultId: vaultId,
      scope: scope,
      policy: policy
    ).value()
  }

  private func startSyncRequest(
    url: URL,
    method: String,
    token: String,
    body: LPMJSONValue? = nil,
    vaultId: String,
    scope: EnvelopeScope,
    policy: EnvelopePolicy
  ) -> StartedRemoteOperation<AuthenticatedResponse<SyncStatus>> {
    prepareSyncRequest(
      url: url,
      method: method,
      token: token,
      body: body,
      vaultId: vaultId,
      scope: scope,
      policy: policy
    ).start()
  }

  private func prepareSyncRequest<Body: Encodable>(
    url: URL,
    method: String,
    token: String,
    body: Body?,
    vaultId: String,
    scope: EnvelopeScope,
    policy: EnvelopePolicy
  ) -> PreparedRemoteOperation<AuthenticatedResponse<SyncStatus>> {
    guard let nonce = Self.requestNonce() else {
      return .completed(.response(nil))
    }
    return prepareRequest(
      url: url,
      method: method,
      token: token,
      body: body,
      signedSuccess: true,
      decode: { data, statusCode in
        try AuthenticatedVaultEnvelopeParser.decodeVaultResponse(
          data,
          statusCode: statusCode,
          operation: policy.vaultOperation,
          requestNonce: nonce,
          vaultID: vaultId,
          organizationSlug: scope.organizationSlug
        )
      },
      maximumBytes: Self.maximumVaultResponseBytes,
      headers: [Self.requestNonceHeader: nonce],
      validateNonSuccess: { _, _ in true }
    )
  }

  private static func requestNonce() -> String? {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    else { return nil }
    return Data(bytes)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func authenticatedEnvelopeRequest<T: Sendable>(
    url: URL,
    method: String,
    token: String,
    body: LPMJSONValue? = nil,
    maximumBytes: Int? = nil,
    headers: [String: String] = [:],
    decode: @escaping @Sendable (Data, Int, String) throws -> T
  ) async -> AuthenticatedResponse<T> {
    guard let nonce = Self.requestNonce() else { return .response(nil) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(nonce, forHTTPHeaderField: Self.requestNonceHeader)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      guard let encoded = try? JSONEncoder().encode(body) else { return .response(nil) }
      request.httpBody = encoded
    }
    do {
      let (data, response) = try await BoundedHTTPResponse.load(
        for: request,
        using: session,
        maximumBytes: maximumBytes ?? maximumResponseBytes
      )
      guard let http = response as? HTTPURLResponse else { return .response(nil) }
      if http.statusCode == 401,
        http.value(forHTTPHeaderField: "X-LPM-Response-Key-ID") == nil,
        http.value(forHTTPHeaderField: "X-LPM-Response-Signature") == nil
      {
        return .unauthorized
      }
      guard responseSignatureVerifier(http, data, true),
        let decoded = try? decode(data, http.statusCode, nonce)
      else { return .response(nil) }
      return .response(decoded)
    } catch {
      return .response(nil)
    }
  }

  private func request<T: Decodable & Sendable>(
    url: URL,
    method: String,
    token: String,
    body: LPMJSONValue? = nil,
    signedSuccess: Bool,
    maximumBytes: Int? = nil,
    headers: [String: String] = [:],
    validate: (@Sendable (T) -> Bool)? = nil,
    validateNonSuccess: (@Sendable (Int, T) -> Bool)? = nil
  ) async -> AuthenticatedResponse<T> {
    await startRequest(
      url: url,
      method: method,
      token: token,
      body: body,
      signedSuccess: signedSuccess,
      maximumBytes: maximumBytes,
      headers: headers,
      validate: validate,
      validateNonSuccess: validateNonSuccess
    ).value()
  }

  private func startRequest<T: Decodable & Sendable>(
    url: URL,
    method: String,
    token: String,
    body: LPMJSONValue? = nil,
    signedSuccess: Bool,
    maximumBytes: Int? = nil,
    headers: [String: String] = [:],
    validate: (@Sendable (T) -> Bool)? = nil,
    validateNonSuccess: (@Sendable (Int, T) -> Bool)? = nil
  ) -> StartedRemoteOperation<AuthenticatedResponse<T>> {
    prepareRequest(
      url: url,
      method: method,
      token: token,
      body: body,
      signedSuccess: signedSuccess,
      decode: { data, _ in try JSONDecoder().decode(T.self, from: data) },
      maximumBytes: maximumBytes,
      headers: headers,
      validate: validate,
      validateNonSuccess: validateNonSuccess
    ).start()
  }

  private func prepareRequest<T: Sendable, Body: Encodable>(
    url: URL,
    method: String,
    token: String,
    body: Body?,
    signedSuccess: Bool,
    decode: @escaping @Sendable (Data, Int) throws -> T,
    maximumBytes: Int? = nil,
    headers: [String: String] = [:],
    validate: (@Sendable (T) -> Bool)? = nil,
    validateNonSuccess: (@Sendable (Int, T) -> Bool)? = nil
  ) -> PreparedRemoteOperation<AuthenticatedResponse<T>> {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      guard let encoded = try? JSONEncoder().encode(body) else {
        return .completed(.response(nil))
      }
      request.httpBody = encoded
    }
    let preparedRequest = request
    let responseLimit = maximumBytes ?? maximumResponseBytes

    return PreparedRemoteOperation { [session, responseSignatureVerifier] in
      do {
        let response = try BoundedHTTPResponse.start(
          for: preparedRequest,
          using: session,
          maximumBytes: responseLimit
        )
        return response.map { result in
          guard case .success(let loaded) = result,
            let http = loaded.response as? HTTPURLResponse
          else { return .response(nil) }
          return Self.adjudicateResponse(
            http,
            data: loaded.data,
            signedSuccess: signedSuccess,
            responseSignatureVerifier: responseSignatureVerifier,
            decode: decode,
            validate: validate,
            validateNonSuccess: validateNonSuccess
          )
        }
      } catch {
        return .completed(.response(nil))
      }
    }
  }

  static func adjudicateResponse<T: Sendable>(
    _ http: HTTPURLResponse,
    data: Data,
    signedSuccess: Bool,
    responseSignatureVerifier: ResponseSignatureVerifier = { response, body, required in
      PinnedSessionDelegate.verifyResponseSignature(
        response,
        body: body,
        requireSignature: required
      )
    },
    decode: @Sendable (Data, Int) throws -> T,
    validate: (@Sendable (T) -> Bool)? = nil,
    validateNonSuccess: (@Sendable (Int, T) -> Bool)? = nil
  ) -> AuthenticatedResponse<T> {
    if http.statusCode == 401,
      http.value(forHTTPHeaderField: "X-LPM-Response-Key-ID") == nil,
      http.value(forHTTPHeaderField: "X-LPM-Response-Signature") == nil
    {
      return .unauthorized
    }
    let isSuccess = (200..<300).contains(http.statusCode)
    if signedSuccess {
      guard
        responseSignatureVerifier(http, data, true)
      else { return .response(nil) }
    }
    guard let decoded = try? decode(data, http.statusCode) else { return .response(nil) }
    guard isSuccess else {
      guard validateNonSuccess?(http.statusCode, decoded) == true else {
        return .response(nil)
      }
      return .response(decoded)
    }
    guard validate?(decoded) != false else { return .response(nil) }
    return .response(decoded)
  }
}

/// The organization-sync surface used by `VaultStore`. Keeping this narrow
/// makes authorization races testable without replacing unrelated API calls.
protocol OrgSyncServiceProtocol: Sendable {
  func pushOrg(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [SyncService.WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) async -> SyncService.SyncStatus?

  func pullOrg(
    authToken: String,
    orgSlug: String,
    vaultId: String
  ) async -> SyncService.SyncStatus?

  func getOrgMemberKeyAccess(
    authToken: String,
    expectedCallerUserID: String,
    orgSlug: String
  ) async -> SyncService.MemberKeyAccess?

  func getMyPublicKey(
    authToken: String,
    expectedPrincipalId: String
  ) async -> SyncService.PublicKeyRecord?

  func pushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [SyncService.WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus>

  func startPushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [SyncService.WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) -> StartedRemoteOperation<
    SyncService.AuthenticatedResponse<SyncService.SyncStatus>
  >

  func preparePushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [SyncService.WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) async -> PreparedRemoteOperation<
    SyncService.AuthenticatedResponse<SyncService.SyncStatus>
  >

  func pullOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    vaultId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus>

  func getOrgMemberKeyAccessAuthenticated(
    authToken: String,
    expectedCallerUserID: String,
    orgSlug: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.MemberKeyAccess>

  func getMyPublicKeyAuthenticated(
    authToken: String,
    expectedPrincipalId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.PublicKeyRecord>
}

extension OrgSyncServiceProtocol {
  func preparePushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [SyncService.WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) async -> PreparedRemoteOperation<
    SyncService.AuthenticatedResponse<SyncService.SyncStatus>
  > {
    PreparedRemoteOperation {
      .run {
        await pushOrgAuthenticated(
          authToken: authToken,
          orgSlug: orgSlug,
          expectedOrganizationID: expectedOrganizationID,
          expectedCallerUserID: expectedCallerUserID,
          vaultId: vaultId,
          encryptedBlob: encryptedBlob,
          wrappedKeys: wrappedKeys,
          expectedVersion: expectedVersion,
          name: name,
          schema: schema
        )
      }
    }
  }

  func startPushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [SyncService.WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) -> StartedRemoteOperation<
    SyncService.AuthenticatedResponse<SyncService.SyncStatus>
  > {
    .run {
      await pushOrgAuthenticated(
        authToken: authToken,
        orgSlug: orgSlug,
        expectedOrganizationID: expectedOrganizationID,
        expectedCallerUserID: expectedCallerUserID,
        vaultId: vaultId,
        encryptedBlob: encryptedBlob,
        wrappedKeys: wrappedKeys,
        expectedVersion: expectedVersion,
        name: name,
        schema: schema
      )
    }
  }

  func pushOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    expectedOrganizationID: String,
    expectedCallerUserID: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKeys: [SyncService.WrappedMemberKey]?,
    expectedVersion: Int?,
    name: String?,
    schema: LPMJSONValue?
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus> {
    .response(
      await pushOrg(
        authToken: authToken,
        orgSlug: orgSlug,
        expectedOrganizationID: expectedOrganizationID,
        expectedCallerUserID: expectedCallerUserID,
        vaultId: vaultId,
        encryptedBlob: encryptedBlob,
        wrappedKeys: wrappedKeys,
        expectedVersion: expectedVersion,
        name: name,
        schema: schema
      ))
  }

  func pullOrgAuthenticated(
    authToken: String,
    orgSlug: String,
    vaultId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus> {
    .response(await pullOrg(authToken: authToken, orgSlug: orgSlug, vaultId: vaultId))
  }

  func getOrgMemberKeyAccessAuthenticated(
    authToken: String,
    expectedCallerUserID: String,
    orgSlug: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.MemberKeyAccess> {
    .response(await getOrgMemberKeyAccess(
      authToken: authToken,
      expectedCallerUserID: expectedCallerUserID,
      orgSlug: orgSlug
    ))
  }

  func getMyPublicKeyAuthenticated(
    authToken: String,
    expectedPrincipalId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.PublicKeyRecord> {
    .response(await getMyPublicKey(
      authToken: authToken,
      expectedPrincipalId: expectedPrincipalId
    ))
  }

}

extension SyncService: OrgSyncServiceProtocol {}

protocol PersonalSyncServiceProtocol: Sendable {
  func push(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int?,
    force: Bool,
    recreateMissing: Bool,
    name: String?,
    schema: LPMJSONValue?
  ) async -> SyncService.SyncStatus?

  func pull(authToken: String, vaultId: String) async -> SyncService.SyncStatus?

  func pushAuthenticated(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int?,
    force: Bool,
    recreateMissing: Bool,
    name: String?,
    schema: LPMJSONValue?
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus>

  func preparePushAuthenticated(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int?,
    force: Bool,
    recreateMissing: Bool,
    name: String?,
    schema: LPMJSONValue?
  ) async -> PreparedRemoteOperation<
    SyncService.AuthenticatedResponse<SyncService.SyncStatus>
  >

  func pullAuthenticated(
    authToken: String,
    vaultId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus>

  func versionPreflightAuthenticated(
    authToken: String,
    vaultId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.VersionPreflight>
}

extension PersonalSyncServiceProtocol {
  func preparePushAuthenticated(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int?,
    force: Bool,
    recreateMissing: Bool,
    name: String?,
    schema: LPMJSONValue?
  ) async -> PreparedRemoteOperation<
    SyncService.AuthenticatedResponse<SyncService.SyncStatus>
  > {
    PreparedRemoteOperation {
      .run {
        await pushAuthenticated(
          authToken: authToken,
          expectedPrincipalId: expectedPrincipalId,
          vaultId: vaultId,
          encryptedBlob: encryptedBlob,
          wrappedKey: wrappedKey,
          expectedVersion: expectedVersion,
          force: force,
          recreateMissing: recreateMissing,
          name: name,
          schema: schema
        )
      }
    }
  }

  func pushAuthenticated(
    authToken: String,
    expectedPrincipalId: String,
    vaultId: String,
    encryptedBlob: String,
    wrappedKey: String,
    expectedVersion: Int?,
    force: Bool,
    recreateMissing: Bool,
    name: String?,
    schema: LPMJSONValue?
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus> {
    .response(
      await push(
        authToken: authToken,
        expectedPrincipalId: expectedPrincipalId,
        vaultId: vaultId,
        encryptedBlob: encryptedBlob,
        wrappedKey: wrappedKey,
        expectedVersion: expectedVersion,
        force: force,
        recreateMissing: recreateMissing,
        name: name,
        schema: schema
      ))
  }

  func pullAuthenticated(
    authToken: String,
    vaultId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.SyncStatus> {
    .response(await pull(authToken: authToken, vaultId: vaultId))
  }

  func versionPreflightAuthenticated(
    authToken: String,
    vaultId: String
  ) async -> SyncService.AuthenticatedResponse<SyncService.VersionPreflight> {
    _ = authToken
    _ = vaultId
    return .response(nil)
  }
}

extension SyncService: PersonalSyncServiceProtocol {}

protocol ProjectListServiceProtocol: Sendable {
  func listPersonalProjects(
    authToken: String
  ) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError>

  func listOrgProjects(
    authToken: String,
    orgSlug: String
  ) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError>
}

extension SyncService: ProjectListServiceProtocol {}

extension CharacterSet {
  fileprivate static let urlPathSegmentAllowed: CharacterSet = {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#%")
    return allowed
  }()
}
