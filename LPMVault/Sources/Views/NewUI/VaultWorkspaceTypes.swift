import Foundation
import SwiftUI

enum VaultWorkspaceMode: Equatable {
  case matrix
  case environment(String)
  /// The project's env rules from lpm.json.
  case schema

  func synchronized(to selectedEnvironment: String) -> Self {
    switch self {
    case .matrix: .matrix
    case .environment: .environment(selectedEnvironment)
    case .schema: .schema
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

enum VaultTableColumn: Hashable {
  case key
  case value
  case actions
  case environment(String)

  var title: String {
    switch self {
    case .key: "Key"
    case .value: "Value"
    case .actions: "Actions"
    case .environment(let name): VaultProject.displayName(for: name)
    }
  }

  var minimumWidth: CGFloat {
    switch self {
    case .key: 160
    case .value, .environment: 120
    case .actions: VaultMetrics.environmentActionsColumn
    }
  }

  var defaultWidth: CGFloat {
    switch self {
    case .key: VaultMetrics.keyColumn
    case .value: VaultMetrics.environmentValueColumn
    case .actions: VaultMetrics.environmentActionsColumn
    case .environment: VaultMetrics.environmentColumn
    }
  }
}

struct VaultTableColumnLayout {
  struct Boundary: Identifiable {
    let id: VaultTableColumn
    let position: CGFloat
  }

  let widths: [VaultTableColumn: CGFloat]
  let boundaries: [Boundary]
  let totalWidth: CGFloat

  init(columns: [VaultTableColumn], available: CGFloat, requested: [VaultTableColumn: CGFloat] = [:]) {
    let defaultTotal = columns.reduce(CGFloat.zero) { $0 + $1.defaultWidth }
    let environmentCount = columns.reduce(0) { count, column in
      if case .environment = column { count + 1 } else { count }
    }
    let extra = requested.isEmpty ? max(0, available - defaultTotal) : 0
    var widths: [VaultTableColumn: CGFloat] = [:]
    var boundaries: [Boundary] = []
    var position: CGFloat = 0
    for column in columns {
      let share: CGFloat
      if case .environment = column {
        share = extra / CGFloat(environmentCount)
      } else {
        share = environmentCount == 0 && column == .key ? extra : 0
      }
      let width = max(column.minimumWidth, requested[column] ?? (column.defaultWidth + share))
      widths[column] = width
      position += width
      boundaries.append(Boundary(id: column, position: position))
    }
    self.widths = widths
    self.boundaries = boundaries
    totalWidth = position
  }

  subscript(column: VaultTableColumn) -> CGFloat { widths[column] ?? column.defaultWidth }
}

struct VaultTableColumnWidths {
  private(set) var requested: [VaultTableColumn: CGFloat] = [:]

  mutating func resize(_ column: VaultTableColumn, to width: CGFloat, in layout: VaultTableColumnLayout) {
    if requested.isEmpty { requested = layout.widths }
    requested[column] = max(column.minimumWidth, width)
  }
}

struct VaultProjectTableColumnWidths {
  var matrix = VaultTableColumnWidths()
  var environment = VaultTableColumnWidths()
}

/// The order the workspace lists keys in, kept across launches.
enum VaultKeySortOrder: String, Sendable {
  case ascending
  case descending

  static let defaultsKey = "lpm-vault-key-sort"

  var reversed: Self { self == .ascending ? .descending : .ascending }

  var title: String { self == .ascending ? "A→Z" : "Z→A" }

  var spokenTitle: String { self == .ascending ? "A to Z" : "Z to A" }

  /// Finder's order: case-insensitive, with numbers compared by value, so
  /// `KEY_2` comes before `KEY_10`.
  static func sortedAscending<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
    keys.sorted {
      let comparison = $0.localizedStandardCompare($1)
      return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
    }
  }
}

struct VaultSecretTarget: Identifiable {
  let id = UUID()
  let projectId: String
  let environment: String
  var initialKey = ""
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

  @MainActor
  func isCurrent(in store: VaultStore) -> Bool {
    isCurrent(
      isUnlocked: store.canUseLocalSecrets,
      selectedProjectID: store.selectedProjectId,
      selectedEnvironment: store.selectedEnvironment
    )
  }
}

/// What one copy action in the key inspector puts on the clipboard.
enum VaultCopyFormat: CaseIterable, Identifiable, Sendable {
  case value
  case dotenv
  case export
  case reference

  var id: Self { self }

  var title: String {
    switch self {
    case .value: "Copy value"
    case .dotenv: "Copy as KEY=value"
    case .export: "Copy as export KEY=value"
    case .reference: "Copy process.env.KEY"
    }
  }

  /// Whether the copied text contains the secret value.
  var includesValue: Bool { self != .reference }

  func text(key: String, value: String) -> String {
    switch self {
    case .value: value
    case .dotenv: ClipboardManager.dotenvText(for: [key: value])
    case .export: "export " + ClipboardManager.dotenvText(for: [key: value])
    case .reference: Self.reference(to: key)
    }
  }

  private static func reference(to key: String) -> String {
    if EnvValidation.isValidVariableName(key) { return "process.env.\(key)" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let quoted = (try? encoder.encode(key)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(key)\""
    return "process.env[\(quoted)]"
  }
}

struct VaultValueCopy: Equatable, Sendable {
  let projectID: String
  let key: String
  let environment: String
  let format: VaultCopyFormat
}

/// How long a copy confirmation stays before it clears. Tests replace it to
/// end confirmations on demand instead of after a delay.
struct VaultCopyFeedbackTimer: Sendable {
  let wait: @Sendable () async throws -> Void

  static let standard = VaultCopyFeedbackTimer { try await Task.sleep(for: .seconds(2)) }
}

extension EnvironmentValues {
  @Entry var vaultCopyFeedbackTimer = VaultCopyFeedbackTimer.standard
}

struct VaultCopyFeedback: Equatable {
  enum Target: Equatable {
    case all(VaultSensitiveActionContext)
    case secret(projectID: String, environment: String, key: String)
    case unsaved(VaultKeyDraft.ID, environment: String)
  }

  let id = UUID()
  let target: Target
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

  /// Every key, A to Z.
  let allSecretKeys: [String]
  /// `allSecretKeys` from Z to A, built once so either order is shown without copying.
  private let allSecretKeysDescending: [String]
  /// Lowercased keys, in the order of `allSecretKeys`.
  let normalizedSecretKeys: [String]
  private let sortedKeysByEnvironment: [String: [String]]
  private let descendingKeysByEnvironment: [String: [String]]
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
    var descendingKeysByEnvironment: [String: [String]] = [:]
    sortedKeysByEnvironment.reserveCapacity(project.environments.count)
    descendingKeysByEnvironment.reserveCapacity(project.environments.count)
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
      let sortedKeys = Self.sortedKeys(secrets.keys)
      sortedKeysByEnvironment[environment] = sortedKeys
      descendingKeysByEnvironment[environment] = sortedKeys.reversed()
      guard !cancellationCheck() else { return nil }
    }
    self.sortedKeysByEnvironment = sortedKeysByEnvironment
    self.descendingKeysByEnvironment = descendingKeysByEnvironment

    environmentCount = project.environments.count
    if project.environments.count == 1,
      let environment = project.environments.keys.first,
      let sortedKeys = sortedKeysByEnvironment[environment],
      let descendingKeys = descendingKeysByEnvironment[environment]
    {
      allSecretKeys = sortedKeys
      allSecretKeysDescending = descendingKeys
    } else {
      guard !cancellationCheck() else { return nil }
      allSecretKeys = Self.sortedKeys(accumulators.keys)
      guard !cancellationCheck() else { return nil }
      allSecretKeysDescending = allSecretKeys.reversed()
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

  func keys(_ order: VaultKeySortOrder) -> [String] {
    order == .ascending ? allSecretKeys : allSecretKeysDescending
  }

  func sortedKeys(for environment: String, _ order: VaultKeySortOrder = .ascending) -> [String] {
    (order == .ascending ? sortedKeysByEnvironment : descendingKeysByEnvironment)[environment] ?? []
  }

  func missingKeyCount(for environment: String) -> Int {
    allSecretKeys.count - (sortedKeysByEnvironment[environment]?.count ?? 0)
  }

  private static func sortedKeys<S: Sequence>(_ keys: S) -> [String]
  where S.Element == String {
    VaultKeySortOrder.sortedAscending(keys)
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
  /// Every visible value that can be masked is revealed.
  let allVisibleRevealed: Bool
  /// Some visible value can be masked; public values always show.
  let hasMaskableValues: Bool

  init(
    project: VaultProject,
    snapshot: VaultWorkspaceSnapshot,
    selectedEnvironment: String,
    mode: VaultWorkspaceMode,
    filter: VaultWorkspaceFilter,
    searchText: String,
    sortOrder: VaultKeySortOrder,
    revealedKeys: Set<String>,
    publicKeys: Set<String> = []
  ) {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Matching walks the A-to-Z keys alongside their lowercased forms, then
    // reverses the matches in place for Z to A.
    let ascendingKeys = snapshot.allSecretKeys
    allKeys = snapshot.keys(sortOrder)
    switch mode {
    case .matrix:
      if filter == .all, query.isEmpty {
        filteredKeys = allKeys
      } else {
        var matchingKeys: [String] = []
        matchingKeys.reserveCapacity(ascendingKeys.count)
        for index in ascendingKeys.indices {
          let key = ascendingKeys[index]
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
        if sortOrder == .descending { matchingKeys.reverse() }
        filteredKeys = matchingKeys
      }
      environmentKeys = []
      environmentDriftingKeyCount = 0
    case .environment:
      filteredKeys = []
      let sortedEnvironmentKeys = snapshot.sortedKeys(for: selectedEnvironment, sortOrder)
      if query.isEmpty {
        environmentKeys = sortedEnvironmentKeys
      } else if snapshot.environmentCount == 1,
        sortedEnvironmentKeys.count == ascendingKeys.count
      {
        var matchingKeys: [String] = []
        matchingKeys.reserveCapacity(sortedEnvironmentKeys.count)
        for index in ascendingKeys.indices
        where snapshot.normalizedSecretKeys[index].contains(query) {
          matchingKeys.append(ascendingKeys[index])
        }
        if sortOrder == .descending { matchingKeys.reverse() }
        environmentKeys = matchingKeys
      } else {
        environmentKeys = sortedEnvironmentKeys.filter {
          snapshot.normalizedKey(for: $0).contains(query)
        }
      }
      environmentDriftingKeyCount = environmentKeys.reduce(into: 0) { count, key in
        if snapshot.hasDrift(for: key) { count += 1 }
      }
    case .schema:
      filteredKeys = []
      environmentKeys = []
      environmentDriftingKeyCount = 0
    }
    let visibleKeys = mode == .matrix ? filteredKeys : environmentKeys
    hasMaskableValues = visibleKeys.contains { !publicKeys.contains($0) }
    allVisibleRevealed = hasMaskableValues
      && visibleKeys.allSatisfy { publicKeys.contains($0) || revealedKeys.contains($0) }
  }
}

/// One environment's value in a key draft: the latest saved value and the
/// person's edit of it.
struct VaultSecretEditDraft: Equatable, Sendable {
  private(set) var baseline: String
  var draft: String
  /// The saved value changed elsewhere after the person edited it.
  private(set) var hasExternalConflict = false

  init(value: String) {
    baseline = value
    draft = value
  }

  var isDirty: Bool { draft != baseline }

  mutating func receiveExternalValue(_ value: String) {
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

  mutating func revert() {
    draft = baseline
    hasExternalConflict = false
  }

  /// Keeps the edit over the value saved elsewhere.
  mutating func keepDraft() {
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
