import SwiftUI

struct SecretGeneratorButton: View {
	var disabled = false
	let onGenerate: (String) -> Void

	@State private var showsGenerator = false
	@State private var kind: SecretValueKind = .base64
	@State private var length = SecretValueGenerator.defaultLength

	var body: some View {
		Button { showsGenerator.toggle() } label: {
			HStack(spacing: 5) {
				Image(systemName: "sparkles")
					.font(.system(size: 11, weight: .semibold))
				Text("Generate")
					.font(.system(size: 12, weight: .semibold))
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
			}
			.foregroundStyle(VaultPalette.accentDeep)
			.padding(.horizontal, 9)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.accentTint))
			.fixedSize()
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.vaultPointingHand()
		.accessibilityLabel("Generate value")
		.popover(isPresented: $showsGenerator, arrowEdge: .trailing) {
			SecretGeneratorPanel(kind: $kind, length: $length) {
				guard !disabled else { return }
				onGenerate(SecretValueGenerator.generate(kind, length: length))
			}
			.disabled(disabled)
		}
		.onChange(of: disabled) { _, disabled in
			if disabled { showsGenerator = false }
		}
		.onDisappear { showsGenerator = false }
	}
}

struct SecretGeneratorPanel: View {
	@Binding var kind: SecretValueKind
	@Binding var length: Int
	let onGenerate: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Text("GENERATE VALUE")
				.vaultSectionLabel()
				.padding(.horizontal, 8)
				.padding(.top, 5)
				.padding(.bottom, 6)

			ForEach(SecretValueKind.allCases) { candidate in
				GeneratorKindRow(
					tag: candidate.tag,
					title: candidate.title,
					subtitle: candidate.subtitle(length: length),
					usesMonospacedSubtitle: candidate.hasCommandSubtitle,
					selected: candidate == kind
				) {
					kind = candidate
					onGenerate()
				}
			}

			Rectangle()
				.fill(VaultPalette.divider)
				.frame(height: 1)
				.padding(.horizontal, 4)
				.padding(.vertical, 5)

			lengthRow
				.opacity(kind.lengthUnit == nil ? 0.4 : 1)
				.disabled(kind.lengthUnit == nil)

			HStack(spacing: 6) {
				Text("Generated locally, never sent.")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textFaint)
					.lineLimit(1)
				Spacer(minLength: 6)
				Button(action: onGenerate) {
					Label("Regenerate", systemImage: "arrow.clockwise")
						.labelStyle(TrailingIconLabelStyle())
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(VaultPalette.accentForeground)
				}
				.buttonStyle(.plain)
				.vaultPointingHand()
			}
			.padding(.horizontal, 8)
			.padding(.top, 4)
			.padding(.bottom, 6)
		}
		.padding(6)
		.frame(width: 300)
		.background(VaultPalette.control)
	}

	private var lengthRow: some View {
		HStack(spacing: 10) {
			Text("Length")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
			Spacer(minLength: 0)
			HStack(spacing: 0) {
				ForEach(Array(SecretValueGenerator.presetLengths.enumerated()), id: \.element) { index, preset in
					if index > 0 { segmentDivider }
					Button { select(length: preset) } label: {
						segmentLabel("\(preset)", selected: length == preset)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("\(preset) \(kind.lengthUnit?.label ?? "")")
				}
				segmentDivider
				Menu {
					ForEach(SecretValueGenerator.additionalLengths, id: \.self) { option in
						Button("\(option)") { select(length: option) }
					}
				} label: {
					segmentLabel(customLengthLabel, selected: !SecretValueGenerator.presetLengths.contains(length))
				}
				.menuStyle(.button)
				.buttonStyle(.plain)
				.menuIndicator(.hidden)
				.fixedSize()
				.accessibilityLabel("Other length")
			}
			.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
			.clipShape(RoundedRectangle(cornerRadius: 6))
			Text(kind.lengthUnit?.label ?? "bytes")
				.font(.system(size: 10.5))
				.foregroundStyle(VaultPalette.textFaint)
				.frame(width: 58, alignment: .leading)
		}
		.padding(.horizontal, 8)
		.padding(.top, 6)
		.padding(.bottom, 4)
	}

	private var customLengthLabel: String {
		SecretValueGenerator.presetLengths.contains(length) ? "…" : "\(length)"
	}

	private var segmentDivider: some View {
		Rectangle().fill(VaultPalette.border).frame(width: 1, height: 20)
	}

	private func segmentLabel(_ text: String, selected: Bool) -> some View {
		Text(text)
			.font(VaultTypography.mono(11, selected ? .bold : .regular))
			.foregroundStyle(selected ? .white : VaultPalette.masked)
			.padding(.horizontal, 8)
			.frame(height: 20)
			.background(selected ? VaultPalette.strongFill : .clear)
			.contentShape(Rectangle())
	}

	private func select(length newLength: Int) {
		length = newLength
		if kind.lengthUnit != nil { onGenerate() }
	}
}

private struct GeneratorKindRow: View {
	let tag: String
	let title: String
	let subtitle: String
	let usesMonospacedSubtitle: Bool
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Text(tag)
					.font(VaultTypography.mono(10, .bold))
					.foregroundStyle(selected ? VaultPalette.accentDeep : VaultPalette.masked)
					.frame(width: 30)
				VStack(alignment: .leading, spacing: 1) {
					Text(title)
						.font(.system(size: 12.5, weight: selected ? .semibold : .regular))
						.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textPrimary)
					Text(subtitle)
						.font(usesMonospacedSubtitle ? VaultTypography.mono(10.5) : .system(size: 10.5))
						.foregroundStyle(VaultPalette.textFaint)
						.lineLimit(1)
				}
				Spacer(minLength: 0)
				if selected {
					Image(systemName: "checkmark")
						.font(.system(size: 10, weight: .bold))
						.foregroundStyle(VaultPalette.accentForeground)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 7)
			.contentShape(Rectangle())
			.background(
				RoundedRectangle(cornerRadius: 7)
					.fill(selected ? VaultPalette.accentTint : (hovering ? VaultPalette.neutralTint : .clear))
			)
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

private struct TrailingIconLabelStyle: LabelStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 4) {
			configuration.title
			configuration.icon
		}
	}
}

private extension SecretValueKind {
	var tag: String {
		switch self {
		case .base64: "b64"
		case .hex: "hex"
		case .uuid: "uuid"
		case .alphanumeric: "a-Z9"
		case .password: "@%^"
		}
	}

	var title: String {
		switch self {
		case .base64: "Base64 random"
		case .hex: "Hexadecimal"
		case .uuid: "UUID v4"
		case .alphanumeric: "Alphanumeric"
		case .password: "Password"
		}
	}

	var hasCommandSubtitle: Bool {
		self == .base64 || self == .hex
	}

	func subtitle(length: Int) -> String {
		switch self {
		case .base64: "openssl rand -base64 \(length)"
		case .hex: "openssl rand -hex \(length)"
		case .uuid: "Random, RFC 9562"
		case .alphanumeric: "URL-safe, no symbols"
		case .password: "Letters, digits, symbols"
		}
	}
}
