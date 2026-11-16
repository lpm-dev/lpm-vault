import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
			VaultPalette.curtain
			VStack(spacing: 12) {
				VaultAppMark(size: 56)
				Text("LPM Vault")
					.font(.headline)
			}
			.foregroundStyle(VaultPalette.curtainText)
		}
		.ignoresSafeArea()
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("LPM Vault content hidden while the app is inactive")
	}
}

private struct VaultPrivacyProtected: ViewModifier {
	let isObscured: Bool

	func body(content: Content) -> some View {
		// SwiftUI leaves a transparent view out of the accessibility tree and
		// one at full opacity as it is. accessibilityHidden(false) on an
		// ancestor would read out what its views hide themselves, such as
		// decorative icons, and a container adds a group VoiceOver steps into.
		content
			.opacity(isObscured ? 0 : 1)
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

/// The panels that choose a project's folder and an image for its icon.
@MainActor
enum VaultOpenPanel {
	static func projectFolder() -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Choose Folder"
		panel.message = "Choose the folder that contains your project’s package.json"
		guard runVaultPrivacyAwareModal(panel) == .OK else { return nil }
		return panel.url
	}

	/// Opens in `folder`, the project's, when it has one.
	static func iconImage(for projectName: String, in folder: String?) -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.image]
		panel.message = "Choose an image for \(projectName)"
		if let folder { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
		guard runVaultPrivacyAwareModal(panel) == .OK else { return nil }
		return panel.url
	}
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
		VaultMainWindow.current = window
		Self.style(window)
	}

	/// Draws `window` as LPM Vault's: its content runs under the title bar,
	/// which the app draws itself, with its own window buttons.
	static func style(_ window: NSWindow) {
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

/// The window a view is in, for what SwiftUI doesn't say about it, such as
/// whether a sheet is attached to it.
@MainActor
final class VaultHostWindow {
	fileprivate(set) weak var window: NSWindow?

	var hasAttachedSheet: Bool { window?.attachedSheet != nil }
}

struct VaultHostWindowReader: NSViewRepresentable {
	let host: VaultHostWindow

	func makeNSView(context: Context) -> NSView { ReaderView(host: host) }
	func updateNSView(_ nsView: NSView, context: Context) {}

	private final class ReaderView: NSView {
		let host: VaultHostWindow

		init(host: VaultHostWindow) {
			self.host = host
			super.init(frame: .zero)
		}

		required init?(coder: NSCoder) { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			host.window = window
		}

		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}

struct VaultWindowDragArea: NSViewRepresentable {
	func makeNSView(context: Context) -> VaultWindowDragView { VaultWindowDragView() }
	func updateNSView(_ nsView: VaultWindowDragView, context: Context) {}
}

/// Moves the window when it's pressed and dragged, as a title bar does.
final class VaultWindowDragView: NSView {
	override func mouseDown(with event: NSEvent) {
		window?.performDrag(with: event)
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
