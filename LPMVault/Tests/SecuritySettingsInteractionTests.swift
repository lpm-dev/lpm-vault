import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Security, CLI and About settings, rendered")
	@MainActor
	struct SecuritySettingsInteractionTests {
		private struct Fixture {
			let store: VaultStore
			let biometric: MockBiometricService
			let defaults: UserDefaults
			let folder: String

			@MainActor func tearDown() {
				store.lock()
				store.clipboard.pasteboard.releaseGlobally()
				try? FileManager.default.removeItem(atPath: folder)
			}
		}

		private func makeFixture(_ configure: (VaultSettings) -> Void = { _ in }) throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appending(path: "security-settings-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			let defaults = try isolatedDefaults()
			let settings = VaultSettings(defaults: defaults)
			configure(settings)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "guarded", name: "guarded-app", path: folder,
				environments: ["default": ["PORT": "8080", "TOKEN": "s3cret-token"]])
			keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: project.environments)
			let biometric = MockBiometricService()
			let store = VaultStore(keychainService: keychain, biometricService: biometric,
				apiService: MockAPIService(), preferences: defaults, authTokenProvider: { _, _ in nil }, settings: settings,
				clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			store.locateCLI = { .found(path: "/opt/homebrew/bin/lpm", version: "1.4.2") }
			return Fixture(store: store, biometric: biometric, defaults: defaults, folder: folder)
		}

		private func overlay(_ fixture: Fixture, _ category: VaultSettingsCategory, updates: UpdateChecker = UpdateChecker())
			async throws -> SheetTestHost<some View>
		{
			let host = SheetTestHost(VaultSettingsOverlay(store: fixture.store, category: category)
				.environment(updates)
				.environment(VaultAppearanceSettings(defaults: fixture.defaults))
				.environment(VaultQuitSettings(defaults: fixture.defaults)),
				size: NSSize(width: 1040, height: 760), keepsRequestedSize: true)
			try await host.settle()
			return host
		}

		private func workspace(_ fixture: Fixture) async throws -> SheetTestHost<some View> {
			await fixture.store.refreshCliAccess()
			let host = SheetTestHost(VaultWorkspaceView(store: fixture.store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: fixture.defaults)).environment(VaultQuitSettings(defaults: fixture.defaults))
				.defaultAppStorage(fixture.defaults),
				size: NSSize(width: 1400, height: 800), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { fixture.store.workspaceSnapshots["guarded"] != nil })
			try await host.settle()
			return host
		}

		private func revealToggle<V: View>(in host: SheetTestHost<V>) -> AccessibilityTree.Element? {
			AccessibilityTree.visibleElements(in: host.window, of: host.view).first { $0.role == .checkBox && $0.says("Reveal all values") }
		}

		@Test("Security names each setting, shows its choice, and says what LPM Vault always does")
		func securityPage() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await overlay(fixture, .security)
			defer { host.window.close() }
			for text in ["LOCKING", "Lock after", "VALUES", "Ask again to show or copy a value", "Hide shown values again",
				"CLIPBOARD", "Clear copied values after",
				"Locks when your Mac sleeps, its screen locks or you close the window", "Hides values while another app is in front",
				"Copies stay on this Mac: Universal Clipboard and clipboard history apps skip them",
				"Publishing and backups ask for Touch ID or your password every time, however recently you unlocked"] {
				#expect(try await host.waitForText(text), "\(text)")
			}
			let lockAfter = try await host.waitForElement(saying: "Lock after")
			#expect(lockAfter.value == "2 min")
			#expect(try await !host.text().contains("Restore Defaults"), "Nothing to restore while every setting is as it started")
			try await host.scrollToEnd(ofScrollViewShowing: "Lock after")
			#expect(try await host.waitForText("SCREEN", exactly: true))
			let capture = try await host.waitForElement(saying: "Hide from screenshots and screen sharing")
			#expect(capture.isOn == true)
		}

		@Test("a lock time chosen from its menu is saved and applies, and Restore Defaults puts the page back")
		func choosesAndRestores() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await overlay(fixture, .security)
			defer { host.window.close() }
			try await host.click("Lock after")
			let menu = try await host.popoverWindow()
			try await host.click("15 min", in: menu)
			#expect(try await host.waitUntil { fixture.store.settings.lockAfter == .fifteenMinutes })
			#expect(VaultSettings(defaults: fixture.defaults).lockAfter == .fifteenMinutes)
			#expect(try await host.waitForText("Restore Defaults", exactly: true))
			try await host.scrollToEnd(ofScrollViewShowing: "Lock after")
			try await host.click("Hide from screenshots and screen sharing")
			#expect(try await host.waitUntil { !fixture.store.settings.hidesFromCapture })

			try await host.click("Restore Defaults")
			#expect(try await host.waitUntil { fixture.store.settings.security == VaultSettings.standard.security })
			#expect(try await host.waitForTextToDisappear("Restore Defaults"))
		}

		@Test("the CLI page shows the lpm the shell finds, and offers to install one it doesn't")
		func cliStatus() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let answer = LockedCLIStatus(.found(path: "/opt/homebrew/bin/lpm", version: "1.4.2"))
			fixture.store.locateCLI = { answer.value }
			let host = try await overlay(fixture, .cli)
			defer { host.window.close() }
			#expect(try await host.waitForText("lpm 1.4.2", exactly: true))
			#expect(try await host.waitForText("At /opt/homebrew/bin/lpm, as your shell finds it."))
			#expect(try await host.waitForText("Ask before the CLI reads a new project"))
			#expect(try await !host.text().contains("Install…"))

			answer.value = .notFound
			try await host.click("Check Again")
			#expect(try await host.waitForText("Not found", exactly: true))
			#expect(try await host.waitForText("Install…", exactly: true))
		}

		@Test("About opens release notes, documentation and a feedback issue that holds the version and no values")
		func aboutLinks() async throws {
			var opened: [URL] = []
			var acknowledged = 0
			let build = VaultBuildInfo(info: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "8"])
			let host = SheetTestHost(VaultAboutLinksSection(build: build, open: { opened.append($0) }, showAcknowledgements: { acknowledged += 1 })
				.frame(width: 640), size: NSSize(width: 640, height: 320))
			defer { host.window.close() }
			try await host.click("Open release notes")
			try await host.click("Open documentation")
			try await host.click("Write…")
			try await host.click("Show acknowledgements")
			#expect(try await host.waitUntil { opened.count == 3 && acknowledged == 1 })
			#expect(Array(opened.prefix(2)) == [VaultAboutLinks.releaseNotes, VaultAboutLinks.documentation])
			let feedback = try #require(URLComponents(url: opened[2], resolvingAgainstBaseURL: false))
			#expect(feedback.host == "github.com" && feedback.path == "/lpm-dev/lpm-vault/issues/new")
			let body = try #require(feedback.queryItems?.first { $0.name == "body" }?.value)
			#expect(body.contains("LPM Vault 1.1.0 (build 8)"))
			#expect(body.contains("macOS "))
		}

		@Test("with asking again on, Reveal All asks once for Touch ID, then reveals, and asks nothing more while the approval holds")
		func revealAsksAgain() async throws {
			let fixture = try makeFixture { $0.valueApproval = .afterFiveMinutes }
			defer { fixture.tearDown() }
			let host = try await workspace(fixture)
			defer { host.window.close() }
			try #require(revealToggle(in: host)).press()
			#expect(try await host.waitUntil { revealToggle(in: host)?.isOn == true })
			#expect(fixture.biometric.confirmationReasons == [VaultValueAccess.reason])
			try #require(revealToggle(in: host)).press()
			#expect(try await host.waitUntil { revealToggle(in: host)?.isOn == false })
			try #require(revealToggle(in: host)).press()
			#expect(try await host.waitUntil { revealToggle(in: host)?.isOn == true })
			#expect(fixture.biometric.confirmationReasons.count == 1, "The approval holds for five minutes")

			fixture.store.valueAccess.hideRevealed()
			#expect(try await host.waitUntil { revealToggle(in: host)?.isOn == false }, "Masking again clears what the table shows")
		}

		@Test("a declined approval reveals and copies nothing")
		func declinedApproval() async throws {
			let fixture = try makeFixture { $0.valueApproval = .afterFifteenMinutes }
			defer { fixture.tearDown() }
			let host = try await workspace(fixture)
			defer { host.window.close() }
			fixture.biometric.shouldSucceed = false
			try #require(revealToggle(in: host)).press()
			try await host.click("Copy all .env values")
			#expect(try await host.waitUntil { fixture.biometric.confirmationReasons.count >= 1 })
			try await host.settle()
			#expect(revealToggle(in: host)?.isOn == false)
			#expect(fixture.store.clipboard.pasteboard.string(forType: .string) == nil)
		}

		@Test("the backup reminder shows a month after the last backup, opens Backup & Restore, and Later puts it off a week")
		func backupReminder() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
			fixture.defaults.set(start, forKey: VaultBackupReminder.startedKey)
			let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
				apiService: MockAPIService(), preferences: fixture.defaults, authTokenProvider: { _, _ in nil },
				settings: fixture.store.settings)
			let now = LockedDate(start.addingTimeInterval(VaultBackupReminder.interval - 60))
			store.backupReminderNow = { now.value }
			store.isUnlocked = true
			store.projects = fixture.store.projects
			let host = SheetTestHost(VaultSidebarView(store: store, mode: .constant(.matrix),
				filter: .constant(.all), searchText: .constant(""), showsAccountSwitcher: .constant(false),
				onNewProject: {}, onNewEnvironment: {}, onProjectSettings: { _ in }, onRenameProject: { _ in },
				onDeleteProject: { _ in }, onRenameEnvironment: { _ in }, onDuplicateEnvironment: { _ in },
				onClearEnvironment: { _ in }, onDeleteEnvironment: { _ in }, reorder: VaultSidebarReorder()),
				size: NSSize(width: 260, height: 600), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await !host.text().contains("Back up your projects"), "Not yet a month")
			now.value = start.addingTimeInterval(VaultBackupReminder.interval)
			#expect(store.isBackupReminderDue)
			// The sidebar reads the time again each hour, or as anything it shows changes.
			store.settings.remindsToBackUp = false
			store.settings.remindsToBackUp = true
			#expect(try await host.waitForText("Back up your projects"))
			#expect(try await host.waitForText("This Mac has no backup of your projects yet."))
			try await host.click("Back Up…")
			#expect(store.accountPage == .settings && store.shownSettingsCategory == .backup)
			try await host.click("Later")
			#expect(try await host.waitForTextToDisappear("Back up your projects"))
			#expect(store.backupReminderPostponedUntil == now.value.addingTimeInterval(VaultBackupReminder.postponement))
			now.value = now.value.addingTimeInterval(VaultBackupReminder.postponement)
			#expect(store.isBackupReminderDue, "Due again a week later")
			store.settings.remindsToBackUp = false
			#expect(!store.isBackupReminderDue, "Off in Settings, never")
			store.lock()
		}
	}
}

/// The CLI a test's shell finds, changed between checks.
final class LockedCLIStatus: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: LPMCLIStatus
	init(_ status: LPMCLIStatus) { stored = status }
	var value: LPMCLIStatus {
		get { lock.withLock { stored } }
		set { lock.withLock { stored = newValue } }
	}
}

/// A date a test moves, read from a closure that can't say which actor it runs on.
final class LockedDate: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: Date
	init(_ date: Date) { stored = date }
	var value: Date {
		get { lock.withLock { stored } }
		set { lock.withLock { stored = newValue } }
	}
}
