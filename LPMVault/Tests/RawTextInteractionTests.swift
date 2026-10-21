import AppKit
import SwiftUI
import Testing

@testable import LPMVault

/// The wait before a copy is cleared: it records how long each copy asked
/// for, and ends only when the test says the time is up.
final class ClipboardClearWaits: @unchecked Sendable {
	private let lock = NSLock()
	private var requested: [Duration] = []
	private var waiting: [CheckedContinuation<Void, Never>] = []

	var durations: [Duration] { lock.withLock { requested } }

	var sleep: @Sendable (Duration) async throws -> Void {
		{ [self] duration in
			await withCheckedContinuation { continuation in
				lock.withLock {
					requested.append(duration)
					waiting.append(continuation)
				}
			}
		}
	}

	func elapse() {
		let ended = lock.withLock {
			defer { waiting.removeAll() }
			return waiting
		}
		for continuation in ended { continuation.resume() }
	}
}

extension SheetInteractionTests {
	@Suite("Raw text interaction", .serialized)
	@MainActor
	struct RawTextInteractionTests {
		private static let values = ["API_TOKEN": "tok en", "DATABASE_URL": "postgres://app:pw@db:5432/demo", "LOG_LEVEL": "info"]

		@Test("Raw text masks values, and copying takes the real lines a selection touches, without Touch ID, for 10 seconds")
		func copySelectedLines() async throws {
			let waits = ClipboardClearWaits()
			defer { waits.elapse() }
			let (store, biometric, _) = makeStore(clearWaits: waits)
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("API_TOKEN=\(VaultRawText.mask)"))
			let text = try await host.text()
			#expect(!text.contains("postgres://") && !text.contains("tok en"), "Hidden values aren't in the text at all")
			for status in ["3 lines", "values masked", "⌘A selects all"] { #expect(text.contains(status), "The status says \(status)") }
			try record(host, named: "raw-text-masked")
			let textView = try codeView(in: host)
			let lines = textView.string as NSString
			let firstLine = lines.lineRange(for: NSRange(location: 0, length: 0))
			let partial = NSRange(location: firstLine.length - 4, length: 8)
			textView.setSelectedRange(partial)
			#expect(textView.selectedRange() == lines.lineRange(for: partial), "A selection takes whole lines")
			#expect(try await host.waitForText("2 lines selected"))
			NSApp.sendAction(#selector(NSText.copy(_:)), to: textView, from: nil)
			let pasteboard = store.clipboard.pasteboard
			#expect(pasteboard.string(forType: .string) == "API_TOKEN=\"tok en\"\nDATABASE_URL=postgres://app:pw@db:5432/demo\n")
			#expect(pasteboard.types?.contains(ClipboardManager.concealedType) == true)
			#expect(pasteboard.types?.contains(ClipboardManager.transientType) == true)
			#expect(biometric.authenticateCallCount == 0 && biometric.confirmationReasons.isEmpty)
			#expect(try await host.waitForText("Copied 2 lines · clears in 10s"))
			try record(host, named: "raw-text-copied")
			#expect(try await host.waitUntil { waits.durations == [.seconds(10)] })
			waits.elapse()
			#expect(try await host.waitUntil { pasteboard.string(forType: .string) == nil })
		}

		@Test("Copy all asks for no Touch ID, and its copy clears after 10 seconds, as every copy does")
		func copyAll() async throws {
			let waits = ClipboardClearWaits()
			defer { waits.elapse() }
			let (store, biometric, _) = makeStore(clearWaits: waits)
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Copy all")
			#expect(try await host.waitUntil {
				store.clipboard.pasteboard.string(forType: .string) == ClipboardManager.dotenvText(for: Self.values)
			})
			#expect(try await host.waitForText("Copied"))
			#expect(biometric.authenticateCallCount == 0 && biometric.confirmationReasons.isEmpty)
			#expect(try await host.waitUntil { waits.durations == [.seconds(10)] })
		}

		@Test("revealing shows the real lines, keeps the same lines selected, and the status says values are revealed")
		func revealKeepsSelection() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			let textView = try codeView(in: host)
			let masked = textView.string as NSString
			let second = masked.lineRange(for: NSRange(location: masked.lineRange(for: NSRange(location: 0, length: 0)).length, length: 0))
			textView.setSelectedRange(second)
			#expect(try await host.waitForText("1 line selected"))
			try await host.click("Reveal")
			#expect(try await host.waitForText("DATABASE_URL=postgres://app:pw@db:5432/demo"))
			let text = try await host.text()
			#expect(text.contains("API_TOKEN=\"tok en\"") && text.contains("values revealed"))
			#expect((textView.string as NSString).substring(with: textView.selectedRange()) == "DATABASE_URL=postgres://app:pw@db:5432/demo\n")
			try record(host, named: "raw-text-revealed")
		}

		@Test("a drag over parts of two lines selects both lines whole")
		func dragSelectsWholeLines() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			let textView = try codeView(in: host)
			let layoutManager = try #require(textView.layoutManager)
			let container = try #require(textView.textContainer)
			func point(at index: Int) -> NSPoint {
				let glyph = layoutManager.glyphIndexForCharacter(at: index)
				let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
					.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
				return textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
			}
			func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
				try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
					windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
			}
			let lines = textView.string as NSString
			let first = lines.lineRange(for: NSRange(location: 0, length: 0))
			let second = lines.lineRange(for: NSRange(location: first.length, length: 0))
			// The text view tracks a drag in its mouse-down, reading the events after it.
			NSApp.postEvent(try event(.leftMouseDragged, at: point(at: first.length + 3)), atStart: false)
			NSApp.postEvent(try event(.leftMouseUp, at: point(at: first.length + 3)), atStart: false)
			textView.mouseDown(with: try event(.leftMouseDown, at: point(at: 4)))
			#expect(textView.selectedRange() == NSRange(location: 0, length: NSMaxRange(second)))
			#expect(try await host.waitForText("2 lines selected"))
		}

		@Test("copying lines during a refresh copies the values it publishes")
		func copyWaitsForRefresh() async throws {
			let keychain = MockKeychainService()
			let (store, _, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			let textView = try codeView(in: host)
			let lines = textView.string as NSString
			textView.setSelectedRange(lines.lineRange(for: NSRange(location: lines.lineRange(for: NSRange(location: 0, length: 0)).length, length: 0)))
			let entered = DispatchSemaphore(value: 0)
			let release = DispatchSemaphore(value: 0)
			keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
			let refresh = Task { await store.refreshLocalState() }
			await withCheckedContinuation { continuation in
				DispatchQueue.global().async { entered.wait(); continuation.resume() }
			}
			keychain.beforeKeychainTransaction = nil
			keychain.envStorage["raw"]?.environments["default"]?["DATABASE_URL"] = "postgres://refreshed"
			NSApp.sendAction(#selector(NSText.copy(_:)), to: textView, from: nil)
			#expect(store.clipboard.pasteboard.string(forType: .string) == nil, "Nothing is copied before the refresh publishes")
			release.signal()
			await refresh.value
			#expect(try await host.waitUntil { store.clipboard.pasteboard.string(forType: .string) == "DATABASE_URL=postgres://refreshed\n" })
		}

		@Test("only Copy takes the text out: its menu has Copy and Select All, and drags, Services and Writing Tools get nothing")
		func nothingElseTakesTheText() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Reveal")
			let textView = try codeView(in: host)
			#expect(try await host.waitUntil { textView.string.contains("postgres://") })
			textView.selectAll(nil)
			let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
				windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
			#expect(textView.menu(for: click)?.items.map(\.title) == ["Copy", "Select All"])
			#expect(!textView.writeSelection(to: .withUniqueName(), types: [.string]))
			#expect(textView.validRequestor(forSendType: .string, returnType: nil) == nil)
			if #available(macOS 15.0, *) { #expect(textView.writingToolsBehavior == .none) }
			#expect(!textView.isEditable)
		}

		@Test("Fix in table, on a failed group's banner, shows the table")
		func fixInTable() async throws {
			let project = VaultProject(id: "p", name: "p", path: "", environments: ["default": ["SAVED": "x"]])
			let check = ProjectEnvValueCheck(environments: [
				"default": .init(problems: ["SAVED": [.init(key: "SAVED", kind: .group(name: "credentials", mode: "exactlyOne"))]])
			])
			let host = SheetTestHost(FixInTableView(project: project, check: check), size: NSSize(width: 950, height: 550),
				keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitForText("Group credentials fails"))
			try await host.click("Fix in table")
			#expect(try await host.waitForText("KEY", exactly: true))
			#expect(try await host.waitForTextToDisappear("Fix in table"))
		}

		/// `clearWaits` holds each copy until it's told the time is up.
		private func makeStore(keychain: MockKeychainService = MockKeychainService(), clearWaits: ClipboardClearWaits? = nil)
			-> (VaultStore, MockBiometricService, MockKeychainService)
		{
			let biometric = MockBiometricService()
			let project = VaultProject(id: "raw", name: "Raw", path: "", environments: ["default": Self.values])
			keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments)
			let clipboard = clearWaits.map { ClipboardManager(pasteboard: .withUniqueName(), sleep: $0.sleep) }
				?? ClipboardManager(pasteboard: .withUniqueName())
			let store = VaultStore(keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil }, clipboard: clipboard)
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			return (store, biometric, keychain)
		}

		/// The workspace showing the project's .env as Raw text. Copy
		/// confirmations stay until the test is over.
		private func rawText(_ store: VaultStore) async throws -> SheetTestHost<some View> {
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "raw-text-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).environment(VaultQuitSettings(defaults: defaults))
				.environment(\.vaultCopyFeedbackTimer, ManualFeedbackTimer().timer)
				.defaultAppStorage(defaults),
				size: NSSize(width: 1300, height: 700), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["raw"] != nil })
			try await host.clickSidebarEnvironment(".env")
			try await host.click("Raw text")
			#expect(try await host.waitForText("API_TOKEN="))
			try await host.settle()
			return host
		}

		private func codeView<V: View>(in host: SheetTestHost<V>) throws -> VaultRawTextView.CodeTextView {
			func find(_ view: NSView) -> VaultRawTextView.CodeTextView? {
				if let textView = view as? VaultRawTextView.CodeTextView { return textView }
				return view.subviews.lazy.compactMap(find).first
			}
			return try #require(find(host.view), "Raw text shows a code view")
		}

		private func record<V: View>(_ host: SheetTestHost<V>, named name: String) throws {
			let view = host.view
			let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
			view.cacheDisplay(in: view.bounds, to: bitmap)
			Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: name + ".png")
		}
	}
}

/// A content view showing Raw text, whose Fix in table can switch it to the table.
private struct FixInTableView: View {
	let project: VaultProject
	let check: ProjectEnvValueCheck
	@State private var viewMode = VaultEnvironmentViewMode.raw

	var body: some View {
		VaultContentView(
			project: project, snapshot: VaultWorkspaceSnapshot(project: project),
			environments: ["default"], selectedEnvironment: "default",
			mode: .constant(.environment("default")), filter: .constant(.all),
			environmentViewMode: $viewMode, sortOrder: .constant(.ascending),
			searchText: "", selectedKey: .constant(nil), revealedKeys: .constant([]),
			showsInspector: .constant(false), columnWidths: .constant(VaultProjectTableColumnWidths()),
			isCopyingAll: false, cliAccess: nil,
			isChangingCliAccess: false, onChangeCliAccess: { _ in }, onCopyAll: {},
			onImport: {}, onExport: {},
			valueChecks: VaultValueCheckPresentation(check: check, rules: nil, project: project),
			onAddSecret: {}, onCopySecret: { _, _ in },
			onDeleteSecret: { _, _ in }, onResizeColumns: {}
		)
	}
}
