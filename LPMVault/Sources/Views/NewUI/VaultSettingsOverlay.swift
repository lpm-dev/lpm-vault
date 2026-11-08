import SwiftUI

/// Settings and Platforms over the workspace, which stays as it was under a
/// dimmed backdrop: a menu of Settings' parts on the leading side, the part
/// chosen beside it, and a header naming it. Esc, the close button or a click
/// on the backdrop closes it.
struct VaultSettingsOverlay: View {
	@Bindable var store: VaultStore
	let category: VaultSettingsCategory

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	/// How far the panel sits in from the window's edges, as the design sets it,
	/// and the most it grows to in a large window.
	static let horizontalInset: CGFloat = 120
	static let topInset: CGFloat = 60
	static let bottomInset: CGFloat = 40
	static let maximumSize = CGSize(width: 1040, height: 760)
	static let menuWidth: CGFloat = 200
	static let headerHeight: CGFloat = 58

	var body: some View {
		GeometryReader { geometry in
			ZStack {
				VaultPalette.scrim
					.overlay { VaultClickCatcher { store.closeAccountPage() } }
					.accessibilityHidden(true)
				panel
					.frame(
						maxWidth: min(Self.maximumSize.width, max(0, geometry.size.width - 2 * Self.inset(for: geometry.size.width))),
						maxHeight: min(Self.maximumSize.height, max(0, geometry.size.height - Self.topInset - Self.bottomInset))
					)
					.padding(.top, Self.topInset - Self.bottomInset)
			}
			.frame(width: geometry.size.width, height: geometry.size.height)
		}
		// Esc closes it wherever focus is in the window, unless a sheet, such as a backup's, is over it.
		.background(VaultMenuKeys { key in
			guard key == .close else { return false }
			store.closeAccountPage()
			return true
		})
	}

	/// The side inset: the design's, short of what leaves the panel room for its menu and a readable column.
	static func inset(for width: CGFloat) -> CGFloat {
		min(horizontalInset, max(24, (width - 760) / 2))
	}

	private var panel: some View {
		VStack(spacing: 0) {
			header
			VaultHairline()
			HStack(spacing: 0) {
				menu
				VaultHairline(axis: .vertical)
				VaultSettingsContent(store: store, category: category)
					.id(category)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.background(VaultPalette.content)
		.clipShape(RoundedRectangle(cornerRadius: 12))
		.overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(VaultPalette.popoverBorder, lineWidth: 1) }
		.shadow(color: VaultPalette.shadow.opacity(0.22), radius: 28, y: 14)
		// A modal group: VoiceOver stays in it. Its header says what it is.
		.accessibilityElement(children: .contain)
		.accessibilityAddTraits(.isModal)
	}

	private var header: some View {
		HStack(spacing: 10) {
			HStack(spacing: 10) {
				Text("Settings")
					.foregroundStyle(VaultPalette.textTertiary)
				Text("/")
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
				Text(category.title)
					.foregroundStyle(VaultPalette.textPrimary)
					.accessibilityAddTraits(.isHeader)
			}
			.font(.system(size: 15, weight: .semibold))
			.lineLimit(1)
			Spacer(minLength: 12)
			closeButton
		}
		.padding(.horizontal, 20)
		.frame(height: Self.headerHeight)
	}

	private var closeButton: some View {
		Button { store.closeAccountPage() } label: {
			Image(systemName: "xmark")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(VaultPalette.textSecondary)
				.frame(width: 26, height: 26)
				.background(Circle().fill(VaultPalette.neutralTint))
		}
		.buttonStyle(VaultPressStyle(shape: Circle()))
		.help("Close (Esc)")
		.accessibilityLabel("Close Settings")
	}

	private var menu: some View {
		VStack(alignment: .leading, spacing: 1) {
			ForEach(VaultSettingsCategory.allCases) { item in
				VaultSettingsMenuRow(category: item, selected: item == category) { store.showSettings(item) }
			}
			Spacer(minLength: 12)
			VStack(alignment: .leading, spacing: 2) {
				Text("LPM Vault")
				Text(VaultBuildInfo().displayVersion)
					.lineLimit(2)
			}
			.font(.system(size: 11))
			.foregroundStyle(VaultPalette.textTertiary)
			.padding(.horizontal, 9)
			.padding(.bottom, 4)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 14)
		.frame(width: Self.menuWidth, alignment: .leading)
		.frame(maxHeight: .infinity)
		.background(VaultPalette.sidebar)
	}
}

/// Takes a click, as AppKit delivers it, whichever window is key.
private struct VaultClickCatcher: NSViewRepresentable {
	let action: () -> Void

	func makeNSView(context: Context) -> CatcherView { CatcherView() }

	func updateNSView(_ view: CatcherView, context: Context) {
		view.action = action
	}

	final class CatcherView: NSView {
		var action: () -> Void = {}

		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
		override func mouseDown(with event: NSEvent) { action() }
	}
}

private struct VaultSettingsMenuRow: View {
	let category: VaultSettingsCategory
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 9) {
				Image(systemName: category.systemImage)
					.font(.system(size: 12.5))
					.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
					.frame(width: 16)
					.accessibilityHidden(true)
				Text(category.title)
					.font(.system(size: 13, weight: selected ? .semibold : .regular))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 9)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 7).fill(selected ? VaultPalette.sidebarSelection : (hovering ? VaultPalette.sidebarHover : .clear)))
			.contentShape(Rectangle())
			.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle())
		.onHover { hovering = $0 }
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}
