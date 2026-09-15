import CoreGraphics
import Foundation
import Testing

@testable import LPMVault

@Suite("Workspace pane budget")
struct VaultPaneBudgetTests {
	private let dividers = VaultMetrics.sidebarDivider + VaultMetrics.inspectorDivider

	@Test("Requested widths survive when the window is wide enough")
	func honoursRequestedWidths() {
		let budget = VaultPaneBudget(
			available: 1400,
			requestedSidebar: 320,
			requestedInspector: 340,
			showsInspector: true
		)

		#expect(budget.sidebar.width == 320)
		#expect(budget.inspector.width == 340)
		#expect(budget.content == 1400 - dividers - 320 - 340)
	}

	@Test("Dragging one pane cannot push the other outside the window")
	func panesNeverOverflow() {
		for available in stride(from: 600.0, through: 2000.0, by: 37.0) {
			for sidebar in stride(from: 0.0, through: 900.0, by: 53.0) {
				for inspector in stride(from: 0.0, through: 900.0, by: 71.0) {
					for showsInspector in [true, false] {
						let budget = VaultPaneBudget(
							available: CGFloat(available),
							requestedSidebar: CGFloat(sidebar),
							requestedInspector: CGFloat(inspector),
							showsInspector: showsInspector
						)
						let used = budget.sidebar.width
							+ budget.inspector.width
							+ budget.content
							+ VaultMetrics.sidebarDivider
							+ (showsInspector ? VaultMetrics.inspectorDivider : 0)

						#expect(used <= CGFloat(available) + 0.001)
						#expect(budget.content >= 0)
						#expect(budget.sidebar.width >= budget.sidebar.minimum - 0.001)
						#expect(budget.sidebar.width <= budget.sidebar.maximum + 0.001)
						#expect(budget.inspector.width <= budget.inspector.maximum + 0.001)
						#expect(showsInspector || budget.inspector.width == 0)
					}
				}
			}
		}
	}

	@Test("Content keeps its reserved width at the smallest supported window")
	func contentKeepsMinimumWidth() {
		let budget = VaultPaneBudget(
			available: 1040,
			requestedSidebar: VaultMetrics.sidebarMaximum,
			requestedInspector: VaultMetrics.inspectorMaximum,
			showsInspector: true
		)

		#expect(budget.content >= VaultMetrics.contentMinimum)
		#expect(budget.sidebar.width >= VaultMetrics.sidebarMinimum)
		#expect(budget.inspector.width >= VaultMetrics.inspectorMinimum)
	}

	@Test("Dragging one divider leaves the other pane where it is")
	func draggingOneDividerKeepsTheOtherPane() {
		let available: CGFloat = 1160

		var sidebar = VaultMetrics.sidebar
		for _ in 0..<80 {
			let budget = VaultPaneBudget(
				available: available,
				requestedSidebar: sidebar,
				requestedInspector: 300,
				showsInspector: true
			)

			#expect(budget.inspector.width == 300)
			#expect(budget.content >= VaultMetrics.contentMinimum)
			#expect(budget.sidebar.width == sidebar)
			sidebar = VaultPaneBudget.clamp(
				sidebar + 10,
				minimum: budget.sidebar.minimum,
				maximum: budget.sidebar.maximum
			)
		}
		#expect(sidebar > VaultMetrics.sidebar)

		var inspector = VaultMetrics.inspector
		for _ in 0..<80 {
			let budget = VaultPaneBudget(
				available: available,
				requestedSidebar: 300,
				requestedInspector: inspector,
				showsInspector: true
			)

			#expect(budget.sidebar.width == 300)
			#expect(budget.content >= VaultMetrics.contentMinimum)
			#expect(budget.inspector.width == inspector)
			inspector = VaultPaneBudget.clamp(
				inspector + 10,
				minimum: budget.inspector.minimum,
				maximum: budget.inspector.maximum
			)
		}
		#expect(inspector > VaultMetrics.inspector)
	}

	@Test("A narrower window shrinks panes without dropping their stored widths")
	func narrowWindowShrinksPanesReversibly() {
		let narrow = VaultPaneBudget(
			available: 1040,
			requestedSidebar: 440,
			requestedInspector: 440,
			showsInspector: true
		)

		#expect(narrow.sidebar.width < 440)
		#expect(narrow.inspector.width < 440)
		#expect(narrow.content >= VaultMetrics.contentMinimum)

		let wide = VaultPaneBudget(
			available: 1600,
			requestedSidebar: 440,
			requestedInspector: 440,
			showsInspector: true
		)

		#expect(wide.sidebar.width == 440)
		#expect(wide.inspector.width == 440)
	}

	@Test("Hiding the inspector returns its width to the content pane")
	func hiddenInspectorFreesSpace() {
		let budget = VaultPaneBudget(
			available: 1200,
			requestedSidebar: 300,
			requestedInspector: 400,
			showsInspector: false
		)

		#expect(budget.inspector.width == 0)
		#expect(budget.content == 1200 - VaultMetrics.sidebarDivider - 300)
	}
}
