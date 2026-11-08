import AppKit
import Testing
import SwiftUI

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Account settings presentation")
	@MainActor
	struct SettingsPagePresentationTests {
		@Test("signed out, Account & Sync offers signing in above the server, local server selection only in debug builds, and the menu the app's other settings")
		func signedOutSettingsOfferLocalServerSelection() async throws {
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil }
			)
			store.appEnvironment = .production
			let host = SheetTestHost(VaultSettingsOverlay(store: store, category: .account).environment(VaultAppearanceSettings())
				.environment(UpdateChecker()).environment(VaultQuitSettings()).environment(\.colorScheme, .light),
				size: NSSize(width: 900, height: 1000), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			let labels = try await host.text()
			#expect(labels.contains("Not logged in"))
			for category in ["General", "Appearance", "Updates"] {
				#expect(AccessibilityTree.elements(in: host.window).contains { $0.role == .button && $0.says(category) }, "\(category) is in the menu")
			}
			#expect(!labels.contains("Open Settings"))
			// The content, beside the menu, whose rows would otherwise join its lines.
			let contentStart = (VaultSettingsOverlay.inset(for: 900) + VaultSettingsOverlay.menuWidth + 2) / 900
			let lines = AccessibilityTree.lines(in: host.view, region: CGRect(x: contentStart, y: 0, width: 1 - contentStart, height: 1))
			let explanation = try #require(lines.first { $0.text.contains("Sign in to sync personal") })
			let signIn = try #require(lines.first { $0.text.contains("Sign In with Browser") })
			let server = try #require(lines.first { $0.text.caseInsensitiveCompare("Server") == .orderedSame }, "Lines: \(lines.map(\.text))")
			#expect(explanation.bounds.minY > signIn.bounds.maxY)
			#expect(signIn.bounds.minY > server.bounds.maxY)
			#if DEBUG
			#expect(labels.contains("Use Local"))
			#else
			#expect(!labels.contains("Use Local"))
			#endif
		}

		@Test("Sign out asks first, naming the account in a card, and Esc keeps it signed in")
		func signOutAsks() async throws {
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil }
			)
			store.currentUser = LPMUser(id: "u1", username: "tolga", name: nil, email: "tolga@example.com", avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
			let host = SheetTestHost(VaultSettingsOverlay(store: store, category: .account).environment(VaultAppearanceSettings())
				.environment(UpdateChecker()).environment(VaultQuitSettings()), size: NSSize(width: 900, height: 700), keepsRequestedSize: true)
			defer { host.window.close() }
			try host.scrollToEnd()
			try await host.click("Sign Out")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Signing out asks first")
			let dialog = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Sign out of LPM?", exactly: true, in: dialog))
			#expect(try await host.waitForText("@tolga", in: dialog))
			#expect(try await host.waitForText("tolga@example.com", in: dialog))
			let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dialog.windowNumber, context: nil,
				characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
			#expect(dialog.performKeyEquivalent(with: escape))
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			#expect(store.currentUser != nil)
		}
	}
}

extension SheetInteractionTests {
	@Suite("Sync conflict presentation")
	@MainActor
	struct ConflictResolutionSheetTests {
		@Test("personal conflict recovery explains which values survive before confirmation")
		func personalConflictExplainsMergePrecedence() async throws {
			let text = try await AccessibilityTree.text(of: ConflictResolutionSheet(
				projectName: "test-project", account: .personal,
				onPullAndMerge: {}, onForcePush: {}, onCancel: {}
			).frame(width: 400, height: 450).background(Color.white).environment(\.colorScheme, .light), size: CGSize(width: 400, height: 450))
			#expect(text.contains("Version Conflict"))
			#expect(text.contains("Cloud values replace conflicting local values."))
			#expect(text.contains("Force Push replaces cloud values with local values."))
		}
	}
}

@Suite("VaultProject Model")
struct VaultProjectTests {
	@Test("environment keys sort alphabetically regardless of case")
	func sortedKeys() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: ["default": ["ZEBRA": "z", "APPLE": "a", "MANGO": "m", "banana": "b"]]
		)

		#expect(VaultWorkspaceSnapshot(project: project).sortedKeys(for: "default") == ["APPLE", "banana", "MANGO", "ZEBRA"])
	}

	@Test("keys that differ only in case keep Finder's order, lowercase first")
	func sortedKeysCaseOrder() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "",
			environments: ["default": ["HEY": "upper", "hey": "lower", "Hey": "mixed"]]
		)

		#expect(VaultWorkspaceSnapshot(project: project).sortedKeys(for: "default") == ["hey", "Hey", "HEY"])
	}

	@Test("numbers in keys sort by value, as in Finder")
	func sortedKeysCompareNumbersByValue() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "",
			environments: ["default": ["DATABASE_URL_10": "c", "DATABASE_URL_2": "b", "DATABASE_URL": "a", "api_key": "k"]]
		)

		#expect(VaultWorkspaceSnapshot(project: project).sortedKeys(for: "default") == ["api_key", "DATABASE_URL", "DATABASE_URL_2", "DATABASE_URL_10"])
	}

	@Test("an empty environment has no sorted keys")
	func emptySortedKeys() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: ["default": [:]]
		)

		#expect(VaultWorkspaceSnapshot(project: project).sortedKeys(for: "default").isEmpty)
	}

	@Test("secret count across environments")
	func secretCount() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: [
				"local": ["A": "1", "B": "2"],
				"live": ["A": "x", "C": "3"],
			]
		)

		#expect(project.secretCount == 4)  // total across all envs
		#expect(project.secretCount(for: "local") == 2)
		#expect(project.secretCount(for: "live") == 2)
	}

	@Test("environment names sorted")
	func environmentNames() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: ["live": [:], "ci": [:], "local": [:]]
		)

		#expect(project.environmentNames == ["ci", "live", "local"])
	}

	@Test("identifiable: same vault ID means same identity")
	func identifiable() {
		let a = VaultProject(id: "same-id", name: "A", path: "/a", environments: ["default": ["K": "V"]])
		let b = VaultProject(id: "same-id", name: "B", path: "/b", environments: [:])

		#expect(a.id == b.id)
	}

	@Test("identifiable: different vault ID means different identity")
	func differentIdentity() {
		let a = VaultProject(id: "id-1", name: "Same", path: "/a", environments: [:])
		let b = VaultProject(id: "id-2", name: "Same", path: "/a", environments: [:])

		#expect(a.id != b.id)
	}

	@Test("workspace key union is stable across dynamic environments")
	func workspaceKeyUnion() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["ZEBRA": "1", "ALPHA": "2"],
				"staging": ["MIDDLE": "3", "ALPHA": "4"],
			]
		)

		#expect(project.allSecretKeys == ["ALPHA", "MIDDLE", "ZEBRA"])
	}

	@Test("workspace derives drift only from differing stored values")
	func workspaceDrift() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["SAME": "value", "DIFF": "one", "LOCAL_ONLY": "local"],
				"staging": ["SAME": "value", "DIFF": "two"],
			]
		)

		#expect(!project.hasDrift(for: "SAME"))
		#expect(project.hasDrift(for: "DIFF"))
		#expect(!project.hasDrift(for: "LOCAL_ONLY"))
	}

	@Test("workspace derives missing keys across arbitrary environments")
	func workspaceMissing() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["EVERYWHERE": "one", "MISSING": "one"],
				"ci": ["EVERYWHERE": "two"],
				"production": ["EVERYWHERE": "three", "MISSING": "three"],
			]
		)

		#expect(!project.isMissingSomewhere("EVERYWHERE"))
		#expect(project.isMissingSomewhere("MISSING"))
		#expect(project.environmentCount(for: "MISSING") == 2)
	}

	@Test("workspace snapshot aggregates key status once")
	func workspaceSnapshot() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["SAME": "one", "DIFF": "one", "MISSING": "one"],
				"staging": ["SAME": "one", "DIFF": "two"],
			]
		)
		let snapshot = VaultWorkspaceSnapshot(project: project)

		#expect(snapshot.allSecretKeys == ["DIFF", "MISSING", "SAME"])
		#expect(snapshot.driftingKeyCount == 1)
		#expect(snapshot.missingKeyCount == 1)
		#expect(snapshot.environmentCount(for: "MISSING") == 1)
	}
}
