import SwiftUI

struct VaultSheetCloseButton: View {
	var label = "Close"
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: "xmark")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(hovering ? VaultPalette.textPrimary : VaultPalette.textTertiary)
				.frame(width: 28, height: 28)
				.background(Circle().fill(hovering ? VaultPalette.controlHover : .clear))
				.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle(shape: Circle()))
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
			.padding(.vertical, 16)
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
	/// Rounded input frame used by sheet fields. Focus draws one crisp accent
	/// border inside the frame, never a halo around it.
	func vaultInputField(focused: Bool, invalid: Bool = false, background: Color = VaultPalette.control) -> some View {
		let stroke = invalid ? VaultPalette.problemMark : (focused ? VaultPalette.focusRing : VaultPalette.inputBorder)
		return self
			.background(RoundedRectangle(cornerRadius: 7).fill(background))
			.overlay {
				RoundedRectangle(cornerRadius: 7)
					.strokeBorder(stroke, lineWidth: focused ? 2 : 1)
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

	@FocusState private var focused: Bool
	@State private var hovering = false

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
			.frame(height: 30)
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
			.vaultInputField(focused: focused, background: hovering && !disabled ? VaultPalette.controlHover : VaultPalette.control)
			.vaultHoverAnimation(hovering)
			// A menu drawn as a button otherwise makes each part of its label a menu of its own.
			.accessibilityElement(children: .combine)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.focusEffectDisabled()
		.focused($focused)
		.onHover { hovering = $0 }
		.disabled(disabled)
		.accessibilityLabel(title)
		.accessibilityValue(selected?.label ?? placeholder)
	}
}

/// A caution in a sheet or panel: amber text that stays readable on light
/// and dark backgrounds, with a warning glyph so it isn't said by color alone.
struct VaultInlineWarning: View {
	let text: String

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 7) {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.system(size: 10.5))
				.foregroundStyle(VaultPalette.warningMark)
				.accessibilityHidden(true)
			Text(text)
				.foregroundStyle(VaultPalette.textPrimary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		}
		.font(.system(size: 11.5))
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.orangeTint))
		.accessibilityElement(children: .combine)
	}
}
