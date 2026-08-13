import SwiftUI

private let railColor = Color(nsColor: .underPageBackgroundColor)
private let listColor = Color(nsColor: .controlBackgroundColor)

struct ContentView: View {
	@Bindable var store: VaultStore
	@State private var updateChecker = UpdateChecker()
	@State private var listWidth: CGFloat = 240
	@GestureState private var dragOffset: CGFloat = 0

	var body: some View {
		Group {
			if store.isUnlocked {
				unlockedContent
			} else {
				lockScreen
			}
		}
	}

	private var lockScreen: some View {
		VStack(spacing: 16) {
			Image(systemName: "lock.fill")
				.font(.system(size: 48))
				.foregroundStyle(.secondary)

			Text("LPM Vault is Locked")
				.font(.title3)
				.fontWeight(.semibold)

			Text("Authenticate with Touch ID or your Mac password to unlock.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)

			Button {
				Task { await store.unlock() }
			} label: {
				Group {
					if store.isUnlocking {
						ProgressView("Unlocking…")
							.controlSize(.small)
					} else {
						Label("Unlock", systemImage: "touchid")
					}
				}
				.frame(minWidth: 120)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)
			.keyboardShortcut(.return, modifiers: [])
			.disabled(store.isUnlocking)
			.accessibilityHint("Shows the macOS authentication prompt")
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.frame(minWidth: 800, minHeight: 500)
	}

	private var effectiveListWidth: CGFloat {
		min(max(listWidth + dragOffset, 180), 360)
	}

	private var unlockedContent: some View {
		VStack(spacing: 0) {
			// Update banner
			if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
				HStack {
					Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
					Text("Update available: \(updateChecker.currentVersion) → \(latest)")
						.font(.callout)
					Spacer()
					if let url = updateChecker.releaseURL {
						Link("Download", destination: url).font(.callout.bold())
					}
					Button { updateChecker.updateAvailable = false } label: {
						Image(systemName: "xmark").font(.caption)
					}
					.buttonStyle(.plain)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 8)
				.background(.blue.opacity(0.1))
			}

			HStack(spacing: 0) {
				// Column 1: Account rail
				AccountRailView(store: store)
					.background(railColor)

				Divider()

				// Column 2: Vault list
				if store.showAuthStatus {
					AuthStatusView(store: store)
						.frame(width: effectiveListWidth)
						.background(listColor)
				} else {
					VaultListView(store: store)
						.frame(width: effectiveListWidth)
						.background(listColor)
						.tint(Color(hex: 0x17793A))
				}

				// Resize handle
				Color.clear
					.frame(width: 6)
					.overlay(Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 1))
					.contentShape(Rectangle())
					.gesture(
						DragGesture(minimumDistance: 1, coordinateSpace: .global)
							.updating($dragOffset) { value, state, _ in state = value.translation.width }
							.onEnded { value in listWidth = min(max(listWidth + value.translation.width, 180), 360) }
					)
					.onHover { hovering in
						if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
					}

				// Column 3: Vault detail
				VaultDetailView(store: store)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.frame(minWidth: 800, minHeight: 500)
			.onChange(of: store.selectedAccount) { _, _ in store.resetAutoLock() }
			.onChange(of: store.selectedProjectId) { _, _ in store.resetAutoLock() }
		}
		.task { await updateChecker.checkForUpdate() }
		.sheet(isPresented: $store.showKeyApprovalSheet) {
			KeyApprovalSheet(store: store)
		}
	}
}

// MARK: - Color Hex Extension

extension Color {
	init(hex: UInt, opacity: Double = 1.0) {
		self.init(
			red: Double((hex >> 16) & 0xFF) / 255.0,
			green: Double((hex >> 8) & 0xFF) / 255.0,
			blue: Double(hex & 0xFF) / 255.0,
			opacity: opacity
		)
	}
}
