import AppKit
import SwiftUI

enum VaultPalette {
	static let titleBar = adaptive(light: 0xF2F1F5, dark: 0x181818)
	static let titleBarBorder = adaptive(light: 0xDEDDE3, dark: 0x2B2B2B)
	static let sidebar = adaptive(light: 0xF7F7FA, dark: 0x232323)
	static let sidebarBorder = adaptive(light: 0xE4E3E9, dark: 0x2B2B2B)
	static let content = adaptive(light: 0xFFFFFF, dark: 0x181818)
	static let control = adaptive(light: 0xFFFFFF, dark: 0x292929)
	static let inspector = adaptive(light: 0xFAFAFC, dark: 0x232323)

	static let textPrimary = adaptive(light: 0x1C1C1E, dark: 0xFFFFFF)
	static let textSecondary = adaptive(light: 0x3C3C43, dark: 0xA3A3A3)
	static let textTertiary = adaptive(light: 0x6F6F75, dark: 0xA3A3A3)
	static let textQuaternary = adaptive(light: 0x717178, dark: 0xA3A3A3)
	static let textFaint = adaptive(light: 0x73737A, dark: 0xA3A3A3)
	static let masked = adaptive(light: 0x6B6B72, dark: 0xA3A3A3)

	static let border = adaptive(light: 0xDCDBE2, dark: 0x2B2B2B)
	static let divider = adaptive(light: 0xECEAF0, dark: 0x2B2B2B)
	static let rowDivider = adaptive(light: 0xF0EFF4, dark: 0x2B2B2B)

	static let accent = Color(hex: 0x5E5CE6)
	static let accentForeground = adaptive(light: 0x5E5CE6, dark: 0xB9B8FF)
	static let accentHover = adaptive(light: 0x7A78F0, dark: 0x6664E8)
	static let accentTint = adaptive(light: 0xECEAFC, dark: 0x29263D)
	static let accentText = adaptive(light: 0x2C2B4A, dark: 0xD5D4FF)
	static let accentDeep = adaptive(light: 0x4B48D6, dark: 0xB9B8FF)
	static let vaultChip = adaptive(light: 0xE7E6EE, dark: 0x292929)
	static let vaultChipText = adaptive(light: 0x5B5A6E, dark: 0xA3A3A3)

	static let green = Color(hex: 0x34C759)
	static let orange = Color(hex: 0xFF9F0A)
	static let red = Color(hex: 0xFF3B30)
	static let redText = adaptive(light: 0xC8342B, dark: 0xFF847D)
	static let greenTint = adaptive(light: 0xE4F7E8, dark: 0x233528)
	static let greenTintText = adaptive(light: 0x1A7F37, dark: 0x75DB94)
	static let orangeTint = adaptive(light: 0xFFF1DE, dark: 0x3B3020)
	static let orangeTintText = adaptive(light: 0xA05A12, dark: 0xFFC06A)
	static let redTint = adaptive(light: 0xFFE9E7, dark: 0x3D2423)
	static let neutralTint = adaptive(light: 0xECEAF0, dark: 0x292929)

	static let rowSelected = adaptive(light: 0xF6F5FD, dark: 0x292929)
	static let rowHover = adaptive(light: 0xFAFAFC, dark: 0x232323)
	static let headerRow = adaptive(light: 0xFAFAFC, dark: 0x232323)
	static let sidebarHover = adaptive(light: 0xEEEDF3, dark: 0x292929)
	static let selectedEnvHeader = adaptive(light: 0xF3F1FF, dark: 0x29263D)
	static let selectedEnvCell = adaptive(light: 0xFAF9FF, dark: 0x211F2E)

	static let strongFill = adaptive(light: 0x1C1C1E, dark: 0x5E5CE6)
	static let shadow = adaptive(light: 0x1C1C1E, dark: 0x000000)

	static let avatarNeutral = adaptive(light: 0xD9D8E4, dark: 0x292929)
	static let avatarNeutralForeground = adaptive(light: 0x5B5A6E, dark: 0xA3A3A3)
	static let terminal = adaptive(light: 0x1C1C1E, dark: 0x181818)
	static let terminalText = Color(hex: 0xE8E8ED)

	private static func adaptive(light: UInt, dark: UInt) -> Color {
		func color(_ hex: UInt) -> NSColor {
			NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
				green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
		}
		let lightColor = color(light)
		let darkColor = color(dark)
		return Color(nsColor: NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
		})
	}

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
		if disabled { return filled ? VaultPalette.accent.opacity(0.35) : VaultPalette.control.opacity(0.7) }
		if filled { return hovering ? VaultPalette.accentHover : VaultPalette.accent }
		if invertsOnHover && hovering { return VaultPalette.strongFill }
		return hovering ? VaultPalette.sidebar : VaultPalette.control
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
						.foregroundStyle(!disabled && (filled || (invertsOnHover && hovering)) ? .white.opacity(0.7) : VaultPalette.textFaint)
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
			.foregroundStyle(disabled ? VaultPalette.textFaint : (active ? VaultPalette.accentForeground : VaultPalette.textSecondary))
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
			.background(Capsule().fill(selected ? VaultPalette.strongFill : (hovering ? VaultPalette.sidebar : .clear)))
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
