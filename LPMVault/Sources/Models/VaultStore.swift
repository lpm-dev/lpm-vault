import CryptoKit
import Foundation
import LocalAuthentication

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

final class CliAccessChangeAuthorization: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = true

  func beginCommit() -> Bool {
    lock.withLock {
      guard pending else { return false }
      pending = false
      return true
    }
  }

  func invalidate() { lock.withLock { pending = false } }
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

  /// The Registry a platform connection made in this environment belongs to.
  var issuer: PlatformIssuer {
    switch self {
    case .production: .production
    #if DEBUG
      case .development: .development
    #endif
    }
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

enum VaultLoadFailure: Equatable, Sendable {
  case keychainLocked, accessDenied, unsupportedBuild, invalidState, unavailable, authentication

  init(_ error: KeychainError) {
    switch error {
    case .keychainLocked: self = .keychainLocked
    case .accessDenied: self = .accessDenied
    case .missingEntitlement: self = .unsupportedBuild
    case .encodingFailed, .transactionOutcomeIndeterminate: self = .invalidState
    default: self = .unavailable
    }
  }

  var message: String {
    switch self {
    case .keychainLocked: "macOS did not allow Keychain access. Unlock your Mac and retry. If access still fails, check your login Keychain."
    case .accessDenied: "Keychain access was denied. Allow LPM Vault in Keychain Access, then retry."
    case .unsupportedBuild: "This build cannot access the shared Keychain. Install an official LPM Vault build."
    case .invalidState: "Protected vault state could not be read. Retry after other LPM operations finish. If the error continues, contact support."
    case .unavailable: "Protected vault state is unavailable. Retry. If the error continues, contact support."
    case .authentication: "Could not authenticate with macOS. Try Touch ID or your Mac login password again."
    }
  }
}

enum AddSecretError: LocalizedError, Sendable, Equatable {
  case vaultLocked
  case noEnvironments
  case targetUnavailable
  case invalidName
  case duplicate
  case caseInsensitiveCollision(existingKey: String)
  case persistence(String)

  var errorDescription: String? {
    switch self {
    case .vaultLocked:
      "Unlock LPM Vault before adding a secret."
    case .noEnvironments:
      "Choose at least one environment."
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

/// How a queued project mutation ended.
enum ProjectMutationOutcome: Equatable, Sendable {
  case saved
  /// Another process changed the project first; its latest state is published.
  case changed
  case unavailable
  case failed(String)
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
      schemaReviews = [:]
      invalidateLocalStateRefresh()
      keyDrafts.receive(projects)
      if !projects.elementsEqual(oldValue, by: { $0.id == $1.id }) {
        reconcileProjectOrder()
        let projectIDs = Set(projects.lazy.map(\.id))
        projectCliAccess = projectCliAccess.filter { projectIDs.contains($0.key) }
        cliAccessProjectRevisions = cliAccessProjectRevisions.filter { projectIDs.contains($0.key) }
        pruneProjectSettingsDrafts(keeping: projectIDs)
      }
      if !projects.elementsEqual(oldValue, by: { $0.id == $1.id && $0.path == $1.path }) {
        projectIcons.follow(projects.map { ProjectIconStore.Target(id: $0.id, folder: $0.path) })
      }
      pruneSchemaDrafts()
      refreshValueChecks()
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
  /// Unsaved key edits of this session; cleared on lock and account changes.
  let keyDrafts = VaultKeyDrafts()
  /// Each project's icon, chosen or found in its folder.
  let projectIcons: ProjectIconStore
  /// Where values are copied, and cleared from when the vault locks.
  let clipboard: ClipboardManager
  /// Unsaved Project Settings edits by project ID; cleared on lock and account changes.
  var projectSettingsDrafts: [String: ProjectSettingsDraft] = [:]
  /// Projects whose Project Settings are being saved.
  var savingProjectSettings: Set<String> = []
  /// Why each project's Project Settings couldn't be saved.
  var projectSettingsErrors: [String: String] = [:]
  /// Key descriptions from each project's `lpm.json`, by project ID.
  private(set) var keyDescriptions: [String: ProjectKeyDescriptions] = [:] {
    didSet {
      schemaBases = [:]
      schemaReviews = [:]
    }
  }
  /// The app's own edits of each project's lpm.json that are in flight.
  @ObservationIgnored private var ownSchemaWrites: [String: Int] = [:]
  /// Projects whose draft merges once their own edits are published.
  @ObservationIgnored private var pendingSchemaMerges: Set<String> = []
  /// lpm.json's rules as a draft without changes, parsed once per project
  /// while its descriptions stay the same.
  @ObservationIgnored private var schemaBases: [String: ProjectEnvSchemaDraft] = [:]
  /// How often lpm.json's rules have been read into a project's draft base,
  /// which every read reuses until the rules change.
  @ObservationIgnored private(set) var schemaBaseBuilds = 0
  /// What the bundled engine finds in each project's stored values, by
  /// project ID; absent while a project's rules are unknown or unreadable.
  private(set) var valueChecks: [String: ProjectEnvValueCheck] = [:] { didSet { schemaReviews = [:] } }
  /// Unsaved schema edits by project ID; cleared on lock and account changes.
  private(set) var schemaDrafts: [String: ProjectEnvSchemaDraft] = [:] {
    didSet {
      schemaReviews = [:]
      let edited = Set(schemaDrafts.lazy.filter { !$0.value.isEmpty }.map(\.key))
      if edited != projectsWithSchemaDrafts { projectsWithSchemaDrafts = edited }
    }
  }
  /// Projects with unsaved schema edits, which changes only when a draft
  /// starts or ends, so views that show it skip keystroke updates.
  private(set) var projectsWithSchemaDrafts: Set<String> = []
  /// Raw text edits not saved yet, by environment. Locking or another account discards them.
  private(set) var rawTextDrafts: [VaultEnvironmentTarget: VaultRawTextDraft] = [:]
  /// The Raw text drafts being saved, each with its save's own number.
  private var rawTextSaves: [VaultEnvironmentTarget: UUID] = [:]
  /// The folder each draft's rules were read from.
  @ObservationIgnored private var schemaDraftFolders: [String: SchemaDraftFolder] = [:]
  /// Counts each project's draft changes, so an evaluation is matched to its draft cheaply.
  @ObservationIgnored private var schemaDraftRevisions: [String: Int] = [:]
  /// Each draft's latest evaluation, with the draft revision and values it used.
  private(set) var schemaDraftEvaluations: [String: EvaluatedSchemaDraft] = [:] { didSet { schemaReviews = [:] } }
  /// Each project's review of its draft, for the environment order it was
  /// built for, until anything it's built from changes.
  @ObservationIgnored private var schemaReviews: [String: (environments: [String], review: ProjectEnvSchemaReview?)] = [:]
  /// What merging drafts onto lpm.json's rules as read from disk changed, until dismissed.
  private(set) var schemaDraftRebases: [String: ProjectEnvSchemaDraft.Rebase] = [:]
  private(set) var savingSchemaDrafts: Set<String> = []
  /// Ends saves that started before the drafts were cleared.
  @ObservationIgnored private var schemaDraftGeneration = 0
  /// Projects whose next evaluation waits for typing to pause.
  @ObservationIgnored private var debouncedSchemaDrafts: Set<String> = []
  private(set) var schemaDraftHistory: [String: SchemaDraftHistory] = [:]
  /// Each project's last failed save, with the draft revision it tried to save.
  private(set) var schemaDraftSaveFailures: [String: SchemaDraftSaveFailure] = [:]
  @ObservationIgnored private var schemaDraftEvaluationInputs: [String: SchemaDraftEvaluationInputs] = [:]
  @ObservationIgnored private var schemaDraftEvaluationTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var schemaDraftEvaluator = ProjectEnvSchemaDraftEvaluator()
  @ObservationIgnored let valueCheckWorker: ProjectEnvValueCheckWorker
  @ObservationIgnored private var valueCheckInputs: [String: ValueCheckInputs] = [:]
  @ObservationIgnored private var valueCheckTasks: [String: Task<Void, Never>] = [:]
  private var unverifiedKeyDescriptionProjects: Set<String> = []
  private var keyDescriptionsTask: Task<Void, Never>?
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
      if let selectedProjectId { unverifiedKeyDescriptionProjects.insert(selectedProjectId) }
      lastSyncWarnings = []
      invalidateLocalStateRefresh()
      cancelExports()
      if let oldValue { cancelLocalEnvImports(projectId: oldValue) }
      cancelLocalEnvPreviews()
      invalidatePendingOrgPush()
      beginSelectedProjectLoadIfNeeded()
    }
  }
  var isUnlocked: Bool = false
  var error: String?
  var isLoadingProjects: Bool = false
  var isUnlocking: Bool = false
  private(set) var unlockFailure: VaultLoadFailure?
  private(set) var selectedProjectLoadFailure: VaultLoadFailure?
  private(set) var autoLockCountdownSeconds: Int?
  private(set) var selectedProjectCliAccess: VaultCliAccess?
  private(set) var projectCliAccess: [String: VaultCliAccess] = [:]
  private var cliAccessLoadTask: Task<Void, Never>?
  private var cliAccessLoadGeneration = 0
  private var cliAccessProjectRevisions: [String: UUID] = [:]
  private var cliAccessChangeID: UUID?
  private var cliAccessChangeAuthorization: CliAccessChangeAuthorization?
  var isChangingCliAccess: Bool { cliAccessChangeID != nil }

  // Auth state
  var currentUser: LPMUser? {
    didSet {
      invalidateLocalStateRefresh()
      reconcileNavigationState()
    }
  }
  var personalTokens: [LPMToken] = []
  var orgTokens: [String: [LPMToken]] = [:]  // orgSlug → tokens
  var isLoadingTokens: Bool = false
  var isLoggingIn: Bool = false

  // Navigation state
  var selectedAccount: SelectedAccount = .personal {
    didSet {
      guard oldValue != selectedAccount else { return }
      lastSyncWarnings = []
      invalidateLocalStateRefresh()
      keyDrafts.discardAll()
      rawTextDrafts.removeAll()
      discardAllProjectSettings()
      clearKeyDescriptions()
    }
  }
  /// The account page shown instead of a project, if any.
  var accountPage: AccountPage?
  var isShowingAccountPage: Bool { accountPage != nil }

  // Sync state
  var isSyncing: Bool = false
  var lastSyncStatus: String? {
    didSet { if lastSyncStatus == nil { lastSyncWarnings = [] } }
  }
  var lastSyncWarnings: [SyncMetadataWarning] = []

  // Sync metadata (persisted across launches)
  var syncMetadata: [String: SyncMetadata] = [:]

  // Vault → org associations (persisted in Keychain)
  var vaultOrgAssociations: [String: String] = [:] {  // vaultId → orgSlug
    didSet { reconcileNavigationState() }
  }

  /// Local display preferences and folders linked for the CLI.
  let preferences: UserDefaults

  /// Where the LPM CLI keeps login and env state, which no project's state may be.
  var lpmHome = LPMHome.current
  /// A move between LPM homes through the credential stores, given the
  /// authentication that reads items whose CLI access asks for approval.
  @ObservationIgnored var lpmHomeMove: @Sendable (LAContext?) -> LPMHomeMove = { context in
    let shared = SecurityKeychainStoreBackend()
    shared.setAuthenticationContext(context)
    return LPMHomeMove(shared: shared, app: AppGroupKeychain())
  }
  /// Where an LPM home keeps its login credentials, including those an older
  /// LPM version kept in the login keychain, which a move upgrades first.
  @ObservationIgnored var lpmHomeCredentials: @Sendable (LPMHome) -> any AuthCredentialBackend = { home in
    KeychainAuthCredentialBackend(service: home.service(VaultConstants.cliAuthService))
  }
  /// Places a folder as an LPM home for the user whose home folder is given.
  /// Blocking file work.
  @ObservationIgnored var lpmHomeResolver: @Sendable (URL, URL) -> LPMHome? = { url, userHome in
    LPMHome.at(url, userHome: userHome)
  }
  /// Removes the copies a move that didn't end left, once an unlock starts it.
  private var lpmHomeMoveRecovery: Task<Void, Never>?
  /// Quits the app and opens it again, as using another LPM home takes.
  @ObservationIgnored var relaunch: @MainActor () -> Void = AppRelaunch.relaunch
  static let projectOrderKey = "lpm-vault-project-order"
  private var projectOrder: [String]
  /// The last backup this Mac exported.
  private(set) var lastBackup: VaultBackupRecord?

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
  /// Publish destinations and this Mac's publish history.
  let publishing: PublishingStore
  private let platformConnect: PlatformConnections.Connect?
  private let netlifyConnect: PlatformConnections.ConnectNetlify?
  private let githubConnect: PlatformConnections.ConnectGitHub?
  private let platformURLOpener: (@MainActor @Sendable (URL) -> Void)?
  /// The platform accounts this Mac publishes to, for the Platforms page.
  let platformConnectionStore: PlatformConnectionStore
  private let platformClient: @Sendable (String) -> any VercelClientProtocol
  private let coolifyClient: CoolifyConnector.ClientFactory
  private let netlifyClient: NetlifyConnector.ClientFactory
  private let githubClient: GitHubConnector.ClientFactory
  private let cloudflareClient: RenewingCloudflareClient.ClientFactory
  private let cloudflareConnect: PlatformConnections.ConnectCloudflare?
  private let platformRevoker: (any PlatformTokenRevoking)?
  /// Each project's saved publish destinations, for the Publish menu.
  private(set) var publishDestinations: [String: [PublishDestinationSummary]] = [:]
  /// Open Publish sheets' sessions, which locking stops.
  @ObservationIgnored private var publishSessions: [WeakPublishSession] = []
  /// Each platform connection's detail for the Publish menu, read once
  /// while unlocked; nil until read, and again once the connections change.
  @ObservationIgnored private var connectionDetails: [PlatformConnection.ID: String]?
  @ObservationIgnored private var connectionDetailsGeneration = 0
  /// The connections' access tokens, renewed through lpm.dev for a platform
  /// whose tokens expire. One instance serves every Publish sheet, so a
  /// token is renewed by one request at a time.
  @ObservationIgnored private(set) lazy var platformCredentials = PlatformCredentials(
    store: platformConnectionStore,
    revoker: platformRevoker ?? PlatformAuthorizationClient(),
    session: { [weak self] in await self?.platformSession() },
    cleanupChanged: { [weak self] in Task { @MainActor in self?.platformCleanupChanged() } }
  )
  @ObservationIgnored private(set) lazy var platforms = PlatformConnections(
    store: platformConnectionStore,
    connect: platformConnect ?? { await VercelConnector().connect(session: $0, open: $1) },
    connectCoolify: { [coolifyClient] in await CoolifyConnector(client: coolifyClient).connect(address: $0, token: $1) },
    connectNetlify: netlifyConnect ?? { [netlifyClient] in await NetlifyConnector(client: netlifyClient).connect(session: $0, open: $1) },
    connectGitHub: githubConnect ?? { [githubClient] in await GitHubConnector(client: githubClient).connect(session: $0, open: $1) },
    connectCloudflare: cloudflareConnect,
    credentials: platformCredentials,
    session: { [weak self] in await self?.platformSession() },
    openURL: platformURLOpener ?? PlatformConnections.openInBrowser,
    didChange: { [weak self] in self?.forgetConnectionDetails() }
  )
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
  /// When a schema edit is made, for undoing typing in one field together.
  private let schemaEditNow: @Sendable () -> ContinuousClock.Instant
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
  /// Every write running, which quitting lets finish.
  private let writes = VaultWrites()
  /// What sheets still open hold, which quitting would discard.
  private(set) var openSheetWork: [UUID: VaultUnsavedWork.OpenSheet] = [:]
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
  private var localEnvImportRequests: [LocalEnvImportTarget: UUID] = [:]
  private var localEnvCreationRequests: [LocalEnvImportTarget: UUID] = [:]
  private var localEnvReviewIDs: [LocalEnvImportTarget: UUID] = [:]
  private var localEnvPreviewTasks: [UUID: Task<ImportedEnvFile, Error>] = [:]
  private var exportTasks: [UUID: Task<[String], Error>] = [:]
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
    orderedProjects.filter { projectBelongsToSelectedAccount($0.id) }
  }

  private var orderedProjects: [VaultProject] {
    guard !projectOrder.isEmpty else { return projects }
    var remaining = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    var ordered = projectOrder.compactMap { remaining.removeValue(forKey: $0) }
    ordered.append(contentsOf: projects.filter { remaining[$0.id] != nil })
    return ordered
  }

  private func reconcileProjectOrder() {
    let currentIds = Set(projects.lazy.map(\.id))
    var seen: Set<String> = []
    let retained = projectOrder.filter { currentIds.contains($0) && seen.insert($0).inserted }
    let added = projects.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    let order = added + retained
    guard order != projectOrder else { return }
    projectOrder = order
    preferences.set(order, forKey: Self.projectOrderKey)
  }

  /// Filtered vaults for search.
  func visibleVaults(matching search: String) -> [VaultProject] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return activeVaults }
    return orderedProjects.filter { project in
      projectBelongsToSelectedAccount(project.id)
        && (project.name.lowercased().contains(query)
          || workspaceSnapshots[project.id]?.normalizedSearchIndex.contains(query) == true)
    }
  }

  @discardableResult
  func moveProject(id: String, relativeTo targetId: String, placement: VaultProjectPlacement) -> Bool {
    guard isUnlocked, id != targetId,
      projectBelongsToSelectedAccount(id), projectBelongsToSelectedAccount(targetId)
    else { return false }
    let currentOrder = orderedProjects.map(\.id)
    guard let source = currentOrder.firstIndex(of: id), currentOrder.contains(targetId) else { return false }
    var order = currentOrder
    order.remove(at: source)
    guard let target = order.firstIndex(of: targetId) else { return false }
    order.insert(id, at: target + (placement == .after ? 1 : 0))
    guard order != currentOrder else { return false }
    projectOrder = order
    preferences.set(order, forKey: Self.projectOrderKey)
    resetAutoLock()
    return true
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
      selectedAccount = resolvedAccount
    } else {
      reconcileNavigationState()
    }
    accountPage = nil
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

  /// Selects a project after switching to its owning account, and always
  /// leaves the Settings or Platforms page.
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
        accountPage = nil
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
    accountPage = nil
    selectedProjectId = projectId
    normalizeSelectedEnvironment()
    resetAutoLock()
  }

  /// The page on lpm.dev that manages the signed-in account, for the server in use.
  var accountManagementURL: URL? {
    URL(string: "/dashboard/settings", relativeTo: appEnvironment.baseURL)?.absoluteURL
  }

  func showSettings() {
    accountPage = .settings
    resetAutoLock()
  }

  /// Shows the Settings page, unlocking first when the vault is locked:
  /// the settings live in the window, behind the lock.
  func showSettingsUnlockingFirst() async {
    if !isUnlocked { await unlock() }
    guard isUnlocked else { return }
    showSettings()
  }

  func showPlatforms() {
    accountPage = .platforms
    platforms.load()
    resetAutoLock()
  }

  /// Reads the project's saved publish destinations, most recently published first.
  func loadPublishDestinations(for projectID: String) async {
    guard isUnlocked else { return }
    let generation = vaultSessionGeneration
    guard case .success(let destinations) = await publishing.destinations(of: projectID) else { return }
    let details = destinations.isEmpty ? [:] : await platformConnectionDetails()
    var summaries: [PublishDestinationSummary] = []
    summaries.reserveCapacity(destinations.count)
    for destination in destinations {
      let history = try? await publishing.history(of: destination.id, in: projectID).get()
      summaries.append(PublishDestinationSummary(
        destination: destination, lastPublishedAt: history?.publishedAt,
        accountDetail: destination.target.connectionID.flatMap { details[$0] }))
    }
    guard isUnlocked, generation == vaultSessionGeneration else { return }
    publishDestinations[projectID] = summaries.sorted {
      switch ($0.lastPublishedAt, $1.lastPublishedAt) {
      case let (left?, right?) where left != right: left > right
      case (.some, nil): true
      case (nil, .some): false
      default: $0.destination.createdAt < $1.destination.createdAt
      }
    }
  }

  /// Reads the project's destinations again when the Publish menu has them,
  /// as after a rename or deletion moved or removed some.
  private func refreshPublishMenu(for projectID: String) async {
    guard publishDestinations[projectID] != nil else { return }
    await loadPublishDestinations(for: projectID)
  }

  /// Each platform connection's detail, read from the Keychain only when
  /// the connections changed since it was last read. Each record holds its
  /// token, so the menu doesn't read them all every time it's refreshed.
  private func platformConnectionDetails() async -> [PlatformConnection.ID: String] {
    if let connectionDetails { return connectionDetails }
    let generation = connectionDetailsGeneration
    guard case .success(let connections) = await platformConnectionStore.connections() else { return [:] }
    let details = Dictionary(connections.map { ($0.id, $0.detail) }, uniquingKeysWith: { first, _ in first })
    if generation == connectionDetailsGeneration, isUnlocked { connectionDetails = details }
    return details
  }

  private func forgetConnectionDetails() {
    connectionDetailsGeneration &+= 1
    connectionDetails = nil
  }

  /// A Publish sheet for the selected project, opening on `destination`'s
  /// review when it's a saved one.
  func makePublishSession(for destination: PublishDestination? = nil) -> PublishSession? {
    guard isUnlocked, let project = selectedProject else { return nil }
    let session = PublishSession(
      vaultID: project.id,
      projectName: project.name,
      environments: orderedEnvironmentNames(for: project),
      sourceEnvironment: selectedEnvironment,
      saved: destination,
      dependencies: publishDependencies(for: project.id))
    publishSessions.removeAll { $0.session == nil }
    publishSessions.append(WeakPublishSession(session: session))
    return session
  }

  /// What a Publish sheet for the project reads its values with, and publishes through.
  func publishDependencies(for projectID: String) -> PublishSession.Dependencies {
    PublishSession.Dependencies(
      snapshot: { [weak self] environment, contents in
        await self?.publishSnapshot(projectID: projectID, environment: environment, contents: contents)
      },
      confirm: { [weak self] reason in await self?.confirmSensitiveAction(reason: reason) ?? false },
      publishing: publishing,
      connections: platformConnectionStore,
      credentials: platformCredentials,
      vercel: platformClient,
      coolify: coolifyClient,
      netlify: netlifyClient,
      github: githubClient,
      cloudflare: cloudflareClient,
      issuer: { [weak self] in self?.appEnvironment.issuer },
      didChange: { [weak self] in Task { await self?.loadPublishDestinations(for: projectID) } })
  }

  /// A cleanup of a retired platform connection changed what the Platforms page shows.
  private func platformCleanupChanged() {
    forgetConnectionDetails()
    if isUnlocked, accountPage == .platforms { platforms.load() }
  }

  /// The environment's saved values once local changes are read, with
  /// lpm.json's rules and, when `contents` asks for it, those values' check,
  /// while the project is open. The check is the one made for these values:
  /// one still running for them is waited for, and one made for other values
  /// isn't taken for theirs. A check made here for the project's current
  /// values is kept for the rest of the app.
  private func publishSnapshot(
    projectID: String,
    environment: String,
    contents: PublishSession.Snapshot.Contents
  ) async -> PublishSession.Snapshot? {
    await waitForLocalStateRefresh()
    guard canUseLocalSecrets, selectedProjectId == projectID, let project = selectedProject,
      project.environmentNames.contains(environment)
    else { return nil }
    let values = project.environments[environment] ?? [:]
    let rules = publishRules(projectID: projectID)
    guard contents == .checked, case .known(let overview) = rules, overview.effectiveSchema != nil, project.hasLoadedEnvironments
    else {
      return PublishSession.Snapshot(values: values, rules: rules, check: nil)
    }
    let inputs = ValueCheckInputs(values: project.workspaceSnapshotIdentity, rules: overview)
    if valueCheckInputs[projectID] == inputs {
      if valueChecks[projectID] == nil, let running = valueCheckTasks[projectID] { await running.value }
      if valueCheckInputs[projectID] == inputs, let check = valueChecks[projectID] {
        return PublishSession.Snapshot(values: values, rules: rules, check: check.environments[environment])
      }
    }
    let check = await valueCheckWorker.check(rules: overview, environments: project.environments)
    if let check, valueCheckInputs[projectID] == inputs, valueChecks[projectID] == nil {
      valueCheckTasks.removeValue(forKey: projectID)?.cancel()
      valueChecks[projectID] = check
    }
    return PublishSession.Snapshot(values: values, rules: rules, check: check?.environments[environment])
  }

  /// lpm.json's saved rules; an unsaved draft isn't published by.
  private func publishRules(projectID: String) -> PublishSession.Rules {
    switch keyDescriptions[projectID]?.schema {
    case .loaded(let overview, _)?: .known(overview)
    case .noFolder?: .none
    case .unreadable?, nil: .unreadable
    }
  }

  /// The signed-in LPM session a platform connection starts with, while unlocked.
  func platformSession() async -> PlatformSession? {
    guard isUnlocked, let user = currentUser else { return nil }
    let environment = appEnvironment
    let generation = vaultSessionGeneration
    let resolution = await resolveAuthToken(environment.registryURL, environment.baseURL)
    guard let token = resolution.token, isUnlocked, generation == vaultSessionGeneration,
      environment == appEnvironment, currentUser?.id == user.id
    else { return nil }
    return PlatformSession(token: token, principalID: user.id, baseURL: environment.baseURL, issuer: environment.issuer)
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

  /// A project on this Mac that `openProject(id:)` can open: a personal one, or
  /// one of an organization the person belongs to.
  func openableProject(id projectId: String) -> VaultProject? {
    guard let project = projects.first(where: { $0.id == projectId }) else { return nil }
    if let slug = vaultOrgAssociations[projectId], !userOrgs.contains(where: { $0.slug == slug }) { return nil }
    return project
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
    activeVaults.first?.id
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
    preferences: UserDefaults = .standard,
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
    platformConnect: PlatformConnections.Connect? = nil,
    netlifyConnect: PlatformConnections.ConnectNetlify? = nil,
    githubConnect: PlatformConnections.ConnectGitHub? = nil,
    cloudflareConnect: PlatformConnections.ConnectCloudflare? = nil,
    platformClient: (@Sendable (String) -> any VercelClientProtocol)? = nil,
    coolifyClient: CoolifyConnector.ClientFactory? = nil,
    netlifyClient: NetlifyConnector.ClientFactory? = nil,
    githubClient: GitHubConnector.ClientFactory? = nil,
    cloudflareClient: RenewingCloudflareClient.ClientFactory? = nil,
    platformRevoker: (any PlatformTokenRevoking)? = nil,
    platformURLOpener: (@MainActor @Sendable (URL) -> Void)? = nil,
    valueChecker: ProjectEnvValueCheckWorker.Checker? = nil,
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
    autoLockDuration: TimeInterval = VaultConstants.vaultAutoLockDuration,
    schemaEditNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    projectIconsDirectory: URL = ProjectIconStore.defaultImagesDirectory,
    clipboard: ClipboardManager = ClipboardManager()
  ) {
    self.keychainService = keychainService
    self.clipboard = clipboard
    self.projectIcons = ProjectIconStore(preferences: preferences, imagesDirectory: projectIconsDirectory)
    self.persistence = VaultPersistenceCoordinator(service: keychainService)
    self.publishing = PublishingStore(service: keychainService)
    self.platformConnect = platformConnect
    self.netlifyConnect = netlifyConnect
    self.githubConnect = githubConnect
    self.cloudflareConnect = cloudflareConnect
    self.platformRevoker = platformRevoker
    self.platformConnectionStore = PlatformConnectionStore(service: keychainService)
    self.platformClient = platformClient ?? { VercelClient(token: $0) }
    self.coolifyClient = coolifyClient ?? { CoolifyClient(instance: $0, token: $1) }
    self.netlifyClient = netlifyClient ?? { NetlifyClient(token: $0) }
    self.githubClient = githubClient ?? { GitHubClient(token: $0) }
    self.cloudflareClient = cloudflareClient ?? { CloudflareClient(token: $0) }
    self.platformURLOpener = platformURLOpener
    self.valueCheckWorker = valueChecker.map(ProjectEnvValueCheckWorker.init(checker:)) ?? ProjectEnvValueCheckWorker()
    self.biometricService = biometricService
    self.injectedAPIService = apiService
    self.apiServiceFactory = apiServiceFactory
    self.importServiceFactory = importServiceFactory
    self.projectListServiceFactory = projectListServiceFactory
    self.orgSyncServiceFactory = orgSyncServiceFactory
    self.personalSyncServiceFactory = personalSyncServiceFactory
    self.envFileImportService = envFileImportService
    self.envFileExportService = envFileExportService
    self.preferences = preferences
    self.projectOrder = preferences.stringArray(forKey: Self.projectOrderKey) ?? []
    self.lastBackup = VaultBackupRecord(defaults: preferences)
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
    self.schemaEditNow = schemaEditNow

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
      environmentLoadTask = Task { await loadAccount() }
    }

    /// The account load the latest environment switch started.
    @ObservationIgnored private(set) var environmentLoadTask: Task<Void, Never>?
  #endif

  // MARK: - Load

  private(set) var isRefreshingLocalState = false
  /// Set when a refresh fails. Cached values may be stale, so copying,
  /// revealing, and exporting pause until a refresh succeeds.
  private(set) var localStateRefreshError: String?
  private var localStateRefreshTask: Task<Void, Never>?
  private var localStateRefreshID: UUID?
  private var localStateRefreshGeneration = 0
  private var localStateRefreshDeferred = false
  private static let localStateRefreshPassLimit = 8

  var canUseLocalSecrets: Bool {
    isUnlocked && localStateRefreshError == nil && !isLoadingProjects && !isLoadingSelectedProject
  }

  /// Reloads local state that the LPM CLI may have changed, without extending
  /// the idle deadline. Concurrent requests share one refresh, and a request
  /// made during a CLI approval change runs when that change finishes.
  func refreshLocalState() async {
    if isUnlocked { projectIcons.revalidate() }
    await startLocalStateRefresh()?.value
  }

  /// Returns once no refresh is running, so reads see refreshed values.
  func waitForLocalStateRefresh() async {
    while let task = localStateRefreshTask { await task.value }
  }

  @discardableResult
  private func startLocalStateRefresh() -> Task<Void, Never>? {
    guard isUnlocked, !isLoadingProjects else { return nil }
    if let task = localStateRefreshTask { return task }
    guard !isChangingCliAccess else {
      localStateRefreshDeferred = true
      return nil
    }
    localStateRefreshDeferred = false
    let id = UUID()
    localStateRefreshID = id
    isRefreshingLocalState = true
    localStateRefreshError = nil
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runLocalStateRefresh(id: id)
    }
    localStateRefreshTask = task
    return task
  }

  /// Reads a snapshot and publishes it unless a newer local change, project
  /// selection, or account switch superseded it; then it reads again.
  private func runLocalStateRefresh(id: UUID) async {
    defer {
      if localStateRefreshID == id {
        localStateRefreshID = nil
        localStateRefreshTask = nil
        isRefreshingLocalState = false
      }
    }
    let session = vaultSessionGeneration
    for _ in 0..<Self.localStateRefreshPassLimit {
      guard !Task.isCancelled, isUnlocked, session == vaultSessionGeneration else { return }
      localStateRefreshGeneration &+= 1
      let generation = localStateRefreshGeneration
      let projectID = selectedProjectId
      let account = selectedAccount
      let policyRevisions = cliAccessProjectRevisions
      invalidateSelectedProjectLoad()
      cliAccessLoadTask?.cancel()
      cliAccessLoadGeneration &+= 1
      await waitForProjectMutations()
      guard generation == localStateRefreshGeneration else { continue }
      let result = await persistence.refreshSnapshot(selectedProjectID: projectID)
      guard !Task.isCancelled, isUnlocked, session == vaultSessionGeneration else { return }
      guard generation == localStateRefreshGeneration, selectedProjectId == projectID,
        selectedAccount == account
      else { continue }
      let snapshot: VaultPersistenceSnapshot
      switch result {
      case .success(let loaded): snapshot = loaded
      case .failure(let failure):
        failLocalStateRefresh(VaultLoadFailure(failure))
        return
      }
      let update = await workspaceSnapshotBuilder.buildIncremental(
        currentProjects: snapshot.projects,
        existingSnapshots: workspaceSnapshots.filter { $0.key == projectID }
      )
      guard !Task.isCancelled, isUnlocked, session == vaultSessionGeneration else { return }
      guard let update else {
        failLocalStateRefresh(.unavailable)
        return
      }
      guard generation == localStateRefreshGeneration, selectedProjectId == projectID,
        selectedAccount == account
      else { continue }
      pendingWorkspaceSnapshots = update.snapshots
      projects = snapshot.projects
      syncMetadata = snapshot.syncMetadata
      vaultOrgAssociations = snapshot.orgAssociations
      publishCliAccessSnapshot(snapshot.cliAccess, previousRevisions: policyRevisions)
      loadEnvironmentOrders()
      reconcileNavigationState()
      selectedProjectCliAccess = selectedProjectId.flatMap { projectCliAccess[$0] }
      reloadKeyDescriptions()
      return
    }
    failLocalStateRefresh(.unavailable)
  }

  /// Pauses secret actions after a failed refresh. A selected project without
  /// loaded values shows why it could not load instead of an empty workspace.
  private func failLocalStateRefresh(_ failure: VaultLoadFailure) {
    localStateRefreshError = Self.localStateRefreshFailure
    if let selectedProject, !selectedProject.hasLoadedEnvironments {
      selectedProjectLoadFailure = failure
    }
  }

  private static let localStateRefreshFailure =
    "Couldn't reload changes from the LPM CLI. Copying, revealing, and exporting are paused until a refresh succeeds."

  /// Makes an in-flight refresh read again instead of publishing a snapshot
  /// that a newer local change or selection has superseded.
  private func invalidateLocalStateRefresh() {
    guard localStateRefreshTask != nil else { return }
    localStateRefreshGeneration &+= 1
  }

  private func cancelLocalStateRefresh() {
    localStateRefreshTask?.cancel()
    localStateRefreshTask = nil
    localStateRefreshID = nil
    localStateRefreshDeferred = false
    isRefreshingLocalState = false
  }

  private func beginSelectedProjectLoadIfNeeded() {
    selectedProjectLoadFailure = nil
    cancelCliAccessChange()
    selectedProjectCliAccess = nil
    cliAccessLoadTask?.cancel()
    cliAccessLoadTask = Task { [weak self] in await self?.refreshCliAccess() }
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
        self.normalizeSelectedEnvironment()
      case .success(nil):
        self.error = "The selected env project no longer exists in Keychain."
        self.selectedProjectId = nil
      case .failure(let failure):
        self.selectedProjectLoadFailure = VaultLoadFailure(failure)
      }
      if generation == self.selectedProjectLoadGeneration {
        self.isLoadingSelectedProject = false
        self.selectedProjectLoadTask = nil
      }
    }
    selectedProjectLoadTask = task
  }

  func refreshCliAccess() async {
    guard !Task.isCancelled else { return }
    cliAccessLoadGeneration &+= 1
    let generation = cliAccessLoadGeneration
    selectedProjectCliAccess = nil
    guard isUnlocked, let projectID = selectedProjectId,
      projectBelongsToSelectedAccount(projectID)
    else { return }
    let session = vaultSessionGeneration
    let revision = cliAccessProjectRevisions[projectID]
    let result = await persistence.cliAccess(vaultId: projectID)
    guard !Task.isCancelled, generation == cliAccessLoadGeneration,
      session == vaultSessionGeneration, isUnlocked, selectedProjectId == projectID,
      cliAccessProjectRevisions[projectID] == revision
    else { return }
    switch result {
    case .success(let access):
      selectedProjectCliAccess = access
      projectCliAccess[projectID] = access
    case .failure(let failure):
      projectCliAccess.removeValue(forKey: projectID)
      error = "Could not load CLI approval. \(failure.description)"
    }
  }

  func retrySelectedProjectLoad() {
    guard isUnlocked, !isLoadingSelectedProject, selectedProjectLoadFailure != nil else { return }
    // After a failed refresh the shared state is stale too, so retry the refresh,
    // which also reloads the selected project.
    if localStateRefreshError != nil {
      startLocalStateRefresh()
    } else {
      beginSelectedProjectLoadIfNeeded()
    }
  }

  func changeCliAccess(to access: VaultCliAccess) async {
    let write = writes.begin()
    defer { writes.end(write) }
    guard isUnlocked, let projectID = selectedProjectId,
      projectBelongsToSelectedAccount(projectID), selectedProjectCliAccess != nil,
      selectedProjectCliAccess != access, !isChangingCliAccess
    else { return }
    invalidateProjectLoad()
    let requestID = UUID()
    let authorization = CliAccessChangeAuthorization()
    let session = vaultSessionGeneration
    cliAccessChangeID = requestID
    cliAccessProjectRevisions[projectID] = requestID
    cliAccessChangeAuthorization = authorization
    cliAccessLoadTask?.cancel()
    cliAccessLoadGeneration &+= 1
    defer {
      if cliAccessChangeID == requestID {
        cliAccessChangeID = nil
        cliAccessChangeAuthorization = nil
      }
      if localStateRefreshDeferred, !isChangingCliAccess { startLocalStateRefresh() }
    }
    await waitForProjectMutations()
    guard !Task.isCancelled, session == vaultSessionGeneration, isUnlocked,
      selectedProjectId == projectID, cliAccessChangeID == requestID
    else { return }
    let result = await persistence.setCliAccess(vaultId: projectID, access: access, authorization: authorization)
    guard session == vaultSessionGeneration, isUnlocked,
      cliAccessProjectRevisions[projectID] == requestID,
      projects.contains(where: { $0.id == projectID })
    else { return }
    switch result {
    case .success(let saved):
      projectCliAccess[projectID] = saved
      guard !Task.isCancelled, selectedProjectId == projectID,
        cliAccessChangeID == requestID
      else { return }
      selectedProjectCliAccess = saved
      error = nil
    case .failure(let failure):
      guard !Task.isCancelled, selectedProjectId == projectID,
        cliAccessChangeID == requestID
      else { return }
      await refreshCliAccess()
      guard !Task.isCancelled, session == vaultSessionGeneration, isUnlocked,
        selectedProjectId == projectID, cliAccessChangeID == requestID
      else { return }
      error = "Could not change CLI approval. \(failure.description)"
    }
  }

  private func publishCliAccessSnapshot(
    _ policies: [String: VaultCliAccess],
    previousRevisions: [String: UUID]
  ) {
    var merged = policies
    for (projectID, revision) in cliAccessProjectRevisions
      where previousRevisions[projectID] != revision {
      merged[projectID] = projectCliAccess[projectID]
    }
    projectCliAccess = merged
  }

  private func cancelCliAccessChange() {
    cliAccessChangeAuthorization?.invalidate()
    cliAccessChangeAuthorization = nil
    cliAccessChangeID = nil
  }

  private func invalidateSelectedProjectLoad() {
    selectedProjectLoadFailure = nil
    selectedProjectLoadGeneration &+= 1
    selectedProjectLoadTask?.cancel()
    selectedProjectLoadTask = nil
    isLoadingSelectedProject = false
  }

  /// Load a coherent Keychain snapshot. A newer load, lock, or mutation
  /// invalidates this generation before it can publish decrypted state.
  /// A draft-owned recovery also requires its original account session.
  @discardableResult
  func loadProjects(ownedByKeyDraftGeneration: Int? = nil) async -> Bool {
    cancelLocalStateRefresh()
    invalidateSelectedProjectLoad()
    projectLoadGeneration &+= 1
    let generation = projectLoadGeneration
    projectLoadTask?.cancel()
    isLoadingProjects = true

    let policyRevisions = cliAccessProjectRevisions
    let task = Task { [weak self, persistence] in
      let result = await persistence.loadSnapshot()
      guard !Task.isCancelled, let self,
        generation == self.projectLoadGeneration
      else { return }
      guard ownedByKeyDraftGeneration == nil || (ownedByKeyDraftGeneration == self.keyDrafts.generation && self.isUnlocked) else {
        self.isLoadingProjects = false
        self.projectLoadTask = nil
        return
      }
      guard case .success(let snapshot) = result else {
        if case .failure(let failure) = result {
          self.error = "Could not load the protected vault state. \(failure.description)"
          if !self.isUnlocked { self.unlockFailure = VaultLoadFailure(failure) }
        }
        self.isLoadingProjects = false
        self.projectLoadTask = nil
        return
      }
      guard !Task.isCancelled, generation == self.projectLoadGeneration else { return }
      self.workspaceSnapshots = [:]
      self.pendingWorkspaceSnapshots = [:]
      self.projects = snapshot.projects
      self.publishCliAccessSnapshot(snapshot.cliAccess, previousRevisions: policyRevisions)
      self.syncMetadata = snapshot.syncMetadata
      self.vaultOrgAssociations = snapshot.orgAssociations
      self.error = nil
      self.localStateRefreshError = nil
      self.lastSuccessfulProjectLoadGeneration = generation
      self.forgetPreferences(ofVaultsOutside: Set(snapshot.projects.lazy.map(\.id)))
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
    let write = writes.begin()
    defer { writes.end(write) }
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
      let policyRevision = cliAccessProjectRevisions[project.id]
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
        var checkpointWarning: String?
        if await hasCurrentCloudAuthorization(authority), orgSlug == nil {
          do { try await service.rememberPersonalKeys(payload) }
          catch { checkpointWarning = "The import succeeded, but the local key checkpoint could not be saved: \(error.localizedDescription)" }
        }
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
        if cliAccessProjectRevisions[project.id] == policyRevision {
          projectCliAccess[project.id] = committed.cliAccess
        }
        applySyncMetadata(committed.syncMetadata, for: project.id)
        vaultOrgAssociations = committed.orgAssociations
        if ownsPresentation { openProject(id: project.id) }
        if ownsPresentation { error = checkpointWarning ?? committed.warning }
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

    let policyRevision = cliAccessProjectRevisions[vaultId]
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
      if cliAccessProjectRevisions[vaultId] == policyRevision {
        projectCliAccess[vaultId] = creationRecord.cliAccess
      }
      vaultOrgAssociations = creationRecord.orgAssociations
      openProject(id: vaultId)
    } else {
      guard
        await addProjectWithVaultId(
          vaultId: vaultId,
          name: normalizedName,
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
    let write = writes.begin()
    defer { writes.end(write) }
    guard let associations = await persistence.associate(vaultId: vaultId, orgSlug: orgSlug)
    else {
      error = "Could not save the organization association."
      return false
    }
    vaultOrgAssociations = associations
    reconcileNavigationState()
    return true
  }

  /// Adds a project without a folder under a specific vault ID. Returns only
  /// after the Keychain write and in-memory selection are complete; a folder is
  /// linked later through Connect CLI.
  @discardableResult
  func addProjectWithVaultId(
    vaultId: String,
    name: String,
    environments: [String: [String: String]],
    orgSlug: String? = nil
  ) async -> Bool {
    let write = writes.begin()
    defer { writes.end(write) }
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
      path: "",
      environments: environments
    )

    // Run Keychain write off main thread to prevent UI freeze
    let policyRevision = cliAccessProjectRevisions[vaultId]
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
      if cliAccessProjectRevisions[vaultId] == policyRevision {
        projectCliAccess[vaultId] = committed.cliAccess
      }
      vaultOrgAssociations = committed.orgAssociations
      openProject(id: vaultId)
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

  /// Renames a project from `expectedName`, and returns once the rename is
  /// saved or can't be; `.changed` when the name isn't `expectedName` anymore.
  /// The name is in the index the LPM CLI shares, so its folder and CLI
  /// connection stay as they are.
  func renameProject(_ project: VaultProject, from expectedName: String, to name: String) async -> ProjectMutationOutcome {
    guard isUnlocked, let normalizedName = EnvValidation.normalizedProjectName(name),
      let current = projects.first(where: { $0.id == project.id })
    else { return .unavailable }
    return await withCheckedContinuation { continuation in
      enqueueProjectMutation(
        base: current,
        mutation: .renameProject(expectedName: expectedName, replacement: normalizedName),
        reportsFailures: false,
        afterCompletion: { continuation.resume(returning: $0) }
      )
    }
  }

  /// Remove from sidebar only — Keychain data stays.
  /// Re-adding the same folder will restore the project.
  func removeFromSidebar(_ project: VaultProject) {
    cancelLocalEnvImports(projectId: project.id)
    invalidateProjectLoad()
    let write = writes.begin()
    Task { [weak self, persistence, writes] in
      defer { writes.end(write) }
      guard await persistence.removeFromSidebar(vaultId: project.id) else {
        self?.error = "Could not remove the env project from the protected sidebar index."
        return
      }
      guard let self else { return }
      forgetPreferences(ofVault: project.id)
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
    let write = writes.begin()
    defer { writes.end(write) }
    cancelLocalEnvImports(projectId: project.id)
    invalidateProjectLoad()
    let sessionGeneration = vaultSessionGeneration
    let policyRevisions = cliAccessProjectRevisions
    let wasSelected = selectedProjectId == project.id
    let snapshot: VaultPersistenceSnapshot
    switch await persistence.deleteProjectAndMetadata(vaultId: project.id) {
    case .success(let persisted):
      snapshot = persisted
      if case .failure(let failure) = await publishing.deleteOrphanedRecords(among: [project.id]) {
        error = "The local copy was deleted, but its publish destinations couldn't be removed: \(failure)"
      }
    case .failure(let persistenceError):
	  if case .transactionOutcomeIndeterminate = persistenceError {
        _ = await publishing.deleteOrphanedRecords(among: [project.id])
        lock()
        error =
          "The local deletion could not be rolled back completely. The vault was locked; unlock to reload durable state."
      } else {
        error = "Could not delete the local Keychain copy. The env project was kept."
      }
      return false
    }

    forgetPreferences(ofVault: project.id)
    // Durable deletion remains successful if locking won the race. Unlocking
    // will load the new snapshot; never republish its plaintext while locked.
    guard sessionGeneration == vaultSessionGeneration, isUnlocked else { return true }
    let shouldSelectFallback = wasSelected && selectedProjectId == project.id
    projects = snapshot.projects
    publishCliAccessSnapshot(snapshot.cliAccess, previousRevisions: policyRevisions)
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
    guard selectedProjectId == projectId,
      let project = projects.first(where: { $0.id == projectId }),
      EnvValidation.isValidEnvironmentName(name),
      secrets.keys.allSatisfy(EnvValidation.isValidVariableName),
      project.environments[name] == nil
    else { return false }
    switch await insertEnvironment(name, secrets: secrets, into: project) {
    case .success: return true
    case .failure(.cancelled): return false
    case .failure(.persistence(let message)): error = message
    case .failure(let failure): error = failure.localizedDescription
    }
    return false
  }

  /// Creates the new environment `review` shows, leaving out the keys in
  /// `skippingKeys`, unless its name was taken meanwhile.
  func createEnvironment(
    from review: EnvFileImportReview, skippingKeys: Set<String> = []
  ) async -> Result<Void, EnvFileImportError> {
    guard isUnlocked else { return .failure(.vaultLocked) }
    let target = LocalEnvImportTarget(projectId: review.projectId, environment: review.environment)
    guard review.createsEnvironment, review.sessionGeneration == vaultSessionGeneration,
      localEnvReviewIDs[target] == review.id,
      skippingKeys.isSubset(of: review.addedKeys)
    else { return .failure(.cancelled) }
    guard selectedProjectId == review.projectId,
      let project = projects.first(where: { $0.id == review.projectId }),
      project.name == review.projectName, project.path == review.projectPath
    else { return .failure(.targetUnavailable) }
    guard project.environments[review.environment] == nil else {
      return .failure(.environmentExists(review.environment))
    }
    let secrets = skippingKeys.isEmpty
      ? review.imported.secrets : review.imported.secrets.filter { !skippingKeys.contains($0.key) }
    return await insertEnvironment(review.environment, secrets: secrets, into: project)
  }

  /// Persists `name`, a new environment holding `secrets`, in `project`, then
  /// shows it. A review of that environment ends here, whatever the outcome.
  private func insertEnvironment(
    _ name: String, secrets: [String: String], into project: VaultProject
  ) async -> Result<Void, EnvFileImportError> {
    let write = writes.begin()
    defer { writes.end(write) }
    let projectId = project.id
    let sessionGeneration = vaultSessionGeneration
    let target = LocalEnvImportTarget(projectId: projectId, environment: name)
    let requestId = UUID()
    localEnvCreationRequests[target] = requestId
    localEnvImportAuthority.begin(target, requestId: requestId)
    defer {
      if localEnvCreationRequests[target] == requestId {
        localEnvCreationRequests.removeValue(forKey: target)
        localEnvReviewIDs.removeValue(forKey: target)
      }
      localEnvImportAuthority.complete(target, requestId: requestId)
    }
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
    let persisted: LocalEnvImportPersistenceCommit
    switch commit {
    case .success(let commit): persisted = commit
    case .failure(let persistenceError): return .failure(.persistence(persistenceError.description))
    case .targetUnavailable, .reviewChanged: return .failure(.targetUnavailable)
    case .environmentExists: return .failure(.environmentExists(name))
    case .caseInsensitiveCollision: return .failure(.caseInsensitiveCollisionWithExisting)
    case .cancelled: return .failure(.cancelled)
    }
    guard sessionGeneration == vaultSessionGeneration, isUnlocked,
      projects.contains(where: { $0.id == projectId }),
      projects.first(where: { $0.id == projectId })?.environments[name] == nil
    else {
      // Persistence is intentionally non-cancellable. Report its durable
      // success without republishing plaintext into stale or locked UI.
      return .success(())
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
    return .success(())
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
      rawTextDrafts.removeValue(forKey: VaultEnvironmentTarget(projectId: projectId, environment: name))
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
      if let draft = rawTextDrafts.removeValue(forKey: VaultEnvironmentTarget(projectId: projectId, environment: oldName)) {
        rawTextDrafts[VaultEnvironmentTarget(projectId: projectId, environment: newName)] = draft.renamed(to: newName)
      }
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

  /// Compares `imported`, read for the selected environment, with the
  /// environment's durable values, which the review keeps as its baseline.
  /// `creating` reviews it as `environment`, a new environment, instead, which
  /// needn't be the one shown.
  func prepareEnvImport(
    _ imported: ImportedEnvFile, from source: EnvImportSource, to projectId: String, environment: String,
    creating: Bool = false
  ) async -> Result<EnvFileImportReview, EnvFileImportError> {
    guard isUnlocked else { return .failure(.vaultLocked) }
    guard selectedProjectId == projectId,
      let project = projects.first(where: { $0.id == projectId })
    else { return .failure(.targetUnavailable) }
    if creating {
      guard EnvValidation.isValidEnvironmentName(environment) else { return .failure(.targetUnavailable) }
      guard project.environments[environment] == nil else { return .failure(.environmentExists(environment)) }
    } else {
      guard selectedEnvironment == environment, project.environments[environment] != nil
      else { return .failure(.targetUnavailable) }
    }
    let target = LocalEnvImportTarget(projectId: projectId, environment: environment)
    let reviewID = UUID()
    let session = vaultSessionGeneration
    func isWanted() -> Bool {
      isUnlocked && session == vaultSessionGeneration && localEnvReviewIDs[target] == reviewID
        && selectedProjectId == projectId && (creating || selectedEnvironment == environment) && !Task.isCancelled
    }
    cancelLocalEnvImport(projectId: projectId, environment: environment)
    localEnvReviewIDs[target] = reviewID
    let durable = await persistence.loadProject(vaultId: projectId)
    guard isWanted() else { return .failure(.cancelled) }
    switch durable {
    case .success(let current?):
      guard current.name == project.name, current.path == project.path else {
        return .failure(.targetUnavailable)
      }
      do {
        let review = try await Task.detached(priority: .userInitiated) {
          try EnvFileImportReview(id: reviewID, project: current, environment: environment, creating: creating,
            source: source, sessionGeneration: session, imported: imported)
        }.value
        guard isWanted() else { return .failure(.cancelled) }
        return .success(review)
      } catch let failure as EnvFileImportError { return .failure(failure) }
      catch { return .failure(.readFailed) }
    case .success(nil): return .failure(.targetUnavailable)
    case .failure(let failure): return .failure(.persistence(failure.description))
    }
  }

  /// Whether `review` still holds: a new environment's while its name is
  /// free, and an import's while the environment it goes into is shown.
  func isCurrentEnvFileImportReview(_ review: EnvFileImportReview) -> Bool {
    let target = LocalEnvImportTarget(projectId: review.projectId, environment: review.environment)
    guard isUnlocked, !isShowingAccountPage,
      review.sessionGeneration == vaultSessionGeneration,
      localEnvReviewIDs[target] == review.id,
      selectedProjectId == review.projectId,
      let project = projects.first(where: { $0.id == review.projectId })
    else { return false }
    return review.createsEnvironment
      ? project.environments[review.environment] == nil
      : selectedEnvironment == review.environment && project.environments[review.environment] != nil
  }

  /// Imports what `review` compared, keeping existing values except
  /// `replacingKeys`, and leaving out the new keys in `skippingKeys`. A new
  /// environment's review is created with `createEnvironment(from:skippingKeys:)`.
  func applyEnvFileImport(
    _ review: EnvFileImportReview, replacingKeys: Set<String>, skippingKeys: Set<String> = []
  ) async -> Result<EnvironmentChangeReceipt, EnvFileImportError> {
    let target = LocalEnvImportTarget(projectId: review.projectId, environment: review.environment)
    guard isUnlocked else { return .failure(.vaultLocked) }
    guard !review.createsEnvironment, review.sessionGeneration == vaultSessionGeneration,
      localEnvReviewIDs[target] == review.id,
      replacingKeys.isSubset(of: review.changedKeys),
      skippingKeys.isSubset(of: review.addedKeys)
    else { return .failure(.cancelled) }
    let result = await commitEnvFileImport(review, replacingKeys: replacingKeys, skippingKeys: skippingKeys)
    if case .success = result, localEnvReviewIDs[target] == review.id {
      localEnvReviewIDs.removeValue(forKey: target)
    }
    return result
  }

  /// Persists the reviewed file into its captured destination, keeping existing
  /// values except approved replacements, then publishes the durable project.
  /// The commit fails with `reviewChanged` when the destination no longer
  /// matches the reviewed baseline, so concurrent CLI edits are never replaced.
  private func commitEnvFileImport(
    _ review: EnvFileImportReview, replacingKeys: Set<String>, skippingKeys: Set<String>
  ) async -> Result<EnvironmentChangeReceipt, EnvFileImportError> {
    let write = writes.begin()
    defer { writes.end(write) }
    let projectId = review.projectId
    let environment = review.environment
    guard selectedProjectId == projectId, selectedEnvironment == environment,
      projects.contains(where: { $0.id == projectId && $0.environments[environment] != nil })
    else { return .failure(.targetUnavailable) }
    guard !Task.isCancelled else { return .failure(.cancelled) }

    let target = LocalEnvImportTarget(projectId: projectId, environment: environment)
    let requestId = UUID()
    let sessionGeneration = vaultSessionGeneration
    localEnvImportRequests[target] = requestId
    localEnvImportAuthority.begin(target, requestId: requestId)
    defer {
      if localEnvImportRequests[target] == requestId {
        localEnvImportRequests.removeValue(forKey: target)
      }
      localEnvImportAuthority.complete(target, requestId: requestId)
    }

    invalidateProjectLoad()
    let commit = await withTaskCancellationHandler {
      await persistence.importSecrets(
        projectId: projectId,
        projectName: review.projectName,
        projectPath: review.projectPath,
        environment: environment,
        secrets: skippingKeys.isEmpty ? review.imported.secrets : review.imported.secrets.filter { !skippingKeys.contains($0.key) },
        expectedSecrets: review.baseline,
        replacingKeys: replacingKeys,
        requestId: requestId,
        authority: localEnvImportAuthority
      )
    } onCancel: { [localEnvImportAuthority] in
      localEnvImportAuthority.cancel(target, requestId: requestId)
    }

    switch commit {
    case .success(let persisted):
      let receipt = EnvironmentChangeReceipt(
        projectId: projectId, environment: environment, before: review.baseline,
        after: persisted.project.environments[environment] ?? [:])
      guard sessionGeneration == vaultSessionGeneration,
        isUnlocked,
        projects.contains(where: { $0.id == projectId })
      else {
        // The transaction crossed its synchronous commit point. Keep
        // locked/stale UI clear, but report the durable success.
        return .success(receipt)
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
      return .success(receipt)
    case .targetUnavailable, .environmentExists:
      return .failure(.targetUnavailable)
    case .reviewChanged:
      return .failure(.reviewChanged)
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
  }

  /// Puts an environment that an import or a Raw text save changed back as
  /// it was, as long as nothing has changed it since, as the LPM CLI could have.
  func undoEnvironmentChange(_ receipt: EnvironmentChangeReceipt) async -> ProjectMutationOutcome {
    guard isUnlocked, receipt.changed, selectedProjectId == receipt.projectId,
      let project = projects.first(where: { $0.id == receipt.projectId }),
      project.environments[receipt.environment] != nil
    else { return .unavailable }
    recordUserActivity()
    return await withCheckedContinuation { continuation in
      enqueueProjectMutation(
        base: project,
        mutation: .restoreEnvironment(name: receipt.environment, expectedSecrets: receipt.after, restored: receipt.before),
        reportsFailures: false
      ) { continuation.resume(returning: $0) }
    }
  }

  // MARK: - Raw text editing

  /// Why the selected environment can't be edited as Raw text now, or nil when it can.
  var rawTextEditBlocker: String? {
    guard canUseLocalSecrets, let project = selectedProject, project.environments[selectedEnvironment] != nil else {
      return "Values can't be edited right now"
    }
    // A key's edit can rename it or change it in every environment, which
    // the text, written from the saved values, would put back.
    let edited = keyDrafts.editedKeys(in: project.id).count
    guard edited == 0 else { return "Save or discard the unsaved edits of \(edited.counted("key")) first" }
    return nil
  }

  func rawTextDraft(for target: VaultEnvironmentTarget) -> VaultRawTextDraft? {
    rawTextDrafts[target]
  }

  /// Edits the selected environment as Raw text, from a line for each of its
  /// keys in `order`, or goes back to the edit that's already there.
  @discardableResult
  func beginRawTextEdit(order: [String]) -> Bool {
    guard rawTextEditBlocker == nil, let project = selectedProject, let values = project.environments[selectedEnvironment] else {
      return false
    }
    let target = VaultEnvironmentTarget(projectId: project.id, environment: selectedEnvironment)
    if rawTextDrafts[target] == nil {
      rawTextDrafts[target] = VaultRawTextDraft(target: target, baseline: values, order: order)
    }
    return true
  }

  func updateRawTextDraft(_ target: VaultEnvironmentTarget, text: String) {
    guard isUnlocked, rawTextSaves[target] == nil else { return }
    rawTextDrafts[target]?.text = text
  }

  func discardRawTextDraft(_ target: VaultEnvironmentTarget) {
    guard rawTextSaves[target] == nil else { return }
    rawTextDrafts.removeValue(forKey: target)
  }

  /// Compares a draft with its environment's values now, as after the LPM CLI changed them.
  func rebaseRawTextDraft(_ target: VaultEnvironmentTarget) {
    guard rawTextSaves[target] == nil,
      let values = projects.first(where: { $0.id == target.projectId })?.environments[target.environment]
    else { return }
    rawTextDrafts[target]?.baseline = values
  }

  /// Whether a draft is being saved, when it can't be changed.
  func isSavingRawText(_ target: VaultEnvironmentTarget) -> Bool {
    rawTextSaves[target] != nil
  }

  /// Writes a draft's values as its environment's, as long as the
  /// environment still has the values the draft was compared with.
  func saveRawTextDraft(_ target: VaultEnvironmentTarget) async -> VaultRawTextSaveOutcome {
    guard isUnlocked, let draft = rawTextDrafts[target], draft.canSave else { return .unavailable }
    return await writeRawText(target, expected: draft.baseline, values: draft.check.values)
  }

  func setRawTextReview(_ target: VaultEnvironmentTarget, on reviews: Bool) {
    guard rawTextSaves[target] == nil else { return }
    rawTextDrafts[target]?.reviewsBeforeSaving = reviews
  }

  /// What a draft with no problem line changes in its environment's values now.
  func reviewRawTextDraft(_ target: VaultEnvironmentTarget) -> VaultRawTextReview? {
    guard isUnlocked, let draft = rawTextDrafts[target], draft.check.problems.isEmpty,
      let current = projects.first(where: { $0.id == target.projectId })?.environments[target.environment]
    else { return nil }
    return VaultRawTextReview(draft: draft, current: current)
  }

  /// Makes a review's changes, but those of `skipping`, as long as the edit
  /// is still the one reviewed and the environment still has the values it
  /// was reviewed against.
  func applyRawTextReview(_ review: VaultRawTextReview, skipping: Set<String>) async -> VaultRawTextSaveOutcome {
    guard isUnlocked, let draft = rawTextDrafts[review.target], draft.check.values == review.edited else { return .unavailable }
    let values = review.values(skipping: skipping)
    guard values != review.current else { return .unavailable }
    return await writeRawText(review.target, expected: review.current, values: values)
  }

  /// Replaces an environment's values with `values` if it still has
  /// `expected`, which ends the environment's Raw text edit.
  private func writeRawText(_ target: VaultEnvironmentTarget, expected: [String: String], values: [String: String]) async
    -> VaultRawTextSaveOutcome
  {
    guard rawTextSaves[target] == nil,
      let project = projects.first(where: { $0.id == target.projectId }), project.environments[target.environment] != nil
    else { return .unavailable }
    let saveID = UUID()
    rawTextSaves[target] = saveID
    defer { if rawTextSaves[target] == saveID { rawTextSaves.removeValue(forKey: target) } }
    recordUserActivity()
    let outcome = await withCheckedContinuation { continuation in
      enqueueProjectMutation(
        base: project,
        mutation: .restoreEnvironment(name: target.environment, expectedSecrets: expected, restored: values),
        reportsFailures: false
      ) { continuation.resume(returning: $0) }
    }
    switch outcome {
    case .saved:
      rawTextDrafts.removeValue(forKey: target)
      return .saved(EnvironmentChangeReceipt(projectId: target.projectId, environment: target.environment, before: expected, after: values))
    case .changed: return .changed
    case .unavailable: return .unavailable
    case .failed(let message): return .failed(message)
    }
  }

  /// Reads variables from a file or pasted text for the selected project,
  /// off the main actor; a lock or another project cancels the read.
  func loadEnvImport(
    _ input: EnvImportInput,
    for projectId: String
  ) async -> Result<ImportedEnvFile, EnvFileImportError> {
    guard isUnlocked else { return .failure(.vaultLocked) }
    guard selectedProjectId == projectId,
      projects.contains(where: { $0.id == projectId })
    else { return .failure(.targetUnavailable) }
    let requestId = UUID()
    let sessionGeneration = vaultSessionGeneration
    let task = Task { [envFileImportService] in
      let imported = try await envFileImportService.load(input)
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
    localEnvImportRequests.removeValue(forKey: target)
    localEnvCreationRequests.removeValue(forKey: target)
    localEnvReviewIDs.removeValue(forKey: target)
    localEnvImportAuthority.cancel(target)
  }

  private func cancelLocalEnvImports(projectId: String? = nil) {
    let targets = Set(localEnvImportRequests.keys)
      .union(localEnvCreationRequests.keys)
      .union(localEnvReviewIDs.keys)
      .filter { projectId == nil || $0.projectId == projectId }
    for target in targets {
      localEnvImportRequests.removeValue(forKey: target)
      localEnvCreationRequests.removeValue(forKey: target)
      localEnvReviewIDs.removeValue(forKey: target)
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
    await addSecret(to: projectId, environments: [environment], key: key, value: value)
  }

  /// Adds the same value to every environment in `environments`, or to none of them.
  func addSecret(
    to projectId: String,
    environments: Set<String>,
    key: String,
    value: String
  ) async -> AddSecretResult {
    let write = writes.begin()
    defer { writes.end(write) }
    guard isUnlocked else { return .failure(.vaultLocked) }
    guard !environments.isEmpty else { return .failure(.noEnvironments) }
    guard EnvValidation.isValidVariableName(key) else { return .failure(.invalidName) }
    let sessionGeneration = vaultSessionGeneration
    guard let project = projects.first(where: { $0.id == projectId }) else {
      return .failure(.targetUnavailable)
    }
    for environment in environments.sorted() {
      guard let secrets = project.environments[environment] else {
        return .failure(.targetUnavailable)
      }
      guard secrets[key] == nil else { return .failure(.duplicate) }
      if let existingKey = EnvValidation.caseInsensitiveCollision(for: key, in: secrets.keys) {
        return .failure(.caseInsensitiveCollision(existingKey: existingKey))
      }
    }

    invalidateProjectLoad()
    let commit = await persistence.addSecret(
      projectId: projectId,
      projectName: project.name,
      projectPath: project.path,
      environments: environments,
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

  /// Saves a key's draft: its rename and values to the Keychain in one
  /// transaction. A rename coordinates its schema edit under both storage locks.
  /// Description-only edits follow the value save.
  /// A successful save ends the draft; a failed one keeps it, updated to the
  /// latest saved state, and throws the reason.
  func saveKeyDraft(_ id: VaultKeyDraft.ID) async throws(VaultKeyEditError) {
    let write = writes.begin()
    defer { writes.end(write) }
    guard let draft = keyDrafts.draft(id), let edit = keyDrafts.beginSave(id) else { return }
    let generation = keyDrafts.generation
    let description = draft.keyDescriptionChange
    var schemaChange = ProjectEnvSchemaFile.Change()
    var schemaFolder: String?
    if let pending = draft.pendingSchemaRename {
      schemaFolder = pending.folder
      schemaChange.rename = .init(from: pending.from, to: edit.newKey)
    } else {
      if let cached = keyDescriptions[id.projectID], let project = selectedProject,
        cached.folder != keyDescriptionFolder(for: project)
      {
        keyDrafts.finishSave(id, succeeded: false, projects: projects)
        reloadKeyDescriptions()
        throw .description("The project folder changed. Review its descriptions, then save again.", keySaved: false)
      }
      switch keyDescriptions[id.projectID]?.rules {
      case .success?:
        schemaFolder = keyDescriptions[id.projectID]?.folder
      case .failure(let failure)? where description != nil:
        keyDrafts.finishSave(id, succeeded: false, projects: projects)
        throw .description(failure.localizedDescription, keySaved: false)
      case nil where description != nil:
        keyDrafts.finishSave(id, succeeded: false, projects: projects)
        throw .description("lpm.json has not been read yet.", keySaved: false)
      default:
        if edit.isRename, let project = selectedProject {
          let folder = keyDescriptionFolder(for: project)
          if !folder.isEmpty { schemaFolder = folder }
        }
      }
      if edit.isRename, schemaFolder != nil {
        schemaChange.rename = .init(from: id.key, to: edit.newKey)
      }
    }
    if let description {
      var expected = draft.keyDescription?.baseline
      if edit.isRename, let descriptions = keyDescriptions[id.projectID],
        case .success(let rules) = descriptions.rules, rules.keys.contains(edit.newKey)
      {
        expected = rules.descriptions[edit.newKey] ?? ""
      }
      schemaChange.description = .init(key: edit.newKey, text: description, expectedText: expected)
    }

    if edit.isRename, let schemaFolder, !schemaFolder.isEmpty {
      guard isUnlocked, let project = selectedProject, project.id == id.projectID else {
        keyDrafts.finishSave(id, succeeded: false, projects: projects)
        throw .targetUnavailable
      }
      let result = await withCheckedContinuation { continuation in
        let identity = keyDescriptions[id.projectID].flatMap { $0.folder == schemaFolder ? $0.folderIdentity : nil }
        enqueueSchemaKeyRename(base: project, edit: edit, change: schemaChange, folder: schemaFolder, folderIdentity: identity) {
          continuation.resume(returning: $0)
        }
      }
      guard generation == keyDrafts.generation, isUnlocked else { throw .targetUnavailable }
      switch result {
      case .success:
        keyDrafts.finishSave(id, succeeded: true, projects: projects)
        return
      case .failure(let failure):
        keyDrafts.finishSave(id, succeeded: false, projects: projects)
        if let cached = keyDescriptions[id.projectID], case .success(let rules) = cached.rules {
          keyDrafts.receiveKeyDescriptions(rules.descriptions, ruleKeys: rules.keys, folder: cached.folder, in: id.projectID)
        }
        if let latest = projects.first(where: { $0.id == id.projectID }) { keyDrafts.edit(latest, key: id.key) { $0.saveError = failure } }
        throw failure
      }
    }

    do {
      try await saveKeyEdit(edit, in: id.projectID)
    } catch {
      if generation == keyDrafts.generation { keyDrafts.finishSave(id, succeeded: false, projects: projects) }
      throw error
    }
    guard generation == keyDrafts.generation, isUnlocked else { throw .targetUnavailable }
    guard let schemaFolder, !schemaFolder.isEmpty, !schemaChange.isEmpty else {
      keyDrafts.finishSave(id, succeeded: true, projects: projects)
      return
    }

    let projectID = id.projectID
    beginOwnSchemaWrite(projectID)
    defer { endOwnSchemaWrite(projectID) }
    let result = await ProjectEnvSchemaFile.save(schemaChange, inFolder: schemaFolder, vaultID: projectID)
    guard generation == keyDrafts.generation, isUnlocked else { throw .targetUnavailable }
    switch result {
    case .success(let saved):
      keyDrafts.finishSave(id, succeeded: true, projects: projects)
      if let project = projects.first(where: { $0.id == projectID }), keyDescriptionFolder(for: project) == schemaFolder {
        publishSavedRules(saved.rules, rootSchema: saved.rootSchema, folder: schemaFolder, for: projectID,
          description: schemaChange.description.map { ($0.key, $0.text) })
      }
    case .failure(let failure):
      let keySaved = edit.isRename || !edit.values.isEmpty || draft.pendingSchemaRename != nil
      let saveError = VaultKeyEditError.description(failure.localizedDescription, keySaved: keySaved)
      if keySaved {
        keyDrafts.finishSave(id, succeeded: true, projects: projects)
        if let project = projects.first(where: { $0.id == projectID }), project.hasLoadedEnvironments {
          keyDrafts.edit(project, key: edit.newKey) { retained in
            if let description {
              retained.setKeyDescription(description, saved: schemaChange.description?.expectedText ?? "")
            }
            if let rename = schemaChange.rename {
              retained.pendingSchemaRename = .init(folder: schemaFolder, from: rename.from)
            }
            retained.saveError = saveError
          }
        }
      } else {
        keyDrafts.finishSave(id, succeeded: false, projects: projects)
        if let project = projects.first(where: { $0.id == projectID }) {
          keyDrafts.edit(project, key: id.key) { $0.saveError = saveError }
        }
      }
      if failure == .changed {
        let loaded = await ProjectEnvSchemaFile.loadRules(inFolder: schemaFolder, vaultID: projectID)
        guard generation == keyDrafts.generation, isUnlocked else { throw .targetUnavailable }
        if let project = projects.first(where: { $0.id == projectID }), keyDescriptionFolder(for: project) == schemaFolder {
          publishKeyDescriptions(ProjectKeyDescriptions(folder: schemaFolder, loaded: loaded), for: projectID)
        }
      }
      throw saveError
    }
  }

  // MARK: - Key descriptions

  /// The folder whose `lpm.json` holds a project's key descriptions: the one the
  /// CLI was connected in, or else the project's own folder.
  func keyDescriptionFolder(for project: VaultProject) -> String {
    ProjectCLILink.folder(vaultId: project.id, projectPath: project.path, defaults: preferences)
  }

  /// Keys whose current rules allow automatic reveal. Empty while rules are
  /// being reread, the folder changed, or secret actions are unavailable.
  func publicKeys(in projectID: String) -> Set<String> {
    guard canUseLocalSecrets, !isRefreshingLocalState,
      !unverifiedKeyDescriptionProjects.contains(projectID),
      let descriptions = keyDescriptions[projectID],
      let project = projects.first(where: { $0.id == projectID }),
      descriptions.folder == keyDescriptionFolder(for: project)
    else { return [] }
    return descriptions.schema?.overview?.publicKeys ?? []
  }

  /// Rereads the selected project's key descriptions from its `lpm.json`.
  func reloadKeyDescriptions() {
    keyDescriptionsTask?.cancel()
    guard isUnlocked, let project = selectedProject else { return }
    let projectID = project.id
    let folder = keyDescriptionFolder(for: project)
    unverifiedKeyDescriptionProjects.insert(projectID)
    let session = vaultSessionGeneration
    let account = selectedAccount
    keyDescriptionsTask = Task { [weak self] in
      let loaded = await ProjectEnvSchemaFile.loadRules(inFolder: folder, vaultID: projectID)
      guard let self, !Task.isCancelled, isUnlocked, session == vaultSessionGeneration, selectedAccount == account,
        selectedProjectId == projectID, let currentProject = selectedProject,
        keyDescriptionFolder(for: currentProject) == folder
      else { return }
      publishKeyDescriptions(ProjectKeyDescriptions(folder: folder, loaded: loaded), for: projectID)
      unverifiedKeyDescriptionProjects.remove(projectID)
      keyDescriptionsTask = nil
    }
  }

  /// Rules an edit just saved, with lpm.json's envSchema after it. The display
  /// keeps the last read schema until the selected project's rules are read
  /// again, which also picks up new sources. A schema draft merges the app's
  /// own edit right away, taking in a `description` it saved for a key the
  /// draft changes, and notes only conflicts.
  private func publishSavedRules(
    _ rules: ProjectEnvSchemaFile.Rules, rootSchema: LPMConfigJSON?, folder: String, for projectID: String,
    description: (key: String, text: String)? = nil
  ) {
    unverifiedKeyDescriptionProjects.insert(projectID)
    let previous = keyDescriptions[projectID]
    let sameFolder = previous?.folder == folder
    if sameFolder, var draft = schemaDrafts[projectID], schemaDraftFolders[projectID]?.path == folder,
      !savingSchemaDrafts.contains(projectID)
    {
      let merged = draft
      let outcome = draft.rebase(ontoOwnWrite: rootSchema, description: description)
      if draft.schema != merged.schema {
        settleSchemaDraft(&draft, since: merged, everyKey: true, for: projectID)
        schemaDraftHistory[projectID] = nil
      }
      setSchemaDraft(draft, for: projectID)
      if !outcome.conflicts.isEmpty { noteSchemaDraftRebase(outcome, for: projectID) }
    }
    var descriptions = ProjectKeyDescriptions(folder: folder, rules: .success(rules), schema: sameFolder ? previous?.schema : nil,
      rootSchema: rootSchema, folderIdentity: sameFolder ? previous?.folderIdentity : nil,
      dependencies: sameFolder ? previous?.dependencies : nil)
    descriptions.schemaPredatesRoot = descriptions.schema != nil
    publishKeyDescriptions(descriptions, for: projectID)
    if selectedProjectId == projectID { reloadKeyDescriptions() }
  }

  /// `mergingDraft` false leaves merging the schema draft to the caller.
  /// While the app's own edit of lpm.json is in flight, the draft merges once
  /// it's published, so a reread that sees the edit first doesn't take it
  /// for a change on disk.
  private func publishKeyDescriptions(_ descriptions: ProjectKeyDescriptions, for projectID: String, mergingDraft: Bool = true) {
    var descriptions = descriptions
    // A read that fails names no imports, so the ones last resolved stay
    // watched and fixing a broken one is noticed.
    if case .unreadable? = descriptions.schema, let previous = keyDescriptions[projectID], previous.folder == descriptions.folder {
      descriptions.importPaths = previous.importPaths
    }
    guard keyDescriptions[projectID] != descriptions else { return }
    keyDescriptions[projectID] = descriptions
    if case .success(let rules) = descriptions.rules {
      keyDrafts.receiveKeyDescriptions(rules.descriptions, ruleKeys: rules.keys, folder: descriptions.folder, in: projectID)
    }
    if mergingDraft {
      if ownSchemaWrites[projectID] != nil { pendingSchemaMerges.insert(projectID) } else { mergeSchemaDraft(for: projectID) }
    }
    refreshValueCheck(for: projectID)
    refreshSchemaDraftEvaluation(for: projectID)
  }

  // MARK: - Value checks

  /// The values and rules a project's value check evaluated.
  private struct ValueCheckInputs: Equatable {
    let values: UUID
    let rules: ProjectEnvSchemaOverview
  }

  /// Rechecks every project whose values or rules changed since its last check.
  private func refreshValueChecks() {
    for projectID in Set(valueChecks.keys).union(valueCheckInputs.keys).union(keyDescriptions.keys) {
      refreshValueCheck(for: projectID)
    }
    for projectID in Set(schemaDrafts.keys).union(schemaDraftEvaluationInputs.keys) {
      refreshSchemaDraftEvaluation(for: projectID)
    }
  }

  /// Checks a project's stored values against its rules with the bundled
  /// engine, off the main thread. A project whose rules aren't loaded, or
  /// whose lpm.json can't be read, has no check.
  private func refreshValueCheck(for projectID: String) {
    guard let rules = keyDescriptions[projectID]?.schema?.overview, rules.effectiveSchema != nil,
      let project = projects.first(where: { $0.id == projectID }), project.hasLoadedEnvironments
    else {
      valueCheckTasks.removeValue(forKey: projectID)?.cancel()
      valueCheckInputs[projectID] = nil
      if valueChecks[projectID] != nil { valueChecks[projectID] = nil }
      return
    }
    let inputs = ValueCheckInputs(values: project.workspaceSnapshotIdentity, rules: rules)
    guard valueCheckInputs[projectID] != inputs else { return }
    valueCheckInputs[projectID] = inputs
    valueChecks[projectID] = nil
    valueCheckTasks[projectID]?.cancel()
    let environments = project.environments
    valueCheckTasks[projectID] = Task { [weak self] in
      guard let self else { return }
      let check = await valueCheckWorker.check(rules: rules, environments: environments)
      guard !Task.isCancelled, self.valueCheckInputs[projectID] == inputs else { return }
      self.valueCheckTasks[projectID] = nil
      if self.valueChecks[projectID] != check { self.valueChecks[projectID] = check }
    }
  }

  private func clearValueChecks() {
    for task in valueCheckTasks.values { task.cancel() }
    valueCheckTasks = [:]
    valueCheckInputs = [:]
    valueChecks = [:]
  }

  private func clearKeyDescriptions() {
    keyDescriptionsTask?.cancel()
    keyDescriptionsTask = nil
    keyDescriptions = [:]
    unverifiedKeyDescriptionProjects = []
    clearValueChecks()
    clearSchemaDrafts()
  }

  // MARK: - Schema drafts

  /// The folder a draft's rules were read from, and its identity then.
  private struct SchemaDraftFolder: Equatable {
    let path: String
    let identity: ProjectConfigFile.DirectoryIdentity?
  }

  /// An evaluation and the draft revision and stored values it evaluated.
  struct EvaluatedSchemaDraft: Equatable {
    let revision: Int
    let values: UUID
    /// The imports as lpm.json was last read when the draft was evaluated.
    let imports: [RustSchemaEngine.Dependency]?
    let evaluation: ProjectEnvSchemaDraft.Evaluation
  }

  /// The project's unsaved schema edits; nil while it has none.
  func schemaDraft(for projectID: String) -> ProjectEnvSchemaDraft? {
    schemaDrafts[projectID].flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Removes `key` from lpm.json in the project's draft, with a fix for
  /// each reference to it, as one change.
  func removeSchemaKey(
    _ key: String, settling fixes: [(reference: ProjectEnvSchemaReference, fix: ProjectEnvSchemaReference.Fix)], in projectID: String
  ) {
    editSchemaDraft(in: projectID) { $0.remove(key, settling: fixes) }
  }

  /// What going back to the imports' version of each of `groups`, which
  /// `draft`, the project's draft or lpm.json's rules, overrides, brings back;
  /// nil while the rules can't be edited, or when the calling task was cancelled.
  func restoredSchemaGroups(_ groups: [String], of draft: ProjectEnvSchemaDraft, in projectID: String) async -> [String: ProjectEnvSchemaReference.Restore]? {
    guard let folder = editableSchemaFolder(for: projectID)?.path else { return nil }
    return await schemaDraftEvaluator.restoredGroups(groups, of: draft, inFolder: folder)
  }

  /// Takes a key's removal back, with the fixes that came with it.
  func keepSchemaKey(_ key: String, in projectID: String) {
    editSchemaDraft(in: projectID) { $0.keep(key) }
  }

  /// A key some environment stores, and how many do.
  struct StoredSchemaKey: Hashable, Sendable {
    let key: String
    let environments: Int
    /// A declared key whose name differs from this one only in letter case,
    /// which Windows reads as the same name, so this one can't be declared.
    var conflict: String?
    /// The LPM CLI never passes the key to a process, so a rule for it has no effect.
    var isIgnored = false

    /// The keys of `keys` declaring them all at once can declare: not ignored,
    /// not a letter-case variant of a declared key, nor of another of them,
    /// which is left for the person to choose between.
    static func declarableTogether(_ keys: [StoredSchemaKey]) -> [String] {
      var counts: [String: Int] = [:]
      for stored in keys where !stored.isIgnored && stored.conflict == nil { counts[stored.key.uppercased(), default: 0] += 1 }
      return keys.compactMap { !$0.isIgnored && $0.conflict == nil && counts[$0.key.uppercased()] == 1 ? $0.key : nil }
    }
  }

  /// Keys the project stores that lpm.json doesn't declare, with the draft
  /// applied, from A to Z. A key the draft removes isn't one: it's listed as
  /// removed. Read from the workspace snapshot, which is built off the main
  /// thread whenever the values change.
  func undeclaredSchemaKeys(for projectID: String) -> [StoredSchemaKey] {
    guard let project = projects.first(where: { $0.id == projectID }), project.hasLoadedEnvironments,
      case .loaded(let saved, _)? = keyDescriptions[projectID]?.schema, let snapshot = workspaceSnapshots[projectID]
    else { return [] }
    let draft = schemaDraftOrBase(for: projectID)
    // Declared keys by their name in capitals, with the draft applied.
    var declared: [String: String] = [:]
    for rule in saved.rules {
      let item = ProjectEnvSchemaDraft.Item.key(rule.key)
      if case .declared = draft.base(of: item), draft.declaration(of: item) == .absent { continue }
      declared[rule.key.uppercased()] = declared[rule.key.uppercased()] ?? rule.key
    }
    for case .key(let key) in draft.changedItems where draft.declaration(of: .key(key)) != .absent {
      declared[key.uppercased()] = declared[key.uppercased()] ?? key
    }
    let ignored = valueChecks[projectID]?.environments.values.reduce(into: Set<String>()) { $0.formUnion($1.ignored) } ?? []
    return snapshot.allSecretKeys.compactMap { key in
      let item = ProjectEnvSchemaDraft.Item.key(key)
      guard draft.declaration(of: item) == .absent, draft.base(of: item) == .absent, saved.rule(for: key)?.source == nil else { return nil }
      return StoredSchemaKey(key: key, environments: snapshot.summaries[key]?.environmentCount ?? 0,
        conflict: declared[key.uppercased()], isIgnored: ignored.contains(key))
    }
  }

  /// `undeclaredSchemaKeys(for:)`'s entry for `key`, without listing the
  /// project's other keys; nil when it isn't one.
  func undeclaredSchemaKey(_ key: String, for projectID: String) -> StoredSchemaKey? {
    guard let project = projects.first(where: { $0.id == projectID }), project.hasLoadedEnvironments,
      case .loaded(let saved, _)? = keyDescriptions[projectID]?.schema, let summary = workspaceSnapshots[projectID]?.summaries[key]
    else { return nil }
    let draft = schemaDraftOrBase(for: projectID)
    let item = ProjectEnvSchemaDraft.Item.key(key)
    guard draft.declaration(of: item) == .absent, draft.base(of: item) == .absent, saved.rule(for: key)?.source == nil else { return nil }
    let name = key.uppercased()
    var conflict = saved.rules.first { rule in
      let item = ProjectEnvSchemaDraft.Item.key(rule.key)
      if case .declared = draft.base(of: item), draft.declaration(of: item) == .absent { return false }
      return rule.key.uppercased() == name
    }?.key
    if conflict == nil {
      for case .key(let other) in draft.changedItems where other.uppercased() == name && draft.declaration(of: .key(other)) != .absent {
        conflict = other
        break
      }
    }
    let ignored = valueChecks[projectID]?.environments.values.contains { $0.ignored.contains(key) } ?? false
    return StoredSchemaKey(key: key, environments: summary.environmentCount, conflict: conflict, isIgnored: ignored)
  }

  /// Keys the project's draft declares whose names differ only in letter
  /// case, which the LPM CLI rejects on Windows; nil when the draft adds no
  /// such names. Names lpm.json already has that clash don't stop a save.
  func schemaDraftCaseClash(for projectID: String) -> ProjectEnvSchemaOverview.CaseClash? {
    guard schemaDraft(for: projectID) != nil else { return nil }
    return currentSchemaDraftEvaluation(for: projectID)?.overview?.caseClash(since: keyDescriptions[projectID]?.schema?.overview)
  }

  /// The review of the project's draft as it is now: nil without a draft,
  /// and while it's evaluated or the engine rejects it.
  func schemaDraftReview(for projectID: String, environments: [String]) -> ProjectEnvSchemaReview? {
    // Read every input first, so a view that shows the review follows them.
    guard let draft = schemaDraft(for: projectID), let evaluation = currentSchemaDraftEvaluation(for: projectID),
      let project = projects.first(where: { $0.id == projectID })
    else { return nil }
    let savedRules = keyDescriptions[projectID]?.schema?.overview
    let savedCheck = valueChecks[projectID]
    if let cached = schemaReviews[projectID], cached.environments == environments { return cached.review }
    let review = ProjectEnvSchemaReview(draft: draft, evaluation: evaluation, savedRules: savedRules, savedCheck: savedCheck,
      project: project, environments: environments)
    schemaReviews[projectID] = (environments, review)
    return review
  }

  /// The project's schema draft, or lpm.json's rules as last read when it has none.
  func schemaDraftOrBase(for projectID: String) -> ProjectEnvSchemaDraft {
    schemaDraft(for: projectID) ?? schemaBase(for: projectID)
  }

  private func schemaBase(for projectID: String) -> ProjectEnvSchemaDraft {
    let descriptions = keyDescriptions[projectID]
    if let base = schemaBases[projectID] { return base }
    let base = ProjectEnvSchemaDraft(schema: descriptions?.rootSchema)
    schemaBaseBuilds += 1
    schemaBases[projectID] = base
    return base
  }

  /// The evaluation of the project's draft as it is now, with the values and
  /// imports as they are now; nil while it's being evaluated.
  func currentSchemaDraftEvaluation(for projectID: String) -> ProjectEnvSchemaDraft.Evaluation? {
    guard schemaDraft(for: projectID) != nil, let evaluated = schemaDraftEvaluations[projectID],
      evaluated.revision == schemaDraftRevisions[projectID],
      evaluated.values == projects.first(where: { $0.id == projectID })?.workspaceSnapshotIdentity,
      evaluated.imports == keyDescriptions[projectID]?.dependencies
    else { return nil }
    return evaluated.evaluation
  }

  /// The project's rules with its draft applied, as last evaluated, which can
  /// lag the draft; lpm.json's rules when it has no draft.
  func schemaOverview(for projectID: String) -> ProjectEnvSchemaOverview? {
    let saved = keyDescriptions[projectID]?.schema?.overview
    return schemaDraft(for: projectID) == nil ? saved : latestSchemaDraftEvaluation(for: projectID)?.overview ?? saved
  }

  /// The prefixes lpm.json's imports list, each with the first schema that
  /// lists it, as lpm.json's rules were last read. The app doesn't change
  /// what lpm.json imports, so the draft's evaluation names the same ones.
  func schemaImportedClientPrefixSources(for projectID: String) -> [String: String] {
    (keyDescriptions[projectID]?.schema?.overview ?? latestSchemaDraftEvaluation(for: projectID)?.overview)?.importedClientPrefixes ?? [:]
  }

  /// The prefixes lpm.json's imports list.
  func schemaImportedClientPrefixes(for projectID: String) -> Set<String> {
    Set(schemaImportedClientPrefixSources(for: projectID).keys)
  }

  /// The prefixes that make the project's keys public besides the
  /// frameworks', with its draft applied: lpm.json's own and its imports',
  /// sorted, so callers that key work on them see a stable value.
  func schemaClientPrefixesInEffect(for projectID: String) -> [String] {
    schemaImportedClientPrefixes(for: projectID).union(ProjectEnvSchemaClientPrefixes.own(in: schemaDraftOrBase(for: projectID))).sorted()
  }

  /// What the project's client prefixes can be changed from now: its draft
  /// with the rules the engine resolved for exactly it, or lpm.json's rules
  /// without a draft. Rules of another version of the draft never stand in.
  func schemaPrefixAvailability(for projectID: String) -> ProjectEnvSchemaClientPrefixes.Availability {
    guard let descriptions = keyDescriptions[projectID], case .loaded(let saved, _)? = descriptions.schema else { return .unreadable }
    // The rules lag lpm.json's base until the app's own write is read back.
    guard !descriptions.schemaPredatesRoot else { return .checking }
    guard let draft = schemaDraft(for: projectID) else { return .ready(.init(draft: schemaBase(for: projectID), rules: saved, saved: saved)) }
    guard let evaluation = currentSchemaDraftEvaluation(for: projectID) else { return .checking }
    guard evaluation.rejection == nil, let rules = evaluation.overview else { return .rejected }
    return .ready(.init(draft: draft, rules: rules, saved: saved))
  }

  /// The latest evaluation of the project's draft, which can be of an earlier
  /// version of it; for showing something while the current one is evaluated.
  func latestSchemaDraftEvaluation(for projectID: String) -> ProjectEnvSchemaDraft.Evaluation? {
    schemaDraft(for: projectID) == nil ? nil : schemaDraftEvaluations[projectID]?.evaluation
  }

  /// Whether the selected project's rules are being read.
  var isReloadingKeyDescriptions: Bool { keyDescriptionsTask != nil }

  /// Whether the project's rules are loaded from its folder, so they can be edited.
  func canEditSchema(of projectID: String) -> Bool {
    editableSchemaFolder(for: projectID) != nil && !savingSchemaDrafts.contains(projectID)
  }

  /// Changes the project's schema draft, starting one from lpm.json's rules as
  /// last read. Ignored while the rules can't be edited or the draft is saving.
  /// Edits with a `coalescing` key, such as typing in one field, undo together
  /// and are evaluated once typing pauses.
  func editSchemaDraft(in projectID: String, coalescing: String? = nil, _ edit: (inout ProjectEnvSchemaDraft) -> Void) {
    guard !savingSchemaDrafts.contains(projectID), let folder = editableSchemaFolder(for: projectID) else { return }
    let current = schemaDraftFolders[projectID] == folder ? schemaDrafts[projectID] : nil
    let previous = current ?? schemaBase(for: projectID)
    var draft = previous
    edit(&draft)
    settleSchemaDraft(&draft, since: previous, for: projectID)
    guard draft != previous else { return }
    if current == nil { schemaDraftHistory[projectID] = nil }
    schemaDraftHistory[projectID, default: SchemaDraftHistory()].record(previous, coalescing: coalescing, at: schemaEditNow())
    schemaDraftFolders[projectID] = folder
    if coalescing != nil { debouncedSchemaDrafts.insert(projectID) }
    setSchemaDraft(draft, for: projectID)
  }

  /// Ends the project's unsaved schema edits, also while its rules can't be read.
  func discardSchemaDraft(in projectID: String) {
    guard var draft = schemaDrafts[projectID], !draft.isEmpty, !savingSchemaDrafts.contains(projectID) else { return }
    schemaDraftHistory[projectID, default: SchemaDraftHistory()].record(draft, coalescing: nil, at: schemaEditNow())
    draft.discardAll()
    setSchemaDraft(draft, for: projectID)
  }

  func canUndoSchemaDraft(in projectID: String) -> Bool {
    schemaDraftHistory[projectID]?.undo.isEmpty == false && canEditSchema(of: projectID)
  }

  func canRedoSchemaDraft(in projectID: String) -> Bool {
    schemaDraftHistory[projectID]?.redo.isEmpty == false && canEditSchema(of: projectID)
  }

  func undoSchemaDraft(in projectID: String) {
    guard canEditSchema(of: projectID), let draft = schemaDrafts[projectID],
      let restored = schemaDraftHistory[projectID]?.undo(from: draft)
    else { return }
    setSchemaDraft(restored, for: projectID)
  }

  func redoSchemaDraft(in projectID: String) {
    guard canEditSchema(of: projectID), let draft = schemaDrafts[projectID],
      let restored = schemaDraftHistory[projectID]?.redo(from: draft, at: schemaEditNow())
    else { return }
    setSchemaDraft(restored, for: projectID)
  }

  func dismissSchemaDraftRebase(in projectID: String) {
    schemaDraftRebases[projectID] = nil
  }

  /// Writes the project's schema draft into its lpm.json, checked against the
  /// imported schemas its current evaluation used. When lpm.json changed since
  /// the draft last read it, the rules are read again and the draft merges;
  /// a change that only reordered the file saves right away, and any other
  /// fails with `changed` so the merged draft can be reviewed.
  func saveSchemaDraft(in projectID: String) async throws(ProjectEnvSchemaFile.DraftSaveError) {
    let write = writes.begin()
    defer { writes.end(write) }
    var attempt = SchemaDraftSaveAttempt()
    do {
      try await saveSchemaDraftOnce(in: projectID, attempt: &attempt)
      schemaDraftSaveFailures[projectID] = nil
    } catch {
      if error != .inProgress, let revision = attempt.revision, let evaluation = attempt.evaluation, schemaDrafts[projectID] != nil {
        schemaDraftSaveFailures[projectID] = SchemaDraftSaveFailure(revision: revision, evaluation: evaluation, error: error)
      }
      throw error
    }
  }

  /// What a save tried: the draft revision of its last attempt, and the
  /// evaluation the first attempt saved with, which the review showed.
  private struct SchemaDraftSaveAttempt {
    var revision: Int?
    var evaluation: ProjectEnvSchemaDraft.Evaluation?
  }

  /// A failed save, with the draft revision and the evaluation it tried to save.
  struct SchemaDraftSaveFailure: Equatable {
    let revision: Int
    let evaluation: ProjectEnvSchemaDraft.Evaluation
    let error: ProjectEnvSchemaFile.DraftSaveError
  }

  /// Why saving the project's draft as it is now failed: nil once the draft,
  /// or what its evaluation shows, changes, since that needs another review.
  func schemaDraftSaveFailure(for projectID: String) -> ProjectEnvSchemaFile.DraftSaveError? {
    guard let failure = schemaDraftSaveFailures[projectID], failure.revision == schemaDraftRevisions[projectID],
      currentSchemaDraftEvaluation(for: projectID) == failure.evaluation
    else { return nil }
    return failure.error
  }

  private func saveSchemaDraftOnce(in projectID: String, attempt saving: inout SchemaDraftSaveAttempt) async throws(ProjectEnvSchemaFile.DraftSaveError) {
    // The imports the evaluation showed, which a retry after a reordering keeps.
    var reviewed: [RustSchemaEngine.Dependency] = []
    for attempt in 0..<2 {
      saving.revision = schemaDraftRevisions[projectID]
      guard let draft = schemaDraft(for: projectID) else { return }
      guard !savingSchemaDrafts.contains(projectID) else { throw .inProgress }
      guard let folder = editableSchemaFolder(for: projectID), schemaDraftFolders[projectID]?.path == folder.path else {
        throw .unavailable(schemaUnavailableReason(for: projectID))
      }
      guard draft.conflicts.isEmpty else { throw .conflicts }
      if attempt == 0 {
        guard let evaluation = currentSchemaDraftEvaluation(for: projectID) else {
          throw .unavailable("The rules are still being checked. Save again in a moment.")
        }
        reviewed = evaluation.dependencies
        saving.evaluation = evaluation
        if let clash = evaluation.overview?.caseClash(since: keyDescriptions[projectID]?.schema?.overview) {
          throw .unavailable(clash.message)
        }
      }
      let generation = schemaDraftGeneration
      savingSchemaDrafts.insert(projectID)
      let result = await ProjectEnvSchemaFile.save(draft, inFolder: folder.path, vaultID: projectID,
        folderIdentity: folder.identity, reviewed: reviewed)
      guard generation == schemaDraftGeneration, isUnlocked else {
        throw .unavailable("The project changed while the rules were saving. Nothing else was changed in the app.")
      }
      savingSchemaDrafts.remove(projectID)
      switch result {
      case .success(let saved):
        guard let project = projects.first(where: { $0.id == projectID }), keyDescriptionFolder(for: project) == folder.path else {
          // Saved where the draft was reviewed; the project's new folder has its own rules.
          endSchemaDraft(for: projectID)
          reloadKeyDescriptions()
          return
        }
        schemaDraftHistory[projectID] = nil
        setSchemaDraft(ProjectEnvSchemaDraft(schema: saved.schema), for: projectID)
        schemaDraftRebases[projectID] = nil
        publishKeyDescriptions(
          ProjectKeyDescriptions(folder: folder.path, rules: .success(saved.rules), schema: .loaded(saved.overview, file: saved.file),
            rootSchema: saved.schema, folderIdentity: folder.identity, dependencies: saved.dependencies),
          for: projectID
        )
        unverifiedKeyDescriptionProjects.remove(projectID)
        return
      case .failure(.file(.changed)):
        let loaded = await ProjectEnvSchemaFile.loadRules(inFolder: folder.path, vaultID: projectID)
        guard generation == schemaDraftGeneration, isUnlocked,
          let project = projects.first(where: { $0.id == projectID }), keyDescriptionFolder(for: project) == folder.path
        else { throw .file(.changed) }
        publishKeyDescriptions(ProjectKeyDescriptions(folder: folder.path, loaded: loaded), for: projectID, mergingDraft: false)
        let outcome = mergeSchemaDraft(for: projectID)
        guard attempt == 0, let outcome, outcome.isEmpty, outcome.conflicts.isEmpty else { throw .file(.changed) }
      case .failure(.importsChanged):
        reloadKeyDescriptions()
        throw .importsChanged
      case .failure(let failure):
        mergeSchemaDraft(for: projectID)
        throw failure
      }
    }
  }

  private func schemaUnavailableReason(for projectID: String) -> String {
    switch keyDescriptions[projectID]?.schema {
    case .unreadable?: "lpm.json can't be read. Fix it, then save."
    case .noFolder?: "The project's folder isn't available."
    case nil: "lpm.json hasn't been read yet."
    case .loaded?: "The project's folder changed. Review the rules, then save again."
    }
  }

  /// Renames a key lpm.json declares: its stored values and its rule together,
  /// as the inspector does, or only the rule when no environment stores the key.
  /// Waits for an empty schema draft, so no unsaved rule refers to the old name.
  func renameDeclaredKey(_ key: String, to newKey: String, in projectID: String) async throws(VaultKeyEditError) {
    guard key != newKey else { return }
    guard schemaDraft(for: projectID) == nil else { throw .refused("Save or discard your rule changes before renaming a key.") }
    guard EnvValidation.isValidVariableName(newKey) else { throw .invalidName }
    guard let project = projects.first(where: { $0.id == projectID }), selectedProjectId == projectID,
      let folder = editableSchemaFolder(for: projectID)
    else { throw .targetUnavailable }
    guard project.hasLoadedEnvironments else { throw .refused("\(project.name)'s values are still loading. Rename the key once they've loaded.") }
    let id = VaultKeyDraft.ID(projectID: projectID, key: key)
    if let draft = keyDrafts.draft(id) {
      guard !draft.isDirty else { throw .refused("\(key) has unsaved edits on the Environments page. Save or discard them first.") }
      keyDrafts.discard(id)
    }
    // The Keychain checks these values under its lock, so a key stored since
    // they were read fails the rename instead of leaving its values behind.
    let edit = VaultKeyEdit(key: key, environments: project.environments, newKey: newKey)
    let result = await withCheckedContinuation { continuation in
      enqueueSchemaKeyRename(base: project, edit: edit, change: .init(rename: .init(from: key, to: newKey)),
        folder: folder.path, folderIdentity: folder.identity) { continuation.resume(returning: $0) }
    }
    try result.get()
  }

  /// The folder whose lpm.json holds the project's loaded rules.
  private func editableSchemaFolder(for projectID: String) -> SchemaDraftFolder? {
    guard isUnlocked, let descriptions = keyDescriptions[projectID], case .loaded? = descriptions.schema,
      let project = projects.first(where: { $0.id == projectID }), keyDescriptionFolder(for: project) == descriptions.folder,
      !descriptions.folder.isEmpty
    else { return nil }
    return SchemaDraftFolder(path: descriptions.folder, identity: descriptions.folderIdentity)
  }

  /// Keeps each key lpm.json declares public exactly when a prefix makes it
  /// so, after an edit from `previous`, or after a merge, of every key. Undo,
  /// redo and discarding restore drafts that were settled, or lpm.json's
  /// own rules, so they don't settle again.
  private func settleSchemaDraft(_ draft: inout ProjectEnvSchemaDraft, since previous: ProjectEnvSchemaDraft, everyKey: Bool = false, for projectID: String) {
    guard let saved = keyDescriptions[projectID]?.schema?.overview else { return }
    ProjectEnvSchemaClientPrefixes.settle(&draft, since: previous, everyKey: everyKey, imported: Set(saved.importedClientPrefixes.keys), saved: saved)
  }

  private func setSchemaDraft(_ draft: ProjectEnvSchemaDraft, for projectID: String) {
    schemaDrafts[projectID] = draft
    schemaDraftRevisions[projectID, default: 0] &+= 1
    if draft.isEmpty { schemaDraftRebases[projectID] = nil }
    refreshSchemaDraftEvaluation(for: projectID)
  }

  private func noteSchemaDraftRebase(_ outcome: ProjectEnvSchemaDraft.Rebase, for projectID: String) {
    schemaDraftRebases[projectID] = schemaDraftRebases[projectID].map { $0.merged(with: outcome) } ?? outcome
  }

  /// Merges the project's draft onto lpm.json's rules as last read, noting
  /// what changed on disk. A draft from another folder ends. Returns what the
  /// merge did; nil when there was nothing to merge.
  @discardableResult
  private func mergeSchemaDraft(for projectID: String) -> ProjectEnvSchemaDraft.Rebase? {
    guard var draft = schemaDrafts[projectID], let descriptions = keyDescriptions[projectID] else { return nil }
    let folder = schemaDraftFolders[projectID]
    guard folder?.path == descriptions.folder, folder?.identity == nil || descriptions.folderIdentity == nil || folder?.identity == descriptions.folderIdentity else {
      endSchemaDraft(for: projectID)
      return nil
    }
    let schema = schemaBase(for: projectID).schema
    guard case .loaded? = descriptions.schema, !savingSchemaDrafts.contains(projectID), schema != draft.schema else { return nil }
    let merged = draft
    let outcome = draft.rebase(onto: schema)
    settleSchemaDraft(&draft, since: merged, everyKey: true, for: projectID)
    schemaDraftHistory[projectID] = nil
    setSchemaDraft(draft, for: projectID)
    if !draft.isEmpty, !outcome.isEmpty || !outcome.conflicts.isEmpty { noteSchemaDraftRebase(outcome, for: projectID) }
    return outcome
  }

  private func endSchemaDraft(for projectID: String) {
    schemaDrafts[projectID] = nil
    schemaDraftFolders[projectID] = nil
    schemaDraftRevisions[projectID] = nil
    schemaDraftRebases[projectID] = nil
    schemaDraftHistory[projectID] = nil
    schemaDraftSaveFailures[projectID] = nil
    debouncedSchemaDrafts.remove(projectID)
    refreshSchemaDraftEvaluation(for: projectID)
  }

  private func beginOwnSchemaWrite(_ projectID: String) {
    ownSchemaWrites[projectID, default: 0] += 1
  }

  /// Ends an own edit, merging the draft with what was read meanwhile once
  /// none is left.
  private func endOwnSchemaWrite(_ projectID: String) {
    guard let count = ownSchemaWrites[projectID] else { return }
    guard count == 1 else {
      ownSchemaWrites[projectID] = count - 1
      return
    }
    ownSchemaWrites[projectID] = nil
    if pendingSchemaMerges.remove(projectID) != nil { mergeSchemaDraft(for: projectID) }
  }

  /// Ends the drafts of projects that are gone.
  private func pruneSchemaDrafts() {
    let projectIDs = Set(projects.lazy.map(\.id))
    for projectID in schemaDrafts.keys where !projectIDs.contains(projectID) { endSchemaDraft(for: projectID) }
  }

  /// A draft's earlier and undone versions. A merge with lpm.json or a save
  /// ends the history, because earlier versions were made against the old file.
  struct SchemaDraftHistory: Equatable {
    private struct Entry: Equatable {
      let draft: ProjectEnvSchemaDraft
      let coalescing: String?
      let time: ContinuousClock.Instant
    }

    private static let limit = 200
    private static let coalescingWindow = Duration.seconds(1)
    private var undoEntries: [Entry] = []
    private var redoEntries: [ProjectEnvSchemaDraft] = []

    var undo: [ProjectEnvSchemaDraft] { undoEntries.map(\.draft) }
    var redo: [ProjectEnvSchemaDraft] { redoEntries }

    mutating func record(_ previous: ProjectEnvSchemaDraft, coalescing: String?, at time: ContinuousClock.Instant) {
      redoEntries = []
      if let coalescing, let last = undoEntries.last, last.coalescing == coalescing, time - last.time < Self.coalescingWindow {
        undoEntries[undoEntries.count - 1] = Entry(draft: last.draft, coalescing: coalescing, time: time)
        return
      }
      undoEntries.append(Entry(draft: previous, coalescing: coalescing, time: time))
      if undoEntries.count > Self.limit { undoEntries.removeFirst(undoEntries.count - Self.limit) }
    }

    mutating func undo(from current: ProjectEnvSchemaDraft) -> ProjectEnvSchemaDraft? {
      guard let entry = undoEntries.popLast() else { return nil }
      redoEntries.append(current)
      return entry.draft
    }

    mutating func redo(from current: ProjectEnvSchemaDraft, at time: ContinuousClock.Instant) -> ProjectEnvSchemaDraft? {
      guard let draft = redoEntries.popLast() else { return nil }
      undoEntries.append(Entry(draft: current, coalescing: nil, time: time))
      return draft
    }
  }

  /// The draft and stored values a draft's evaluation used, and the digests
  /// of the schemas lpm.json imported when it was last read.
  private struct SchemaDraftEvaluationInputs: Equatable {
    let revision: Int
    let folder: String
    let values: UUID
    let imports: [RustSchemaEngine.Dependency]?
  }

  /// Evaluates the project's draft with the bundled engine, one evaluation at
  /// a time and off the main thread, when the draft, the rules it builds on,
  /// or the stored values changed. While typing, it waits for a pause.
  private func refreshSchemaDraftEvaluation(for projectID: String) {
    guard let draft = schemaDraft(for: projectID), let folder = schemaDraftFolders[projectID]?.path,
      let revision = schemaDraftRevisions[projectID],
      let project = projects.first(where: { $0.id == projectID }), project.hasLoadedEnvironments
    else {
      schemaDraftEvaluationTasks.removeValue(forKey: projectID)?.cancel()
      schemaDraftEvaluationInputs[projectID] = nil
      debouncedSchemaDrafts.remove(projectID)
      if schemaDraftEvaluations[projectID] != nil { schemaDraftEvaluations[projectID] = nil }
      return
    }
    let imports = keyDescriptions[projectID]?.dependencies
    let inputs = SchemaDraftEvaluationInputs(revision: revision, folder: folder, values: project.workspaceSnapshotIdentity, imports: imports)
    guard schemaDraftEvaluationInputs[projectID] != inputs else { return }
    schemaDraftEvaluationInputs[projectID] = inputs
    schemaDraftEvaluationTasks[projectID]?.cancel()
    let debounced = debouncedSchemaDrafts.remove(projectID) != nil
    let environments = project.environments
    let evaluator = schemaDraftEvaluator
    schemaDraftEvaluationTasks[projectID] = Task { [weak self] in
      if debounced {
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      }
      guard let evaluation = await evaluator.evaluate(draft, inFolder: folder, imports: imports, environments: environments),
        let self, !Task.isCancelled, self.schemaDraftEvaluationInputs[projectID] == inputs
      else { return }
      self.schemaDraftEvaluationTasks[projectID] = nil
      let evaluated = EvaluatedSchemaDraft(revision: inputs.revision, values: inputs.values, imports: inputs.imports, evaluation: evaluation)
      if self.schemaDraftEvaluations[projectID] != evaluated { self.schemaDraftEvaluations[projectID] = evaluated }
    }
  }

  private func clearSchemaDrafts() {
    for task in schemaDraftEvaluationTasks.values { task.cancel() }
    schemaDraftEvaluationTasks = [:]
    schemaDraftEvaluationInputs = [:]
    schemaDraftEvaluations = [:]
    schemaDrafts = [:]
    schemaDraftFolders = [:]
    schemaDraftRevisions = [:]
    schemaDraftRebases = [:]
    schemaDraftHistory = [:]
    savingSchemaDrafts = []
    debouncedSchemaDrafts = []
    schemaDraftSaveFailures = [:]
    pendingSchemaMerges = []
    schemaDraftGeneration &+= 1
  }

  /// Saves an inspector edit of one key — a rename, new values, or both — in a
  /// single transaction. Conflicts are thrown for the editor to show next to the
  /// values rather than raised as an alert.
  func saveKeyEdit(_ edit: VaultKeyEdit, in projectId: String) async throws(VaultKeyEditError) {
    guard isUnlocked else { throw .vaultLocked }
    guard selectedProjectId == projectId, let project = selectedProject, project.hasLoadedEnvironments else {
      throw .targetUnavailable
    }
    switch edit.applied(to: project.environments) {
    case .failure(let failure):
      throw VaultKeyEditError(failure, newKey: edit.newKey)
    case .success(let environments) where environments == project.environments:
      return
    case .success:
      break
    }
    let outcome = await withCheckedContinuation { continuation in
      enqueueProjectMutation(
        base: project,
        mutation: .editKey(edit),
        reportsFailures: false,
        afterCompletion: { continuation.resume(returning: $0) }
      )
    }
    switch outcome {
    case .saved:
      return
    case .changed:
      // The latest project is published; say why the edit no longer applies to it.
      if let latest = projects.first(where: { $0.id == projectId }),
        case .failure(let failure) = edit.applied(to: latest.environments)
      {
        throw VaultKeyEditError(failure, newKey: edit.newKey)
      }
      throw .changed
    case .unavailable:
      throw .targetUnavailable
    case .failed(let message):
      throw .persistence(message)
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
        Task { [platformCredentials] in await platformCredentials.resumeCleanup(now: true) }
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
    prepared: PreparedRemoteOperation<Value>,
    beforeStart: @escaping @Sendable () throws -> Void = {}
  ) async throws -> Value? {
    guard let authority else {
      try beforeStart()
      return await prepared.start().value()
    }
    let result = try await authorizedRemoteMutationExecutor(authority) {
      AuthorizedMutationBox(value: Result {
        try beforeStart()
        return prepared.start()
      })
    }
    guard let request = result as? AuthorizedMutationBox<Result<StartedRemoteOperation<Value>, any Error>>
    else { return nil }
    return await (try request.value.get()).value()
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
      Task { [platformCredentials] in await platformCredentials.resumeCleanup(now: true) }
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
    unlockFailure = nil
    unlockGeneration &+= 1
    let generation = unlockGeneration
    isUnlocking = true
    let outcome = await biometricService.authenticate(
      reason: "Unlock LPM Vault to view secrets"
    )
    guard generation == unlockGeneration else { return }
    guard outcome == .authenticated else {
      if outcome == .failed { unlockFailure = .authentication }
      isUnlocking = false
      return
    }
    keychainService.setAuthenticationContext(biometricService.keychainAuthenticationContext)
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
    unlockFailure = nil
    beginSelectedProjectLoadIfNeeded()
    // Locking forgot the list, and the page doesn't reopen to load it again.
    if accountPage == .platforms { platforms.load() }
    isUnlocking = false
    scheduleAutoLock()
    Task { [platformCredentials] in await platformCredentials.resumeCleanup(now: true) }
    Task { [weak self] in await self?.reconcilePublishingRecords() }
    if lpmHomeMoveRecovery == nil, LPMHome.unfinishedMove(in: preferences) != nil {
      lpmHomeMoveRecovery = Task { [weak self] in
        try? await self?.finishUnfinishedLPMHomeMove()
        self?.lpmHomeMoveRecovery = nil
      }
    }
  }

  /// Asks the person to authenticate for an action that sends values off the
  /// Mac, every time, however recently they unlocked. Reading and copying
  /// values on the Mac asks nothing more than unlocking did.
  func confirmSensitiveAction(reason: String) async -> Bool {
    guard isUnlocked else { return false }
    let sessionGeneration = vaultSessionGeneration
    let outcome = await biometricService.confirm(reason: reason)
    let approved = !Task.isCancelled
      && outcome == .authenticated
      && isUnlocked
      && sessionGeneration == vaultSessionGeneration
    if approved {
      keychainService.setAuthenticationContext(biometricService.keychainAuthenticationContext)
    }
    return approved
  }

  // MARK: - Backups

  /// Asks the person to authenticate before a backup reads every value,
  /// every time, however recently they unlocked. The authorization holds only
  /// while this session stays unlocked.
  func authorizeBackupExport() async -> BackupExportAuthorization? {
    guard canUseLocalSecrets else { return nil }
    let sessionGeneration = vaultSessionGeneration
    guard await confirmSensitiveAction(reason: "export a backup of your env projects"),
      sessionGeneration == vaultSessionGeneration
    else { return nil }
    return BackupExportAuthorization(sessionGeneration: sessionGeneration)
  }

  /// Seals a backup of every env project, removed ones included, with
  /// `passphrase`, and saves it to `destination`, replacing a file there.
  /// Nothing is saved once the session `authorization` came from ends or the
  /// task is cancelled.
  func exportBackup(
    _ contents: BackupExporter.Contents,
    passphrase: String,
    to destination: URL,
    authorization: BackupExportAuthorization
  ) async throws -> BackupExportResult {
    let write = writes.begin()
    defer { writes.end(write) }
    await waitForLocalStateRefresh()
    guard isUnlocked, authorization.sessionGeneration == vaultSessionGeneration else { throw CancellationError() }
    let exporter = BackupExporter(
      persistence: persistence, publishing: publishing, imagesDirectory: projectIcons.imagesDirectory)
    let appState = BackupExporter.AppState(
      settings: backupSettings(), iconChoices: projectIcons.savedChoices(for: projects.map(\.id)))
    let now = Date()
    let sealed = try await exporter.seal(
      contents,
      appState: appState,
      producerVersion: VaultBuildInfo().version,
      deviceName: BackupExporter.computerName(),
      passphrase: passphrase,
      now: now)
    try Task.checkCancellation()
    guard isUnlocked, authorization.sessionGeneration == vaultSessionGeneration else { throw CancellationError() }
    let file = sealed.file
    try await BlockingWork.run { try SecureFileWriter.write(file, to: destination) }
    let record = VaultBackupRecord(date: now, bytes: file.count)
    record.save(to: preferences)
    lastBackup = record
    return BackupExportResult(file: destination, bytes: file.count, summary: sealed.summary)
  }

  /// How many publish destinations the listed projects have, as a backup's
  /// checklist counts them; nil when one project's can't be read.
  func publishDestinationCount() async -> Int? {
    var total = 0
    for project in projects {
      guard case .success(let destinations) = await publishing.destinations(of: project.id) else { return nil }
      total += destinations.count
    }
    return total
  }

  /// The settings a backup carries, as this Mac has them.
  private func backupSettings() -> BackupAppSection.Settings {
    BackupAppSection.Settings(
      appearance: preferences.string(forKey: VaultAppearanceSettings.defaultsKey).flatMap(VaultAppearance.init(rawValue:)) ?? .system,
      keySort: preferences.string(forKey: VaultKeySortOrder.defaultsKey).flatMap(VaultKeySortOrder.init(rawValue:)) ?? .ascending,
      quitShortcut: VaultQuitShortcut.saved(in: preferences),
      updateChannel: preferences.string(forKey: UpdateChecker.channelDefaultsKey).flatMap(VaultReleaseChannel.init(rawValue:)) ?? .stable,
      projectOrder: projectOrder,
      environmentOrders: environmentOrders)
  }

  /// Writes the environment's values to `destination`, kept out of git first
  /// as `lpm env export` keeps one; returns what the user should know.
  @discardableResult
  func exportEnvironment(
    projectId: String,
    environment: String,
    to destination: URL
  ) async throws -> [String] {
    let write = writes.begin()
    defer { writes.end(write) }
    await waitForLocalStateRefresh()
    guard canUseLocalSecrets,
      selectedProjectId == projectId,
      selectedEnvironment == environment,
      let project = selectedProject
    else { throw CancellationError() }
    let requestId = UUID()
    let authorization = EnvFileExportAuthorization()
    let secrets = project.secrets(for: environment)
    let projectFolder = ProjectCLILink.folder(vaultId: project.id, projectPath: project.path, defaults: preferences)
    let task = Task { [envFileExportService] in
      try await envFileExportService.export(
        secrets: secrets,
        to: destination,
        projectFolder: projectFolder,
        authorization: authorization
      )
    }
    exportAuthorizations[requestId] = authorization
    exportTasks[requestId] = task
    defer {
      exportAuthorizations.removeValue(forKey: requestId)
      exportTasks.removeValue(forKey: requestId)
    }

    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      authorization.invalidate()
      task.cancel()
    }
  }

  /// What `home` holds that moving it would take; nil when it can't be read.
  func lpmHomeContents(_ home: LPMHome) async -> LPMHomeMove.Contents? {
    let move = lpmHomeMove(nil)
    return await BlockingWork.run { try? move.contents(of: home) }
  }

  /// The LPM home at `url`, as the CLI with `LPM_HOME` set to it would use
  /// it; nil when the engine can't place it.
  func lpmHome(at url: URL) async -> LPMHome? {
    let resolve = lpmHomeResolver
    let userHome = lpmHome.userHome
    return await BlockingWork.run { resolve(url, userHome) }
  }

  /// Makes `target` the LPM home and relaunches the app, which then uses it.
  /// With `moving`, what the current home holds moves there first, once the
  /// user confirms with Touch ID or their password, holding both homes' login
  /// and transaction locks, so neither the CLI nor this app changes either
  /// meanwhile. Removes what a move that didn't end left first, as changing
  /// homes would lose which home holds its copies.
  func changeLPMHome(to target: LPMHome, moving: Bool) async throws {
    guard isUnlocked, target.scope != lpmHome.scope else { throw CancellationError() }
    let source = lpmHome
    let preferences = ThreadSafeDefaults(defaults: preferences)
    let exposure = try await BlockingWork.run {
      do throws(CLIFiles.Refusal) { return try CLIFiles.prepareHome(target) } catch { throw LPMHomeMoveError.copyFailed(error.message) }
    }
    if let exposure { throw LPMHomeMoveError.targetExposed(exposure.explanation(of: "login and env secrets")) }
    if moving {
      guard await confirmSensitiveAction(reason: "move your env projects and sign-in to \(target.displayPath)") else {
        throw CancellationError()
      }
    }
    let write = writes.begin()
    do {
      await lpmHomeMoveRecovery?.value
      try await finishUnfinishedLPMHomeMove()
      if moving {
        try await move(from: source, to: target, preferences: preferences)
      } else {
        LPMHome.choose(target, in: preferences.defaults)
      }
      writes.end(write)
    } catch {
      writes.end(write)
      throw error
    }
    lock()
    relaunch()
  }

  private func move(from source: LPMHome, to target: LPMHome, preferences: ThreadSafeDefaults) async throws {
    let move = lpmHomeMove(biometricService.keychainAuthenticationContext)
    let logins = AuthSessionCoordinator(
      home: source, credentialBackend: lpmHomeCredentials(source),
      refreshOperation: { _, _, _ in throw AuthSessionRefreshError.invalidResponse })
    LPMHome.beginMove(from: source, to: target, in: preferences.defaults)
    let leftovers: [String]
    do {
      leftovers = try await AuthSessionCoordinator.withLoginLocks(of: source) {
        try await AuthSessionCoordinator.withLoginLocks(of: target) {
          try await BlockingWork.run {
            try move.move(from: source, to: target, prepareSource: { try logins.upgradeLegacyCredentialsHoldingLocks() }) {
              LPMHome.choose(target, in: preferences.defaults)
              VaultKeychainTransactionLock.retire(source)
            }
          }
        }
      }
    } catch {
      if (error as? LPMHomeMoveError)?.leftCopies != true { LPMHome.endMove(in: preferences.defaults) }
      throw error
    }
    LPMHome.recordLeftovers(leftovers, of: source, in: preferences.defaults)
    LPMHome.endMove(in: preferences.defaults)
  }

  /// Removes the copies a move that didn't end left in whichever of its two
  /// homes the app doesn't use, holding both homes' login locks, and keeps
  /// what couldn't be removed for Settings to show. A move between homes the
  /// engine can no longer place, or neither of which the app uses, ends
  /// without removing anything.
  func finishUnfinishedLPMHomeMove() async throws {
    guard let record = LPMHome.unfinishedMove(in: preferences) else { return }
    let write = writes.begin()
    defer { writes.end(write) }
    let current = lpmHome
    let resolve = lpmHomeResolver
    let preferences = ThreadSafeDefaults(defaults: preferences)
    let homes = await BlockingWork.run { () -> (from: LPMHome, to: LPMHome)? in
      guard let from = resolve(record.from, current.userHome), let to = resolve(record.to, current.userHome),
        current.scope == from.scope || current.scope == to.scope
      else { return nil }
      return (from, to)
    }
    guard let homes else {
      LPMHome.endMove(in: preferences.defaults)
      return
    }
    let switched = current.scope == homes.to.scope
    let move = lpmHomeMove(biometricService.keychainAuthenticationContext)
    let left = try await AuthSessionCoordinator.withLoginLocks(of: homes.from) {
      try await AuthSessionCoordinator.withLoginLocks(of: homes.to) {
        try await BlockingWork.run { try move.removeCopies(between: homes.from, and: homes.to, switched: switched) }
      }
    }
    if !left.isEmpty {
      LPMHome.recordLeftovers(left, of: switched ? homes.from : homes.to, in: preferences.defaults)
    }
    LPMHome.endMove(in: preferences.defaults)
  }

  private func cancelExports() {
    for authorization in exportAuthorizations.values { authorization.invalidate() }
    for task in exportTasks.values { task.cancel() }
    exportAuthorizations.removeAll(keepingCapacity: true)
    exportTasks.removeAll(keepingCapacity: true)
  }

  func lock() {
    lastSyncWarnings = []
    unlockFailure = nil
    keyDrafts.discardAll()
    rawTextDrafts.removeAll()
    discardAllProjectSettings()
    openSheetWork.removeAll()
    clearKeyDescriptions()
    cancelCliAccessChange()
    cliAccessLoadTask?.cancel()
    cliAccessLoadGeneration &+= 1
    selectedProjectCliAccess = nil
    projectCliAccess.removeAll(keepingCapacity: true)
    cliAccessProjectRevisions.removeAll(keepingCapacity: true)
    keychainService.setAuthenticationContext(nil)
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
    autoLockCountdownSeconds = nil
    autoLockTaskGeneration &+= 1
    isUnlocked = false
    cancelLocalStateRefresh()
    localStateRefreshError = nil
    biometricService.resetCache()
    clipboard.clearClipboard()
    projects = projects.map { VaultProject(metadata: $0.metadata) }
    workspaceSnapshots = [:]
    platforms.reset()
    // Nothing can be sent without a session while locked; unlocking resumes it.
    Task { [platformCredentials] in await platformCredentials.stopCleanup() }
    for entry in publishSessions { entry.session?.cancel() }
    publishSessions = []
    publishDestinations = [:]
    forgetConnectionDetails()
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
    autoLockCountdownSeconds = nil
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
          let countdownDuration = VaultConstants.vaultAutoLockCountdownDuration
          autoLockCountdownSeconds = remaining <= countdownDuration ? Int(ceil(remaining)) : nil
          let sleepDuration = remaining > countdownDuration
            ? remaining - countdownDuration
            : min(1, remaining)
          try await autoLockSleep(.seconds(sleepDuration))
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
    invalidateLocalStateRefresh()
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
    let write = writes.begin()
    defer { writes.end(write) }
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
    let environments = pushedProject.environments
    let encryptor = stableSyncEncryptor
    var plaintext: Data?
    var schema: LPMJSONValue?
    var schemaSources: CapturedSyncSchema?
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
            try JSONEncoder().encode(["environments": environments])
          }
          plaintext = try await serializationTask.value
          guard await hasCurrentSyncAuth(authority) else {
            finishSyncIfOwned(authority)
            return
          }
          let captured = try await capturedSyncSchema(for: pushedProject)
          schema = captured.value
          schemaSources = captured
          preparedPayload = true
        }
        guard let plaintext else {
          throw VaultSyncError("Could not serialize the env project for sync.")
        }
        let targetRevision = try Self.nextSyncRevision(after: expectedVersion)
        let preparedPush = try await syncService.preparePersonalPush(
          authToken: authToken,
          expectedPrincipalId: authority.principalID,
          vaultId: pushedProject.id,
          plaintext: plaintext,
          expectedVersion: expectedVersion,
          force: force,
          recreateMissing: recreateMissing,
          name: pushedProject.name,
          schema: schema,
          legacyEncryptor: encryptor
        )
        guard await hasCurrentSyncAuth(authority) else {
          finishSyncIfOwned(authority)
          return
        }
        let currentSchemaSources = schemaSources
        guard
          let response = try await executeAuthorizedRemoteMutation(
            authority: authority.authorityGeneration,
            prepared: preparedPush,
            beforeStart: { try currentSchemaSources?.verify() }
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
          var checkpointWarning: String?
          if persistedCommit != nil, let envelope = result?.personalKeys, await hasCurrentDurableSyncAuth(authority) {
            do { try await syncService.rememberPersonalKeys(envelope, principalID: authority.principalID, vaultID: pushedProject.id) }
            catch { checkpointWarning = "The push succeeded, but the local key checkpoint could not be saved: \(error.localizedDescription)" }
          }
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
            error = checkpointWarning
            lastSyncWarnings = result?.warnings ?? []
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
    let write = writes.begin()
    defer { writes.end(write) }
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
    if let message = result.displayError,
      result.vaultId == baselineProject.id,
      result.principalId == authority.principalID
    {
      error = message
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

    guard result.encryptedBlob != nil, result.wrappedKey != nil else {
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

      let jsonData = try await syncService.decryptPersonalPayload(result, legacyDecryptor: stableSyncDecryptor)
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
        if let envelope = result.personalKeys, await hasCurrentDurableSyncAuth(authority) {
          do { try await syncService.rememberPersonalKeys(envelope, principalID: authority.principalID, vaultID: baselineProject.id) }
          catch {
            if await hasCurrentSyncAuth(authority) {
              self.error = "The pull succeeded, but the local key checkpoint could not be saved: \(error.localizedDescription)"
            }
          }
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
      let (_, pubKey) = try await BlockingWork.run {
        try keypairProvider(
          registryURL,
          callerUserID,
          expectedPublicKey,
          expectedFingerprint
        )
      }
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
    let write = writes.begin()
    defer { writes.end(write) }
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
      let (_, localPublicKey) = try await BlockingWork.run {
        try keypairProvider(
          registryURL,
          callerUserID,
          expectedPublicKey,
          expectedFingerprint
        )
      }
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
    let write = writes.begin()
    defer { writes.end(write) }
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
    let environments = pushedProject.environments
    let scopeSlug = orgSlug(for: authority)
    let encrypted: (blob: String, wrappedKeys: [SyncService.WrappedMemberKey]?)
    let expectedVersion = pushSnapshot.metadata?.lastVersion
    let targetRevision = try Self.nextSyncRevision(after: expectedVersion)
    if canReplaceWrappedKeys {
      let projectID = pushedProject.id
      encrypted = try await Task.detached(priority: .userInitiated) {
        let payload = ["environments": environments]
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
      if let current, let message = current.displayError {
        guard current.matchesOrganizationErrorContext(
          vaultID: pushedProject.id, organizationSlug: scopeSlug,
          callerUserID: callerUserID, organizationID: authority.principalID
        ) else {
          throw VaultSyncError(
            "The organization access response did not match the authenticated account."
          )
        }
        throw VaultSyncError(message)
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
      let (privateKey, publicKey) = try await BlockingWork.run {
        try keypairProvider(
          registryURL,
          callerUserID,
          nil,
          expectedFingerprint
        )
      }
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
        let payload = ["environments": environments]
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
    let schema = try await capturedSyncSchema(for: pushedProject)
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
      schema: schema.value
    )
    guard await hasCurrentSyncAuth(authority) else {
      finishSyncIfOwned(authority)
      return .failed
    }
    guard
      let response = try await executeAuthorizedRemoteMutation(
        authority: authority.authorityGeneration,
        prepared: preparedPush,
        beforeStart: { try schema.verify() }
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
      lastSyncWarnings = result?.warnings ?? []
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
    let write = writes.begin()
    defer { writes.end(write) }
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
    let write = writes.begin()
    defer { writes.end(write) }
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
        let (_, publicKey) = try await BlockingWork.run {
          try keypairProvider(
            registryURL,
            callerUserID,
            registeredKey,
            expectedFingerprint
          )
        }
        guard registeredKey == publicKey.base64EncodedString() else {
          throw VaultSyncError(
            "This device does not hold the sharing key registered for your account."
          )
        }
        throw VaultSyncError(
          "Your registered sharing key does not have access to this env project yet. Ask an organization admin to share it again."
        )
      }
      if let message = result.displayError {
        guard result.matchesOrganizationErrorContext(
          vaultID: baselineProject.id, organizationSlug: orgSlug,
          callerUserID: currentUserID, organizationID: authority.principalID
        ) else {
          throw VaultSyncError(
            "The organization access response did not match the authenticated account."
          )
        }
        error = message
        finishSyncIfOwned(authority)
        lastSyncStatus = "failed"
        return
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
      let (privKey, pubKey) = try await BlockingWork.run {
        try keypairProvider(
          registryURL,
          callerUserID,
          nil,
          expectedFingerprint
        )
      }
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

	func syncSchema(for project: VaultProject) async throws -> LPMJSONValue? {
		try await capturedSyncSchema(for: project).value
	}

	private struct CapturedSyncSchema: Sendable {
		let value: LPMJSONValue?
		let sources: ProjectEnvSchemaFile.SyncSnapshot?
		func verify() throws { try sources?.verify() }
	}

	private func capturedSyncSchema(for project: VaultProject) async throws -> CapturedSyncSchema {
		let path = keyDescriptionFolder(for: project)
    guard !path.isEmpty else { return CapturedSyncSchema(value: nil, sources: nil) }
    let projectID = project.id
    return try await BlockingWork.run {
      let captured: ProjectEnvSchemaFile.SyncSnapshot
      do { captured = try ProjectEnvSchemaFile.validatedSyncSnapshot(inFolder: path, vaultID: projectID) }
      catch ProjectEnvSchemaFile.FileError.noFolder { return CapturedSyncSchema(value: nil, sources: nil) }
      guard case .object(let root)? = captured.config else {
        return CapturedSyncSchema(value: nil, sources: captured)
      }

      return CapturedSyncSchema(value: ProjectEnvSchemaFile.pushMetadata(from: root), sources: captured)
    }
  }

  // MARK: - Private

  private func enqueueSchemaKeyRename(
    base project: VaultProject,
    edit: VaultKeyEdit,
    change: ProjectEnvSchemaFile.Change,
    folder: String,
    folderIdentity: ProjectConfigFile.DirectoryIdentity? = nil,
    afterCompletion: @escaping @MainActor (Result<Void, VaultKeyEditError>) -> Void
  ) {
    cancelLocalEnvImports(projectId: project.id)
    invalidateProjectLoad()
    let predecessor = projectMutationTask
    let requestId = UUID()
    let sessionGeneration = vaultSessionGeneration
    let draftGeneration = keyDrafts.generation
    projectMutationRequestId = requestId
    let write = writes.begin()
    projectMutationTask = Task { @MainActor [weak self, persistence, writes] in
      defer { writes.end(write) }
      await predecessor?.value
      guard let self, sessionGeneration == vaultSessionGeneration, draftGeneration == keyDrafts.generation, isUnlocked,
        selectedProjectId == project.id
      else { afterCompletion(.failure(.targetUnavailable)); return }
      guard keyDescriptionFolder(for: project) == folder else {
        reloadKeyDescriptions()
        afterCompletion(.failure(.description("The project folder changed. Review its descriptions, then save again.", keySaved: false)))
        return
      }
      beginOwnSchemaWrite(project.id)
      defer { endOwnSchemaWrite(project.id) }
      let result = await persistence.renameKeyWithSchema(project: project, edit: edit, change: change, folder: folder, folderIdentity: folderIdentity)
      let saved: Bool? = switch result {
      case .success: true
      case .indeterminate: nil
      default: false
      }
      let follow = await Self.followPublishing(
        .editKey(edit), base: project, saved: saved, persistence: persistence, publishing: publishing)
      if follow.touchedDestinations { await refreshPublishMenu(for: project.id) }
      guard sessionGeneration == vaultSessionGeneration, draftGeneration == keyDrafts.generation, isUnlocked else {
        afterCompletion(.failure(.targetUnavailable)); return
      }
      switch result {
      case .success(let commit, let rules, let rootSchema):
        updateProjectInPlace(commit.project)
        applySyncMetadata(commit.syncMetadata, for: commit.project.id)
        error = commit.warning ?? follow.failure.map(Self.publishingFollowMessage)
        if let rules, keyDescriptionFolder(for: commit.project) == folder {
          publishSavedRules(rules, rootSchema: rootSchema, folder: folder, for: project.id,
            description: change.description.map { ($0.key, $0.text) })
        }
        afterCompletion(.success(()))
      case .conflict(let latest, let metadata, let failure):
        updateProjectInPlace(latest)
        applySyncMetadata(metadata, for: latest.id)
        afterCompletion(.failure(failure))
      case .schemaChanged:
        let loaded = await ProjectEnvSchemaFile.loadRules(inFolder: folder, vaultID: project.id)
        guard sessionGeneration == vaultSessionGeneration, draftGeneration == keyDrafts.generation, isUnlocked else { afterCompletion(.failure(.targetUnavailable)); return }
        if let latest = projects.first(where: { $0.id == project.id }), keyDescriptionFolder(for: latest) == folder {
          publishKeyDescriptions(ProjectKeyDescriptions(folder: folder, loaded: loaded), for: project.id)
        }
        afterCompletion(.failure(.description(ProjectEnvSchemaFile.FileError.changed.localizedDescription, keySaved: false)))
      case .failure(let failure):
        afterCompletion(.failure(failure))
      case .indeterminate:
        _ = await loadProjects(ownedByKeyDraftGeneration: draftGeneration)
        afterCompletion(.failure(.persistence(KeychainError.transactionOutcomeIndeterminate.description)))
      }
    }
  }

  private func enqueueProjectMutation(
    base project: VaultProject,
    mutation: VaultProjectMutation,
    afterCommit: @escaping @MainActor (VaultProject) -> Void = { _ in },
    reportsFailures: Bool = true,
    afterCompletion: @escaping @MainActor (ProjectMutationOutcome) -> Void = { _ in }
  ) {
    cancelLocalEnvImports(projectId: project.id)
    invalidateProjectLoad()
    let predecessor = projectMutationTask
    let requestId = UUID()
    let sessionGeneration = vaultSessionGeneration
    projectMutationRequestId = requestId
    let write = writes.begin()
    let task = Task { @MainActor [weak self, persistence, publishing, writes] in
      defer { writes.end(write) }
      await predecessor?.value
      let result = await persistence.mutateProject(
        projectId: project.id,
        expectedName: project.name,
        expectedPath: project.path,
        mutation: mutation
      )
      let saved: Bool? = switch result {
      case .success: true
      case .failure(.transactionOutcomeIndeterminate): nil
      default: false
      }
      let follow = await Self.followPublishing(
        mutation, base: project, saved: saved, persistence: persistence, publishing: publishing)
      if follow.touchedDestinations { await self?.refreshPublishMenu(for: project.id) }
      guard let self else {
        afterCompletion(.unavailable)
        return
      }
      guard sessionGeneration == vaultSessionGeneration, isUnlocked else {
        afterCompletion(.unavailable)
        return
      }
      switch result {
      case .success(let persisted):
        updateProjectInPlace(persisted.project)
        applySyncMetadata(persisted.syncMetadata, for: persisted.project.id)
        error = persisted.warning ?? follow.failure.map(Self.publishingFollowMessage)
        afterCommit(persisted.project)
        afterCompletion(.saved)
      case .conflict(let latest, let metadata):
        updateProjectInPlace(latest)
        applySyncMetadata(metadata, for: latest.id)
        if reportsFailures {
          error =
            "This env project changed in another LPM process. Review the latest values and retry."
        }
        afterCompletion(.changed)
      case .targetUnavailable:
        if reportsFailures {
          error = "The target env project changed before the update was saved."
        }
        afterCompletion(.unavailable)
      case .failure(let persistenceError):
        if reportsFailures { error = persistenceError.description }
        if case .transactionOutcomeIndeterminate = persistenceError {
          _ = await loadProjects()
        }
        afterCompletion(.failed(persistenceError.description))
      }
    }
    projectMutationTask = task
  }

  /// What following a vault change did to its publish destinations.
  private enum PublishingFollow {
    /// The change doesn't move or remove destinations, or wasn't saved.
    case untouched
    case followed
    /// The destinations couldn't follow, or only some did.
    case failed(PublishingStoreError)

    var touchedDestinations: Bool {
      if case .untouched = self { false } else { true }
    }

    var failure: PublishingStoreError? {
      if case .failed(let failure) = self { failure } else { nil }
    }
  }

  /// Keeps publish destinations on an environment or key the vault renamed,
  /// and removes those of a deleted environment. `saved` is nil when the
  /// Keychain couldn't say whether the change was saved; the vault is then
  /// read back to find out. The change is already saved when this runs, so
  /// it runs even if the vault locks meanwhile.
  private static func followPublishing(
    _ mutation: VaultProjectMutation,
    base project: VaultProject,
    saved: Bool?,
    persistence: VaultPersistenceCoordinator,
    publishing: PublishingStore
  ) async -> PublishingFollow {
    switch mutation {
    case .renameEnvironment, .deleteEnvironment: break
    case .editKey(let edit) where edit.isRename: break
    default: return .untouched
    }
    switch saved {
    case true?: break
    case false?: return .untouched
    case nil:
      guard case .success(let latest) = await persistence.loadProject(vaultId: project.id),
        isApplied(mutation, base: project, latest: latest)
      else { return .untouched }
    }
    let result: Result<Void, PublishingStoreError>
    switch mutation {
    case .renameEnvironment(let source, _, let destination):
      result = await publishing.renameEnvironment(source, to: destination, in: project.id)
    case .deleteEnvironment(let name, _):
      result = await publishing.removeDestinations(sourcedFrom: name, in: project.id)
    case .editKey(let edit):
      let environments = Set(VaultKeyEdit.environments(containing: edit.key, in: project.environments))
      result = await publishing.renameKey(edit.key, to: edit.newKey, sourcedFrom: environments, in: project.id)
    default:
      return .untouched
    }
    if case .failure(let failure) = result { return .failed(failure) }
    return .followed
  }

  /// Deletes the publishing records of vaults whose local copy is gone,
  /// such as one whose deletion's outcome was lost. A project only removed
  /// from the sidebar keeps its payload, and with it its records.
  func reconcilePublishingRecords() async {
    _ = await publishing.deleteOrphanedRecords()
  }

  /// Whether `latest` shows `mutation` applied to `base`.
  private static func isApplied(_ mutation: VaultProjectMutation, base: VaultProject, latest: VaultProject?) -> Bool {
    guard let latest else { return false }
    switch mutation {
    case .renameEnvironment(let source, _, let destination):
      return latest.environments[source] == nil && latest.environments[destination] != nil
    case .deleteEnvironment(let name, _):
      return latest.environments[name] == nil
    case .editKey(let edit) where edit.isRename:
      let renamed = VaultKeyEdit.environments(containing: edit.key, in: base.environments)
      return !renamed.isEmpty && renamed.allSatisfy { name in
        latest.environments[name]?[edit.key] == nil && latest.environments[name]?[edit.newKey] != nil
      }
    default:
      return false
    }
  }

  private static func publishingFollowMessage(_ failure: PublishingStoreError) -> String {
    "The change was saved, but its publish destinations couldn't be updated: \(failure)"
  }

  /// Returns true once nothing is being written to the Keychain, a project's
  /// lpm.json, an exported file or a platform, or false when `timeout` passes first.
  func finishWritesInProgress(within timeout: Duration) async -> Bool {
    await writes.finish(within: timeout)
  }

  /// Whether anything is being written, which quitting waits for.
  var isWriting: Bool { writes.isWriting }

  /// Notes what an open sheet holds, until it's saved, discarded or closed.
  func holdSheetWork(_ work: VaultUnsavedWork.OpenSheet) {
    if openSheetWork[work.id] != work { openSheetWork[work.id] = work }
  }

  func releaseSheetWork(_ id: UUID) {
    if openSheetWork[id] != nil { openSheetWork[id] = nil }
  }

  /// Selects a project and waits until its values and rules are loaded, so
  /// its unsaved edits can be saved; false when it can't be loaded.
  func openProjectForSaving(_ projectID: String, timeout: Duration) async -> Bool {
    guard isUnlocked, projects.contains(where: { $0.id == projectID }) else { return false }
    if selectedProjectId != projectID || isShowingAccountPage { openProject(id: projectID) }
    guard selectedProjectId == projectID else { return false }
    reloadKeyDescriptions()
    let loaded = await ObservedWait.value(within: timeout) { [weak self] () -> Bool? in
      guard let self, isUnlocked, selectedProjectId == projectID, selectedProjectLoadFailure == nil else { return false }
      guard let project = selectedProject, project.hasLoadedEnvironments, !isLoadingSelectedProject,
        !isReloadingKeyDescriptions, keyDescriptions[projectID] != nil
      else { return nil }
      return true
    }
    return loaded ?? false
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
    preferences.set(normalized, forKey: Self.envOrderPrefix + projectId)
  }

  private func forgetPreferences(ofVault vaultId: String) {
    if projectOrder.contains(vaultId) {
      projectOrder.removeAll { $0 == vaultId }
      preferences.set(projectOrder, forKey: Self.projectOrderKey)
    }
    environmentOrders.removeValue(forKey: vaultId)
    preferences.removeObject(forKey: Self.envOrderPrefix + vaultId)
    ProjectCLILink.forgetFolder(vaultId: vaultId, defaults: preferences)
    projectIcons.forget(vaultId)
  }

  /// Removes preferences of vaults that are no longer on this Mac, such as
  /// vaults the CLI deleted while the app was closed.
  private func forgetPreferences(ofVaultsOutside vaultIds: Set<String>) {
    var seen: Set<String> = []
    let normalized = projectOrder.filter { vaultIds.contains($0) && seen.insert($0).inserted }
    if normalized != projectOrder {
      projectOrder = normalized
      preferences.set(normalized, forKey: Self.projectOrderKey)
    }
    let prefixes = [Self.envOrderPrefix, ProjectCLILink.folderKeyPrefix]
    for key in preferences.dictionaryRepresentation().keys {
      guard let prefix = prefixes.first(where: key.hasPrefix),
        !vaultIds.contains(String(key.dropFirst(prefix.count)))
      else { continue }
      preferences.removeObject(forKey: key)
    }
    projectIcons.forget(keeping: vaultIds)
  }

  private func loadEnvironmentOrders() {
    for project in projects {
      let key = Self.envOrderPrefix + project.id
      if let saved = preferences.stringArray(forKey: key) {
        environmentOrders[project.id] = saved
      }
    }
  }
}

/// A Publish sheet's session, held without keeping it alive.
private struct WeakPublishSession {
  weak var session: PublishSession?
}
