import AppKit
import SwiftUI

enum VaultPalette {
	// Content is the brightest layer in both appearances; the title bar, sidebar and
	// inspector sit a step below it, and controls and cards a step above the content.
	static let titleBar = adaptive(light: 0xF8F8FA, dark: 0x161618)
	static let titleBarBorder = adaptive(light: 0xE2E1E7, dark: 0x2C2C30)
	static let sidebar = adaptive(light: 0xF6F6F8, dark: 0x161618)
	static let sidebarBorder = adaptive(light: 0xE2E1E7, dark: 0x2C2C30)
	static let content = adaptive(light: 0xFFFFFF, dark: 0x1C1C1F)
	/// A group of settings or a tile on the content.
	static let card = adaptive(light: 0xF8F8FA, dark: 0x222225)
	static let control = adaptive(light: 0xFFFFFF, dark: 0x242428)
	/// A popover's or menu's card: a step above the content in dark, where no shadow shows depth.
	static let popover = adaptive(light: 0xFFFFFF, dark: 0x2A2A2F)
	static let popoverBorder = adaptive(light: 0xDCDBE2, dark: 0x414148)
	static let controlHover = adaptive(light: 0xF1F1F4, dark: 0x2D2D32)
	static let inspector = adaptive(light: 0xF8F8FA, dark: 0x19191B)

	// Dark text is white at four strengths, so it takes on the tint of what it sits on.
	static let textPrimary = adaptive(light: 0x1C1C1E, dark: 0xFFFFFF, darkOpacity: 0.92)
	static let textSecondary = adaptive(light: 0x45454C, dark: 0xFFFFFF, darkOpacity: 0.74)
	static let textTertiary = adaptive(light: 0x5C5C64, dark: 0xFFFFFF, darkOpacity: 0.58)
	static let textQuaternary = textTertiary
	/// Hints and placeholders: still 4.5:1 on the content, the weakest text that says something.
	static let textFaint = adaptive(light: 0x6C6C74, dark: 0xFFFFFF, darkOpacity: 0.48)
	/// A control that's off: plainly fainter than any working control's text, in both appearances.
	static let disabledText = adaptive(light: 0xA3A3AB, dark: 0xFFFFFF, darkOpacity: 0.36)
	/// An empty field's prompt: gray where typed text is near black, and 4.5:1 on every surface a field sits on, as text it is.
	static let placeholder = textFaint
	static let masked = textFaint

	static let border = adaptive(light: 0xDCDBE2, dark: 0x3A3A3F)
	/// A text field's edge: 3:1 against the field and what's around it, as a
	/// control's boundary needs, where cards and tables keep the quieter `border`.
	static let inputBorder = adaptive(light: 0x8E8E99, dark: 0x6E6E78)
	static let divider = adaptive(light: 0xEAE9EF, dark: 0x343439)
	static let rowDivider = adaptive(light: 0xF0EFF4, dark: 0x252528)

	static let accent = Color(hex: 0x5E5CE6)
	static let accentForeground = adaptive(light: 0x5654DE, dark: 0xB4B3FF)
	static let accentHover = adaptive(light: 0x5250DA, dark: 0x5452DC)
	static let accentPressed = adaptive(light: 0x4542C8, dark: 0x5250D6)
	static let accentTint = adaptive(light: 0xEEEDFD, dark: 0x2B2946)
	static let accentText = adaptive(light: 0x2E2C8A, dark: 0xD5D4FF)
	static let accentDeep = adaptive(light: 0x4B48D6, dark: 0xB9B8FF)
	/// The ring around a control that has keyboard focus.
	static let focusRing = adaptive(light: 0x5E5CE6, dark: 0x8C8AFF)

	static let green = Color(hex: 0x34C759)
	static let orange = Color(hex: 0xFF9F0A)
	static let red = Color(hex: 0xFF3B30)
	static let redText = adaptive(light: 0xC8342B, dark: 0xFF847D)
	/// A status glyph that needs fixing: a value that fails its rules.
	static let problemMark = adaptive(light: 0xD7372E, dark: 0xFF6B61)
	/// A status glyph worth a look: a key missing from an environment.
	static let warningMark = adaptive(light: 0xB86200, dark: 0xFFB547)
	/// A destructive action's solid button.
	static let destructiveFill = adaptive(light: 0xE5342A, dark: 0xFF453A)
	static let destructiveFillHover = adaptive(light: 0xCC2B22, dark: 0xFF5F55)
	static let greenTint = adaptive(light: 0xE4F7E8, dark: 0x1F3326)
	static let greenTintText = adaptive(light: 0x1A7F37, dark: 0x75DB94)
	static let orangeTint = adaptive(light: 0xFFF1DE, dark: 0x392C1B)
	/// A caution's band inside a sheet: quieter than `orangeTint`, edged so it holds its shape.
	static let cautionFill = adaptive(light: 0xFFF7EC, dark: 0x2A2319)
	static let cautionEdge = adaptive(light: 0xF2D9B3, dark: 0x4A3A22)
	static let orangeTintText = adaptive(light: 0xA05A12, dark: 0xFFC06A)
	static let redTint = adaptive(light: 0xFFEBE9, dark: 0x3B2325)
	static let neutralTint = adaptive(light: 0xEEEDF2, dark: 0x2C2C30)
	static let publicTint = adaptive(light: 0xE3F2FA, dark: 0x16303D)
	static let publicText = adaptive(light: 0x0B6A96, dark: 0x6CCFF6)

	static let rowSelected = adaptive(light: 0xF1F0FD, dark: 0x27263B)
	static let rowHover = adaptive(light: 0xF2F2F6, dark: 0x232328)
	static let headerRow = adaptive(light: 0xFAFAFC, dark: 0x19191C)
	static let headerHover = adaptive(light: 0xF0EFF4, dark: 0x26262A)
	/// A band that starts a section inside a list, set off from the rows on both sides.
	static let sectionBand = adaptive(light: 0xF4F4F7, dark: 0x252529)
	/// A menu row under the pointer or the arrow keys: a step up from the popover's card in both appearances.
	static let menuHighlight = adaptive(light: 0xE9E9EE, dark: 0x37373D)
	static let sidebarHover = adaptive(light: 0xEDEDF1, dark: 0x202023)
	static let sidebarSelection = adaptive(light: 0xE7E7EA, dark: 0x2A2A2D)
	static let schemaRowSelected = adaptive(light: 0xF5F4FE, dark: 0x252439)

	/// A selected chip, segment or toggle: the same tinted look in both appearances.
	static let selectedFill = accentTint
	static let selectedText = accentText
	static let selectedBorder = adaptive(light: 0x5E5CE6, dark: 0x8C8AFF, lightOpacity: 0.35, darkOpacity: 0.45)
	static let strongFill = adaptive(light: 0x1C1C1E, dark: 0x5E5CE6)
	static let shadow = adaptive(light: 0x1C1C1E, dark: 0x000000)
	/// A switch's track while it's off: visible on every surface, with its own edge.
	static let switchOff = adaptive(light: 0xD9D8DF, dark: 0x3A3A3F)
	static let switchOffBorder = adaptive(light: 0xBEBDC6, dark: 0x4A4A50)
	/// Darkens a control while it's pressed, over whatever fill it has.
	static let pressedOverlay = adaptive(light: 0x000000, dark: 0xFFFFFF, lightOpacity: 0.07, darkOpacity: 0.08)
	/// What dims the window behind an overlay, such as Settings.
	static let scrim = adaptive(light: 0x1C1C1E, dark: 0x000000, lightOpacity: 0.32, darkOpacity: 0.5)

	static let avatarNeutral = adaptive(light: 0xE2E1EA, dark: 0x2E2E33)
	static let avatarNeutralForeground = adaptive(light: 0x55546A, dark: 0xFFFFFF, darkOpacity: 0.7)
	static let terminal = adaptive(light: 0x1C1C1E, dark: 0x111113)
	/// A block of code or a command, a calm panel in both appearances.
	static let codeBlock = adaptive(light: 0xF6F6F9, dark: 0x151517)
	static let codeText = adaptive(light: 0x1C1C1E, dark: 0xE8E8ED)
	static let codeKey = adaptive(light: 0x0B6A96, dark: 0x9FD4FF)
	static let codeString = adaptive(light: 0x1A7F37, dark: 0xC3E88D)
	/// A toast is dark in both appearances, with white text.
	static let toast = adaptive(light: 0x1C1C1E, dark: 0x2A2A2E)
	static let toastSecondaryText = Color.white.opacity(0.6)
	static let toastConfirmation = Color(hex: 0x75DB94)
	static let toastAction = Color(hex: 0xB9B8FF)
	static let toastDivider = Color.white.opacity(0.2)

	private static func adaptive(light: UInt, dark: UInt, lightOpacity: Double = 1, darkOpacity: Double = 1) -> Color {
		func color(_ hex: UInt, alpha: Double) -> NSColor {
			NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
				green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
		}
		let lightColor = color(light, alpha: lightOpacity)
		let darkColor = color(dark, alpha: darkOpacity)
		return Color(nsColor: NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
		})
	}

	/// An environment's color. None of them is green, orange or red, which mean a key's state.
	static func environment(_ index: Int) -> Color {
		environmentColors[index % environmentColors.count]
	}

	// Purple, nearest the accent, comes late, so a second environment never reads as part of a selection;
	// teal, nearest the Public chip, comes after the three most projects have, so Public never reads as an environment.
	private static let environmentColors = [0x3D84F2, 0xD6579A, 0xA97C52, 0x2FA6C0, 0x8D6BEA, 0x8B909A].map { Color(hex: $0) }
}

enum VaultMetrics {
	static let titleBar: CGFloat = 46
	static let sidebar: CGFloat = 260
	static let sidebarMinimum: CGFloat = 240
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
	static let matrixRow: CGFloat = 36
	static let fileRow: CGFloat = 36
	static let statusBar: CGFloat = 36
	static let keyColumn: CGFloat = 270
	/// The space after a scroll view's content, so its end scrolls clear of a pinned footer's line.
	static let scrollEndPadding: CGFloat = 32
	static let environmentColumn: CGFloat = 190
	/// The narrowest a value column gets while its values are shown to be read:
	/// a local URL with its port, and a mark before it, fits whole.
	static let readableValueColumn: CGFloat = 206
	static let environmentValueColumn: CGFloat = 280
	static let environmentActionsColumn: CGFloat = 142
	/// The widest a settings-style page's column of cards grows.
	static let formWidth: CGFloat = 720
	/// Below this window width, opening the inspector hides the sidebar, so the
	/// table keeps room for its environments; the title bar's button brings it back.
	static let sidebarAutoHideWidth: CGFloat = 1180
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
	static func codeNSFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
		.monospacedSystemFont(ofSize: size, weight: weight)
	}

	static let sectionLabel = Font.system(size: 11, weight: .semibold)
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
	/// A settings-style page's column of cards: the page's inset, and no wider
	/// than lines of text stay easy to read.
	func vaultFormColumn() -> some View {
		frame(maxWidth: VaultMetrics.formWidth, alignment: .leading)
			.padding(.horizontal, 20)
			.padding(.vertical, 20)
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// A page's title, the same size on every page.
	func vaultPageTitle() -> some View {
		font(.system(size: 20, weight: .semibold))
			.tracking(-0.3)
			.foregroundStyle(VaultPalette.textPrimary)
	}

	/// A table column's header, as Mac tables set them: title case, the same for a
	/// key, a value or an environment's file name.
	func vaultColumnHeader() -> some View {
		font(.system(size: 12, weight: .semibold))
			.foregroundStyle(VaultPalette.textSecondary)
	}

	/// A table's leading column kept in view while the table scrolls sideways
	/// by `offset`: it moves back by as much, on `background` once cells slide
	/// under it, and stays above them.
	func vaultPinnedColumn<Background: View>(offset: CGFloat, @ViewBuilder background: () -> Background) -> some View {
		let fill = background()
		return self
			.background { if offset > 0 { fill } }
			.offset(x: offset)
			.zIndex(1)
	}

	/// A section's band inside a list: its own fill, with a line on each
	/// edge that takes the place of the row line above it.
	func vaultSectionBand() -> some View {
		background(VaultPalette.sectionBand)
			.overlay(alignment: .top) { VaultHairline().offset(y: -1) }
			.overlay(alignment: .bottom) { VaultHairline() }
	}

	func vaultSectionLabel(_ color: Color = VaultPalette.textQuaternary) -> some View {
		font(VaultTypography.sectionLabel)
			.tracking(0.5)
			.foregroundStyle(color)
	}

	/// Shows the pointing hand while the pointer is over the view and it's
	/// enabled, as macOS does for links; buttons keep the arrow. `enabled` is
	/// for a link that disables itself inside this modifier, which the
	/// environment here can't see; a disabled parent is read from the environment.
	func vaultPointingHand(enabled: Bool = true) -> some View {
		modifier(VaultPointingHand(enabled: enabled))
	}
}

/// Whether a control shows the pointing hand, and the one cursor change each
/// update needs, so every push is popped exactly once.
struct VaultPointingHandState {
	enum Change { case push, pop }

	private(set) var showsHand = false

	mutating func update(hovering: Bool, enabled: Bool) -> Change? {
		let wanted = hovering && enabled
		guard wanted != showsHand else { return nil }
		showsHand = wanted
		return wanted ? .push : .pop
	}
}

private struct VaultPointingHand: ViewModifier {
	let enabled: Bool
	@Environment(\.isEnabled) private var parentEnabled
	@State private var hovering = false
	@State private var state = VaultPointingHandState()

	func body(content: Content) -> some View {
		content
			.onHover { inside in
				hovering = inside
				apply()
			}
			.onChange(of: enabled && parentEnabled) { apply() }
			.onDisappear {
				hovering = false
				apply()
			}
	}

	private func apply() {
		switch state.update(hovering: hovering, enabled: enabled && parentEnabled) {
		case .push?: NSCursor.pointingHand.push()
		case .pop?: NSCursor.pop()
		case nil: break
		}
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

/// A short note floating over the content, such as what a copy took. One
/// with a button keeps its parts apart for accessibility, so the button can be pressed.
struct VaultToast<Content: View>: View {
	var hasButton = false
	@ViewBuilder let content: Content

	@State private var arrived = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		HStack(spacing: 8) { content }
			.font(.system(size: 12))
			.foregroundStyle(.white)
			.lineLimit(1)
			.padding(.horizontal, 12)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.toast))
			.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
			.shadow(color: .black.opacity(0.18), radius: 6, y: 3)
			.offset(y: arrived || reduceMotion ? 0 : 8)
			.opacity(arrived || reduceMotion ? 1 : 0)
			.onAppear { withAnimation(reduceMotion ? nil : VaultMotion.enter) { arrived = true } }
			.accessibilityElement(children: hasButton ? .contain : .combine)
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
			.font(.system(size: size, weight: .semibold))
			.tracking(0.2)
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
			.font(VaultTypography.tabular(10.5, .semibold))
			.foregroundStyle(.white)
			.padding(.horizontal, 6)
			.padding(.vertical, 1)
			.background(Capsule().fill(tint))
	}
}

/// How the app's buttons respond to a press and to keyboard focus: a press
/// darkens whatever the button draws, and keyboard focus draws a crisp ring
/// inside its edge. Hover belongs to each button, which knows its own colors.
/// How keyboard focus is drawn: the accent ring at a control's edge, or on an
/// accent-filled control, which the accent can't show on, a white ring inside it.
enum VaultFocusRing {
	static func color(onFill: Bool) -> Color { onFill ? .white : VaultPalette.focusRing }
	static func width(onFill: Bool) -> CGFloat { onFill ? 1.5 : 2 }
	/// How far inside the control's edge the ring sits.
	static func inset(onFill: Bool) -> CGFloat { onFill ? 3 : 0 }
}

struct VaultPressStyle<S: InsettableShape>: ButtonStyle {
	let shape: S
	/// The control is filled with the accent, so its focus ring is drawn in white, inside it.
	var filled = false

	func makeBody(configuration: Configuration) -> some View {
		VaultPressBody(configuration: configuration, shape: shape, filled: filled)
	}
}

extension VaultPressStyle where S == RoundedRectangle {
	init(cornerRadius: CGFloat = 7, filled: Bool = false) {
		shape = RoundedRectangle(cornerRadius: cornerRadius)
		self.filled = filled
	}
}

/// A shape's border as the ring between the shape and its inset, for filling
/// even-odd. A stroked capsule picks up marks at its round ends when it's drawn
/// into a bitmap, as screenshots and the Accessibility Inspector do; a filled
/// ring draws the same border without them.
struct VaultRing<S: InsettableShape>: Shape {
	let shape: S
	let lineWidth: CGFloat

	func path(in rect: CGRect) -> Path {
		var path = shape.path(in: rect)
		path.addPath(shape.inset(by: lineWidth).path(in: rect))
		return path
	}
}

extension InsettableShape {
	/// Draws the shape's border inside its edge, like `strokeBorder`, without the marks a stroked capsule can leave.
	func vaultBorder(_ content: some ShapeStyle, lineWidth: CGFloat = 1) -> some View {
		VaultRing(shape: self, lineWidth: lineWidth).fill(content, style: FillStyle(eoFill: true))
	}
}

private struct VaultPressBody<S: InsettableShape>: View {
	let configuration: ButtonStyleConfiguration
	let shape: S
	let filled: Bool
	@Environment(\.isFocused) private var isFocused
	@Environment(\.isEnabled) private var isEnabled

	var body: some View {
		configuration.label
			.environment(\.vaultControlFocused, isFocused)
			.overlay { shape.fill(VaultPalette.pressedOverlay).opacity(configuration.isPressed && isEnabled ? 1 : 0) }
			.overlay {
				if isFocused {
					shape.inset(by: VaultFocusRing.inset(onFill: filled))
						.vaultBorder(VaultFocusRing.color(onFill: filled), lineWidth: VaultFocusRing.width(onFill: filled))
				}
			}
			.contentShape(shape)
	}
}

extension EnvironmentValues {
	/// Whether the button a label belongs to has keyboard focus, which `VaultPressStyle` tells its label.
	@Entry var vaultControlFocused = false
}

/// The app's motion: short, eased, and none under Reduce Motion, which
/// `VaultHoverAnimation` and each use check.
enum VaultMotion {
	/// Hover and press feedback.
	static let quick = Animation.easeOut(duration: 0.12)
	/// Something arriving, such as a toast.
	static let enter = Animation.spring(response: 0.28, dampingFraction: 0.9)
	/// A pane opening or closing, such as the sidebar.
	static let panel = Animation.spring(response: 0.3, dampingFraction: 0.88)
}

extension View {
	/// Eases a hover change in over a tenth of a second, or switches at once under Reduce Motion.
	func vaultHoverAnimation(_ hovering: Bool) -> some View {
		modifier(VaultHoverAnimation(hovering: hovering))
	}
}

private struct VaultHoverAnimation: ViewModifier {
	let hovering: Bool
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func body(content: Content) -> some View {
		content.animation(reduceMotion ? nil : VaultMotion.quick, value: hovering)
	}
}

struct VaultBarButton: View {
	var systemImage: String?
	var title: String?
	var shortcut: String?
	var leadingDot: Color?
	var filled = false
	/// Drawn without a border or fill until the pointer is over it, as in the title bar.
	var borderless = false
	var destructive = false
	/// Drawn in the accent tint, as while the sheet it opens is showing.
	var active = false
	var disabled = false
	var height: CGFloat = 28
	/// Stretches across its container, as a panel's footer actions do.
	var fillsWidth = false
	let action: () -> Void

	@State private var hovering = false

	private var foreground: Color {
		if disabled { return filled ? .white.opacity(0.75) : VaultPalette.disabledText }
		if filled { return .white }
		if destructive { return VaultPalette.redText }
		if active { return VaultPalette.selectedText }
		return borderless ? VaultPalette.textSecondary : VaultPalette.textPrimary
	}

	private var background: Color {
		// Off, a filled button keeps its color, faded, so it stays the default and never passes for a working one.
		if disabled { return filled ? (destructive ? VaultPalette.destructiveFill : VaultPalette.accent).opacity(0.4) : .clear }
		if filled && destructive { return hovering ? VaultPalette.destructiveFillHover : VaultPalette.destructiveFill }
		if filled { return hovering ? VaultPalette.accentHover : VaultPalette.accent }
		if active { return VaultPalette.selectedFill }
		if borderless { return hovering ? VaultPalette.controlHover : .clear }
		return hovering ? VaultPalette.controlHover : VaultPalette.control
	}

	private var border: Color {
		if filled { return .clear }
		if active { return VaultPalette.selectedBorder }
		if disabled && !borderless { return VaultPalette.divider }
		return borderless ? .clear : VaultPalette.border
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let leadingDot { VaultStatusDot(color: leadingDot) }
				if let systemImage {
					Image(systemName: systemImage).font(.system(size: 11.5, weight: borderless ? .regular : .medium))
				}
				if let title {
					// A borderless button is chrome, so it reads quieter than the page it serves.
					Text(title).font(.system(size: 12.5, weight: filled ? .semibold : (borderless ? .regular : .medium)))
				}
				if let shortcut {
					// A default button's shortcut shows once it works, in the room it keeps, so turning on doesn't move it.
					let hidden = filled && disabled
					Text(shortcut)
						.font(VaultTypography.tabular(10.5))
						.foregroundStyle(filled && !disabled ? .white.opacity(0.75) : VaultPalette.textFaint)
						.opacity(hidden ? 0 : 1)
						.accessibilityHidden(hidden)
				}
			}
			.foregroundStyle(foreground)
			.padding(.horizontal, title == nil ? 0 : (borderless ? 9 : 11))
			.frame(minWidth: title == nil ? height : nil, maxWidth: fillsWidth ? .infinity : nil)
			.frame(height: height)
			.background(RoundedRectangle(cornerRadius: 7).fill(background))
			.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(border, lineWidth: 1) }
			.vaultHoverAnimation(hovering)
			.fixedSize(horizontal: !fillsWidth, vertical: true)
		}
		.buttonStyle(VaultPressStyle(filled: filled && !disabled))
		.disabled(disabled)
		.onHover { hovering = $0 }
	}
}

/// A control that opens a menu of `rows` in the app's popover, drawn like a
/// `VaultBarButton` with a chevron after its label.
struct VaultBarMenu<ID: Hashable, Label: View>: View {
	let accessibilityLabel: String
	/// Drawn without a border or fill until the pointer is over it, as in the title bar.
	var borderless = false
	var height: CGFloat = 28
	var menuWidth: CGFloat = 240
	let rows: [VaultMenuList<ID>.Row]
	let onChoose: (ID) -> Void
	let label: Label

	@Environment(\.isEnabled) private var isEnabled
	@State private var hovering = false
	@State private var isOpen = false

	init(accessibilityLabel: String, borderless: Bool = false, height: CGFloat = 28, menuWidth: CGFloat = 240,
		rows: [VaultMenuList<ID>.Row], onChoose: @escaping (ID) -> Void, @ViewBuilder label: () -> Label) {
		self.accessibilityLabel = accessibilityLabel
		self.borderless = borderless
		self.height = height
		self.menuWidth = menuWidth
		self.rows = rows
		self.onChoose = onChoose
		self.label = label()
	}

	var body: some View {
		let lit = (hovering || isOpen) && isEnabled
		Button { isOpen.toggle() } label: {
			HStack(spacing: 6) {
				label
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.foregroundStyle(!isEnabled ? VaultPalette.textFaint : (borderless ? VaultPalette.textSecondary : VaultPalette.textPrimary))
			.padding(.horizontal, borderless ? 8 : 11)
			.frame(height: height)
			.background(RoundedRectangle(cornerRadius: 7).fill(lit ? VaultPalette.controlHover : (borderless ? .clear : VaultPalette.control)))
			.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(borderless ? .clear : VaultPalette.border, lineWidth: 1) }
			.vaultHoverAnimation(lit)
			.contentShape(Rectangle())
		}
		.buttonStyle(VaultPressStyle())
		.fixedSize()
		.onHover { hovering = $0 }
		.accessibilityLabel(accessibilityLabel)
		.accessibilityHint("Shows a menu")
		.vaultMenu(isPresented: $isOpen, rows: rows, width: menuWidth, label: accessibilityLabel, onChoose: onChoose)
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
	/// Drawn without a border or fill until the pointer is over it, as in a toolbar.
	var borderless = false
	/// Draws nothing until the pointer or keyboard focus reaches it, as a table
	/// row's actions do on a row that isn't hovered or selected.
	var resting = false
	let action: () -> Void

	@State private var hovering = false
	@Environment(\.vaultControlFocused) private var focused

	private var background: Color {
		if active { return VaultPalette.selectedFill }
		if hovering && !disabled { return VaultPalette.controlHover }
		return borderless ? .clear : VaultPalette.control
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let systemImage {
					Image(systemName: systemImage)
						.font(.system(size: 11.5, weight: borderless ? .regular : .medium))
						.frame(width: 14)
				}
				if let title {
					ZStack {
						ForEach(reservedTitles, id: \.self) { Text($0).hidden().accessibilityHidden(true) }
						Text(title)
					}
					// One weight in every state, so a title that changes, as Copy All's does, never moves the row.
					.font(.system(size: 12.5, weight: borderless ? .regular : .medium))
				}
			}
			// Hidden by color, not opacity, so it stays named for accessibility.
			.foregroundStyle(resting && !hovering && !focused ? Color.clear
				: disabled ? VaultPalette.disabledText
				: (active ? VaultPalette.selectedText : (borderless ? VaultPalette.textSecondary : VaultPalette.textPrimary)))
			.padding(.horizontal, title == nil ? 0 : (borderless ? 9 : 11))
			.frame(width: title == nil ? 28 : nil, height: 28)
			.background { RoundedRectangle(cornerRadius: 7).fill(background) }
			.overlay {
				RoundedRectangle(cornerRadius: 7)
					.strokeBorder(active ? VaultPalette.selectedBorder : (borderless ? .clear : VaultPalette.border), lineWidth: 1)
			}
			.vaultHoverAnimation(hovering)
			.fixedSize()
		}
		.buttonStyle(VaultPressStyle())
		.disabled(disabled)
		.help(help ?? title ?? "")
		.accessibilityLabel(label ?? title ?? help ?? "")
		.accessibilityAddTraits(toggles ? (active ? [.isToggle, .isSelected] : .isToggle) : [])
		.onHover { hovering = $0 }
	}
}

struct VaultRowIconButton: View {
	let systemImage: String
	/// The tooltip, which also names the button for accessibility unless `label` does.
	let help: String
	var destructive = false
	/// The button's name for accessibility, when the tooltip says more, such as a shortcut.
	var label: String?
	var disabled = false
	/// Drawn smaller, for a card's header.
	var compact = false
	/// Draws nothing until the pointer or keyboard focus reaches it, as on a
	/// table row that isn't hovered or selected. It stays pressable and named.
	var resting = false
	/// Drawn as if hovered, as while the menu or popover it opens is showing.
	var active = false
	/// Drawn fainter until the pointer reaches it, for a control that's always
	/// there beside a more important one, as Copy and More beside a value's eye.
	var quiet = false
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		let lit = (hovering || active) && !disabled
		Button(action: action) {
			VaultRowIconGlyph(systemImage: systemImage, compact: compact, resting: resting && !active, hovering: hovering)
				.foregroundStyle(lit ? (destructive ? VaultPalette.redText : VaultPalette.textPrimary) : (quiet ? VaultPalette.textFaint : VaultPalette.textTertiary))
				.opacity(disabled ? 0.45 : 1)
				.frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
				.background {
					RoundedRectangle(cornerRadius: 6)
						.fill(lit ? (destructive ? VaultPalette.redTint : VaultPalette.controlHover) : .clear)
				}
				.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle(cornerRadius: 6))
		.disabled(disabled)
		.help(help)
		.accessibilityLabel(label ?? help)
		.onHover { hovering = $0 }
	}
}

/// A row icon's glyph, hidden while it rests until the pointer or keyboard focus reaches it.
/// A More menu's glyph that rests like a row icon: drawn while `resting` is
/// false, as when its row is hovered, or while the menu has keyboard focus.
struct VaultMoreGlyph: View {
	var resting = false
	var size: CGFloat = 28
	@Environment(\.vaultControlFocused) private var focused

	var body: some View {
		// Hidden by color, not opacity: a fully transparent view leaves the accessibility tree.
		Image(systemName: "ellipsis")
			.font(.system(size: 11.5, weight: .semibold))
			.foregroundStyle(resting && !focused ? Color.clear : VaultPalette.textTertiary)
			.frame(width: size, height: size)
			.contentShape(Rectangle())
	}
}

/// A row that tells its content whether the pointer is over it, for controls
/// that rest until then.
struct VaultHoverRow<Content: View>: View {
	@ViewBuilder let content: (_ hovering: Bool) -> Content
	@State private var hovering = false

	var body: some View {
		content(hovering)
			.onHover { hovering = $0 }
	}
}

private struct VaultRowIconGlyph: View {
	let systemImage: String
	let compact: Bool
	let resting: Bool
	let hovering: Bool
	@Environment(\.vaultControlFocused) private var focused

	var body: some View {
		Image(systemName: systemImage)
			.font(.system(size: compact ? 11 : 12, weight: .medium))
			.opacity(resting && !hovering && !focused ? 0 : 1)
	}
}

/// Lays its first view out as wide as it would be, up to the room the
/// others leave, with the others just after it, as a name with its rename
/// button; with `fits` off, the first takes all that room, as while editing.
/// The views keep their identity either way, so a field keeps its focus.
struct VaultLeadingFitLayout: Layout {
	var fits = true
	var spacing: CGFloat = 6

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let widths = widths(proposal: proposal, subviews: subviews)
		let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }.max() ?? 0
		let width = widths.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
		return CGSize(width: width, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var x = bounds.minX
		for (subview, width) in zip(subviews, widths(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)) {
			subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
			x += width + spacing
		}
	}

	private func widths(proposal: ProposedViewSize, subviews: Subviews) -> [CGFloat] {
		guard let first = subviews.first else { return [] }
		let rest = subviews.dropFirst().map { $0.sizeThatFits(.unspecified).width }
		let ideal = first.sizeThatFits(.unspecified).width
		let room = max((proposal.width ?? .infinity) - rest.reduce(0, +) - spacing * CGFloat(rest.count), 0)
		guard room.isFinite else { return [ideal] + rest }
		return [fits ? min(ideal, room) : room] + rest
	}
}

struct VaultFilterChip: View {
	let title: String
	var dot: Color?
	var symbol: String?
	/// The symbol's color, matching the glyph the chip's keys carry.
	var symbolTint: Color?
	var trailing: String?
	/// Draws the chip's symbol and count in red, for a view of things to fix.
	var alert = false
	/// Shows only the symbol and count, for a narrow header. The chip keeps its title for accessibility.
	var compact = false
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	private var background: Color {
		if selected { return alert ? VaultPalette.redTint : VaultPalette.selectedFill }
		return hovering ? VaultPalette.controlHover : .clear
	}

	private var border: Color {
		if selected { return alert ? VaultPalette.problemMark.opacity(0.45) : VaultPalette.selectedBorder }
		return VaultPalette.border
	}

	private var foreground: Color {
		if selected { return alert ? VaultPalette.redText : VaultPalette.selectedText }
		return VaultPalette.textSecondary
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let dot { VaultStatusDot(color: dot) }
				if let symbol {
					Image(systemName: symbol)
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(alert ? VaultPalette.redText : (symbolTint ?? foreground))
				}
				if !compact || symbol == nil {
					Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
				}
				if let trailing {
					Text(trailing)
						.font(VaultTypography.tabular(11, .medium))
						// Only the symbol carries the status color; every count reads the same.
						.foregroundStyle(selected ? foreground : VaultPalette.textTertiary)
				}
			}
			.foregroundStyle(foreground)
			.padding(.horizontal, 11)
			.frame(height: 26)
			.background(Capsule().fill(background))
			.overlay { Capsule().vaultBorder(border) }
			.vaultHoverAnimation(hovering)
			.vaultHoverAnimation(selected)
			.fixedSize()
		}
		.buttonStyle(VaultPressStyle(shape: Capsule()))
		.help(compact && symbol != nil ? title : "")
		.accessibilityLabel(trailing.map { "\(title), \($0)" } ?? title)
		.accessibilityAddTraits(selected ? .isSelected : [])
		.onHover { hovering = $0 }
	}
}

/// The app's switch: the accent track when on and a neutral, edged track when
/// off, the same in every window state, so on and off never look alike. The
/// native switch underneath takes clicks, the keyboard and accessibility; this
/// only draws over it.
struct VaultSwitchStyle: ToggleStyle {
	/// Shows the toggle's title before the switch; most switches sit beside a title of their own.
	var showsLabel = false

	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 8) {
			if showsLabel {
				configuration.label.accessibilityHidden(true)
			}
			Toggle(isOn: configuration.$isOn) { configuration.label }
				.toggleStyle(.switch)
				.labelsHidden()
				.overlay { VaultSwitchTrack(isOn: configuration.isOn).allowsHitTesting(false).accessibilityHidden(true) }
		}
	}
}

private struct VaultSwitchTrack: View {
	let isOn: Bool
	@Environment(\.isEnabled) private var isEnabled
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		ZStack(alignment: isOn ? .trailing : .leading) {
			Capsule().fill(isOn ? VaultPalette.accent : VaultPalette.switchOff)
			Capsule().vaultBorder(isOn ? .clear : VaultPalette.switchOffBorder)
			Circle()
				.fill(.white)
				.overlay { Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
				.padding(2)
		}
		.opacity(isEnabled ? 1 : 0.5)
		.animation(reduceMotion ? nil : VaultMotion.quick, value: isOn)
	}
}

/// What sets a key apart, one distinct glyph per state, in a slot of its own so
/// the glyphs line up down a table: it fails its rules, it's missing from an
/// environment, or its values differ between environments.
struct VaultKeyStatusMarks: View {
	var invalid = false
	var missing = false
	var drifts = false
	/// Keeps every mark's place when it isn't shown, so down a table each kind
	/// of mark stays in its own column.
	var slotted = false
	/// Draws the drift mark in the secondary text color, as on a hovered or
	/// selected row; at rest it's quieter, since drift is often intended.
	var emphasized = false

	var body: some View {
		HStack(spacing: 4) {
			slot(.invalid, shown: invalid)
			slot(.missing, shown: missing)
			slot(.drift, shown: drifts)
		}
		.fixedSize()
	}

	@ViewBuilder
	private func slot(_ view: VaultSmartView, shown: Bool) -> some View {
		if shown {
			mark(view)
		} else if slotted {
			Color.clear.frame(width: 14, height: 14).accessibilityHidden(true)
		}
	}

	private func mark(_ view: VaultSmartView) -> some View {
		Image(systemName: view.symbol)
			.font(.system(size: view == .drift ? 11 : 11.5, weight: view == .drift ? .regular : .semibold))
			// Drift is often meant, so at rest it stays behind the marks that need fixing.
			.foregroundStyle(view == .drift ? (emphasized ? VaultPalette.textSecondary : VaultPalette.textFaint) : view.tint)
			.frame(width: 14, height: 14)
			.help(view.meaning)
			.accessibilityLabel(view.meaning)
	}
}

extension View {
	/// A list row's fill: the selection's tint and bar, a lighter tint under the
	/// pointer, and `resting` otherwise.
	func vaultRowBackground(selected: Bool, resting: Color = .clear) -> some View {
		modifier(VaultRowBackground(selected: selected, resting: resting))
	}
}

private struct VaultRowBackground: ViewModifier {
	let selected: Bool
	let resting: Color
	@State private var hovering = false

	func body(content: Content) -> some View {
		content
			.background { VaultRowFill(selected: selected, hovering: hovering, resting: resting) }
			.onHover { hovering = $0 }
	}
}

/// A row's fill and selection bar, with the hover easing only the fill.
struct VaultRowFill: View {
	let selected: Bool
	let hovering: Bool
	var resting: Color = .clear

	var body: some View {
		Rectangle()
			.fill(selected ? VaultPalette.rowSelected : (hovering ? VaultPalette.rowHover : resting))
			.vaultHoverAnimation(hovering)
			.overlay(alignment: .leading) { if selected { VaultSelectionBar() } }
	}
}

/// A card's leading icon: a glyph on a small neutral tile, the same on every card.
struct VaultCardIcon: View {
	let systemImage: String
	var size: CGFloat = 30

	var body: some View {
		Image(systemName: systemImage)
			.font(.system(size: size * 0.47, weight: .medium))
			.foregroundStyle(VaultPalette.textSecondary)
			.frame(width: size, height: size)
			.background(RoundedRectangle(cornerRadius: size * 0.25).fill(VaultPalette.neutralTint))
			.accessibilityHidden(true)
	}
}

/// The bar on a selected row's leading edge, which marks the selection
/// alongside its tint in every list and table.
struct VaultSelectionBar: View {
	var body: some View {
		Rectangle()
			.fill(VaultPalette.accent)
			.frame(width: 3)
			.accessibilityHidden(true)
	}
}

struct VaultInitialsAvatar: View {
	let initials: String
	var size: CGFloat = 26
	/// An organization's: a rounded square in the accent's tint, where a person's is a neutral circle.
	var square = false

	/// The first letter or digit of `name`, uppercased: one letter reads at
	/// an avatar's size where two crowd it. LPM's L when there's none.
	static func initial(of name: String) -> String {
		name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "L"
	}

	var body: some View {
		Text(initials)
			.font(.system(size: size * 0.45, weight: .semibold))
			.foregroundStyle(square ? VaultPalette.accentText : VaultPalette.avatarNeutralForeground)
			.frame(width: size, height: size)
			.background {
				if square {
					RoundedRectangle(cornerRadius: size * 0.28).fill(VaultPalette.accentTint)
				} else {
					Circle().fill(VaultPalette.avatarNeutral)
				}
			}
	}
}

/// A table cell's value as the rules see it: the stored value, in red with the
/// reason as its tooltip when it fails a rule; or, without a stored value,
/// "Required", the default that fills it, or "Not set".
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
				HStack(spacing: 5) {
					// The failing cell carries the glyph too, so it isn't told by its color alone.
					if problem != nil { glyph(.invalid) }
					VaultValueText(text: isRevealed ? value : VaultValueText.mask, masked: !isRevealed, size: size, fails: problem != nil)
				}
				// A shown value reads in full on hover, where the cell cuts it, with why it fails.
				.help(isRevealed ? ([value] + [problem].compactMap { $0 }).joined(separator: "\n") : (problem ?? ""))
			} else if isRequired {
				HStack(spacing: 5) {
					glyph(.invalid)
					Text("Required")
						.font(.system(size: size - 0.5, weight: .medium))
						.foregroundStyle(VaultPalette.redText)
				}
				.help(problem ?? "Required")
			} else if let defaultValue {
				(Text(defaultValue).font(VaultTypography.tabular(size)).foregroundColor(problem == nil ? VaultPalette.textTertiary : VaultPalette.redText)
					+ Text("  (default)").font(VaultTypography.tabular(size - 1)).foregroundColor(VaultPalette.textFaint))
					.lineLimit(1)
					.truncationMode(.middle)
					.help(problem ?? "The schema default the LPM CLI uses: \(defaultValue)")
			} else if showsNotSet {
				HStack(spacing: 5) {
					glyph(.missing)
					Text("Not set").font(.system(size: size - 0.5)).foregroundStyle(VaultPalette.textTertiary)
				}
			}
		}
	}

	/// The key column's mark for the cell's state, so the cell says it without its color.
	private func glyph(_ view: VaultSmartView) -> some View {
		Image(systemName: view.symbol)
			.font(.system(size: size - 1.5, weight: .semibold))
			.foregroundStyle(view.tint)
			.accessibilityHidden(true)
	}
}

struct VaultValueText: View {
	/// What a hidden value shows, the same length whatever the value, everywhere a value is hidden.
	static let mask = "••••••"

	let text: String
	var masked = true
	var size: CGFloat = 12
	/// Draws the value in red, as when it fails its rules.
	var fails = false

	var body: some View {
		// A URL too long for its cell gives up its path first, then the end of its
		// host: never the scheme, which can be what a rule checks, nor the host's
		// start, which is where environments' hosts tend to differ.
		if !masked, let separator = Self.schemeSeparator(in: text) {
			let scheme = String(text[..<separator.upperBound])
			let origin = Self.origin(of: text)
			ViewThatFits(in: .horizontal) {
				styled(text, truncation: .tail).fixedSize()
				if let origin { styled(origin + "/…", truncation: .tail).fixedSize() }
				HStack(spacing: 0) {
					styled(scheme, truncation: .tail).fixedSize()
					styled(String((origin ?? text).dropFirst(scheme.count)), truncation: .tail)
				}
			}
		} else {
			styled(text, truncation: .tail)
		}
	}

	private func styled(_ shown: String, truncation: Text.TruncationMode) -> some View {
		Text(shown)
			.font(masked ? VaultTypography.tabular(size) : VaultTypography.code(size))
			.tracking(masked ? 1.2 : 0)
			.foregroundStyle(fails ? VaultPalette.redText : (masked ? VaultPalette.masked : VaultPalette.textSecondary))
			.lineLimit(1)
			.truncationMode(truncation)
			.accessibilityHidden(true)
	}

	/// A URL's scheme and host, such as "https://api.acme.io" for
	/// "https://api.acme.io/v1/users", when there's a path, query or fragment
	/// after them to leave out; nil otherwise, and for a value that isn't a URL.
	nonisolated static func origin(of value: String) -> String? {
		guard let separator = schemeSeparator(in: value) else { return nil }
		let rest = value[separator.upperBound...]
		guard let end = rest.firstIndex(where: { "/?#".contains($0) }), end > rest.startIndex else { return nil }
		let after = rest[end...]
		guard after != "/" else { return nil }
		return String(value[..<end])
	}

	/// Where "://" ends a scheme at the start of `value` with something after it.
	private nonisolated static func schemeSeparator(in value: String) -> Range<String.Index>? {
		guard let separator = value.range(of: "://"), separator.lowerBound > value.startIndex,
			value[..<separator.lowerBound].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }),
			value[separator.upperBound...].contains(where: { !$0.isWhitespace })
		else { return nil }
		return separator
	}
}
