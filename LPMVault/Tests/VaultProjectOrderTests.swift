import AppKit
import Foundation
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
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

		@Test("a dragged group lands once its leading edge passes the middle of the group it moves over",
			arguments: [(1, CGFloat(-14), 1), (1, -16, 0), (1, 14, 1), (1, 16, 2), (1, 46, 3), (0, 0, 0), (3, -100, 0)])
		func landing(sample: (Int, CGFloat, Int)) {
			let order = ["a", "b", "c", "d"]
			let frames = Dictionary(uniqueKeysWithValues: order.enumerated().map {
				($0.element, CGRect(x: 0, y: CGFloat($0.offset) * 30, width: 280, height: 30))
			})
			let (from, offset, expected) = sample
			#expect(VaultSidebarReorder.landing(from: from, order: order, frames: frames,
				origin: CGFloat(from) * 30, height: 30, offset: offset) == expected)
		}

		@Test("landing stops at a group whose place isn't known")
		func landingStopsAtUnknownGroups() {
			let order = ["a", "b", "c", "d"]
			let frames = ["a": CGRect(x: 0, y: 0, width: 280, height: 30), "b": CGRect(x: 0, y: 30, width: 280, height: 30),
				"d": CGRect(x: 0, y: 90, width: 280, height: 30)]
			#expect(VaultSidebarReorder.landing(from: 1, order: order, frames: frames, origin: 30, height: 30, offset: 46) == 1)
		}

		@Test("dragging near an edge scrolls toward it, faster the closer it gets, and never against the drag")
		func autoscrollVelocity() {
			let speed = VaultSidebarReorder.autoscrollSpeed
			func velocity(_ pointer: CGFloat, grab: CGFloat = 200, height: CGFloat = 400) -> CGFloat {
				VaultSidebarReorder.autoscrollVelocity(pointerY: pointer, grabY: grab, viewportHeight: height)
			}
			#expect(velocity(200) == 0)
			#expect(velocity(16) == -speed / 2)
			#expect(velocity(0) == -speed)
			#expect(velocity(-80) == -speed)
			#expect(velocity(384) == speed / 2)
			#expect(velocity(480) == speed)
			#expect(velocity(16, grab: 10) == 0, "A pointer moving down mustn't scroll up")
			#expect(velocity(390, grab: 395) == 0, "A pointer moving up mustn't scroll down")
			#expect(velocity(10, height: 80) == -speed / 2, "A short list narrows the edges to a quarter of its height")
			#expect(velocity(10, height: 0) == 0)
		}

		@Test("sidebar keys are ⌥↑, ⌥↓ and Esc, whatever flags arrow keys carry")
		func sidebarKeys() {
			#expect(VaultSidebarKeys.key(modifiers: .option, keyCode: 126) == .move(-1))
			#expect(VaultSidebarKeys.key(modifiers: [.option, .numericPad, .function], keyCode: 125) == .move(1))
			#expect(VaultSidebarKeys.key(modifiers: [], keyCode: 53) == .cancelDrag)
			#expect(VaultSidebarKeys.key(modifiers: [], keyCode: 126) == nil)
			#expect(VaultSidebarKeys.key(modifiers: [.option, .shift], keyCode: 126) == nil)
			#expect(VaultSidebarKeys.key(modifiers: .command, keyCode: 125) == nil)
			#expect(VaultSidebarKeys.key(modifiers: .option, keyCode: 53) == nil)
		}

		@Test("the drag model reports the move, the room it makes and where it lands, and forgets all of it once it ends")
		func reorderModel() {
			let order = ["a", "b", "c", "d"]
			let reorder = modelWithRows(order)
			reorder.drag("b", in: order, from: CGPoint(x: 100, y: 45), to: CGPoint(x: 100, y: 95))
			#expect(reorder.lift == VaultSidebarReorder.Lift(projectId: "b", order: order, from: 1, height: 30))
			#expect(reorder.offset == 50)
			#expect(reorder.target == 3)
			#expect([0, 1, 2, 3].map(reorder.shift(at:)) == [0, 0, -30, -30])
			#expect([0, 1, 2, 3].map(reorder.landingEdge(at:)) == [nil, nil, nil, .bottom])
			#expect(reorder.finish() == VaultSidebarReorder.Move(projectId: "b", targetId: "d", placement: .after))
			#expect(reorder.lift == nil && reorder.offset == 0 && reorder.landingEdge(at: 3) == nil)

			reorder.drag("c", in: order, from: CGPoint(x: 100, y: 75), to: CGPoint(x: 100, y: 20))
			#expect(reorder.target == 0)
			#expect([0, 1, 2, 3].map(reorder.shift(at:)) == [30, 30, 0, 0])
			#expect([0, 1, 2, 3].map(reorder.landingEdge(at:)) == [.top, nil, nil, nil])
			#expect(reorder.finish() == VaultSidebarReorder.Move(projectId: "c", targetId: "a", placement: .before))

			reorder.drag("b", in: order, from: CGPoint(x: 100, y: 45), to: CGPoint(x: 100, y: 900))
			#expect(reorder.offset == 60, "The group stops at the end of the list")
			reorder.drag("b", in: order, from: CGPoint(x: 100, y: 45), to: CGPoint(x: -20, y: 900))
			#expect(reorder.target == 1, "Outside the sidebar the drag lands where it began")
			#expect(reorder.autoscrollVelocity == 0)
			#expect(reorder.finish() == nil)
		}

		@Test("a cancelled drag ignores the rest of its gesture, and a new gesture starts afresh")
		func cancelledDrag() {
			let order = ["a", "b", "c"]
			let reorder = modelWithRows(order)
			#expect(!reorder.cancel())
			reorder.drag("a", in: order, from: CGPoint(x: 100, y: 15), to: CGPoint(x: 100, y: 60))
			#expect(reorder.target == 1)
			#expect(reorder.cancel())
			#expect(reorder.lift == nil)
			reorder.drag("a", in: order, from: CGPoint(x: 100, y: 15), to: CGPoint(x: 100, y: 80))
			#expect(reorder.lift == nil)
			#expect(reorder.finish() == nil)
			reorder.drag("a", in: order, from: CGPoint(x: 100, y: 15), to: CGPoint(x: 100, y: 60))
			#expect(reorder.lift?.projectId == "a")
			reorder.cancel(unlessShowing: order)
			#expect(reorder.lift != nil)
			reorder.cancel(unlessShowing: ["c", "a", "b"])
			#expect(reorder.lift == nil)
			reorder.end()
			reorder.drag("a", in: order, from: CGPoint(x: 100, y: 15), to: CGPoint(x: 100, y: 60))
			#expect(reorder.lift?.projectId == "a")
		}

		@Test("the lifted group stays under the pointer when the list scrolls or something above it changes size")
		func liftedGroupFollowsLayout() {
			let order = ["a", "b", "c"]
			let reorder = modelWithRows(order)
			reorder.drag("b", in: order, from: CGPoint(x: 100, y: 45), to: CGPoint(x: 100, y: 55))
			#expect(reorder.offset == 10)
			reorder.setContentTop(-20)
			#expect(reorder.offset == 30, "Scrolling 20 points carries the pointer 20 points further down the list")
			reorder.setFrame(CGRect(x: 0, y: 0, width: 280, height: 50), for: "a")
			reorder.setFrame(CGRect(x: 0, y: 80, width: 280, height: 30), for: "c")
			reorder.setFrame(CGRect(x: 0, y: 50, width: 280, height: 30), for: "b")
			#expect(reorder.offset == 10, "A taller group above pushes B's place down, and B stays where it was drawn")
			reorder.setFrame(CGRect(x: 0, y: 50, width: 280, height: 40), for: "b")
			#expect(reorder.lift?.height == 40)
		}

		@Test("a drag draws the landing line between the projects it would land between and leaves none once it ends",
			arguments: ["up", "down"])
		func dragMovesProject(direction: String) async throws {
			let (store, _, preferences, domain) = try fixture(count: 5)
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let rows = try labelBands(in: host)
			try #require(rows.count == 4, "Expected the first four of five project rows, got \(rows)")
			let pitch = rows[0].midY - rows[1].midY
			let up = direction == "up"
			// Far enough past the boundary that the lifted project no longer covers the line.
			let start = NSPoint(x: 140, y: up ? rows[0].midY - 4 * pitch : rows[0].midY)
			let end = NSPoint(x: 140, y: start.y + (up ? 2.27 : -2.27) * pitch)
			try drag(in: host, from: start, to: end, release: false)
			#expect(reorder.lift?.projectId == (up ? "zz-01" : "alpha"))
			#expect(reorder.target == 2)
			#expect(reorder.shift(at: 2) == (up ? 1 : -1) * (reorder.lift?.height ?? 0), "Zulu makes room for the dragged project")
			try await settleAnimations(in: host)
			let markers = try markerRows(in: host)
			if markers.isEmpty { RenderedText.saveDiagnostic(try host.snapshot(host.view), named: "sidebar-drag-\(direction)") }
			#expect((1...4).contains(markers.count), """
				One 2-point landing line marks the drop; offset \(reorder.offset), \
				frames \((reorder.lift?.order ?? []).compactMap { reorder.frames[$0] }), rows \(rows)
				""")
			let line = try lineCenter(in: host)
			// Zulu slides into the dragged project's place, so the line sits where that place met Zulu.
			let (below, above) = up ? (rows[3], rows[2]) : (rows[2], rows[1])
			#expect(line > below.maxY && line < above.minY, "Line at \(line) must fall between \(below) and \(above)")
			try mouse(.leftMouseUp, at: end, in: host)
			try await settleAnimations(in: host)
			#expect(try markerRows(in: host).isEmpty, "The landing line must not outlive the drag")
			#expect(reorder.lift == nil)
			let expected = up ? ["alpha", "middle", "zz-01", "zulu", "zz-00"] : ["middle", "zulu", "alpha", "zz-00", "zz-01"]
			#expect(store.visibleVaults(matching: "").map(\.id) == expected)
			#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == expected)
		}

		@Test("a drag that comes back to where it began moves nothing and draws no line")
		func dragBackMovesNothing() async throws {
			let (store, _, preferences, domain) = try fixture()
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let rows = try labelBands(in: host)
			try #require(rows.count == 3)
			let start = NSPoint(x: 140, y: rows[1].midY)
			try drag(in: host, from: start, to: NSPoint(x: 140, y: rows[0].midY + 4), release: false)
			#expect(reorder.target == 0)
			try drag(in: host, from: nil, to: NSPoint(x: 140, y: rows[1].midY + 6), release: false)
			#expect(reorder.target == 1)
			try await settleAnimations(in: host)
			#expect(try markerRows(in: host).isEmpty)
			try mouse(.leftMouseUp, at: NSPoint(x: 140, y: rows[1].midY + 6), in: host)
			try await host.settle()
			#expect(store.visibleVaults(matching: "").map(\.id) == ["alpha", "middle", "zulu"])
			#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["alpha", "middle", "zulu"])
		}

		@Test("Esc cancels a drag, and the rest of its gesture moves nothing")
		func escapeCancelsDrag() async throws {
			let (store, _, preferences, domain) = try fixture()
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let rows = try labelBands(in: host)
			try #require(rows.count == 3)
			try drag(in: host, from: NSPoint(x: 140, y: rows[2].midY), to: NSPoint(x: 140, y: rows[0].midY + 8), release: false)
			#expect(reorder.target == 0)
			try host.sendEscape()
			#expect(reorder.lift == nil)
			try drag(in: host, from: nil, to: NSPoint(x: 140, y: rows[0].midY + 12), release: true)
			try await settleAnimations(in: host)
			#expect(try markerRows(in: host).isEmpty)
			#expect(store.visibleVaults(matching: "").map(\.id) == ["alpha", "middle", "zulu"])
			#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["alpha", "middle", "zulu"])
		}

		@Test("releasing a drag outside the sidebar moves nothing")
		func releaseOutsideMovesNothing() async throws {
			let (store, _, preferences, domain) = try fixture()
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let rows = try labelBands(in: host)
			try #require(rows.count == 3)
			try drag(in: host, from: NSPoint(x: 140, y: rows[2].midY), to: NSPoint(x: 140, y: rows[0].midY + 8), release: false)
			#expect(reorder.target == 0)
			try drag(in: host, from: nil, to: NSPoint(x: -60, y: rows[0].midY + 8), release: false)
			#expect(reorder.target == 2)
			try await settleAnimations(in: host)
			#expect(try markerRows(in: host).isEmpty)
			try mouse(.leftMouseUp, at: NSPoint(x: -60, y: rows[0].midY + 8), in: host)
			try await host.settle()
			#expect(reorder.lift == nil)
			#expect(store.visibleVaults(matching: "").map(\.id) == ["alpha", "middle", "zulu"])
		}

		@Test("a click without a drag still opens the project")
		func clickOpensProject() async throws {
			let (store, _, preferences, domain) = try fixture()
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let rows = try labelBands(in: host)
			try #require(rows.count == 3)
			let point = NSPoint(x: 140, y: rows[1].midY)
			try mouse(.leftMouseDown, at: point, in: host)
			try mouse(.leftMouseDragged, at: NSPoint(x: point.x + 1, y: point.y), in: host)
			try mouse(.leftMouseUp, at: NSPoint(x: point.x + 1, y: point.y), in: host)
			#expect(try await host.waitUntil { store.selectedProjectId == "middle" })
			#expect(reorder.lift == nil)
			#expect(store.visibleVaults(matching: "").map(\.id) == ["alpha", "middle", "zulu"])
		}

		@Test("an expanded project makes room for its environments, and the line falls below them")
		func expandedProjectLanding() async throws {
			let (store, _, preferences, domain) = try fixture(count: 5)
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			store.openProject(id: "zulu")
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let rows = try labelBands(in: host)
			try #require(rows.count >= 3, "Expected Alpha, Middle and Zulu at least, got \(rows)")
			let alpha = try #require(reorder.frames["alpha"]), zulu = try #require(reorder.frames["zulu"])
			// Past the line by more than the lifted project's shadow reaches, short of the next landing.
			let end = NSPoint(x: 140, y: rows[0].midY - (zulu.maxY - alpha.height + 12))
			try drag(in: host, from: NSPoint(x: 140, y: rows[0].midY), to: end, release: false)
			#expect(reorder.target == 2)
			#expect(reorder.landingEdge(at: 2) == .bottom)
			try await settleAnimations(in: host)
			let line = try lineCenter(in: host)
			// Alpha's label sits at the middle of its row, which tells where list coordinates fall in the window.
			let expected = rows[0].midY - (zulu.maxY - alpha.height - alpha.midY)
			#expect(abs(line - expected) <= 1.5, "Line at \(line), expected below Zulu's environments at \(expected)")
			try mouse(.leftMouseUp, at: end, in: host)
			try await settleAnimations(in: host)
			#expect(store.visibleVaults(matching: "").map(\.id) == ["middle", "zulu", "alpha", "zz-00", "zz-01"])
		}

		@Test("dragging to an edge scrolls the list, and the project lands beyond what was visible")
		func dragAutoscrolls() async throws {
			let (store, _, preferences, domain) = try fixture(count: 30)
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, height: 320, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let scroller = try #require(subviews(of: VaultSidebarAutoscroll.ScrollerView.self, in: host.view).first)
			let scrollView = try #require(scroller.enclosingScrollView)
			let rows = try labelBands(in: host)
			try #require(rows.count >= 3)
			let first = store.visibleVaults(matching: "").map(\.id)[0]
			#expect(!scroller.isScrolling)
			let edge = NSPoint(x: 140, y: 6)
			try drag(in: host, from: NSPoint(x: 140, y: rows[0].midY), to: edge, release: false)
			#expect(reorder.autoscrollVelocity == VaultSidebarReorder.autoscrollSpeed)
			try await host.settle()
			#expect(scroller.isScrolling, "A display link drives the scrolling")
			// The display link pauses while the test's window is covered, so frames are stepped here.
			let end = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
			for _ in 0..<120 where scrollView.contentView.bounds.origin.y < end - 1 {
				scroller.advance(by: 1.0 / 60)
				try await host.settle()
			}
			#expect(scrollView.contentView.bounds.origin.y >= end - 1, "The list should scroll to its end while the pointer holds at the edge")
			try mouse(.leftMouseDragged, at: edge, in: host)
			try mouse(.leftMouseUp, at: edge, in: host)
			try await settleAnimations(in: host)
			let order = store.visibleVaults(matching: "").map(\.id)
			let landing = try #require(order.firstIndex(of: first))
			#expect(landing == order.count - 1, "\(first) landed at \(landing) of \(order.count)")
			#expect(reorder.autoscrollVelocity == 0)
			#expect(!scroller.isScrolling)
		}

		@Test("a drag ends when the projects it began with change", arguments: ["refresh", "account", "lock"])
		func dragEndsWhenProjectsChange(change: String) async throws {
			let (store, keychain, preferences, domain) = try fixture()
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let rows = try labelBands(in: host)
			try #require(rows.count == 3)
			let end = NSPoint(x: 140, y: rows[0].midY + 8)
			try drag(in: host, from: NSPoint(x: 140, y: rows[2].midY), to: end, release: false)
			#expect(reorder.target == 0)
			switch change {
			case "refresh":
				keychain.envStorage["newest"] = (name: "Newest", path: "", environments: ["default": [:]])
				await store.refreshLocalState()
			case "account":
				store.currentUser = LPMUser(id: "user", username: "user", name: nil, email: nil, avatarUrl: nil, plan: nil,
					createdAt: nil, orgs: [LPMOrg(id: "team-id", slug: "team", name: "Team", avatarUrl: nil, role: "owner")])
				store.selectAccount(.org("team"))
			default:
				store.lock()
			}
			try await host.settle()
			#expect(reorder.lift == nil)
			try drag(in: host, from: nil, to: NSPoint(x: 140, y: end.y + 4), release: true)
			try await settleAnimations(in: host)
			#expect(try markerRows(in: host).isEmpty)
			let saved = preferences.stringArray(forKey: VaultStore.projectOrderKey) ?? []
			#expect(saved.filter { ["alpha", "middle", "zulu"].contains($0) } == ["alpha", "middle", "zulu"])
		}

		@Test("⌥↑ and ⌥↓ move the selected project, but not while a field is being edited")
		func keyboardMoves() async throws {
			let (store, _, preferences, domain) = try fixture()
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			store.openProject(id: "middle")
			let host = sidebarHost(store)
			defer { host.window.close() }
			try await host.settle()
			try host.key("\u{F700}", code: 126, modifiers: [.option, .numericPad, .function], in: host.window)
			#expect(store.visibleVaults(matching: "").map(\.id) == ["middle", "alpha", "zulu"])
			try host.key("\u{F700}", code: 126, modifiers: [.option, .numericPad, .function], in: host.window)
			#expect(store.visibleVaults(matching: "").map(\.id) == ["middle", "alpha", "zulu"])
			for _ in 0..<3 { try host.key("\u{F701}", code: 125, modifiers: [.option, .numericPad, .function], in: host.window) }
			#expect(store.visibleVaults(matching: "").map(\.id) == ["alpha", "zulu", "middle"])
			try host.typeInFirstField("")
			try host.key("\u{F700}", code: 126, modifiers: [.option, .numericPad, .function], in: host.window)
			#expect(store.visibleVaults(matching: "").map(\.id) == ["alpha", "zulu", "middle"])
			#expect(preferences.stringArray(forKey: VaultStore.projectOrderKey) == ["alpha", "zulu", "middle"])
		}

		@Test("a project moved by keyboard past the visible rows scrolls into view")
		func keyboardMoveScrolls() async throws {
			let (store, _, preferences, domain) = try fixture(count: 30)
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			let order = store.visibleVaults(matching: "").map(\.id)
			store.openProject(id: order[0])
			let reorder = VaultSidebarReorder()
			let host = sidebarHost(store, height: 320, reorder: reorder)
			defer { host.window.close() }
			try await host.settle()
			let scrollView = try #require(subviews(of: VaultSidebarAutoscroll.ScrollerView.self, in: host.view).first?.enclosingScrollView)
			for _ in 0..<29 { try host.key("\u{F701}", code: 125, modifiers: [.option, .numericPad, .function], in: host.window) }
			#expect(store.visibleVaults(matching: "").map(\.id).last == order[0])
			// macOS 15 lays out the new order a turn later, so the wait needs the
			// project at the end of the list: its old place at the top is in view too.
			let visible = try await host.waitUntil {
				guard let frame = reorder.frames[order[0]], frame.minY > reorder.viewportSize.height else { return false }
				return reorder.contentTop + frame.minY >= -1 && reorder.contentTop + frame.maxY <= reorder.viewportSize.height + 1
			}
			#expect(visible, """
				The moved project should be scrolled into view: frame \(reorder.frames[order[0]].map(String.init(describing:)) ?? "none"), \
				content top \(reorder.contentTop), viewport \(reorder.viewportSize), clip \(scrollView.contentView.bounds)
				""")
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
			let projectStart = try inkStart(in: host, band: project, columns: 55..<150)
			var labelStarts: [CGFloat] = []
			for (label, band) in zip(["Schema", "New environment", ".env", ".env.staging"], bands.dropFirst()) {
				let icon = try inkBounds(in: host, band: band, columns: 48..<71)
				#expect(abs(icon.midX - projectStart - 3) <= 0.5, "\(label) icon center is \(icon.midX), expected \(projectStart + 3)")
				labelStarts.append(try inkStart(in: host, band: band, columns: 71..<200))
			}
			let spread = try #require(labelStarts.max()) - #require(labelStarts.min())
			#expect(spread <= 1, "Visible label starts: \(labelStarts)")
			let image = NSBitmapImageRep(cgImage: try host.snapshot(host.view))
			Attachment.record(try #require(image.representation(using: .png, properties: [:])), named: "sidebar-\(Int(width)).png")
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

		@Test("moving projects works in both directions and persists without changing selection")
		func movesAndPersists() async throws {
			let (store, keychain, preferences, domain) = try fixture()
			defer { store.lock(); preferences.removePersistentDomain(forName: domain) }
			store.openProject(id: "alpha")
			store.selectEnvironment("staging")
			let original = store.projects
			#expect(store.moveProject(id: "zulu", relativeTo: "alpha", placement: .before))
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

		@Test("self moves, missing projects, already adjacent moves and a locked vault leave preferences untouched")
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
			store.lock()
			#expect(!store.moveProject(id: "zulu", relativeTo: "alpha", placement: .before))
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

		private func modelWithRows(_ order: [String]) -> VaultSidebarReorder {
			let reorder = VaultSidebarReorder()
			reorder.setViewportSize(CGSize(width: 280, height: 500))
			for (index, id) in order.enumerated() {
				reorder.setFrame(CGRect(x: 0, y: CGFloat(index) * 30, width: 280, height: 30), for: id)
			}
			return reorder
		}

		private func sidebarHost(_ store: VaultStore, width: CGFloat = 280, height: CGFloat = 500,
			mode: VaultWorkspaceMode = .matrix, reorder: VaultSidebarReorder = VaultSidebarReorder()) -> SheetTestHost<some View> {
			SheetTestHost(VaultSidebarView(store: store, snapshots: [:], mode: .constant(mode),
				filter: .constant(.all), searchText: .constant(""), showsAccountSwitcher: .constant(false),
				onNewProject: {}, onCloudProjects: {}, onNewEnvironment: {}, onRenameProject: { _ in },
				onDeleteProject: { _ in }, onRenameEnvironment: { _ in }, onDuplicateEnvironment: { _ in },
				onClearEnvironment: { _ in }, onDeleteEnvironment: { _ in }, reorder: reorder),
				size: NSSize(width: width, height: height), keepsRequestedSize: true, usesHostingView: true)
		}

		/// Presses on `start`, when given, and drags through to `end` in steps, as a pointer does.
		private func drag<V: View>(in host: SheetTestHost<V>, from start: NSPoint?, to end: NSPoint, release: Bool) throws {
			var current = start ?? end
			if let start {
				try mouse(.leftMouseDown, at: start, in: host)
				current = start
			}
			let steps = 6
			let origin = current
			for step in 1...steps {
				let fraction = CGFloat(step) / CGFloat(steps)
				current = NSPoint(x: origin.x + (end.x - origin.x) * fraction, y: origin.y + (end.y - origin.y) * fraction)
				try mouse(.leftMouseDragged, at: current, in: host)
			}
			if release { try mouse(.leftMouseUp, at: end, in: host) }
		}

		private func mouse<V: View>(_ type: NSEvent.EventType, at point: NSPoint, in host: SheetTestHost<V>) throws {
			let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
				eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
			host.window.sendEvent(event)
		}

		/// Lets the 160-millisecond slides and fades of a drag finish, then settles.
		private func settleAnimations<V: View>(in host: SheetTestHost<V>) async throws {
			try await Task.sleep(for: .milliseconds(250))
			try await host.settle()
		}

		/// The landing line's center, in window coordinates.
		private func lineCenter<V: View>(in host: SheetTestHost<V>) throws -> CGFloat {
			let rows = try markerRows(in: host)
			let first = try #require(rows.first), last = try #require(rows.last)
			return host.view.bounds.height - CGFloat(first + last + 1) / 4
		}

		private func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
			((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { subviews(of: type, in: $0) }
		}

		/// Pixel rows, from the top at 2x, drawn in the accent's hue across the sidebar.
		/// Matching the hue, not the exact color, keeps the line found where the
		/// lifted project's shadow shades it, which macOS 15 draws farther out.
		private func markerRows<V: View>(in host: SheetTestHost<V>) throws -> [Int] {
			let image = try host.snapshot(host.view)
			let context = try pixelContext(image)
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			return (0..<image.height).filter { row in
				[image.width / 4, image.width / 2, 3 * image.width / 4].allSatisfy { column in
					let pixel = (row * image.width + column) * 4
					let red = Int(pixels[pixel]), green = Int(pixels[pixel + 1]), blue = Int(pixels[pixel + 2])
					return blue - red > 80 && blue - green > 80
				}
			}
		}

		private func inkStart<V: View>(in host: SheetTestHost<V>, band: CGRect, columns: Range<Int>) throws -> CGFloat {
			try inkBounds(in: host, band: band, columns: columns).minX
		}

		/// The rows of the sidebar's projects and children with text in them, from the top, in window coordinates.
		private func labelBands<V: View>(in host: SheetTestHost<V>) throws -> [CGRect] {
			let image = try host.snapshot(host.view)
			let context = try pixelContext(image)
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let scale = CGFloat(image.width) / host.view.bounds.width
			var bands: [CGRect] = []
			var first: Int?
			for row in Int(80 * scale)..<min(Int(215 * scale), image.height) {
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

		/// Alpha, Middle and Zulu, each with `.env` and `.env.staging`, then
		/// `count - 3` more projects named so they sort after them.
		private func fixture(count: Int = 3) throws -> (VaultStore, MockKeychainService, UserDefaults, String) {
			let domain = "sidebar-project-order-" + UUID().uuidString
			let preferences = try #require(UserDefaults(suiteName: domain))
			let keychain = MockKeychainService()
			let ids = ["alpha", "middle", "zulu"] + (0..<max(0, count - 3)).map { String(format: "zz-%02d", $0) }
			let projects = ids.map {
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
}
