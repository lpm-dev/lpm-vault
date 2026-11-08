import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Settings search, rendered")
	@MainActor
	struct SettingsSearchInteractionTests {
		/// Settings as the workspace shows it: the overlay at the page the store shows.
		private struct Overlay: View {
			@Bindable var store: VaultStore

			var body: some View {
				if let category = store.shownSettingsCategory {
					VaultSettingsOverlay(store: store, category: category)
				}
			}
		}

		private final class AnchorRecord: @unchecked Sendable {
			private let lock = NSLock()
			private var stored: Set<VaultSettingsEntry.ID> = []

			var ids: Set<VaultSettingsEntry.ID> {
				get { lock.withLock { stored } }
				set { lock.withLock { stored = newValue } }
			}
		}

		private func makeStore(_ defaults: UserDefaults) -> VaultStore {
			let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
				apiService: MockAPIService(), preferences: defaults, authTokenProvider: { _, _ in nil },
				settings: VaultSettings(defaults: defaults))
			store.isUnlocked = true
			store.locateCLI = { .found(path: "/opt/homebrew/bin/lpm", version: "1.4.2") }
			return store
		}

		private func overlay(_ store: VaultStore, _ defaults: UserDefaults) async throws -> SheetTestHost<some View> {
			let host = SheetTestHost(Overlay(store: store)
				.environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults))
				.environment(VaultQuitSettings(defaults: defaults)),
				size: NSSize(width: 1040, height: 760), keepsRequestedSize: true)
			try await host.settle()
			return host
		}

		private func isShown<V: View>(_ label: String, in host: SheetTestHost<V>, where matches: (AccessibilityTree.Element) -> Bool) -> Bool {
			AccessibilityTree.visibleElements(in: host.window, of: host.view).contains { $0.says(label) && matches($0) }
		}

		@Test("typing lists the settings that match under their pages, in the menu's place; Return shows the best on its page, scrolled into view")
		func typeAndReturn() async throws {
			let defaults = try isolatedDefaults()
			let store = makeStore(defaults)
			store.showSettings(.general)
			let host = try await overlay(store, defaults)
			defer { host.window.close() }
			let capture = VaultSettingsEntry.hideFromCapture.title

			try host.typeText("screenshot", placeholder: "Search")
			#expect(try await host.waitForText("SECURITY", exactly: true))
			let result = try await host.waitForElement(saying: capture)
			#expect(result.role == .button)
			#expect(try await host.waitForTextToDisappear("Appearance"), "The results take the menu's place")

			try host.press(.return)
			#expect(try await host.waitUntil { store.shownSettingsCategory == .security })
			#expect(try await host.waitUntil { isShown(capture, in: host) { $0.isOn != nil } }, "The switch, below the fold, is scrolled into view")
			#expect(host.isEditing(placeholder: "Search"), "The search keeps the keyboard")
		}

		@Test("from the search field the arrows show each result on its page; Esc clears the search, then closes Settings")
		func arrowsAndEscape() async throws {
			let defaults = try isolatedDefaults()
			let store = makeStore(defaults)
			store.showSettings(.general)
			let host = try await overlay(store, defaults)
			defer { host.window.close() }

			try host.typeText("backup", placeholder: "Search")
			_ = try await host.waitForElement(saying: VaultSettingsEntry.exportBackup.title)
			try host.press(.down)
			#expect(try await host.waitUntil { store.shownSettingsCategory == .backup })
			#expect(try await host.waitUntil { isShown("Export Backup…", in: host) { $0.role == .button } })
			try host.press(.down)
			try host.press(.down)
			try host.press(.down)
			#expect(try await host.waitUntil { store.shownSettingsCategory == .security }, "On to Security's fact about backups")
			try host.press(.up)
			#expect(try await host.waitUntil { store.shownSettingsCategory == .backup })

			try host.press(.escape)
			#expect(try await host.waitForText("Appearance", exactly: true), "The menu is back")
			#expect(host.fieldText(placeholder: "Search")?.isEmpty == true && store.accountPage == .settings)
			try host.press(.escape)
			#expect(try await host.waitUntil { store.accountPage == nil })
		}

		@Test("a search that finds nothing says so")
		func nothingFound() async throws {
			let defaults = try isolatedDefaults()
			let store = makeStore(defaults)
			store.showSettings(.general)
			let host = try await overlay(store, defaults)
			defer { host.window.close() }
			try host.typeText("zzzz", placeholder: "Search")
			#expect(try await host.waitForText("No settings match “zzzz”."))
		}

		@Test("⌘F while Settings shows puts the keyboard in its search")
		func findShortcut() async throws {
			let defaults = try isolatedDefaults()
			let store = makeStore(defaults)
			store.showSettings(.security)
			let host = try await overlay(store, defaults)
			defer { host.window.close() }
			#expect(!host.isEditing(placeholder: "Search"))
			NotificationCenter.default.post(name: VaultFindTarget(showingSettings: store.isShowingAccountPage).notification, object: nil)
			#expect(try await host.waitUntil { host.isEditing(placeholder: "Search") })
		}

		@Test("every setting search lists is on its page, where search can bring it into view", arguments: VaultSettingsCategory.allCases)
		func everySettingIsOnItsPage(category: VaultSettingsCategory) async throws {
			let defaults = try isolatedDefaults()
			let store = makeStore(defaults)
			let record = AnchorRecord()
			let host = SheetTestHost(VaultSettingsContent(store: store, category: category)
				.environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults))
				.environment(VaultQuitSettings(defaults: defaults))
				.onPreferenceChange(VaultSettingsAnchors.self) { record.ids = $0 },
				size: NSSize(width: 800, height: 700), keepsRequestedSize: true)
			defer { host.window.close() }
			let expected = Set(VaultSettingsEntry.all.filter { $0.category == category }.map(\.id))
			#expect(try await host.waitUntil { record.ids == expected }, "\(category): \(record.ids.sorted()) of \(expected.sorted())")
		}
	}
}
