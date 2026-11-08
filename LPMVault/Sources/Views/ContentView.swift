import SwiftUI

struct ContentView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured

	var body: some View {
		Group {
			if store.isUnlocked {
				VaultWorkspaceView(store: store)
			} else {
				lockScreen
			}
		}
		.simultaneousGesture(
			TapGesture().onEnded { store.recordUserActivity() },
			including: .all
		)
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			Task { await store.refreshLocalState() }
		}
		.background(VaultWindowConfigurator())
		.sheet(isPresented: $store.showKeyApprovalSheet) {
			KeyApprovalSheet(store: store)
				.vaultPrivacyProtected(isObscured)
		}
	}

	private var lockScreen: some View {
		VStack(spacing: 0) {
			HStack {
				VaultTrafficLights()
				Spacer()
			}
			.padding(.horizontal, 14)
			.frame(height: VaultMetrics.titleBar)
			.background {
				VaultPalette.titleBar
				VaultWindowDragArea()
			}

			VStack(spacing: 16) {
				VaultAppMark(size: 56)

				VStack(spacing: 5) {
					Text("LPM Vault is Locked")
						.font(.system(size: 20, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)

					Text("Authenticate with Touch ID or your Mac password to unlock.")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
				}

				VaultBarButton(
					systemImage: store.isUnlocking ? nil : "touchid",
					title: store.isUnlocking ? "Unlocking…" : "Unlock",
					shortcut: store.isUnlocking ? nil : "⌘L",
					filled: true,
					disabled: store.isUnlocking,
					height: 32
				) {
					Task { await store.unlock() }
				}
				.keyboardShortcut(.return, modifiers: [])
				.accessibilityHint("Shows the macOS authentication prompt")
				if let failure = store.unlockFailure {
					VaultLoadErrorView(failure: failure)
				}
				VaultHairline().padding(.top, 6)
				Text("Saved values stay encrypted in this Mac’s Keychain.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.multilineTextAlignment(.center)
			}
			.padding(.horizontal, 40)
			.padding(.top, 36)
			.padding(.bottom, 24)
			.frame(width: 440)
			// One card on the window's quiet surface, so the screen has a center.
			.background(RoundedRectangle(cornerRadius: 12).fill(VaultPalette.content))
			.overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(VaultPalette.border, lineWidth: 1) }
			// Sits a little above the middle, where the eye takes the middle to be.
			.padding(.bottom, 96)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.background(VaultPalette.titleBar)
		.frame(minWidth: 1040, minHeight: 640)
		.ignoresSafeArea(.container, edges: .top)
	}
}

struct VaultLoadErrorView: View {
	let failure: VaultLoadFailure
	var retry: (() -> Void)?

	var body: some View {
		VStack(spacing: 12) {
			Text(failure.message)
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
			HStack(spacing: 16) {
				if let retry { VaultBarButton(title: "Retry", filled: true, height: 30, action: retry) }
				Link("Support", destination: URL(string: "https://github.com/lpm-dev/lpm-vault/blob/main/SUPPORT.md")!)
			}
		}
		.frame(maxWidth: 420)
		.padding(20)
		.accessibilityElement(children: .contain)
	}
}
