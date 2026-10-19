import AppKit
import SwiftUI

/// A project's icon at `size` points: an image, a symbol or monogram on a
/// colored tile, an emoji, or the folder shown when there's nothing else.
struct VaultProjectIconView: View {
	let appearance: ProjectIconAppearance
	var size: CGFloat = 16
	var folderColor: Color = VaultPalette.textTertiary

	private var cornerRadius: CGFloat { size * 0.25 }

	var body: some View {
		Group {
			switch appearance {
			case .image(let image):
				Image(decorative: image.image(for: size), scale: 1)
					.resizable()
					.interpolation(.high)
					.aspectRatio(contentMode: .fit)
					.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
			case .symbol(let name, let color):
				tile(color) {
					Image(systemName: name)
						.font(.system(size: size * 0.625, weight: .semibold))
						.foregroundStyle(.white)
				}
			case .emoji(let emoji):
				Text(emoji)
					.font(.system(size: size * 0.875))
					.fixedSize()
			case .monogram(let letters, let color):
				tile(color) {
					Text(letters)
						.font(.system(size: size * 0.47, weight: .bold))
						.foregroundStyle(.white)
						.lineLimit(1)
						.minimumScaleFactor(0.6)
				}
			case .folder:
				if size > 24 {
					RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
						.fill(VaultPalette.neutralTint)
						.overlay {
							Image(systemName: "folder")
								.font(.system(size: size * 0.45, weight: .medium))
								.foregroundStyle(folderColor)
						}
				} else {
					Image(systemName: "folder")
						.font(.system(size: size * 0.75, weight: .medium))
						.foregroundStyle(folderColor)
				}
			}
		}
		.frame(width: size, height: size)
		.accessibilityHidden(true)
	}

	private func tile<Content: View>(_ color: ProjectIconColor, @ViewBuilder content: () -> Content) -> some View {
		RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
			.fill(color.color)
			.overlay(content())
	}
}
