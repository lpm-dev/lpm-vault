import SwiftUI

extension EnvironmentValues {
	/// The setting Settings' search asks its page to bring into view and mark.
	@Entry var vaultSettingsHighlight: VaultSettingsSearch.Highlight? = nil
}

/// The settings a page has laid out, so its scroll view brings the one search
/// chose into view once it's there.
struct VaultSettingsAnchors: PreferenceKey {
	static let defaultValue: Set<VaultSettingsEntry.ID> = []

	static func reduce(value: inout Set<VaultSettingsEntry.ID>, nextValue: () -> Set<VaultSettingsEntry.ID>) {
		value.formUnion(nextValue())
	}
}

extension View {
	/// Where `entry` is on its page: search scrolls here when it's chosen, and
	/// tints it a moment. `outset` is how far the tint reaches past it.
	func vaultSettingsAnchor(_ entry: VaultSettingsEntry, outset: CGSize = CGSize(width: 8, height: 6)) -> some View {
		modifier(VaultSettingsAnchor(entry: entry, outset: outset))
	}
}

private struct VaultSettingsAnchor: ViewModifier {
	let entry: VaultSettingsEntry
	let outset: CGSize
	@Environment(\.vaultSettingsHighlight) private var highlight
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var marked = false

	/// How long a chosen setting stays tinted before the tint fades.
	private static let markDuration: Duration = .milliseconds(1600)

	func body(content: Content) -> some View {
		content
			.background {
				RoundedRectangle(cornerRadius: 8)
					.fill(VaultPalette.accentTint)
					.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.focusRing.opacity(0.55), lineWidth: 1) }
					.padding(.horizontal, -outset.width)
					.padding(.vertical, -outset.height)
					.opacity(marked ? 1 : 0)
					.allowsHitTesting(false)
					.accessibilityHidden(true)
			}
			.id(entry.id)
			.preference(key: VaultSettingsAnchors.self, value: [entry.id])
			.task(id: highlight) {
				guard highlight?.entry == entry else {
					if marked { marked = false }
					return
				}
				marked = true
				try? await Task.sleep(for: Self.markDuration)
				guard !Task.isCancelled else { return }
				withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { marked = false }
			}
	}
}

/// A Settings page's scroll view. It brings the setting search chose into view
/// once the page has laid it out, which a page just opened hasn't yet, and
/// after the update that found it there: a scroll asked for within that update
/// is dropped.
struct VaultSettingsScroller<Content: View>: View {
	@ViewBuilder let content: Content
	@Environment(\.vaultSettingsHighlight) private var highlight
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var anchors: Set<VaultSettingsEntry.ID> = []

	private var target: VaultSettingsSearch.Highlight? {
		guard let highlight, anchors.contains(highlight.entry.id) else { return nil }
		return highlight
	}

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView { content }
				.onPreferenceChange(VaultSettingsAnchors.self) { anchors = $0 }
				.task(id: target) {
					guard let target else { return }
					withAnimation(reduceMotion ? nil : VaultMotion.panel) { proxy.scrollTo(target.entry.id, anchor: .center) }
				}
		}
	}
}

/// Settings' search field, at the top of its menu.
struct VaultSettingsSearchField: View {
	@Bindable var search: VaultSettingsSearch
	var focused: FocusState<Bool>.Binding

	var body: some View {
		HStack(spacing: 7) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.textTertiary)
				.accessibilityHidden(true)
			TextField(vaultPrompt: "Search", text: $search.query)
				.textFieldStyle(.plain)
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textPrimary)
				.autocorrectionDisabled()
				.focused(focused)
				.accessibilityLabel("Search Settings")
			if search.query.isEmpty {
				Text("⌘F")
					.font(VaultTypography.tabular(10))
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
			} else {
				Button { search.clear() } label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Clear search")
			}
		}
		.padding(.horizontal, 9)
		.frame(height: 30)
		.vaultSearchField(focused: focused.wrappedValue)
	}
}

/// What Settings' search found, in the menu's place: each page's settings
/// under its name. Choosing one shows it on its page.
struct VaultSettingsSearchResults: View {
	let search: VaultSettingsSearch
	let show: (VaultSettingsEntry) -> Void

	private struct Page: Identifiable {
		let category: VaultSettingsCategory
		var entries: [VaultSettingsEntry]
		var id: VaultSettingsCategory { category }
	}

	/// The results by page, in the order search ranked them.
	private var pages: [Page] {
		var pages: [Page] = []
		for entry in search.results {
			if pages.last?.category == entry.category {
				pages[pages.count - 1].entries.append(entry)
			} else {
				pages.append(Page(category: entry.category, entries: [entry]))
			}
		}
		return pages
	}

	var body: some View {
		if search.results.isEmpty {
			Text("No settings match “\(search.query.trimmingCharacters(in: .whitespaces))”.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.horizontal, 9)
				.padding(.top, 4)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		} else {
			ScrollViewReader { proxy in
				ScrollView {
					VStack(alignment: .leading, spacing: 1) {
						ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
							Text(page.category.title.uppercased())
								.vaultSectionLabel()
								.accessibilityAddTraits(.isHeader)
								.padding(.horizontal, 9)
								.padding(.top, index == 0 ? 2 : 12)
								.padding(.bottom, 4)
							ForEach(page.entries) { entry in
								VaultSettingsResultRow(entry: entry, selected: search.selected == entry.id) { show(entry) }
									.id(entry.id)
							}
						}
					}
				}
				.scrollIndicators(.never)
				// Arrows move through the results from the field, so the one shown stays in sight.
				.onChange(of: search.selected) { _, selected in
					guard let selected else { return }
					proxy.scrollTo(selected)
				}
			}
		}
	}
}

private struct VaultSettingsResultRow: View {
	let entry: VaultSettingsEntry
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Text(entry.title)
				.font(.system(size: 12.5, weight: selected ? .semibold : .regular))
				.foregroundStyle(VaultPalette.textPrimary)
				.lineLimit(2)
				.multilineTextAlignment(.leading)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 9)
				.padding(.vertical, 6)
				.frame(minHeight: 28)
				.background(RoundedRectangle(cornerRadius: 7)
					.fill(selected ? VaultPalette.sidebarSelection : (hovering ? VaultPalette.sidebarHover : .clear)))
				.contentShape(Rectangle())
				.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle())
		.onHover { hovering = $0 }
		.help(entry.title)
		.accessibilityHint("Shows it in \(entry.category.title)")
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}
