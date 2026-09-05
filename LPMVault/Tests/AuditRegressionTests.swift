import AppKit
import Foundation
import Testing

@testable import LPMVault

@Suite("End-to-end audit regressions", .serialized)
struct AuditRegressionTests {
  @Test("biometric cache does not survive a clock rollback")
  func biometricCacheRejectsClockRollback() async {
    let clock = LockedTestClock(100)
    let prompts = LockedTestCounter()
    let service = BiometricService(
      cacheDuration: 300,
      now: { clock.value },
      authentication: { _ in
        prompts.increment()
        return true
      }
    )

    #expect(await service.authenticate(reason: "first"))
    clock.value = 50
    #expect(await service.authenticate(reason: "after rollback"))

    #expect(prompts.value == 2)
  }

  @Test("login attempt throttling does not persist across a monotonic clock reset")
  func loginAttemptClockReset() {
    let limiter = LoginAttemptLimiter()
    #expect(limiter.reserve(now: 100))
    #expect(limiter.reserve(now: 50))
  }

  @Test("future-dated update cache entries expire immediately")
  func futureUpdateCacheExpires() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(
      UpdateChecker.cacheIsExpired(
        checkedAt: now.addingTimeInterval(60),
        now: now
      ))
  }

  @Test("shared RFC 3339 relative timestamps cover fractional, whole, and future values")
  func sharedRelativeTimestampFormatting() {
    let now = Date(timeIntervalSince1970: 2_000)
    #expect(
      RelativeTimestampFormatter.string(
        fromRFC3339: "1970-01-01T00:32:50.000Z", now: now
      ) == "just now")
    #expect(
      RelativeTimestampFormatter.string(
        fromRFC3339: "1970-01-01T00:31:40Z", now: now
      ) == "1m ago")
    #expect(
      RelativeTimestampFormatter.string(
        fromRFC3339: "1970-01-01T00:34:00Z", now: now
      ) == "just now")
    #expect(
      RelativeTimestampFormatter.string(
        fromRFC3339: "invalid", now: now
      ) == "invalid")
  }
  @Test("dotenv export and clipboard text remain literal when sourced")
  func shellSafeLosslessDotenvExport() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("expanded")
    let source = [
      "PAYLOAD": "$(touch \(marker.path))",
      "BACKTICK": "`touch \(marker.path)`",
      "VARIABLE": "$HOME",
      "TABS": "\tkeep\t",
    ]
    let formatted = ClipboardManager.dotenvText(for: source)
    #expect(try EnvFileCodec.parse(formatted) == source)

    let file = directory.appendingPathComponent("export.env")
    try Data(formatted.utf8).write(to: file)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      #". "$1"; printf '%s\n%s\n%s\n' "$PAYLOAD" "$BACKTICK" "$VARIABLE""#,
      "audit-shell",
      file.path,
    ]
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let rendered = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0)
    #expect(rendered == "\(source["PAYLOAD"]!)\n\(source["BACKTICK"]!)\n\(source["VARIABLE"]!)\n")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("token expiry accepts fractional RFC3339 and treats an elapsed instant as expired")
  func tokenExpiryParsingAndClassification() throws {
    let now = Date()
    let fractional = now.addingTimeInterval(3_600).formatted(
      Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    )
    let future = LPMToken(
      id: "future", name: "future", scope: nil, expiresAt: fractional,
      lastUsedAt: nil, downloadCount: nil, createdAt: nil
    )
    #expect(future.expiresDate != nil)

    let justExpired = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
    let expired = LPMToken(
      id: "expired", name: "expired", scope: nil, expiresAt: justExpired,
      lastUsedAt: nil, downloadCount: nil, createdAt: nil
    )
    #expect(expired.expiryStatus == .expired)
  }

  @Test("semantically equal release versions do not produce an update")
  @MainActor
  func numericReleaseComparison() async throws {
    #expect(UpdateChecker.isNewerVersion("1.10.0", than: "1.9.0"))
    #expect(!UpdateChecker.isNewerVersion("1.9.0", than: "1.10.0"))
    #expect(!UpdateChecker.isNewerVersion("2.0", than: "2.0.0"))

    struct Cache: Encodable {
      let version: String
      let checkedAt: Date
    }
    let defaults = UserDefaults.standard
    let key = "lpm-vault-update-check"
    let previous = defaults.data(forKey: key)
    defer {
      if let previous {
        defaults.set(previous, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
    let checker = UpdateChecker()
    var equivalentFields = checker.currentVersion.split(separator: ".").map(String.init)
    #expect(equivalentFields.count == 3)
    equivalentFields[1] = "0" + equivalentFields[1]
    let equivalent = equivalentFields.joined(separator: ".")
    defaults.set(
      try JSONEncoder().encode(Cache(version: equivalent, checkedAt: Date())),
      forKey: key
    )
    await checker.checkForUpdate()
    #expect(checker.latestVersion == equivalent)
    #expect(!checker.updateAvailable)
  }

  @Test("a wholly empty cloud payload has a durable default environment")
  func emptyCloudPayloadNormalization() throws {
    let decoded = try EnvValidation.decodeRemoteEnvironments(
      Data(#"{"environments":{}}"#.utf8)
    )
    #expect(decoded.environments == ["default": [:]])
    #expect(decoded.keyCount == 0)
  }

  @Test("a corrupt metadata snapshot does not replace the last coherent state")
  @MainActor
  func corruptMetadataFailsClosed() async {
    let keychain = MockKeychainService()
    keychain.envStorage["project"] = (
      name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
    )
    keychain.dataStorage[mockSyncMetadataAccount(vaultId: "project")] = Data("not-json".utf8)
    let store = VaultStore(
      keychainService: keychain,
      biometricService: MockBiometricService(),
      apiService: MockAPIService()
    )
    store.projects = [
      VaultProject(
        id: "previous", name: "Previous", path: "",
        environments: ["default": ["OLD": "value"]]
      )
    ]
    store.syncMetadata = ["previous": SyncMetadata(lastVersion: 9)]

    let loaded = await store.loadProjects()

    #expect(!loaded)
    #expect(store.projects.map(\.id) == ["previous"])
    #expect(store.syncMetadata["previous"]?.lastVersion == 9)
    #expect(store.error != nil)
  }

  @Test("a corrupt organization association does not reroute the last coherent state")
  @MainActor
  func corruptOrganizationAssociationFailsClosed() async {
    let keychain = MockKeychainService()
    keychain.envStorage["project"] = (
      name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
    )
    keychain.dataStorage["__org_associations__"] = Data("not-json".utf8)
    let store = VaultStore(
      keychainService: keychain,
      biometricService: MockBiometricService(),
      apiService: MockAPIService()
    )
    store.projects = [
      VaultProject(
        id: "previous", name: "Previous", path: "",
        environments: ["default": ["OLD": "value"]]
      )
    ]
    store.vaultOrgAssociations = ["previous": "trusted-org"]

    let loaded = await store.loadProjects()

    #expect(!loaded)
    #expect(store.projects.map(\.id) == ["previous"])
    #expect(store.vaultOrgAssociations == ["previous": "trusted-org"])
    #expect(store.error != nil)
  }

  @Test("a project read failure does not fabricate an empty vault")
  @MainActor
  func projectReadFailureFailsClosed() async {
    let keychain = MockKeychainService()
    keychain.failProjectReads = true
    keychain.failureError = .keychainLocked
    let store = VaultStore(
      keychainService: keychain,
      biometricService: MockBiometricService(),
      apiService: MockAPIService()
    )
    store.projects = [
      VaultProject(
        id: "coherent", name: "Coherent", path: "",
        environments: ["default": ["TOKEN": "retained"]]
      )
    ]

    #expect(!(await store.loadProjects()))
    #expect(store.projects.first?.secrets(for: "default")["TOKEN"] == "retained")
    #expect(store.error?.contains("Keychain") == true)
  }

  @Test("single-project mutation reads only its target project")
  func directProjectPersistenceRead() async {
    let keychain = MockKeychainService()
    for index in 0..<100 {
      keychain.envStorage["project-\(index)"] = (
        name: "Project \(index)", path: "",
        environments: ["default": ["EXISTING": "value"]]
      )
    }
    let persistence = VaultPersistenceCoordinator(service: keychain)

    let result = await persistence.addSecret(
      projectId: "project-42",
      projectName: "Project 42",
      projectPath: "",
      environment: "default",
      key: "NEW",
      value: "value"
    )

    guard case .success = result else {
      Issue.record("The direct project mutation failed: \(result)")
      return
    }
    #expect(keychain.projectReadCount == 1)
    #expect(keychain.environmentReadCount == 0)
  }

  @Test("content-only mutation does not rewrite project index metadata")
  func contentOnlyMutationUsesPayloadUpdate() async {
    let keychain = MockKeychainService()
    keychain.envStorage["project"] = (
      name: "Project", path: "", environments: ["default": ["TOKEN": "old"]]
    )
    let persistence = VaultPersistenceCoordinator(service: keychain)

    let result = await persistence.mutateProject(
      projectId: "project",
      expectedName: "Project",
      expectedPath: "",
      mutation: .updateSecret(
        environment: "default",
        key: "TOKEN",
        expectedValue: "old",
        replacement: "new"
      )
    )

    guard case .success = result else {
      Issue.record("Content-only mutation failed: \(result)")
      return
    }
    #expect(keychain.updateEnvironmentsCallCount == 1)
    #expect(keychain.dataReadCounts[mockSyncMetadataAccount(vaultId: "project")] == 1)
    #expect(keychain.envStorage["project"]?.environments["default"]?["TOKEN"] == "new")
  }

  @Test("sync metadata point mutations are independent of unrelated projects")
  func syncMetadataUsesPerVaultRecords() async throws {
    let keychain = MockKeychainService()
    var metadata: [String: SyncMetadata] = [:]
    for index in 0..<1_000 {
      let projectID = "project-\(index)"
      keychain.envStorage[projectID] = (
        name: "Project \(index)", path: "",
        environments: ["default": ["EXISTING": "value"]]
      )
      metadata[projectID] = SyncMetadata(isDirty: true)
    }
    #expect(keychain.seedSyncMetadata(metadata))
    let persistence = VaultPersistenceCoordinator(service: keychain)

    guard case .success(let snapshot) = await persistence.loadSnapshot() else {
      Issue.record("Current sync metadata loading failed")
      return
    }

    #expect(snapshot.syncMetadata.count == 1_000)
    #expect(keychain.dataStorage["__sync_metadata__"] == nil)

    keychain.dataReadCounts.removeAll()
    keychain.dataWriteCounts.removeAll()
    let result = await persistence.addSecret(
      projectId: "project-500",
      projectName: "Project 500",
      projectPath: "",
      environment: "default",
      key: "NEW",
      value: "value"
    )

    guard case .success = result else {
      Issue.record("The sharded metadata mutation failed: \(result)")
      return
    }
    #expect(keychain.dataReadCounts["__sync_metadata__"] == nil)
    #expect(keychain.dataReadCounts[mockSyncMetadataAccount(vaultId: "project-500")] == 1)
    #expect(keychain.dataWriteCounts[mockSyncMetadataAccount(vaultId: "project-500")] == 1)
  }

  @Test("corrupt versioned sync metadata fails closed")
  func corruptVersionedSyncMetadataFailsClosed() async throws {
    let keychain = MockKeychainService()
    keychain.envStorage["project"] = (
      name: "Project", path: "", environments: ["default": [:]]
    )
    #expect(keychain.seedSyncMetadata([:]))
    keychain.dataStorage[mockSyncMetadataAccount(vaultId: "project")] = Data("bad".utf8)

    let result = await VaultPersistenceCoordinator(service: keychain).loadSnapshot()

    guard case .failure(.encodingFailed) = result else {
      Issue.record("A corrupt sync metadata shard did not fail closed: \(result)")
      return
    }
  }

  @Test("first point mutation initializes versioned sync metadata directly")
  func pointMutationInitializesVersionedSyncMetadata() async {
    let keychain = MockKeychainService()
    keychain.envStorage["project"] = (
      name: "Project", path: "", environments: ["default": [:]]
    )

    let result = await VaultPersistenceCoordinator(service: keychain).addSecret(
      projectId: "project",
      projectName: "Project",
      projectPath: "",
      environment: "default",
      key: "TOKEN",
      value: "secret"
    )

    guard case .success = result else {
      Issue.record("The first versioned metadata mutation failed: \(result)")
      return
    }
    #expect(keychain.dataStorage["__sync_metadata__"] == nil)
    #expect(keychain.storedSyncMetadata(vaultId: "project")?.isDirty == true)
  }

  @Test("one-project changes rebuild only one workspace snapshot")
  @MainActor
  func incrementalWorkspaceSnapshotCache() async throws {
    let store = VaultStore(
      keychainService: MockKeychainService(),
      biometricService: MockBiometricService(),
      apiService: MockAPIService()
    )
    store.projects = (0..<100).map { index in
      VaultProject(
        id: "project-\(index)",
        name: "Project \(index)",
        path: "",
        environments: ["default": ["KEY": "\(index)"]]
      )
    }
    try await waitForWorkspaceSnapshots(store, count: 100)
    let baseline = store.workspaceSnapshotBuildCount

    store.projects[42].environments["default"]?["KEY"] = "changed"
    try await waitForWorkspaceSnapshotBuilds(store, count: baseline + 1)

    #expect(store.workspaceSnapshotBuildCount - baseline == 1)
  }

  @Test("workspace snapshot identity changes after a nested secret mutation")
  func workspaceSnapshotMutationIdentity() {
    var project = VaultProject(
      id: "project",
      name: "Project",
      path: "",
      environments: ["default": ["TOKEN": "before"]]
    )
    let initialIdentity = project.workspaceSnapshotIdentity

    project.environments["default"]?["TOKEN"] = "after"

    #expect(project.workspaceSnapshotIdentity != initialIdentity)
  }

  @Test("workspace snapshot reconciliation does not block the main actor")
  @MainActor
  func workspaceSnapshotReconciliationIsAsynchronous() async throws {
    let store = VaultStore(
      keychainService: MockKeychainService(),
      biometricService: MockBiometricService(),
      apiService: MockAPIService()
    )
    store.projects = (0..<100).map { projectIndex in
      let secrets = Dictionary(
        uniqueKeysWithValues: (0..<6_000).map { keyIndex in
          ("KEY_\(keyIndex)", "VALUE_\(projectIndex)_\(keyIndex)")
        })
      return VaultProject(
        id: "project-\(projectIndex)",
        name: "Project \(projectIndex)",
        path: "",
        environments: ["default": secrets]
      )
    }
    try await waitForWorkspaceSnapshots(store, count: 100)

    let baseline = store.workspaceSnapshotBuildCount
    let start = ContinuousClock.now
    store.projects[42].environments["default"]?["KEY_42"] = "changed"
    let assignmentDuration = start.duration(to: .now)

    #expect(assignmentDuration < .milliseconds(20))
    try await waitForWorkspaceSnapshotBuilds(store, count: baseline + 1)
    #expect(store.workspaceSnapshots["project-42"]?.summaries["KEY_42"] != nil)
  }

  @Test("superseded workspace snapshot builds stop without overlapping replacements")
  func supersededWorkspaceSnapshotBuildStopsSerially() async {
    let tracker = SnapshotBuildTracker()
    let builder = VaultWorkspaceSnapshotBuilder { project in
      tracker.begin()
      defer { tracker.end() }
      if project.id == "superseded" {
        while !Task.isCancelled {
          Thread.sleep(forTimeInterval: 0.001)
        }
        tracker.recordCancellation()
        return nil
      }
      return VaultWorkspaceSnapshot(project: project)
    }
    let superseded = VaultProject(
      id: "superseded",
      name: "Superseded",
      path: "",
      environments: ["default": ["KEY": "old"]]
    )
    let replacement = VaultProject(
      id: "replacement",
      name: "Replacement",
      path: "",
      environments: ["default": ["KEY": "new"]]
    )

    let first = Task { await builder.buildAll([superseded]) }
    for _ in 0..<1_000 where tracker.startedBuildCount == 0 {
      await Task.yield()
    }
    let second = Task { await builder.buildAll([replacement]) }
    first.cancel()

    let firstResult = await first.value
    let secondResult = await second.value
    #expect(firstResult == nil)
    #expect(secondResult?["replacement"] != nil)
    #expect(tracker.maximumConcurrentBuildCount == 1)
    #expect(tracker.cancelledBuildCount == 1)
  }

  @Test("workspace derivation computes only the active presentation mode")
  func workspaceDerivationIsModeSpecific() {
    let project = VaultProject(
      id: "project",
      name: "Project",
      path: "",
      environments: [
        "default": ["A": "1"],
        "production": ["B": "2"],
      ]
    )
    let snapshot = VaultWorkspaceSnapshot(project: project)
    let matrix = VaultContentDerivation(
      project: project,
      snapshot: snapshot,
      selectedEnvironment: "default",
      mode: .matrix,
      filter: .all,
      searchText: "",
      revealedKeys: []
    )
    let environment = VaultContentDerivation(
      project: project,
      snapshot: snapshot,
      selectedEnvironment: "default",
      mode: .environment("default"),
      filter: .all,
      searchText: "",
      revealedKeys: []
    )

    #expect(matrix.filteredKeys == ["A", "B"])
    #expect(matrix.environmentKeys.isEmpty)
    #expect(environment.filteredKeys.isEmpty)
    #expect(environment.environmentKeys == ["A"])
  }

  @Test("single-project writes propagate protected read failures without saving")
  func directProjectReadFailureDoesNotWrite() async {
    let keychain = MockKeychainService()
    keychain.envStorage["project"] = (
      name: "Project", path: "", environments: ["default": ["TOKEN": "original"]]
    )
    keychain.failProjectReads = true
    keychain.failureError = .keychainLocked
    let persistence = VaultPersistenceCoordinator(service: keychain)

    let addition = await persistence.addSecret(
      projectId: "project",
      projectName: "Project",
      projectPath: "",
      environment: "default",
      key: "NEW",
      value: "value"
    )
    guard case .failure(.keychainLocked) = addition else {
      Issue.record("Expected the protected read error, got \(addition)")
      return
    }

    #expect(keychain.saveEnvironmentsCallCount == 0)
    #expect(keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "original"])
  }

  @Test("avatar URLs and decoded dimensions are bounded by an allowlist")
  func avatarPolicyAndDimensions() throws {
    #expect(AvatarURLPolicy.validatedURL("https://avatars.githubusercontent.com/u/1?v=4") != nil)
    #expect(AvatarURLPolicy.validatedURL("https://lpm.dev/avatar/user") != nil)
    for rejected in [
      "http://avatars.githubusercontent.com/u/1",
      "https://127.0.0.1/avatar",
      "https://localhost/avatar",
      "file:///etc/passwd",
      "https://lpm.dev:8443/avatar",
      "https://tracker.example/avatar",
    ] {
      #expect(AvatarURLPolicy.validatedURL(rejected) == nil)
    }

    let smallBitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ))
    let small = try #require(smallBitmap.representation(using: .png, properties: [:]))
    #expect(SecureAvatarLoader.isSafeImageData(small))

    let wideBitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: SecureAvatarLoader.maximumPixelDimension + 1,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ))
    let wide = try #require(wideBitmap.representation(using: .png, properties: [:]))
    #expect(!SecureAvatarLoader.isSafeImageData(wide))
    #expect(
      !SecureAvatarLoader.isSafeImageData(
        Data(repeating: 0, count: SecureAvatarLoader.maximumResponseBytes + 1)
      ))
  }

  @Test("avatar image cache coalesces concurrent loads and reuses the decoded image")
  @MainActor
  func avatarCacheCoalescesRequests() async throws {
    let requests = LockedTestCounter()
    let cache = SecureAvatarImageCache(maximumCost: 1_024, maximumCount: 2) { _ in
      requests.increment()
      try await Task.sleep(for: .milliseconds(20))
      return NSImage(size: NSSize(width: 1, height: 1))
    }
    let url = URL(string: "https://lpm.dev/avatar/test")!

    async let first = cache.image(for: url)
    async let second = cache.image(for: url)
    _ = try await [first, second]
    _ = try await cache.image(for: url)

    #expect(requests.value == 1)
  }

  @Test("organization approval arrays must exactly match the displayed bindings")
  func exactOrganizationApprovals() {
    let first = PendingKeyApproval(
      memberId: "one", fingerprint: "fingerprint-one",
      isNewMember: true, oldFingerprint: nil
    )
    let second = PendingKeyApproval(
      memberId: "two", fingerprint: "fingerprint-two",
      isNewMember: false, oldFingerprint: "old"
    )
    let forged = PendingKeyApproval(
      memberId: "two", fingerprint: "attacker",
      isNewMember: false, oldFingerprint: "old"
    )

    #expect(PendingKeyApproval.exactlyMatches([second, first], pending: [first, second]))
    #expect(!PendingKeyApproval.exactlyMatches([first], pending: [first, second]))
    #expect(!PendingKeyApproval.exactlyMatches([first, forged], pending: [first, second]))
  }

  @Test("secret drafts refresh when clean and block stale saves after a conflict")
  func secretDraftConflictHandling() {
    var clean = VaultSecretEditDraft(value: "old")
    clean.receiveExternalValue("external")
    #expect(clean.draft == "external")
    #expect(!clean.isDirty)
    #expect(!clean.hasExternalConflict)

    var edited = VaultSecretEditDraft(value: "old")
    edited.draft = "local-edit"
    edited.receiveExternalValue("external")
    #expect(edited.draft == "local-edit")
    #expect(edited.hasExternalConflict)
    #expect(!edited.canSave)
    #expect(edited.canRevert)
    edited.revert()
    #expect(edited.draft == "external")
    #expect(!edited.hasExternalConflict)

    var pendingSave = VaultSecretEditDraft(value: "old")
    pendingSave.draft = "requested"
    #expect(pendingSave.canSave)
    pendingSave.receiveExternalValue("old")
    #expect(pendingSave.canSave)
    pendingSave.receiveExternalValue("requested")
    #expect(!pendingSave.isDirty)
    #expect(!pendingSave.hasExternalConflict)
  }

  @Test("secret editor admits only one save activation until durable completion")
  func secretDraftSaveIsSingleFlight() {
    var editor = VaultSecretEditDraft(value: "old")
    editor.draft = "requested"

    #expect(editor.beginSave() == "requested")
    #expect(editor.isSaveInFlight)
    #expect(editor.beginSave() == nil)
    #expect(!editor.canSave)

    editor.receiveExternalValue("requested")
    #expect(editor.isSaveInFlight)
    editor.finishSave(succeeded: true)

    #expect(!editor.isSaveInFlight)
    #expect(!editor.isDirty)
    #expect(!editor.hasExternalConflict)
  }

  @Test("delayed save completion preserves newer external state")
  func secretDraftCompletionDoesNotEraseNewerExternalState() {
    var clean = VaultSecretEditDraft(value: "old")
    clean.draft = "submitted"
    #expect(clean.beginSave() != nil)
    clean.receiveExternalValue("submitted")
    clean.receiveExternalValue("newer")
    clean.finishSave(succeeded: true)
    #expect(clean.baseline == "newer")
    #expect(clean.draft == "newer")
    #expect(!clean.hasExternalConflict)

    var edited = VaultSecretEditDraft(value: "old")
    edited.draft = "submitted"
    #expect(edited.beginSave() != nil)
    edited.receiveExternalValue("submitted")
    edited.draft = "next-edit"
    edited.receiveExternalValue("newer")
    edited.finishSave(succeeded: true)
    #expect(edited.baseline == "newer")
    #expect(edited.draft == "next-edit")
    #expect(edited.hasExternalConflict)

    var coalesced = VaultSecretEditDraft(value: "old")
    coalesced.draft = "submitted"
    #expect(coalesced.beginSave() != nil)
    coalesced.receiveExternalValue("newer")
    coalesced.finishSave(succeeded: true)
    #expect(coalesced.baseline == "newer")
    #expect(coalesced.draft == "submitted")
    #expect(coalesced.hasExternalConflict)

    var coalescedEdit = VaultSecretEditDraft(value: "old")
    coalescedEdit.draft = "submitted"
    #expect(coalescedEdit.beginSave() != nil)
    coalescedEdit.draft = "next-edit"
    coalescedEdit.receiveExternalValue("newer")
    coalescedEdit.finishSave(succeeded: true)
    #expect(coalescedEdit.baseline == "newer")
    #expect(coalescedEdit.draft == "next-edit")
    #expect(coalescedEdit.hasExternalConflict)
  }

  @Test("project rename controls use the canonical name contract")
  func projectRenamePolicyMatchesCanonicalValidation() {
    for invalid in [
      "\n\t",
      String(repeating: "a", count: 121),
      String(repeating: "😀", count: 101),
      "release\u{0085}secrets",
    ] {
      #expect(VaultProjectRenamePolicy.normalizedName(invalid) == nil)
    }
    #expect(VaultProjectRenamePolicy.normalizedName("  Release  ") == "Release")
  }

  @Test("fixed organization changes invalidate sheet loading and routing")
  func fixedOrganizationSheetIdentityTracksItsRoute() {
    let organizationA = OrgVaultSheetLoadIdentity(
      authGeneration: 4,
      fixedOrgSlug: "organization-a",
      selectedOrg: "organization-a",
      reloadID: 0
    )
    let organizationB = OrgVaultSheetLoadIdentity(
      authGeneration: 4,
      fixedOrgSlug: "organization-b",
      selectedOrg: "organization-a",
      reloadID: 0
    )

    #expect(organizationA != organizationB)
    #expect(organizationB.effectiveOrgSlug == "organization-b")
  }

  @Test("stale export completion cannot release a replacement task")
  func exportTaskCleanupRequiresRequestOwnership() {
    let stale = UUID()
    let replacement = UUID()

    #expect(!VaultTaskOwnership.owns(current: replacement, request: stale))
    #expect(VaultTaskOwnership.owns(current: replacement, request: replacement))
    #expect(!VaultTaskOwnership.owns(current: nil, request: replacement))
  }

  @Test("sensitive actions remain bound to their unlocked project and environment")
  func sensitiveActionContextRejectsStalePresentation() {
    let context = VaultSensitiveActionContext(projectID: "project-a", environment: "staging")

    #expect(context.isCurrent(
      isUnlocked: true,
      selectedProjectID: "project-a",
      selectedEnvironment: "staging"
    ))
    #expect(!context.isCurrent(
      isUnlocked: false,
      selectedProjectID: "project-a",
      selectedEnvironment: "staging"
    ))
    #expect(!context.isCurrent(
      isUnlocked: true,
      selectedProjectID: "project-b",
      selectedEnvironment: "staging"
    ))
    #expect(!context.isCurrent(
      isUnlocked: true,
      selectedProjectID: "project-a",
      selectedEnvironment: "production"
    ))
  }

  @Test("task admission is single-flight before asynchronous work starts")
  func taskAdmissionRequiresAnEmptyOwnershipSlot() {
    #expect(VaultTaskOwnership.canStart(current: nil))
    #expect(!VaultTaskOwnership.canStart(current: UUID()))
  }

  @Test("project creation cannot be dismissed after durable submission starts")
  func projectCreationDismissalTracksSubmission() {
    #expect(VaultCreationDismissalPolicy.canDismiss(isCreating: false))
    #expect(!VaultCreationDismissalPolicy.canDismiss(isCreating: true))
  }

	@Test("organization creation approval completion dismisses exactly on success")
	func projectCreationApprovalTracksTerminalStatus() {
		#expect(VaultCreationDismissalPolicy.approvalAction(for: nil) == .wait)
		#expect(VaultCreationDismissalPolicy.approvalAction(for: "approval_required") == .wait)
		#expect(VaultCreationDismissalPolicy.approvalAction(for: "failed") == .retry)
		#expect(VaultCreationDismissalPolicy.approvalAction(for: "rejected") == .retry)
		#expect(
			VaultCreationDismissalPolicy.approvalAction(for: "Shared with acme (v1)") == .dismiss
		)
	}

  @Test("personal push rejects missing, non-positive versions and mismatched vault identities")
  @MainActor
  func personalPushResponseBinding() async {
    func run(
      _ response: SyncService.SyncStatus,
      localVersion: Int? = nil
    ) async -> VaultStore {
      let sync = MockPersonalSyncService()
      sync.pushHandlers = [{ response }]
      if let localVersion {
        sync.versionPreflightHandlers = [
          {
            .response(.found(syncStatus(vaultId: "project", version: localVersion)))
          }
        ]
      }
      let keychain = MockKeychainService()
      keychain.envStorage["project"] = (
        name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
      )
      if let localVersion {
        let binding = SyncPrincipalBinding(
          registryURL: "https://lpm.dev",
          principalID: "user",
          scope: "personal"
        )
        #expect(keychain.seedSyncMetadata([
          "project": SyncMetadata(
            lastSyncedAt: Date(timeIntervalSince1970: 1),
            lastAction: "pull",
            lastVersion: localVersion,
            isDirty: true,
            binding: binding
          )
        ]))
      }
      let store = VaultStore(
        keychainService: keychain,
        biometricService: MockBiometricService(),
        apiService: MockAPIService(),
        personalSyncServiceFactory: { _ in sync },
        stableSyncEncryptor: { _, _, _, _ in ("blob", "wrapped") },
        authTokenProvider: { _, _ in "session" }
      )
	  store.appEnvironment = .production
      store.currentUser = personalUser()
      store.projects = [
        VaultProject(
          id: "project", name: "Project", path: "",
          environments: ["default": ["TOKEN": "secret"]]
        )
      ]
      store.isUnlocked = true
      store.selectProject("project")
      await store.pushToCloud()
      return store
    }

    for invalidVersion in [nil, 0, -1] as [Int?] {
      let invalid = await run(syncStatus(vaultId: "project", version: invalidVersion))
      #expect(invalid.lastSyncStatus == "failed")
      #expect(invalid.syncMetadata["project"] == nil)
      #expect(invalid.error?.contains("valid version") == true)
    }

    let wrongVault = await run(syncStatus(vaultId: "other", version: 2))
    #expect(wrongVault.lastSyncStatus == "failed")
    #expect(wrongVault.syncMetadata["project"] == nil)
    #expect(wrongVault.error?.contains("did not match") == true)

    let downgrade = await run(
      syncStatus(vaultId: "project", version: 4),
      localVersion: 5
    )
    #expect(downgrade.lastSyncStatus == "failed")
    #expect(downgrade.error?.contains("valid version") == true)
  }

  @Test("personal pull rejects invalid versions, identity mismatches, and downgrades")
  @MainActor
  func personalPullResponseBinding() async throws {
    func run(
      _ response: SyncService.SyncStatus,
      localVersion: Int? = nil
    ) async throws -> VaultStore {
      let sync = MockPersonalSyncService()
      sync.pullHandlers = [{ response }]
      let keychain = MockKeychainService()
      keychain.envStorage["project"] = (
        name: "Project", path: "", environments: ["default": ["TOKEN": "local"]]
      )
      if let localVersion {
        let binding = SyncPrincipalBinding(
          registryURL: "https://lpm.dev",
          principalID: "user",
          scope: "personal"
        )
        #expect(keychain.seedSyncMetadata([
          "project": SyncMetadata(
            lastSyncedAt: Date(timeIntervalSince1970: 1),
            lastAction: "pull",
            lastVersion: localVersion,
            isDirty: true,
            binding: binding
          )
        ]))
      }
      let store = VaultStore(
        keychainService: keychain,
        biometricService: MockBiometricService(),
        apiService: MockAPIService(),
        personalSyncServiceFactory: { _ in sync },
        authTokenProvider: { _, _ in "session" }
      )
	  store.appEnvironment = .production
      store.currentUser = personalUser()
      store.projects = [
        VaultProject(
          id: "project", name: "Project", path: "",
          environments: ["default": ["TOKEN": "local"]]
        )
      ]
      store.isUnlocked = true
      store.selectProject("project")
      await store.pullFromCloud()
      return store
    }

    for invalidVersion in [nil, 0, -1] as [Int?] {
      let invalid = try await run(syncStatus(vaultId: "project", version: invalidVersion))
      #expect(invalid.lastSyncStatus == "failed")
      #expect(invalid.error?.contains("valid version") == true)
    }
    let mismatch = try await run(syncStatus(vaultId: "other", version: 2))
    #expect(mismatch.lastSyncStatus == "failed")
    #expect(mismatch.error?.contains("did not match") == true)

    let downgrade = try await run(
      syncStatus(
        vaultId: "project",
        version: 4,
        encryptedBlob: "unused",
        wrappedKey: "unused"
      ),
      localVersion: 5
    )
    #expect(downgrade.lastSyncStatus == "failed")
    #expect(downgrade.error?.contains("downgrade") == true)
  }

  @Test("organization pull rejects invalid versions, identity mismatches, and downgrades")
  @MainActor
  func organizationPullResponseBinding() async throws {
    func run(
      _ makeResponse: (Data) -> SyncService.SyncStatus,
      localVersion: Int? = nil
    ) async throws -> VaultStore {
      let slug = "audit-org"
      let keypair = VaultCrypto.generateX25519Keypair()
      let sync = MockOrgSyncService()
      sync.publicKeyRecord = SyncService.PublicKeyRecord(
        publicKey: keypair.publicKey.base64EncodedString(),
        publicKeyVersion: 1,
        publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
      )
      sync.pullResult = makeResponse(keypair.publicKey)
      let keychain = MockKeychainService()
      keychain.envStorage["project"] = (
        name: "Project", path: "", environments: ["default": ["TOKEN": "local"]]
      )
      if let localVersion {
        let binding = SyncPrincipalBinding(
          registryURL: "https://lpm.dev",
          principalID: "org",
          scope: "organization"
        )
        #expect(keychain.seedSyncMetadata([
          "project": SyncMetadata(
            lastSyncedAt: Date(timeIntervalSince1970: 1),
            lastAction: "pull",
            lastVersion: localVersion,
            isDirty: true,
            binding: binding
          )
        ]))
      }
      let store = VaultStore(
        keychainService: keychain,
        biometricService: MockBiometricService(),
        apiService: MockAPIService(),
        orgSyncServiceFactory: { _ in sync },
        sharingKeypairProvider: { keypair },
        authTokenProvider: { _, _ in "session" }
      )
	  store.appEnvironment = .production
      store.currentUser = LPMUser(
        id: "user", username: "user", name: nil, email: nil,
        avatarUrl: nil, plan: nil, createdAt: nil,
        orgs: [
          LPMOrg(
            id: "org", slug: slug, name: "Audit", avatarUrl: nil, role: "admin"
          )
        ]
      )
      store.projects = [
        VaultProject(
          id: "project", name: "Project", path: "",
          environments: ["default": ["TOKEN": "local"]]
        )
      ]
      store.vaultOrgAssociations["project"] = slug
      store.isUnlocked = true
      store.selectAccount(.org(slug))
      store.selectProject("project")
      await store.pullFromOrg(orgSlug: slug)
      return store
    }

    for invalidVersion in [nil, 0, -1] as [Int?] {
      let invalid = try await run { _ in
        syncStatus(vaultId: "project", version: invalidVersion, principalId: "org")
      }
      #expect(invalid.lastSyncStatus == "failed")
      #expect(invalid.error?.contains("valid version") == true)
    }
    let mismatch = try await run { _ in
      syncStatus(vaultId: "other", version: 2, principalId: "org")
    }
    #expect(mismatch.lastSyncStatus == "failed")
    #expect(mismatch.error?.contains("did not match") == true)

    let downgrade = try await run(
      { publicKey in
        syncStatus(
          vaultId: "project",
          version: 4,
          contentKeyVersion: 1,
          recipientPublicKeyVersion: 1,
          recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(publicKey),
          encryptedBlob: "unused",
          wrappedKey: "unused",
          principalId: "org"
        )
      }, localVersion: 5)
    #expect(downgrade.lastSyncStatus == "failed")
    #expect(downgrade.error?.contains("downgrade") == true)
  }

  @Test("sync services retain one connection pool per exact base URL")
  func retainedSyncServiceIdentity() {
    let firstURL = URL(string: "https://audit-one.invalid")!
    let secondURL = URL(string: "https://audit-two.invalid")!
    let first = SyncService.shared(baseURL: firstURL)

    #expect(first === SyncService.shared(baseURL: firstURL))
    #expect(first !== SyncService.shared(baseURL: secondURL))
  }

  @Test("shared personal and organization push validation rejects unbound versions")
  func sharedPushResponseValidation() {
    for invalid in [
      syncStatus(vaultId: "project", version: nil),
      syncStatus(vaultId: "project", version: 0),
      syncStatus(vaultId: "project", version: -1),
      syncStatus(vaultId: "other", version: 2),
    ] {
      #expect(VaultStore.acceptedPushVersion(invalid, vaultId: "project") == nil)
    }
    let valid = syncStatus(vaultId: "project", version: 5)
    #expect(VaultStore.acceptedPushVersion(valid, vaultId: "project") == 5)
    #expect(VaultStore.acceptedPushVersion(valid, vaultId: "project", greaterThan: 5) == nil)
  }

  @Test("personal sync serialization and encryption execute away from the main thread")
  @MainActor
  func personalSyncCryptoIsBackground() async {
    let recorder = AuditThreadRecorder()
    let sync = MockPersonalSyncService()
    let successResponse = syncStatus(vaultId: "project", version: 1)
    sync.pushHandlers = [{ successResponse }]
    let keychain = MockKeychainService()
    keychain.envStorage["project"] = (
      name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
    )
    let store = VaultStore(
      keychainService: keychain,
      biometricService: MockBiometricService(),
      apiService: MockAPIService(),
      personalSyncServiceFactory: { _ in sync },
      stableSyncEncryptor: { _, _, _, _ in
        recorder.captureCurrentThread()
        return ("blob", "wrapped")
      },
      authTokenProvider: { _, _ in "session" }
    )
    store.currentUser = personalUser()
    store.projects = [
      VaultProject(
        id: "project", name: "Project", path: "",
        environments: ["default": ["TOKEN": "secret"]]
      )
    ]
    store.isUnlocked = true
    store.selectProject("project")

    await store.pushToCloud()

    #expect(recorder.usedMainThread == false)
    #expect(store.lastSyncStatus == "Pushed (v1)")
  }

  @Test("clipboard timeout never clears a newer pasteboard owner")
  @MainActor
  func clipboardOwnership() async throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let manager = ClipboardManager(clearDelay: 0.02)
    manager.copy("lpm-secret")
    pasteboard.clearContents()
    pasteboard.setString("newer-owner", forType: .string)

    try await Task.sleep(for: .milliseconds(80))

    #expect(pasteboard.string(forType: .string) == "newer-owner")
    manager.clearClipboard()
    #expect(pasteboard.string(forType: .string) == "newer-owner")
  }

  @Test("an immediate clear removes only a clipboard value owned by the vault")
  @MainActor
  func immediateClipboardOwnership() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("unrelated", forType: .string)
    let manager = ClipboardManager(clearDelay: 60)

    manager.clearClipboard()
    #expect(pasteboard.string(forType: .string) == "unrelated")

    manager.copy("owned")
    #expect(pasteboard.types?.contains(ClipboardManager.concealedType) == true)
    #expect(pasteboard.types?.contains(ClipboardManager.transientType) == true)
    manager.clearClipboard()
    #expect(pasteboard.string(forType: .string) == nil)
  }

  @Test("application termination synchronously locks and clears sensitive state")
  @MainActor
  func terminationLocksVault() {
    let delegate = AppDelegate()
    var lockCount = 0
    delegate.lockVault = { lockCount += 1 }

    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification)
    )

    #expect(lockCount == 1)
  }

  @Test("build script rejects undeclared build modes before signing")
  func buildScriptRejectsUnknownMode() throws {
    let script = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("build-app.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path, "invalid-mode"]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus != 0)
    #expect(message.contains("Usage:"))
    #expect(message.contains("release|debug"))
    #expect(!message.contains("Signing identity"))
  }

  @MainActor
  private func waitForWorkspaceSnapshots(_ store: VaultStore, count: Int) async throws {
    try await waitForAuditCondition { store.workspaceSnapshots.count == count }
  }

  @MainActor
  private func waitForWorkspaceSnapshotBuilds(_ store: VaultStore, count: Int) async throws {
    try await waitForAuditCondition { store.workspaceSnapshotBuildCount >= count }
  }

  @MainActor
  private func waitForAuditCondition(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AuditWaitError.timedOut
  }

  private func syncStatus(
    vaultId: String?,
    version: Int?,
    contentKeyVersion: Int? = nil,
    recipientPublicKeyVersion: Int? = nil,
    recipientPublicKeyFingerprint: String? = nil,
    encryptedBlob: String? = nil,
    wrappedKey: String? = nil,
    principalId: String? = "user",
    callerUserId: String? = "user"
  ) -> SyncService.SyncStatus {
    SyncService.SyncStatus(
      vaultId: vaultId,
      version: version,
      cryptoVersion: VaultCrypto.currentCryptoVersion,
      contentKeyVersion: contentKeyVersion,
      recipientPublicKeyVersion: recipientPublicKeyVersion,
      recipientPublicKeyFingerprint: recipientPublicKeyFingerprint,
      status: "ok",
      error: nil,
      code: nil,
      serverVersion: nil,
      hint: nil,
      encryptedBlob: encryptedBlob,
      wrappedKey: wrappedKey,
      updatedAt: nil,
      principalId: principalId,
      callerUserId: callerUserId
    )
  }

  private func personalUser() -> LPMUser {
    LPMUser(
      id: "user",
      username: "user",
      name: nil,
      email: nil,
      avatarUrl: nil,
      plan: nil,
      createdAt: nil,
      orgs: nil
    )
  }
}

private enum AuditWaitError: Error {
  case timedOut
}

private final class AuditThreadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Bool?

  var usedMainThread: Bool? { lock.withLock { storage } }

  func captureCurrentThread() {
    lock.withLock { storage = Thread.isMainThread }
  }
}

private final class LockedTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: TimeInterval

  init(_ value: TimeInterval) { storage = value }

  var value: TimeInterval {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class LockedTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int { lock.withLock { storage } }

  func increment() { lock.withLock { storage += 1 } }
}

private final class SnapshotBuildTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var activeBuildCount = 0
  private var cancellations = 0
  private var maximumConcurrentBuilds = 0
  private var starts = 0

  var cancelledBuildCount: Int { lock.withLock { cancellations } }
  var maximumConcurrentBuildCount: Int { lock.withLock { maximumConcurrentBuilds } }
  var startedBuildCount: Int { lock.withLock { starts } }

  func begin() {
    lock.withLock {
      activeBuildCount += 1
      starts += 1
      maximumConcurrentBuilds = max(maximumConcurrentBuilds, activeBuildCount)
    }
  }

  func end() {
    lock.withLock { activeBuildCount -= 1 }
  }

  func recordCancellation() {
    lock.withLock { cancellations += 1 }
  }
}
