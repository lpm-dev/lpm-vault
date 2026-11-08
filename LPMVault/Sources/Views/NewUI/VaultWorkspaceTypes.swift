import Foundation
import SwiftUI

enum VaultWorkspaceMode: Equatable {
  case matrix
  case environment(String)
  /// The project's env rules from lpm.json.
  case schema
  /// How the project's values changed on this Mac.
  case history
  /// The project's name, icon, folder, CLI approval and deletion.
  case projectSettings

  func synchronized(to selectedEnvironment: String) -> Self {
    switch self {
    case .matrix: .matrix
    case .environment: .environment(selectedEnvironment)
    case .schema: .schema
    case .history: .history
    case .projectSettings: .projectSettings
    }
  }
}

enum VaultWorkspaceFilter: String, CaseIterable, Identifiable {
  case all = "All keys"
  case drift = "Drift"
  case missing = "Missing"
  /// Keys whose values fail their lpm.json rules.
  case invalid = "Invalid"

  var id: String { rawValue }
}

enum VaultEnvironmentViewMode: String, CaseIterable, Identifiable {
  case table = "Table"
  case raw = "Raw Text"

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
  /// The width of the view the table is laid out in.
  let available: CGFloat

  /// `keyWidth` is the width the keys shown need, which the key column takes
  /// instead of its default when narrower, so the value columns get the rest.
  /// `valueMinimum`, while values are shown to be read, keeps each value
  /// column at least that wide and the key column at what its keys need:
  /// the table scrolls, with the key column pinned, rather than cut values
  /// short where they're compared. When the environment columns can't all
  /// fit, as many as fit share the view whole and the rest wait past its
  /// edge, so none shows cut off until the table is scrolled.
  init(columns: [VaultTableColumn], available: CGFloat, requested: [VaultTableColumn: CGFloat] = [:], keyWidth: CGFloat? = nil,
    valueMinimum: CGFloat? = nil) {
    self.available = available
    let fittedKey = keyWidth.map { min(Self.fittedKeyMaximum, max(Self.fittedKeyMinimum, $0)) }
    func defaultWidth(_ column: VaultTableColumn) -> CGFloat {
      column == .key ? (fittedKey ?? column.defaultWidth) : column.defaultWidth
    }
    func minimum(_ column: VaultTableColumn) -> CGFloat {
      switch column {
      case .environment, .value: max(column.minimumWidth, valueMinimum ?? 0)
      case .key: valueMinimum == nil ? Self.fittedKeyMinimum : defaultWidth(column)
      case .actions: column.minimumWidth
      }
    }
    let defaultTotal = columns.reduce(CGFloat.zero) { $0 + defaultWidth($1) }
    let environmentCount = columns.reduce(0) { count, column in
      if case .environment = column { count + 1 } else { count }
    }
    let extra = requested.isEmpty ? max(0, available - defaultTotal) : 0
    // A narrow viewport takes width from the value columns first, in proportion
    // to how far each can shrink, and from the key column only once they're at
    // their minimums, so keys stay readable and every column stays in view
    // before any of them scrolls.
    let deficit = requested.isEmpty ? max(0, defaultTotal - available) : 0
    func slack(_ column: VaultTableColumn) -> CGFloat {
      max(0, defaultWidth(column) - minimum(column))
    }
    let valueSlack = columns.filter { $0 != .key }.reduce(CGFloat.zero) { $0 + slack($1) }
    let valueShrink = valueSlack > 0 ? min(1, deficit / valueSlack) : 0
    let keyShrink = columns.contains(.key) && slack(.key) > 0 ? min(1, max(0, deficit - valueSlack) / slack(.key)) : 0
    var widths: [VaultTableColumn: CGFloat] = [:]
    for column in columns {
      let share: CGFloat
      if case .environment = column {
        share = extra / CGFloat(environmentCount)
      } else {
        share = environmentCount == 0 && column == .value ? extra : 0
      }
      let fitted = defaultWidth(column) - slack(column) * (column == .key ? keyShrink : valueShrink)
      widths[column] = max(column.minimumWidth, requested[column] ?? max(minimum(column), fitted + share))
    }
    let fittedTotal = widths.values.reduce(CGFloat.zero, +)
    if requested.isEmpty, environmentCount > 0, fittedTotal > available + 0.5 {
      let environment = VaultTableColumn.environment("")
      let fixed = columns.reduce(CGFloat.zero) { total, column in
        if case .environment = column { total } else { total + (widths[column] ?? 0) }
      }
      let room = available - fixed
      let shown = max(1, min(environmentCount, Int((room / minimum(environment)).rounded(.down))))
      let width = max(environment.minimumWidth, (room / CGFloat(shown)).rounded(.down))
      for column in columns {
        if case .environment = column { widths[column] = width }
      }
      // Whole points for every column; what rounding leaves goes to the key, so the last column shown ends at the view's edge.
      if let key = widths[.key] { widths[.key] = key + max(0, room - width * CGFloat(shown)) }
    }
    var boundaries: [Boundary] = []
    var position: CGFloat = 0
    for column in columns {
      position += widths[column] ?? 0
      boundaries.append(Boundary(id: column, position: position))
    }
    self.widths = widths
    self.boundaries = boundaries
    totalWidth = position
  }

  subscript(column: VaultTableColumn) -> CGFloat { widths[column] ?? column.defaultWidth }

  /// The farthest the table scrolls sideways.
  var maximumOffset: CGFloat { max(0, totalWidth - available) }

  /// The columns past the pinned key column, in order, that aren't whole in
  /// view while the table is scrolled `offset` sideways: those under the key
  /// column or before it, and those past the view's edge.
  func hiddenColumns(at offset: CGFloat) -> (before: [VaultTableColumn], after: [VaultTableColumn]) {
    let start = offset + self[.key]
    let end = offset + available
    var before: [VaultTableColumn] = []
    var after: [VaultTableColumn] = []
    for boundary in boundaries where boundary.id != .key {
      if boundary.position - self[boundary.id] < start - 0.5 {
        before.append(boundary.id)
      } else if boundary.position > end + 0.5 {
        after.append(boundary.id)
      }
    }
    return (before, after)
  }

  /// How far to scroll the table sideways, from `offset`, to bring `column`
  /// whole into view: one before the view starts at the key column's edge;
  /// one past it ends in view, with the first column shown starting whole.
  func offset(showing column: VaultTableColumn, from offset: CGFloat) -> CGFloat {
    guard let boundary = boundaries.first(where: { $0.id == column }) else { return offset }
    let key = self[.key]
    let columnStart = boundary.position - self[column]
    if columnStart < offset + key - 0.5 { return min(maximumOffset, max(0, columnStart - key)) }
    let needed = boundary.position - available
    let starts = boundaries.lazy.filter { $0.id != .key }.map { $0.position - self[$0.id] - key }
    let aligned = starts.first { $0 >= needed - 0.5 } ?? needed
    return min(maximumOffset, max(0, min(aligned, columnStart - key)))
  }

  /// The narrowest a fitted key column gets, wide enough for a typical key and
  /// its status glyphs; the table scrolls rather than cut keys shorter. A
  /// person can still drag it down to the key column's minimum.
  static let fittedKeyMinimum: CGFloat = 200
  /// A little past the default, so a key as long as NEXT_PUBLIC_API_URL keeps its whole name beside its marks.
  static let fittedKeyMaximum: CGFloat = 300

  /// The width a key cell needs for the longest of `keys`: its name in the
  /// selected row's weight, a public key's globe, the status marks and the
  /// cell's insets. `marks` is how many mark slots the table keeps.
  @MainActor
  static func keyWidth(for keys: some Sequence<String>, publicKeys: Set<String>, marks: Int) -> CGFloat {
    var widest: CGFloat = 0
    for key in keys {
      widest = max(widest, VaultKeyNameWidths.width(of: key) + (publicKeys.contains(key) ? 22 : 0))
    }
    let markSlots = marks > 0 ? CGFloat(marks) * 14 + CGFloat(marks - 1) * 4 + 8 : 0
    // The cell's 20-point leading and 14-point trailing insets, and room to breathe before the marks.
    return ceil(20 + widest + 12 + markSlots + 14)
  }
}

/// Key names' widths in the table's key font, measured once each.
@MainActor
enum VaultKeyNameWidths {
  private static var widths: [String: CGFloat] = [:]
  private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

  static func width(of key: String) -> CGFloat {
    if let width = widths[key] { return width }
    let width = ceil((key as NSString).size(withAttributes: [.font: font]).width)
    widths[key] = width
    return width
  }
}

struct VaultTableColumnWidths: Equatable {
  private(set) var requested: [VaultTableColumn: CGFloat] = [:]

  mutating func resize(_ column: VaultTableColumn, to width: CGFloat, in layout: VaultTableColumnLayout) {
    if requested.isEmpty { requested = layout.widths }
    requested[column] = max(column.minimumWidth, width)
  }
}

/// Saved as each column's name and width, such as `{"key": 300, "env:production": 240}`.
extension VaultTableColumnWidths: Codable {
  init(from decoder: any Decoder) throws {
    let saved = try decoder.singleValueContainer().decode([String: Double].self)
    for (name, width) in saved {
      guard let column = VaultTableColumn(savedName: name), width.isFinite, width > 0 else { continue }
      requested[column] = max(column.minimumWidth, CGFloat(width))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(Dictionary(uniqueKeysWithValues: requested.map { ($0.key.savedName, Double($0.value)) }))
  }
}

struct VaultProjectTableColumnWidths: Equatable, Codable {
  var matrix = VaultTableColumnWidths()
  var environment = VaultTableColumnWidths()
}

extension VaultTableColumn {
  private static let environmentPrefix = "env:"

  /// The name a saved width goes by.
  var savedName: String {
    switch self {
    case .key: "key"
    case .value: "value"
    case .actions: "actions"
    case .environment(let name): Self.environmentPrefix + name
    }
  }

  init?(savedName: String) {
    switch savedName {
    case "key": self = .key
    case "value": self = .value
    case "actions": self = .actions
    default:
      guard savedName.hasPrefix(Self.environmentPrefix) else { return nil }
      self = .environment(String(savedName.dropFirst(Self.environmentPrefix.count)))
    }
  }
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
    keys.sorted(by: precedes)
  }

  static func mergingAscending<S: Sequence>(_ extras: S, into keys: [String]) -> [String]
  where S.Element == String {
    let additions = sortedAscending(extras)
    guard !additions.isEmpty else { return keys }
    var merged: [String] = []
    merged.reserveCapacity(keys.count + additions.count)
    var cursor = 0
    var previous: String?
    for addition in additions {
      guard addition != previous else { continue }
      previous = addition
      var lower = cursor
      var upper = keys.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if precedes(keys[middle], addition) {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      merged.append(contentsOf: keys[cursor..<lower])
      if lower == keys.count || keys[lower] != addition { merged.append(addition) }
      cursor = lower
    }
    merged.append(contentsOf: keys[cursor...])
    return merged
  }

  /// `items`, already in this order by `key`, with `extras` merged in at their places.
  static func mergingAscending<Item>(_ extras: [Item], into items: [Item], by key: (Item) -> String) -> [Item] {
    guard !extras.isEmpty else { return items }
    let additions = extras.sorted { precedes(key($0), key($1)) }
    var merged: [Item] = []
    merged.reserveCapacity(items.count + additions.count)
    var cursor = 0
    for addition in additions {
      let name = key(addition)
      var lower = cursor
      var upper = items.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if precedes(key(items[middle]), name) {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      merged.append(contentsOf: items[cursor..<lower])
      merged.append(addition)
      cursor = lower
    }
    merged.append(contentsOf: items[cursor...])
    return merged
  }

  private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
    let comparison = lhs.localizedStandardCompare(rhs)
    return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
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

/// An environment, by its project and name.
struct VaultEnvironmentTarget: Identifiable, Hashable, Sendable {
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

  /// What a menu lists the format as, under a "Copy as" heading.
  var shortTitle: String {
    switch self {
    case .value: "Value"
    case .dotenv: "KEY=value"
    case .export: "export KEY=value"
    case .reference: "process.env.KEY"
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

/// How long feedback stays before it clears: a copy confirmation, or the
/// chance to undo an import or a Raw text save. Tests replace it to end the
/// feedback on demand instead of after a delay.
struct VaultFeedbackTimer: Sendable {
  let wait: @Sendable () async throws -> Void

  /// How long a change to an environment can be undone.
  static let undoSeconds = 30

  static let copyConfirmation = VaultFeedbackTimer { try await Task.sleep(for: .seconds(2)) }
  static let importUndo = VaultFeedbackTimer { try await Task.sleep(for: .seconds(undoSeconds)) }
}

extension EnvironmentValues {
  @Entry var vaultCopyFeedbackTimer = VaultFeedbackTimer.copyConfirmation
  @Entry var vaultImportUndoTimer = VaultFeedbackTimer.importUndo
  /// The time history's pages say things relative to, such as "Today".
  @Entry var vaultClock = VaultClock.system
}

/// The time now, which a test sets, so what's "Today" doesn't depend on
/// when it runs.
struct VaultClock: Sendable {
  let now: @Sendable () -> Date

  static let system = VaultClock { Date() }
}

/// Raw text's edit of the selected environment, as the content view shows it.
struct VaultRawTextEditing {
  let draft: VaultRawTextDraft
  /// What the draft's values hold that's hard to see.
  var characterWarnings: VaultRawTextCharacterWarnings?
  let isSaving: Bool
  /// Why the last save wrote nothing, until the next.
  let failure: VaultRawTextFailure?
  let onChange: (String) -> Void
  let onCancel: () -> Void
  /// Shows what the edit changes, or saves it at once when its review is off.
  let onSave: () -> Void
  let onReviewChange: (Bool) -> Void
  /// Compares the edit with the environment's values now, after they changed.
  let onCompare: () -> Void
  /// Copies text cut or copied in the editor.
  let onCopy: (String) -> Void
  /// Applies a fix the person chose to every value that holds characters that are hard to see.
  var onFixCharacters: (RustSchemaEngine.CharacterFix) -> Void = { _ in }
}

enum VaultRawTextFailure: Equatable {
  /// Something else, as the LPM CLI, changed the environment since the edit began.
  case changed
  case failed(String)
}

/// A Raw text save, which a short while can undo.
struct VaultRawTextSaved: Equatable {
  enum Undo: Equatable {
    case available
    case undoing
    case undone
    case failed(String)
  }

  let id = UUID()
  let receipt: EnvironmentChangeReceipt
  /// Such as "1 added, 2 changed".
  let summary: String
  let savedAt: Date
  var undo = Undo.available
}

/// Which part of a Raw text save's feedback is showing, which decides how long it stays.
struct RawTextSavedPhase: Equatable {
  let id: UUID
  let undo: VaultRawTextSaved.Undo
}

struct VaultCopyFeedback: Equatable {
  enum Target: Equatable {
    case all(VaultSensitiveActionContext)
    /// Raw text's selected lines.
    case lines(VaultSensitiveActionContext, count: Int)
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
      if ExactText(value) != ExactText(firstValue) {
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
    publicKeys: Set<String> = [],
    invalidKeys: Set<String> = [],
    unstoredKeys: Set<String> = []
  ) {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch mode {
    case .matrix:
      // Matching walks the A-to-Z keys alongside their lowercased forms, then
      // reverses the matches in place for Z to A.
      let extra = unstoredKeys.filter { snapshot.summaries[$0] == nil }
      let ascendingKeys: [String]
      if extra.isEmpty {
        ascendingKeys = snapshot.allSecretKeys
        allKeys = snapshot.keys(sortOrder)
      } else {
        ascendingKeys = VaultKeySortOrder.mergingAscending(extra, into: snapshot.allSecretKeys)
        allKeys = sortOrder == .ascending ? ascendingKeys : ascendingKeys.reversed()
      }
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
          case .invalid: matchesFilter = invalidKeys.contains(key)
          }
          if matchesFilter,
            query.isEmpty || (extra.isEmpty ? snapshot.normalizedSecretKeys[index]
              : snapshot.normalizedKey(for: key)).contains(query)
          {
            matchingKeys.append(key)
          }
        }
        if sortOrder == .descending { matchingKeys.reverse() }
        filteredKeys = matchingKeys
      }
      environmentKeys = []
    case .environment:
      allKeys = snapshot.keys(sortOrder)
      filteredKeys = []
      let extra = unstoredKeys.filter { project.value(for: $0, in: selectedEnvironment) == nil }
      if extra.isEmpty {
        let ascendingKeys = snapshot.allSecretKeys
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
      } else {
        let ascendingKeys = VaultKeySortOrder.mergingAscending(extra,
          into: snapshot.sortedKeys(for: selectedEnvironment, .ascending))
        var matchingKeys = query.isEmpty ? ascendingKeys : ascendingKeys.filter { snapshot.normalizedKey(for: $0).contains(query) }
        if sortOrder == .descending { matchingKeys.reverse() }
        environmentKeys = matchingKeys
      }
    case .schema, .history, .projectSettings:
      allKeys = snapshot.keys(sortOrder)
      filteredKeys = []
      environmentKeys = []
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

  var isDirty: Bool { ExactText(draft) != ExactText(baseline) }

  static func == (lhs: Self, rhs: Self) -> Bool {
    ExactText(lhs.baseline) == ExactText(rhs.baseline) && ExactText(lhs.draft) == ExactText(rhs.draft)
      && lhs.hasExternalConflict == rhs.hasExternalConflict
  }

  mutating func receiveExternalValue(_ value: String) {
    if ExactText(value) == ExactText(draft) {
      baseline = value
      hasExternalConflict = false
      return
    }
    guard ExactText(value) != ExactText(baseline) else { return }
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
