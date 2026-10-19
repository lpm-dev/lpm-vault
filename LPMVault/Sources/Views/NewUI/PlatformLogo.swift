import SwiftUI

/// A platform's mark, in white on a tile of the platform's brand color.
struct PlatformLogo: View {
	let platform: PublishPlatform
	var size: CGFloat = 28

	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		let tile = RoundedRectangle(cornerRadius: (size * 0.285).rounded(), style: .continuous)
		Image(nsImage: VaultBranding.platformMark(platform))
			.renderingMode(.template)
			.resizable()
			.scaledToFit()
			.foregroundStyle(.white)
			.frame(width: size * platform.markScale, height: size * platform.markScale)
			.frame(width: size, height: size)
			.background(tile.fill(platform.brandColor))
			.overlay {
				// Vercel's black and GitHub's near-black tiles would vanish into a dark page without an edge.
				if colorScheme == .dark, platform.hasDarkTile {
					tile.strokeBorder(.white.opacity(0.14), lineWidth: 1)
				}
			}
			.accessibilityHidden(true)
	}
}

extension PublishPlatform {
	/// The color of the platform's logo tile.
	fileprivate var brandColor: Color {
		switch self {
		case .vercel: Color(hex: 0x000000)
		case .netlify: Color(hex: 0x05BDBA)
		case .github: Color(hex: 0x24292F)
		case .cloudflare: Color(hex: 0xF38020)
		case .coolify: Color(hex: 0x6B16ED)
		}
	}

	fileprivate var hasDarkTile: Bool {
		self == .vercel || self == .github
	}

	/// How much of the tile the mark spans, so marks of different shapes
	/// look the same size: Cloudflare's wide cloud spans more of it.
	fileprivate var markScale: CGFloat {
		switch self {
		case .vercel: 0.46
		case .netlify: 0.62
		case .github: 0.54
		case .cloudflare: 0.66
		case .coolify: 0.48
		}
	}
}
