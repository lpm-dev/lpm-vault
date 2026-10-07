import AppKit
import CoreTransferable
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import LPMVault

@Suite("Sidebar project order", .serialized)
@MainActor
struct VaultProjectOrderTests {
	@Test("project drag data is available only inside this process")
	func projectDragVisibility() {
		if #available(macOS 15.2, *) {
			#expect(VaultSidebarProjectDrag.exportedContentTypes(visibility: .all).isEmpty)
			#expect(VaultSidebarProjectDrag.exportedContentTypes(visibility: .ownProcess) == [VaultSidebarProjectDrag.contentType])
		}
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
		let alpha = try await host.labelFrame("Alpha")
		let staging = try await host.labelFrame(".env.staging")
		let middle = try await host.labelFrame("Middle")
		let point = NSPoint(x: alpha.midX, y: alpha.minY + 1)
		func dropViews(in view: NSView) -> [NSView] {
			let own = view.registeredDraggedTypes.isEmpty ? [] : [view]
			return own + view.subviews.flatMap { dropViews(in: $0) }
		}
		let target = try #require(dropViews(in: host.view).filter { $0.convert($0.bounds, to: nil).contains(point) }
			.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
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
		#expect(markerY > middle.maxY)
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

	@Test("the native item provider decodes a project drag and rejects malformed data", arguments: [false, true])
	func nativeDrop(malformed: Bool) async throws {
		let (store, _, preferences, domain) = try fixture()
		defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
		let drag = VaultSidebarProjectDrag(projectId: "zulu", sessionId: store.sidebarDragSessionId)
		let data = malformed ? Data("invalid".utf8) : try JSONEncoder().encode(drag)
		let provider = NSItemProvider()
		provider.registerDataRepresentation(forTypeIdentifier: VaultSidebarProjectDrag.contentType.identifier, visibility: .ownProcess) { completion in
			completion(data, nil)
			return nil
		}
		let delegate = VaultSidebarProjectDropDelegate(store: store, projectId: "alpha", rowHeight: 30, placement: .constant(nil))
		#expect(await delegate.loadDrop(from: provider, placement: .before) == !malformed)
		#expect(store.visibleVaults(matching: "").map(\.id) == (malformed ? ["alpha", "middle", "zulu"] : ["zulu", "alpha", "middle"]))
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
		let delegate = VaultSidebarProjectDropDelegate(store: store, projectId: "alpha", rowHeight: 30, placement: .constant(nil))
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
private final class SidebarTestDraggingInfo: NSObject, NSDraggingInfo {
	let draggingDestinationWindow: NSWindow?
	let draggingPasteboard: NSPasteboard
	let draggingLocation: NSPoint
	let draggingSourceOperationMask: NSDragOperation = .move
	let draggingSequenceNumber = 1
	var draggingSource: Any? { nil }
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
		for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
			block(NSDraggingItem(pasteboardWriter: item), index, &stop)
			if stop.boolValue { break }
		}
	}
}
