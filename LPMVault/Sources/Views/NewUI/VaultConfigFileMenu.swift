import AppKit
import SwiftUI

extension EnvironmentValues {
	/// Where the Open lpm.json menu finds the apps that open JSON; tests give their own.
	@Entry var vaultConfigEditors = ProjectConfigOpener.Catalog.system
}

/// lpm.json's button in a page's header: a menu that opens the file in the
/// app last chosen for JSON or in another that opens it, shows it in Finder,
/// or copies its path. Choosing another app keeps it for next time.
struct VaultConfigFileMenu: View {
	/// lpm.json; nil while there's none to open, which turns the button off.
	let file: URL?
	/// Shows only the button's symbol, where its header has no room for its title.
	var compact = false
	let onCopyPath: (String) -> Void

	@Environment(\.vaultConfigEditors) private var catalog
	@State private var isOpen = false
	@State private var hovering = false
	/// Reading the apps that open JSON, before the menu opens with them.
	@State private var loading: Task<Void, Never>?
	/// The apps that open JSON, and the menu's rows with their icons, read as
	/// the menu opens, since apps come and go.
	@State private var editors: [ProjectConfigOpener.Editor] = []
	@State private var rows: [VaultMenuList<Choice>.Row] = []

	enum Choice: Hashable {
		case open(URL)
		case reveal
		case copyPath
	}

	private var disabled: Bool { file == nil }

	var body: some View {
		Button {
			guard !isOpen else { return isOpen = false }
			guard loading == nil else { return }
			let list = catalog.list
			loading = Task {
				let found = await BlockingWork.run { list() }
				loading = nil
				guard !Task.isCancelled else { return }
				editors = found
				rows = Self.rows(editors: found)
				isOpen = true
			}
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "doc")
					.font(.system(size: 11.5))
					.frame(width: 14)
				if !compact {
					Text("Open lpm.json").font(.system(size: 12.5))
				}
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(disabled ? VaultPalette.disabledText : VaultPalette.textTertiary)
			}
			.foregroundStyle(disabled ? VaultPalette.disabledText : (isOpen ? VaultPalette.selectedText : VaultPalette.textSecondary))
			.padding(.horizontal, compact ? 7 : 9)
			.frame(height: 28)
			.background { RoundedRectangle(cornerRadius: 7).fill(isOpen ? VaultPalette.selectedFill : (hovering && !disabled ? VaultPalette.controlHover : .clear)) }
			.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(isOpen ? VaultPalette.selectedBorder : .clear, lineWidth: 1) }
			.vaultHoverAnimation(hovering)
			.contentShape(Rectangle())
			.fixedSize()
		}
		.buttonStyle(VaultPressStyle())
		.disabled(disabled)
		.onHover { hovering = $0 }
		.help(disabled ? "lpm.json can’t be opened yet" : "Open lpm.json, show it in Finder, or copy its path")
		.accessibilityLabel("Open lpm.json")
		.accessibilityHint("Shows the apps that open it, Show in Finder and Copy Path")
		.vaultMenu(isPresented: $isOpen, rows: rows, width: 260, label: "Open lpm.json", onChoose: choose)
		.onDisappear {
			loading?.cancel()
			loading = nil
		}
	}

	/// The app that opens lpm.json first, then the others that can, then Finder and the path.
	static func rows(editors: [ProjectConfigOpener.Editor], icon: (URL) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0.path) }) -> [VaultMenuList<Choice>.Row] {
		var rows: [VaultMenuList<Choice>.Row] = []
		if let first = editors.first {
			rows.append(.init(id: .open(first.url), title: "Open in \(first.name)", detail: first.version, image: icon(first.url)))
		}
		for (index, editor) in editors.dropFirst().enumerated() {
			rows.append(.init(id: .open(editor.url), title: editor.name, detail: editor.version, section: index == 0 ? "Open With" : nil,
				image: icon(editor.url), accessibilityLabel: "Open in \(editor.name)" + (editor.version.map { " \($0)" } ?? "")))
		}
		rows.append(.init(id: .reveal, title: "Show in Finder", separated: true, systemImage: "folder"))
		rows.append(.init(id: .copyPath, title: "Copy Path", systemImage: "doc.on.doc"))
		return rows
	}

	private func choose(_ choice: Choice) {
		guard let file else { return }
		switch choice {
		case .open(let editor):
			// The first is already the app that opens JSON; another becomes it.
			catalog.open(file, editor, editor != editors.first?.url)
		case .reveal:
			ProjectConfigOpener.reveal(file)
		case .copyPath:
			onCopyPath(file.path)
			AccessibilityNotification.Announcement("lpm.json’s path copied").post()
		}
	}
}
