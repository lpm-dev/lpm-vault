import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	/// What the workspace's title bar, header and sidebar say to VoiceOver and
	/// Voice Control: a control's name holds the words it shows, and one that
	/// shows only an icon is named by what it does.
	@Suite("Workspace header accessibility", .serialized)
	@MainActor
	struct WorkspaceHeaderAccessibilityTests {
		@Test("each header control is named by the words it shows, or by what it does when it shows only an icon")
		func headerNames() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let expected: [(String, NSAccessibility.Role)] = [
				("Connect CLI", .button), ("Refresh", .button), ("Publish…", .button), ("Lock LPM Vault", .button),
				("Show inspector", .button), ("Project Settings", .button), ("New Key", .button),
				("Reveal all values", .checkBox), ("Copy all .env values", .button),
				("Import variables into .env", .button), ("Export .env", .button),
			]
			let elements = AccessibilityTree.visibleElements(in: host.window, of: host.view)
			for (name, role) in expected {
				#expect(elements.contains { $0.role == role && ($0.label ?? $0.title) == name }, "No \(role.rawValue) is named \(name)")
			}
			for symbolName in ["Split View Horizontally Right", "Download", "Share", "New secret"] {
				#expect(!elements.contains { $0.says(symbolName) }, "A control is named \(symbolName)")
			}
		}

		@Test("Refresh sits with the sync status on the right, and Connect CLI leads the actions after them, before Publish and Lock")
		func titleBarOrder() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let name = try await host.drawnFrame(saying: "— billing-app")
			let refresh = try await host.drawnFrame(saying: "Refresh")
			let sync = try await host.drawnFrame(saying: "Sync status: Local")
			let connect = try await host.drawnFrame(saying: "Connect CLI")
			let publish = try await host.drawnFrame(saying: "Publish…")
			let lock = try await host.drawnFrame(saying: "Lock LPM Vault")
			#expect(refresh.minX > host.view.bounds.width / 2 && name.maxX < refresh.minX, "Refresh isn't read as part of the title: \(name) \(refresh)")
			#expect(refresh.maxX < sync.minX && sync.minX - refresh.maxX < 32, "Refresh sits beside the sync status: \(refresh) \(sync)")
			#expect(sync.maxX < connect.minX && connect.maxX < publish.minX && publish.maxX < lock.minX)
		}

		@Test("the header leaves CLI approval to the project's card and settings, and names it only when it needs fixing, opening Project Settings")
		func approvalOnlyWhenItNeedsFixing() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			#expect(try await host.waitForText("All variables"))
			#expect(fixture.store.selectedProjectCliAccess == .automatic)
			#expect(!AccessibilityTree.visibleElements(in: host.window, of: host.view).contains { $0.label?.hasPrefix("CLI approval") == true },
				"The header names no approval that's set as it should be")
			host.window.close()

			fixture.keychain.unreadableCliAccess = ["header"]
			fixture.keychain.failureError = .contradictoryApproval
			let fixing = try await workspace(fixture.store)
			defer { fixing.window.close() }
			let link = try await fixing.waitForElement(saying: "CLI approval needs fixing")
			#expect(link.role == .button && link.value == "Contradicts itself")
			try await fixing.click("CLI approval needs fixing")
			#expect(try await fixing.waitForText("Delete Locally"))
		}

		@Test("the header's Settings button opens the project's settings")
		func settingsButton() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let button = try await host.waitForElement(saying: "Project Settings")
			#expect(button.role == .button && button.help == "Project Settings (⌘I)")
			try await host.click("Project Settings")
			#expect(try await host.waitForText("Delete Locally"))
		}

		@Test("Import and Export show their names where there's room, and go into a More menu where there isn't, rather than becoming bare icons")
		func importExportLabels() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let wide = try await workspace(fixture.store, width: 1400)
			for name in ["Import variables into .env", "Export .env"] {
				let drawn = try await wide.drawnFrame(saying: name)
				#expect(drawn.width > 30, "\(name) shows its name: \(drawn)")
			}
			wide.window.close()

			let narrow = try await workspace(fixture.store, width: 1040)
			defer { narrow.window.close() }
			try await narrow.click("Show inspector")
			#expect(try await narrow.waitForText("Hide inspector", exactly: true))
			let elements = AccessibilityTree.visibleElements(in: narrow.window, of: narrow.view)
			#expect(!elements.contains { $0.says("Import variables into .env") }, "Import isn't a bare icon")
			try await narrow.click("More actions")
			let menu = try await narrow.popoverWindow()
			#expect(try await narrow.waitForText("Import into .env…", in: menu))
			#expect(try await narrow.waitForText("Export .env…", in: menu))
			try await narrow.click("Import into .env…", in: menu)
			#expect(try await narrow.waitUntil { narrow.window.sheets.first != nil }, "Import opens its sheet from the menu")
		}

		@Test("the sidebar's footer names its icon pages, which open their pages, and the vault it shows, which opens the account menu")
		func sidebarFooter() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			for name in ["Platforms", "Settings"] {
				#expect(try await host.waitForElement(saying: name).role == .button, "\(name) is a named button, not a bare icon")
			}
			try await host.click("Settings")
			#expect(try await host.waitUntil { fixture.store.accountPage == .settings })
			try await host.click("Platforms")
			#expect(try await host.waitUntil { fixture.store.accountPage == .platforms })
			try await host.click("Account menu")
			#expect(try await host.waitForText("Sign In…"))
		}

		@Test("the inspector toggle says whether it shows or hides the inspector")
		func inspectorToggle() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			try await host.click("Show inspector")
			#expect(try await host.waitForText("Hide inspector", exactly: true))
			#expect(try await host.waitForText("Resize inspector", exactly: true))
			try await host.click("Hide inspector")
			#expect(try await host.waitForText("Show inspector", exactly: true))
		}

		@Test("Reveal is a toggle that keeps its name, and says when it's on")
		func revealToggle() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let reveal = try await host.waitForElement(saying: "Reveal all values")
			#expect(reveal.role == .checkBox)
			#expect(reveal.isOn == false)
			reveal.press()
			#expect(try await host.waitUntil { revealToggle(in: host)?.isOn == true })
			#expect(try await host.waitForText("values shown"))
			try #require(revealToggle(in: host)).press()
			#expect(try await host.waitUntil { revealToggle(in: host)?.isOn == false })
		}

		@Test("Copy all's name begins with the words it shows, while it waits for a refresh to copy and once it has")
		func copyAllNames() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let copyFeedback = ManualFeedbackTimer()
			let host = try await workspace(fixture.store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			// A refresh held before it reads the Keychain keeps Copy all copying.
			let entered = DispatchSemaphore(value: 0)
			let release = DispatchSemaphore(value: 0)
			fixture.keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
			let refresh = Task { await fixture.store.refreshLocalState() }
			await withCheckedContinuation { continuation in
				DispatchQueue.global().async { entered.wait(); continuation.resume() }
			}
			fixture.keychain.beforeKeychainTransaction = nil
			try await host.click("Copy all .env values")
			#expect(try await host.waitForText("Copying all .env values", exactly: true))
			release.signal()
			await refresh.value
			#expect(try await host.waitForText("Copied all .env values", exactly: true))
			#expect(fixture.store.clipboard.pasteboard.string(forType: .string)?.contains("PORT=") == true)
			#expect(try await host.waitUntil { copyFeedback.started == 1 }, "The confirmation starts waiting just after Copied shows")
			copyFeedback.expire()
			#expect(try await host.waitForText("Copy all .env values", exactly: true))
		}

		@Test("filter and view chips say which one is selected")
		func chipsSaySelection() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			#expect(try await host.waitUntil { selected(in: host) == ["All keys"] })
			try #require(chip("Drift, 1", in: host)).press()
			#expect(try await host.waitUntil { selected(in: host) == ["Drift, 1"] })
			_ = try await host.clickSidebarEnvironment(".env")
			// One environment's view is a mode, so it's segments, as every mode switch in the app is, not chips.
			#expect(try await host.waitUntil {
				AccessibilityTree.visibleElements(in: host.window, of: host.view).filter { $0.role == .radioButton }.compactMap(\.texts.first) == ["Table", "Raw Text"]
			})
			#expect(selected(in: host).isEmpty, "No filter chip shows in one environment's view")
			try await host.click("Raw Text")
			#expect(try await host.waitForText("One KEY=value per line"))
		}

		@Test("the sync status is one control, the size it's drawn, and opens its menu in the app's popover")
		func syncMenuIsOneControl() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let menus = AccessibilityTree.visibleElements(in: host.window, of: host.view).filter { $0.says("Sync status: Local") }
			#expect(menus.count == 1)
			#expect(menus.allSatisfy { $0.role == .button && $0.frame.height >= 26 })
			try await host.click("Sync status: Local")
			let popover = try await host.popoverWindow()
			#expect(try await host.waitForText("Sign In to Sync…", in: popover))
			#expect(try await host.waitForText("Values stay on this Mac. Sign in to sync them with lpm.dev.", in: popover),
				"It says what Local means before what can be done")
			try host.key("\u{1b}", code: 53, in: popover)
			#expect(try await host.waitUntil { !popover.isVisible }, "Esc closes it")
		}

		@Test("a bar menu is one control however many parts its label has, and opens its rows in the app's popover")
		func barMenuIsOneControl() async throws {
			let chosen = ChosenRow()
			let host = SheetTestHost(
				VaultBarMenu(accessibilityLabel: "Publish", rows: [VaultMenuList<Int>.Row(id: 1, title: "New destination…")],
					onChoose: { chosen.id = $0 }) {
					Image(systemName: "arrow.up.to.line")
					Text("Publish")
				}
				.padding(20),
				size: NSSize(width: 240, height: 80), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try await host.settle()
			let menus = AccessibilityTree.visibleElements(in: host.window, of: host.view).filter { $0.says("Publish") }
			#expect(menus.count == 1)
			#expect(menus.allSatisfy { $0.role == .button && $0.frame.height >= 26 })
			try await host.click("Publish")
			let popover = try await host.popoverWindow()
			try await host.click("New destination…", in: popover)
			#expect(try await host.waitUntil { chosen.id == 1 })
			#expect(try await host.waitUntil { !popover.isVisible }, "Choosing a row closes the menu")
		}

		@Test("sidebar counts say one in the singular")
		func sidebarCounts() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let elements = AccessibilityTree.visibleElements(in: host.window, of: host.view)
			func row(_ name: String) -> AccessibilityTree.Element? { elements.first { $0.role == .button && $0.says(name) } }
			#expect(row(".env.production")?.value == "1 secret")
			#expect(row(".env")?.value == "2 secrets")
			#expect(row("Schema")?.value == "1 declared key")
			#expect(elements.contains { $0.says("solo, 1 secret", as: .leading) })
			#expect(elements.contains { $0.says("billing-app, 3 secrets", as: .leading) })
		}

		private func revealToggle<V: View>(in host: SheetTestHost<V>) -> AccessibilityTree.Element? {
			AccessibilityTree.visibleElements(in: host.window, of: host.view).first { $0.role == .checkBox && $0.says("Reveal all values") }
		}

		private static let chips: Set<String> = ["All keys", "Drift, 1", "Missing, 1", "Invalid, 1"]

		private func chip<V: View>(_ name: String, in host: SheetTestHost<V>) -> AccessibilityTree.Element? {
			AccessibilityTree.visibleElements(in: host.window, of: host.view).first { $0.role == .button && $0.label == name }
		}

		/// The names of the header's selected filter or view chips.
		private func selected<V: View>(in host: SheetTestHost<V>) -> [String] {
			AccessibilityTree.visibleElements(in: host.window, of: host.view)
				.filter { $0.role == .button && $0.isSelected }.compactMap(\.label).filter(Self.chips.contains)
		}

		private struct Fixture {
			let store: VaultStore
			let keychain: MockKeychainService
			let folder: String

			@MainActor func tearDown() {
				store.lock()
				store.clipboard.pasteboard.releaseGlobally()
				try? FileManager.default.removeItem(atPath: folder)
			}
		}

		/// A project whose PORT fails its one rule in `.env` and drifts from
		/// `.env.production`, and a second project with one secret.
		private func makeFixture() throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appending(path: "workspace-header-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "header", name: "billing-app", path: folder,
				environments: ["default": ["PORT": "not-a-port", "TOKEN": "a"], "production": ["PORT": "443"]])
			let solo = VaultProject(id: "solo", name: "solo", path: "", environments: ["default": ["ONLY": "x"]])
			for project in [project, solo] {
				keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: project.environments)
			}
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil }, clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			store.isUnlocked = true
			store.projects = [project, solo]
			store.openProject(id: project.id)
			return Fixture(store: store, keychain: keychain, folder: folder)
		}

		private func workspace(_ store: VaultStore, width: CGFloat = 1400, copyFeedback: ManualFeedbackTimer = ManualFeedbackTimer())
			async throws -> SheetTestHost<some View>
		{
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "workspace-header-accessibility"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).environment(VaultQuitSettings(defaults: defaults))
				.environment(\.vaultCopyFeedbackTimer, copyFeedback.timer)
				.defaultAppStorage(defaults),
				size: NSSize(width: width, height: 800), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["header"] != nil })
			#expect(try await host.waitForText("Invalid, 1"))
			try await host.settle()
			return host
		}
	}
}

@MainActor
private final class ChosenRow {
	var id: Int?
}
