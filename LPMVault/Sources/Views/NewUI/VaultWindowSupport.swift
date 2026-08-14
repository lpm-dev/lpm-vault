import AppKit
import SwiftUI

struct VaultWindowConfigurator: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async { configure(view.window) }
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		DispatchQueue.main.async { configure(nsView.window) }
	}

	private func configure(_ window: NSWindow?) {
		guard let window else { return }
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.backgroundColor = .white
		window.styleMask.insert(.fullSizeContentView)
		window.isMovableByWindowBackground = false
		for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
			window.standardWindowButton(button)?.isHidden = true
		}
	}
}

struct VaultWindowDragArea: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView { DragView() }
	func updateNSView(_ nsView: NSView, context: Context) {}

	private final class DragView: NSView {
		override func mouseDown(with event: NSEvent) {
			window?.performDrag(with: event)
		}

		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	}
}

struct VaultTrafficLights: View {
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 8) {
			light(color: Color(hex: 0xFF5F57), glyph: "xmark", help: "Close") { $0.performClose(nil) }
			light(color: Color(hex: 0xFEBC2E), glyph: "minus", help: "Minimize") { $0.performMiniaturize(nil) }
			light(color: Color(hex: 0x28C840), glyph: "plus", help: "Zoom") { $0.performZoom(nil) }
		}
		.onHover { hovering = $0 }
	}

	private func light(
		color: Color,
		glyph: String,
		help: String,
		action: @escaping (NSWindow) -> Void
	) -> some View {
		Button {
			if let window = NSApp.keyWindow ?? NSApp.windows.first { action(window) }
		} label: {
			Circle()
				.fill(color)
				.frame(width: 12, height: 12)
				.overlay {
					Image(systemName: glyph)
						.font(.system(size: 6.5, weight: .black))
						.foregroundStyle(.black.opacity(0.55))
						.opacity(hovering ? 1 : 0)
				}
		}
		.buttonStyle(.plain)
		.help(help)
		.accessibilityLabel(help)
	}
}
