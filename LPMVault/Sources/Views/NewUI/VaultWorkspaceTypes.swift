import Foundation

enum VaultWorkspaceMode: Equatable {
  case matrix
  case environment(String)

  func synchronized(to selectedEnvironment: String) -> Self {
    switch self {
    case .matrix: .matrix
    case .environment: .environment(selectedEnvironment)
    }
  }
}

enum VaultWorkspaceFilter: String, CaseIterable, Identifiable {
  case all = "All keys"
  case drift = "Drift"
  case missing = "Missing"

  var id: String { rawValue }
}

enum VaultEnvironmentViewMode: String, CaseIterable, Identifiable {
  case table = "Table"
  case raw = "Raw text"

  var id: String { rawValue }
}

struct VaultSecretTarget: Identifiable {
  let id = UUID()
  let projectId: String
  let environment: String
}

struct VaultSecretDeleteTarget: Identifiable {
  var id: String { "\(projectId)-\(environment)-\(key)" }
  let projectId: String
  let environment: String
  let key: String
}

struct VaultEnvironmentTarget: Identifiable {
  var id: String { "\(projectId)-\(environment)" }
  let projectId: String
  let environment: String
}

struct VaultSyncTarget: Identifiable, Equatable {
  let projectId: String
  let account: SelectedAccount

  var id: String {
    switch account {
    case .personal: "personal:\(projectId)"
    case .org(let slug): "org:\(slug):\(projectId)"
    }
  }
}

enum VaultConflictRecoveryAction {
  case pullAndMerge
  case forcePush
}

enum VaultConflictRecoveryPolicy {
  static func allowsForcePush(for account: SelectedAccount) -> Bool {
    account == .personal
  }

  static func primaryActionLabel(for account: SelectedAccount) -> String {
    switch account {
    case .personal: "Pull & Merge"
    case .org: "Retry Pull"
    }
  }
}

enum VaultTaskOwnership {
  static func canStart(current: UUID?) -> Bool {
    current == nil
  }

  static func owns(current: UUID?, request: UUID) -> Bool {
    current == request
  }
}

struct VaultSensitiveActionContext: Equatable {
  let projectID: String
  let environment: String

  func isCurrent(
    isUnlocked: Bool,
    selectedProjectID: String?,
    selectedEnvironment: String
  ) -> Bool {
    isUnlocked
      && selectedProjectID == projectID
      && selectedEnvironment == environment
  }
}

enum VaultCreationDismissalPolicy {
	enum ApprovalAction: Equatable {
		case wait
		case dismiss
		case retry
	}

  static func canDismiss(isCreating: Bool) -> Bool {
    !isCreating
  }

	static func approvalAction(for status: String?) -> ApprovalAction {
		guard let status else { return .wait }
		if status.hasPrefix("Shared with ") { return .dismiss }
		if status == "failed" || status == "rejected" { return .retry }
		return .wait
	}
}

extension VaultStore {
  @MainActor
  func recoverFromConflict(
    _ action: VaultConflictRecoveryAction,
    target: VaultSyncTarget
  ) async {
    guard selectedAccount == target.account,
      selectedProject?.id == target.projectId
    else { return }
    switch (target.account, action) {
    case (.personal, .pullAndMerge):
      guard await pullFromCloud() else { return }
      guard selectedAccount == target.account,
        selectedProject?.id == target.projectId
      else { return }
      await pushToCloud()
    case (.personal, .forcePush):
      await pushToCloud(force: true)
    case (.org(let slug), .pullAndMerge):
      await pullFromOrg(orgSlug: slug)
    case (.org, .forcePush):
      return
    }
  }
}

struct VaultWorkspaceSnapshot: Equatable, Sendable {
  struct KeySummary: Equatable, Sendable {
    let environmentCount: Int
    let hasDrift: Bool
    let normalizedKey: String
  }

  private struct KeyAccumulator {
    let firstValue: String
    var environmentCount: Int
    var hasDrift: Bool

    mutating func observe(_ value: String) {
      environmentCount += 1
      if value != firstValue {
        hasDrift = true
      }
    }
  }

  let allSecretKeys: [String]
  let normalizedSecretKeys: [String]
  let sortedKeysByEnvironment: [String: [String]]
  let normalizedSearchIndex: String
  let summaries: [String: KeySummary]
  let environmentCount: Int
  let driftingKeyCount: Int
  let missingKeyCount: Int
  let sourceIdentity: UUID

  init(project: VaultProject) {
    self.init(project: project, cancellationCheck: { false })!
  }

  init?(cancellableProject project: VaultProject) {
    self.init(project: project, cancellationCheck: { Task.isCancelled })
  }

  private init?(
    project: VaultProject,
    cancellationCheck: () -> Bool
  ) {
    guard !cancellationCheck() else { return nil }
    sourceIdentity = project.workspaceSnapshotIdentity
    var accumulators: [String: KeyAccumulator] = [:]
    var sortedKeysByEnvironment: [String: [String]] = [:]
    sortedKeysByEnvironment.reserveCapacity(project.environments.count)
    for (environment, secrets) in project.environments {
      guard !cancellationCheck() else { return nil }
      for (index, element) in secrets.enumerated() {
        if index.isMultiple(of: 256), cancellationCheck() { return nil }
        let (key, value) = element
        if var accumulator = accumulators[key] {
          accumulator.observe(value)
          accumulators[key] = accumulator
        } else {
          accumulators[key] = KeyAccumulator(
            firstValue: value,
            environmentCount: 1,
            hasDrift: false
          )
        }
      }
      guard !cancellationCheck() else { return nil }
      sortedKeysByEnvironment[environment] = Self.sortedKeys(secrets.keys)
      guard !cancellationCheck() else { return nil }
    }
    self.sortedKeysByEnvironment = sortedKeysByEnvironment

    environmentCount = project.environments.count
    if project.environments.count == 1,
      let environment = project.environments.keys.first,
      let sortedKeys = sortedKeysByEnvironment[environment]
    {
      allSecretKeys = sortedKeys
    } else {
      guard !cancellationCheck() else { return nil }
      allSecretKeys = Self.sortedKeys(accumulators.keys)
      guard !cancellationCheck() else { return nil }
    }
    var normalizedSecretKeys: [String] = []
    normalizedSecretKeys.reserveCapacity(allSecretKeys.count)
    for (index, key) in allSecretKeys.enumerated() {
      if index.isMultiple(of: 256), cancellationCheck() { return nil }
      normalizedSecretKeys.append(key.lowercased())
    }
    self.normalizedSecretKeys = normalizedSecretKeys
    guard !cancellationCheck() else { return nil }
    normalizedSearchIndex = normalizedSecretKeys.joined(separator: "\0")
    guard !cancellationCheck() else { return nil }

    var summaries: [String: KeySummary] = [:]
    summaries.reserveCapacity(allSecretKeys.count)
    var drifting = 0
    var missing = 0
    for (index, pair) in zip(allSecretKeys, normalizedSecretKeys).enumerated() {
      if index.isMultiple(of: 256), cancellationCheck() { return nil }
      let (key, normalizedKey) = pair
      guard let accumulator = accumulators[key] else { continue }
      let count = accumulator.environmentCount
      let hasDrift = accumulator.hasDrift
      if hasDrift { drifting += 1 }
      if count < environmentCount { missing += 1 }
      summaries[key] = KeySummary(
        environmentCount: count,
        hasDrift: hasDrift,
        normalizedKey: normalizedKey
      )
    }
    self.summaries = summaries
    driftingKeyCount = drifting
    missingKeyCount = missing
  }

  func sortedKeys(for environment: String) -> [String] {
    sortedKeysByEnvironment[environment] ?? []
  }

  func missingKeyCount(for environment: String) -> Int {
    allSecretKeys.count - (sortedKeysByEnvironment[environment]?.count ?? 0)
  }

  private static func sortedKeys<S: Sequence>(_ keys: S) -> [String]
  where S.Element == String {
    keys.sorted {
      let comparison = $0.localizedCaseInsensitiveCompare($1)
      return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
    }
  }

  func hasDrift(for key: String) -> Bool {
    summaries[key]?.hasDrift ?? false
  }

  func isMissingSomewhere(_ key: String) -> Bool {
    guard let summary = summaries[key] else { return false }
    return summary.environmentCount < environmentCount
  }

  func environmentCount(for key: String) -> Int {
    summaries[key]?.environmentCount ?? 0
  }

  func normalizedKey(for key: String) -> String {
    summaries[key]?.normalizedKey ?? key.lowercased()
  }
}

struct VaultWorkspaceSnapshotUpdate: Sendable {
  let snapshots: [String: VaultWorkspaceSnapshot]
  let buildCount: Int
}

actor VaultWorkspaceSnapshotBuilder {
  typealias SnapshotFactory = @Sendable (VaultProject) -> VaultWorkspaceSnapshot?

  private let snapshotFactory: SnapshotFactory

  init(
    snapshotFactory: @escaping SnapshotFactory = {
      VaultWorkspaceSnapshot(cancellableProject: $0)
    }
  ) {
    self.snapshotFactory = snapshotFactory
  }

  func buildIncremental(
    currentProjects: [VaultProject],
    existingSnapshots: [String: VaultWorkspaceSnapshot]
  ) -> VaultWorkspaceSnapshotUpdate? {
    guard !Task.isCancelled else { return nil }
    let currentIDs = Set(currentProjects.map(\.id))
    var snapshots = existingSnapshots.filter { currentIDs.contains($0.key) }
    snapshots.reserveCapacity(currentProjects.count)
    var buildCount = 0
    for project in currentProjects {
      guard !Task.isCancelled else { return nil }
      guard project.hasLoadedEnvironments else { continue }
      guard snapshots[project.id]?.sourceIdentity != project.workspaceSnapshotIdentity else {
        continue
      }
      guard let snapshot = snapshotFactory(project) else { return nil }
      snapshots[project.id] = snapshot
      buildCount += 1
    }
    return VaultWorkspaceSnapshotUpdate(
      snapshots: snapshots,
      buildCount: buildCount
    )
  }

  func buildAll(_ projects: [VaultProject]) -> [String: VaultWorkspaceSnapshot]? {
    guard !Task.isCancelled else { return nil }
    var snapshots: [String: VaultWorkspaceSnapshot] = [:]
    snapshots.reserveCapacity(projects.count)
    for project in projects {
      guard project.hasLoadedEnvironments else { continue }
      guard !Task.isCancelled,
        let snapshot = snapshotFactory(project)
      else { return nil }
      snapshots[project.id] = snapshot
    }
    return snapshots
  }
}

struct VaultContentDerivation: Equatable {
  let allKeys: [String]
  let filteredKeys: [String]
  let environmentKeys: [String]
  let environmentDriftingKeyCount: Int
  let allVisibleRevealed: Bool

  init(
    project: VaultProject,
    snapshot: VaultWorkspaceSnapshot,
    selectedEnvironment: String,
    mode: VaultWorkspaceMode,
    filter: VaultWorkspaceFilter,
    searchText: String,
    revealedKeys: Set<String>
  ) {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    allKeys = snapshot.allSecretKeys
    switch mode {
    case .matrix:
      if filter == .all, query.isEmpty {
        filteredKeys = allKeys
      } else {
        var matchingKeys: [String] = []
        matchingKeys.reserveCapacity(allKeys.count)
        for index in allKeys.indices {
          let key = allKeys[index]
          let matchesFilter: Bool
          switch filter {
          case .all: matchesFilter = true
          case .drift: matchesFilter = snapshot.hasDrift(for: key)
          case .missing: matchesFilter = snapshot.isMissingSomewhere(key)
          }
          if matchesFilter,
            query.isEmpty || snapshot.normalizedSecretKeys[index].contains(query)
          {
            matchingKeys.append(key)
          }
        }
        filteredKeys = matchingKeys
      }
      environmentKeys = []
      environmentDriftingKeyCount = 0
    case .environment:
      filteredKeys = []
      let sortedEnvironmentKeys = snapshot.sortedKeys(for: selectedEnvironment)
      if query.isEmpty {
        environmentKeys = sortedEnvironmentKeys
      } else if snapshot.environmentCount == 1,
        sortedEnvironmentKeys.count == snapshot.allSecretKeys.count
      {
        var matchingKeys: [String] = []
        matchingKeys.reserveCapacity(sortedEnvironmentKeys.count)
        for index in snapshot.allSecretKeys.indices
        where snapshot.normalizedSecretKeys[index].contains(query) {
          matchingKeys.append(snapshot.allSecretKeys[index])
        }
        environmentKeys = matchingKeys
      } else {
        environmentKeys = sortedEnvironmentKeys.filter {
          snapshot.normalizedKey(for: $0).contains(query)
        }
      }
      environmentDriftingKeyCount = environmentKeys.reduce(into: 0) { count, key in
        if snapshot.hasDrift(for: key) { count += 1 }
      }
    }
    let visibleKeys = mode == .matrix ? filteredKeys : environmentKeys
    allVisibleRevealed = !visibleKeys.isEmpty && visibleKeys.allSatisfy(revealedKeys.contains)
  }
}

struct VaultSecretEditDraft: Equatable {
  private(set) var baseline: String
  var draft: String
  private(set) var hasExternalConflict = false
  private var pendingSaveValue: String?
  private var pendingSaveBaseline: String?

  init(value: String) {
    baseline = value
    draft = value
  }

  var isDirty: Bool { draft != baseline }
  var isSaveInFlight: Bool { pendingSaveValue != nil }
  var canSave: Bool { isDirty && !hasExternalConflict && !isSaveInFlight }
  var canRevert: Bool { isDirty || hasExternalConflict }

  mutating func receiveExternalValue(_ value: String) {
    if value == pendingSaveValue {
      baseline = value
      hasExternalConflict = false
      return
    }
    if value == draft {
      baseline = value
      hasExternalConflict = false
      return
    }
    guard value != baseline else { return }
    if !isDirty {
      baseline = value
      draft = value
      hasExternalConflict = false
    } else {
      baseline = value
      hasExternalConflict = true
    }
  }

  mutating func beginSave() -> String? {
    guard canSave else { return nil }
    pendingSaveValue = draft
    pendingSaveBaseline = baseline
    return draft
  }

  mutating func finishSave(succeeded: Bool) {
    guard let submittedValue = pendingSaveValue,
      let submittedBaseline = pendingSaveBaseline
    else { return }
    pendingSaveValue = nil
    pendingSaveBaseline = nil
    guard succeeded, baseline == submittedBaseline, !hasExternalConflict else { return }
    baseline = submittedValue
    hasExternalConflict = false
  }

  mutating func revert() {
    draft = baseline
    hasExternalConflict = false
  }

}

extension VaultProject {
  var allSecretKeys: [String] {
    VaultWorkspaceSnapshot(project: self).allSecretKeys
  }

  func value(for key: String, in environment: String) -> String? {
    environments[environment]?[key]
  }

  func hasDrift(for key: String) -> Bool {
    VaultWorkspaceSnapshot(project: self).hasDrift(for: key)
  }

  func isMissingSomewhere(_ key: String) -> Bool {
    VaultWorkspaceSnapshot(project: self).isMissingSomewhere(key)
  }

  func environmentCount(for key: String) -> Int {
    VaultWorkspaceSnapshot(project: self).environmentCount(for: key)
  }
}
