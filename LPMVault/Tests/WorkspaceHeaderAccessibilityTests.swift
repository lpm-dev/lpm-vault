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
				("CLI approval", .checkBox), ("Show inspector", .button), ("More actions", .button), ("New key", .button),
				("Reveal all values", .checkBox), ("Copy all .env values", .button),
				("Import a .env file into .env", .button), ("Export .env", .button),
			]
			let elements = AccessibilityTree.visibleElements(in: host.window, of: host.view)
			for (name, role) in expected {
				#expect(elements.contains { $0.role == role && ($0.label ?? $0.title) == name }, "No \(role.rawValue) is named \(name)")
			}
			for symbolName in ["Split View Horizontally Right", "Download", "Share", "New secret"] {
				#expect(!elements.contains { $0.says(symbolName) }, "A control is named \(symbolName)")
			}
			#expect(elements.first { $0.role == .checkBox && $0.title == "CLI approval" }?.value == "Automatic")
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

		@Test("Copy all's name begins with the words it shows, while it copies and once it has")
		func copyAllNames() async throws {
			let fixture = try makeFixture()
			let gate = AsyncStream<Void>.makeStream()
			fixture.biometric.authenticateHandlers = [{
				for await _ in gate.stream { return true }
				return false
			}]
			defer { gate.continuation.finish(); fixture.tearDown() }
			let copyFeedback = ManualCopyFeedbackTimer()
			let host = try await workspace(fixture.store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			try await host.click("Copy all .env values")
			#expect(try await host.waitForText("Copying all .env values", exactly: true))
			gate.continuation.yield(())
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
			#expect(try await host.waitUntil { selected(in: host) == ["Table"] })
			try #require(chip("Raw text", in: host)).press()
			#expect(try await host.waitUntil { selected(in: host) == ["Raw text"] })
		}

		@Test("the sync menu is one control, the size it's drawn")
		func syncMenuIsOneControl() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await workspace(fixture.store)
			defer { host.window.close() }
			let menus = AccessibilityTree.visibleElements(in: host.window, of: host.view).filter { $0.says("Sync status: Local") }
			#expect(menus.count == 1)
			#expect(menus.allSatisfy { $0.role == .menuButton && $0.frame.height >= 26 })
		}

		@Test("a title bar menu is one control however many parts its label has")
		func barMenuIsOneControl() async throws {
			let host = SheetTestHost(
				VaultBarMenu(accessibilityLabel: "Publish") {
					Button("New destination…") {}
				} label: {
					Image(systemName: "arrow.up.to.line")
					Text("Publish")
				}
				.padding(20),
				size: NSSize(width: 240, height: 80), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try await host.settle()
			let menus = AccessibilityTree.visibleElements(in: host.window, of: host.view).filter { $0.role == .menuButton }
			#expect(menus.count == 1)
			#expect(menus.first?.says("Publish") == true)
			#expect((menus.first?.frame.height ?? 0) >= 26)
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

		private static let chips: Set<String> = ["All keys", "Drift, 1", "Missing, 1", "Invalid, 1", "Table", "Raw text"]

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
			let biometric: MockBiometricService
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
			let biometric = MockBiometricService()
			let project = VaultProject(id: "header", name: "billing-app", path: folder,
				environments: ["default": ["PORT": "not-a-port", "TOKEN": "a"], "production": ["PORT": "443"]])
			let solo = VaultProject(id: "solo", name: "solo", path: "", environments: ["default": ["ONLY": "x"]])
			for project in [project, solo] {
				keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: project.environments)
			}
			let store = VaultStore(keychainService: keychain, biometricService: biometric,
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil }, clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			store.isUnlocked = true
			store.projects = [project, solo]
			store.openProject(id: project.id)
			return Fixture(store: store, biometric: biometric, folder: folder)
		}

		private func workspace(_ store: VaultStore, copyFeedback: ManualCopyFeedbackTimer = ManualCopyFeedbackTimer())
			async throws -> SheetTestHost<some View>
		{
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "workspace-header-accessibility"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults))
				.environment(\.vaultCopyFeedbackTimer, copyFeedback.timer)
				.defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 800), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["header"] != nil })
			#expect(try await host.waitForText("Invalid, 1"))
			try await host.settle()
			return host
		}
	}
}
