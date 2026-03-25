import SwiftUI

/// A visually grouped set of toolbar buttons with rounded background.
/// Use multiple instances side by side to create separated groups.
struct ToolbarButtonGroup<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		HStack(spacing: 4) {
			content
		}
		.padding(.horizontal, 4)
		.padding(.vertical, 4)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
	}
}

/// A single toolbar icon button with consistent sizing.
struct ToolbarIconButton: View {
	let icon: String
	let help: String
	var role: ButtonRole?
	let action: () -> Void

	var body: some View {
		Button(role: role) {
			action()
		} label: {
			Image(systemName: icon)
				.frame(width: 26, height: 26)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(help)
	}
}
