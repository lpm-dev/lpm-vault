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

/// One choice in a `VaultMenuField`.
struct VaultMenuOption<Value: Hashable>: Identifiable {
	let value: Value
	let label: String
	var systemImage: String?
	/// Shown, but not chosen, as when the label says why it can't be.
	var disabled = false

	var id: Value { value }
}

/// A full-width field that opens a menu of choices, styled like the sheet's text fields.
struct VaultMenuField<Value: Hashable>: View {
	let title: String
	let options: [VaultMenuOption<Value>]
	@Binding var selection: Value?
	var placeholder = "Choose…"
	var disabled = false

	private var selected: VaultMenuOption<Value>? {
		selection.flatMap { value in options.first { $0.value == value } }
	}

	var body: some View {
		Menu {
			ForEach(options) { option in
				Button {
					selection = option.value
				} label: {
					if let systemImage = option.systemImage {
						Label(option.label, systemImage: systemImage)
					} else {
						Text(option.label)
					}
				}
				.disabled(option.disabled)
			}
		} label: {
			HStack(spacing: 7) {
				if let systemImage = selected?.systemImage {
					Image(systemName: systemImage).font(.system(size: 10)).foregroundStyle(VaultPalette.textPrimary)
				}
				Text(selected?.label ?? placeholder)
					.font(.system(size: 12.5))
					.foregroundStyle(selected == nil || disabled ? VaultPalette.textTertiary : VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer(minLength: 6)
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(VaultPalette.textQuaternary)
			}
			.padding(.horizontal, 10)
			.frame(height: 28)
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
			.vaultInputField(focused: false)
			// A menu drawn as a button otherwise makes each part of its label a menu of its own.
			.accessibilityElement(children: .combine)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.disabled(disabled)
		.accessibilityLabel(title)
		.accessibilityValue(selected?.label ?? placeholder)
	}
}
