import CryptoKit
import Foundation

// MARK: - Strict Key Trust for Org Members

/// A member key that requires explicit user approval before the vault
/// is encrypted for them. Covers both new members (never seen) and
/// existing members whose key changed (rotation or compromise).
struct PendingKeyApproval: Identifiable, Equatable, Sendable {
  let id = UUID()
  let memberId: String
  let fingerprint: String
  /// true = first-time member, false = existing member whose key changed
  let isNewMember: Bool
  /// Previous fingerprint (nil for new members)
  let oldFingerprint: String?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.memberId == rhs.memberId
      && lhs.fingerprint == rhs.fingerprint
      && lhs.isNewMember == rhs.isNewMember
      && lhs.oldFingerprint == rhs.oldFingerprint
  }

  static func exactlyMatches(_ approved: [Self], pending: [Self]) -> Bool {
    guard approved.count == pending.count else { return false }
    var remainingKeys = Set<ApprovalKey>()
    remainingKeys.reserveCapacity(approved.count)
    for approval in approved {
      guard remainingKeys.insert(ApprovalKey(approval)).inserted else { return false }
    }
    for approval in pending {
      guard remainingKeys.remove(ApprovalKey(approval)) != nil else { return false }
    }
    return remainingKeys.isEmpty
  }

  private struct ApprovalKey: Hashable {
    let memberId: String
    let fingerprint: String
    let isNewMember: Bool
    let oldFingerprint: String?

    init(_ approval: PendingKeyApproval) {
      memberId = approval.memberId
      fingerprint = approval.fingerprint
      isNewMember = approval.isNewMember
      oldFingerprint = approval.oldFingerprint
    }
  }
}

/// Holds all context needed to resume an org push after the user
/// approves pending member keys in the KeyApprovalSheet.
struct PendingOrgPush {
  let id = UUID()
  let orgSlug: String
  let projectId: String
  let ownPublicKey: SyncService.PublicKeyRecord?
  let allMembers: [SyncService.MemberPublicKey]
  let pendingApprovals: [PendingKeyApproval]
  var orgTrust: OrgKeyTrust
  let trustScope: OrgTrustScope
  let authToken: String
  let callerUserID: String
  let canReplaceWrappedKeys: Bool
  var environment: AppEnvironment = .production
  var authGeneration: Int = 0
  var sessionGeneration: Int = 0
  var operationGeneration: Int = 0
  var authorityGeneration: AuthSessionAuthorityGeneration?
}

struct VaultSyncError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

enum VaultCreationResult: Equatable {
  case completed
  case approvalRequired
  case failed
}

private struct SyncAuthority: Sendable {
  let projectId: String
  let account: SelectedAccount
  let environment: AppEnvironment
  let authGeneration: Int
  let sessionGeneration: Int
  let operationGeneration: Int
  let authToken: String
  let principalID: String
  let authorityGeneration: AuthSessionAuthorityGeneration?
}

private struct AuthTokenResolution: Sendable {
  let token: String?
  let failure: String?
  let authorityGeneration: AuthSessionAuthorityGeneration?
  let disposition: AuthTokenResolutionDisposition
}

private enum AuthTokenResolutionDisposition: Sendable {
  case authorized
  case absent
  case revoked
  case transientFailure
  case cancelled

  var definitivelyInvalidated: Bool {
    self == .absent || self == .revoked
  }
}

private struct CloudAuthorization: Sendable {
  let environment: AppEnvironment
  let authGeneration: Int
  let sessionGeneration: Int
  let token: String
  let authorityGeneration: AuthSessionAuthorityGeneration?
}

typealias AuthorizedImportCommitter =
  @Sendable (
    AuthSessionAuthorityGeneration,
    @escaping @Sendable () async -> ImportPersistenceResult
  ) async throws -> ImportPersistenceResult?

typealias AuthorizedPullCommitter =
  @Sendable (
    AuthSessionAuthorityGeneration,
    @escaping @Sendable () async -> PullPersistenceResult
  ) async throws -> PullPersistenceResult?

private struct AuthorizedMutationBox<Value: Sendable>: Sendable {
  let value: Value
}

typealias AuthorizedRemoteMutationExecutor =
  @Sendable (
    AuthSessionAuthorityGeneration,
    @escaping @Sendable () -> any Sendable
  ) async throws -> (any Sendable)?

private actor AuthSessionMutationQueue {
  private var tail: Task<Void, Never>?

  func run(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    let previous = tail
    let current = Task {
      await previous?.value
      try await operation()
    }
    tail = Task { _ = try? await current.value }
    try await current.value
  }
}

struct ImportedEnvProject: Sendable, Equatable {
  let projectId: String
  let version: Int
  let keyCount: Int
}

private struct TokenInventory: Sendable {
  let user: LPMUser
  let personalTokens: [LPMToken]
  let organizationTokens: [String: [LPMToken]]
}

private struct OrganizationTokenResult: Sendable {
  let slug: String
  let result: LPMAPIResult<[LPMToken]>
}

private actor TokenInventoryBudget {
  private let maximumOrganizations: Int
  private let maximumTokens: Int
  private let maximumBytes: Int
  private var organizations = 0
  private var tokens = 0
  private var bytes = 0

  init(maximumOrganizations: Int, maximumTokens: Int, maximumBytes: Int) {
    self.maximumOrganizations = maximumOrganizations
    self.maximumTokens = maximumTokens
    self.maximumBytes = maximumBytes
  }

  func reserve(_ values: [LPMToken], organization: Bool) -> Bool {
    let addedOrganizations = organization ? 1 : 0
    guard organizations + addedOrganizations <= maximumOrganizations,
      tokens + values.count <= maximumTokens
    else { return false }

    var addedBytes = 0
    for value in values {
      guard let footprint = Self.footprint(of: value),
        addedBytes <= maximumBytes - footprint
      else { return false }
      addedBytes += footprint
    }
    guard bytes <= maximumBytes - addedBytes else { return false }
    organizations += addedOrganizations
    tokens += values.count
    bytes += addedBytes
    return true
  }

  private nonisolated static func footprint(of token: LPMToken) -> Int? {
    let values = [
      Optional(token.id),
      Optional(token.name),
      token.scope,
      token.expiresAt,
      token.lastUsedAt,
      token.createdAt,
      token.orgSlug,
    ]
    var total = 128
    for value in values {
      guard let value else { continue }
      let (next, overflow) = total.addingReportingOverflow(value.utf8.count)
      guard !overflow else { return nil }
      total = next
    }
    return total
  }
}

struct LocalEnvImportTarget: Hashable, Sendable {
  let projectId: String
  let environment: String
}

/// Synchronous commit authority shared with the persistence actor. A UI
/// invalidation that wins this lock prevents a queued transaction from
/// crossing its durable commit point.
final class LocalEnvImportAuthority: @unchecked Sendable {
  private enum State {
    case pending
    case committing
  }

  private struct Request {
    let id: UUID
    var state: State
  }

  private let lock = NSLock()
  private var requests: [LocalEnvImportTarget: Request] = [:]

  func begin(_ target: LocalEnvImportTarget, requestId: UUID) {
    lock.withLock { requests[target] = Request(id: requestId, state: .pending) }
  }

  /// Establishes the commit point with one atomic state transition. If
  /// cancellation wins first, persistence is rejected. Once commit wins,
  /// later cancellation cannot turn durable success into a cancelled result.
  func beginCommit(_ target: LocalEnvImportTarget, requestId: UUID) -> Bool {
    lock.withLock {
      guard var request = requests[target], request.id == requestId,
        request.state == .pending
      else { return false }
      request.state = .committing
      requests[target] = request
      return true
    }
  }

  func cancel(_ target: LocalEnvImportTarget, requestId: UUID? = nil) {
    lock.withLock {
      guard let request = requests[target],
        requestId == nil || request.id == requestId,
        request.state == .pending
      else { return }
      requests.removeValue(forKey: target)
    }
  }

  func complete(_ target: LocalEnvImportTarget, requestId: UUID) {
    lock.withLock {
      guard requests[target]?.id == requestId else { return }
      requests.removeValue(forKey: target)
    }
  }
}

private enum TokenInventoryLoader {
  static let maximumConcurrentOrganizations = 4
  private static let maximumOrganizations = 256
  private static let maximumTokens = 40_000
  private static let maximumBytes = 8 * 1024 * 1024

  static func load(
    user: LPMUser,
    authToken: String,
    service: any LPMAPIServiceProtocol
  ) async -> LPMAPIResult<TokenInventory> {
    let budget = TokenInventoryBudget(
      maximumOrganizations: maximumOrganizations,
      maximumTokens: maximumTokens,
      maximumBytes: maximumBytes
    )
    async let personalResult = loadPersonal(
      authToken: authToken,
      service: service,
      budget: budget
    )
    let organizationResult = await loadOrganizations(
      user.orgs ?? [],
      authToken: authToken,
      service: service,
      budget: budget
    )
    let resolvedPersonal = await personalResult
    guard !Task.isCancelled else { return .failure(.cancelled) }

    switch (resolvedPersonal, organizationResult) {
    case (.success(let personal), .success(let organizations)):
      return .success(
        TokenInventory(
          user: user,
          personalTokens: personal,
          organizationTokens: organizations
        ))
    case (.failure(let error), _):
      return .failure(error)
    case (_, .failure(let error)):
      return .failure(error)
    }
  }

  private static func loadPersonal(
    authToken: String,
    service: any LPMAPIServiceProtocol,
    budget: TokenInventoryBudget
  ) async -> LPMAPIResult<[LPMToken]> {
    let result = await service.fetchPersonalTokens(authToken: authToken)
    guard case .success(let tokens) = result else { return result }
    guard await budget.reserve(tokens, organization: false) else {
      return .failure(.invalidResponse)
    }
    return .success(tokens)
  }

  private static func loadOrganizations(
    _ organizations: [LPMOrg],
    authToken: String,
    service: any LPMAPIServiceProtocol,
    budget: TokenInventoryBudget
  ) async -> LPMAPIResult<[String: [LPMToken]]> {
    let eligible =
      organizations
      .filter { organization in
        guard let role = organization.role?.lowercased() else { return false }
        return role == "owner" || role == "admin"
      }
    guard eligible.count <= maximumOrganizations else {
      return .failure(.invalidResponse)
    }
    guard !eligible.isEmpty else { return .success([:]) }
    let sortedEligible = eligible.sorted { $0.slug < $1.slug }

    return await withTaskGroup(of: OrganizationTokenResult.self) { group in
      var iterator = sortedEligible.makeIterator()
      var results: [String: [LPMToken]] = [:]

      func addNext() -> Bool {
        guard !Task.isCancelled, let organization = iterator.next() else { return false }
        group.addTask {
          OrganizationTokenResult(
            slug: organization.slug,
            result: await service.fetchOrgTokens(
              orgSlug: organization.slug,
              authToken: authToken
            )
          )
        }
        return true
      }

      for _ in 0..<min(maximumConcurrentOrganizations, sortedEligible.count) {
        _ = addNext()
      }

      while let next = await group.next() {
        guard !Task.isCancelled else {
          group.cancelAll()
          return .failure(.cancelled)
        }
        switch next.result {
        case .success(let tokens):
          guard await budget.reserve(tokens, organization: true) else {
            group.cancelAll()
            return .failure(.invalidResponse)
          }
          results[next.slug] = tokens
        case .failure(let error):
          group.cancelAll()
          return .failure(error)
        }
        _ = addNext()
      }

      return .success(results)
    }
  }
}

enum EnvProjectImportError: LocalizedError, Sendable, Equatable {
  case cancelled
  case duplicate
  case notAuthenticated
  case authStorage(String)
  case unauthorized
  case noResponse
  case noData(String)
  case invalidSharingKey(String)
  case invalidPayload(String)
  case persistence(String)

  var errorDescription: String? {
    switch self {
    case .cancelled: "Import cancelled."
    case .duplicate: "This env project is already available locally."
    case .notAuthenticated: "Sign in to lpm.dev, then retry."
    case .unauthorized: "Your lpm.dev session expired. Sign in again."
    case .noResponse: "The server request failed. Check your connection and try again."
    case .authStorage(let message), .noData(let message), .invalidSharingKey(let message),
      .invalidPayload(let message), .persistence(let message):
      message
    }
  }
}

struct OrgKeyTrust: Codable, Sendable {
  /// member_id → SHA256 hex fingerprint of their public key
  var trustedFingerprints: [String: String]

  init(trustedFingerprints: [String: String] = [:]) {
    self.trustedFingerprints = trustedFingerprints
  }

  /// Verify member public keys against trusted fingerprints (strict mode).
  /// - New members are NOT auto-trusted — they produce pending approvals.
  /// - Changed keys for existing members also produce pending approvals.
  /// - Returns empty array only when every member key is already trusted and unchanged.
  /// - Does NOT mutate trustedFingerprints — caller must explicitly approve via `approve(_:)`.
  func verify(members: [(id: String, publicKey: Data)]) -> [PendingKeyApproval] {
    verify(
      bindings: members.map {
        OrgMemberKeyBinding(
          id: $0.id,
          publicKey: $0.publicKey,
          fingerprint: VaultCrypto.publicKeyFingerprint($0.publicKey)
        )
      })
  }

  func verify(bindings: [OrgMemberKeyBinding]) -> [PendingKeyApproval] {
    bindings.compactMap { member in
      if let existing = trustedFingerprints[member.id] {
        guard existing != member.fingerprint else { return nil }
        return PendingKeyApproval(
          memberId: member.id,
          fingerprint: member.fingerprint,
          isNewMember: false,
          oldFingerprint: existing
        )
      }
      return PendingKeyApproval(
        memberId: member.id,
        fingerprint: member.fingerprint,
        isNewMember: true,
        oldFingerprint: nil
      )
    }
  }

  /// Mark approved members as trusted. Call only after the user explicitly
  /// accepts each key in the KeyApprovalSheet.
  mutating func approve(_ approvals: [PendingKeyApproval]) {
    for approval in approvals {
      trustedFingerprints[approval.memberId] = approval.fingerprint
    }
  }

}

struct OrgTrustScope: Codable, Equatable, Sendable {
  let registryURL: String
  let organizationID: String
  let organizationSlug: String

  init?(registryURL: String, organizationID: String, organizationSlug: String) {
    guard EnvValidation.isSafeOrgSlug(organizationSlug),
      let normalizedRegistryURL = Self.normalizedRegistryURL(registryURL),
      let uuid = UUID(uuidString: organizationID),
      uuid.uuidString.lowercased() == organizationID
    else { return nil }

    self.registryURL = normalizedRegistryURL
    self.organizationID = organizationID
    self.organizationSlug = organizationSlug
  }

  var storageAccount: String {
    var input = Data()
    for component in [registryURL, organizationID, organizationSlug] {
      var length = UInt64(component.utf8.count).bigEndian
      withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
      input.append(contentsOf: component.utf8)
    }
    let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
		return OrgTrustRecordContract.accountPrefix + digest
  }

  private static func normalizedRegistryURL(_ value: String) -> String? {
    guard var components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      ["http", "https"].contains(scheme),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { return nil }

    components.scheme = scheme
    components.host = host
    if (scheme == "https" && components.port == 443)
      || (scheme == "http" && components.port == 80)
    {
      components.port = nil
    }
    var trimmedPath = components.percentEncodedPath
    while trimmedPath.last == "/" { trimmedPath.removeLast() }
    components.percentEncodedPath = trimmedPath
    return components.url?.absoluteString
  }
}

enum OrgTrustRecordContract {
	static let accountPrefix = "__org_keys__"
	static let schemaVersion = 3
}

struct OrgMemberKeyBinding: Sendable {
  let id: String
  let publicKey: Data
  let fingerprint: String
}

struct ValidatedSharingKey: Sendable {
  let canonicalBase64: String
  let rawRepresentation: Data
  let version: Int
  let fingerprint: String

  init(
    canonicalBase64: String,
    rawRepresentation: Data,
    version: Int,
    fingerprint: String
  ) {
    self.canonicalBase64 = canonicalBase64
    self.rawRepresentation = rawRepresentation
    self.version = version
    self.fingerprint = fingerprint
  }
}

struct ValidatedOrganizationRecipient: Sendable {
  let userId: String
  let sharingKey: ValidatedSharingKey

  var publicKey: Data { sharingKey.rawRepresentation }
  var publicKeyVersion: Int { sharingKey.version }
  var publicKeyFingerprint: String { sharingKey.fingerprint }

  fileprivate init(userId: String, sharingKey: ValidatedSharingKey) {
    self.userId = userId
    self.sharingKey = sharingKey
  }
}

struct PreparedOrganizationMembers: Sendable {
  let membersWithKeys: [SyncService.MemberPublicKey]
  let bindings: [OrgMemberKeyBinding]
  let validatedRecipients: [ValidatedOrganizationRecipient]
  let pendingApprovals: [PendingKeyApproval]
}

private struct RefreshedOrganizationAuthorization: Sendable {
  let prepared: PreparedOrganizationMembers
  let membershipIsUnchanged: Bool
  let approvedTrust: OrgKeyTrust
  let approvalIsComplete: Bool
}

enum OrganizationMemberAuthorizationPolicy {
  static let maximumMemberCount = 10_000
  private static let maximumUserIdBytes = 256
  private static let maximumRoleBytes = 64

  static func prepare(
    _ members: [SyncService.MemberPublicKey],
    trust: OrgKeyTrust,
    decodePublicKey: (String) -> Data? = { Data(base64Encoded: $0) },
    fingerprintPublicKey: (Data) -> String = VaultCrypto.publicKeyFingerprint
  ) throws -> PreparedOrganizationMembers {
    guard members.count <= maximumMemberCount else {
      throw VaultSyncError("The organization member inventory is too large to share safely.")
    }

    var seenMemberIds = Set<String>()
    seenMemberIds.reserveCapacity(members.count)
    var validatedPublicKeys = Set<Data>()
    validatedPublicKeys.reserveCapacity(members.count)
    var membersWithKeys: [SyncService.MemberPublicKey] = []
    membersWithKeys.reserveCapacity(members.count)
    var bindings: [OrgMemberKeyBinding] = []
    bindings.reserveCapacity(members.count)
    var validatedRecipients: [ValidatedOrganizationRecipient] = []
    validatedRecipients.reserveCapacity(members.count)

    for member in members {
      guard !member.userId.isEmpty,
        member.userId.utf8.count <= maximumUserIdBytes,
        !member.role.isEmpty,
        member.role.utf8.count <= maximumRoleBytes,
        seenMemberIds.insert(member.userId).inserted
      else {
        throw VaultSyncError("The organization member inventory is invalid.")
      }

      guard member.hasPublicKey else {
        guard member.publicKey == nil,
          member.publicKeyVersion == nil,
          member.publicKeyFingerprint == nil,
          member.validatedSharingKey == nil
        else {
          throw VaultSyncError("The organization member key inventory is inconsistent.")
        }
        continue
      }

      guard let encodedKey = member.publicKey,
        let publicKeyVersion = member.publicKeyVersion,
        publicKeyVersion > 0,
        let fingerprint = member.publicKeyFingerprint
      else {
        throw VaultSyncError("The organization member key inventory is invalid.")
      }

      let sharingKey: ValidatedSharingKey
      if let validated = member.validatedSharingKey {
        guard validated.canonicalBase64 == encodedKey,
          validated.rawRepresentation.count == 32,
          validated.rawRepresentation.base64EncodedString() == encodedKey,
          validated.version == publicKeyVersion,
          validated.fingerprint == fingerprint
        else {
          throw VaultSyncError("The organization member key inventory is invalid.")
        }
        sharingKey = validated
      } else {
        guard let publicKey = decodePublicKey(encodedKey),
          publicKey.count == 32,
          publicKey.base64EncodedString() == encodedKey,
          fingerprint == fingerprintPublicKey(publicKey)
        else {
          throw VaultSyncError("The organization member key inventory is invalid.")
        }
        if validatedPublicKeys.insert(publicKey).inserted {
          do {
            try VaultCrypto.validateContributoryX25519PublicKey(publicKey)
          } catch {
            throw VaultSyncError("The organization member key inventory is invalid.")
          }
        }
        sharingKey = ValidatedSharingKey(
          canonicalBase64: encodedKey,
          rawRepresentation: publicKey,
          version: publicKeyVersion,
          fingerprint: fingerprint
        )
      }

      membersWithKeys.append(member)
      bindings.append(
        OrgMemberKeyBinding(
          id: member.userId,
          publicKey: sharingKey.rawRepresentation,
          fingerprint: fingerprint
        )
      )
      validatedRecipients.append(
        ValidatedOrganizationRecipient(
          userId: member.userId,
          sharingKey: sharingKey
        )
      )
    }

    return PreparedOrganizationMembers(
      membersWithKeys: membersWithKeys,
      bindings: bindings,
      validatedRecipients: validatedRecipients,
      pendingApprovals: trust.verify(bindings: bindings)
    )
  }

  static func sameAuthorization(
    _ lhs: [SyncService.MemberPublicKey],
    _ rhs: [SyncService.MemberPublicKey]
  ) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var leftById: [String: SyncService.MemberPublicKey] = [:]
    leftById.reserveCapacity(lhs.count)
    for member in lhs {
      guard leftById.updateValue(member, forKey: member.userId) == nil else {
        return false
      }
    }
    for approved in rhs {
      guard let current = leftById.removeValue(forKey: approved.userId),
        current.role == approved.role,
        current.publicKey == approved.publicKey,
        current.publicKeyVersion == approved.publicKeyVersion,
        current.publicKeyFingerprint == approved.publicKeyFingerprint,
        current.hasPublicKey == approved.hasPublicKey
      else { return false }
    }
    return leftById.isEmpty
  }

  static func currentMemberKey(
    userId: String,
    localPublicKey: Data,
    members: [SyncService.MemberPublicKey]
  ) throws -> SyncService.PublicKeyRecord {
    guard let member = members.first(where: { $0.userId == userId }) else {
      throw VaultSyncError(
        "Your sharing key is not registered yet. Run `lpm env share --org` once to complete secure step-up registration, then retry."
      )
    }
    let encodedLocalKey = localPublicKey.base64EncodedString()
    guard member.publicKey == encodedLocalKey,
      let version = member.publicKeyVersion,
      version > 0,
      member.publicKeyFingerprint == VaultCrypto.publicKeyFingerprint(localPublicKey)
    else {
      throw VaultSyncError(
        "This device's sharing-key binding differs from the organization member record. Run `lpm env rotate-sharing-key` or restore the matching key before sharing."
      )
    }
    return SyncService.PublicKeyRecord(
      publicKey: member.publicKey,
      publicKeyVersion: version,
      publicKeyFingerprint: member.publicKeyFingerprint
    )
  }
}

// MARK: - App Environment

enum AppEnvironment: String, Sendable {
  case production
  #if DEBUG
    case development
  #endif

  var baseURL: URL {
    switch self {
    case .production: VaultConstants.apiBaseURL
    #if DEBUG
      case .development: VaultConstants.localAPIBaseURL
    #endif
    }
  }

  var registryURL: String {
    AuthSessionStore.registryURL(for: baseURL)
  }

  var label: String {
    switch self {
    case .production: "Live"
    #if DEBUG
      case .development: "Local"
    #endif
    }
  }
}

// MARK: - Sync Types

struct SyncPrincipalCheckpoint: Codable, Equatable, Sendable {
  let binding: SyncPrincipalBinding
  var lastSyncedAt: Date?
  var lastAction: String?
  var lastVersion: Int
}

enum SyncCheckpointError: Error {
  case invalidRevision
  case rollback
  case principalConflict
  case capacityReached
}

struct SyncMetadata: Codable {
  static let maximumCheckpoints = 64

  var lastSyncedAt: Date?
  var lastAction: String?  // "push" or "pull"
  var lastVersion: Int?
  var isDirty: Bool
  var binding: SyncPrincipalBinding?
  var checkpoints: [SyncPrincipalCheckpoint]

  init(
    lastSyncedAt: Date? = nil,
    lastAction: String? = nil,
    lastVersion: Int? = nil,
    isDirty: Bool = false,
    binding: SyncPrincipalBinding? = nil,
    checkpoints: [SyncPrincipalCheckpoint] = []
  ) {
    self.lastSyncedAt = lastSyncedAt
    self.lastAction = lastAction
    self.lastVersion = lastVersion
    self.isDirty = isDirty
    self.binding = binding
    self.checkpoints = checkpoints
    if checkpoints.isEmpty, let binding, let lastVersion, lastVersion > 0 {
      self.checkpoints = [
        SyncPrincipalCheckpoint(
          binding: binding,
          lastSyncedAt: lastSyncedAt,
          lastAction: lastAction,
          lastVersion: lastVersion
        )
      ]
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    lastAction = try container.decodeIfPresent(String.self, forKey: .lastAction)
    lastVersion = try container.decodeIfPresent(Int.self, forKey: .lastVersion)
    isDirty = try container.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
    binding = try container.decodeIfPresent(SyncPrincipalBinding.self, forKey: .binding)
    checkpoints = try container.decode(
      [SyncPrincipalCheckpoint].self,
      forKey: .checkpoints
    )
    guard checkpoints.count <= Self.maximumCheckpoints,
      checkpoints.allSatisfy({ $0.lastVersion > 0 }),
      Set(checkpoints.map(\.binding)).count == checkpoints.count,
      isValidCurrentWireState
    else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Sync checkpoint history is invalid."
        )
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
    try container.encodeIfPresent(lastAction, forKey: .lastAction)
    try container.encodeIfPresent(lastVersion, forKey: .lastVersion)
    try container.encode(isDirty, forKey: .isDirty)
    try container.encodeIfPresent(binding, forKey: .binding)
    try container.encode(checkpoints, forKey: .checkpoints)
  }

  var isValidCurrentWireState: Bool {
    let validVersion: (Int) -> Bool = { 1...Int(Int32.max) ~= $0 }
    let validAction: (String) -> Bool = { $0 == "push" || $0 == "pull" }
    guard checkpoints.count <= Self.maximumCheckpoints,
      Set(checkpoints.map(\.binding)).count == checkpoints.count,
      Set(checkpoints.map {
        "\($0.binding.registryURL)\u{0}\($0.binding.scope)"
      }).count == checkpoints.count,
      checkpoints.allSatisfy({ checkpoint in
        checkpoint.binding.isValidCurrentWireBinding
          && checkpoint.lastSyncedAt?.timeIntervalSinceReferenceDate.isFinite == true
          && checkpoint.lastAction.map(validAction) == true
          && validVersion(checkpoint.lastVersion)
      })
    else { return false }

    if checkpoints.isEmpty {
      return lastSyncedAt == nil && lastAction == nil && lastVersion == nil && binding == nil
    }
    guard let lastSyncedAt,
      lastSyncedAt.timeIntervalSinceReferenceDate.isFinite,
      let lastAction,
      validAction(lastAction),
      let lastVersion,
      validVersion(lastVersion),
      let binding,
      binding.isValidCurrentWireBinding,
      let checkpoint = checkpoints.first(where: { $0.binding == binding })
    else { return false }
    return checkpoint.lastSyncedAt == lastSyncedAt
      && checkpoint.lastAction == lastAction
      && checkpoint.lastVersion == lastVersion
  }

  func version(boundTo expectedBinding: SyncPrincipalBinding) -> Int? {
    checkpoints.first(where: { $0.binding == expectedBinding })?.lastVersion
  }

  func conflicts(with expectedBinding: SyncPrincipalBinding) -> Bool {
    if checkpoints.contains(where: {
      $0.binding.registryURL == expectedBinding.registryURL
        && $0.binding.scope == expectedBinding.scope
        && $0.binding.principalID != expectedBinding.principalID
    }) {
      return true
    }
    guard let binding else { return false }
    return binding.registryURL == expectedBinding.registryURL
      && binding.scope == expectedBinding.scope
      && binding.principalID != expectedBinding.principalID
  }

  func scoped(to expectedBinding: SyncPrincipalBinding) -> SyncMetadata? {
    if let checkpoint = checkpoints.first(where: { $0.binding == expectedBinding }) {
      var scoped = self
      scoped.lastSyncedAt = checkpoint.lastSyncedAt
      scoped.lastAction = checkpoint.lastAction
      scoped.lastVersion = checkpoint.lastVersion
      scoped.binding = expectedBinding
      return scoped
    }
    return isDirty ? SyncMetadata(isDirty: true) : nil
  }

  func syncInfo(
    boundTo expectedBinding: SyncPrincipalBinding
  ) -> (date: Date, action: String, version: Int)? {
    guard let checkpoint = checkpoints.first(where: { $0.binding == expectedBinding }),
      let date = checkpoint.lastSyncedAt,
      let action = checkpoint.lastAction
    else { return nil }
    return (date, action, checkpoint.lastVersion)
  }

  mutating func record(
    binding newBinding: SyncPrincipalBinding,
    version newVersion: Int,
    action: String,
    date: Date,
    isDirty newIsDirty: Bool
  ) throws {
    guard newVersion > 0 else { throw SyncCheckpointError.invalidRevision }
    guard checkpoints.count <= Self.maximumCheckpoints,
      Set(checkpoints.map(\.binding)).count == checkpoints.count
    else { throw SyncCheckpointError.capacityReached }
    guard !conflicts(with: newBinding) else {
      throw SyncCheckpointError.principalConflict
    }
    let scopedFloor = checkpoints.lazy
      .filter {
        $0.binding.registryURL == newBinding.registryURL
          && $0.binding.scope == newBinding.scope
      }
      .map(\.lastVersion)
      .max()
    guard newVersion >= (scopedFloor ?? 0) else {
      throw SyncCheckpointError.rollback
    }
    if let index = checkpoints.firstIndex(where: { $0.binding == newBinding }) {
      checkpoints[index].lastSyncedAt = date
      checkpoints[index].lastAction = action
      checkpoints[index].lastVersion = newVersion
    } else {
      guard checkpoints.count < Self.maximumCheckpoints else {
        throw SyncCheckpointError.capacityReached
      }
      checkpoints.append(
        SyncPrincipalCheckpoint(
          binding: newBinding,
          lastSyncedAt: date,
          lastAction: action,
          lastVersion: newVersion
        ))
    }
    lastSyncedAt = date
    lastAction = action
    lastVersion = newVersion
    isDirty = newIsDirty
    binding = newBinding
  }

  private enum CodingKeys: String, CodingKey {
    case lastSyncedAt
    case lastAction
    case lastVersion
    case isDirty
    case binding
    case checkpoints
  }
}

struct SyncPrincipalBinding: Codable, Equatable, Hashable, Sendable {
  let registryURL: String
  let principalID: String
  let scope: String

  var isValidCurrentWireBinding: Bool {
    guard scope == "personal" || scope == "organization",
      !principalID.isEmpty,
      principalID.utf8.count <= 256,
      !principalID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      var components = URLComponents(string: registryURL),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      scheme == "http" || scheme == "https",
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { return false }
    components.scheme = scheme
    components.host = host
    if (scheme == "https" && components.port == 443)
      || (scheme == "http" && components.port == 80)
    {
      components.port = nil
    }
    var path = components.percentEncodedPath
    while path.last == "/" { path.removeLast() }
    components.percentEncodedPath = path
    return components.url?.absoluteString == registryURL
  }
}

enum ProjectSyncStatus {
  case neverSynced
  case synced
  case localChanges
}

enum AddSecretError: LocalizedError, Sendable, Equatable {
  case vaultLocked
  case targetUnavailable
  case invalidName
  case duplicate
  case caseInsensitiveCollision(existingKey: String)
  case persistence(String)

  var errorDescription: String? {
    switch self {
    case .vaultLocked:
      "Unlock LPM Vault before adding a secret."
    case .targetUnavailable:
      "The target env project or environment changed before the secret was saved."
    case .invalidName:
      "Use letters, numbers, and underscores; the first character cannot be a number."
    case .duplicate:
      "A secret with this key already exists."
    case .caseInsensitiveCollision(let existingKey):
      "A key named \(existingKey) already exists. Rename one key for Windows compatibility."
    case .persistence(let message):
      "Could not save the secret. \(message)"
    }
  }
}

enum AddSecretResult: Sendable, Equatable {
  case success
  case failure(AddSecretError)
}

@Observable
@MainActor
final class VaultStore {
  // MARK: - State

  var projects: [VaultProject] = [] {
    didSet {
      workspaceSnapshotGeneration &+= 1
      let generation = workspaceSnapshotGeneration
      workspaceSnapshotBuildTask?.cancel()
      workspaceSnapshotPublishTask?.cancel()
      let currentIDs = Set(projects.lazy.filter(\.hasLoadedEnvironments).map(\.id))
      if let pendingWorkspaceSnapshots,
        Set(pendingWorkspaceSnapshots.keys) == currentIDs
      {
        workspaceSnapshots = pendingWorkspaceSnapshots
        workspaceSnapshotBuildCount += pendingWorkspaceSnapshots.count
        self.pendingWorkspaceSnapshots = nil
        workspaceSnapshotBuildTask = nil
        workspaceSnapshotPublishTask = nil
        return
      }
      pendingWorkspaceSnapshots = nil
      let currentProjects = projects
      workspaceSnapshots = workspaceSnapshots.filter { currentIDs.contains($0.key) }
      let existingSnapshots = workspaceSnapshots
      let buildTask = Task(priority: .userInitiated) { [workspaceSnapshotBuilder] in
        await workspaceSnapshotBuilder.buildIncremental(
          currentProjects: currentProjects,
          existingSnapshots: existingSnapshots
        )
      }
      workspaceSnapshotBuildTask = buildTask
      let publishTask = Task { [weak self] in
        guard let update = await buildTask.value,
          !Task.isCancelled, let self,
          generation == self.workspaceSnapshotGeneration
        else { return }
        self.workspaceSnapshots = update.snapshots
        self.workspaceSnapshotBuildCount += update.buildCount
        self.workspaceSnapshotBuildTask = nil
        self.workspaceSnapshotPublishTask = nil
      }
      workspaceSnapshotPublishTask = publishTask
    }
  }
  private(set) var workspaceSnapshots: [String: VaultWorkspaceSnapshot] = [:]
  private(set) var workspaceSnapshotBuildCount = 0
  private let workspaceSnapshotBuilder = VaultWorkspaceSnapshotBuilder()
  private var pendingWorkspaceSnapshots: [String: VaultWorkspaceSnapshot]?
  private var workspaceSnapshotBuildTask: Task<VaultWorkspaceSnapshotUpdate?, Never>?
  private var workspaceSnapshotPublishTask: Task<Void, Never>?
  private var workspaceSnapshotGeneration = 0
  var selectedProjectId: String? {
    didSet {
      guard oldValue != selectedProjectId else { return }
      cancelExports()
      if let oldValue { cancelLocalEnvImports(projectId: oldValue) }
      cancelLocalEnvPreviews()
      invalidatePendingOrgPush()
      beginSelectedProjectLoadIfNeeded()
    }
  }
  var isUnlocked: Bool = false
  var searchQuery: String = ""
  var error: String?
  var isLoadingProjects: Bool = false
  var isUnlocking: Bool = false

  // Auth state
  var currentUser: LPMUser? {
    didSet { reconcileNavigationState() }
  }
  var personalTokens: [LPMToken] = []
  var orgTokens: [String: [LPMToken]] = [:]  // orgSlug → tokens
  var isLoadingTokens: Bool = false
  var isLoggingIn: Bool = false

  // Navigation state
  var selectedAccount: SelectedAccount = .personal
  var showAuthStatus: Bool = false

  // Sync state
  var isSyncing: Bool = false
  var lastSyncStatus: String?

  // Sync metadata (persisted across launches)
  var syncMetadata: [String: SyncMetadata] = [:]

  // Vault → org associations (persisted in Keychain)
  var vaultOrgAssociations: [String: String] = [:] {  // vaultId → orgSlug
    didSet { reconcileNavigationState() }
  }

  // SECURITY NOTE: Environment tab ordering is stored in UserDefaults (not Keychain).
  // This is intentional — it contains only the display order of environment names
  // (e.g., ["default", "staging", "production"]), not secret values.
  // Moving to Keychain would add unnecessary complexity for non-sensitive UI state.
  var environmentOrders: [String: [String]] = [:]

  // App environment (dev vs live)
  var appEnvironment: AppEnvironment = .production

  // Strict key approval — blocks org push until user approves pending keys
  var pendingOrgPush: PendingOrgPush?
  var showKeyApprovalSheet: Bool = false

  // MARK: - Dependencies

  private let keychainService: KeychainServiceProtocol
  private let persistence: VaultPersistenceCoordinator
  private let biometricService: BiometricServiceProtocol
  private let injectedAPIService: LPMAPIServiceProtocol?
  private let apiServiceFactory: @Sendable (URL) -> any LPMAPIServiceProtocol
  private let importServiceFactory: @Sendable (URL) -> any EnvProjectImportServiceProtocol
  private let projectListServiceFactory: @Sendable (URL) -> any ProjectListServiceProtocol
  private let orgSyncServiceFactory: @Sendable (URL) -> any OrgSyncServiceProtocol
  private let personalSyncServiceFactory: @Sendable (URL) -> any PersonalSyncServiceProtocol
  private let envFileImportService: any EnvFileImportServiceProtocol
  private let envFileExportService: EnvFileExportService
  private let sharingKeypairProvider:
    @Sendable (
      _ registryURL: String,
      _ callerUserID: String,
      _ expectedPublicKey: String?,
      _ expectedFingerprint: String?
    ) throws -> (privateKey: Data, publicKey: Data)
  private let stableSyncEncryptor:
    @Sendable (
      _ plaintext: Data,
      _ principalId: String,
      _ vaultId: String,
      _ revision: Int
    ) throws -> (encryptedBlob: String, wrappedKey: String)
  private let stableSyncDecryptor:
    @Sendable (
      _ encryptedBlob: String,
      _ wrappedKey: String,
      _ principalId: String,
      _ vaultId: String,
      _ revision: Int,
      _ cryptoVersion: Int
    ) throws -> Data
  private let authTokenProvider: (@Sendable (String, URL) async throws -> String?)?
  private let authAuthorizationProvider:
    @Sendable (String, URL) async throws -> AuthSessionAuthorization?
  private let authAuthorityValidator: @Sendable (AuthSessionAuthorityGeneration) -> Bool
  private let authorizedImportCommitter: AuthorizedImportCommitter
  private let authorizedPullCommitter: AuthorizedPullCommitter
  private let authorizedRemoteMutationExecutor: AuthorizedRemoteMutationExecutor
  private let loginProvider: @Sendable (String, URL) async throws -> AuthSessionCredentials
  private let authSessionWriter: @Sendable (AuthSessionCredentials, String) async throws -> Void
  private let authSessionClearer: @Sendable (String) async throws -> Void
  private let authSessionMutationQueue = AuthSessionMutationQueue()
  private let autoLockSleep: @Sendable (Duration) async throws -> Void
  private let autoLockNow: @Sendable () -> TimeInterval
  private var autoLockTask: Task<Void, Never>?
  private var autoLockDeadline: TimeInterval?
  private var autoLockTaskGeneration = 0
  private var projectLoadTask: Task<Void, Never>?
  private var projectLoadGeneration = 0
  private var lastSuccessfulProjectLoadGeneration = -1
  private var selectedProjectLoadTask: Task<Void, Never>?
  private var selectedProjectLoadGeneration = 0
  private(set) var isLoadingSelectedProject = false
  private var projectMutationTask: Task<Void, Never>?
  private var projectMutationRequestId: UUID?
  private var tokenLoadTask: Task<Void, Never>?
  private var tokenLoadGeneration = 0
  private var authOperationGeneration = 0
  private var currentIdentityAuthorityGeneration: AuthSessionAuthorityGeneration?
  private var syncOperationGeneration = 0
  private var retainedAPIServices: [URL: any LPMAPIServiceProtocol] = [:]
  private var unlockGeneration = 0
  private var vaultSessionGeneration = 0
  private var activeImportIds: Set<String> = []
  private var localEnvImportTasks: [LocalEnvImportTarget: Task<ImportedEnvFile, Error>] = [:]
  private var localEnvImportRequests: [LocalEnvImportTarget: UUID] = [:]
  private var localEnvCreationRequests: [LocalEnvImportTarget: UUID] = [:]
  private var localEnvPreviewTasks: [UUID: Task<ImportedEnvFile, Error>] = [:]
  private var exportTasks: [UUID: Task<Void, Error>] = [:]
  private var exportAuthorizations: [UUID: EnvFileExportAuthorization] = [:]
  private let localEnvImportAuthority = LocalEnvImportAuthority()
  private let autoLockDuration: TimeInterval

  /// Retains one connection pool for each exact API base URL. Production and
  /// the debug-only local server can never share a session.
  private func apiService(for environment: AppEnvironment) -> any LPMAPIServiceProtocol {
    if let injectedAPIService { return injectedAPIService }
    let baseURL = environment.baseURL
    if let retained = retainedAPIServices[baseURL] { return retained }
    let service = apiServiceFactory(baseURL)
    retainedAPIServices[baseURL] = service
    return service
  }

  // MARK: - Computed

  var selectedProject: VaultProject? {
    guard let id = selectedProjectId else { return nil }
    // Account membership is a security boundary for sync routing. Never
    // return a project that belongs to a different account context.
    guard projectBelongsToSelectedAccount(id) else { return nil }
    return projects.first { $0.id == id }
  }

  var isLoggedIn: Bool { currentUser != nil }
  var authContextGeneration: Int { authOperationGeneration }

  var userOrgs: [LPMOrg] { currentUser?.orgs ?? [] }

  var expiringTokens: [LPMToken] {
    let allTokens = personalTokens + orgTokens.values.flatMap { $0 }
    return allTokens.filter { token in
      guard let days = token.daysUntilExpiry else { return false }
      return days >= 0 && days <= 7
    }
  }

  /// Vaults for the currently selected account context.
  var activeVaults: [VaultProject] {
    projects.filter { projectBelongsToSelectedAccount($0.id) }
  }

  /// Filtered vaults for search.
  var filteredVaults: [VaultProject] {
    visibleVaults(matching: searchQuery)
  }

  func visibleVaults(matching search: String) -> [VaultProject] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return activeVaults }
    return projects.filter { project in
      projectBelongsToSelectedAccount(project.id)
        && (project.name.lowercased().contains(query)
          || workspaceSnapshots[project.id]?.normalizedSearchIndex.contains(query) == true)
    }
  }

  // MARK: - Navigation

  /// Selects an account as one user action. Switching accounts clears the
  /// incompatible project; reselecting the current account leaves it intact.
  func selectAccount(_ account: SelectedAccount) {
    let resolvedAccount = validatedAccount(account)
    if selectedAccount != resolvedAccount {
      cancelExports()
      selectedProjectId = nil
      selectedEnvironment = "default"
      searchQuery = ""
      selectedAccount = resolvedAccount
    } else {
      reconcileNavigationState()
    }
    showAuthStatus = false
    resetAutoLock()
  }

  /// Selects only a project visible in the current account and repairs the
  /// shared environment selection for the persistent detail column.
  func selectProject(_ projectId: String?) {
    guard let projectId else {
      if selectedProjectId != nil { cancelExports() }
      selectedProjectId = nil
      selectedEnvironment = "default"
      resetAutoLock()
      return
    }
    guard projectBelongsToSelectedAccount(projectId),
      projects.contains(where: { $0.id == projectId })
    else {
      reconcileNavigationState()
      return
    }
    if selectedProjectId != projectId { cancelExports() }
    selectedProjectId = projectId
    normalizeSelectedEnvironment()
    resetAutoLock()
  }

  func selectEnvironment(_ environment: String) {
    guard let selectedProject,
      selectedProject.environmentNames.contains(environment)
    else { return }
    if selectedEnvironment != environment { cancelExports() }
    selectedEnvironment = environment
    resetAutoLock()
  }

  /// Routes menu-bar and other global navigation to the project's owning
  /// account before selecting it, and always leaves Settings.
  func openProject(id projectId: String) {
    guard projects.contains(where: { $0.id == projectId }) else {
      reconcileNavigationState()
      return
    }
    let account: SelectedAccount
    if let orgSlug = vaultOrgAssociations[projectId] {
      guard userOrgs.contains(where: { $0.slug == orgSlug }) else {
        selectedProjectId = nil
        selectedAccount = .personal
        showAuthStatus = false
        resetAutoLock()
        return
      }
      account = .org(orgSlug)
    } else {
      account = .personal
    }
    if selectedAccount != account || selectedProjectId != projectId { cancelExports() }
    if selectedAccount != account {
      selectedProjectId = nil
      selectedAccount = account
    }
    showAuthStatus = false
    selectedProjectId = projectId
    normalizeSelectedEnvironment()
    resetAutoLock()
  }

  func showSettings() {
    showAuthStatus = true
    resetAutoLock()
  }

  /// Repairs restored/background state without extending the auto-lock timer.
  func reconcileNavigationState() {
    let previousAccount = selectedAccount
    let previousProject = selectedProjectId
    let previousEnvironment = selectedEnvironment
    defer {
      if previousAccount != selectedAccount || previousProject != selectedProjectId
        || previousEnvironment != selectedEnvironment
      {
        cancelExports()
      }
    }
    let account = validatedAccount(selectedAccount)
    if selectedAccount != account {
      selectedProjectId = nil
      selectedEnvironment = "default"
      selectedAccount = account
    }
    guard let selectedProjectId,
      projectBelongsToSelectedAccount(selectedProjectId),
      projects.contains(where: { $0.id == selectedProjectId })
    else {
      self.selectedProjectId = nil
      selectedEnvironment = "default"
      return
    }
    normalizeSelectedEnvironment()
  }

  private func validatedAccount(_ account: SelectedAccount) -> SelectedAccount {
    guard case .org(let slug) = account else { return .personal }
    return userOrgs.contains(where: { $0.slug == slug }) ? account : .personal
  }

  private func projectBelongsToSelectedAccount(_ projectId: String) -> Bool {
    switch selectedAccount {
    case .personal:
      vaultOrgAssociations[projectId] == nil
    case .org(let slug):
      vaultOrgAssociations[projectId] == slug
    }
  }

  private var firstActiveProjectId: String? {
    projects.lazy.first { projectBelongsToSelectedAccount($0.id) }?.id
  }

  private func normalizeSelectedEnvironment() {
    guard let selectedProject else {
      selectedEnvironment = "default"
      return
    }
    let names = orderedEnvironmentNames(for: selectedProject)
    if !names.contains(selectedEnvironment) {
      selectedEnvironment = names.first ?? "default"
    }
  }

  // MARK: - Init

  init(
    keychainService: KeychainServiceProtocol = KeychainService(),
    biometricService: BiometricServiceProtocol = BiometricService(),
    apiService: LPMAPIServiceProtocol? = nil,
    apiServiceFactory: @escaping @Sendable (URL) -> any LPMAPIServiceProtocol = {
      LPMAPIService(baseURL: $0)
    },
    importServiceFactory: @escaping @Sendable (URL) -> any EnvProjectImportServiceProtocol = {
      EnvProjectImportService(baseURL: $0)
    },
    projectListServiceFactory:
      @escaping @Sendable (URL) -> any ProjectListServiceProtocol = {
        SyncService.shared(baseURL: $0)
      },
    orgSyncServiceFactory: @escaping @Sendable (URL) -> any OrgSyncServiceProtocol = {
      SyncService.shared(baseURL: $0)
    },
    personalSyncServiceFactory: @escaping @Sendable (URL) -> any PersonalSyncServiceProtocol = {
      SyncService.shared(baseURL: $0)
    },
    envFileImportService: any EnvFileImportServiceProtocol = EnvFileImportService.shared,
    envFileExportService: EnvFileExportService = .shared,
    sharingKeypairProvider:
      (@Sendable () throws -> (privateKey: Data, publicKey: Data))? = nil,
    stableSyncEncryptor:
      @escaping @Sendable (
        _ plaintext: Data,
        _ principalId: String,
        _ vaultId: String,
        _ revision: Int
      ) throws -> (encryptedBlob: String, wrappedKey: String) = {
        try VaultCrypto.encryptForStableSync(
          plaintext: $0,
          principalId: $1,
          vaultId: $2,
          revision: $3
        )
      },
    stableSyncDecryptor:
      @escaping @Sendable (
        _ encryptedBlob: String,
        _ wrappedKey: String,
        _ principalId: String,
        _ vaultId: String,
        _ revision: Int,
        _ cryptoVersion: Int
      ) throws -> Data = {
        try VaultCrypto.decryptStableSyncData(
          encryptedBlob: $0,
          wrappedKey: $1,
          principalId: $2,
          vaultId: $3,
          revision: $4,
          cryptoVersion: $5
        )
      },
    authTokenProvider: (@Sendable (String, URL) async throws -> String?)? = nil,
    authAuthorizationProvider:
      @escaping @Sendable (String, URL) async throws -> AuthSessionAuthorization? = {
        registryURL, baseURL in
        try await AuthSessionStore.currentAccessAuthorization(
          registryURL: registryURL,
          baseURL: baseURL
        )
      },
    authAuthorityValidator:
      @escaping @Sendable (AuthSessionAuthorityGeneration) -> Bool = {
        AuthSessionStore.isAuthorityGenerationCurrent($0)
      },
    authorizedImportCommitter: @escaping AuthorizedImportCommitter = {
      generation, operation in
      try await AuthSessionStore.withCurrentAuthority(
        generation,
        operation: operation
      )
    },
    authorizedPullCommitter: @escaping AuthorizedPullCommitter = {
      generation, operation in
      try await AuthSessionStore.withCurrentAuthority(
        generation,
        operation: operation
      )
    },
    authorizedRemoteMutationExecutor: @escaping AuthorizedRemoteMutationExecutor = {
      generation, operation in
      try await AuthSessionStore.startWithCurrentAuthority(
        generation,
        operation: operation
      )
    },
    loginProvider: @escaping @Sendable (String, URL) async throws -> AuthSessionCredentials = {
      try await LoginService.login(registryURL: $0, baseURL: $1)
    },
    authSessionWriter:
      @escaping @Sendable (AuthSessionCredentials, String) async throws -> Void = {
        try await LoginService.writeAuthSession($0, registryURL: $1)
      },
    authSessionClearer: @escaping @Sendable (String) async throws -> Void = {
      try await LoginService.clearAuthSession(registryURL: $0)
    },
    autoLockSleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    },
    autoLockNow: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    autoLockDuration: TimeInterval = VaultConstants.vaultAutoLockDuration
  ) {
    self.keychainService = keychainService
    self.persistence = VaultPersistenceCoordinator(service: keychainService)
    self.biometricService = biometricService
    self.injectedAPIService = apiService
    self.apiServiceFactory = apiServiceFactory
    self.importServiceFactory = importServiceFactory
    self.projectListServiceFactory = projectListServiceFactory
    self.orgSyncServiceFactory = orgSyncServiceFactory
    self.personalSyncServiceFactory = personalSyncServiceFactory
    self.envFileImportService = envFileImportService
    self.envFileExportService = envFileExportService
    if let sharingKeypairProvider {
      self.sharingKeypairProvider = { _, _, _, _ in
        try sharingKeypairProvider()
      }
    } else {
      self.sharingKeypairProvider = { registryURL, callerUserID, _, _ in
        try VaultCrypto.getOrCreateX25519Keypair(
          registryURL: registryURL,
          callerUserID: callerUserID
        )
      }
    }
    self.stableSyncEncryptor = stableSyncEncryptor
    self.stableSyncDecryptor = stableSyncDecryptor
    self.authTokenProvider = authTokenProvider
    self.authAuthorizationProvider = authAuthorizationProvider
    self.authAuthorityValidator = authAuthorityValidator
    self.authorizedImportCommitter = authorizedImportCommitter
    self.authorizedPullCommitter = authorizedPullCommitter
    self.authorizedRemoteMutationExecutor = authorizedRemoteMutationExecutor
    self.loginProvider = loginProvider
    self.authSessionWriter = authSessionWriter
    self.authSessionClearer = authSessionClearer
    self.autoLockSleep = autoLockSleep
    self.autoLockNow = autoLockNow
    self.autoLockDuration = autoLockDuration

    #if DEBUG
      // Local-server selection is a debug-only developer convenience.
      if let saved = UserDefaults.standard.string(forKey: "lpm-vault-environment"),
        let env = AppEnvironment(rawValue: saved)
      {
        self.appEnvironment = env
      }
    #endif

  }

  #if DEBUG
    /// Switch between the production server and the local development server.
    /// Clears current session and reloads tokens for the new environment.
    func switchEnvironment(to env: AppEnvironment) {
      guard env != appEnvironment else { return }
      authOperationGeneration &+= 1
      isLoggingIn = false
      invalidateTokenLoad()
      invalidatePendingOrgPush()
      appEnvironment = env
      UserDefaults.standard.set(env.rawValue, forKey: "lpm-vault-environment")
      // Reset auth state for new environment
      currentUser = nil
      currentIdentityAuthorityGeneration = nil
      personalTokens = []
      orgTokens = [:]
      // Reload tokens from the new environment's keychain entry
      Task { await loadAccount() }
    }
  #endif

  // MARK: - Load

  private func beginSelectedProjectLoadIfNeeded() {
    selectedProjectLoadGeneration &+= 1
    let generation = selectedProjectLoadGeneration
    selectedProjectLoadTask?.cancel()
    selectedProjectLoadTask = nil
    isLoadingSelectedProject = false

    let retainedProjectID = isUnlocked ? selectedProjectId : nil
    let evicted = projects.map { project in
      guard project.hasLoadedEnvironments, project.id != retainedProjectID else { return project }
      return VaultProject(metadata: project.metadata)
    }
    if evicted != projects { projects = evicted }

    guard isUnlocked, let projectID = selectedProjectId,
      projectBelongsToSelectedAccount(projectID),
      let current = projects.first(where: { $0.id == projectID })
    else { return }
    guard !current.hasLoadedEnvironments else {
      normalizeSelectedEnvironment()
      return
    }

    isLoadingSelectedProject = true
    let task = Task { [weak self, persistence] in
      let result = await persistence.loadProject(vaultId: projectID)
      guard !Task.isCancelled, let self,
        generation == self.selectedProjectLoadGeneration,
        self.isUnlocked,
        self.selectedProjectId == projectID,
        self.projectBelongsToSelectedAccount(projectID)
      else { return }

      switch result {
      case .success(let loadedProject?):
        guard let index = self.projects.firstIndex(where: { $0.id == projectID }) else {
          self.isLoadingSelectedProject = false
          self.selectedProjectLoadTask = nil
          return
        }
        self.projects[index] = loadedProject
        self.error = nil
        self.normalizeSelectedEnvironment()
      case .success(nil):
        self.error = "The selected env project no longer exists in Keychain."
        self.selectedProjectId = nil
      case .failure(let failure):
        self.error = "Could not load the selected env project. \(failure.description)"
      }
      if generation == self.selectedProjectLoadGeneration {
        self.isLoadingSelectedProject = false
        self.selectedProjectLoadTask = nil
      }
    }
    selectedProjectLoadTask = task
  }

  private func invalidateSelectedProjectLoad() {
    selectedProjectLoadGeneration &+= 1
    selectedProjectLoadTask?.cancel()
    selectedProjectLoadTask = nil
    isLoadingSelectedProject = false
  }

  /// Load a coherent Keychain snapshot. A newer load, lock, or mutation
  /// invalidates this generation before it can publish decrypted state.
  @discardableResult
  func loadProjects() async -> Bool {
    invalidateSelectedProjectLoad()
    projectLoadGeneration &+= 1
    let generation = projectLoadGeneration
    projectLoadTask?.cancel()
    isLoadingProjects = true

    let task = Task { [weak self, persistence] in
      let result = await persistence.loadSnapshot()
      guard !Task.isCancelled, let self,
        generation == self.projectLoadGeneration
      else { return }
      guard case .success(let snapshot) = result else {
        if case .failure(let failure) = result {
          self.error = "Could not load the protected vault state. \(failure.description)"
        }
        self.isLoadingProjects = false
        self.projectLoadTask = nil
        return
      }
      guard !Task.isCancelled, generation == self.projectLoadGeneration else { return }
      self.workspaceSnapshots = [:]
      self.pendingWorkspaceSnapshots = [:]
      self.projects = snapshot.projects
      self.syncMetadata = snapshot.syncMetadata
      self.vaultOrgAssociations = snapshot.orgAssociations
      self.error = nil
      self.lastSuccessfulProjectLoadGeneration = generation
      self.loadEnvironmentOrders()
      self.reconcileNavigationState()
      self.beginSelectedProjectLoadIfNeeded()
      self.isLoadingProjects = false
      self.projectLoadTask = nil
    }
    projectLoadTask = task
    await task.value
    return generation == lastSuccessfulProjectLoadGeneration && !isLoadingProjects
  }

  // MARK: - Transactional Cloud Imports

  func importCloudProject(
    _ remote: SyncService.RemoteProject
  ) async -> Result<ImportedEnvProject, EnvProjectImportError> {
    await importRemoteProject(remote, orgSlug: nil)
  }

  func importOrganizationProject(
    _ remote: SyncService.RemoteProject,
    orgSlug: String
  ) async -> Result<ImportedEnvProject, EnvProjectImportError> {
    guard EnvValidation.isSafeOrgSlug(orgSlug) else {
      return .failure(.invalidPayload("The organization identifier is invalid."))
    }
    return await importRemoteProject(remote, orgSlug: orgSlug)
  }

  func listPersonalCloudProjects() async -> Result<
    [SyncService.RemoteProject], SyncService.ProjectListError
  > {
    await listCloudProjects(orgSlug: nil)
  }

  func listOrganizationCloudProjects(
    orgSlug: String
  ) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError> {
    guard EnvValidation.isSafeOrgSlug(orgSlug),
      userOrgs.contains(where: { $0.slug == orgSlug })
    else { return .failure(.forbidden) }
    return await listCloudProjects(orgSlug: orgSlug)
  }

  private func listCloudProjects(
    orgSlug: String?
  ) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError> {
    guard let authority = await resolveCloudAuthorization() else {
      return .failure(.sessionNotAuthorized)
    }
    let service = projectListServiceFactory(authority.environment.baseURL)
    let result: Result<[SyncService.RemoteProject], SyncService.ProjectListError>
    if let orgSlug {
      result = await service.listOrgProjects(
        authToken: authority.token,
        orgSlug: orgSlug
      )
    } else {
      result = await service.listPersonalProjects(authToken: authority.token)
    }
    guard await hasCurrentCloudAuthorization(authority) else {
      clearIdentityIfPeerAuthorityChanged(authority)
      return .failure(.cancelled)
    }
    if case .failure(let error) = result,
      error == .unauthorized || error == .sessionNotAuthorized
    {
      clearAuthDependentState(message: error.localizedDescription)
    }
    return result
  }

  private func importRemoteProject(
    _ remote: SyncService.RemoteProject,
    orgSlug: String?
  ) async -> Result<ImportedEnvProject, EnvProjectImportError> {
    let sessionGeneration = vaultSessionGeneration
    let authGeneration = authOperationGeneration
    let environment = appEnvironment
    let baseURL = environment.baseURL
    guard EnvValidation.isSafeVaultId(remote.vaultId) else {
      return .failure(
        .invalidPayload("The server returned an unsafe env project identifier."))
    }
    guard let listedVersion = remote.version, listedVersion > 0 else {
      return .failure(.invalidPayload("The env project listing has an invalid version."))
    }
    guard activeImportIds.insert(remote.vaultId).inserted
    else { return .failure(.duplicate) }
    defer { activeImportIds.remove(remote.vaultId) }

    let existing: ProjectCreationRecord?
    switch await persistence.containsProject(vaultId: remote.vaultId) {
    case .success(true):
      guard let orgSlug else { return .failure(.duplicate) }
      guard isUnlocked else { return .failure(.cancelled) }
      switch await persistence.loadProjectCreationRecord(vaultId: remote.vaultId) {
      case .success(let record):
        guard record.project != nil else { return .failure(.cancelled) }
        guard record.orgAssociations[remote.vaultId] != orgSlug else { return .failure(.duplicate) }
        existing = record
      case .failure(let failure): return .failure(.persistence(failure.description))
      }
    case .success(false): existing = nil
    case .failure(let persistenceError):
      return .failure(.persistence(persistenceError.description))
    }
    guard authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      environment == appEnvironment
    else { return .failure(.cancelled) }
    let authResolution = await resolveAuthToken(environment.registryURL, baseURL)
    guard authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      environment == appEnvironment
    else { return .failure(.cancelled) }
    guard let authToken = authResolution.token else {
      rejectMissingAccountAuthorization(
        authResolution,
        fallback: "Sign in to lpm.dev, then retry."
      )
      if let failure = authResolution.failure { return .failure(.authStorage(failure)) }
      return .failure(.notAuthenticated)
    }
    guard authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      environment == appEnvironment
    else { return .failure(.cancelled) }
    guard
      acceptAccountAuthorization(
        authResolution,
        failureMessage: "The active lpm.dev account changed. Reload account data before importing."
      )
    else { return .failure(.cancelled) }
    guard authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      environment == appEnvironment
    else {
      return .failure(.cancelled)
    }
    let authority = CloudAuthorization(
      environment: environment,
      authGeneration: authGeneration,
      sessionGeneration: sessionGeneration,
      token: authToken,
      authorityGeneration: authResolution.authorityGeneration
    )
    guard await hasCurrentCloudAuthorization(authority) else {
      clearIdentityIfPeerAuthorityChanged(authority)
      return .failure(.cancelled)
    }

    do {
      let service = importServiceFactory(baseURL)
      let payload: RemoteEnvProjectPayload
      if let orgSlug {
        guard let expectedCallerUserID = currentUser?.id, !expectedCallerUserID.isEmpty else {
          return .failure(.invalidPayload("The active account identity is invalid."))
        }
        payload = try await service.loadOrganization(
          authToken: authToken,
          orgSlug: orgSlug,
          vaultId: remote.vaultId,
          expectedCallerUserID: expectedCallerUserID
        )
      } else {
        payload = try await service.loadPersonal(
          authToken: authToken,
          vaultId: remote.vaultId
        )
      }
      try Task.checkCancellation()
      guard await hasCurrentCloudAuthorization(authority) else {
        clearIdentityIfPeerAuthorityChanged(authority)
        return .failure(.cancelled)
      }
      guard payload.vaultId == remote.vaultId else {
        return .failure(.invalidPayload("The cloud response is for a different env project."))
      }
      guard payload.version > 0, payload.version >= listedVersion else {
        return .failure(
          .invalidPayload("The cloud response has an invalid or downgraded version."))
      }
      let account: SelectedAccount = orgSlug.map(SelectedAccount.org) ?? .personal
      guard selectedAccount == account,
        let expectedPrincipalID = syncPrincipalID(for: account),
        payload.principalID == expectedPrincipalID
      else {
        return .failure(
          .invalidPayload("The cloud response is bound to a different account."))
      }
      let binding = SyncPrincipalBinding(
        registryURL: environment.registryURL,
        principalID: expectedPrincipalID,
        scope: orgSlug == nil ? "personal" : "organization"
      )

		guard
			let projectName = importProjectName(
				remote.name,
				vaultId: remote.vaultId,
				isOrganization: orgSlug != nil
			)
		else {
			return .failure(.invalidPayload("The cloud env project name is invalid."))
		}
		let project = VaultProject(
			id: remote.vaultId,
			name: projectName,
			path: "",
			environments: payload.environments
		)
      guard EnvValidation.areValidEnvironments(project.environments) else {
        return .failure(
          .invalidPayload(
            "The env project contains invalid environment or variable names."))
      }

      // Any older project snapshot must not overwrite this commit afterward.
      guard await hasCurrentCloudAuthorization(authority) else {
        clearIdentityIfPeerAuthorityChanged(authority)
        return .failure(.cancelled)
      }
      invalidateProjectLoad()
      try Task.checkCancellation()
      let persistence = persistence
      let commitOperation: @Sendable () async -> ImportPersistenceResult = { [weak self] in
        guard let self,
          await self.isCurrentCloudCommit(
            authority,
            account: account,
            principalID: expectedPrincipalID
          )
        else {
          return .cancelled
        }
        return await persistence.importProject(
          project,
          orgSlug: orgSlug,
          version: payload.version,
          binding: binding,
          existing: existing
        )
      }
      let commit: ImportPersistenceResult
      if let authorityGeneration = authority.authorityGeneration {
        guard
          let authorizedCommit = try await authorizedImportCommitter(
            authorityGeneration,
            commitOperation
          )
        else { return .failure(.cancelled) }
        commit = authorizedCommit
      } else {
        guard await hasCurrentCloudAuthorization(authority) else {
          clearIdentityIfPeerAuthorityChanged(authority)
          return .failure(.cancelled)
        }
        commit = await commitOperation()
      }

      switch commit {
      case .success(let committed):
        let project = committed.project
        let keyCount = project.environments.values.reduce(0) { $0 + $1.count }
        let authorizationIsCurrent = await hasCurrentCloudAuthorization(authority)
        let ownsPresentation = authorizationIsCurrent && !Task.isCancelled
        if !authorizationIsCurrent {
          clearIdentityIfPeerAuthorityChanged(authority)
        }
        guard sessionGeneration == vaultSessionGeneration else {
          return .success(
            ImportedEnvProject(
              projectId: project.id,
              version: payload.version,
              keyCount: keyCount
            ))
        }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
          projects[index] = project
        } else {
          projects.append(project)
        }
        projects.sort {
          $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        applySyncMetadata(committed.syncMetadata, for: project.id)
        vaultOrgAssociations = committed.orgAssociations
        if ownsPresentation { openProject(id: project.id) }
        if ownsPresentation { error = committed.warning }
        return .success(
          ImportedEnvProject(
            projectId: project.id,
            version: payload.version,
            keyCount: keyCount
          ))
      case .duplicate:
        return .failure(.duplicate)
      case .conflict:
        return .failure(.persistence("The local env project changed during import. Retry to merge its current values."))
      case .staleVersion:
        return .failure(.invalidPayload("The cloud env project is older than the last verified revision."))
      case .cancelled:
        return .failure(.cancelled)
      case .failure(let persistenceError):
		if case .transactionOutcomeIndeterminate = persistenceError {
          if sessionGeneration == vaultSessionGeneration, isUnlocked {
            _ = await loadProjects()
          }
          return .failure(
            .persistence(
              isUnlocked
                ? "The import could not be rolled back completely. Local state was reloaded from Keychain."
                : "The import could not be rolled back completely. Unlock to reload local state from Keychain."
            ))
        }
        return .failure(.persistence(persistenceError.description))
      }
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let importError as EnvProjectImportError {
      if importError == .unauthorized {
        rejectUnauthorizedCloudResponseIfCurrent(
          authority,
          message: importError.localizedDescription
        )
      }
      return .failure(importError)
    } catch {
      return .failure(.invalidPayload(error.localizedDescription))
    }
  }

	private func importProjectName(
		_ name: String?,
		vaultId: String,
		isOrganization: Bool
	) -> String? {
		let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if !trimmed.isEmpty { return EnvValidation.normalizedProjectName(trimmed) }
		let prefix = isOrganization ? "org-env" : "env"
		return EnvValidation.normalizedProjectName("\(prefix)-\(vaultId.prefix(8))")
	}

  // MARK: - Project Operations

  /// Currently selected environment tab name
  var selectedEnvironment: String = "default" {
    didSet {
      if oldValue != selectedEnvironment, let selectedProjectId {
        cancelExports()
        cancelLocalEnvImport(projectId: selectedProjectId, environment: oldValue)
      }
    }
  }

  /// Create a new vault with just a name (no folder needed).
  /// If orgSlug is provided, immediately shares with that org.
  @discardableResult
  func createVault(
    name: String,
    orgSlug: String? = nil,
    vaultId: String = UUID().uuidString.lowercased()
  ) async -> VaultCreationResult {
    let expectedAccount = orgSlug.map(SelectedAccount.org) ?? .personal
    let sessionGeneration = vaultSessionGeneration
    guard isUnlocked, selectedAccount == expectedAccount else { return .failed }
    guard let normalizedName = EnvValidation.normalizedProjectName(name),
      EnvValidation.isSafeVaultId(vaultId)
    else {
      error = "The env project name or identifier is invalid."
      return .failed
    }
    let environments: [String: [String: String]] = ["default": [:]]

    let creationRecord: ProjectCreationRecord
    switch await persistence.loadProjectCreationRecord(vaultId: vaultId) {
    case .success(let loaded): creationRecord = loaded
    case .failure(let persistenceError):
      guard isUnlocked, selectedAccount == expectedAccount,
        sessionGeneration == vaultSessionGeneration
      else { return .failed }
      error = persistenceError.description
      return .failed
    }
    guard isUnlocked, selectedAccount == expectedAccount,
      sessionGeneration == vaultSessionGeneration
    else { return .failed }
    if let existing = creationRecord.project {
      guard existing.name == normalizedName,
        existing.path.isEmpty,
        existing.environments == environments,
        creationRecord.orgAssociations[vaultId] == orgSlug
      else {
        error = "The pending env project no longer matches this creation request."
        return .failed
      }
      if !projects.contains(where: { $0.id == vaultId }) {
        projects.append(existing)
        projects.sort {
          $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
      }
      vaultOrgAssociations = creationRecord.orgAssociations
      openProject(id: vaultId)
    } else {
      guard
        await addProjectWithVaultId(
          vaultId: vaultId,
          name: normalizedName,
          path: "",
          environments: environments,
          orgSlug: orgSlug
        )
      else { return .failed }
    }
    guard isUnlocked, selectedAccount == expectedAccount,
      sessionGeneration == vaultSessionGeneration
    else { return .failed }

    if let slug = orgSlug {
      openProject(id: vaultId)
      return await pushToOrg(orgSlug: slug)
    }
    return .completed
  }

  /// Associate a vault with an org (for column 2 filtering).
  @discardableResult
  func associateVaultWithOrg(vaultId: String, orgSlug: String) async -> Bool {
    guard let associations = await persistence.associate(vaultId: vaultId, orgSlug: orgSlug)
    else {
      error = "Could not save the organization association."
      return false
    }
    vaultOrgAssociations = associations
    reconcileNavigationState()
    return true
  }

  /// Add a project with a specific vault ID (for re-adding existing vaults).
  /// Returns only after the Keychain write and in-memory selection are complete.
  @discardableResult
  func addProjectWithVaultId(
    vaultId: String,
    name: String,
    path: String,
    environments: [String: [String: String]],
    orgSlug: String? = nil
  ) async -> Bool {
    invalidateProjectLoad()
    let expectedAccount = orgSlug.map(SelectedAccount.org) ?? selectedAccount
    guard isUnlocked, selectedAccount == expectedAccount else { return false }
    guard let normalizedName = EnvValidation.normalizedProjectName(name) else {
      error =
        "The env project name must be between 1 and \(EnvValidation.maximumProjectNameLength) characters."
      return false
    }
    guard EnvValidation.isSafeVaultId(vaultId) else {
      error = "The env project identifier is invalid."
      return false
    }
    guard EnvValidation.areValidEnvironments(environments) else {
      error = "Environment names or variable names do not match the LPM env format."
      return false
    }
    let sessionGeneration = vaultSessionGeneration
    let project = VaultProject(
      id: vaultId,
      name: normalizedName,
      path: path,
      environments: environments
    )

    // Run Keychain write off main thread to prevent UI freeze
    let result = await persistence.createProject(project, orgSlug: orgSlug)
    switch result {
    case .success(let committed):
      guard sessionGeneration == vaultSessionGeneration, isUnlocked,
        selectedAccount == expectedAccount
      else { return true }
      projects.append(project)
      projects.sort {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      vaultOrgAssociations = committed.orgAssociations
      openProject(id: vaultId)
      writeLpmJson(vaultId: vaultId, projectPath: path)
      error = committed.warning
      return true
    case .failure(let err):
      guard sessionGeneration == vaultSessionGeneration, isUnlocked,
        selectedAccount == expectedAccount
      else { return false }
      error = err.description
      return false
    }
  }

  func renameProject(_ project: VaultProject, to name: String) {
    guard let normalizedName = EnvValidation.normalizedProjectName(name),
      let current = projects.first(where: { $0.id == project.id })
    else { return }
    enqueueProjectMutation(
      base: current,
      mutation: .renameProject(expectedName: current.name, replacement: normalizedName)
    )
  }

  // MARK: - lpm.json Integration

  /// Write or update vault ID in lpm.json.
  /// Preserves existing keys (runtime, env, tasks, tools, services).
  private func writeLpmJson(vaultId: String, projectPath: String) {
    guard !projectPath.isEmpty else { return }
    let url = URL(fileURLWithPath: projectPath).appendingPathComponent("lpm.json")
    try? ProjectConfigFile.writeVaultID(vaultId, to: url)
  }

  /// Remove from sidebar only — Keychain data stays.
  /// Re-adding the same folder will restore the project.
  func removeFromSidebar(_ project: VaultProject) {
    cancelLocalEnvImports(projectId: project.id)
    invalidateProjectLoad()
    Task { [weak self, persistence] in
      guard await persistence.removeFromSidebar(vaultId: project.id) else {
        self?.error = "Could not remove the env project from the protected sidebar index."
        return
      }
      guard let self else { return }
      projects.removeAll { $0.id == project.id }
      if selectedProjectId == project.id {
        selectedProjectId = firstActiveProjectId
        normalizeSelectedEnvironment()
      }
    }
  }

  /// Delete local vault data (Keychain) but keep cloud copy.
  /// Can be recovered via `lpm env pull`.
  @discardableResult
  func deleteLocalVault(_ project: VaultProject) async -> Bool {
    cancelLocalEnvImports(projectId: project.id)
    invalidateProjectLoad()
    let sessionGeneration = vaultSessionGeneration
    let wasSelected = selectedProjectId == project.id
    let snapshot: VaultPersistenceSnapshot
    switch await persistence.deleteProjectAndMetadata(vaultId: project.id) {
    case .success(let persisted):
      snapshot = persisted
    case .failure(let persistenceError):
	  if case .transactionOutcomeIndeterminate = persistenceError {
        lock()
        error =
          "The local deletion could not be rolled back completely. The vault was locked; unlock to reload durable state."
      } else {
        error = "Could not delete the local Keychain copy. The env project was kept."
      }
      return false
    }

    environmentOrders.removeValue(forKey: project.id)
    UserDefaults.standard.removeObject(forKey: Self.envOrderPrefix + project.id)
    // Durable deletion remains successful if locking won the race. Unlocking
    // will load the new snapshot; never republish its plaintext while locked.
    guard sessionGeneration == vaultSessionGeneration, isUnlocked else { return true }
    let shouldSelectFallback = wasSelected && selectedProjectId == project.id
    projects = snapshot.projects
    syncMetadata = snapshot.syncMetadata
    vaultOrgAssociations = snapshot.orgAssociations
    if shouldSelectFallback {
      selectedProjectId = firstActiveProjectId
    }
    reconcileNavigationState()
    beginSelectedProjectLoadIfNeeded()
    return true
  }

  // MARK: - Environment Operations

  /// Adds a new environment after persistence succeeds. The async boundary
  /// keeps a rejected Keychain write from appearing as a successful import.
  @discardableResult
  func addEnvironment(
    to projectId: String,
    name: String,
    secrets: [String: String] = [:]
  ) async -> Bool {
    guard isUnlocked else {
      error = EnvFileImportError.vaultLocked.localizedDescription
      return false
    }
    let sessionGeneration = vaultSessionGeneration
    guard selectedProjectId == projectId,
      let project = projects.first(where: { $0.id == projectId })
    else { return false }
    let target = LocalEnvImportTarget(projectId: projectId, environment: name)
    let requestId = UUID()
    localEnvCreationRequests[target] = requestId
    localEnvImportAuthority.begin(target, requestId: requestId)
    defer {
      if localEnvCreationRequests[target] == requestId {
        localEnvCreationRequests.removeValue(forKey: target)
      }
      localEnvImportAuthority.complete(target, requestId: requestId)
    }
    guard EnvValidation.isValidEnvironmentName(name),
      secrets.keys.allSatisfy(EnvValidation.isValidVariableName)
    else { return false }
    guard project.environments[name] == nil else { return false }
    invalidateProjectLoad()
    let commit = await withTaskCancellationHandler {
      await persistence.addEnvironment(
        projectId: projectId,
        projectName: project.name,
        projectPath: project.path,
        environment: name,
        secrets: secrets,
        requestId: requestId,
        authority: localEnvImportAuthority
      )
    } onCancel: { [localEnvImportAuthority] in
      localEnvImportAuthority.cancel(target, requestId: requestId)
    }
    guard case .success(let persisted) = commit else {
      switch commit {
      case .failure(let persistenceError):
        error = persistenceError.description
      case .targetUnavailable:
        error = EnvFileImportError.targetUnavailable.localizedDescription
      case .caseInsensitiveCollision:
        error = EnvFileImportError.caseInsensitiveCollisionWithExisting.localizedDescription
      case .cancelled:
        return false
      case .success:
        break
      }
      return false
    }
    guard sessionGeneration == vaultSessionGeneration, isUnlocked,
      projects.contains(where: { $0.id == projectId }),
      projects.first(where: { $0.id == projectId })?.environments[name] == nil
    else {
      // Persistence is intentionally non-cancellable. Report its durable
      // success without republishing plaintext into stale or locked UI.
      return true
    }
    updateProjectInPlace(persisted.project)
    applySyncMetadata(persisted.syncMetadata, for: persisted.project.id)
    // The persisted project already contains the new environment. Remove it
    // from the derived order before appending it in the requested position.
    var order = orderedEnvironmentNames(for: persisted.project).filter { $0 != name }
    order.append(name)
    saveEnvironmentOrder(for: projectId, order: order)
    if localEnvCreationRequests[target] == requestId,
      selectedProjectId == projectId,
      !Task.isCancelled
    {
      error = persisted.warning
      selectedEnvironment = name
    }
    return true
  }

  /// Delete an environment tab from a project. Cannot delete the last environment.
  func deleteEnvironment(from projectId: String, name: String) {
    cancelLocalEnvImport(projectId: projectId, environment: name)
    guard let project = projects.first(where: { $0.id == projectId }),
      let expectedSecrets = project.environments[name]
    else { return }
    guard project.environments.count > 1 else { return }
    enqueueProjectMutation(
      base: project,
      mutation: .deleteEnvironment(name: name, expectedSecrets: expectedSecrets)
    ) { [weak self] persisted in
      guard let self else { return }
      var order = orderedEnvironmentNames(for: persisted)
      order.removeAll { $0 == name }
      saveEnvironmentOrder(for: projectId, order: order)
      guard selectedProjectId == projectId else { return }
      if selectedEnvironment == name {
        selectedEnvironment = persisted.environments.keys.sorted().first ?? "default"
      }
    }
  }

  /// Duplicate an environment's secrets to a new tab.
  func duplicateEnvironment(in projectId: String, from source: String, to newName: String) {
    guard let project = projects.first(where: { $0.id == projectId }) else { return }
    guard EnvValidation.isValidEnvironmentName(newName) else { return }
    guard project.environments[newName] == nil else { return }
    guard let sourceSecrets = project.environments[source] else { return }
    enqueueProjectMutation(
      base: project,
      mutation: .duplicateEnvironment(
        source: source,
        expectedSecrets: sourceSecrets,
        destination: newName
      )
    ) { [weak self] persisted in
      guard let self else { return }
      var order = orderedEnvironmentNames(for: persisted).filter { $0 != newName }
      if let sourceIdx = order.firstIndex(of: source) {
        order.insert(newName, at: sourceIdx + 1)
      } else {
        order.append(newName)
      }
      saveEnvironmentOrder(for: projectId, order: order)
      guard selectedProjectId == projectId else { return }
      selectedEnvironment = newName
    }
  }

  /// Rename an environment tab.
  func renameEnvironment(in projectId: String, from oldName: String, to newName: String) {
    cancelLocalEnvImport(projectId: projectId, environment: oldName)
    guard let project = projects.first(where: { $0.id == projectId }) else { return }
    guard EnvValidation.isValidEnvironmentName(newName) else { return }
    guard project.environments[newName] == nil else { return }
    guard let secrets = project.environments[oldName] else { return }
    enqueueProjectMutation(
      base: project,
      mutation: .renameEnvironment(
        source: oldName,
        expectedSecrets: secrets,
        destination: newName
      )
    ) { [weak self] persisted in
      guard let self else { return }
      var order = orderedEnvironmentNames(for: persisted)
      if let idx = order.firstIndex(of: oldName) {
        order[idx] = newName
      }
      saveEnvironmentOrder(for: projectId, order: order)
      guard selectedProjectId == projectId else { return }
      if selectedEnvironment == oldName { selectedEnvironment = newName }
    }
  }

  /// Clear all secrets from an environment (keeps the tab).
  func clearEnvironment(in projectId: String, name: String) {
    cancelLocalEnvImport(projectId: projectId, environment: name)
    guard let project = projects.first(where: { $0.id == projectId }),
      let expectedSecrets = project.environments[name]
    else { return }
    enqueueProjectMutation(
      base: project,
      mutation: .clearEnvironment(name: name, expectedSecrets: expectedSecrets)
    )
  }

  // MARK: - Secret Operations (environment-aware)

  // MARK: - Bounded Local Dotenv Imports

  /// Reads and parses off the main actor, then persists the exact captured
  /// destination before publishing. A newer import to the same destination
  /// cancels and supersedes the older request.
  func importEnvFile(
    at url: URL,
    to projectId: String,
    environment: String
  ) async -> Result<ImportedEnvFile, EnvFileImportError> {
    guard isUnlocked else { return .failure(.vaultLocked) }
    guard selectedProjectId == projectId, selectedEnvironment == environment,
      let project = projects.first(where: { $0.id == projectId }),
      project.environments[environment] != nil
    else { return .failure(.targetUnavailable) }

    let target = LocalEnvImportTarget(projectId: projectId, environment: environment)
    let requestId = UUID()
    let sessionGeneration = vaultSessionGeneration
    localEnvImportTasks[target]?.cancel()
    localEnvImportRequests[target] = requestId
    localEnvImportAuthority.begin(target, requestId: requestId)

    let task = Task { [envFileImportService] in
      try await envFileImportService.load(at: url)
    }
    localEnvImportTasks[target] = task
    defer {
      if localEnvImportRequests[target] == requestId {
        localEnvImportTasks.removeValue(forKey: target)
        localEnvImportRequests.removeValue(forKey: target)
      }
      localEnvImportAuthority.complete(target, requestId: requestId)
    }

    do {
      let imported = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try Task.checkCancellation()
      guard localEnvImportRequests[target] == requestId,
        sessionGeneration == vaultSessionGeneration,
        isUnlocked,
        selectedProjectId == projectId,
        selectedEnvironment == environment,
        let currentProject = projects.first(where: { $0.id == projectId }),
        currentProject.environments[environment] != nil
      else { return .failure(.cancelled) }

      invalidateProjectLoad()
      let commit = await withTaskCancellationHandler {
        await persistence.importSecrets(
          projectId: projectId,
          projectName: currentProject.name,
          projectPath: currentProject.path,
          environment: environment,
          secrets: imported.secrets,
          requestId: requestId,
          authority: localEnvImportAuthority
        )
      } onCancel: { [localEnvImportAuthority] in
        localEnvImportAuthority.cancel(target, requestId: requestId)
      }

      switch commit {
      case .success(let persisted):
        guard sessionGeneration == vaultSessionGeneration,
          isUnlocked,
          projects.contains(where: { $0.id == projectId })
        else {
          // The transaction crossed its synchronous commit point. Keep
          // locked/stale UI clear, but report the durable success.
          return .success(imported)
        }
        updateProjectInPlace(persisted.project)
        applySyncMetadata(persisted.syncMetadata, for: persisted.project.id)
        if localEnvImportRequests[target] == requestId,
          selectedProjectId == projectId,
          selectedEnvironment == environment,
          !Task.isCancelled
        {
          error = persisted.warning
        }
        return .success(imported)
      case .targetUnavailable:
        return .failure(.targetUnavailable)
      case .caseInsensitiveCollision:
        return .failure(.caseInsensitiveCollisionWithExisting)
      case .cancelled:
        return .failure(.cancelled)
      case .failure(let persistenceError):
		if case .transactionOutcomeIndeterminate = persistenceError {
          if sessionGeneration == vaultSessionGeneration, isUnlocked,
            selectedProjectId == projectId,
            selectedEnvironment == environment
          {
            _ = await loadProjects()
          }
        }
        return .failure(.persistence(persistenceError.description))
      }
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let importError as EnvFileImportError {
      return .failure(importError)
    } catch {
      return .failure(.readFailed)
    }
  }

  func loadEnvFilePreview(
    at url: URL,
    for projectId: String
  ) async -> Result<ImportedEnvFile, EnvFileImportError> {
    guard isUnlocked else { return .failure(.vaultLocked) }
    guard selectedProjectId == projectId,
      projects.contains(where: { $0.id == projectId })
    else { return .failure(.targetUnavailable) }
    let requestId = UUID()
    let sessionGeneration = vaultSessionGeneration
    let task = Task { [envFileImportService] in
      let imported = try await envFileImportService.load(at: url)
      try Task.checkCancellation()
      return imported
    }
    localEnvPreviewTasks[requestId] = task
    defer { localEnvPreviewTasks.removeValue(forKey: requestId) }
    do {
      let imported = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard sessionGeneration == vaultSessionGeneration, isUnlocked,
        selectedProjectId == projectId,
        projects.contains(where: { $0.id == projectId })
      else {
        return .failure(.cancelled)
      }
      return .success(imported)
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let importError as EnvFileImportError {
      return .failure(importError)
    } catch {
      return .failure(.readFailed)
    }
  }

  private func cancelLocalEnvImport(projectId: String, environment: String) {
    let target = LocalEnvImportTarget(projectId: projectId, environment: environment)
    localEnvImportTasks.removeValue(forKey: target)?.cancel()
    localEnvImportRequests.removeValue(forKey: target)
    localEnvCreationRequests.removeValue(forKey: target)
    localEnvImportAuthority.cancel(target)
  }

  private func cancelLocalEnvImports(projectId: String? = nil) {
    let targets = Set(localEnvImportTasks.keys)
      .union(localEnvImportRequests.keys)
      .union(localEnvCreationRequests.keys)
      .filter { projectId == nil || $0.projectId == projectId }
    for target in targets {
      localEnvImportTasks.removeValue(forKey: target)?.cancel()
      localEnvImportRequests.removeValue(forKey: target)
      localEnvCreationRequests.removeValue(forKey: target)
      localEnvImportAuthority.cancel(target)
    }
  }

  private func cancelLocalEnvPreviews() {
    for task in localEnvPreviewTasks.values { task.cancel() }
    localEnvPreviewTasks.removeAll()
  }

  func addSecret(
    to projectId: String,
    environment: String,
    key: String,
    value: String
  ) async -> AddSecretResult {
    guard isUnlocked else { return .failure(.vaultLocked) }
    guard EnvValidation.isValidVariableName(key) else { return .failure(.invalidName) }
    let sessionGeneration = vaultSessionGeneration
    guard let project = projects.first(where: { $0.id == projectId }),
      let secrets = project.environments[environment]
    else { return .failure(.targetUnavailable) }
    guard secrets[key] == nil else { return .failure(.duplicate) }
    if let existingKey = EnvValidation.caseInsensitiveCollision(for: key, in: secrets.keys) {
      return .failure(.caseInsensitiveCollision(existingKey: existingKey))
    }

    invalidateProjectLoad()
    let commit = await persistence.addSecret(
      projectId: projectId,
      projectName: project.name,
      projectPath: project.path,
      environment: environment,
      key: key,
      value: value
    )
    switch commit {
    case .success(let persisted):
      guard sessionGeneration == vaultSessionGeneration, isUnlocked else {
        // Durable success raced a lock. Do not republish plaintext until unlock.
        return .success
      }
      updateProjectInPlace(persisted.project)
      applySyncMetadata(persisted.syncMetadata, for: persisted.project.id)
      error = persisted.warning
      return .success
    case .targetUnavailable:
      return .failure(.targetUnavailable)
    case .failure(let persistenceError):
		if case .transactionOutcomeIndeterminate = persistenceError,
        sessionGeneration == vaultSessionGeneration, isUnlocked
      {
        _ = await loadProjects()
      }
      return .failure(.persistence(persistenceError.description))
    }
  }

  func updateSecret(in projectId: String, key: String, newValue: String) {
    updateSecret(
      in: projectId,
      environment: selectedEnvironment,
      key: key,
      newValue: newValue
    )
  }

  func updateSecret(in projectId: String, environment: String, key: String, newValue: String) {
    guard isUnlocked,
      selectedProjectId == projectId,
      let project = selectedProject,
      let expectedValue = project.environments[environment]?[key]
    else { return }
    enqueueProjectMutation(
      base: project,
      mutation: .updateSecret(
        environment: environment,
        key: key,
        expectedValue: expectedValue,
        replacement: newValue
      )
    )
  }

  func updateSecretAndWait(
    in projectId: String,
    environment: String,
    key: String,
    expectedValue: String,
    newValue: String
  ) async -> Bool {
    guard isUnlocked,
      selectedProjectId == projectId,
      let project = selectedProject
    else { return false }
    return await withCheckedContinuation { continuation in
      enqueueProjectMutation(
        base: project,
        mutation: .updateSecret(
          environment: environment,
          key: key,
          expectedValue: expectedValue,
          replacement: newValue
        ),
        afterCompletion: { succeeded in
          continuation.resume(returning: succeeded)
        }
      )
    }
  }

  func deleteSecret(from projectId: String, key: String) {
    deleteSecret(from: projectId, environment: selectedEnvironment, key: key)
  }

  func deleteSecret(from projectId: String, environment: String, key: String) {
    guard isUnlocked,
      selectedProjectId == projectId,
      let project = selectedProject,
      let expectedValue = project.environments[environment]?[key]
    else { return }
    enqueueProjectMutation(
      base: project,
      mutation: .deleteSecret(
        environment: environment,
        key: key,
        expectedValue: expectedValue
      )
    )
  }

  // MARK: - Token Operations

  func loadAccount() async {
    await loadIdentity(includeTokenInventory: false)
  }

  func loadTokens() async {
    await loadIdentity(includeTokenInventory: true)
  }

  private func loadIdentity(includeTokenInventory: Bool) async {
    tokenLoadGeneration &+= 1
    let generation = tokenLoadGeneration
    let environment = appEnvironment
    let service = apiService(for: environment)
    tokenLoadTask?.cancel()
    isLoadingTokens = true

    let task = Task { [weak self] in
      guard let self else { return }
      let authResolution = await self.resolveAuthToken(
        environment.registryURL,
        environment.baseURL
      )
      guard let authToken = authResolution.token else {
        guard !Task.isCancelled,
          generation == self.tokenLoadGeneration,
          environment == self.appEnvironment
        else { return }
        if authResolution.disposition.definitivelyInvalidated {
          self.clearAuthDependentState(message: authResolution.failure)
          self.isLoadingTokens = false
          self.tokenLoadTask = nil
          return
        }
        if let failure = authResolution.failure {
          self.error = failure
          self.isLoadingTokens = false
          self.tokenLoadTask = nil
          return
        }
        if authResolution.disposition == .absent {
          self.clearAuthDependentState(message: nil)
        }
        self.isLoadingTokens = false
        self.tokenLoadTask = nil
        return
      }
      guard !Task.isCancelled else { return }
      if self.authTokenProvider == nil, self.currentUser != nil,
        self.currentIdentityAuthorityGeneration != authResolution.authorityGeneration
          || authResolution.authorityGeneration.map(self.authAuthorityValidator) != true
      {
        guard generation == self.tokenLoadGeneration,
          environment == self.appEnvironment
        else { return }
        self.clearAuthDependentState(
          message: "The active lpm.dev account changed. Reload account data for the new account."
        )
        self.isLoadingTokens = false
        self.tokenLoadTask = nil
        return
      }

      let userResult = await service.fetchCurrentUser(authToken: authToken)
      let inventoryResult: LPMAPIResult<TokenInventory>
      switch userResult {
      case .success(let user) where user.hasValidRoutingIdentity:
        if includeTokenInventory {
          inventoryResult = await TokenInventoryLoader.load(
            user: user, authToken: authToken, service: service)
        } else {
          inventoryResult = .success(
            TokenInventory(
              user: user,
              personalTokens: [],
              organizationTokens: [:]
            ))
        }
      case .success:
        inventoryResult = .failure(.invalidResponse)
      case .failure(let loadError):
        inventoryResult = .failure(loadError)
      }

      guard !Task.isCancelled,
        generation == self.tokenLoadGeneration,
        environment == self.appEnvironment
      else { return }
      if let authorityGeneration = authResolution.authorityGeneration {
        guard self.authAuthorityValidator(authorityGeneration) else {
          self.clearAuthDependentState(
            message: "The active lpm.dev session changed while tokens were loading."
          )
          self.isLoadingTokens = false
          self.tokenLoadTask = nil
          return
        }
      } else {
        let currentAuthResolution = await self.resolveAuthToken(
          environment.registryURL,
          environment.baseURL
        )
        guard !Task.isCancelled,
          generation == self.tokenLoadGeneration,
          environment == self.appEnvironment
        else { return }
        let authorityChanged =
          currentAuthResolution.token != nil
          && currentAuthResolution.token != authToken
        if currentAuthResolution.disposition.definitivelyInvalidated || authorityChanged {
          self.clearAuthDependentState(
            message: currentAuthResolution.failure
              ?? "The active lpm.dev session changed while tokens were loading."
          )
          self.isLoadingTokens = false
          self.tokenLoadTask = nil
          return
        }
        guard currentAuthResolution.token == authToken else {
          self.error =
            currentAuthResolution.failure
            ?? "The active lpm.dev session changed while tokens were loading. Reload to use the new session."
          self.isLoadingTokens = false
          self.tokenLoadTask = nil
          return
        }
      }

      switch inventoryResult {
      case .success(let inventory):
        self.currentUser = inventory.user
        self.currentIdentityAuthorityGeneration = authResolution.authorityGeneration
        self.personalTokens = inventory.personalTokens
        self.orgTokens = inventory.organizationTokens
        self.error = nil
      case .failure(.cancelled):
        break
      case .failure(.unauthorized):
        self.clearAuthDependentState(
          message: LPMAPIError.unauthorized.localizedDescription
        )
      case .failure(let loadError):
        // Keep the prior coherent inventory visible on transient or
        // per-organization failure; never publish a partial snapshot.
        self.error = loadError.localizedDescription
      }
      self.isLoadingTokens = false
      self.tokenLoadTask = nil
    }
    tokenLoadTask = task
    await task.value
  }

  private func clearAuthDependentState(message: String?) {
    let hasStateToInvalidate =
      currentUser != nil
      || currentIdentityAuthorityGeneration != nil
      || !personalTokens.isEmpty
      || !orgTokens.isEmpty
      || selectedAccount != .personal
      || lastSyncStatus != nil
      || isSyncing
      || isLoggingIn
      || tokenLoadTask != nil
      || pendingOrgPush != nil
    if hasStateToInvalidate {
      authOperationGeneration &+= 1
      syncOperationGeneration &+= 1
    }
    isSyncing = false
    isLoggingIn = false
    invalidateTokenLoad()
    invalidatePendingOrgPush()
    currentUser = nil
    currentIdentityAuthorityGeneration = nil
    personalTokens = []
    orgTokens = [:]
    lastSyncStatus = nil
    selectedAccount = .personal
    reconcileNavigationState()
    error = message
  }

  private func rejectMissingAccountAuthorization(
    _ resolution: AuthTokenResolution,
    fallback: String
  ) {
    let message = resolution.failure ?? fallback
    if resolution.disposition.definitivelyInvalidated {
      clearAuthDependentState(message: message)
    } else {
      error = message
    }
  }

  private func rejectDefinitiveAccountAuthorizationIfCurrent(
    _ resolution: AuthTokenResolution,
    authGeneration: Int,
    sessionGeneration: Int,
    environment: AppEnvironment,
    fallback: String
  ) -> Bool {
    guard resolution.disposition.definitivelyInvalidated else { return false }
    guard authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      environment == appEnvironment
    else { return true }
    rejectMissingAccountAuthorization(resolution, fallback: fallback)
    return true
  }

  private func acceptAccountAuthorization(
    _ resolution: AuthTokenResolution,
    failureMessage: String
  ) -> Bool {
    guard authTokenProvider == nil else { return true }
    guard currentUser != nil,
      let identityGeneration = currentIdentityAuthorityGeneration,
      resolution.authorityGeneration == identityGeneration,
      authAuthorityValidator(identityGeneration)
    else {
      clearAuthDependentState(message: failureMessage)
      return false
    }
    return true
  }

  private func acceptCompletedAccountMutation(
    _ resolution: AuthTokenResolution,
    expectedToken: String,
    expectedAuthority: AuthSessionAuthorityGeneration?,
    failureMessage: String
  ) -> Bool {
    if resolution.disposition.definitivelyInvalidated {
      clearAuthDependentState(message: resolution.failure ?? failureMessage)
      return false
    }
    if authTokenProvider == nil,
      let expectedAuthority,
      resolution.authorityGeneration != expectedAuthority
        || currentIdentityAuthorityGeneration != expectedAuthority
        || !authAuthorityValidator(expectedAuthority)
    {
      clearAuthDependentState(message: failureMessage)
      return false
    }
    guard resolution.token == expectedToken else {
      if resolution.disposition == .authorized {
        clearAuthDependentState(message: failureMessage)
      } else {
        error = resolution.failure ?? failureMessage
      }
      return false
    }
    return true
  }

  private func executeAuthorizedRemoteMutation<Value: Sendable>(
    authority: AuthSessionAuthorityGeneration?,
    start: @escaping @Sendable () -> StartedRemoteOperation<Value>
  ) async throws -> Value? {
    guard let authority else { return await start().value() }
    let result = try await authorizedRemoteMutationExecutor(authority) {
      AuthorizedMutationBox(value: start())
    }
    guard let request = result as? AuthorizedMutationBox<StartedRemoteOperation<Value>>
    else { return nil }
    return await request.value.value()
  }

  private func executeAuthorizedRemoteMutation<Value: Sendable>(
    authority: AuthSessionAuthorityGeneration?,
    prepared: PreparedRemoteOperation<Value>
  ) async throws -> Value? {
    guard let authority else { return await prepared.start().value() }
    let result = try await authorizedRemoteMutationExecutor(authority) {
      AuthorizedMutationBox(value: prepared.start())
    }
    guard let request = result as? AuthorizedMutationBox<StartedRemoteOperation<Value>>
    else { return nil }
    return await request.value.value()
  }

  func revokePersonalToken(_ token: LPMToken) async {
    let generation = authOperationGeneration
    let environment = appEnvironment
    let authResolution = await resolveAuthToken(environment.registryURL, environment.baseURL)
    guard generation == authOperationGeneration, environment == appEnvironment else { return }
    guard let authToken = authResolution.token else {
      rejectMissingAccountAuthorization(
        authResolution,
        fallback: "Sign in to lpm.dev, then retry."
      )
      return
    }
    guard
      acceptAccountAuthorization(
        authResolution,
        failureMessage: "The active lpm.dev account changed. Reload tokens before revoking one."
      )
    else { return }
    let result: LPMAPIResult<Void>
    do {
      guard
        let executed = try await executeAuthorizedRemoteMutation(
          authority: authResolution.authorityGeneration,
          start: { [apiService = apiService(for: environment)] in
            apiService.startRevokePersonalToken(id: token.id, authToken: authToken)
          }
        )
      else {
        guard generation == authOperationGeneration,
          environment == appEnvironment
        else { return }
        clearAuthDependentState(
          message: "The active lpm.dev session changed before revocation started."
        )
        return
      }
      result = executed
    } catch {
      guard generation == authOperationGeneration, environment == appEnvironment else { return }
      self.error = error.localizedDescription
      return
    }
    guard generation == authOperationGeneration, environment == appEnvironment else { return }
    let currentAuthResolution: AuthTokenResolution
    if authResolution.authorityGeneration != nil {
      currentAuthResolution = authResolution
    } else {
      currentAuthResolution = await resolveAuthToken(
        environment.registryURL,
        environment.baseURL
      )
    }
    guard generation == authOperationGeneration, environment == appEnvironment else { return }
    guard
      acceptCompletedAccountMutation(
        currentAuthResolution,
        expectedToken: authToken,
        expectedAuthority: authResolution.authorityGeneration,
        failureMessage:
          "The active lpm.dev session changed before revocation completed. Reload and retry."
      )
    else { return }
    switch result {
    case .success:
      // A load that started before the revocation may still contain this
      // token. Invalidate it before committing the newer server state.
      invalidateTokenLoad()
      personalTokens.removeAll { $0.id == token.id }
    case .failure(.unauthorized):
      clearAuthDependentState(message: LPMAPIError.unauthorized.localizedDescription)
    case .failure(let revokeError):
      error = revokeError.localizedDescription
    }
  }

  func revokeOrgToken(_ token: LPMToken, orgSlug: String) async {
    let generation = authOperationGeneration
    let environment = appEnvironment
    let authResolution = await resolveAuthToken(environment.registryURL, environment.baseURL)
    guard generation == authOperationGeneration, environment == appEnvironment else { return }
    guard let authToken = authResolution.token else {
      rejectMissingAccountAuthorization(
        authResolution,
        fallback: "Sign in to lpm.dev, then retry."
      )
      return
    }
    guard
      acceptAccountAuthorization(
        authResolution,
        failureMessage: "The active lpm.dev account changed. Reload tokens before revoking one."
      )
    else { return }
    let result: LPMAPIResult<Void>
    do {
      guard
        let executed = try await executeAuthorizedRemoteMutation(
          authority: authResolution.authorityGeneration,
          start: { [apiService = apiService(for: environment)] in
            apiService.startRevokeOrgToken(
              orgSlug: orgSlug,
              id: token.id,
              authToken: authToken
            )
          }
        )
      else {
        guard generation == authOperationGeneration,
          environment == appEnvironment
        else { return }
        clearAuthDependentState(
          message: "The active lpm.dev session changed before revocation started."
        )
        return
      }
      result = executed
    } catch {
      guard generation == authOperationGeneration, environment == appEnvironment else { return }
      self.error = error.localizedDescription
      return
    }
    guard generation == authOperationGeneration, environment == appEnvironment else { return }
    let currentAuthResolution: AuthTokenResolution
    if authResolution.authorityGeneration != nil {
      currentAuthResolution = authResolution
    } else {
      currentAuthResolution = await resolveAuthToken(
        environment.registryURL,
        environment.baseURL
      )
    }
    guard generation == authOperationGeneration, environment == appEnvironment else { return }
    guard
      acceptCompletedAccountMutation(
        currentAuthResolution,
        expectedToken: authToken,
        expectedAuthority: authResolution.authorityGeneration,
        failureMessage:
          "The active lpm.dev session changed before revocation completed. Reload and retry."
      )
    else { return }
    switch result {
    case .success:
      invalidateTokenLoad()
      orgTokens[orgSlug]?.removeAll { $0.id == token.id }
    case .failure(.unauthorized):
      clearAuthDependentState(message: LPMAPIError.unauthorized.localizedDescription)
    case .failure(let revokeError):
      error = revokeError.localizedDescription
    }
  }

  // MARK: - Auth (Login / Logout)

  /// Start the browser-based login flow — same UX as `lpm login`.
  /// Validates the token with the server before persisting it to Keychain.
  @discardableResult
  func login() async -> Bool {
    guard !isLoggingIn else { return false }
    authOperationGeneration &+= 1
    invalidateTokenLoad()
    let generation = authOperationGeneration
    let environment = appEnvironment
    isLoggingIn = true
    error = nil

    do {
      let credentials = try await loginProvider(environment.registryURL, environment.baseURL)
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return false
      }

      // Validate the token actually works before storing it
      let user = await apiService(for: environment).fetchCurrentUser(
        authToken: credentials.token)
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return false
      }
      guard case .success(let authenticatedUser) = user else {
        error = "Login failed — server rejected the token."
        isLoggingIn = false
        return false
      }

      // Token is valid — persist to Keychain (shared with CLI)
      try await authSessionMutationQueue.run { [authSessionWriter] in
        try await authSessionWriter(credentials, environment.registryURL)
      }
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return false
      }
      let storedAuthorization = await resolveAuthToken(
        environment.registryURL,
        environment.baseURL
      )
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return false
      }
      guard storedAuthorization.token == credentials.token,
        authTokenProvider != nil || storedAuthorization.authorityGeneration != nil
      else {
        clearAuthDependentState(
          message: "Login succeeded, but the stored lpm.dev session could not be verified."
        )
        isLoggingIn = false
        return false
      }

      guard generation == authOperationGeneration, environment == appEnvironment else {
        return false
      }
      authOperationGeneration &+= 1
      invalidateTokenLoad()
      currentUser = authenticatedUser
      currentIdentityAuthorityGeneration = storedAuthorization.authorityGeneration
      personalTokens = []
      orgTokens = [:]
      error = nil
      isLoggingIn = false
      return true
    } catch {
      let failureMessage = error.localizedDescription
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return false
      }
      let currentAuthorization = await resolveAuthToken(
        environment.registryURL,
        environment.baseURL
      )
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return false
      }
      let identityAuthorityInvalidated =
        authTokenProvider == nil && currentUser != nil
        && (currentIdentityAuthorityGeneration == nil
          || currentAuthorization.authorityGeneration
            != currentIdentityAuthorityGeneration
          || currentIdentityAuthorityGeneration.map(authAuthorityValidator) != true)
      if currentAuthorization.disposition.definitivelyInvalidated
        || identityAuthorityInvalidated
      {
        clearAuthDependentState(message: failureMessage)
        return false
      }
      self.error = failureMessage
      isLoggingIn = false
      return false
    }
  }

  /// Sign out — clear token from Keychain and reset state.
  func logout() async {
    authOperationGeneration &+= 1
    let generation = authOperationGeneration
    let environment = appEnvironment
    isLoggingIn = false
    invalidateTokenLoad()
    invalidatePendingOrgPush()
    do {
      try await authSessionMutationQueue.run { [authSessionClearer] in
        try await authSessionClearer(environment.registryURL)
      }
    } catch AuthSessionCoordinatorError.sessionRevokedWithCleanupFailure(let message) {
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return
      }
      currentUser = nil
      currentIdentityAuthorityGeneration = nil
      personalTokens = []
      orgTokens = [:]
      lastSyncStatus = nil
      self.error = "The shared LPM session was cleared, but cleanup failed. \(message)"
      return
    } catch {
      guard generation == authOperationGeneration, environment == appEnvironment else {
        return
      }
      self.error = "Could not clear the shared LPM session. \(error.localizedDescription)"
      return
    }
    guard generation == authOperationGeneration, environment == appEnvironment else { return }
    currentUser = nil
    currentIdentityAuthorityGeneration = nil
    personalTokens = []
    orgTokens = [:]
    error = nil
    lastSyncStatus = nil
  }

  // MARK: - Auth (Biometric)

  func unlock() async {
    guard !isUnlocking else { return }
    unlockGeneration &+= 1
    let generation = unlockGeneration
    isUnlocking = true
    let success = await biometricService.authenticate(
      reason: "Unlock LPM Vault to view secrets"
    )
    guard generation == unlockGeneration else { return }
    guard success else {
      isUnlocking = false
      return
    }
    guard generation == unlockGeneration else { return }
    await waitForProjectMutations()
    guard generation == unlockGeneration else { return }
    // Do not expose the unlocked UI until the latest snapshot is present.
    let loaded = await loadProjects()
    guard generation == unlockGeneration else { return }
    guard loaded else {
      isUnlocking = false
      return
    }
    isUnlocked = true
    beginSelectedProjectLoadIfNeeded()
    isUnlocking = false
    scheduleAutoLock()
  }

  func authenticateForSensitiveAction(reason: String) async -> Bool {
    guard isUnlocked else { return false }
    let sessionGeneration = vaultSessionGeneration
    let success = await biometricService.authenticate(reason: reason)
    return !Task.isCancelled
      && success
      && isUnlocked
      && sessionGeneration == vaultSessionGeneration
  }

  func exportEnvironment(
    projectId: String,
    environment: String,
    to destination: URL
  ) async throws {
    guard isUnlocked,
      selectedProjectId == projectId,
      selectedEnvironment == environment,
      let project = selectedProject
    else { throw CancellationError() }
    let requestId = UUID()
    let authorization = EnvFileExportAuthorization()
    let secrets = project.secrets(for: environment)
    let task = Task { [envFileExportService] in
      try await envFileExportService.export(
        secrets: secrets,
        to: destination,
        authorization: authorization
      )
    }
    exportAuthorizations[requestId] = authorization
    exportTasks[requestId] = task
    defer {
      exportAuthorizations.removeValue(forKey: requestId)
      exportTasks.removeValue(forKey: requestId)
    }

    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      authorization.invalidate()
      task.cancel()
    }
  }

  private func cancelExports() {
    for authorization in exportAuthorizations.values { authorization.invalidate() }
    for task in exportTasks.values { task.cancel() }
    exportAuthorizations.removeAll(keepingCapacity: true)
    exportTasks.removeAll(keepingCapacity: true)
  }

  func lock() {
    unlockGeneration &+= 1
    vaultSessionGeneration &+= 1
    cancelExports()
    cancelLocalEnvImports()
    cancelLocalEnvPreviews()
    invalidatePendingOrgPush()
    isUnlocking = false
    invalidateProjectLoad()
    invalidateSelectedProjectLoad()
    autoLockTask?.cancel()
    autoLockTask = nil
    autoLockDeadline = nil
    autoLockTaskGeneration &+= 1
    isUnlocked = false
    biometricService.resetCache()
    ClipboardManager.shared.clearClipboard()
    projects = projects.map { VaultProject(metadata: $0.metadata) }
    workspaceSnapshots = [:]
  }

  /// Records local keyboard, click, scroll, or gesture input while unlocked.
  func recordUserActivity() {
    guard isUnlocked else { return }
    scheduleAutoLock()
  }

  /// Navigation actions are user activity too.
  private func resetAutoLock() {
    recordUserActivity()
  }

  private func scheduleAutoLock() {
    let now = autoLockNow()
    if let autoLockDeadline, now >= autoLockDeadline {
      lock()
      return
    }
    autoLockDeadline = now + autoLockDuration
    guard autoLockTask == nil else { return }
    autoLockTaskGeneration &+= 1
    let generation = autoLockTaskGeneration
    autoLockTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        while isUnlocked, generation == autoLockTaskGeneration {
          try Task.checkCancellation()
          guard let autoLockDeadline else { break }
          let remaining = autoLockDeadline - autoLockNow()
          if remaining <= 0 {
            lock()
            return
          }
          try await autoLockSleep(.seconds(remaining))
        }
      } catch {}
      if generation == autoLockTaskGeneration {
        autoLockTask = nil
      }
    }
  }

  private func invalidatePendingOrgPush() {
    syncOperationGeneration &+= 1
    pendingOrgPush = nil
    showKeyApprovalSheet = false
    if lastSyncStatus == "approval_required" { lastSyncStatus = nil }
    isSyncing = false
  }

  private func invalidatePendingOrgPush(matching id: UUID) {
    guard pendingOrgPush?.id == id else { return }
    invalidatePendingOrgPush()
  }

  private func invalidateProjectLoad() {
    projectLoadGeneration &+= 1
    projectLoadTask?.cancel()
    projectLoadTask = nil
    isLoadingProjects = false
  }

  private func invalidateTokenLoad() {
    tokenLoadGeneration &+= 1
    tokenLoadTask?.cancel()
    tokenLoadTask = nil
    isLoadingTokens = false
  }

  // MARK: - Cloud Sync

  /// Info shown in the push/pull confirmation dialog.
  struct SyncConfirmation {
    let action: String  // "push" or "pull"
    let projectName: String
    let localKeyCount: Int
    let cloudVersion: Int?
  }

  /// Prepare info for push confirmation. Returns nil if no project selected.
  func preparePushConfirmation() -> SyncConfirmation? {
    guard let project = selectedProject else { return nil }
    return SyncConfirmation(
      action: "push",
      projectName: project.name,
      localKeyCount: project.secretCount,
      cloudVersion: nil
    )
  }

  /// Push the selected project's secrets to cloud.
  /// Pushes ALL environments (default, live, local, etc.), not just the selected one.
  func pushToCloud(force: Bool = false) async {
    guard isUnlocked, selectedAccount == .personal, let project = selectedProject else {
      return
    }
    syncOperationGeneration &+= 1
    let operationGeneration = syncOperationGeneration
    let sessionGeneration = vaultSessionGeneration
    let environment = appEnvironment
    let authGeneration = authOperationGeneration
    let authResolution = await resolveAuthToken(environment.registryURL, environment.baseURL)
    guard let authToken = authResolution.token else {
      let fallback = "Not logged in. Run `lpm login` in terminal first."
      if rejectDefinitiveAccountAuthorizationIfCurrent(
        authResolution,
        authGeneration: authGeneration,
        sessionGeneration: sessionGeneration,
        environment: environment,
        fallback: fallback
      ) {
        return
      }
      guard operationGeneration == syncOperationGeneration,
        environment == appEnvironment,
        authGeneration == authOperationGeneration,
        sessionGeneration == vaultSessionGeneration,
        isUnlocked,
        selectedAccount == .personal,
        selectedProject?.id == project.id
      else { return }
      rejectMissingAccountAuthorization(
        authResolution,
        fallback: fallback
      )
      return
    }
    guard operationGeneration == syncOperationGeneration,
      environment == appEnvironment,
      authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      isUnlocked,
      selectedAccount == .personal,
      selectedProject?.id == project.id
    else { return }
    guard
      acceptAccountAuthorization(
        authResolution,
        failureMessage: "The active lpm.dev account changed. Reload account data before syncing."
      ), let principalID = syncPrincipalID(for: .personal)
    else { return }
    let authority = SyncAuthority(
      projectId: project.id,
      account: .personal,
      environment: environment,
      authGeneration: authGeneration,
      sessionGeneration: sessionGeneration,
      operationGeneration: operationGeneration,
      authToken: authToken,
      principalID: principalID,
      authorityGeneration: authResolution.authorityGeneration
    )
    guard isCurrentSync(authority) else { return }

    isSyncing = true
    lastSyncStatus = nil
    await waitForProjectMutations()
    let binding = syncBinding(for: authority)
    guard await hasCurrentSyncAuth(authority),
      let pushSnapshot = await persistence.syncSnapshot(
        vaultId: project.id,
        binding: binding
      )
    else {
      finishSyncIfOwned(authority)
      return
    }
    guard !rejectPrincipalBindingConflict(pushSnapshot, authority: authority) else {
      return
    }
    let pushedProject = pushSnapshot.project

    let syncService = personalSyncServiceFactory(environment.baseURL)
    let localExpectedVersion = pushSnapshot.metadata?.lastVersion
    let attemptLimit = force ? 3 : 1
    let nonEmptyEnvs = pushedProject.environments.filter { !$0.value.isEmpty }
    let encryptor = stableSyncEncryptor
    let projectID = pushedProject.id
    var plaintext: Data?
    var schema: LPMJSONValue?
    var preparedPayload = false
    var forcedRecreationFloor = localExpectedVersion
    do {
      for attempt in 0..<attemptLimit {
        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return
        }
        let expectedVersion: Int?
        let recreateMissing: Bool
        if force {
          let preflightResponse = await syncService.versionPreflightAuthenticated(
            authToken: authToken,
            vaultId: pushedProject.id
          )
          switch preflightResponse {
          case .response(.found(let preflight)):
            guard
              let serverVersion = Self.acceptedPushVersion(
                preflight,
                vaultId: pushedProject.id
              ), preflight.principalId == authority.principalID
            else {
              error = "Could not authenticate the current cloud revision before pushing."
              lastSyncStatus = "failed"
              finishSyncIfOwned(authority)
              return
            }
            let authenticatedFloor = max(
              localExpectedVersion ?? 0,
              forcedRecreationFloor ?? 0
            )
            if serverVersion < authenticatedFloor {
              error =
                "The cloud env project revision is older than this checkout's authenticated checkpoint."
              lastSyncStatus = "failed"
              finishSyncIfOwned(authority)
              return
            }
            expectedVersion = serverVersion
            recreateMissing = false
          case .response(.notFound):
            expectedVersion = forcedRecreationFloor
            recreateMissing = expectedVersion != nil
          case .response(nil):
            error = "Could not authenticate the current cloud revision before pushing."
            lastSyncStatus = "failed"
            finishSyncIfOwned(authority)
            return
          case .unauthorized:
            rejectUnauthorizedSyncResponseIfCurrent(
              authority,
              message: "Your lpm.dev session expired. Sign in again."
            )
            return
          }
        } else {
          expectedVersion = localExpectedVersion
          recreateMissing = false
        }
        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return
        }

        if !preparedPayload {
          let serializationTask = Task.detached(priority: .userInitiated) {
            try JSONEncoder().encode(["environments": nonEmptyEnvs])
          }
          plaintext = try await serializationTask.value
          guard await hasCurrentSyncAuth(authority) else {
            finishSyncIfOwned(authority)
            return
          }
          schema = await syncSchema(for: pushedProject)
          preparedPayload = true
        }
        guard let plaintext else {
          throw VaultSyncError("Could not serialize the env project for sync.")
        }
        let targetRevision = try Self.nextSyncRevision(after: expectedVersion)
        let encryptionTask = Task.detached(priority: .userInitiated) {
          try encryptor(
            plaintext,
            authority.principalID,
            projectID,
            targetRevision
          )
        }
        let encrypted = try await encryptionTask.value
        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return
        }

        let preparedPush = await syncService.preparePushAuthenticated(
          authToken: authToken,
          expectedPrincipalId: authority.principalID,
          vaultId: pushedProject.id,
          encryptedBlob: encrypted.encryptedBlob,
          wrappedKey: encrypted.wrappedKey,
          expectedVersion: expectedVersion,
          force: force,
          recreateMissing: recreateMissing,
          name: pushedProject.name,
          schema: schema
        )
        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return
        }
        guard
          let response = try await executeAuthorizedRemoteMutation(
            authority: authority.authorityGeneration,
            prepared: preparedPush
          )
        else {
          _ = await hasCurrentSyncAuth(authority)
          finishSyncIfOwned(authority)
          return
        }
        let result: SyncService.SyncStatus?
        switch response {
        case .response(let value): result = value
        case .unauthorized:
          rejectUnauthorizedSyncResponseIfCurrent(
            authority,
            message: "Your lpm.dev session expired. Sign in again."
          )
          return
        }

        if let pushedVersion = Self.acceptedPushVersion(
          result,
          vaultId: pushedProject.id,
          greaterThan: expectedVersion ?? 0
        ), pushedVersion == targetRevision,
          result?.principalId == authority.principalID
        {
          guard await hasCurrentDurableSyncAuth(authority) else {
            finishSyncIfOwned(authority)
            return
          }
          await waitForProjectMutations()
          guard canBeginDurableSyncCommit(authority) else {
            finishSyncIfOwned(authority)
            return
          }
          let persistedCommit = await persistence.finishPush(
            pushedProject: pushedProject,
            action: "push",
            version: pushedVersion,
            binding: binding
          )
          let ownsPresentation = await hasCurrentSyncAuth(authority)
          guard canPublishDurableSyncCommit(authority) else {
            finishSyncIfOwned(authority)
            return
          }
          guard let commit = persistedCommit else {
            if ownsPresentation {
              error = "The push succeeded, but local sync state could not be saved."
              lastSyncStatus = "failed"
            }
            finishSyncIfOwned(authority)
            return
          }
          updateProjectInPlace(commit.project)
          applySyncMetadata(commit.syncMetadata, for: commit.project.id)
          if ownsPresentation {
            lastSyncStatus =
              commit.isDirty
              ? "Pushed (v\(pushedVersion)); local changes pending"
              : "Pushed (v\(pushedVersion))"
          }
          finishSyncIfOwned(authority)
          return
        }

        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return
        }
        if force, Self.isRetryablePushConflict(result) {
          if recreateMissing, let serverVersion = result?.serverVersion, serverVersion > 0 {
            forcedRecreationFloor = max(forcedRecreationFloor ?? 0, serverVersion)
          }
          guard attempt + 1 == attemptLimit else { continue }
          error =
            "Force push could not acquire a stable cloud revision after \(attemptLimit) attempts. Retry when concurrent writes stop."
          lastSyncStatus = "conflict"
          finishSyncIfOwned(authority)
          return
        }
        let message: String
        if let result, result.error == nil {
          message = "The push response did not match this env project or contain a valid version."
        } else {
          message = result?.displayError ?? "Push failed"
        }
        if Self.isRetryablePushConflict(result) {
          error =
            Self.personalPushConflictMessage(
              result,
              localExpectedVersion: localExpectedVersion
            ) ?? message
          lastSyncStatus = "conflict"
        } else {
          error = message
          lastSyncStatus = "failed"
        }
        finishSyncIfOwned(authority)
        return
      }
    } catch {
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      self.error = error.localizedDescription
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
    }
  }

  /// Pull secrets from cloud and merge into the selected project.
  @discardableResult
  func pullFromCloud() async -> Bool {
    guard isUnlocked, selectedAccount == .personal, let project = selectedProject else {
      return false
    }
    syncOperationGeneration &+= 1
    let operationGeneration = syncOperationGeneration
    let sessionGeneration = vaultSessionGeneration
    let environment = appEnvironment
    let authGeneration = authOperationGeneration
    let authResolution = await resolveAuthToken(environment.registryURL, environment.baseURL)
    guard let authToken = authResolution.token else {
      let fallback = "Not logged in. Run `lpm login` in terminal first."
      if rejectDefinitiveAccountAuthorizationIfCurrent(
        authResolution,
        authGeneration: authGeneration,
        sessionGeneration: sessionGeneration,
        environment: environment,
        fallback: fallback
      ) {
        return false
      }
      guard operationGeneration == syncOperationGeneration,
        environment == appEnvironment,
        authGeneration == authOperationGeneration,
        sessionGeneration == vaultSessionGeneration
      else { return false }
      rejectMissingAccountAuthorization(
        authResolution,
        fallback: fallback
      )
      return false
    }
    guard operationGeneration == syncOperationGeneration,
      environment == appEnvironment,
      authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      isUnlocked,
      selectedAccount == .personal,
      selectedProject?.id == project.id
    else { return false }
    guard
      acceptAccountAuthorization(
        authResolution,
        failureMessage: "The active lpm.dev account changed. Reload account data before syncing."
      ), let principalID = syncPrincipalID(for: .personal)
    else { return false }
    let authority = SyncAuthority(
      projectId: project.id,
      account: .personal,
      environment: environment,
      authGeneration: authGeneration,
      sessionGeneration: sessionGeneration,
      operationGeneration: operationGeneration,
      authToken: authToken,
      principalID: principalID,
      authorityGeneration: authResolution.authorityGeneration
    )
    guard isCurrentSync(authority) else { return false }

    isSyncing = true
    lastSyncStatus = nil
    await waitForProjectMutations()
    let binding = syncBinding(for: authority)
    guard await hasCurrentSyncAuth(authority),
      let pullSnapshot = await persistence.syncSnapshot(
        vaultId: project.id,
        binding: binding
      )
    else {
      finishSyncIfOwned(authority)
      return false
    }
    guard !rejectPrincipalBindingConflict(pullSnapshot, authority: authority) else {
      return false
    }
    let baselineProject = pullSnapshot.project

    guard await hasCurrentSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return false
    }
    let syncService = personalSyncServiceFactory(environment.baseURL)
    let response = await syncService.pullAuthenticated(
      authToken: authToken,
      vaultId: baselineProject.id
    )
    let result: SyncService.SyncStatus?
    switch response {
    case .response(let value): result = value
    case .unauthorized:
      rejectUnauthorizedSyncResponseIfCurrent(
        authority,
        message: "Your lpm.dev session expired. Sign in again."
      )
      return false
    }
    guard await hasCurrentSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return false
    }
    guard let result else {
      error = "Pull failed — no response from server"
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
      return false
    }
    guard result.vaultId == baselineProject.id,
      result.principalId == authority.principalID,
      let version = result.version,
      version > 0
    else {
      error = "The pull response did not match this env project or contain a valid version."
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
      return false
    }

    guard let blob = result.encryptedBlob, let wrapped = result.wrappedKey else {
      error = result.error ?? "No env project data on cloud. Push first."
      finishSyncIfOwned(authority)
      lastSyncStatus = "empty"
      return false
    }
    guard let cryptoVersion = result.cryptoVersion,
      cryptoVersion == VaultCrypto.currentCryptoVersion
    else {
      error = "The cloud response uses an unsupported encryption version."
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
      return false
    }

    do {
      // Replay protection: reject version downgrades
      if let localVersion = pullSnapshot.metadata?.lastVersion,
        version < localVersion
      {
        error =
          "Version downgrade rejected (local: v\(localVersion), server: v\(version))"
        finishSyncIfOwned(authority)
        lastSyncStatus = "failed"
        return false
      }

      let decryptArguments = (
        blob: blob,
        wrapped: wrapped,
        vaultID: baselineProject.id
      )
      let decryptor = stableSyncDecryptor
      let jsonData = try await Task.detached(priority: .userInitiated) {
        try decryptor(
          decryptArguments.blob,
          decryptArguments.wrapped,
          authority.principalID,
          decryptArguments.vaultID,
          version,
          cryptoVersion
        )
      }.value
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return false
      }
      await waitForProjectMutations()
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return false
      }
      guard
        let commit = try await commitPull(
          authority: authority,
          baseline: baselineProject,
          remotePayload: jsonData,
          action: "pull",
          version: version
        )
      else {
        _ = await hasCurrentSyncAuth(authority)
        finishSyncIfOwned(authority)
        return false
      }
      let ownsPresentation = await hasCurrentSyncAuth(authority)
      guard canPublishDurableSyncCommit(authority) else {
        finishSyncIfOwned(authority)
        return false
      }
      let committedSuccessfully: Bool
      switch commit {
      case .success(let persisted):
        updateProjectInPlace(persisted.project)
        applySyncMetadata(persisted.syncMetadata, for: persisted.project.id)
        if ownsPresentation {
          error = persisted.warning
          let keyCount = Self.keyCountDescription(persisted.keyCount)
          lastSyncStatus =
            persisted.isDirty
            ? "Pulled (v\(version), \(keyCount)); local changes pending"
            : "Pulled (v\(version), \(keyCount))"
        }
        committedSuccessfully = true
      case .conflict(let latest, let metadata):
        updateProjectInPlace(latest)
        applySyncMetadata(metadata, for: latest.id)
        if ownsPresentation {
          error = "Local values changed while the pull was running. Review them and retry."
          lastSyncStatus = "conflict"
        }
        committedSuccessfully = false
      case .staleVersion(let latest, let metadata):
        updateProjectInPlace(latest)
        applySyncMetadata(metadata, for: latest.id)
        if ownsPresentation {
          error = "A newer sync completed while this pull was running. Reload and retry."
          lastSyncStatus = "failed"
        }
        committedSuccessfully = false
      case .targetUnavailable:
        if ownsPresentation {
          error = "The target env project changed while the pull was running."
          lastSyncStatus = "failed"
        }
        committedSuccessfully = false
      case .invalidPayload(let message):
        if ownsPresentation {
          error = message
          lastSyncStatus = "failed"
        }
        committedSuccessfully = false
      case .cancelled:
        committedSuccessfully = false
      case .failure(let persistenceError):
        if ownsPresentation {
          error = persistenceError.description
          lastSyncStatus = "failed"
        }
        committedSuccessfully = false
      }
      finishSyncIfOwned(authority)
      return committedSuccessfully
    } catch {
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return false
      }
      self.error = "Decryption failed: \(error.localizedDescription)"
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
      return false
    }
  }

  // MARK: - Org Sync

  /// Share (push) the selected project's vault with an org.
  /// If any member keys are new or changed, the push is blocked and
  /// `showKeyApprovalSheet` is set — the user must approve before continuing.
  @discardableResult
  func pushToOrg(orgSlug: String) async -> VaultCreationResult {
    guard isUnlocked, selectedAccount == .org(orgSlug), let project = selectedProject else {
      return .failed
    }
    syncOperationGeneration &+= 1
    let operationGeneration = syncOperationGeneration
    let environment = appEnvironment
    let authGeneration = authOperationGeneration
    let sessionGeneration = vaultSessionGeneration
    let authResolution = await resolveAuthToken(environment.registryURL, environment.baseURL)
    guard let authToken = authResolution.token else {
      let fallback = "Not logged in."
      if rejectDefinitiveAccountAuthorizationIfCurrent(
        authResolution,
        authGeneration: authGeneration,
        sessionGeneration: sessionGeneration,
        environment: environment,
        fallback: fallback
      ) {
        return .failed
      }
      guard operationGeneration == syncOperationGeneration,
        environment == appEnvironment,
        authGeneration == authOperationGeneration,
        sessionGeneration == vaultSessionGeneration
      else { return .failed }
      rejectMissingAccountAuthorization(
        authResolution,
        fallback: fallback
      )
      return .failed
    }
    guard operationGeneration == syncOperationGeneration,
      environment == appEnvironment,
      authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      isUnlocked,
      selectedAccount == .org(orgSlug),
      selectedProject?.id == project.id
    else { return .failed }
    guard
      acceptAccountAuthorization(
        authResolution,
        failureMessage: "The active lpm.dev account changed. Reload account data before syncing."
      ), let principalID = syncPrincipalID(for: .org(orgSlug))
    else { return .failed }
    let authority = SyncAuthority(
      projectId: project.id,
      account: .org(orgSlug),
      environment: environment,
      authGeneration: authGeneration,
      sessionGeneration: sessionGeneration,
      operationGeneration: operationGeneration,
      authToken: authToken,
      principalID: principalID,
      authorityGeneration: authResolution.authorityGeneration
    )
    guard isCurrentSync(authority), let currentUserId = currentUser?.id else { return .failed }

    isSyncing = true
    lastSyncStatus = nil

    do {
      let syncService = orgSyncServiceFactory(environment.baseURL)
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }

      guard
        case .response(let memberAccess) =
          await syncService
          .getOrgMemberKeyAccessAuthenticated(
            authToken: authToken,
            expectedCallerUserID: currentUserId,
            orgSlug: orgSlug
          )
      else {
        rejectUnauthorizedSyncResponseIfCurrent(
          authority,
          message: "Your lpm.dev session expired. Sign in again."
        )
        return .failed
      }
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      guard let memberAccess else {
        throw VaultSyncError("Could not fetch organization member keys.")
      }
      guard memberAccess.organizationID == authority.principalID else {
        throw VaultSyncError("The organization identity returned by lpm.dev changed.")
      }
      guard memberAccess.callerUserID == currentUserId else {
        throw VaultSyncError(
          "The authenticated account changed while organization access was loading.")
      }
      guard
        let trustScope = OrgTrustScope(
          registryURL: environment.registryURL,
          organizationID: memberAccess.organizationID,
          organizationSlug: orgSlug
        )
      else {
        throw VaultSyncError("The organization identity returned by lpm.dev is invalid.")
      }

      // 2b. Strict key verification — block on new or changed keys
      let orgTrust: OrgKeyTrust
      switch await persistence.loadOrgTrust(scope: trustScope) {
      case .success(let loaded): orgTrust = loaded
      case .failure(let trustError):
        throw VaultSyncError(
          "Could not load organization key trust. \(trustError.description)"
        )
      }
      let members = memberAccess.members
      let preparedMembers = try await Task.detached(priority: .userInitiated) {
        try OrganizationMemberAuthorizationPolicy.prepare(members, trust: orgTrust)
      }.value
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      let membersWithKeys = preparedMembers.membersWithKeys
      let pendingApprovals = preparedMembers.pendingApprovals
      guard
        let authenticatedMember = membersWithKeys.first(where: {
          $0.userId == memberAccess.callerUserID
        })
      else {
        throw VaultSyncError(
          "Your sharing key is not registered yet. Run `lpm env share --org` once to complete secure step-up registration, then retry."
        )
      }
      let keypairProvider = sharingKeypairProvider
      let registryURL = environment.registryURL
      let callerUserID = memberAccess.callerUserID
      let expectedPublicKey = authenticatedMember.publicKey
      let expectedFingerprint = authenticatedMember.publicKeyFingerprint
      let (_, pubKey) = try await Task.detached(priority: .userInitiated) {
        try keypairProvider(
          registryURL,
          callerUserID,
          expectedPublicKey,
          expectedFingerprint
        )
      }.value
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      let serverKey = try OrganizationMemberAuthorizationPolicy.currentMemberKey(
        userId: callerUserID,
        localPublicKey: pubKey,
        members: membersWithKeys
      )

      if membersWithKeys.isEmpty {
        error = "No org members have registered public keys yet."
        finishSyncIfOwned(authority)
        lastSyncStatus = "failed"
        return .failed
      }

      // If any keys need approval, block the push and show the approval sheet
      if !pendingApprovals.isEmpty {
        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return .failed
        }
        pendingOrgPush = PendingOrgPush(
          orgSlug: orgSlug,
          projectId: project.id,
          ownPublicKey: serverKey,
          allMembers: membersWithKeys,
          pendingApprovals: pendingApprovals,
          orgTrust: orgTrust,
          trustScope: trustScope,
          authToken: authToken,
          callerUserID: callerUserID,
          canReplaceWrappedKeys: memberAccess.canReplaceWrappedKeys,
          environment: environment,
          authGeneration: authGeneration,
          sessionGeneration: sessionGeneration,
          operationGeneration: operationGeneration,
          authorityGeneration: authResolution.authorityGeneration
        )
        showKeyApprovalSheet = true
        finishSyncIfOwned(authority)
        lastSyncStatus = "approval_required"
        return .approvalRequired
      }

      // All keys are trusted — proceed with push
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      return try await executeOrgPush(
        project: project,
        validatedRecipients: preparedMembers.validatedRecipients,
        syncService: syncService,
        canReplaceWrappedKeys: memberAccess.canReplaceWrappedKeys,
        callerUserID: callerUserID,
        authority: authority
      )
    } catch {
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      self.error = error.localizedDescription
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
      return .failed
    }
  }

  /// Called from KeyApprovalSheet when user accepts all pending keys.
  func approveAndContinueOrgPush(approved: [PendingKeyApproval]) async {
    guard let pending = pendingOrgPush else { return }
    guard
      PendingKeyApproval.exactlyMatches(
        approved,
        pending: pending.pendingApprovals
      )
    else {
      invalidatePendingOrgPush(matching: pending.id)
      error = "The sharing-key approval set changed. Review the organization members and retry."
      lastSyncStatus = "failed"
      return
    }
    guard pending.environment == appEnvironment,
      pending.authGeneration == authOperationGeneration,
      pending.sessionGeneration == vaultSessionGeneration,
      pending.operationGeneration == syncOperationGeneration,
      isUnlocked,
      selectedAccount == .org(pending.orgSlug),
      let project = selectedProject,
      project.id == pending.projectId,
      let currentUserId = currentUser?.id
    else {
      invalidatePendingOrgPush(matching: pending.id)
      return
    }

    syncOperationGeneration &+= 1
    let authority = SyncAuthority(
      projectId: pending.projectId,
      account: .org(pending.orgSlug),
      environment: pending.environment,
      authGeneration: pending.authGeneration,
      sessionGeneration: pending.sessionGeneration,
      operationGeneration: syncOperationGeneration,
      authToken: pending.authToken,
      principalID: pending.trustScope.organizationID,
      authorityGeneration: pending.authorityGeneration
    )
    pendingOrgPush = nil
    showKeyApprovalSheet = false
    isSyncing = true
    lastSyncStatus = nil

    let currentAuthResolution = await resolveAuthToken(
      pending.environment.registryURL,
      pending.environment.baseURL
    )
    if rejectDefinitiveAccountAuthorizationIfCurrent(
      currentAuthResolution,
      authGeneration: pending.authGeneration,
      sessionGeneration: pending.sessionGeneration,
      environment: pending.environment,
      fallback: "Your lpm.dev session is no longer available. Sign in again."
    ) {
      finishSyncIfOwned(authority)
      return
    }
    guard currentAuthResolution.token == pending.authToken,
      currentAuthResolution.authorityGeneration == pending.authorityGeneration,
      isCurrentSync(authority)
    else {
      if currentAuthResolution.disposition == .transientFailure,
        isCurrentSync(authority)
      {
        error = currentAuthResolution.failure
          ?? "Could not access the shared LPM session. Retry the organization push."
        lastSyncStatus = "failed"
      }
      finishSyncIfOwned(authority)
      return
    }

    do {
      let syncService = orgSyncServiceFactory(pending.environment.baseURL)
      guard
        case .response(let refreshedAccess) =
          await syncService
          .getOrgMemberKeyAccessAuthenticated(
            authToken: pending.authToken,
            expectedCallerUserID: currentUserId,
            orgSlug: pending.orgSlug
          )
      else {
        rejectUnauthorizedSyncResponseIfCurrent(
          authority,
          message: "Your lpm.dev session expired. Sign in again."
        )
        return
      }
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      guard let refreshedAccess else {
        throw VaultSyncError("Could not refresh organization member keys.")
      }
      guard refreshedAccess.organizationID == pending.trustScope.organizationID else {
        throw VaultSyncError(
          "The organization identity changed while approval was open. Review and retry."
        )
      }
      guard refreshedAccess.callerUserID == pending.callerUserID,
        refreshedAccess.callerUserID == currentUserId
      else {
        throw VaultSyncError(
          "The authenticated account changed while sharing-key approval was open. Review and retry."
        )
      }
      let refreshedMembers = refreshedAccess.members
      let pendingTrust = pending.orgTrust
      let previouslyApprovedMembers = pending.allMembers
      let refreshedAuthorization = try await Task.detached(priority: .userInitiated) {
        let prepared = try OrganizationMemberAuthorizationPolicy.prepare(
          refreshedMembers,
          trust: pendingTrust
        )
        var approvedTrust = pendingTrust
        approvedTrust.approve(approved)
        return RefreshedOrganizationAuthorization(
          prepared: prepared,
          membershipIsUnchanged:
            OrganizationMemberAuthorizationPolicy.sameAuthorization(
              prepared.membersWithKeys,
              previouslyApprovedMembers
            ),
          approvedTrust: approvedTrust,
          approvalIsComplete: approvedTrust.verify(bindings: prepared.bindings).isEmpty
        )
      }.value
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      guard refreshedAccess.canReplaceWrappedKeys == pending.canReplaceWrappedKeys,
        refreshedAuthorization.membershipIsUnchanged
      else {
        throw VaultSyncError(
          "Organization membership or sharing keys changed while approval was open. Review and retry."
        )
      }
      guard
        let authenticatedMember = refreshedAuthorization.prepared.membersWithKeys
          .first(where: { $0.userId == refreshedAccess.callerUserID })
      else {
        throw VaultSyncError(
          "Your registered sharing key changed while approval was open. Retry the share.")
      }
      let keypairProvider = sharingKeypairProvider
      let registryURL = pending.environment.registryURL
      let callerUserID = refreshedAccess.callerUserID
      let expectedPublicKey = authenticatedMember.publicKey
      let expectedFingerprint = authenticatedMember.publicKeyFingerprint
      let (_, localPublicKey) = try await Task.detached(priority: .userInitiated) {
        try keypairProvider(
          registryURL,
          callerUserID,
          expectedPublicKey,
          expectedFingerprint
        )
      }.value
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      let refreshedServerKey = try OrganizationMemberAuthorizationPolicy.currentMemberKey(
        userId: callerUserID,
        localPublicKey: localPublicKey,
        members: refreshedAuthorization.prepared.membersWithKeys
      )
      guard refreshedServerKey == pending.ownPublicKey else {
        throw VaultSyncError(
          "Your registered sharing key changed while approval was open. Retry the share."
        )
      }

      guard refreshedAuthorization.approvalIsComplete else {
        throw VaultSyncError(
          "Organization sharing-key approval is no longer complete. Review and retry.")
      }
      guard
        await persistence.saveOrgTrust(
          refreshedAuthorization.approvedTrust,
          scope: pending.trustScope
        )
      else {
        throw VaultSyncError(
          "Could not save organization key trust; the approved push was not started."
        )
      }
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }

      _ = try await executeOrgPush(
        project: project,
        validatedRecipients: refreshedAuthorization.prepared.validatedRecipients,
        syncService: syncService,
        canReplaceWrappedKeys: refreshedAccess.canReplaceWrappedKeys,
        callerUserID: callerUserID,
        authority: authority
      )
    } catch {
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      self.error = error.localizedDescription
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
    }
  }

  /// Called from KeyApprovalSheet when user rejects pending keys.
  func rejectPendingOrgPush() {
    invalidatePendingOrgPush()
    lastSyncStatus = "rejected"
    error = "Org push cancelled — untrusted member keys were rejected."
  }

  /// Shared implementation: encrypt and push vault data to an org.
  /// Only called after all member keys have been verified/approved.
  private func executeOrgPush(
    project: VaultProject,
    validatedRecipients: [ValidatedOrganizationRecipient],
    syncService: any OrgSyncServiceProtocol,
    canReplaceWrappedKeys: Bool,
    callerUserID: String,
    authority: SyncAuthority
  ) async throws -> VaultCreationResult {
    guard await hasCurrentSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    await waitForProjectMutations()
    let binding = syncBinding(for: authority)
    guard await hasCurrentSyncAuth(authority),
      let pushSnapshot = await persistence.syncSnapshot(
        vaultId: project.id,
        binding: binding
      )
    else {
      finishSyncIfOwned(authority)
      return .failed
    }
    guard !rejectPrincipalBindingConflict(pushSnapshot, authority: authority) else {
      return .failed
    }
    let pushedProject = pushSnapshot.project
    let nonEmptyEnvs = pushedProject.environments.filter { !$0.value.isEmpty }
    let scopeSlug = orgSlug(for: authority)
    let encrypted: (blob: String, wrappedKeys: [SyncService.WrappedMemberKey]?)
    let expectedVersion = pushSnapshot.metadata?.lastVersion
    let targetRevision = try Self.nextSyncRevision(after: expectedVersion)
    if canReplaceWrappedKeys {
      let projectID = pushedProject.id
      encrypted = try await Task.detached(priority: .userInitiated) {
        let payload = ["environments": nonEmptyEnvs]
        let secretsJSON = try JSONEncoder().encode(payload)
        let aesKey = VaultCrypto.generateAESKey()
        let wrappedKeys = try Self.wrapContentKey(aesKey, for: validatedRecipients)
        let blob = try VaultCrypto.encryptPayload(
          key: aesKey,
          plaintext: secretsJSON,
          scope: .organization(slug: scopeSlug),
          principalId: authority.principalID,
          vaultId: projectID,
          revision: targetRevision
        )
        return (blob, wrappedKeys)
      }.value
    } else {
      guard let expectedVersion else {
        throw VaultSyncError(
          "Organization maintainers must pull the current env project before updating it."
        )
      }
      guard
        case .response(let current) = await syncService.pullOrgAuthenticated(
          authToken: authority.authToken,
          orgSlug: orgSlug(for: authority),
          vaultId: pushedProject.id
        )
      else {
        rejectUnauthorizedSyncResponseIfCurrent(
          authority,
          message: "Your lpm.dev session expired. Sign in again."
        )
        return .failed
      }
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      guard let current,
        current.vaultId == pushedProject.id,
        current.principalId == authority.principalID,
        current.callerUserId == callerUserID,
        current.version == expectedVersion,
        let currentEncryptedBlob = current.encryptedBlob,
        let wrappedKey = current.wrappedKey
      else {
        throw VaultSyncError("The organization env project changed. Pull it and retry.")
      }
      guard let contentKeyVersion = current.contentKeyVersion,
        contentKeyVersion > 0,
        let cryptoVersion = current.cryptoVersion,
        cryptoVersion == VaultCrypto.currentCryptoVersion,
        let recipientKeyVersion = current.recipientPublicKeyVersion,
        recipientKeyVersion > 0,
        let expectedFingerprint = current.recipientPublicKeyFingerprint
      else {
        throw VaultSyncError(
          "The organization response has an invalid sharing-key binding."
        )
      }
      let keypairProvider = sharingKeypairProvider
      let registryURL = authority.environment.registryURL
      let (privateKey, publicKey) = try await Task.detached(priority: .userInitiated) {
        try keypairProvider(
          registryURL,
          callerUserID,
          nil,
          expectedFingerprint
        )
      }.value
      guard VaultCrypto.publicKeyFingerprint(publicKey) == expectedFingerprint else {
        throw VaultSyncError(
          "The organization response has an invalid sharing-key binding."
        )
      }
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      let projectID = pushedProject.id
      encrypted = try await Task.detached(priority: .userInitiated) {
        let syncScope = VaultCrypto.SyncScope.organization(slug: scopeSlug)
        let payload = ["environments": nonEmptyEnvs]
        let secretsJSON = try JSONEncoder().encode(payload)
        let aesKey = try VaultCrypto.unwrapKeyFromSender(
          wrapped: wrappedKey,
          privateKey: privateKey
        )
        do {
          _ = try VaultCrypto.decryptPayload(
            key: aesKey,
            encoded: currentEncryptedBlob,
            scope: syncScope,
            principalId: authority.principalID,
            vaultId: projectID,
            revision: expectedVersion,
            cryptoVersion: cryptoVersion
          )
        } catch {
          throw VaultSyncError(
            "The current organization env project could not be authenticated. Pull it and retry."
          )
        }
        let blob = try VaultCrypto.encryptPayload(
          key: aesKey,
          plaintext: secretsJSON,
          scope: syncScope,
          principalId: authority.principalID,
          vaultId: projectID,
          revision: targetRevision
        )
        return (blob, nil)
      }.value
    }

    // Push to org
    guard await hasCurrentSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    let schema = await syncSchema(for: pushedProject)
    guard await hasCurrentSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    let preparedPush = await syncService.preparePushOrgAuthenticated(
      authToken: authority.authToken,
      orgSlug: scopeSlug,
      expectedOrganizationID: authority.principalID,
      expectedCallerUserID: callerUserID,
      vaultId: pushedProject.id,
      encryptedBlob: encrypted.blob,
      wrappedKeys: encrypted.wrappedKeys,
      expectedVersion: expectedVersion,
      name: pushedProject.name,
      schema: schema
    )
    guard await hasCurrentSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    guard
      let response = try await executeAuthorizedRemoteMutation(
        authority: authority.authorityGeneration,
        prepared: preparedPush
      )
    else {
      _ = await hasCurrentSyncAuth(authority)
      finishSyncIfOwned(authority)
      return .failed
    }
    let result: SyncService.SyncStatus?
    switch response {
    case .response(let value): result = value
    case .unauthorized:
      rejectUnauthorizedSyncResponseIfCurrent(
        authority,
        message: "Your lpm.dev session expired. Sign in again."
      )
      return .failed
    }

    guard let pushedVersion = Self.acceptedPushVersion(
      result,
      vaultId: pushedProject.id,
      greaterThan: expectedVersion ?? 0
    ), pushedVersion == targetRevision,
      result?.principalId == authority.principalID
    else {
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return .failed
      }
      if let result, result.error == nil {
        self.error =
          "The organization push response did not match this env project or contain a valid version."
      } else {
        self.error = result?.displayError ?? "Org push failed"
      }
      lastSyncStatus = "failed"
      finishSyncIfOwned(authority)
      return .failed
    }
    guard await hasCurrentDurableSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    await waitForProjectMutations()
    guard canBeginDurableSyncCommit(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    let persistedCommit = await persistence.finishPush(
      pushedProject: pushedProject,
      action: "push",
      version: pushedVersion,
      binding: binding
    )
    let ownsPresentation = await hasCurrentSyncAuth(authority)
    guard canPublishDurableSyncCommit(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    guard let commit = persistedCommit else {
      if ownsPresentation {
        self.error = "The push succeeded, but local sync state could not be saved."
        lastSyncStatus = "failed"
      }
      finishSyncIfOwned(authority)
      return .failed
    }
    updateProjectInPlace(commit.project)
    applySyncMetadata(commit.syncMetadata, for: commit.project.id)
    if ownsPresentation {
      lastSyncStatus =
        commit.isDirty
        ? "Shared with \(orgSlug(for: authority)) (v\(pushedVersion)); local changes pending"
        : "Shared with \(orgSlug(for: authority)) (v\(pushedVersion))"
    }
    finishSyncIfOwned(authority)
    return .completed
  }

  private func isCurrentSync(_ authority: SyncAuthority) -> Bool {
    authority.operationGeneration == syncOperationGeneration
      && authority.sessionGeneration == vaultSessionGeneration
      && authority.authGeneration == authOperationGeneration
      && authority.environment == appEnvironment
      && isUnlocked
      && selectedAccount == authority.account
      && selectedProject?.id == authority.projectId
  }

  nonisolated static func acceptedPushVersion(
    _ result: SyncService.SyncStatus?,
    vaultId: String,
    greaterThan minimumVersion: Int = 0
  ) -> Int? {
    guard let result,
      result.error == nil,
      result.vaultId == vaultId,
      let version = result.version,
      version > minimumVersion
    else { return nil }
    return version
  }

  nonisolated private static func isRetryablePushConflict(
    _ result: SyncService.SyncStatus?
  ) -> Bool {
    switch result?.code {
    case "vault_version_conflict",
      "vault_expected_version_required",
      "vault_ciphertext_revision_mismatch",
      "vault_creation_conflict",
      "vault_recreation_intent_required":
      true
    default:
      false
    }
  }

  nonisolated private static func personalPushConflictMessage(
    _ result: SyncService.SyncStatus?,
    localExpectedVersion: Int?
  ) -> String? {
    switch result?.code {
    case "vault_expected_version_required"
    where localExpectedVersion == nil && (result?.serverVersion ?? 0) > 0:
      "This cloud env project already exists. Pull it before pushing."
    case "vault_version_conflict":
      "The cloud env project changed. Pull the latest version before pushing."
    case "vault_ciphertext_revision_mismatch"
    where localExpectedVersion != nil && result?.serverVersion == 0:
      "This cloud env project was deleted. Use Force Push to recreate it."
    default:
      nil
    }
  }

  nonisolated private static func nextSyncRevision(after version: Int?) throws -> Int {
    let previous = version ?? 0
    guard previous >= 0, previous < Int(Int32.max) else {
      throw VaultSyncError("The local env project revision is invalid.")
    }
    return previous + 1
  }

  nonisolated private static func keyCountDescription(_ count: Int) -> String {
    "\(count) \(count == 1 ? "key" : "keys")"
  }

  private func commitPull(
    authority: SyncAuthority,
    baseline: VaultProject,
    remotePayload: Data,
    action: String,
    version: Int
  ) async throws -> PullPersistenceResult? {
    let persistence = persistence
    let binding = syncBinding(for: authority)
    let operation: @Sendable () async -> PullPersistenceResult = { [weak self] in
      guard let self, await self.hasCurrentSyncAuth(authority) else {
        return .cancelled
      }
      return await persistence.commitPull(
        baseline: baseline,
        remotePayload: remotePayload,
        action: action,
        version: version,
        binding: binding
      )
    }
    if let generation = authority.authorityGeneration {
      return try await authorizedPullCommitter(generation, operation)
    }
    guard await hasCurrentSyncAuth(authority) else { return nil }
    return await operation()
  }

  private func hasCurrentSyncAuth(_ authority: SyncAuthority) async -> Bool {
    guard isCurrentSync(authority) else { return false }
    if authTokenProvider == nil {
      guard currentUser != nil,
        let identityGeneration = currentIdentityAuthorityGeneration,
        authority.authorityGeneration == identityGeneration
      else {
        clearAuthDependentState(
          message: "The active lpm.dev account changed while syncing."
        )
        return false
      }
    }
    if let authorityGeneration = authority.authorityGeneration {
      guard authAuthorityValidator(authorityGeneration) else {
        clearAuthDependentState(
          message: "The active lpm.dev session changed while syncing."
        )
        return false
      }
      return isCurrentSync(authority)
    }
    let currentAuthResolution = await resolveAuthToken(
      authority.environment.registryURL,
      authority.environment.baseURL
    )
    return isCurrentSync(authority)
      && currentAuthResolution.token == authority.authToken
  }

  private func rejectUnauthorizedSyncResponseIfCurrent(
    _ authority: SyncAuthority,
    message: String
  ) {
    guard authority.authGeneration == authOperationGeneration,
      authority.sessionGeneration == vaultSessionGeneration,
      authority.environment == appEnvironment
    else { return }
    if authTokenProvider == nil {
      guard currentIdentityAuthorityGeneration == authority.authorityGeneration else {
        return
      }
    }
    clearAuthDependentState(message: message)
  }

  private func finishSyncIfOwned(_ authority: SyncAuthority) {
    guard authority.operationGeneration == syncOperationGeneration else { return }
    isSyncing = false
  }

  private func canBeginDurableSyncCommit(_ authority: SyncAuthority) -> Bool {
    authority.sessionGeneration == vaultSessionGeneration
      && authority.authGeneration == authOperationGeneration
      && authority.environment == appEnvironment
      && isUnlocked
      && syncPrincipalID(for: authority.account) == authority.principalID
      && projects.contains { $0.id == authority.projectId }
  }

  private func hasCurrentDurableSyncAuth(_ authority: SyncAuthority) async -> Bool {
    guard canBeginDurableSyncCommit(authority) else { return false }
    if authTokenProvider == nil {
      guard currentUser != nil,
        let identityGeneration = currentIdentityAuthorityGeneration,
        authority.authorityGeneration == identityGeneration
      else {
        clearAuthDependentState(
          message: "The active lpm.dev account changed while syncing."
        )
        return false
      }
    }
    if let authorityGeneration = authority.authorityGeneration {
      guard authAuthorityValidator(authorityGeneration) else {
        clearAuthDependentState(
          message: "The active lpm.dev session changed while syncing."
        )
        return false
      }
      return canBeginDurableSyncCommit(authority)
    }
    let currentAuthResolution = await resolveAuthToken(
      authority.environment.registryURL,
      authority.environment.baseURL
    )
    return canBeginDurableSyncCommit(authority)
      && currentAuthResolution.token == authority.authToken
  }

  private func canPublishDurableSyncCommit(_ authority: SyncAuthority) -> Bool {
    authority.sessionGeneration == vaultSessionGeneration
      && isUnlocked
      && projects.contains { $0.id == authority.projectId }
  }

  private func syncPrincipalID(for account: SelectedAccount) -> String? {
    switch account {
    case .personal:
      return currentUser?.id
    case .org(let slug):
      return userOrgs.first(where: { $0.slug == slug })?.id
    }
  }

  private func syncBinding(for authority: SyncAuthority) -> SyncPrincipalBinding {
    SyncPrincipalBinding(
      registryURL: authority.environment.registryURL,
      principalID: authority.principalID,
      scope: {
        switch authority.account {
        case .personal: "personal"
        case .org: "organization"
        }
      }()
    )
  }

  private func rejectPrincipalBindingConflict(
    _ snapshot: SyncPersistenceSnapshot,
    authority: SyncAuthority
  ) -> Bool {
    guard snapshot.bindingConflict else { return false }
    error =
      "This env project is bound to a different account. Use a separate local project when switching accounts."
    lastSyncStatus = "failed"
    finishSyncIfOwned(authority)
    return true
  }

  private func orgSlug(for authority: SyncAuthority) -> String {
    guard case .org(let slug) = authority.account else { return "" }
    return slug
  }

  nonisolated static func wrapContentKey(
    _ aesKey: SymmetricKey,
    for recipients: [ValidatedOrganizationRecipient]
  ) throws -> [SyncService.WrappedMemberKey] {
    var wrappedKeys: [SyncService.WrappedMemberKey] = []
    wrappedKeys.reserveCapacity(recipients.count)
    for recipient in recipients {
      let wrapped = try VaultCrypto.wrapKeyForRecipient(
        aesKey: aesKey,
        recipientPublicKey: recipient.publicKey
      )
      wrappedKeys.append(
        SyncService.WrappedMemberKey(
          userId: recipient.userId,
          wrappedKey: wrapped,
          publicKeyVersion: recipient.publicKeyVersion,
          publicKeyFingerprint: recipient.publicKeyFingerprint
        ))
    }
    guard !wrappedKeys.isEmpty else {
      throw VaultSyncError("No organization members have complete registered sharing keys.")
    }
    return wrappedKeys
  }

  /// Pull a vault from an org using X25519 decryption.
  func pullFromOrg(orgSlug: String) async {
    guard isUnlocked, selectedAccount == .org(orgSlug), let project = selectedProject else {
      return
    }
    syncOperationGeneration &+= 1
    let operationGeneration = syncOperationGeneration
    let sessionGeneration = vaultSessionGeneration
    let environment = appEnvironment
    let authGeneration = authOperationGeneration
    let authResolution = await resolveAuthToken(environment.registryURL, environment.baseURL)
    guard let authToken = authResolution.token else {
      let fallback = "Not logged in."
      if rejectDefinitiveAccountAuthorizationIfCurrent(
        authResolution,
        authGeneration: authGeneration,
        sessionGeneration: sessionGeneration,
        environment: environment,
        fallback: fallback
      ) {
        return
      }
      guard operationGeneration == syncOperationGeneration,
        environment == appEnvironment,
        authGeneration == authOperationGeneration,
        sessionGeneration == vaultSessionGeneration
      else { return }
      rejectMissingAccountAuthorization(
        authResolution,
        fallback: fallback
      )
      return
    }
    guard operationGeneration == syncOperationGeneration,
      environment == appEnvironment,
      authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      isUnlocked,
      selectedAccount == .org(orgSlug),
      selectedProject?.id == project.id
    else { return }
    guard
      acceptAccountAuthorization(
        authResolution,
        failureMessage: "The active lpm.dev account changed. Reload account data before syncing."
      ), let principalID = syncPrincipalID(for: .org(orgSlug))
    else { return }
    let authority = SyncAuthority(
      projectId: project.id,
      account: .org(orgSlug),
      environment: environment,
      authGeneration: authGeneration,
      sessionGeneration: sessionGeneration,
      operationGeneration: operationGeneration,
      authToken: authToken,
      principalID: principalID,
      authorityGeneration: authResolution.authorityGeneration
    )
    guard isCurrentSync(authority), let currentUserID = currentUser?.id else { return }

    isSyncing = true
    lastSyncStatus = nil
    await waitForProjectMutations()
    let binding = syncBinding(for: authority)
    guard await hasCurrentSyncAuth(authority),
      let pullSnapshot = await persistence.syncSnapshot(
        vaultId: project.id,
        binding: binding
      )
    else {
      finishSyncIfOwned(authority)
      return
    }
    guard !rejectPrincipalBindingConflict(pullSnapshot, authority: authority) else {
      return
    }
    let baselineProject = pullSnapshot.project

    do {
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      let syncService = orgSyncServiceFactory(environment.baseURL)

      // Pull
      guard
        case .response(let result) = await syncService.pullOrgAuthenticated(
          authToken: authToken, orgSlug: orgSlug, vaultId: baselineProject.id
        )
      else {
        rejectUnauthorizedSyncResponseIfCurrent(
          authority,
          message: "Your lpm.dev session expired. Sign in again."
        )
        return
      }
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      guard let result else {
        error = "Pull failed — no response"
        finishSyncIfOwned(authority)
        lastSyncStatus = "failed"
        return
      }
      if result.code == "vault_member_needs_rewrap" {
        guard result.organizationId == authority.principalID,
          result.callerUserId == currentUserID
        else {
          throw VaultSyncError(
            "The organization access response did not match the authenticated account."
          )
        }
        guard
          case .response(let serverKey) =
            await syncService
            .getMyPublicKeyAuthenticated(
              authToken: authToken,
              expectedPrincipalId: currentUserID
            )
        else {
          rejectUnauthorizedSyncResponseIfCurrent(
            authority,
            message: "Your lpm.dev session expired. Sign in again."
          )
          return
        }
        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return
        }
        guard serverKey?.principalId == result.callerUserId,
          let registeredKey = serverKey?.publicKey
        else {
          throw VaultSyncError(
            "Your sharing key is not registered. Run `lpm env share --org \(orgSlug)` once, then retry."
          )
        }
        let keypairProvider = sharingKeypairProvider
        let registryURL = environment.registryURL
        let callerUserID = currentUserID
        let expectedFingerprint = serverKey?.publicKeyFingerprint
        let (_, publicKey) = try await Task.detached(priority: .userInitiated) {
          try keypairProvider(
            registryURL,
            callerUserID,
            registeredKey,
            expectedFingerprint
          )
        }.value
        guard registeredKey == publicKey.base64EncodedString() else {
          throw VaultSyncError(
            "This device does not hold the sharing key registered for your account."
          )
        }
        throw VaultSyncError(
          "Your registered sharing key does not have access to this env project yet. Ask an organization admin to share it again."
        )
      }
      guard result.vaultId == baselineProject.id,
        result.principalId == authority.principalID,
        result.callerUserId == currentUserID,
        let version = result.version,
        version > 0
      else {
        throw VaultSyncError(
          "The organization pull response did not match this env project or contain a valid version."
        )
      }

      guard let blob = result.encryptedBlob else {
        error = result.error ?? "No env project data in this organization."
        finishSyncIfOwned(authority)
        lastSyncStatus = "failed"
        return
      }

      guard let wrapped = result.wrappedKey else {
        error =
          "Your registered sharing key does not have access to this env project yet. Ask an organization admin to share it again."
        finishSyncIfOwned(authority)
        lastSyncStatus = "awaiting access"
        return
      }
      guard let contentKeyVersion = result.contentKeyVersion,
        contentKeyVersion > 0,
        let cryptoVersion = result.cryptoVersion,
        cryptoVersion == VaultCrypto.currentCryptoVersion,
        let recipientKeyVersion = result.recipientPublicKeyVersion,
        recipientKeyVersion > 0,
        let expectedFingerprint = result.recipientPublicKeyFingerprint
      else {
        throw VaultSyncError(
          "The organization response has an invalid sharing-key binding.")
      }
      let keypairProvider = sharingKeypairProvider
      let registryURL = environment.registryURL
      let callerUserID = currentUserID
      let (privKey, pubKey) = try await Task.detached(priority: .userInitiated) {
        try keypairProvider(
          registryURL,
          callerUserID,
          nil,
          expectedFingerprint
        )
      }.value
      guard VaultCrypto.publicKeyFingerprint(pubKey) == expectedFingerprint else {
        throw VaultSyncError(
          "The organization response has an invalid sharing-key binding."
        )
      }

      // Replay protection: reject version downgrades
      if let localVersion = pullSnapshot.metadata?.lastVersion,
        version < localVersion
      {
        error =
          "Version downgrade rejected (local: v\(localVersion), server: v\(version))"
        finishSyncIfOwned(authority)
        lastSyncStatus = "failed"
        return
      }

      // Unwrap and decrypt away from MainActor.
      let projectID = baselineProject.id
      let plaintext = try await Task.detached(priority: .userInitiated) {
        let aesKey = try VaultCrypto.unwrapKeyFromSender(
          wrapped: wrapped,
          privateKey: privKey
        )
        return try VaultCrypto.decryptPayload(
          key: aesKey,
          encoded: blob,
          scope: .organization(slug: orgSlug),
          principalId: authority.principalID,
          vaultId: projectID,
          revision: version,
          cryptoVersion: cryptoVersion
        )
      }.value

      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      await waitForProjectMutations()
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      guard
        let commit = try await commitPull(
          authority: authority,
          baseline: baselineProject,
          remotePayload: plaintext,
          action: "pull",
          version: version
        )
      else {
        _ = await hasCurrentSyncAuth(authority)
        finishSyncIfOwned(authority)
        return
      }
      let ownsPresentation = await hasCurrentSyncAuth(authority)
      guard canPublishDurableSyncCommit(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      switch commit {
      case .success(let persisted):
        updateProjectInPlace(persisted.project)
        applySyncMetadata(persisted.syncMetadata, for: persisted.project.id)
        if ownsPresentation {
          error = persisted.warning
          let keyCount = Self.keyCountDescription(persisted.keyCount)
          lastSyncStatus =
            persisted.isDirty
            ? "Pulled from \(orgSlug) (v\(version), \(keyCount)); local changes pending"
            : "Pulled from \(orgSlug) (v\(version), \(keyCount))"
        }
      case .conflict(let latest, let metadata):
        updateProjectInPlace(latest)
        applySyncMetadata(metadata, for: latest.id)
        if ownsPresentation {
          error = "Local values changed while the pull was running. Review them and retry."
          lastSyncStatus = "conflict"
        }
      case .staleVersion(let latest, let metadata):
        updateProjectInPlace(latest)
        applySyncMetadata(metadata, for: latest.id)
        if ownsPresentation {
          error = "A newer sync completed while this pull was running. Reload and retry."
          lastSyncStatus = "failed"
        }
      case .targetUnavailable:
        if ownsPresentation {
          error = "The target env project changed while the pull was running."
          lastSyncStatus = "failed"
        }
      case .invalidPayload(let message):
        if ownsPresentation {
          error = message
          lastSyncStatus = "failed"
        }
      case .cancelled:
        break
      case .failure(let persistenceError):
        if ownsPresentation {
          error = persistenceError.description
          lastSyncStatus = "failed"
        }
      }
      finishSyncIfOwned(authority)
    } catch {
      guard await hasCurrentSyncAuth(authority) else {
        finishSyncIfOwned(authority)
        return
      }
      self.error = "Org pull failed: \(error.localizedDescription)"
      finishSyncIfOwned(authority)
      lastSyncStatus = "failed"
    }
  }

  private func resolveCloudAuthorization() async -> CloudAuthorization? {
    let environment = appEnvironment
    let authGeneration = authOperationGeneration
    let sessionGeneration = vaultSessionGeneration
    let resolution = await resolveAuthToken(
      environment.registryURL,
      environment.baseURL
    )
    guard authGeneration == authOperationGeneration,
      sessionGeneration == vaultSessionGeneration,
      environment == appEnvironment
    else { return nil }
    guard let token = resolution.token else {
      if resolution.disposition.definitivelyInvalidated {
        clearAuthDependentState(message: resolution.failure)
      } else if let failure = resolution.failure {
        error = failure
      }
      return nil
    }
    if authTokenProvider == nil {
      guard currentUser != nil,
        let identityGeneration = currentIdentityAuthorityGeneration,
        resolution.authorityGeneration == identityGeneration,
        authAuthorityValidator(identityGeneration)
      else {
        if currentUser != nil || currentIdentityAuthorityGeneration != nil {
          clearAuthDependentState(
            message: "The active lpm.dev account changed. Reload cloud data for the new account."
          )
        }
        return nil
      }
    }
    let authority = CloudAuthorization(
      environment: environment,
      authGeneration: authGeneration,
      sessionGeneration: sessionGeneration,
      token: token,
      authorityGeneration: resolution.authorityGeneration
    )
    guard await hasCurrentCloudAuthorization(authority) else {
      clearIdentityIfPeerAuthorityChanged(authority)
      return nil
    }
    return authority
  }

  private func hasCurrentCloudAuthorization(_ authority: CloudAuthorization) async -> Bool {
    guard authority.authGeneration == authOperationGeneration,
      authority.sessionGeneration == vaultSessionGeneration,
      authority.environment == appEnvironment
    else { return false }
    if authTokenProvider == nil, currentUser != nil,
      currentIdentityAuthorityGeneration != authority.authorityGeneration
    {
      return false
    }
    if let generation = authority.authorityGeneration {
      return authAuthorityValidator(generation)
    }
    let resolution = await resolveAuthToken(
      authority.environment.registryURL,
      authority.environment.baseURL
    )
    return authority.authGeneration == authOperationGeneration
      && authority.sessionGeneration == vaultSessionGeneration
      && authority.environment == appEnvironment
      && resolution.token == authority.token
  }

  private func isCurrentCloudCommit(
    _ authority: CloudAuthorization,
    account: SelectedAccount,
    principalID: String
  ) -> Bool {
    !Task.isCancelled
      && authority.authGeneration == authOperationGeneration
      && authority.sessionGeneration == vaultSessionGeneration
      && authority.environment == appEnvironment
      && selectedAccount == account
      && syncPrincipalID(for: account) == principalID
  }

  private func clearIdentityIfPeerAuthorityChanged(_ authority: CloudAuthorization) {
    guard authority.authGeneration == authOperationGeneration,
      authority.sessionGeneration == vaultSessionGeneration,
      authority.environment == appEnvironment,
      let generation = authority.authorityGeneration
    else { return }
    let identityMismatch =
      currentIdentityAuthorityGeneration != nil
      && currentIdentityAuthorityGeneration != authority.authorityGeneration
    guard identityMismatch || !authAuthorityValidator(generation) else { return }
    clearAuthDependentState(
      message: "The active lpm.dev session changed while cloud data was loading."
    )
  }

  private func rejectUnauthorizedCloudResponseIfCurrent(
    _ authority: CloudAuthorization,
    message: String
  ) {
    guard authority.authGeneration == authOperationGeneration,
      authority.sessionGeneration == vaultSessionGeneration,
      authority.environment == appEnvironment
    else { return }
    if authTokenProvider == nil {
      guard currentIdentityAuthorityGeneration == authority.authorityGeneration else {
        return
      }
    }
    clearAuthDependentState(message: message)
  }

  private func resolveAuthToken(
    _ registryURL: String,
    _ baseURL: URL
  ) async -> AuthTokenResolution {
    do {
      if let authTokenProvider {
        let token = try await authTokenProvider(registryURL, baseURL)
        return AuthTokenResolution(
          token: token,
          failure: nil,
          authorityGeneration: nil,
          disposition: token == nil ? .absent : .authorized
        )
      }
      let authorization = try await authAuthorizationProvider(
        registryURL,
        baseURL
      )
      return AuthTokenResolution(
        token: authorization?.token,
        failure: nil,
        authorityGeneration: authorization?.authorityGeneration,
        disposition: authorization == nil ? .absent : .authorized
      )
    } catch is CancellationError {
      return AuthTokenResolution(
        token: nil,
        failure: nil,
        authorityGeneration: nil,
        disposition: .cancelled
      )
    } catch AuthSessionCoordinatorError.sessionRevokedWithCleanupFailure(let message) {
      return AuthTokenResolution(
        token: nil,
        failure: "The shared LPM session was revoked, but cleanup failed. \(message)",
        authorityGeneration: nil,
        disposition: .revoked
      )
    } catch {
      let message = "Could not access the shared LPM session. \(error.localizedDescription)"
      return AuthTokenResolution(
        token: nil,
        failure: message,
        authorityGeneration: nil,
        disposition: .transientFailure
      )
    }
  }

  private func syncSchema(for project: VaultProject) async -> LPMJSONValue? {
    let path = project.path
    guard !path.isEmpty else { return nil }
    return await Task.detached(priority: .userInitiated) {
      let configURL = URL(fileURLWithPath: path).appendingPathComponent("lpm.json")
      guard case .object(let root) = ProjectConfigFile.readJSON(at: configURL) else {
        return nil
      }

      var schema: [String: LPMJSONValue] = ["version": .integer(2)]
      if case .object(let envSchema) = root["envSchema"] {
        schema["envSchema"] = envSchema["vars"] ?? .object(envSchema)
      }
      if case .object(let environments) = root["environments"] {
        schema["environments"] = .object(environments)
      }
      if case .object(let env) = root["env"] {
        var envConfig: [String: LPMJSONValue] = [:]
        for (alias, value) in env {
          guard case .string(let envPath) = value else { continue }
          guard envPath.hasPrefix(".env."), envPath.count > ".env.".count else {
            continue
          }
          envConfig[alias] = .object([
            "canonical": .string(String(envPath.dropFirst(".env.".count))),
            "file": .string(envPath),
          ])
        }
        if !envConfig.isEmpty { schema["envConfig"] = .object(envConfig) }
      }
      return .object(schema)
    }.value
  }

  // MARK: - Private

  private func enqueueProjectMutation(
    base project: VaultProject,
    mutation: VaultProjectMutation,
    afterCommit: @escaping @MainActor (VaultProject) -> Void = { _ in },
    afterCompletion: @escaping @MainActor (Bool) -> Void = { _ in }
  ) {
    cancelLocalEnvImports(projectId: project.id)
    invalidateProjectLoad()
    let predecessor = projectMutationTask
    let requestId = UUID()
    let sessionGeneration = vaultSessionGeneration
    projectMutationRequestId = requestId
    let task = Task { @MainActor [weak self, persistence] in
      await predecessor?.value
      let result = await persistence.mutateProject(
        projectId: project.id,
        expectedName: project.name,
        expectedPath: project.path,
        mutation: mutation
      )
      guard let self else {
        afterCompletion(false)
        return
      }
      guard sessionGeneration == vaultSessionGeneration, isUnlocked else {
        afterCompletion(false)
        return
      }
      switch result {
      case .success(let persisted):
        updateProjectInPlace(persisted.project)
        applySyncMetadata(persisted.syncMetadata, for: persisted.project.id)
        error = persisted.warning
        afterCommit(persisted.project)
        afterCompletion(true)
      case .conflict(let latest, let metadata):
        updateProjectInPlace(latest)
        applySyncMetadata(metadata, for: latest.id)
        error =
          "This env project changed in another LPM process. Review the latest values and retry."
        afterCompletion(false)
      case .targetUnavailable:
        error = "The target env project changed before the update was saved."
        afterCompletion(false)
      case .failure(let persistenceError):
        error = persistenceError.description
		if case .transactionOutcomeIndeterminate = persistenceError {
          _ = await loadProjects()
        }
        afterCompletion(false)
      }
    }
    projectMutationTask = task
  }

  private func waitForProjectMutations() async {
    while let pending = projectMutationTask {
      let requestId = projectMutationRequestId
      await pending.value
      guard requestId == projectMutationRequestId else { continue }
      projectMutationTask = nil
      projectMutationRequestId = nil
    }
  }

  private func updateProjectInPlace(_ project: VaultProject) {
    if let index = projects.firstIndex(where: { $0.id == project.id }) {
      projects[index] = project
	}
  }

  private func applySyncMetadata(_ metadata: SyncMetadata?, for vaultId: String) {
    if let metadata {
      syncMetadata[vaultId] = metadata
    } else {
      syncMetadata.removeValue(forKey: vaultId)
    }
  }

  // MARK: - Sync Metadata

  private static let syncMetadataKey = "lpm-vault-sync-metadata"

  func syncStatus(for vaultId: String) -> ProjectSyncStatus {
    guard let meta = syncMetadata[vaultId] else { return .neverSynced }
    if meta.isDirty { return .localChanges }
    guard let binding = currentSyncBinding(), meta.syncInfo(boundTo: binding) != nil else {
      return .neverSynced
    }
    return .synced
  }

  func lastSyncInfo(for vaultId: String) -> (date: Date, action: String, version: Int?)? {
    guard let meta = syncMetadata[vaultId],
      let binding = currentSyncBinding(),
      let info = meta.syncInfo(boundTo: binding)
    else { return nil }
    return (info.date, info.action, info.version)
  }

  private func currentSyncBinding() -> SyncPrincipalBinding? {
    guard let principalID = syncPrincipalID(for: selectedAccount) else { return nil }
    return SyncPrincipalBinding(
      registryURL: appEnvironment.registryURL,
      principalID: principalID,
      scope: {
        switch selectedAccount {
        case .personal: "personal"
        case .org: "organization"
        }
      }()
    )
  }

  // MARK: - Environment Ordering

  private static let envOrderPrefix = "lpm-vault-env-order-"

  func orderedEnvironmentNames(for project: VaultProject) -> [String] {
    if let saved = environmentOrders[project.id], !saved.isEmpty {
      var seen: Set<String> = []
      let validSaved = saved.filter {
        project.environments.keys.contains($0) && seen.insert($0).inserted
      }
      let remaining = project.environmentNames.filter { seen.insert($0).inserted }
      return validSaved + remaining
    }
    return project.environmentNames
  }

  func saveEnvironmentOrder(for projectId: String, order: [String]) {
    var seen: Set<String> = []
    let normalized = order.filter { seen.insert($0).inserted }
    environmentOrders[projectId] = normalized
    UserDefaults.standard.set(normalized, forKey: Self.envOrderPrefix + projectId)
  }

  private func loadEnvironmentOrders() {
    for project in projects {
      let key = Self.envOrderPrefix + project.id
      if let saved = UserDefaults.standard.stringArray(forKey: key) {
        environmentOrders[project.id] = saved
      }
    }
  }
}
