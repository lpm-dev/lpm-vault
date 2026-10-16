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

/// One item of a menu opened from a button.
struct VaultMenuItem {
	enum Kind {
		case action(title: String, shortcut: String?, enabled: Bool, perform: () -> Void)
		case divider
	}

	let kind: Kind

	static func action(_ title: String, shortcut: String? = nil, enabled: Bool = true, perform: @escaping () -> Void) -> VaultMenuItem {
		VaultMenuItem(kind: .action(title: title, shortcut: shortcut, enabled: enabled, perform: perform))
	}

	static var divider: VaultMenuItem { VaultMenuItem(kind: .divider) }

	var title: String? {
		if case .action(let title, _, _, _) = kind { title } else { nil }
	}
}

/// The project header's "…" menu: its settings, its folder, and renaming and deleting it.
enum VaultProjectMenu {
	@MainActor
	static func headerItems(
		for project: VaultProject, folderExists: Bool,
		openSettings: @escaping () -> Void, rename: @escaping () -> Void, delete: @escaping () -> Void
	) -> [VaultMenuItem] {
		let path = project.path
		return [
			.action("Project Settings…", shortcut: "i", perform: openSettings),
			.divider,
			.action("Show in Finder", enabled: !path.isEmpty && folderExists) {
				NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
			},
			.action("Copy folder path", enabled: !path.isEmpty) {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(path, forType: .string)
			},
			.divider,
			.action("Rename…", perform: rename),
			.action("Delete Locally…", perform: delete),
		]
	}
}

/// A 27-point outline button that opens a native menu below it, drawn
/// pressed while the menu is open.
struct VaultMenuButton: View {
	let systemImage: String
	let help: String
	let items: () -> [VaultMenuItem]

	@State private var isOpen = false
	@State private var hovering = false
	@State private var anchor = VaultMenuAnchor()

	var body: some View {
		Button {
			guard !isOpen else { return }
			isOpen = true
			let menu = anchor.menu(for: items())
			// Lets the pressed look draw before the menu's tracking starts.
			DispatchQueue.main.async {
				anchor.popUp(menu)
				isOpen = false
			}
		} label: {
			Image(systemName: systemImage)
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(isOpen ? VaultPalette.accentText : VaultPalette.textSecondary)
				.frame(width: 27, height: 27)
				.background {
					RoundedRectangle(cornerRadius: 7)
						.fill(isOpen ? VaultPalette.accentTint : (hovering ? VaultPalette.sidebar : .clear))
				}
				.overlay {
					RoundedRectangle(cornerRadius: 7)
						.stroke(isOpen ? VaultPalette.accent : VaultPalette.border, lineWidth: 1)
				}
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.background(VaultMenuAnchorView(anchor: anchor))
		.help(help)
		.accessibilityLabel(help)
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}

/// The view a `VaultMenuButton`'s menu opens from, and the actions of its items.
@MainActor
final class VaultMenuAnchor {
	fileprivate weak var view: NSView?
	private var actions: [() -> Void] = []

	func menu(for items: [VaultMenuItem]) -> NSMenu {
		actions.removeAll()
		let menu = NSMenu()
		menu.autoenablesItems = false
		for item in items {
			switch item.kind {
			case .divider:
				menu.addItem(.separator())
			case .action(let title, let shortcut, let enabled, let perform):
				let menuItem = NSMenuItem(title: title, action: #selector(VaultMenuTarget.runItem(_:)), keyEquivalent: shortcut ?? "")
				if shortcut != nil { menuItem.keyEquivalentModifierMask = .command }
				menuItem.isEnabled = enabled
				menuItem.target = VaultMenuTarget.shared
				menuItem.tag = actions.count
				menuItem.representedObject = self
				actions.append(perform)
				menu.addItem(menuItem)
			}
		}
		return menu
	}

	func popUp(_ menu: NSMenu) {
		guard let view else { return }
		menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
	}

	fileprivate func perform(_ index: Int) {
		guard actions.indices.contains(index) else { return }
		actions[index]()
	}
}

@MainActor
private final class VaultMenuTarget: NSObject {
	static let shared = VaultMenuTarget()

	@objc func runItem(_ sender: NSMenuItem) {
		(sender.representedObject as? VaultMenuAnchor)?.perform(sender.tag)
	}
}

private struct VaultMenuAnchorView: NSViewRepresentable {
	let anchor: VaultMenuAnchor

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		anchor.view = view
		return view
	}

	func updateNSView(_ view: NSView, context: Context) {
		anchor.view = view
	}
}
