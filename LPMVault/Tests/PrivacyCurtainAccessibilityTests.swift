import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Privacy curtain accessibility", .serialized)
	@MainActor
	struct PrivacyCurtainAccessibilityTests {
		@Observable
		final class Curtain {
			var isObscured = false
		}

		private struct Content: View {
			@State private var presses = 0

			var body: some View {
				HStack {
					Image(systemName: "info.circle").accessibilityHidden(true)
					Text("Visible words")
					Text("Decorative words").accessibilityHidden(true)
					Button("Pressed \(presses) times") { presses += 1 }
				}
			}
		}

		private struct Protected: View {
			let curtain: Curtain

			var body: some View {
				Content().vaultPrivacyProtected(curtain.isObscured)
			}
		}

		@Test("a protected view reads as it would unprotected, and under the curtain only the curtain is read")
		func curtainHidesOnlyWhileObscured() async throws {
			let plain = SheetTestHost(Content(), size: NSSize(width: 400, height: 120))
			defer { plain.window.close() }
			#expect(try await plain.waitForText("Visible words"))

			let curtain = Curtain()
			let host = SheetTestHost(Protected(curtain: curtain), size: NSSize(width: 400, height: 120))
			defer { host.window.close() }
			#expect(try await host.waitForText("Visible words"))
			#expect(AccessibilityTree.elements(in: host.window).map(\.role) == AccessibilityTree.elements(in: plain.window).map(\.role),
				"No group is added for VoiceOver to step into, and nothing a view hides is read")
			let shown = try await host.text()
			#expect(!shown.contains("Decorative words"))
			#expect(!shown.contains("Info"))

			try await host.click("Pressed 0 times")
			#expect(try await host.waitForText("Pressed 1 times"))
			curtain.isObscured = true
			#expect(try await host.waitForText("LPM Vault content hidden while the app is inactive"))
			let obscured = try await host.text()
			#expect(!obscured.contains("Visible words"))
			#expect(!obscured.contains("Pressed"))

			curtain.isObscured = false
			#expect(try await host.waitForText("Pressed 1 times"), "What the view held survives the curtain")
		}
	}
}
