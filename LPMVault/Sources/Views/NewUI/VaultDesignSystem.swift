import AppKit
import SwiftUI

enum VaultPalette {
	static let titleBar = Color(hex: 0xF2F1F5)
	static let titleBarBorder = Color(hex: 0xDEDDE3)
	static let sidebar = Color(hex: 0xF7F7FA)
	static let sidebarBorder = Color(hex: 0xE4E3E9)
	static let content = Color.white
	static let inspector = Color(hex: 0xFAFAFC)

	static let textPrimary = Color(hex: 0x1C1C1E)
	static let textSecondary = Color(hex: 0x3C3C43)
	static let textTertiary = Color(hex: 0x6F6F75)
	static let textQuaternary = Color(hex: 0x717178)
	static let textFaint = Color(hex: 0x73737A)
	static let masked = Color(hex: 0x6B6B72)

	static let border = Color(hex: 0xDCDBE2)
	static let divider = Color(hex: 0xECEAF0)
	static let rowDivider = Color(hex: 0xF0EFF4)

	static let accent = Color(hex: 0x5E5CE6)
	static let accentHover = Color(hex: 0x7A78F0)
	static let accentTint = Color(hex: 0xECEAFC)
	static let accentText = Color(hex: 0x2C2B4A)
	static let accentDeep = Color(hex: 0x4B48D6)
	static let vaultChip = Color(hex: 0xE7E6EE)
	static let vaultChipText = Color(hex: 0x5B5A6E)

	static let green = Color(hex: 0x34C759)
	static let orange = Color(hex: 0xFF9F0A)
	static let red = Color(hex: 0xFF3B30)
	static let redText = Color(hex: 0xC8342B)
	static let greenTint = Color(hex: 0xE4F7E8)
	static let greenTintText = Color(hex: 0x1A7F37)
	static let orangeTint = Color(hex: 0xFFF1DE)
	static let orangeTintText = Color(hex: 0xA05A12)
	static let redTint = Color(hex: 0xFFE9E7)
	static let neutralTint = Color(hex: 0xECEAF0)

	static let rowSelected = Color(hex: 0xF6F5FD)
	static let rowHover = Color(hex: 0xFAFAFC)
	static let headerRow = Color(hex: 0xFAFAFC)
	static let sidebarHover = Color(hex: 0xEEEDF3)
	static let selectedEnvHeader = Color(hex: 0xF3F1FF)
	static let selectedEnvCell = Color(hex: 0xFAF9FF)

	static let avatarNeutral = Color(hex: 0xD9D8E4)
	static let avatarNeutralForeground = Color(hex: 0x5B5A6E)
	static let terminal = Color(hex: 0x1C1C1E)
	static let terminalText = Color(hex: 0xE8E8ED)

	static func environment(_ index: Int) -> Color {
		let colors = [green, orange, red, accent, Color(hex: 0x0A84FF), Color(hex: 0xAF52DE)]
		return colors[index % colors.count]
	}
}

enum VaultMetrics {
	static let titleBar: CGFloat = 46
	static let sidebar: CGFloat = 280
	static let sidebarMinimum: CGFloat = 280
	static let sidebarMaximum: CGFloat = 460
	static let inspector: CGFloat = 300
	static let inspectorMinimum: CGFloat = 280
	static let inspectorMaximum: CGFloat = 460
	static let sidebarDivider: CGFloat = 7
	static let inspectorDivider: CGFloat = 5
	static let contentMinimum: CGFloat = 420
	static let tableHeader: CGFloat = 34
	static let matrixRow: CGFloat = 44
	static let fileRow: CGFloat = 46
	static let statusBar: CGFloat = 30
	static let keyColumn: CGFloat = 230
	static let environmentColumn: CGFloat = 190
}

enum VaultTypography {
	static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
		.system(size: size, weight: weight, design: .monospaced)
	}

	static let sectionLabel = Font.system(size: 10.5, weight: .bold)
}

extension Color {
	init(hex: UInt, opacity: Double = 1) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255,
			opacity: opacity
		)
	}
}

extension View {
	func vaultSectionLabel(_ color: Color = VaultPalette.textQuaternary) -> some View {
		font(VaultTypography.sectionLabel)
			.tracking(0.95)
			.foregroundStyle(color)
	}

	func vaultPointingHand() -> some View {
		onHover { inside in
			if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
		}
	}
}

struct VaultHairline: View {
	var color: Color = VaultPalette.divider
	var axis: Axis = .horizontal

	var body: some View {
		Rectangle()
			.fill(color)
			.frame(
				width: axis == .vertical ? 1 : nil,
				height: axis == .horizontal ? 1 : nil
			)
	}
}

@MainActor
enum VaultBranding {
	#if SWIFT_PACKAGE
	private static let bundle = Bundle.module
	#else
	private static let bundle = Bundle.main
	#endif

	static let logo = loadImage(name: "lpm-vault", extension: "svg")
	static let appIcon = loadImage(name: "LPMVault", extension: "icns")

	private static func loadImage(name: String, extension fileExtension: String) -> NSImage {
		guard let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources"),
			let image = NSImage(contentsOf: url)
		else {
			preconditionFailure("Missing bundled LPM Vault artwork: \(name).\(fileExtension)")
		}
		return image
	}
}

struct VaultAppMark: View {
	var size: CGFloat = 20

	var body: some View {
		Image(nsImage: VaultBranding.logo)
			.resizable()
			.renderingMode(.original)
			.scaledToFit()
			.frame(width: size, height: size)
			.accessibilityHidden(true)
	}
}

struct VaultEnvSwatch: View {
	let color: Color
	var size: CGFloat = 7

	var body: some View {
		RoundedRectangle(cornerRadius: 2, style: .continuous)
			.fill(color)
			.frame(width: size, height: size)
	}
}

struct VaultStatusDot: View {
	let color: Color
	var size: CGFloat = 6

	var body: some View {
		Circle().fill(color).frame(width: size, height: size)
	}
}

struct VaultTagBadge: View {
	let text: String
	let foreground: Color
	let background: Color
	var size: CGFloat = 10

	var body: some View {
		Text(text)
			.font(.system(size: size, weight: .bold))
			.foregroundStyle(foreground)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(RoundedRectangle(cornerRadius: 4).fill(background))
			.fixedSize()
	}
}

struct VaultCountPill: View {
	let count: Int
	var tint = VaultPalette.accent

	var body: some View {
		Text("\(count)")
			.font(.system(size: 10.5, weight: .bold))
			.foregroundStyle(.white)
			.padding(.horizontal, 6)
			.padding(.vertical, 1)
			.background(Capsule().fill(tint))
	}
}

struct VaultBarButton: View {
	var systemImage: String?
	var title: String?
	var shortcut: String?
	var leadingDot: Color?
	var filled = false
	var invertsOnHover = false
	var disabled = false
	var height: CGFloat = 26
	let action: () -> Void

	@State private var hovering = false

	private var foreground: Color {
		if disabled { return VaultPalette.textFaint }
		if filled { return .white }
		return invertsOnHover && hovering ? .white : VaultPalette.textSecondary
	}

	private var background: Color {
		if disabled { return filled ? VaultPalette.accent.opacity(0.35) : .white.opacity(0.7) }
		if filled { return hovering ? VaultPalette.accentHover : VaultPalette.accent }
		if invertsOnHover && hovering { return VaultPalette.textPrimary }
		return hovering ? VaultPalette.sidebar : .white
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let leadingDot { VaultStatusDot(color: leadingDot) }
				if let systemImage {
					Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
				}
				if let title {
					Text(title).font(.system(size: 12, weight: filled ? .semibold : .regular))
				}
				if let shortcut {
					Text(shortcut)
						.font(VaultTypography.mono(10))
						.foregroundStyle(foreground == .white ? .white.opacity(0.7) : VaultPalette.textFaint)
				}
			}
			.foregroundStyle(foreground)
			.padding(.horizontal, filled ? 11 : 10)
			.frame(height: height)
			.background(RoundedRectangle(cornerRadius: 7).fill(background))
			.overlay {
				RoundedRectangle(cornerRadius: 7)
					.stroke(filled ? .clear : VaultPalette.border, lineWidth: 1)
			}
			.fixedSize()
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

struct VaultOutlineButton: View {
	var systemImage: String?
	var title: String?
	var help: String?
	var active = false
	var disabled = false
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
				if let title { Text(title).font(.system(size: 12)) }
			}
			.foregroundStyle(disabled ? VaultPalette.textFaint : (active ? VaultPalette.accent : VaultPalette.textSecondary))
			.padding(.horizontal, title == nil ? 0 : 10)
			.frame(width: title == nil ? 27 : nil, height: 27)
			.background {
				RoundedRectangle(cornerRadius: 7)
					.fill(active ? VaultPalette.accentTint : (hovering ? VaultPalette.sidebar : .clear))
			}
			.overlay {
				RoundedRectangle(cornerRadius: 7)
					.stroke(active ? VaultPalette.accent.opacity(0.35) : VaultPalette.border, lineWidth: 1)
			}
			.fixedSize()
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.help(help ?? title ?? "")
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

struct VaultRowIconButton: View {
	let systemImage: String
	var help = ""
	var destructive = false
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(
					hovering
						? (destructive ? VaultPalette.red : VaultPalette.textPrimary)
						: VaultPalette.textTertiary
				)
				.frame(width: 26, height: 26)
				.background {
					RoundedRectangle(cornerRadius: 6)
						.fill(hovering ? (destructive ? VaultPalette.redTint : VaultPalette.neutralTint) : .clear)
				}
		}
		.buttonStyle(.plain)
		.help(help)
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

struct VaultFilterChip: View {
	let title: String
	var dot: Color?
	var trailing: String?
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let dot { VaultStatusDot(color: dot) }
				Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
				if let trailing { Text(trailing).font(VaultTypography.mono(11)) }
			}
			.foregroundStyle(selected ? .white : VaultPalette.textSecondary)
			.padding(.horizontal, 11)
			.frame(height: 26)
			.background(Capsule().fill(selected ? VaultPalette.textPrimary : (hovering ? VaultPalette.sidebar : .clear)))
			.overlay { Capsule().stroke(selected ? .clear : VaultPalette.border, lineWidth: 1) }
			.fixedSize()
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

struct VaultInitialsAvatar: View {
	let initials: String
	var size: CGFloat = 26
	var square = false

	var body: some View {
		Text(initials)
			.font(.system(size: size * 0.42, weight: .bold))
			.foregroundStyle(VaultPalette.avatarNeutralForeground)
			.frame(width: size, height: size)
			.background {
				if square {
					RoundedRectangle(cornerRadius: size * 0.28).fill(VaultPalette.avatarNeutral)
				} else {
					Circle().fill(VaultPalette.avatarNeutral)
				}
			}
	}
}

struct VaultValueText: View {
	let text: String
	var masked = true
	var size: CGFloat = 12

	var body: some View {
		Text(text)
			.font(VaultTypography.mono(size))
			.tracking(masked ? 1.2 : 0)
			.foregroundStyle(masked ? VaultPalette.masked : VaultPalette.textSecondary)
			.lineLimit(1)
			.truncationMode(.tail)
			.accessibilityHidden(true)
	}
}
