import AppKit
import SwiftUI

private struct VaultContentObscuredKey: EnvironmentKey {
	static let defaultValue = false
}

extension EnvironmentValues {
	var vaultContentObscured: Bool {
		get { self[VaultContentObscuredKey.self] }
		set { self[VaultContentObscuredKey.self] = newValue }
	}
}

struct VaultPrivacyCurtain: View {
	var body: some View {
		ZStack {
			VaultPalette.terminal
			VStack(spacing: 12) {
				VaultAppMark(size: 56)
				Text("LPM Vault")
					.font(.headline)
			}
			.foregroundStyle(Color.white.opacity(0.65))
		}
		.ignoresSafeArea()
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("LPM Vault content hidden while the app is inactive")
	}
}

private struct VaultPrivacyProtected: ViewModifier {
	let isObscured: Bool

	func body(content: Content) -> some View {
		content
			.accessibilityHidden(isObscured)
			.overlay {
				if isObscured { VaultPrivacyCurtain() }
			}
	}
}

extension View {
	func vaultPrivacyProtected(_ isObscured: Bool) -> some View {
		modifier(VaultPrivacyProtected(isObscured: isObscured))
	}
}

@MainActor
func runVaultPrivacyAwareModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
	let inactivityObserver = VaultModalPanelInactivityObserver(panel: panel)
	defer { inactivityObserver.stop() }
	return panel.runModal()
}

@MainActor
private final class VaultModalPanelInactivityObserver: NSObject {
	private weak var panel: NSSavePanel?

	init(panel: NSSavePanel) {
		self.panel = panel
		super.init()
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(applicationDidResignActive),
			name: NSApplication.didResignActiveNotification,
			object: nil
		)
	}

	func stop() {
		NotificationCenter.default.removeObserver(self)
		panel = nil
	}

	@objc private func applicationDidResignActive() {
		panel?.cancel(nil)
	}
}

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
		window.backgroundColor = NSColor(VaultPalette.content)
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
