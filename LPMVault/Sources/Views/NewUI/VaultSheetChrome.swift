import SwiftUI

struct VaultSheetCloseButton: View {
	var label = "Close"
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: "xmark")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(hovering ? VaultPalette.textPrimary : VaultPalette.textTertiary)
				.frame(width: 26, height: 26)
				.background(Circle().fill(hovering ? VaultPalette.border : VaultPalette.neutralTint))
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.vaultPointingHand()
		.help(label)
		.accessibilityLabel(label)
	}
}

/// Bottom bar of a sheet: helper content on the leading side, actions on the trailing side.
struct VaultSheetFooter<Leading: View, Actions: View>: View {
	@ViewBuilder let leading: Leading
	@ViewBuilder let actions: Actions

	var body: some View {
		VStack(spacing: 0) {
			VaultHairline()
			HStack(spacing: 8) {
				leading
					.frame(maxWidth: .infinity, alignment: .leading)
				actions
			}
			.frame(maxWidth: .infinity, alignment: .trailing)
			.padding(.horizontal, 24)
			.padding(.top, 14)
			.padding(.bottom, 18)
			.background(VaultPalette.headerRow)
		}
	}
}

struct VaultFieldLabel: View {
	let title: String

	var body: some View {
		Text(title)
			.font(.system(size: 12, weight: .semibold))
			.foregroundStyle(VaultPalette.textSecondary)
	}
}

extension View {
	/// Rounded input frame with the accent focus ring used by sheet fields.
	func vaultInputField(focused: Bool, invalid: Bool = false, background: Color = VaultPalette.control) -> some View {
		let stroke = invalid ? VaultPalette.red : (focused ? VaultPalette.accent : VaultPalette.border)
		return self
			.background(RoundedRectangle(cornerRadius: 8).fill(background))
			.overlay {
				RoundedRectangle(cornerRadius: 8)
					.stroke(stroke, lineWidth: focused || invalid ? 1.5 : 1)
			}
			.background {
				RoundedRectangle(cornerRadius: 10)
					.fill(focused ? (invalid ? VaultPalette.red : VaultPalette.accent).opacity(0.15) : .clear)
					.padding(-3)
			}
	}
}
