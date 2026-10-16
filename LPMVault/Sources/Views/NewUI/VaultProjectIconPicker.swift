import SwiftUI

/// Chooses a symbol on a colored tile, an emoji, or a monogram as a
/// project's icon. The choice goes back to Project Settings, which saves it.
struct VaultProjectIconPicker: View {
	enum Tab: String, CaseIterable, Identifiable {
		case icons = "Icons"
		case emoji = "Emoji"
		case monogram = "Monogram"

		var id: String { rawValue }
	}

	static let columns = 10
	private static let cellHeight: CGFloat = 44
	private static let cellSpacing: CGFloat = 4
	private static let visibleRows: CGFloat = 4

	let projectName: String
	let onUse: (ProjectIconChoice) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var tab: Tab
	@State private var color: ProjectIconColor
	@State private var symbol: String
	@State private var emoji: String?
	@State private var letters: String
	@State private var query = ""
	@FocusState private var searchFocused: Bool
	@FocusState private var lettersFocused: Bool

	init(projectName: String, initial: ProjectIconChoice, onUse: @escaping (ProjectIconChoice) -> Void) {
		self.projectName = projectName
		self.onUse = onUse
		var tab = Tab.icons
		var color = ProjectIconColor.indigo
		var symbol = "folder"
		var emoji: String?
		var letters = ProjectIconChoice.suggestedMonogram(for: projectName)
		switch initial {
		case .symbol(let name, let chosen):
			symbol = name
			color = chosen
		case .emoji(let chosen):
			tab = .emoji
			emoji = chosen
		case .monogram(let chosen, let chosenColor):
			tab = .monogram
			letters = chosen
			color = chosenColor
		case .automatic, .projectFile, .storedImage:
			break
		}
		_tab = State(initialValue: tab)
		_color = State(initialValue: color)
		_symbol = State(initialValue: symbol)
		_emoji = State(initialValue: emoji)
		_letters = State(initialValue: letters)
	}

	/// What Use Icon would choose, or nil while the tab has nothing chosen.
	var choice: ProjectIconChoice? {
		switch tab {
		case .icons: .symbol(symbol, color)
		case .emoji: emoji.map(ProjectIconChoice.emoji)
		case .monogram: ProjectIconChoice.normalizedMonogram(letters).map { .monogram($0, color) }
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VStack(alignment: .leading, spacing: 16) {
				Picker("Icon kind", selection: $tab) {
					ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
				if tab != .emoji { colorRow }
				switch tab {
				case .icons:
					searchField("Search symbols") { symbol = ProjectIconCatalog.symbols(matching: query).first?.value ?? symbol }
					grid(ProjectIconCatalog.symbols(matching: query), selected: symbol) { entry in
						Image(systemName: entry.value)
							.font(.system(size: 18))
							.foregroundStyle(color.color)
					} select: { symbol = $0 }
				case .emoji:
					searchField("Search emoji") { emoji = emojiEntries.first?.value ?? emoji }
					grid(emojiEntries, selected: emoji) { entry in
						Text(entry.value).font(.system(size: 22))
					} select: { emoji = $0 }
				case .monogram:
					monogramRow
				}
			}
			.padding(.horizontal, 24)
			.padding(.bottom, 18)
			VaultSheetFooter {
				Text("Replaces the automatic icon. Reset to Automatic from Project Settings.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			} actions: {
				VaultBarButton(title: "Cancel", height: 28) { dismiss() }
					.keyboardShortcut(.cancelAction)
				VaultBarButton(title: "Use Icon", filled: true, disabled: choice == nil, height: 28) { use() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.frame(width: 560)
		.background(VaultPalette.content)
		.onChange(of: tab) { _, _ in query = "" }
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Choose project icon")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Choose a symbol, an emoji or a monogram.")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			VaultSheetCloseButton { dismiss() }
		}
		.padding(.horizontal, 24)
		.padding(.top, 18)
		.padding(.bottom, 14)
	}

	private var colorRow: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Color")
				.font(.system(size: 12.5, weight: .semibold))
				.foregroundStyle(VaultPalette.textSecondary)
			HStack(spacing: 10) {
				ForEach(ProjectIconColor.allCases) { swatch in
					Button { color = swatch } label: {
						Circle()
							.fill(swatch.color)
							.frame(width: 22, height: 22)
							.overlay {
								if swatch == color {
									Circle().strokeBorder(VaultPalette.textPrimary, lineWidth: 1.5).padding(-3.5)
								}
							}
							.contentShape(Circle())
					}
					.buttonStyle(.plain)
					.help(swatch.title)
					.accessibilityLabel(swatch.title)
					.accessibilityAddTraits(swatch == color ? .isSelected : [])
				}
			}
			.padding(.leading, 3.5)
		}
	}

	/// The search field; Return in it chooses the first match.
	private func searchField(_ prompt: String, onSubmit: @escaping () -> Void) -> some View {
		HStack(spacing: 6) {
			TextField(prompt, text: $query)
				.textFieldStyle(.plain)
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textPrimary)
				.focused($searchFocused)
				.onSubmit(onSubmit)
				.accessibilityLabel(prompt)
			Image(systemName: "magnifyingglass")
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(VaultPalette.textTertiary)
		}
		.padding(.horizontal, 9)
		.frame(height: 28)
		.vaultInputField(focused: searchFocused)
	}

	/// The emoji matching the search, led by one typed or pasted there that the list doesn't have.
	private var emojiEntries: [ProjectIconCatalog.Entry] {
		var entries = ProjectIconCatalog.emoji(matching: query)
		let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		if ProjectIconChoice.isEmoji(typed), !entries.contains(where: { $0.value == typed }) {
			entries.insert(.init(value: typed, keywords: ""), at: 0)
		}
		return entries
	}

	private func grid<Glyph: View>(
		_ entries: [ProjectIconCatalog.Entry], selected: String?,
		@ViewBuilder glyph: @escaping (ProjectIconCatalog.Entry) -> Glyph, select: @escaping (String) -> Void
	) -> some View {
		let height = Self.visibleRows * Self.cellHeight + (Self.visibleRows - 1) * Self.cellSpacing
		return ScrollView {
			if entries.isEmpty {
				Text("Nothing matches “\(query)”")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
					.frame(maxWidth: .infinity, minHeight: height)
			} else {
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.cellSpacing), count: Self.columns), spacing: Self.cellSpacing) {
					ForEach(entries) { entry in
						VaultIconPickerCell(selected: entry.value == selected, help: entry.value) {
							glyph(entry)
						} action: {
							select(entry.value)
						}
					}
				}
			}
		}
		.frame(height: height)
	}

	private var monogramRow: some View {
		HStack(spacing: 10) {
			Text("Letters")
				.font(.system(size: 12.5, weight: .semibold))
				.foregroundStyle(VaultPalette.textSecondary)
			TextField("", text: Binding(
				get: { letters },
				set: { letters = String($0.prefix(ProjectIconChoice.maximumMonogramLength * 2)) }
			))
			.textFieldStyle(.plain)
			.font(.system(size: 12.5))
			.foregroundStyle(VaultPalette.textPrimary)
			.focused($lettersFocused)
			.onSubmit(use)
			.padding(.horizontal, 9)
			.frame(width: 72, height: 28)
			.vaultInputField(focused: lettersFocused, invalid: ProjectIconChoice.normalizedMonogram(letters) == nil)
			.accessibilityLabel("Monogram letters")
			Text("1–2 letters or digits")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
			Spacer(minLength: 0)
			if let monogram = ProjectIconChoice.normalizedMonogram(letters) {
				VaultProjectIconView(appearance: .monogram(monogram, color), size: 28)
			}
		}
	}

	private func use() {
		guard let choice else { return }
		onUse(choice)
		dismiss()
	}
}

private struct VaultIconPickerCell<Glyph: View>: View {
	let selected: Bool
	let help: String
	@ViewBuilder let glyph: Glyph
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			glyph
				.frame(maxWidth: .infinity)
				.frame(height: 44)
				.background {
					RoundedRectangle(cornerRadius: 8)
						.fill(selected ? VaultPalette.neutralTint : (hovering ? VaultPalette.rowHover : .clear))
				}
				.overlay {
					if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
				}
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(help)
		.accessibilityLabel(help)
		.accessibilityAddTraits(selected ? .isSelected : [])
		.onHover { hovering = $0 }
	}
}
