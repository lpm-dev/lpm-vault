import AppKit
import Foundation
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Test("native buttons invoke their action without entering mouse tracking", arguments: [false, true])
	@MainActor
	func nativeClickAvoidsTracking(flipped: Bool) async throws {
		let action = NativeClickProbeAction()
		let button = NativeClickProbeButton(title: "Tracking probe", target: action, action: #selector(NativeClickProbeAction.clicked))
		button.bezelStyle = .rounded
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.animationBehavior = .none
		defer { window.close() }
		let content = NativeClickProbeRoot(frame: NSRect(x: 0, y: 0, width: 300, height: 180), flipped: flipped)
		window.contentView = content
		button.frame = NSRect(x: 20, y: 20, width: 160, height: 32)
		content.addSubview(button)
		let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
		try NativeTestClick.send(to: window, at: point)
		#expect(action.clickCount == 1)
		#expect(button.mouseDownCount == 0)
		button.isEnabled = false
		try NativeTestClick.send(to: window, at: point)
		#expect(action.clickCount == 1)
		#expect(button.mouseDownCount == 0)
		button.isEnabled = true
		button.setButtonType(.switch)
		button.state = .off
		try NativeTestClick.send(to: window, at: point)
		#expect(button.state == .on)
		#expect(action.clickCount == 2)
		try NativeTestClick.send(to: window, at: point)
		#expect(button.state == .off)
		#expect(action.clickCount == 3)
		#expect(button.mouseDownCount == 0)
	}
}

@MainActor
private final class NativeClickProbeRoot: NSView {
	private let usesFlippedCoordinates: Bool
	override var isFlipped: Bool { usesFlippedCoordinates }
	init(frame: NSRect, flipped: Bool) { self.usesFlippedCoordinates = flipped; super.init(frame: frame) }
	required init?(coder: NSCoder) { nil }
}

@MainActor
private final class NativeClickProbeButton: NSButton {
	var mouseDownCount = 0
	override func mouseDown(with event: NSEvent) { mouseDownCount += 1 }
}

@MainActor
private final class NativeClickProbeAction: NSObject {
	var clickCount = 0
	@objc func clicked() { clickCount += 1 }
}

extension SheetInteractionTests {
	@Suite("Env file import review", .serialized) @MainActor struct EnvFileImportReviewTests {
		private func fixture(
			existing: [String: String] = ["TOKEN": "existing", "SAME": "same"],
			incoming: [String: String] = ["TOKEN": "incoming", "SAME": "same", "NEW": "added"],
			biometric: MockBiometricService = MockBiometricService()
		) async -> (VaultStore, MockKeychainService) {
			let importer = MockEnvFileImportService()
			await importer.setImmediateResult(.success(ImportedEnvFile(secrets: incoming)))
			let keychain = MockKeychainService()
			keychain.envStorage["project"] = (
				name: "Dummy Project", path: "", environments: ["default": existing, "staging": [:]]
			)
			let store = VaultStore(
				keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
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
			let file = URL(fileURLWithPath: "/tmp/dummy.env")
			let imported = try await store.loadEnvImport(.file(file), for: "project").get()
			return try await store.prepareEnvImport(imported, from: .file(file), to: "project", environment: "default").get()
		}

		/// The review of the fixture's file as `environment`, a new environment, as New file makes it.
		private func newFileReview(
			_ store: VaultStore, named environment: String = "preview"
		) async throws -> Result<EnvFileImportReview, EnvFileImportError> {
			let file = URL(fileURLWithPath: "/tmp/dummy.env")
			let imported = try await store.loadEnvImport(.file(file), for: "project").get()
			return await store.prepareEnvImport(imported, from: .file(file), to: "project", environment: environment, creating: true)
		}

		@Test("review classifies each key without writing secrets") func reviewClassifiesChanges() async throws {
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let preview = try await review(store)
			#expect(preview.rows.map(\.key) == ["NEW", "SAME", "TOKEN"])
			#expect(preview.rows.map(\.change) == [.added, .unchanged, .changed])
			#expect(preview.added.map(\.key) == ["NEW"] && preview.changed.map(\.key) == ["TOKEN"] && preview.unchanged.map(\.key) == ["SAME"])
			#expect(preview.outcome().summary == "1 added · 0 replaced · 1 kept · 1 skipped")
			#expect(preview.outcome(replacing: ["TOKEN"], skipping: ["NEW"]) == .init(added: 0, replaced: 1, kept: 0, skipped: 2))
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

		@Test("only explicitly selected differing keys replace existing values, and new keys left out stay out")
		func reviewAppliesSelectedReplacements() async throws {
			let (store, keychain) = await fixture(
				existing: ["TOKEN": "old", "KEEP": "old", "SAME": "same"],
				incoming: ["TOKEN": "new", "KEEP": "new", "SAME": "same", "NEW": "added", "LEFT_OUT": "x"])
			defer { store.lock() }
			let preview = try await review(store)
			let receipt = try await store.applyEnvFileImport(preview, replacingKeys: ["TOKEN"], skippingKeys: ["LEFT_OUT"]).get()
			let imported = ["TOKEN": "new", "KEEP": "old", "SAME": "same", "NEW": "added"]
			#expect(keychain.envStorage["project"]?.environments["default"] == imported)
			#expect(receipt == EnvImportReceipt(projectId: "project", environment: "default",
				before: ["TOKEN": "old", "KEEP": "old", "SAME": "same"], after: imported))
			#expect(preview.outcome(replacing: ["TOKEN"], skipping: ["LEFT_OUT"]).summary == "1 added · 1 replaced · 1 kept · 2 skipped")
			#expect(keychain.storedSyncMetadata(vaultId: "project")?.isDirty == true)
			let next = try await review(store)
			#expect(await store.applyEnvFileImport(next, replacingKeys: [], skippingKeys: ["TOKEN"]) == .failure(.cancelled),
				"Only new keys can be left out")
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
			let receipt = try await store.applyEnvFileImport(preview, replacingKeys: []).get()
			#expect(!receipt.changed)
			#expect(keychain.updateEnvironmentsCallCount == 0)
			#expect(keychain.storedSyncMetadata(vaultId: "project") == nil)
		}

		@Test("undo puts the environment back as it was, unless something changed it since")
		func undoRestores() async throws {
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let receipt = try await store.applyEnvFileImport(try await review(store), replacingKeys: ["TOKEN"]).get()
			#expect(keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "incoming", "SAME": "same", "NEW": "added"])
			#expect(await store.undoEnvImport(receipt) == .saved)
			#expect(keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "existing", "SAME": "same"])
			#expect(store.projects[0].environments["default"] == ["TOKEN": "existing", "SAME": "same"])
			#expect(keychain.envStorage["project"]?.environments["staging"] == [:], "Other environments are left alone")

			let again = try await store.applyEnvFileImport(try await review(store), replacingKeys: []).get()
			keychain.envStorage["project"]?.environments["default"]?["FROM_CLI"] = "1"
			#expect(await store.undoEnvImport(again) == .changed)
			#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "added", "An environment changed since isn't undone")
			let nothing = EnvImportReceipt(projectId: "project", environment: "default", before: [:], after: [:])
			#expect(await store.undoEnvImport(nothing) == .unavailable, "An import that changed nothing has nothing to undo")
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

		@Test("a new file's review has every key as new, and creates the environment with the keys left on")
		func newFileCreatesEnvironment() async throws {
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let preview = try await newFileReview(store).get()
			#expect(preview.createsEnvironment && preview.baseline.isEmpty)
			#expect(preview.rows.map(\.key) == ["NEW", "SAME", "TOKEN"] && preview.rows.allSatisfy { $0.change == .added })
			#expect(preview.outcome(skipping: ["TOKEN"]) == .init(added: 2, replaced: 0, kept: 0, skipped: 1))
			#expect(store.isCurrentEnvFileImportReview(preview), "A new environment needn't be the one shown")
			#expect(await store.applyEnvFileImport(preview, replacingKeys: []) == .failure(.cancelled), "Nothing is imported into a new environment")
			let unknownKey = await store.createEnvironment(from: preview, skippingKeys: ["OTHER"])
			#expect(throws: EnvFileImportError.cancelled, "Only the review's keys can be left out") { try unknownKey.get() }
			#expect(keychain.updateEnvironmentsCallCount == 0)

			try await store.createEnvironment(from: preview, skippingKeys: ["TOKEN"]).get()
			#expect(keychain.envStorage["project"]?.environments["preview"] == ["NEW": "added", "SAME": "same"])
			#expect(keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "existing", "SAME": "same"])
			#expect(store.projects[0].environments["preview"] == ["NEW": "added", "SAME": "same"])
			#expect(store.selectedEnvironment == "preview")
			#expect(keychain.storedSyncMetadata(vaultId: "project")?.isDirty == true)
			#expect(!store.isCurrentEnvFileImportReview(preview), "The review ends with the environment it made")
			let again = await store.createEnvironment(from: preview)
			#expect(throws: EnvFileImportError.cancelled) { try again.get() }
			store.selectedEnvironment = "default"
			let existing = await store.createEnvironment(from: try await review(store))
			#expect(throws: EnvFileImportError.cancelled, "An environment that exists isn't made again") { try existing.get() }
		}

		@Test("a new file's name taken first, as by the LPM CLI, stops its review and its creation")
		func newFileNameTaken() async throws {
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let shown = try await newFileReview(store, named: "staging")
			#expect(throws: EnvFileImportError.environmentExists("staging")) { try shown.get() }
			keychain.envStorage["project"]?.environments["cli"] = ["FROM_CLI": "1"]
			let unseen = try await newFileReview(store, named: "cli")
			#expect(throws: EnvFileImportError.environmentExists("cli"), "The vault's own environments count, not only those shown") { try unseen.get() }

			let preview = try await newFileReview(store).get()
			keychain.envStorage["project"]?.environments["preview"] = ["FROM_CLI": "1"]
			let created = await store.createEnvironment(from: preview)
			#expect(throws: EnvFileImportError.environmentExists("preview")) { try created.get() }
			#expect(keychain.envStorage["project"]?.environments["preview"] == ["FROM_CLI": "1"], "What the CLI made stays")
			#expect(store.projects[0].environments["preview"] == nil)
			#expect(!store.isCurrentEnvFileImportReview(preview))
			#expect(EnvFileImportError.environmentExists("preview").description(for: .pastedText)
				== ".env.preview was created meanwhile, as by the LPM CLI. Choose another name for this one.")

			let late = try await newFileReview(store, named: "late").get()
			store.projects = [VaultProject(id: "project", name: "Dummy Project", path: "",
				environments: store.projects[0].environments.merging(["late": ["FROM_CLI": "1"]]) { $1 })]
			#expect(!store.isCurrentEnvFileImportReview(late), "A name the window shows as taken ends the review")
			let shownLate = await store.createEnvironment(from: late)
			#expect(throws: EnvFileImportError.environmentExists("late")) { try shownLate.get() }
			#expect(keychain.envStorage["project"]?.environments["late"] == nil)
		}

		@Test(
			"a new file's review outlives a change of the environment shown, but not a lock, another project or a newer review",
			arguments: ["environment", "project", "lock", "newer"])
		func newFileReviewContext(transition: String) async throws {
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let preview = try await newFileReview(store).get()
			switch transition {
			case "environment": store.selectedEnvironment = "staging"
			case "project":
				store.selectedProjectId = nil
				store.openProject(id: "project")
			case "lock": store.lock()
			default: _ = try await newFileReview(store).get()
			}
			let result = await store.createEnvironment(from: preview)
			if transition == "environment" {
				try result.get()
				#expect(keychain.envStorage["project"]?.environments["preview"] == ["TOKEN": "incoming", "SAME": "same", "NEW": "added"])
			} else {
				#expect(throws: transition == "lock" ? EnvFileImportError.vaultLocked : .cancelled) { try result.get() }
				#expect(keychain.envStorage["project"]?.environments["preview"] == nil)
			}
		}

		@Test("a new file's review lists only new keys, any of which can be left out, and Create makes the environment with the rest")
		func newFileReviewSheet() async throws {
			let (store, keychain) = await fixture(incoming: ["ALPHA": "AlphaIncoming", "BETA": "2", "GAMMA": "3"])
			defer { store.lock() }
			let host = try await sheet(store, try await newFileReview(store).get())
			defer { host.window.close() }
			for text in ["Review new file", "/tmp/dummy.env", "Dummy Project", ".env.preview", "NEW · 3", "will be added",
				"+3 added · 0 skipped", "Values stay hidden and are encrypted on import.", "Create .env.preview"]
			{
				#expect(try await host.waitForText(text), "The review says \(text)")
			}
			let text = try await host.text()
			#expect(!text.contains("All · 3") && !text.contains("Changed") && !text.contains("Undo"), "A new file has nothing to compare or undo")
			try await host.click("Reveal values")
			#expect(try await host.waitForText("File value for ALPHA revealed visually"))
			for key in ["ALPHA", "BETA", "GAMMA"] { try await host.click("Add \(key)") }
			#expect(try await host.waitForText("+0 added · 3 skipped"))
			#expect(try await host.waitUntil { element("Nothing to import, ⏎", in: host)?.isEnabled == false })
			try await host.click("Add BETA")
			#expect(try await host.waitForText("+1 added · 2 skipped"))
			try record(host, named: "new-file-review")
			try await host.click("Add ALPHA")
			#expect(try await host.waitForText("Create .env.preview"))
			try submitImport(in: host)
			#expect(try await host.waitUntil { keychain.envStorage["project"]?.environments["preview"] != nil })
			#expect(keychain.envStorage["project"]?.environments["preview"] == ["ALPHA": "AlphaIncoming", "BETA": "2"])
			#expect(store.selectedEnvironment == "preview")
		}

		@Test("a new file whose name is taken meanwhile says so, and Review again checks the name again")
		func newFileReviewNameTaken() async throws {
			let (store, keychain) = await fixture(incoming: ["NEW": "added"])
			defer { store.lock() }
			let host = try await sheet(store, try await newFileReview(store).get())
			defer { host.window.close() }
			#expect(try await host.waitForText("Create .env.preview"))
			keychain.envStorage["project"]?.environments["preview"] = ["FROM_CLI": "1"]
			try submitImport(in: host)
			#expect(try await host.waitForText(".env.preview was created meanwhile, as by the LPM CLI. Choose another name for this one."))
			#expect(try await host.waitUntil { element("Reveal values", in: host)?.isEnabled == false })
			keychain.envStorage["project"]?.environments["preview"] = nil
			try await host.click("Review again")
			#expect(try await host.waitForText("Create .env.preview"), "The name is free again")
			try submitImport(in: host)
			#expect(try await host.waitUntil { keychain.envStorage["project"]?.environments["preview"] == ["NEW": "added"] })
		}

		@Test("the review groups new, changed and unchanged keys, which the filters show one at a time")
		func groupsAndFilters() async throws {
			let (store, _) = await fixture()
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			for text in ["Review import", "/tmp/dummy.env", "Dummy Project", "All · 3", "New · 1", "Changed · 1", "Unchanged · 1",
				"NEW · 1", "will be added", "CHANGED · 1", "existing value kept unless you choose Replace", "UNCHANGED · 1",
				"identical, skipped", "Values stay hidden and are encrypted on import. Undo available for 30s."]
			{
				#expect(try await host.waitForText(text), "The review says \(text)")
			}
			#expect(try await host.waitForText("+1 added · 0 replaced · 1 kept · 1 skipped"))
			#expect(try await host.waitForText("Import 1 change"))
			func sections() -> [String] {
				AccessibilityTree.visibleElements(in: host.window, of: host.view).flatMap(\.texts)
					.filter { ["NEW · 1", "CHANGED · 1", "UNCHANGED · 1"].contains($0) }
			}
			#expect(sections() == ["NEW · 1", "CHANGED · 1", "UNCHANGED · 1"])
			try await host.click("Changed · 1")
			#expect(try await host.waitUntil { sections() == ["CHANGED · 1"] }, "\(sections())")
			#expect(element("Changed · 1", in: host)?.isSelected == true)
			try await host.click("All · 3")
			#expect(try await host.waitUntil { sections().count == 3 })
		}

		@Test("a new key can be left out, and Replace all takes every differing value, until Keep all")
		func decisions() async throws {
			let (store, keychain) = await fixture(
				existing: ["TOKEN": "old", "OTHER": "old"], incoming: ["TOKEN": "new", "OTHER": "new", "NEW": "added", "SECOND": "added"])
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("Import 2 changes"))
			try await host.click("Add SECOND")
			#expect(try await host.waitForText("Import 1 change"))
			#expect(try await host.waitForText("+1 added · 0 replaced · 2 kept · 1 skipped"))
			try await host.click("Replace all")
			#expect(try await host.waitForText("Import 3 changes"))
			#expect(try await host.waitForText("Keep all"))
			try await host.click("Keep TOKEN")
			#expect(try await host.waitForText("Import 2 changes"))
			#expect(try await host.waitForText("Replace all"))
			try submitImport(in: host)
			#expect(try await host.waitForText("Import complete"))
			#expect(keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "old", "OTHER": "new", "NEW": "added"])
			#expect(try await host.waitForText("1 added · 1 replaced · 1 kept · 1 skipped"))
		}

		@Test("a review with nothing to change can't import")
		func nothingToImport() async throws {
			let (store, keychain) = await fixture(existing: ["SAME": "same"], incoming: ["SAME": "same"])
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("Nothing to import"))
			#expect(element("Nothing to import, ⏎", in: host)?.isEnabled == false)
			try await host.settle()
			#expect(try await !host.text().contains("Import complete"))
			#expect(keychain.updateEnvironmentsCallCount == 0)
		}

		@Test("the review Import button keeps existing values by default") func reviewButtonKeepsExistingValues()
			async throws
		{
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			try submitImport(in: host)
			#expect(try await host.waitForText("Import complete"))
			#expect(keychain.envStorage["project"]?.environments["default"]?["TOKEN"] == "existing")
			#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "added")
		}

		@Test("Undo import puts the environment back, once")
		func undoInSheet() async throws {
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let host = try await sheet(store, undoWindow: ManualFeedbackTimer())
			defer { host.window.close() }
			try submitImport(in: host)
			#expect(try await host.waitForText("Import complete"))
			#expect(try await host.waitForText("Puts .env back as it was. Available for 30 seconds."))
			try await host.click("Undo import")
			#expect(try await host.waitForText("Import undone"))
			#expect(try await host.waitForText(".env is back as it was before the import"))
			#expect(keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "existing", "SAME": "same"])
			#expect(try await !host.text().contains("Undo import"))
		}

		@Test("Undo import goes when its 30 seconds end, and says so when the environment changed since")
		func undoWindowAndConflict() async throws {
			let (store, keychain) = await fixture()
			defer { store.lock() }
			let window = ManualFeedbackTimer()
			let host = try await sheet(store, undoWindow: window)
			defer { host.window.close() }
			try submitImport(in: host)
			#expect(try await host.waitForText("Undo import"))
			#expect(try await host.waitUntil { window.started == 1 })
			window.expire()
			#expect(try await host.waitForTextToDisappear("Undo import"))
			#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "added")

			let (other, otherKeychain) = await fixture()
			defer { other.lock() }
			let second = try await sheet(other, undoWindow: ManualFeedbackTimer())
			defer { second.window.close() }
			try submitImport(in: second)
			#expect(try await second.waitForText("Undo import"))
			otherKeychain.envStorage["project"]?.environments["default"]?["FROM_CLI"] = "1"
			try await second.click("Undo import")
			#expect(try await second.waitForText(".env changed after the import, so it can't be undone."))
			#expect(otherKeychain.envStorage["project"]?.environments["default"]?["NEW"] == "added")
		}

		@Test("revealing values compares both of a changed key without approving replacement")
		func revealComparesWithoutApproving() async throws {
			let biometric = MockBiometricService()
			let (store, keychain) = await fixture(existing: ["TOKEN": "ExistingValue"], incoming: ["TOKEN": "IncomingValue"], biometric: biometric)
			defer { store.lock() }
			let preview = try await review(store)
			let host = try await sheet(store, preview)
			defer { host.window.close() }
			try #require(store.isCurrentEnvFileImportReview(preview))
			#expect(biometric.authenticateCallCount == 0)
			try await host.click("Reveal values")
			try #require(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			#expect(try await host.waitForText("Vault value for TOKEN revealed visually"))
			let text = try await host.text()
			#expect(text.contains("File value for TOKEN revealed visually"))
			#expect(text.contains("0 replaced"))
			#expect(biometric.authenticateCallCount == 1)
			try await host.click("Hide values")
			#expect(try await host.waitForText("Vault value for TOKEN hidden"))
			#expect(try await host.text().contains("File value for TOKEN hidden"))
			try await host.click("Replace TOKEN")
			try await host.click("Reveal values")
			#expect(try await host.waitForText("File value for TOKEN revealed visually"))
			try submitImport(in: host)
			#expect(try await host.waitForText("Import complete"))
			#expect(try await !host.text().contains("revealed visually"))
			try record(host, named: "import-review-complete")
			#expect(keychain.envStorage["project"]?.environments["default"]?["TOKEN"] == "IncomingValue")
		}

		@Test("pasted values are called pasted, and a new key has only its incoming value")
		func revealNewValue() async throws {
			let (store, _) = await fixture(existing: [:], incoming: ["NEW": "NewValue"])
			defer { store.lock() }
			let imported = try await store.loadEnvImport(.text("NEW=NewValue"), for: "project").get()
			let preview = try await store.prepareEnvImport(imported, from: .pastedText, to: "project", environment: "default").get()
			let host = try await sheet(store, preview)
			defer { host.window.close() }
			#expect(try await host.waitForText("Pasted text"))
			try await host.click("Reveal values")
			#expect(try await host.waitForText("Pasted value for NEW revealed visually"))
			#expect(try await !host.text().contains("Vault value"), "A new key has no value in the vault to compare")
		}

		@Test("unsuccessful authentication keeps values hidden")
		func unsuccessfulRevealIsMasked() async throws {
			let biometric = MockBiometricService()
			biometric.shouldSucceed = false
			let (store, _) = await fixture(existing: ["TOKEN": "ExistingValue"], incoming: ["TOKEN": "IncomingValue"], biometric: biometric)
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			try await host.click("Reveal values")
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			try await host.settle()
			let text = try await host.text()
			#expect(!text.contains("revealed visually"))
			#expect(!text.contains("Authentication failed"))
		}

		@Test("late authentication cannot reveal values after context changes", arguments: ["environment", "project", "lock", "newer", "dismiss", "privacy", "apply"])
		func staleRevealStaysMasked(transition: String) async throws {
			let biometric = MockBiometricService()
			let gate = AsyncStream<Void>.makeStream()
			biometric.authenticateHandlers = [{
				for await _ in gate.stream { return true }
				return false
			}]
			let (store, _) = await fixture(existing: ["TOKEN": "ExistingValue"], incoming: ["TOKEN": "IncomingValue", "NEW": "added"], biometric: biometric)
			defer { gate.continuation.finish(); store.lock() }
			let preview = try await review(store)
			let presentation = ImportReviewPresentation()
			let host = SheetTestHost(ImportReviewTestView(store: store, review: preview, presentation: presentation), size: reviewSize, keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try await host.click("Reveal values")
			#expect(try await host.waitUntil { biometric.authenticateCallCount == 1 })
			switch transition {
			case "environment": store.selectedEnvironment = "staging"
			case "project": store.selectedProjectId = nil
			case "lock": store.lock()
			case "newer": _ = try await review(store)
			case "dismiss": presentation.isPresented = false
			case "privacy": presentation.isObscured = true
			default: try submitImport(in: host)
			}
			try await host.settle()
			gate.continuation.yield(())
			try await host.settle()
			if transition == "privacy" { presentation.isObscured = false }
			if transition == "dismiss" { presentation.isPresented = true }
			try await host.settle()
			#expect(try await !host.text().contains("revealed visually"))
		}

		@Test("visible values hide after privacy or dismissal", arguments: ["privacy", "dismiss"])
		func visibleComparisonResets(transition: String) async throws {
			let (store, _) = await fixture(existing: [:], incoming: ["NEW": "IncomingValue"])
			defer { store.lock() }
			let presentation = ImportReviewPresentation()
			let host = SheetTestHost(ImportReviewTestView(store: store, review: try await review(store), presentation: presentation), size: reviewSize, keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try await host.click("Reveal values")
			#expect(try await host.waitForText("File value for NEW revealed visually"))
			if transition == "privacy" { presentation.isObscured = true } else { presentation.isPresented = false }
			try await host.settle()
			presentation.isObscured = false
			presentation.isPresented = true
			#expect(try await host.waitForText("File value for NEW hidden"))
		}

		@Test("one authentication reveals every value, and Hide values hides them all")
		func revealAll() async throws {
			let biometric = MockBiometricService()
			let (store, _) = await fixture(existing: ["TOKEN": "old"], incoming: ["ALPHA": "AlphaIncoming", "BETA": "BetaIncoming", "TOKEN": "new"], biometric: biometric)
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			try await host.click("Reveal values")
			#expect(try await host.waitForText("File value for ALPHA revealed visually"))
			let text = try await host.text()
			for label in ["File value for BETA revealed visually", "Vault value for TOKEN revealed visually", "File value for TOKEN revealed visually"] {
				#expect(text.contains(label))
			}
			#expect(biometric.authenticateCallCount == 1)
			try await host.click("Hide values")
			#expect(try await host.waitForText("File value for ALPHA hidden"))
			#expect(try await !host.text().contains("revealed visually"))
		}

		@Test("review again clears revealed values and every decision")
		func freshReviewMasksValues() async throws {
			let (store, keychain) = await fixture(existing: ["TOKEN": "ExistingValue"], incoming: ["TOKEN": "IncomingValue", "NEW": "added"])
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			try await host.click("Reveal values")
			#expect(try await host.waitForText("File value for TOKEN revealed visually"))
			try await host.click("Replace TOKEN")
			try await host.click("Add NEW")
			#expect(try await host.waitForText("+0 added · 1 replaced · 0 kept · 1 skipped"))
			try record(host, named: "import-review-replacing")
			keychain.envStorage["project"]?.environments["default"]?["TOKEN"] = "NewerValue"
			try submitImport(in: host)
			#expect(try await host.waitForText("Review again"))
			try record(host, named: "import-review-changed")
			#expect(try await host.waitUntil { element("Reveal values", in: host)?.isEnabled == false }, "A review that's out of date reveals nothing")
			try await host.click("Review again")
			#expect(try await host.waitForText("+1 added · 0 replaced · 1 kept · 0 skipped"))
			#expect(try await !host.text().contains("revealed visually"))
			try await host.click("Reveal values")
			#expect(try await host.waitForText("Vault value for TOKEN revealed visually"))
		}

		@Test("review displays the target and choices while secret values remain hidden") func reviewMasksValues()
			async throws
		{
			let (store, _) = await fixture(
				existing: ["TOKEN": "ExistingSecretMustStayHidden"],
				incoming: ["TOKEN": "IncomingSecretMustStayHidden", "NEW": "NewSecretMustStayHidden"])
			defer { store.lock() }
			let host = try await sheet(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("TOKEN"))
			#expect(try await host.waitForText("NEW"))
			let text = try await host.text()
			#expect(text.contains("Dummy Project"))
			#expect(text.contains("Replace") && text.contains("Keep") && text.contains("Add"))
			#expect(text.contains("Reveal values"))
			#expect(!text.contains("SecretMustStayHidden"))
			Attachment.record(
				try #require(NSBitmapImageRep(cgImage: host.snapshot(host.view)).representation(using: .png, properties: [:])), named: "masked-import-review")
		}

		private var reviewSize: NSSize { NSSize(width: 640, height: 560) }

		/// The review of the fixture's file, in a window of its own.
		private func sheet(
			_ store: VaultStore, _ preview: EnvFileImportReview? = nil, undoWindow: ManualFeedbackTimer? = nil
		) async throws -> SheetTestHost<some View> {
			let shown = if let preview { preview } else { try await review(store) }
			let host = SheetTestHost(
				EnvFileImportReviewSheet(store: store, review: shown)
					.environment(\.colorScheme, .light)
					.environment(\.vaultImportUndoTimer, undoWindow?.timer ?? .importUndo),
				size: reviewSize, keepsRequestedSize: true, usesHostingView: true)
			try await host.settle()
			return host
		}
	}
}

/// The first control saying exactly `label`, as VoiceOver finds it.
@MainActor
private func element<V: View>(_ label: String, in host: SheetTestHost<V>) -> AccessibilityTree.Element? {
	host.view.layoutSubtreeIfNeeded()
	return AccessibilityTree.visibleElements(in: host.window, of: host.view).first { $0.isInteractive && $0.says(label) }
}

@MainActor
private func record<V: View>(_ host: SheetTestHost<V>, named name: String) throws {
	let view = host.view
	let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
	view.cacheDisplay(in: view.bounds, to: bitmap)
	Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: name + ".png")
}

@Observable @MainActor
private final class ImportReviewPresentation {
	var isObscured = false
	var isPresented = true
}

private struct ImportReviewTestView: View {
	let store: VaultStore
	let review: EnvFileImportReview
	var presentation: ImportReviewPresentation
	var body: some View {
		if presentation.isPresented {
			EnvFileImportReviewSheet(store: store, review: review)
				.environment(\.vaultContentObscured, presentation.isObscured)
				.environment(\.colorScheme, .light)
		} else { Text("Closed") }
	}
}

@MainActor
private func submitImport<V: View>(in host: SheetTestHost<V>) throws {
	host.window.makeFirstResponder(nil)
	let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
	#expect(host.window.performKeyEquivalent(with: event))
}
