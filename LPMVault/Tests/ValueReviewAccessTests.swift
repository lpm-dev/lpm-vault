import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Value review access", .serialized)
	@MainActor
	struct ValueReviewAccessTests {
		@MainActor private struct Fixture {
			let store: VaultStore
			let project: VaultProject
			let biometric: MockBiometricService
			let clock: LockedTime
			let timer: ValueReviewTimer
			let folder: URL
			let defaults: UserDefaults
			let domain: String

			func tearDown() async {
				store.lock()
				await timer.finish()
				store.clipboard.pasteboard.releaseGlobally()
				defaults.removePersistentDomain(forName: domain)
				try? FileManager.default.removeItem(at: folder)
			}
		}

		private func fixture(history: Bool = false, approval: VaultValueApproval = .afterFiveMinutes) async throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appendingPathComponent("value-review-tests-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let domain = "value-review-tests-\(UUID().uuidString)"
			var keepResources = false
			defer {
				if !keepResources {
					UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
					try? FileManager.default.removeItem(at: folder)
				}
			}
			let defaults = try #require(UserDefaults(suiteName: domain))
			let settings = VaultSettings(defaults: defaults)
			settings.lockAfter = .thirtyMinutes
			settings.valueApproval = approval
			settings.rehide = .thirtySeconds
			settings.clipboardClear = .thirtySeconds
			let service = KeychainService(
				testingService: "dev.lpm.vault.value-review-tests.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
			let sourceDate = Date(timeIntervalSince1970: 1_793_800_000)
			guard case .success = service.createEnvironments(
				vaultId: "value-review-tests", projectName: "Demo review", projectPath: "",
				environments: ["default": ["TOKEN": "DEMO-HISTORY-OLD"]],
				source: VaultHistorySource(.set, at: sourceDate))
			else { throw KeychainError.encodingFailed }
			if history {
				guard case .success = service.applyVaultTransaction(
					project: .update(
						vaultId: "value-review-tests", environments: ["default": ["TOKEN": "DEMO-HISTORY-NEW"]],
						source: VaultHistorySource(.editKey, at: sourceDate.addingTimeInterval(60))), data: [])
				else { throw KeychainError.encodingFailed }
			}
			let project = try #require(try service.getProjectResult(vaultId: "value-review-tests").get())
			let biometric = MockBiometricService()
			let clock = LockedTime(0)
			let timer = ValueReviewTimer(clock: clock)
			let importer = MockEnvFileImportService()
			await importer.setImmediateResult(.success(ImportedEnvFile(secrets: ["TOKEN": "DEMO-IMPORT-NEW"])))
			let store = VaultStore(
				keychainService: service, biometricService: biometric, apiService: MockAPIService(),
				envFileImportService: importer, preferences: defaults, authTokenProvider: { _, _ in nil },
				autoLockSleep: { try await timer.sleep($0) }, autoLockNow: { clock.value }, settings: settings,
				projectIconsDirectory: folder.appendingPathComponent("icons"),
				clipboard: ClipboardManager(pasteboard: .withUniqueName(), sleep: { try await timer.sleep($0) }))
			store.projects = [project]
			store.isUnlocked = true
			store.openProject(id: project.id)
			store.valueAccess.noteUnlocked()
			keepResources = true
			return Fixture(store: store, project: project, biometric: biometric, clock: clock, timer: timer,
				folder: folder, defaults: defaults, domain: domain)
		}

		private func withFixture(history: Bool = false, _ operation: (Fixture) async throws -> Void) async throws {
			let value = try await fixture(history: history)
			do {
				try await operation(value)
				await value.tearDown()
			} catch {
				await value.tearDown()
				throw error
			}
		}

		private func importHost(_ fixture: Fixture, presentation: ValueReviewPresentation = ValueReviewPresentation()) async throws -> SheetTestHost<AnyView> {
			let source = EnvImportInput.text("TOKEN=DEMO-IMPORT-NEW")
			let imported = try await fixture.store.loadEnvImport(source, for: fixture.project.id).get()
			let review = try await fixture.store.prepareEnvImport(
				imported, from: .pastedText, to: fixture.project.id, environment: "default").get()
			let host = hosted(EnvFileImportReviewSheet(store: fixture.store, review: review), presentation: presentation, size: NSSize(width: 640, height: 600))
			var ready = false
			defer { if !ready { host.window.close() } }
			try #require(try await host.waitForText("Vault value for TOKEN hidden"))
			ready = true
			return host
		}

		private func historyHost(_ fixture: Fixture, presentation: ValueReviewPresentation = ValueReviewPresentation()) async throws -> SheetTestHost<AnyView> {
			await fixture.store.history.open(fixture.project.id)
			let entry = try #require(fixture.store.history.entries.first { $0.action == "editKey" })
			fixture.store.history.select(entry.id)
			let error = await fixture.store.history.reviewRemoval(
				entry: entry.id, environment: "default", key: "TOKEN", side: "before")
			try #require(error == nil)
			try #require(fixture.store.history.removalReview != nil)
			let host = hosted(VaultHistoryRemovalSheet(store: fixture.store, project: fixture.project), presentation: presentation, size: NSSize(width: 640, height: 640))
			var ready = false
			defer { if !ready { host.window.close() } }
			let field = try await host.waitForElement(saying: "The value of TOKEN to remove")
			try #require(field.value == "hidden")
			ready = true
			return host
		}

		@Test("import comparison requires renewed approval before exposing the stored baseline")
		func importReviewRequiresApproval() async throws {
			try await withFixture { fixture in
				let host = try await importHost(fixture)
				defer { host.window.close() }
				fixture.clock.value = 301
				fixture.biometric.shouldSucceed = false
				try #require(fixture.store.valueAccess.needsApproval)
				try await host.click("Reveal values")
				try #require(try await host.waitUntil {
					fixture.biometric.confirmationReasons.count > 0 ||
						AccessibilityTree.visibleElements(in: host.window, of: host.view).contains {
							$0.says("Vault value for TOKEN revealed visually")
						}
				})
				try await quietPeriod()
				let text = try await host.text()
				#expect(fixture.biometric.confirmationReasons == [VaultValueAccess.reason])
				#expect(text.contains("Vault value for TOKEN hidden"))
				#expect(!text.contains("Vault value for TOKEN revealed visually"))
			}
		}

		@Test("history removal requires renewed approval before exposing the stored historical value")
		func historyRemovalRequiresApproval() async throws {
			try await withFixture(history: true) { fixture in
				let host = try await historyHost(fixture)
				defer { host.window.close() }
				fixture.clock.value = 301
				fixture.biometric.shouldSucceed = false
				try #require(fixture.store.valueAccess.needsApproval)
				try await host.click("Reveal the value")
				try #require(try await host.waitUntil {
					fixture.biometric.confirmationReasons.count > 0 ||
						AccessibilityTree.visibleElements(in: host.window, of: host.view).contains {
							$0.says("The value of TOKEN to remove") && $0.value == "DEMO-HISTORY-OLD"
						}
				})
				try await quietPeriod()
				let field = try await host.waitForElement(saying: "The value of TOKEN to remove")
				#expect(fixture.biometric.confirmationReasons == [VaultValueAccess.reason])
				#expect(field.value == "hidden")
			}
		}

		@Test("import comparison starts the configured remasking lifecycle")
		func importReviewRemasks() async throws {
			try await withFixture { fixture in
				let host = try await importHost(fixture)
				defer { host.window.close() }
				try await host.click("Reveal values")
				try #require(try await host.waitForText("Vault value for TOKEN revealed visually"))
				let scheduled = try await waitUntil { await fixture.timer.requests.contains(.seconds(30)) }
				try #require(scheduled)
				let sleeps = await fixture.timer.requests
				fixture.clock.value = 31
				await fixture.timer.advance()
				let hidden = try await host.waitForText("Vault value for TOKEN hidden")
				#expect(hidden)
				let text = try await host.text()
				#expect(sleeps.filter { $0 == .seconds(30) }.count == 1)
				#expect(text.contains("Vault value for TOKEN hidden"))
			}
		}

		@Test("history removal starts the configured remasking lifecycle")
		func historyRemovalRemasks() async throws {
			try await withFixture(history: true) { fixture in
				let host = try await historyHost(fixture)
				defer { host.window.close() }
				try await host.click("Reveal the value")
				try #require(try await host.waitUntil {
					AccessibilityTree.visibleElements(in: host.window, of: host.view).contains {
						$0.says("The value of TOKEN to remove") && $0.value == "DEMO-HISTORY-OLD"
					}
				})
				let scheduled = try await waitUntil { await fixture.timer.requests.contains(.seconds(30)) }
				try #require(scheduled)
				let sleeps = await fixture.timer.requests
				fixture.clock.value = 31
				await fixture.timer.advance()
				let hidden = try await host.waitUntil {
					AccessibilityTree.visibleElements(in: host.window, of: host.view).contains {
						$0.says("The value of TOKEN to remove") && $0.value == "hidden"
					}
				}
				#expect(hidden)
				let field = try await host.waitForElement(saying: "The value of TOKEN to remove")
				#expect(sleeps.filter { $0 == .seconds(30) }.count == 1)
				#expect(field.value == "hidden")
			}
		}


		@Test("the import editor refuses native selection export and Services for both text types")
		func importInputRefusesNativeExport() async throws {
			try await withFixture { fixture in
				let host = SheetTestHost(EnvImportSheet(store: fixture.store, projectID: fixture.project.id, environment: "default"),
					size: NSSize(width: 660, height: 640), keepsRequestedSize: true, usesHostingView: true)
				defer { host.window.close() }
				try await host.click("Paste text")
				@MainActor func find(in view: NSView) -> EnvImportPasteEditor.PasteTextView? {
					if let input = view as? EnvImportPasteEditor.PasteTextView { return input }
					return view.subviews.lazy.compactMap { find(in: $0) }.first
				}
				try #require(try await host.waitUntil { find(in: host.view) != nil })
				let input = try #require(find(in: host.view))
				let value = "TOKEN=DEMO-IMPORT-SECRET"
				input.insertText(value, replacementRange: NSRange(location: 0, length: 0))
				try #require(try await host.waitForText("1 variable"))
				input.setSelectedRange(NSRange(location: 0, length: value.utf16.count))
				try #require(input.selectedRange().length == value.utf16.count)
				for type in [NSPasteboard.PasteboardType("NSStringPboardType"), .string] {
					let board = NSPasteboard.withUniqueName()
					defer { board.releaseGlobally() }
					#expect(!input.writeSelection(to: board, types: [type]))
					#expect(input.validRequestor(forSendType: type, returnType: nil) == nil)
					#expect(board.string(forType: .string) == nil)
					#expect(board.string(forType: type) == nil)
					#expect(board.types?.isEmpty != false)
				}
			}
		}


		private func hosted<V: View>(_ content: V, presentation: ValueReviewPresentation, size: NSSize) -> SheetTestHost<AnyView> {
			SheetTestHost(AnyView(ValueReviewHost(content: AnyView(content), presentation: presentation)),
				size: size, keepsRequestedSize: true, usesHostingView: true)
		}

		private func inputHost(_ fixture: Fixture, presentation: ValueReviewPresentation = ValueReviewPresentation(),
			text: String = "TOKEN=ab🔑e\u{301}xyz"
		) async throws -> (SheetTestHost<AnyView>, EnvImportPasteEditor.PasteTextView) {
			let host = hosted(EnvImportSheet(store: fixture.store, projectID: fixture.project.id, environment: "default"),
				presentation: presentation, size: NSSize(width: 660, height: 680))
			var ready = false
			defer { if !ready { host.window.close() } }
			try await host.click("Paste text")
			@MainActor func find(in view: NSView) -> EnvImportPasteEditor.PasteTextView? {
				if let input = view as? EnvImportPasteEditor.PasteTextView { return input }
				return view.subviews.lazy.compactMap { find(in: $0) }.first
			}
			try #require(try await host.waitUntil { find(in: host.view) != nil })
			let input = try #require(find(in: host.view))
			try #require(host.window.makeFirstResponder(input))
			input.insertText(text, replacementRange: NSRange(location: 0, length: 0))
			try #require(try await host.waitForText("1 variable"))
			try #require(ExactText(input.string) == ExactText(text))
			ready = true
			return (host, input)
		}

		private func withApproval(_ fixture: Fixture, _ operation: (ValueReviewApproval) async throws -> Void) async throws {
			let approval = ValueReviewApproval()
			fixture.biometric.authenticateHandlers = [{ await approval.wait() }]
			do {
				try await operation(approval)
				await approval.answer(false)
			} catch {
				await approval.answer(false)
				throw error
			}
		}

		private func isMasked(_ host: SheetTestHost<AnyView>, history: Bool) -> Bool {
			let elements = AccessibilityTree.visibleElements(in: host.window, of: host.view)
			return history
				? elements.contains { $0.says("The value of TOKEN to remove") && $0.value == "hidden" }
				: elements.contains { $0.says("Vault value for TOKEN hidden") }
		}

		@Test("renewed approval reveals a review and starts timed hiding", arguments: [false, true])
		func renewedApprovalSucceeds(history: Bool) async throws {
			try await withFixture(history: history) { fixture in
				let host = try await (history ? historyHost(fixture) : importHost(fixture))
				defer { host.window.close() }
				fixture.clock.value = 301
				try await withApproval(fixture) { approval in
					try await host.click(history ? "Reveal the value" : "Reveal values")
					try #require(try await waitUntil { fixture.biometric.confirmationReasons.count == 1 })
					#expect(isMasked(host, history: history))
					await approval.answer(true)
					try #require(try await host.waitUntil { !isMasked(host, history: history) })
					if history {
						#expect(try await host.waitForElement(saying: "The value of TOKEN to remove").value == "DEMO-HISTORY-OLD")
					} else {
						#expect(try await host.waitForText("Vault value for TOKEN revealed visually"))
					}
					try #require(try await waitUntil { await fixture.timer.requests.contains(.seconds(30)) })
					fixture.clock.value = 332
					await fixture.timer.advance()
					#expect(try await host.waitUntil { isMasked(host, history: history) })
					#expect(!fixture.store.valueAccess.needsApproval)
				}
			}
		}

		@Test("a withdrawn review cannot reveal after delayed approval",
			arguments: [false, true], ["hide", "privacy", "dismiss", "review", "lock"])
		func delayedReviewApprovalIsInvalidated(history: Bool, transition: String) async throws {
			try await withFixture(history: history) { fixture in
				let presentation = ValueReviewPresentation()
				let host = try await (history ? historyHost(fixture, presentation: presentation) : importHost(fixture, presentation: presentation))
				defer { host.window.close() }
				fixture.clock.value = 301
				try await withApproval(fixture) { approval in
					try await host.click(history ? "Reveal the value" : "Reveal values")
					try #require(try await waitUntil { fixture.biometric.confirmationReasons.count == 1 })
					switch transition {
					case "hide": fixture.store.valueAccess.hideRevealed()
					case "privacy":
						presentation.obscured = true
						try #require(try await host.waitForText("Values covered"))
					case "dismiss":
						presentation.visible = false
						try #require(try await host.waitForText("Review dismissed"))
					case "review":
						if history {
							let review = try #require(fixture.store.history.removalReview)
							_ = await fixture.store.history.reviewRemoval(entry: review.entry, environment: review.environment, key: review.key, side: "after")
						} else {
							let imported = try await fixture.store.loadEnvImport(.text("TOKEN=OTHER"), for: fixture.project.id).get()
							_ = try await fixture.store.prepareEnvImport(imported, from: .pastedText, to: fixture.project.id, environment: "default").get()
						}
					default: fixture.store.lock()
					}
					await approval.answer(true)
					try await quietPeriod()
					if transition != "lock" {
						presentation.obscured = false
						presentation.visible = true
						#expect(try await host.waitUntil { isMasked(host, history: history) })
					}
					#expect(fixture.store.history.value(of: .init(entry: fixture.store.history.selectedEntryID ?? "",
						environment: 0, key: 0, side: "before")) == nil)
				}
			}
		}

		@Test("concealment withdraws a queued history read before it starts")
		func queuedHistoryReadIsWithdrawn() async throws {
			try await withFixture(history: true) { fixture in
				let host = try await historyHost(fixture)
				defer { host.window.close() }
				let review = try #require(fixture.store.history.removalReview)
				let side = try #require(fixture.store.history.side(entry: review.entry, environment: review.environment, key: review.key, side: review.side))
				let reveal = try await host.clickLater("Reveal the value")
				try reveal()
				fixture.store.valueAccess.hideRevealed()
				try await quietPeriod()
				#expect(fixture.store.history.value(of: side) == nil)
				#expect(isMasked(host, history: true))
			}
		}

		@Test("import Copy preserves a Unicode selection and clears on its timer and lock")
		func importCopyIsManaged() async throws {
			try await withFixture { fixture in
				let (host, input) = try await inputHost(fixture)
				defer { host.window.close() }
				let selected = "ab🔑e\u{301}"
				let range = (input.string as NSString).range(of: selected)
				try #require(range.location != NSNotFound)
				input.setSelectedRange(range)
				let dispatched = NSApp.sendAction(#selector(NSText.copy(_:)), to: input, from: nil)
				#expect(dispatched)
				let board = fixture.store.clipboard.pasteboard
				#expect(ExactText(board.string(forType: .string) ?? "") == ExactText(selected))
				#expect(board.data(forType: ClipboardManager.concealedType) != nil)
				#expect(board.data(forType: ClipboardManager.transientType) != nil)
				try #require(try await waitUntil { await fixture.timer.requests.contains(.seconds(30)) })
				fixture.clock.value = 31
				await fixture.timer.advance()
				try #require(try await waitUntil { board.string(forType: .string) == nil })
				input.copy(nil)
				try #require(board.string(forType: .string) == selected)
				fixture.store.lock()
				#expect(board.string(forType: .string) == nil)
				#expect(fixture.biometric.confirmationReasons.isEmpty)
			}
		}

		@Test("import Cut removes only its copied selection and Undo restores it")
		func importCutAndUndo() async throws {
			try await withFixture { fixture in
				let (host, input) = try await inputHost(fixture)
				defer { host.window.close() }
				let before = input.string
				let range = (before as NSString).range(of: "🔑")
				input.setSelectedRange(range)
				input.breakUndoCoalescing()
				let dispatched = NSApp.sendAction(#selector(NSText.cut(_:)), to: input, from: nil)
				#expect(dispatched)
				#expect(fixture.store.clipboard.pasteboard.string(forType: .string) == "🔑")
				#expect(ExactText(input.string) == ExactText((before as NSString).replacingCharacters(in: range, with: "")))
				try #require(input.undoManager?.canUndo == true)
				input.undoManager?.undo()
				#expect(ExactText(input.string) == ExactText(before))
			}
		}

		@Test("pending import Copy and Cut refuse withdrawn editor state",
			arguments: [false, true], ["deny", "lock", "dismiss", "selection", "edit", "clear", "mode", "privacy"])
		func delayedImportCopyIsInvalidated(cutting: Bool, transition: String) async throws {
			try await withFixture { fixture in
				let presentation = ValueReviewPresentation()
				let (host, input) = try await inputHost(fixture, presentation: presentation)
				defer { host.window.close() }
				fixture.clock.value = 301
				input.setSelectedRange((input.string as NSString).range(of: "🔑"))
				try await withApproval(fixture) { approval in
					if cutting { input.cut(nil) } else { input.copy(nil) }
					try #require(try await waitUntil { fixture.biometric.confirmationReasons.count == 1 })
					switch transition {
					case "lock": fixture.store.lock()
					case "dismiss":
						presentation.visible = false
						try #require(try await host.waitForText("Review dismissed"))
					case "selection": input.setSelectedRange(NSRange(location: 0, length: 5))
					case "edit": input.insertText("changed", replacementRange: input.selectedRange())
					case "clear": try await host.click("Clear")
					case "mode":
						try await host.click("From file")
						try #require(try await host.waitForText("Drop an .env file here"))
					case "privacy":
						presentation.obscured = true
						try #require(try await host.waitForText("Values covered"))
					default: break
					}
					let afterTransition = input.string
					await approval.answer(transition != "deny")
					try await quietPeriod()
					#expect(fixture.store.clipboard.pasteboard.string(forType: .string) == nil)
					#expect(ExactText(input.string) == ExactText(afterTransition))
				}
			}
		}

		@Test("renewed import approval copies or cuts only after approval", arguments: [false, true])
		func renewedImportCopySucceeds(cutting: Bool) async throws {
			try await withFixture { fixture in
				let (host, input) = try await inputHost(fixture)
				defer { host.window.close() }
				let before = input.string
				let range = (before as NSString).range(of: "🔑")
				input.setSelectedRange(range)
				fixture.clock.value = 301
				try await withApproval(fixture) { approval in
					if cutting { input.cut(nil) } else { input.copy(nil) }
					try #require(try await waitUntil { fixture.biometric.confirmationReasons.count == 1 })
					#expect(fixture.store.clipboard.pasteboard.string(forType: .string) == nil)
					#expect(ExactText(input.string) == ExactText(before))
					await approval.answer(true)
					try #require(try await waitUntil { fixture.store.clipboard.pasteboard.string(forType: .string) == "🔑" })
					let expected = cutting ? (before as NSString).replacingCharacters(in: range, with: "") : before
					#expect(ExactText(input.string) == ExactText(expected))
				}
			}
		}

		@Test("the ordinary value gate rejects expired approval when authentication is denied")
		func ordinaryRevealDenialControl() async throws {
			try await withFixture { fixture in
				fixture.clock.value = 301
				fixture.biometric.shouldSucceed = false
				var exposed = false
				fixture.store.valueAccess.reveal { exposed = true }
				try #require(try await waitUntil { fixture.biometric.confirmationReasons.count == 1 })
				try await quietPeriod()
				#expect(!exposed)
				#expect(fixture.store.valueAccess.needsApproval)
			}
		}

		@Test("the ordinary value gate starts and completes the same controlled remasking timer")
		func ordinaryRehideControl() async throws {
			try await withFixture { fixture in
				var exposed = false
				fixture.store.valueAccess.reveal { exposed = true }
				try #require(try await waitUntil { await fixture.timer.requests.contains(.seconds(30)) })
				#expect(exposed)
				#expect(await fixture.timer.requests.filter { $0 == .seconds(30) }.count == 1)
				let generation = fixture.store.valueAccess.hideGeneration
				fixture.clock.value = 31
				await fixture.timer.advance()
				try #require(try await waitUntil { fixture.store.valueAccess.hideGeneration == generation + 1 })
			}
		}
	}
}


@Observable
@MainActor
private final class ValueReviewPresentation {
	var visible = true
	var obscured = false
}

private struct ValueReviewHost: View {
	let content: AnyView
	let presentation: ValueReviewPresentation

	var body: some View {
		VStack(spacing: 0) {
			Text(presentation.visible ? (presentation.obscured ? "Values covered" : "Values uncovered") : "Review dismissed")
			if presentation.visible { content.environment(\.vaultContentObscured, presentation.obscured) }
		}
	}
}

private actor ValueReviewApproval {
	private var answer: Bool?
	private var continuation: CheckedContinuation<Bool, Never>?

	func wait() async -> Bool {
		if let answer { return answer }
		return await withCheckedContinuation { continuation = $0 }
	}

	func answer(_ value: Bool) {
		guard answer == nil else { return }
		answer = value
		continuation?.resume(returning: value)
		continuation = nil
	}
}

private actor ValueReviewTimer {
	let clock: LockedTime
	private(set) var requests: [Duration] = []
	private var pending: [(TimeInterval, CheckedContinuation<Void, any Error>)] = []
	private var closed = false

	init(clock: LockedTime) { self.clock = clock }

	func sleep(_ duration: Duration) async throws {
		guard !closed, !Task.isCancelled else { throw CancellationError() }
		requests.append(duration)
		let components = duration.components
		let deadline = clock.value + Double(components.seconds) + Double(components.attoseconds) / 1e18
		try await withCheckedThrowingContinuation { continuation in pending.append((deadline, continuation)) }
	}

	func advance() {
		let ready = pending.filter { $0.0 <= clock.value }
		pending.removeAll { $0.0 <= clock.value }
		for (_, continuation) in ready { continuation.resume() }
	}

	func finish() {
		closed = true
		let old = pending
		pending.removeAll()
		for (_, continuation) in old { continuation.resume(throwing: CancellationError()) }
	}
}
