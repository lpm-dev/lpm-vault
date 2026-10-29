import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Privacy curtain accessibility", .serialized)
	@MainActor
	struct PrivacyCurtainAccessibilityTests {
		private struct Protected: View {
			let isObscured: Bool

			var body: some View {
				HStack {
					Image(systemName: "info.circle").accessibilityHidden(true)
					Text("Visible words")
					Text("Decorative words").accessibilityHidden(true)
				}
				.vaultPrivacyProtected(isObscured)
			}
		}

		@Test("a protected sheet keeps what it hides from VoiceOver hidden, and hides everything under the curtain")
		func hiddenStaysHidden() async throws {
			let shown = SheetTestHost(Protected(isObscured: false), size: NSSize(width: 400, height: 120))
			defer { shown.window.close() }
			#expect(try await shown.waitForText("Visible words"))
			let text = try await shown.text()
			#expect(!text.contains("Decorative words"))
			#expect(!text.contains("Info"))

			let curtained = SheetTestHost(Protected(isObscured: true), size: NSSize(width: 400, height: 120))
			defer { curtained.window.close() }
			try await curtained.settle()
			#expect(try await !curtained.text().contains("Visible words"))
		}
	}
}
