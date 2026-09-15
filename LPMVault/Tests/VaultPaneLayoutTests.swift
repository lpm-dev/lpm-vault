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
						let dividers = showsInspector ? 12.0 : 7.0
						let usable = max(0, available - dividers)
						#expect(abs(budget.sidebar.width + budget.inspector.width + budget.content - usable) < 0.0001)
						#expect(budget.content >= 0)
						for pane in [budget.sidebar, budget.inspector] {
							#expect(pane.minimum >= 0)
							#expect(pane.minimum <= pane.width)
							#expect(pane.width <= pane.maximum)
							#expect(pane.maximum <= 460)
						}
						if available >= (showsInspector ? 992 : 707) {
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
		try clickInspectorToggle(in: window, contentRightEdge: 1075)
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
		try await waitForLayout(host) {
			let sidebarFrame = host.convert(sidebar.bounds, from: sidebar)
			let inspectorFrame = host.convert(reopened.bounds, from: reopened)
			return abs(inspectorFrame.minX - sidebarFrame.maxX - 420) < 0.01
		}
		let sidebarFrame = host.convert(sidebar.bounds, from: sidebar)
		let inspectorFrame = host.convert(reopened.bounds, from: reopened)
		#expect(abs(inspectorFrame.minX - sidebarFrame.maxX - 420) < 0.01)
		#expect(inspectorFrame.maxX < host.bounds.width)
		try recordWorkspace(host, named: "workspace-minimum-width")
		window.setContentSize(NSSize(width: 1400, height: 800))
		try await waitForLayout(host) { reopened.accessibilityValue() as? String == "320 points" }
		#expect(sidebar.accessibilityValue() as? String == "300 points")
		#expect(reopened.accessibilityValue() as? String == "320 points")
	}

	private func waitForLayout<V: View>(_ host: NSHostingView<V>, until condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		repeat {
			host.layoutSubtreeIfNeeded()
			if condition() { return }
			try await Task.sleep(for: .milliseconds(10))
		} while ContinuousClock.now < deadline
	}

	private func recordWorkspace<V: View>(_ host: NSHostingView<V>, named name: String) throws {
		let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: bitmap)
		let data = try #require(bitmap.representation(using: .png, properties: [:]))
		Attachment.record(data, named: name + ".png")

	}

	private func resizeViews(in view: NSView) -> [VaultResizeTrackingView] {
		if let divider = view as? VaultResizeTrackingView { return [divider] }
		return view.subviews.flatMap { resizeViews(in: $0) }
	}

	private func clickInspectorToggle(in window: NSWindow, contentRightEdge: CGFloat) throws {
		let location = NSPoint(x: contentRightEdge - 129.5, y: 723.5)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			let event = try #require(NSEvent.mouseEvent(with: type, location: location,
				modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
			window.sendEvent(event)
		}
	}

	private func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
		try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100),
			modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1))
	}
}
