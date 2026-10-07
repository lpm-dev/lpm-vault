import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Workspace pane layout")
@MainActor
struct VaultPaneLayoutTests {
	@Test("the sidebar starts wide enough for its navigation labels")
	func sidebarDefaultWidth() {
		#expect(VaultMetrics.sidebar == 280)
		#expect(VaultMetrics.sidebarMinimum == 280)
	}

	@Test("layout stays bounded across window sizes and requested widths")
	func widthInvariants() {
		for available in stride(from: 0.0, through: 2000.0, by: 13.5) {
			for showsInspector in [false, true] {
				for sidebar in [-100.0, 280, 400, 460, 900] {
					for inspector in [-100.0, 280, 300, 460, 900] {
						let budget = VaultPaneBudget(available: available, requestedSidebar: sidebar,
							requestedInspector: inspector, showsInspector: showsInspector)
						let dividers = VaultMetrics.paneDivider * (showsInspector ? 2 : 1)
						let usable = max(0, available - dividers)
						#expect(abs(budget.sidebar.width + budget.inspector.width + budget.content - usable) < 0.0001)
						#expect(budget.content >= 0)
						for pane in [budget.sidebar, budget.inspector] {
							#expect(pane.minimum >= 0)
							#expect(pane.minimum <= pane.width)
							#expect(pane.width <= pane.maximum)
							#expect(pane.maximum <= 460)
						}
						let minimums = VaultMetrics.sidebarMinimum + (showsInspector ? VaultMetrics.inspectorMinimum : 0)
						if available >= minimums + VaultMetrics.contentMinimum + dividers {
							#expect(budget.content >= 420)
						}
					}
				}
			}
		}
	}

	@Test("native resize tracking reports a stable translation and resets between drags")
	func nativeDragLifecycle() throws {
		let view = VaultResizeTrackingView(frame: NSRect(x: 0, y: 0, width: 7, height: 400))
		var changes: [CGFloat] = []
		var ends: [CGFloat] = []
		view.onDragChanged = { changes.append($0) }
		view.onDragEnded = { ends.append($0) }
		view.mouseDragged(with: try event(.leftMouseDragged, x: 40))
		view.mouseUp(with: try event(.leftMouseUp, x: 40))
		#expect(changes.isEmpty && ends.isEmpty)
		view.mouseDown(with: try event(.leftMouseDown, x: 280))
		view.mouseDragged(with: try event(.leftMouseDragged, x: 310))
		view.frame.origin.x = 30
		view.mouseDragged(with: try event(.leftMouseDragged, x: 330))
		view.mouseUp(with: try event(.leftMouseUp, x: 335))
		view.mouseDragged(with: try event(.leftMouseDragged, x: 400))
		view.mouseDown(with: try event(.leftMouseDown, x: 500))
		view.mouseUp(with: try event(.leftMouseUp, x: 480))
		#expect(changes == [30, 50])
		#expect(ends == [55, -20])
		#expect(!view.acceptsFirstResponder)
		#expect(view.acceptsFirstMouse(for: nil))
	}

	@Test("workspace dividers resize accessibly and retain inspector width when reopened")
	func workspaceResizeAndReopen() async throws {
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		let project = VaultProject(id: "pane-test", name: "Layout Preview", path: "/tmp/layout-preview",
			environments: ["default": ["EXAMPLE_KEY": "example-value"]])
		store.isUnlocked = true
		defer { store.lock() }
		store.projects = [project]
		store.selectedProjectId = project.id
		for _ in 0..<1000 {
			if store.workspaceSnapshots[project.id] != nil { break }
			try await Task.sleep(for: .milliseconds(10))
		}
		_ = try #require(store.workspaceSnapshots[project.id])
		let host = NSHostingView(rootView: VaultWorkspaceView(store: store)
			.environment(UpdateChecker())
			.environment(\.colorScheme, .light))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
			styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }
		window.orderBack(nil)
		try await waitForLayout(host) { resizeViews(in: host).count == 1 }
		let sidebar = try #require(resizeViews(in: host).first)
		#expect(sidebar.accessibilityLabel() == "Resize sidebar")
		#expect(sidebar.accessibilityRole() == .splitter)
		#expect(sidebar.accessibilityValue() as? String == "280 points")
		#expect(sidebar.accessibilityPerformIncrement())
		try await waitForLayout(host) { sidebar.accessibilityValue() as? String == "300 points" }
		#expect(sidebar.accessibilityValue() as? String == "300 points")
		sidebar.onDragChanged?(50)
		try await waitForLayout(host) { sidebar.accessibilityValue() as? String == "350 points" }
		#expect(sidebar.accessibilityValue() as? String == "350 points")
		sidebar.onDragChanged?(100)
		try await waitForLayout(host) { sidebar.accessibilityValue() as? String == "400 points" }
		sidebar.onDragEnded?(100)
		try await waitForLayout(host) { sidebar.accessibilityValue() as? String == "400 points" }
		#expect(sidebar.accessibilityValue() as? String == "400 points")
		sidebar.onDragEnded?(-100)
		try await waitForLayout(host) { sidebar.accessibilityValue() as? String == "300 points" }
		#expect(sidebar.accessibilityValue() as? String == "300 points")
		try clickInspectorToggle(in: window, contentRightEdge: 1400)
		try await waitForLayout(host) { resizeViews(in: host).count == 2 }
		#expect(resizeViews(in: host).count == 2)
		let inspector = try #require(resizeViews(in: host).first { $0.accessibilityLabel() == "Resize inspector" })
		#expect(inspector.accessibilityValue() as? String == "300 points")
		#expect(inspector.accessibilityPerformIncrement())
		try await waitForLayout(host) { inspector.accessibilityValue() as? String == "320 points" }
		#expect(inspector.accessibilityValue() as? String == "320 points")
		inspector.onDragChanged?(-40)
		try await waitForLayout(host) { inspector.accessibilityValue() as? String == "360 points" }
		inspector.onDragEnded?(-40)
		try await waitForLayout(host) { inspector.accessibilityValue() as? String == "360 points" }
		#expect(inspector.accessibilityValue() as? String == "360 points")
		for expectedWidth in [340, 320] {
			#expect(inspector.accessibilityPerformDecrement())
			try await waitForLayout(host) { inspector.accessibilityValue() as? String == "\(expectedWidth) points" }
		}
		#expect(inspector.accessibilityValue() as? String == "320 points")
		try clickInspectorToggle(in: window, contentRightEdge: 1400 - 320 - VaultMetrics.paneDivider)
		try await waitForLayout(host) { resizeViews(in: host).count == 1 && inspector.onAdjust == nil }
		#expect(resizeViews(in: host).count == 1)
		#expect(!inspector.accessibilityPerformIncrement())
		#expect(inspector.onDragChanged == nil)
		#expect(inspector.onDragEnded == nil)
		try clickInspectorToggle(in: window, contentRightEdge: 1400)
		try await waitForLayout(host) { resizeViews(in: host).count == 2 }
		let reopened = try #require(resizeViews(in: host).first { $0.accessibilityLabel() == "Resize inspector" })
		#expect(reopened.accessibilityValue() as? String == "320 points")

		try recordWorkspace(host, named: "workspace-restored-panes")
		window.setContentSize(NSSize(width: 1040, height: 800))
		// Divider targets are centered on their hairlines; the content sits between the lines.
		try await waitForLayout(host) {
			let sidebarFrame = host.convert(sidebar.bounds, from: sidebar)
			let inspectorFrame = host.convert(reopened.bounds, from: reopened)
			return abs(inspectorFrame.midX - sidebarFrame.midX - VaultMetrics.paneDivider - 420) < 0.01
		}
		let sidebarFrame = host.convert(sidebar.bounds, from: sidebar)
		let inspectorFrame = host.convert(reopened.bounds, from: reopened)
		#expect(abs(inspectorFrame.midX - sidebarFrame.midX - VaultMetrics.paneDivider - 420) < 0.01)
		#expect(inspectorFrame.maxX < host.bounds.width)
		try recordWorkspace(host, named: "workspace-minimum-width")
		window.setContentSize(NSSize(width: 1400, height: 800))
		try await waitForLayout(host) { reopened.accessibilityValue() as? String == "320 points" }
		#expect(sidebar.accessibilityValue() as? String == "300 points")
		#expect(reopened.accessibilityValue() as? String == "320 points")
	}

	@Test("pane hairlines sit flush against their panes and stay easy to grab")
	func dividersAreFlushHairlines() async throws {
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		let project = VaultProject(id: "divider-test", name: "Divider Preview", path: "/tmp/divider-preview",
			environments: ["default": ["EXAMPLE_KEY": "example-value"]])
		store.isUnlocked = true
		defer { store.lock() }
		store.projects = [project]
		store.selectedProjectId = project.id
		for _ in 0..<1000 {
			if store.workspaceSnapshots[project.id] != nil { break }
			try await Task.sleep(for: .milliseconds(10))
		}
		let host = NSHostingView(rootView: VaultWorkspaceView(store: store)
			.environment(UpdateChecker())
			.environment(\.colorScheme, .light))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
			styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }
		window.orderBack(nil)
		try clickInspectorToggle(in: window, contentRightEdge: 1400)
		let lineCenters = [
			"Resize sidebar": VaultMetrics.sidebar + VaultMetrics.paneDivider / 2,
			"Resize inspector": host.bounds.width - VaultMetrics.inspector - VaultMetrics.paneDivider / 2,
		]
		// macOS 15 routes clicks to a newly inserted platform view only after
		// the window has displayed it; a person can only click what is on screen.
		try await waitForLayout(host) {
			let dividers = resizeViews(in: host)
			return dividers.count == 2 && dividers.allSatisfy { divider in
				let center = lineCenters[divider.accessibilityLabel() ?? ""] ?? -1
				return host.hitTest(NSPoint(x: center, y: host.bounds.midY)) === divider
			}
		}

		let dividers = resizeViews(in: host)
		#expect(dividers.count == 2)
		for divider in dividers {
			let label = divider.accessibilityLabel() ?? ""
			let lineCenter = try #require(lineCenters[label])
			let frame = host.convert(divider.bounds, from: divider)
			#expect(abs(frame.width - VaultMetrics.paneDividerHitWidth) < 0.01)
			#expect(abs(frame.midX - lineCenter) < 0.01, "\(label) is off its hairline")

			let reach = VaultMetrics.paneDividerHitWidth / 2
			for offset in [-(reach - 0.5), -2, 0, 2, reach - 0.5] {
				let point = NSPoint(x: lineCenter + offset, y: host.bounds.midY)
				#expect(host.hitTest(point) === divider, "\(label): \(offset) pt from the hairline misses the resize target")
			}
			for offset in [-(reach + 1), reach + 1] {
				let point = NSPoint(x: lineCenter + offset, y: host.bounds.midY)
				#expect(host.hitTest(point) !== divider, "\(label): \(offset) pt from the hairline still resizes the pane")
			}
		}
		try recordWorkspace(host, named: "workspace-flush-dividers")
	}

	/// Checks after every sleep, including one that a busy main thread stalls
	/// past the deadline, before giving up.
	private func waitForLayout<V: View>(_ host: NSHostingView<V>, until condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))
		while true {
			host.layoutSubtreeIfNeeded()
			host.displayIfNeeded()
			if condition() || ContinuousClock.now >= deadline { return }
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	private func recordWorkspace<V: View>(_ host: NSHostingView<V>, named name: String) throws {
		let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: bitmap)
		let data = try #require(bitmap.representation(using: .png, properties: [:]))
		Attachment.record(data, named: name + ".png")

	}

	private func resizeViews(in view: NSView) -> [VaultResizeTrackingView] {
		if let divider = view as? VaultResizeTrackingView {
			return ["Resize sidebar", "Resize inspector"].contains(divider.accessibilityLabel()) ? [divider] : []
		}
		return view.subviews.flatMap { resizeViews(in: $0) }
	}

	private func clickInspectorToggle(in window: NSWindow, contentRightEdge: CGFloat) throws {
		let location = NSPoint(x: contentRightEdge - 129.5, y: 723.5)
		try NativeTestClick.send(to: window, at: location)
	}

	private func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
		try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100),
			modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1))
	}
}

@Suite("Workspace table column layout")
@MainActor
struct VaultTableColumnLayoutTests {
	@Test("initial columns fill wide viewports and scroll in narrow ones", arguments: [CGFloat(420), 1200])
	func initialLayout(available: CGFloat) {
		let matrix = VaultTableColumnLayout(columns: [.key, .environment("default"), .environment("production")], available: available)
		#expect(matrix[.key] == VaultMetrics.keyColumn)
		#expect(matrix[.environment("default")] == matrix[.environment("production")])
		#expect(matrix.totalWidth == max(available, VaultMetrics.keyColumn + 2 * VaultMetrics.environmentColumn))
		let environment = VaultTableColumnLayout(columns: [.key, .value, .actions], available: available)
		#expect(environment[.value] == VaultMetrics.environmentValueColumn)
		#expect(environment[.actions] == VaultMetrics.environmentActionsColumn)
		#expect(environment.totalWidth == max(available, VaultMetrics.keyColumn + VaultMetrics.environmentValueColumn + VaultMetrics.environmentActionsColumn))
		for layout in [matrix, environment] {
			var position: CGFloat = 0
			for boundary in layout.boundaries {
				position += layout[boundary.id]
				#expect(boundary.position == position)
			}
			#expect(position == layout.totalWidth)
		}
	}

	@Test("resizing preserves neighboring widths and survives viewport changes", arguments: [false, true])
	func explicitWidths(singleEnvironment: Bool) {
		let columns: [VaultTableColumn] = singleEnvironment ? [.key, .value, .actions] : [.key, .environment("default"), .environment("production")]
		let original = VaultTableColumnLayout(columns: columns, available: 1200)
		var widths = VaultTableColumnWidths()
		widths.resize(.key, to: 350, in: original)
		for available in [CGFloat(420), 1600] {
			let layout = VaultTableColumnLayout(columns: columns, available: available, requested: widths.requested)
			#expect(layout[.key] == 350)
			for column in columns.dropFirst() { #expect(layout[column] == original[column]) }
			#expect(layout.totalWidth == original.totalWidth - original[.key] + 350)
		}
		let resized = VaultTableColumnLayout(columns: columns, available: 420, requested: widths.requested)
		widths.resize(columns[1], to: 500, in: resized)
		#expect(widths.requested[.key] == 350)
		#expect(widths.requested[columns[1]] == 500)
	}

	@Test("every column clamps shrinking at a usable minimum")
	func minimumWidths() {
		let columns: [VaultTableColumn] = [.key, .value, .actions, .environment("default")]
		let original = VaultTableColumnLayout(columns: columns, available: 1200)
		var widths = VaultTableColumnWidths()
		for column in columns { widths.resize(column, to: -100, in: original) }
		let layout = VaultTableColumnLayout(columns: columns, available: 420, requested: widths.requested)
		for column in columns { #expect(layout[column] == column.minimumWidth) }
		#expect(layout.totalWidth == columns.reduce(0) { $0 + $1.minimumWidth })
	}

	@Test("environment widths follow their identities through reorder, removal and insertion")
	func environmentIdentity() {
		let original = VaultTableColumnLayout(columns: [.key, .environment("default"), .environment("production")], available: 1200)
		var widths = VaultTableColumnWidths()
		widths.resize(.environment("production"), to: 700, in: original)
		let reordered = VaultTableColumnLayout(columns: [.key, .environment("production"), .environment("default")], available: 420, requested: widths.requested)
		#expect(reordered[.environment("production")] == 700)
		#expect(reordered[.environment("default")] == original[.environment("default")])
		#expect(reordered.boundaries.map(\.id) == [.key, .environment("production"), .environment("default")])
		let replaced = VaultTableColumnLayout(columns: [.key, .environment("production"), .environment("test")], available: 1600, requested: widths.requested)
		#expect(replaced[.environment("production")] == 700)
		#expect(replaced[.environment("test")] == VaultMetrics.environmentColumn)
		#expect(replaced.widths[.environment("default")] == nil)
	}
}
