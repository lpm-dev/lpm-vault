import AppKit
import CoreTransferable
import Foundation
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import LPMVault

@Suite("Sidebar project order", .serialized)
@MainActor
struct VaultProjectOrderTests {
	@Test("sidebar recognition tolerates a spurious dot on the default label without confusing named environments",
		arguments: [("• .env.", ".env", true), (".env", ".env", true), (".env.staging", ".env", false),
			(".env..", ".env", false), (".env.production.", ".env.production", false),
			(".env.production.", ".env.production.", true)])
	func sidebarEnvironmentRecognition(sample: (String, String, Bool)) {
		#expect(SidebarEnvironmentLabel.matches(sample.0, displayName: sample.1) == sample.2)
	}

	@Test("late exits leave the active marker intact and unchanged pointer updates do not invalidate it")
	func markerTransitions() {
		let state = VaultSidebarProjectDropState()
		let first = VaultSidebarProjectDropMarker()
		let second = VaultSidebarProjectDropMarker()
		state.update(first, placement: .before)
		state.update(second, placement: .after)
		#expect(first.placement == nil)
		#expect(second.placement == .after)
		state.exit(first)
		#expect(second.placement == .after)
		let changes = SidebarMarkerChanges()
		withObservationTracking {
			_ = second.placement
		} onChange: {
			MainActor.assumeIsolated { changes.count += 1 }
		}
		for _ in 0..<10_000 { state.update(second, placement: .after) }
		#expect(changes.count == 0)
		state.update(second, placement: .before)
		#expect(changes.count == 1)
		#expect(second.placement == .before)
		state.clear()
		#expect(second.placement == nil)
	}

	@Test("child icon centers and visible labels share their columns", arguments: [CGFloat(280), 400],
		[VaultWorkspaceMode.matrix, .schema, .environment("default")])
	func childRowAlignment(width: CGFloat, mode: VaultWorkspaceMode) async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		store.openProject(id: "alpha")
		let host = sidebarHost(store, width: width, mode: mode)
		defer { host.window.close() }
		try await host.settle()
		let bands = try labelBands(in: host)
		try #require(bands.count == 5, "Expected the project label and four child labels, got \(bands)")
		let project = bands[0]
		let projectStart = try inkStart(in: host, band: project, columns: 35..<150)
		var labelStarts: [CGFloat] = []
		for (label, band) in zip(["Schema", "New environment", ".env", ".env.staging"], bands.dropFirst()) {
			let icon = try inkBounds(in: host, band: band, columns: 30..<54)
			#expect(abs(icon.midX - projectStart - 3) <= 0.5, "\(label) icon center is \(icon.midX), expected \(projectStart + 3)")
			labelStarts.append(try inkStart(in: host, band: band, columns: 54..<180))
		}
		let spread = try #require(labelStarts.max()) - #require(labelStarts.min())
		#expect(spread <= 1, "Visible label starts: \(labelStarts)")
		let image = NSBitmapImageRep(cgImage: try host.snapshot(host.view))
		Attachment.record(try #require(image.representation(using: .png, properties: [:])), named: "sidebar-\(Int(width)).png")
	}

	@Test("only the current insertion marker is visible and drag completion clears it", arguments: ["drop", "exit", "lock", "account"])
	func insertionMarkerLifecycle(completion: String) async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		let host = sidebarHost(store)
		defer { host.window.close() }
		try await host.settle()
		let pasteboard = NSPasteboard(name: NSPasteboard.Name("sidebar-marker-test-" + UUID().uuidString))
		defer { pasteboard.releaseGlobally() }
		let item = NSPasteboardItem()
		let drag = VaultSidebarProjectDrag(projectId: "zulu", sessionId: store.sidebarDragSessionId)
		#expect(item.setData(try JSONEncoder().encode(drag), forType: NSPasteboard.PasteboardType(VaultSidebarProjectDrag.contentType.identifier)))
		#expect(pasteboard.writeObjects([item]))
		let targets = dropViews(in: host.view).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
		try #require(targets.count == 3, "Expected three collapsed project drop targets, got \(targets.map { $0.convert($0.bounds, to: nil) })")
		var previous: (NSView, SidebarTestDraggingInfo)?
		for target in targets.prefix(2) {
			let bounds = target.convert(target.bounds, to: nil)
			let point = NSPoint(x: bounds.midX, y: bounds.maxY - bounds.height / 4)
			let info = SidebarTestDraggingInfo(window: host.window, pasteboard: pasteboard, location: point)
			#expect(target.draggingEntered(info).contains(.move))
			#expect(target.draggingUpdated(info).contains(.move))
			try await host.settle()
			#expect(try markerRows(in: host).count == 4, "There must be exactly one 2-point insertion marker")
			previous = (target, info)
		}
		let (target, info) = try #require(previous)
		switch completion {
		case "exit":
			target.draggingExited(info)
		case "lock":
			store.lock()
		case "account":
			store.selectedAccount = .org("team")
		default:
			#expect(target.prepareForDragOperation(info))
			#expect(target.performDragOperation(info))
		}
		try await host.settle()
		#expect(try markerRows(in: host).isEmpty)
	}

	@Test("project drag data is available only inside this process")
	func projectDragVisibility() {
		if #available(macOS 15.2, *) {
			#expect(VaultSidebarProjectDrag.exportedContentTypes(visibility: .all).isEmpty)
			#expect(VaultSidebarProjectDrag.exportedContentTypes(visibility: .ownProcess) == [VaultSidebarProjectDrag.contentType])
		}
	}

	@Test("native dragging enumeration respects the requested pasteboard classes")
	func nativeDraggingEnumeration() throws {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 500),
			styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		defer { window.close() }
		let pasteboard = NSPasteboard(name: NSPasteboard.Name("sidebar-enumeration-test-" + UUID().uuidString))
		defer { pasteboard.releaseGlobally() }
		let item = NSPasteboardItem()
		let type = NSPasteboard.PasteboardType(VaultSidebarProjectDrag.contentType.identifier)
		let data = Data("project drag".utf8)
		#expect(item.setData(data, forType: type))
		#expect(pasteboard.writeObjects([item]))
		let info = SidebarTestDraggingInfo(window: window, pasteboard: pasteboard, location: .zero)
		var stringItems = 0
		info.enumerateDraggingItems(options: [], for: nil, classes: [NSString.self], searchOptions: [:]) { _, _, _ in
			stringItems += 1
		}
		#expect(stringItems == 0)
		var payloads: [Data] = []
		info.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
			if let data = (item.item as? NSPasteboardItem)?.data(forType: type) { payloads.append(data) }
		}
		#expect(payloads == [data])
	}

	@Test("dropping after an expanded project marks the position below its environments")
	func expandedProjectInsertionMarker() async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		store.openProject(id: "alpha")
		let host = SheetTestHost(VaultSidebarView(store: store, snapshots: [:], mode: .constant(.matrix),
			filter: .constant(.all), searchText: .constant(""), showsAccountSwitcher: .constant(false),
			onNewProject: {}, onCloudProjects: {}, onNewEnvironment: {}, onRenameProject: { _ in },
			onDeleteProject: { _ in }, onRenameEnvironment: { _ in }, onDuplicateEnvironment: { _ in },
			onClearEnvironment: { _ in }, onDeleteEnvironment: { _ in }),
			size: NSSize(width: 280, height: 500), keepsRequestedSize: true, usesHostingView: true)
		defer { host.window.close() }
		try await host.settle()
		let bands = try labelBands(in: host)
		try #require(bands.count == 5)
		let staging = bands[4]
		let target = try #require(dropViews(in: host.view).max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY })
		let bounds = target.convert(target.bounds, to: nil)
		let point = NSPoint(x: bounds.midX, y: bounds.maxY - 24)
		let pasteboard = NSPasteboard(name: NSPasteboard.Name("sidebar-drop-test-" + UUID().uuidString))
		defer { pasteboard.releaseGlobally() }
		let drag = VaultSidebarProjectDrag(projectId: "zulu", sessionId: store.sidebarDragSessionId)
		let item = NSPasteboardItem()
		#expect(item.setData(try JSONEncoder().encode(drag), forType: NSPasteboard.PasteboardType(VaultSidebarProjectDrag.contentType.identifier)))
		#expect(pasteboard.writeObjects([item]))
		let info = SidebarTestDraggingInfo(window: host.window, pasteboard: pasteboard, location: point)
		#expect(target.draggingEntered(info).contains(.move))
		#expect(target.draggingUpdated(info).contains(.move))
		try await host.settle()
		let image = try host.snapshot(host.view)
		let width = image.width, height = image.height
		let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		let lineRows = (0..<height).filter { row in
			[width / 4, width / 2, 3 * width / 4].allSatisfy { column in
				let pixel = (row * width + column) * 4
				return abs(Int(pixels[pixel]) - 94) < 16 && abs(Int(pixels[pixel + 1]) - 92) < 16 && abs(Int(pixels[pixel + 2]) - 230) < 16
			}
		}
		let row = try #require(lineRows.first, "No insertion marker was rendered")
		let markerY = host.view.bounds.height * (1 - (CGFloat(row) + 0.5) / CGFloat(height))
		#expect(markerY < staging.minY, "Insertion marker at \(markerY) must be below the last environment at \(staging.minY)")
		#expect(abs(markerY - bounds.minY - 1) <= 1, "Marker at \(markerY) must follow the expanded group's bottom at \(bounds.minY)")
		target.draggingExited(info)
	}

	@Test("new projects appear at the top before and after manual reordering")
	func createsAtTop() async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		#expect(await store.createVault(name: "Z newest", vaultId: "newest") == .completed)
		#expect(store.visibleVaults(matching: "").map(\.id) == ["newest", "alpha", "middle", "zulu"])
		#expect(store.moveProject(id: "middle", relativeTo: "newest", placement: .before))
		#expect(await store.addProjectWithVaultId(vaultId: "next", name: "Z next", environments: ["default": [:]]))
		#expect(store.visibleVaults(matching: "").map(\.id) == ["next", "middle", "newest", "alpha", "zulu"])
	}

	@Test("a CLI refresh prepends newly discovered projects without sorting the existing sidebar")
	func discoversAtTop() async throws {
		let (store, keychain, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		keychain.envStorage["newest"] = (name: "Z newest", path: "", environments: ["default": [:]])
		keychain.envStorage["alpha"]?.name = "Z renamed"
		await store.refreshLocalState()
		#expect(store.visibleVaults(matching: "").map(\.id) == ["newest", "alpha", "middle", "zulu"])
	}

	@Test("dragging projects moves in both directions and persists without changing selection")
	func movesAndPersists() async throws {
		let (store, keychain, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		store.openProject(id: "alpha")
		store.selectEnvironment("staging")
		let original = store.projects
		let drag = VaultSidebarProjectDrag(projectId: "zulu", sessionId: store.sidebarDragSessionId)
		#expect(store.dropSidebarProject(drag, relativeTo: "alpha", placement: .before))
		#expect(store.visibleVaults(matching: "").map(\.id) == ["zulu", "alpha", "middle"])
		#expect(store.moveProject(id: "alpha", relativeTo: "middle", placement: .after))
		#expect(store.visibleVaults(matching: "").map(\.id) == ["zulu", "middle", "alpha"])
		#expect(store.selectedProjectId == "alpha")
		#expect(store.selectedEnvironment == "staging")
		#expect(store.projects == original)
		#expect(keychain.saveEnvironmentsCallCount == 0)
		#expect(keychain.applyVaultTransactionCallCount == 0)
		#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["zulu", "middle", "alpha"])
		let reopened = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), preferences: preferences, authTokenProvider: { _, _ in nil })
		defer { reopened.lock() }
		#expect(await reopened.loadProjects())
		#expect(reopened.visibleVaults(matching: "").map(\.id) == ["zulu", "middle", "alpha"])
	}

	@Test("search preserves saved order and a move keeps hidden projects in their relative order")
	func filteredMove() throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		store.projects[0].name = "Match Alpha"
		store.projects[2].name = "Match Zulu"
		store.projects.insert(VaultProject(id: "hidden", name: "Hidden", path: "", environments: ["default": [:]]), at: 1)
		#expect(store.moveProject(id: "hidden", relativeTo: "alpha", placement: .after))
		#expect(store.visibleVaults(matching: " match ").map(\.id) == ["alpha", "zulu"])
		#expect(store.moveProject(id: "zulu", relativeTo: "alpha", placement: .before))
		#expect(store.visibleVaults(matching: "match").map(\.id) == ["zulu", "alpha"])
		#expect(store.visibleVaults(matching: "").map(\.id) == ["zulu", "alpha", "hidden", "middle"])
	}

	@Test("self drops, missing projects, and already adjacent moves leave preferences untouched")
	func invalidAndNoOpMoves() throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		for (source, target, placement) in [
			("alpha", "alpha", VaultProjectPlacement.before),
			("missing", "alpha", .before), ("alpha", "missing", .after),
			("alpha", "middle", .before), ("middle", "alpha", .after),
		] {
			#expect(!store.moveProject(id: source, relativeTo: target, placement: placement))
		}
		#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["alpha", "middle", "zulu"])
		#expect(store.visibleVaults(matching: "").map(\.id) == ["alpha", "middle", "zulu"])
	}

	@Test("drops reject foreign drag sessions, account switches, and locked sessions", arguments: ["foreign", "account", "lock"])
	func rejectsStaleDrag(transition: String) throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		let drag = VaultSidebarProjectDrag(projectId: "zulu",
			sessionId: transition == "foreign" ? UUID() : store.sidebarDragSessionId)
		if transition == "account" {
			store.selectedAccount = .org("team")
			store.selectedAccount = .personal
		} else if transition == "lock" {
			store.lock()
			#expect(!store.dropSidebarProject(drag, relativeTo: "alpha", placement: .before))
			store.isUnlocked = true
		}
		#expect(!store.dropSidebarProject(drag, relativeTo: "alpha", placement: .before))
		#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["alpha", "middle", "zulu"])
	}

	@Test("personal and organization projects reorder only within their active account")
	func accountOrdering() throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		store.currentUser = LPMUser(id: "user", username: "user", name: nil, email: nil, avatarUrl: nil,
			plan: nil, createdAt: nil, orgs: [LPMOrg(id: "team-id", slug: "team", name: "Team", avatarUrl: nil, role: "owner")])
		store.projects += ["org-first", "org-last"].map {
			VaultProject(id: $0, name: $0, path: "", environments: ["default": [:]])
		}
		store.vaultOrgAssociations = ["org-first": "team", "org-last": "team"]
		#expect(!store.moveProject(id: "org-last", relativeTo: "alpha", placement: .before))
		#expect(!store.moveProject(id: "alpha", relativeTo: "org-first", placement: .after))
		#expect(store.moveProject(id: "zulu", relativeTo: "alpha", placement: .before))
		store.selectAccount(.org("team"))
		#expect(store.visibleVaults(matching: "").map(\.id) == ["org-first", "org-last"])
		#expect(store.moveProject(id: "org-last", relativeTo: "org-first", placement: .before))
		#expect(store.visibleVaults(matching: "").map(\.id) == ["org-last", "org-first"])
		store.selectAccount(.personal)
		#expect(store.visibleVaults(matching: "").map(\.id) == ["zulu", "alpha", "middle"])
	}

	@Test("deleting a project prunes its saved position and a newly created project appears first")
	func deletionAndInsertion() async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		#expect(store.moveProject(id: "zulu", relativeTo: "alpha", placement: .before))
		let removed = try #require(store.projects.first { $0.id == "alpha" })
		#expect(await store.deleteLocalVault(removed))
		#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["zulu", "middle"])
		store.projects.insert(VaultProject(id: "new", name: "A new project", path: "", environments: ["default": [:]]), at: 0)
		#expect(store.visibleVaults(matching: "").map(\.id) == ["new", "zulu", "middle"])
	}

	@Test("queued native item providers reorder projects and reject malformed data", arguments: [false, true], ["registered", "raw"])
	func nativeDrop(malformed: Bool, representation: String) async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		let drag = VaultSidebarProjectDrag(projectId: "zulu", sessionId: store.sidebarDragSessionId)
		let data = malformed ? Data("invalid".utf8) : try JSONEncoder().encode(drag)
		let provider: NSItemProvider
		if representation == "raw" {
			provider = NSItemProvider(item: data as NSData, typeIdentifier: VaultSidebarProjectDrag.contentType.identifier)
		} else {
			provider = NSItemProvider()
			provider.registerDataRepresentation(forTypeIdentifier: VaultSidebarProjectDrag.contentType.identifier, visibility: .ownProcess) { completion in
				completion(data, nil)
				return nil
			}
		}
		let delegate = VaultSidebarProjectDropDelegate(store: store, projectId: "middle", rowHeight: 30, dropState: VaultSidebarProjectDropState(), marker: VaultSidebarProjectDropMarker())
		let operation = try #require(delegate.enqueueDrop(from: [provider], placement: .before))
		#expect(await operation.value == !malformed)
		#expect(store.visibleVaults(matching: "").map(\.id) == (malformed ? ["alpha", "middle", "zulu"] : ["alpha", "zulu", "middle"]))
	}

	@Test("empty, multiple-item and locked drops do not enqueue work", arguments: ["empty", "multiple", "locked"])
	func invalidDropQueue(input: String) throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		let originalOrder = preferences.stringArray(forKey: VaultStore.projectOrderKey)
		if input == "locked" { store.lock() }
		let providers = input == "empty" ? [] : (0..<(input == "multiple" ? 2 : 1)).map { _ in NSItemProvider() }
		let delegate = VaultSidebarProjectDropDelegate(store: store, projectId: "middle", rowHeight: 30,
			dropState: VaultSidebarProjectDropState(), marker: VaultSidebarProjectDropMarker())
		#expect(delegate.enqueueDrop(from: providers, placement: .before) == nil)
		#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == originalOrder)
	}

	@Test("the pointer selects an insertion before or after the target row")
	func dropPlacement() {
		#expect(VaultProjectPlacement.at(y: 0, rowHeight: 30) == .before)
		#expect(VaultProjectPlacement.at(y: 14, rowHeight: 30) == .before)
		#expect(VaultProjectPlacement.at(y: 15, rowHeight: 30) == .after)
		#expect(VaultProjectPlacement.at(y: 30, rowHeight: 30) == .after)
	}

	@Test("the sidebar restores saved project order before and after a local refresh")
	func restoresSavedOrder() async throws {
		let domain = "sidebar-project-order-" + UUID().uuidString
		let preferences = try #require(UserDefaults(suiteName: domain))
		defer { preferences.removePersistentDomain(forName: domain) }
		preferences.set(["zulu", "alpha", "middle"], forKey: "lpm-vault-project-order")
		let keychain = MockKeychainService()
		for (id, name) in [("alpha", "Alpha"), ("middle", "Middle"), ("zulu", "Zulu")] {
			keychain.envStorage[id] = (name: name, path: "", environments: ["default": [:]])
		}
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), preferences: preferences, authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		defer { store.lock() }
		#expect(await store.loadProjects())
		#expect(store.visibleVaults(matching: "").map(\.id) == ["zulu", "alpha", "middle"])
		keychain.envStorage["alpha"]?.name = "A renamed project"
		await store.refreshLocalState()
		#expect(store.visibleVaults(matching: "").map(\.id) == ["zulu", "alpha", "middle"])
	}

	@Test("saved order ignores deleted and duplicate IDs and prepends new projects")
	func reconcilesSavedOrder() throws {
		let domain = "sidebar-project-order-" + UUID().uuidString
		let preferences = try #require(UserDefaults(suiteName: domain))
		defer { preferences.removePersistentDomain(forName: domain) }
		preferences.set(["deleted", "zulu", "zulu", "alpha"], forKey: "lpm-vault-project-order")
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), preferences: preferences, authTokenProvider: { _, _ in nil })
		store.projects = ["alpha", "middle", "zulu"].map {
			VaultProject(id: $0, name: $0, path: "", environments: ["default": [:]])
		}
		#expect(store.visibleVaults(matching: "").map(\.id) == ["middle", "zulu", "alpha"])
		#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["middle", "zulu", "alpha"])
	}

	@Test("rendered sidebar registers project drops and updates its rows after a native drop")
	func renderedSidebarDrop() async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		let host = SheetTestHost(VaultSidebarView(store: store, snapshots: [:], mode: .constant(.matrix),
			filter: .constant(.all), searchText: .constant(""), showsAccountSwitcher: .constant(false),
			onNewProject: {}, onCloudProjects: {}, onNewEnvironment: {}, onRenameProject: { _ in },
			onDeleteProject: { _ in }, onRenameEnvironment: { _ in }, onDuplicateEnvironment: { _ in },
			onClearEnvironment: { _ in }, onDeleteEnvironment: { _ in }),
			size: NSSize(width: 280, height: 500), keepsRequestedSize: true, usesHostingView: true)
		defer { host.window.close() }
		try await host.settle()
		func registeredTypes(in view: NSView) -> [NSPasteboard.PasteboardType] {
			view.registeredDraggedTypes + view.subviews.flatMap { registeredTypes(in: $0) }
		}
		let types = registeredTypes(in: host.view)
		#expect(types.contains(NSPasteboard.PasteboardType(UTType.data.identifier)))
		let alphaBefore = try await host.labelFrame("Alpha")
		let zuluBefore = try await host.labelFrame("Zulu")
		#expect(alphaBefore.midY > zuluBefore.midY)
		let drag = VaultSidebarProjectDrag(projectId: "zulu", sessionId: store.sidebarDragSessionId)
		let data = try JSONEncoder().encode(drag)
		let provider = NSItemProvider()
		provider.registerDataRepresentation(forTypeIdentifier: VaultSidebarProjectDrag.contentType.identifier, visibility: .ownProcess) { completion in
			completion(data, nil)
			return nil
		}
		let delegate = VaultSidebarProjectDropDelegate(store: store, projectId: "alpha", rowHeight: 30, dropState: VaultSidebarProjectDropState(), marker: VaultSidebarProjectDropMarker())
		#expect(await delegate.loadDrop(from: provider, placement: .before))
		try await host.settle()
		let alphaAfter = try await host.labelFrame("Alpha")
		let zuluAfter = try await host.labelFrame("Zulu")
		#expect(zuluAfter.midY > alphaAfter.midY)
	}

	@Test("the app declares its project drag type as data")
	func declaresProjectDragType() throws {
		let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
		let data = try Data(contentsOf: package.appendingPathComponent("Info.plist"))
		let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
		let declaration = try #require(declarations.first { $0["UTTypeIdentifier"] as? String == VaultSidebarProjectDrag.contentType.identifier })
		#expect(declaration["UTTypeConformsTo"] as? [String] == [UTType.data.identifier])
	}

	private func sidebarHost(_ store: VaultStore, width: CGFloat = 280, mode: VaultWorkspaceMode = .matrix) -> SheetTestHost<some View> {
		SheetTestHost(VaultSidebarView(store: store, snapshots: [:], mode: .constant(mode),
			filter: .constant(.all), searchText: .constant(""), showsAccountSwitcher: .constant(false),
			onNewProject: {}, onCloudProjects: {}, onNewEnvironment: {}, onRenameProject: { _ in },
			onDeleteProject: { _ in }, onRenameEnvironment: { _ in }, onDuplicateEnvironment: { _ in },
			onClearEnvironment: { _ in }, onDeleteEnvironment: { _ in }),
			size: NSSize(width: width, height: 500), keepsRequestedSize: true, usesHostingView: true)
	}

	private func dropViews(in view: NSView) -> [NSView] {
		(view.registeredDraggedTypes.isEmpty ? [] : [view]) + view.subviews.flatMap { dropViews(in: $0) }
	}

	private func markerRows<V: View>(in host: SheetTestHost<V>) throws -> [Int] {
		let image = try host.snapshot(host.view)
		let context = try pixelContext(image)
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		return (0..<image.height).filter { row in
			[image.width / 4, image.width / 2, 3 * image.width / 4].allSatisfy { column in
				let pixel = (row * image.width + column) * 4
				return abs(Int(pixels[pixel]) - 94) < 16 && abs(Int(pixels[pixel + 1]) - 92) < 16 && abs(Int(pixels[pixel + 2]) - 230) < 16
			}
		}
	}

	private func inkStart<V: View>(in host: SheetTestHost<V>, band: CGRect, columns: Range<Int>) throws -> CGFloat {
		try inkBounds(in: host, band: band, columns: columns).minX
	}

	private func labelBands<V: View>(in host: SheetTestHost<V>) throws -> [CGRect] {
		let image = try host.snapshot(host.view)
		let context = try pixelContext(image)
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		let scale = CGFloat(image.width) / host.view.bounds.width
		var bands: [CGRect] = []
		var first: Int?
		for row in Int(80 * scale)..<Int(215 * scale) {
			let background = (row * image.width + Int(220 * scale)) * 4
			let hasInk = (Int(55 * scale)..<Int(190 * scale)).contains { column in
				let pixel = (row * image.width + column) * 4
				return (0..<3).reduce(0) { $0 + abs(Int(pixels[pixel + $1]) - Int(pixels[background + $1])) } > 55
			}
			if hasInk {
				if first == nil { first = row }
			} else if let start = first {
				bands.append(CGRect(x: 0, y: host.view.bounds.height - CGFloat(row) / scale,
					width: host.view.bounds.width, height: CGFloat(row - start) / scale))
				first = nil
			}
		}
		return bands
	}

	private func inkBounds<V: View>(in host: SheetTestHost<V>, band: CGRect, columns: Range<Int>) throws -> CGRect {
		let image = try host.snapshot(host.view)
		let context = try pixelContext(image)
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		let scale = CGFloat(image.width) / host.view.bounds.width
		let top = Int((host.view.bounds.height - band.maxY - 3) * scale)
		let bottom = Int((host.view.bounds.height - band.minY + 3) * scale)
		var first: Int?, last: Int?
		for column in Int(CGFloat(columns.lowerBound) * scale)..<Int(CGFloat(columns.upperBound) * scale) {
			for row in top..<bottom {
				let pixel = (row * image.width + column) * 4
				let background = (row * image.width + Int(220 * scale)) * 4
				let contrast = (0..<3).reduce(0) { $0 + abs(Int(pixels[pixel + $1]) - Int(pixels[background + $1])) }
				if contrast > 55 {
					if first == nil { first = column }
					last = column
					break
				}
			}
		}
		guard let first, let last else { throw CocoaError(.coderValueNotFound) }
		return CGRect(x: CGFloat(first) / scale, y: band.minY,
			width: CGFloat(last - first + 1) / scale, height: band.height)
	}

	private func pixelContext(_ image: CGImage) throws -> CGContext {
		let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
			bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		return context
	}

	private func fixture() throws -> (VaultStore, MockKeychainService, UserDefaults, String) {
		let domain = "sidebar-project-order-" + UUID().uuidString
		let preferences = try #require(UserDefaults(suiteName: domain))
		let keychain = MockKeychainService()
		let projects = ["alpha", "middle", "zulu"].map {
			VaultProject(id: $0, name: $0.capitalized, path: "", environments: ["default": [:], "staging": [:]])
		}
		for project in projects {
			keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: project.environments)
		}
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), preferences: preferences, authTokenProvider: { _, _ in nil })
		store.projects = projects
		store.isUnlocked = true
		return (store, keychain, preferences, domain)
	}
}

@MainActor
private final class SidebarMarkerChanges {
	var count = 0
}

@MainActor
private final class SidebarTestDraggingSource: NSObject, NSDraggingSource {
	func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

@MainActor
private final class SidebarTestDraggingInfo: NSObject, NSDraggingInfo {
	private let source = SidebarTestDraggingSource()
	let draggingDestinationWindow: NSWindow?
	let draggingPasteboard: NSPasteboard
	let draggingLocation: NSPoint
	let draggingSourceOperationMask: NSDragOperation = .move
	let draggingSequenceNumber = 1
	var draggingSource: Any? { source }
	var draggedImageLocation: NSPoint { draggingLocation }
	nonisolated var draggedImage: NSImage? { nil }
	var draggingFormation: NSDraggingFormation = .default
	var animatesToDestination = false
	var numberOfValidItemsForDrop = 1
	var springLoadingHighlight: NSSpringLoadingHighlight { .none }

	init(window: NSWindow, pasteboard: NSPasteboard, location: NSPoint) {
		draggingDestinationWindow = window
		draggingPasteboard = pasteboard
		draggingLocation = location
	}

	func slideDraggedImage(to screenPoint: NSPoint) {}
	nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
	func resetSpringLoading() {}
	func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
		searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
		var stop: ObjCBool = false
		let items = draggingPasteboard.readObjects(forClasses: classes, options: searchOptions) ?? []
		for (index, object) in items.enumerated() {
			guard let item = object as? NSPasteboardWriting else { continue }
			block(NSDraggingItem(pasteboardWriter: item), index, &stop)
			if stop.boolValue { break }
		}
	}
}
