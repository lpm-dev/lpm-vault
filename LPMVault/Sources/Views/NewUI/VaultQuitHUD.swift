import AppKit
import SwiftUI

/// The hint ⌘Q shows when it takes a second press or a hold to quit.
struct VaultQuitHUD: View {
	let hint: VaultQuitGate.Hint
	let visible: Bool

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.colorScheme) private var colorScheme
	@State private var progress: CGFloat = 0

	var body: some View {
		HStack(spacing: 9) {
			switch hint {
			case .pressAgain:
				Text("⌘Q")
					.font(VaultTypography.mono(11.5, .semibold))
					.foregroundStyle(VaultPalette.textSecondary)
					.padding(.horizontal, 5)
					.padding(.vertical, 1)
					.background(RoundedRectangle(cornerRadius: 4).fill(VaultPalette.neutralTint))
				Text("Press ⌘Q again to quit")
			case .hold(let duration):
				ZStack {
					Circle().stroke(VaultPalette.border, lineWidth: 2)
					Circle()
						.trim(from: 0, to: progress)
						.stroke(VaultPalette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
						.rotationEffect(.degrees(-90))
				}
				.frame(width: 14, height: 14)
				.frame(width: 16, height: 16)
				.onAppear {
					progress = 0
					withAnimation(.linear(duration: duration)) { progress = 1 }
				}
				Text("Hold ⌘Q to quit")
			}
		}
		.font(.system(size: 13))
		.foregroundStyle(VaultPalette.textPrimary)
		.lineLimit(1)
		.fixedSize()
		.padding(.leading, 12)
		.padding(.trailing, 14)
		.frame(height: 36)
		.background {
			Capsule().fill(.thinMaterial)
			Capsule().fill(Color(hex: colorScheme == .dark ? 0x323234 : 0xFFFFFF).opacity(0.86))
		}
		.overlay {
			Capsule().strokeBorder(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.5)
		}
		.shadow(color: .black.opacity(0.28), radius: 12, y: 8)
		.opacity(visible ? 1 : 0)
		.scaleEffect(visible || reduceMotion ? 1 : 0.96)
		.padding(VaultQuitHUDController.shadowMargin)
		.accessibilityElement(children: .combine)
	}
}

/// Shows the quit hint in a panel of its own, so it floats above sheets and
/// shows even while the window is closed: centered 44 points above the
/// bottom of the app's window, or of the screen when there's none.
@MainActor
final class VaultQuitHUDController {
	static let shadowMargin: CGFloat = 24
	static let bottomInset: CGFloat = 44

	@Observable
	@MainActor
	final class Model {
		var hint: VaultQuitGate.Hint = .pressAgain
		var visible = false
		/// Restarts the hold ring each time the hint shows.
		var presentation = UUID()
	}

	let model = Model()
	private(set) var panel: NSPanel?
	var isShowing: Bool { showing != nil }
	private var hideWork: DispatchWorkItem?
	/// The showing in progress; hiding ends it, so a show it overtakes doesn't appear.
	private var showing: UUID?

	func show(_ hint: VaultQuitGate.Hint) {
		hideWork?.cancel()
		hideWork = nil
		let panel = self.panel ?? makePanel()
		model.hint = hint
		model.presentation = UUID()
		model.visible = false
		panel.contentView?.layoutSubtreeIfNeeded()
		let size = panel.contentView?.fittingSize ?? .zero
		panel.setFrame(frame(for: size), display: false)
		panel.orderFrontRegardless()
		let token = UUID()
		showing = token
		let duration = reduceMotion ? 0.1 : 0.15
		// The fresh view draws hidden first, so showing it animates.
		DispatchQueue.main.async { [weak self] in
			guard let self, showing == token else { return }
			withAnimation(.easeOut(duration: duration)) { model.visible = true }
		}
		let text = switch hint {
		case .pressAgain: "Press Command Q again to quit"
		case .hold: "Hold Command Q to quit"
		}
		NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
			userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
	}

	func hide() {
		guard let panel, showing != nil else { return }
		showing = nil
		guard model.visible else {
			panel.orderOut(nil)
			return
		}
		let duration = reduceMotion ? 0.1 : 0.3
		withAnimation(.easeOut(duration: duration)) { model.visible = false }
		let work = DispatchWorkItem { [weak self, weak panel] in
			guard let self, showing == nil else { return }
			panel?.orderOut(nil)
		}
		hideWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
	}

	private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

	private func makePanel() -> NSPanel {
		let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.ignoresMouseEvents = true
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = true
		panel.level = .floating
		panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
		panel.contentView = NSHostingView(rootView: VaultQuitHUDRoot(model: model))
		self.panel = panel
		return panel
	}

	private func frame(for size: NSSize) -> NSRect {
		let anchor = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0 !== panel }
		let area = anchor?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
		return NSRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + Self.bottomInset - Self.shadowMargin,
			width: size.width, height: size.height)
	}
}

private struct VaultQuitHUDRoot: View {
	let model: VaultQuitHUDController.Model

	var body: some View {
		VaultQuitHUD(hint: model.hint, visible: model.visible)
			.id(model.presentation)
	}
}
