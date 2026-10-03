import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import LPMVault

@Suite("Env file import review", .serialized) @MainActor struct EnvFileImportReviewTests {
	private func fixture(
		existing: [String: String] = ["TOKEN": "existing", "SAME": "same"],
		incoming: [String: String] = ["TOKEN": "incoming", "SAME": "same", "NEW": "added"]
	) async -> (VaultStore, MockKeychainService) {
		let importer = MockEnvFileImportService()
		await importer.setImmediateResult(.success(ImportedEnvFile(secrets: incoming)))
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Dummy Project", path: "", environments: ["default": existing, "staging": [:]]
		)
		let store = VaultStore(
			keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			envFileImportService: importer)
		store.projects = [
			VaultProject(
				id: "project", name: "Dummy Project", path: "",
				environments: ["default": existing, "staging": [:]])
		]
		store.isUnlocked = true
		store.openProject(id: "project")
		return (store, keychain)
	}

	private func review(_ store: VaultStore) async throws -> EnvFileImportReview {
		try await store.prepareEnvFileImport(
			at: URL(fileURLWithPath: "/tmp/dummy.env"), to: "project", environment: "default"
		).get()
	}

	@Test("review classifies each key without writing secrets") func reviewClassifiesChanges() async throws {
		let (store, keychain) = await fixture()
		defer { store.lock() }
		let preview = try await review(store)
		#expect(preview.rows.map(\.key) == ["NEW", "SAME", "TOKEN"])
		#expect(preview.rows.map(\.change) == [.added, .unchanged, .changed])
		#expect(preview.summary(replacing: []) == "1 added · 0 replaced · 1 kept · 1 unchanged")
		#expect(keychain.updateEnvironmentsCallCount == 0)
	}

	@Test("review reads the durable baseline instead of cached app values") func reviewUsesDurableValues()
		async throws
	{
		let (store, keychain) = await fixture()
		defer { store.lock() }
		keychain.envStorage["project"]?.environments["default"]?["TOKEN"] = "from-cli"
		let preview = try await review(store)
		#expect(preview.baseline["TOKEN"] == "from-cli")
		#expect(store.projects[0].environments["default"]?["TOKEN"] == "existing")
	}

	@Test("only explicitly selected differing keys replace existing values")
	func reviewAppliesSelectedReplacements() async throws {
		let (store, keychain) = await fixture(
			existing: ["TOKEN": "old", "KEEP": "old", "SAME": "same"],
			incoming: ["TOKEN": "new", "KEEP": "new", "SAME": "same", "NEW": "added"])
		defer { store.lock() }
		let preview = try await review(store)
		_ = try await store.applyEnvFileImport(preview, replacingKeys: ["TOKEN"]).get()
		#expect(
			keychain.envStorage["project"]?.environments["default"] == [
				"TOKEN": "new", "KEEP": "old", "SAME": "same", "NEW": "added",
			])
		#expect(preview.summary(replacing: ["TOKEN"]) == "1 added · 1 replaced · 1 kept · 1 unchanged")
		#expect(keychain.storedSyncMetadata(vaultId: "project")?.isDirty == true)
	}

	@Test("a CLI change after review prevents the entire import") func reviewRejectsConcurrentCLIChange()
		async throws
	{
		let (store, keychain) = await fixture()
		defer { store.lock() }
		let preview = try await review(store)
		keychain.envStorage["project"]?.environments["default"]?["TOKEN"] = "from-cli"
		let result = await store.applyEnvFileImport(preview, replacingKeys: ["TOKEN"])
		#expect(result == .failure(.reviewChanged))
		#expect(
			keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "from-cli", "SAME": "same"])
		#expect(keychain.updateEnvironmentsCallCount == 0)
		let updated = try await review(store)
		_ = try await store.applyEnvFileImport(updated, replacingKeys: []).get()
		#expect(keychain.envStorage["project"]?.environments["default"]?["TOKEN"] == "from-cli")
		#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "added")
	}

	@Test("an import that keeps every existing value does not write or mark dirty")
	func unchangedImportIsReadOnly() async throws {
		let (store, keychain) = await fixture(existing: ["TOKEN": "old"], incoming: ["TOKEN": "new"])
		defer { store.lock() }
		let preview = try await review(store)
		_ = try await store.applyEnvFileImport(preview, replacingKeys: []).get()
		#expect(keychain.updateEnvironmentsCallCount == 0)
		#expect(keychain.storedSyncMetadata(vaultId: "project") == nil)
	}

	@Test(
		"navigation, lock, and newer reviews invalidate prior approval",
		arguments: ["environment", "project", "lock", "newer"]) func reviewCannotOutliveContext(
			transition: String
		) async throws
	{
		let (store, keychain) = await fixture()
		defer { store.lock() }
		let preview = try await review(store)
		switch transition {
		case "environment":
			store.selectedEnvironment = "staging"
			store.selectedEnvironment = "default"
		case "project":
			store.selectedProjectId = nil
			store.openProject(id: "project")
		case "lock": store.lock()
		default: _ = try await review(store)
		}
		let result = await store.applyEnvFileImport(preview, replacingKeys: ["TOKEN"])
		#expect(result == .failure(transition == "lock" ? .vaultLocked : .cancelled))
		#expect(keychain.updateEnvironmentsCallCount == 0)
	}

	@Test("the review Import button keeps existing values by default") func reviewButtonKeepsExistingValues()
		async throws
	{
		let (store, keychain) = await fixture()
		defer { store.lock() }
		let preview = try await review(store)
		let host = SheetTestHost(
			EnvFileImportReviewSheet(store: store, review: preview).environment(\.colorScheme, .light),
			size: NSSize(width: 600, height: 510), keepsRequestedSize: true)
		defer { host.window.close() }
		try await host.settle()
		let event = try #require(
			NSEvent.keyEvent(
				with: .keyDown, location: .zero, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
				context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
				keyCode: 36))
		#expect(host.window.performKeyEquivalent(with: event))
		#expect(try await host.waitForText("Import Complete"))
		#expect(keychain.envStorage["project"]?.environments["default"]?["TOKEN"] == "existing")
		#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "added")
	}

	@Test("review displays the target and choices while secret values remain hidden") func reviewMasksValues()
		async throws
	{
		let (store, _) = await fixture(
			existing: ["TOKEN": "ExistingSecretMustStayHidden"],
			incoming: ["TOKEN": "IncomingSecretMustStayHidden", "NEW": "NewSecretMustStayHidden"])
		defer { store.lock() }
		let preview = try await review(store)
		let host = SheetTestHost(
			EnvFileImportReviewSheet(store: store, review: preview).environment(\.colorScheme, .light),
			size: NSSize(width: 600, height: 510), keepsRequestedSize: true)
		defer { host.window.close() }
		#expect(try await host.waitForText("TOKEN"))
		#expect(try await host.waitForText("NEW"))
		let view = host.view
		let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
		view.cacheDisplay(in: view.bounds, to: bitmap)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = false
		try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
		let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
			separator: "\n")
		#expect(text.contains("Dummy Project"))
		#expect(text.contains("Different value"))
		#expect(text.contains("Replace"))
		#expect(!text.contains("SecretMustStayHidden"))
		Attachment.record(
			try #require(bitmap.representation(using: .png, properties: [:])), named: "masked-import-review")
	}
}
