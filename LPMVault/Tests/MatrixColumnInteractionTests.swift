import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Matrix columns out of view", .serialized)
	@MainActor
	struct MatrixColumnInteractionTests {
		private static let project = VaultProject(id: "p", name: "p", path: "", environments: [
			"default": ["API_URL": "https://api.acme.io", "PORT": "3000"],
			"production": ["API_URL": "https://api.acme.com", "PORT": "443"],
			"staging": ["API_URL": "https://staging.acme.io", "PORT": "8080"],
		])

		private func host(width: CGFloat) -> SheetTestHost<VaultContentView> {
			let project = Self.project
			return SheetTestHost(
				VaultContentView(
					project: project, snapshot: VaultWorkspaceSnapshot(project: project),
					environments: ["default", "production", "staging"], selectedEnvironment: "default",
					mode: .constant(.matrix), filter: .constant(.all),
					environmentViewMode: .constant(.table), sortOrder: .constant(.ascending),
					searchText: "",
					selectedKey: .constant(nil), revealedKeys: .constant(["API_URL", "PORT"]),
					showsInspector: .constant(false),
					columnWidths: .constant(VaultProjectTableColumnWidths()),
					isCopyingAll: false, cliAccess: nil,
					onCopyAll: {}, onImport: {}, onExport: {},
					valueChecks: .none, onAddSecret: {}, onCopySecret: { _, _ in },
					onDeleteSecret: { _, _ in }, onResizeColumns: {}
				), size: NSSize(width: width, height: 420), keepsRequestedSize: true)
		}

		/// The column header saying `title`, and how much of it is in view.
		private func header(_ title: String, in host: SheetTestHost<VaultContentView>) throws -> (frame: CGRect, shown: CGRect) {
			let header = try #require(AccessibilityTree.elements(in: host.window).first { $0.label == title })
			return (header.frame, header.visibleFrame)
		}

		private func stepControls(in host: SheetTestHost<VaultContentView>) -> [String] {
			AccessibilityTree.visibleElements(in: host.window, of: host.view).compactMap(\.label).filter { $0.hasPrefix("Show .env") }
		}

		@Test("columns that don't fit wait whole past the edge, named at the header's edge, and a click brings the nearest whole into view")
		func stepsToHiddenColumns() async throws {
			let host = host(width: 720)
			defer { host.window.close() }
			try await host.settle()

			#expect(try await host.waitForText("Show .env.staging", exactly: true))
			let staging = try header(".env.staging", in: host)
			#expect(staging.shown.width < 1, "Not a sliver of the column past the edge")
			let production = try header(".env.production", in: host)
			#expect(abs(production.shown.width - production.frame.width) < 1, "The last column shown is whole")

			try await host.click("Show .env.staging")
			#expect(try await host.waitForText("Show .env", exactly: true), "The column now under the key column is named at its edge")
			#expect(try await host.waitUntilRendered { stepControls(in: host) == ["Show .env"] }, "Nothing is past the edge any more")
			let shown = try header(".env.staging", in: host)
			#expect(abs(shown.shown.width - shown.frame.width) < 1, "The column stepped to is whole")

			try await host.click("Show .env")
			#expect(try await host.waitForText("Show .env.staging", exactly: true))
		}

		@Test("with room for every column, the matrix names none at its edges")
		func roomForEveryColumn() async throws {
			let host = host(width: 1100)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText(".env.staging", exactly: true))
			#expect(stepControls(in: host).isEmpty)
		}
	}
}
