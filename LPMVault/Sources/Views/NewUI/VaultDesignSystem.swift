import AppKit
import SwiftUI

enum VaultPalette {
	static let titleBar = adaptive(light: 0xFAFAFC, dark: 0x101010)
	static let titleBarBorder = adaptive(light: 0xDCDBE2, dark: 0x262626)
	static let sidebar = adaptive(light: 0xF7F7FA, dark: 0x101010)
	static let sidebarBorder = adaptive(light: 0xE4E3E9, dark: 0x262626)
	static let content = adaptive(light: 0xFFFFFF, dark: 0x0A0A0A)
	static let control = adaptive(light: 0xFFFFFF, dark: 0x101010)
	static let inspector = adaptive(light: 0xFAFAFC, dark: 0x101010)

	// Dark text is white at two strengths, so it takes on the tint of what it sits on.
	static let textPrimary = adaptive(light: 0x1C1C1E, dark: 0xFFFFFF, darkOpacity: 0.8)
	static let textSecondary = adaptive(light: 0x3C3C43, dark: 0xFFFFFF, darkOpacity: 0.55)
	static let textTertiary = adaptive(light: 0x6F6F75, dark: 0xFFFFFF, darkOpacity: 0.55)
	static let textQuaternary = adaptive(light: 0x717178, dark: 0xFFFFFF, darkOpacity: 0.55)
	static let textFaint = adaptive(light: 0x73737A, dark: 0xFFFFFF, darkOpacity: 0.55)
	static let masked = adaptive(light: 0x6B6B72, dark: 0xFFFFFF, darkOpacity: 0.55)

	static let border = adaptive(light: 0xDCDBE2, dark: 0x262626)
	static let divider = adaptive(light: 0xECEAF0, dark: 0x262626)
	static let rowDivider = adaptive(light: 0xF0EFF4, dark: 0x191919)

	static let accent = Color(hex: 0x5E5CE6)
	static let accentForeground = adaptive(light: 0x5E5CE6, dark: 0xB9B8FF)
	static let accentHover = adaptive(light: 0x7A78F0, dark: 0x6664E8)
	static let accentTint = adaptive(light: 0xECEAFC, dark: 0x29263D)
	static let accentText = adaptive(light: 0x2C2B4A, dark: 0xD5D4FF)
	static let accentDeep = adaptive(light: 0x4B48D6, dark: 0xB9B8FF)

	static let green = Color(hex: 0x34C759)
	static let orange = Color(hex: 0xFF9F0A)
	static let red = Color(hex: 0xFF3B30)
	static let redText = adaptive(light: 0xC8342B, dark: 0xFF847D)
	/// A destructive action's solid button.
	static let destructiveFill = adaptive(light: 0xE5342A, dark: 0xFF453A)
	static let destructiveFillHover = adaptive(light: 0xCC2B22, dark: 0xFF5F55)
	static let greenTint = adaptive(light: 0xE4F7E8, dark: 0x233528)
	static let greenTintText = adaptive(light: 0x1A7F37, dark: 0x75DB94)
	static let orangeTint = adaptive(light: 0xFFF1DE, dark: 0x3B3020)
	static let orangeTintText = adaptive(light: 0xA05A12, dark: 0xFFC06A)
	static let redTint = adaptive(light: 0xFFE9E7, dark: 0x3D2423)
	static let neutralTint = adaptive(light: 0xECEAF0, dark: 0x262626)
	static let publicTint = adaptive(light: 0xE3F2FA, dark: 0x173140)
	static let publicText = adaptive(light: 0x0B6A96, dark: 0x6CCFF6)

	static let rowSelected = adaptive(light: 0xF6F5FD, dark: 0x191919)
	static let rowHover = adaptive(light: 0xFAFAFC, dark: 0x101010)
	static let headerRow = adaptive(light: 0xFAFAFC, dark: 0x101010)
	static let headerHover = adaptive(light: 0xF0EFF4, dark: 0x262626)
	static let sidebarHover = adaptive(light: 0xEEEDF3, dark: 0x191919)
	static let selectedEnvHeader = adaptive(light: 0xF3F1FF, dark: 0x29263D)
	static let selectedEnvCell = adaptive(light: 0xFAF9FF, dark: 0x211F2E)

	static let strongFill = adaptive(light: 0x1C1C1E, dark: 0x5E5CE6)
	static let shadow = adaptive(light: 0x1C1C1E, dark: 0x000000)

	static let avatarNeutral = adaptive(light: 0xD9D8E4, dark: 0x262626)
	static let avatarNeutralForeground = adaptive(light: 0x5B5A6E, dark: 0xFFFFFF, darkOpacity: 0.55)
	static let terminal = adaptive(light: 0x1C1C1E, dark: 0x101010)
	static let terminalText = Color(hex: 0xE8E8ED)

	private static func adaptive(light: UInt, dark: UInt, darkOpacity: Double = 1) -> Color {
		func color(_ hex: UInt, alpha: Double) -> NSColor {
			NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
				green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
		}
		let lightColor = color(light, alpha: 1)
		let darkColor = color(dark, alpha: darkOpacity)
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
	/// Layout width of a pane divider: the hairline itself, flush with the pane.
	static let paneDivider: CGFloat = 1
	/// Pointer target for resizing, centered on the hairline and overlapping both neighbors.
	/// Odd, so its edges land on whole points around a 1pt hairline at any backing scale.
	static let paneDividerHitWidth: CGFloat = 9
	static let contentMinimum: CGFloat = 420
	static let tableHeader: CGFloat = 34
	static let matrixRow: CGFloat = 44
	static let fileRow: CGFloat = 46
	static let statusBar: CGFloat = 30
	static let keyColumn: CGFloat = 230
	static let environmentColumn: CGFloat = 190
	static let environmentValueColumn: CGFloat = 280
	static let environmentActionsColumn: CGFloat = 132
}

enum VaultTypography {
	/// Names, paths, counts and shortcuts: the system font, with digits of one width so numbers line up.
	static func tabular(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
		.system(size: size, weight: weight).monospacedDigit()
	}

	/// Revealed secret values and shell commands, where every character has to read unambiguously.
	static func code(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
		.system(size: size, weight: weight, design: .monospaced)
	}

	/// The code font in AppKit text, such as the box pasted variables are edited in.
	static func codeNSFont(_ size: CGFloat) -> NSFont {
		.monospacedSystemFont(ofSize: size, weight: .regular)
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

extension View {
	/// Keeps macOS from offering saved passwords in a secure field that holds a
	/// secret value. A one-time-code field is the only secure field it doesn't
	/// offer them in; for a few minutes after a verification code arrives in
	/// Messages or Mail, it offers that code instead.
	func vaultSecretValueField() -> some View {
		textContentType(.oneTimeCode)
	}
}

extension View {
	/// Hides the view but keeps its space, so neighboring controls don't move.
	func hidden(_ isHidden: Bool) -> some View {
		opacity(isHidden ? 0 : 1)
			.allowsHitTesting(!isHidden)
			.accessibilityHidden(isHidden)
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

	private static let vercelMark = loadMark(.vercel)
	private static let netlifyMark = loadMark(.netlify)
	private static let githubMark = loadMark(.github)
	private static let cloudflareMark = loadMark(.cloudflare)
	private static let coolifyMark = loadMark(.coolify)

	/// The platform's mark, one color, to draw in whatever color its tile needs.
	static func platformMark(_ platform: PublishPlatform) -> NSImage {
		switch platform {
		case .vercel: vercelMark
		case .netlify: netlifyMark
		case .github: githubMark
		case .cloudflare: cloudflareMark
		case .coolify: coolifyMark
		}
	}

	private static func loadMark(_ platform: PublishPlatform) -> NSImage {
		let mark = loadImage(name: "platform-\(platform.rawValue)", extension: "svg")
		mark.isTemplate = true
		return mark
	}

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
	var destructive = false
	/// Drawn in the accent tint, as while the sheet it opens is showing.
	var active = false
	var disabled = false
	var height: CGFloat = 26
	let action: () -> Void

	@State private var hovering = false

	private var foreground: Color {
		if disabled { return filled && destructive ? .white.opacity(0.7) : VaultPalette.textFaint }
		if filled { return .white }
		if destructive { return VaultPalette.redText }
		if active { return VaultPalette.accentText }
		return invertsOnHover && hovering ? .white : VaultPalette.textPrimary
	}

	private var background: Color {
		if disabled && filled && destructive { return VaultPalette.destructiveFill.opacity(0.35) }
		if disabled { return filled ? VaultPalette.accent.opacity(0.35) : VaultPalette.control.opacity(0.7) }
		if filled && destructive { return hovering ? VaultPalette.destructiveFillHover : VaultPalette.destructiveFill }
		if filled { return hovering ? VaultPalette.accentHover : VaultPalette.accent }
		if active { return VaultPalette.accentTint }
		if invertsOnHover && hovering { return VaultPalette.strongFill }
		return hovering ? VaultPalette.sidebar : VaultPalette.control
	}

	private var border: Color {
		if filled { return .clear }
		return active ? VaultPalette.accent.opacity(0.35) : VaultPalette.border
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let leadingDot { VaultStatusDot(color: leadingDot) }
				if let systemImage {
					Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
				}
				if let title {
					Text(title).font(.system(size: 12.5, weight: filled ? .semibold : .regular))
				}
				if let shortcut {
					Text(shortcut)
						.font(VaultTypography.tabular(10))
						.foregroundStyle(!disabled && (filled || (invertsOnHover && hovering)) ? .white.opacity(0.7) : VaultPalette.textFaint)
				}
			}
			.foregroundStyle(foreground)
			.padding(.horizontal, filled ? 12 : 11)
			.frame(height: height)
			.background(RoundedRectangle(cornerRadius: 7).fill(background))
			.overlay {
				RoundedRectangle(cornerRadius: 7)
					.stroke(border, lineWidth: 1)
			}
			.fixedSize()
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

/// A control that opens a menu, drawn like a `VaultBarButton` with a chevron after its label.
struct VaultBarMenu<Items: View, Label: View>: View {
	let accessibilityLabel: String
	let items: Items
	let label: Label

	init(accessibilityLabel: String, @ViewBuilder items: () -> Items, @ViewBuilder label: () -> Label) {
		self.accessibilityLabel = accessibilityLabel
		self.items = items()
		self.label = label()
	}

	var body: some View {
		Menu {
			items
		} label: {
			HStack(spacing: 6) {
				label
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(VaultPalette.textQuaternary)
			}
			.foregroundStyle(VaultPalette.textPrimary)
			.padding(.horizontal, 11)
			.frame(height: 26)
			.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
			// A menu drawn as a button otherwise makes each part of its label a menu of its own.
			.accessibilityElement(children: .combine)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.accessibilityLabel(accessibilityLabel)
	}
}

struct VaultOutlineButton: View {
	var systemImage: String?
	var title: String?
	var reservedTitles: [String] = []
	/// The tooltip, which also names a button that shows only its icon.
	var help: String?
	/// The button's name for accessibility, which begins with its title.
	var label: String?
	var active = false
	/// Whether `active` is an on-off state, which makes it a toggle button for accessibility.
	var toggles = false
	var disabled = false
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let systemImage {
					Image(systemName: systemImage)
						.font(.system(size: 11, weight: .medium))
						.frame(width: 12)
				}
				if let title {
					ZStack {
						ForEach(reservedTitles, id: \.self) { Text($0).hidden().accessibilityHidden(true) }
						Text(title)
					}
					.font(.system(size: 12.5))
				}
			}
			.foregroundStyle(disabled ? VaultPalette.textFaint : (active ? VaultPalette.accentForeground : VaultPalette.textPrimary))
			.padding(.horizontal, title == nil ? 0 : 11)
			.frame(width: title == nil ? 27 : nil, height: 27)
			.background {
				RoundedRectangle(cornerRadius: 7)
					.fill(active ? VaultPalette.accentTint : (hovering ? VaultPalette.sidebar : VaultPalette.control))
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
		.accessibilityLabel(label ?? title ?? help ?? "")
		.accessibilityAddTraits(toggles ? (active ? [.isToggle, .isSelected] : .isToggle) : [])
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

struct VaultRowIconButton: View {
	let systemImage: String
	/// The tooltip, which also names the button for accessibility unless `label` does.
	let help: String
	var destructive = false
	/// The button's name for accessibility, when the tooltip says more, such as a shortcut.
	var label: String?
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
		.accessibilityLabel(label ?? help)
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

struct VaultFilterChip: View {
	let title: String
	var dot: Color?
	var symbol: String?
	var trailing: String?
	/// Draws the chip in red, for a view of things to fix.
	var alert = false
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let dot { VaultStatusDot(color: dot) }
				if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
				Text(title).font(.system(size: 12, weight: selected || alert ? .semibold : .regular))
				if let trailing { Text(trailing).font(VaultTypography.tabular(11)) }
			}
			.foregroundStyle(selected ? .white : (alert ? VaultPalette.redText : VaultPalette.textSecondary))
			.padding(.horizontal, 11)
			.frame(height: 26)
			.background(Capsule().fill(selected ? (alert ? VaultPalette.red : VaultPalette.strongFill) : (hovering ? VaultPalette.sidebar : (alert ? VaultPalette.redTint : .clear))))
			.overlay { Capsule().stroke(selected ? .clear : (alert ? VaultPalette.red.opacity(0.55) : VaultPalette.border), lineWidth: 1) }
			.fixedSize()
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
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

/// A table cell's value as the rules see it: the stored value, underlined in
/// red with the reason as its tooltip when it fails a rule; or, without a
/// stored value, "Required", the default that fills it, or "Not set".
struct VaultCheckedValue: View {
	let value: String?
	var isRevealed = false
	/// Why the value fails its rules, one reason per line.
	var problem: String?
	var defaultValue: String?
	var isRequired = false
	var showsNotSet = true
	var size: CGFloat = 12

	var body: some View {
		Group {
			if let value, !value.isEmpty || defaultValue == nil {
				VaultValueText(text: isRevealed ? value : "••••••••••", masked: !isRevealed, size: size)
					.overlay(alignment: .bottom) { if problem != nil { underline } }
					.help(problem ?? "")
			} else if isRequired {
				Text("Required")
					.font(.system(size: size - 0.5, weight: .semibold))
					.foregroundStyle(VaultPalette.redText)
					.overlay(alignment: .bottom) { underline }
					.help(problem ?? "Required")
			} else if let defaultValue {
				(Text(defaultValue).font(VaultTypography.tabular(size)).foregroundColor(VaultPalette.textTertiary)
					+ Text("  (default)").font(VaultTypography.tabular(size - 1)).foregroundColor(VaultPalette.textFaint))
					.lineLimit(1)
					.truncationMode(.middle)
					.overlay(alignment: .bottom) { if problem != nil { underline } }
					.help(problem ?? "The schema default the LPM CLI uses: \(defaultValue)")
			} else if showsNotSet {
				Text("Not set").font(.system(size: size - 1, weight: .semibold)).foregroundStyle(VaultPalette.redText)
			}
		}
	}

	private var underline: some View {
		Rectangle().fill(VaultPalette.red).frame(height: 1.5).offset(y: 3).accessibilityHidden(true)
	}
}

struct VaultValueText: View {
	let text: String
	var masked = true
	var size: CGFloat = 12

	var body: some View {
		Text(text)
			.font(masked ? VaultTypography.tabular(size) : VaultTypography.code(size))
			.tracking(masked ? 1.2 : 0)
			.foregroundStyle(masked ? VaultPalette.masked : VaultPalette.textSecondary)
			.lineLimit(1)
			.truncationMode(.tail)
			.accessibilityHidden(true)
	}
}
