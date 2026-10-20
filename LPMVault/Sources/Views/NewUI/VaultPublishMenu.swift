import SwiftUI

/// The Publish button's menu: the project's saved destinations, each a click
/// from its review, then a new destination and the Platforms page, where an
/// expired connection is fixed. It takes the window's keyboard as a menu
/// does, wherever focus is: ↑ and ↓ move through it, Return opens what's
/// highlighted, and Esc closes it.
struct VaultPublishMenu: View {
	let summaries: [PublishDestinationSummary]
	@Binding var isPresented: Bool
	let onPublish: (PublishDestination?) -> Void
	let onPlatforms: () -> Void
	var now: () -> Date = Date.init

	static let width: CGFloat = 380
	/// The rows show this tall at most, then scroll.
	private static let maximumListHeight: CGFloat = 300

	@State private var highlighted: Item?

	enum Item: Hashable {
		case destination(UUID)
		case newDestination
		case platforms
	}

	var body: some View {
		let entries = Entry.entries(for: summaries, now: now())
		VStack(alignment: .leading, spacing: 0) {
			header
			destinationList(entries)
			VaultHairline(color: VaultPalette.rowDivider).padding(.horizontal, 10)
			VStack(alignment: .leading, spacing: 0) {
				actionRow(.newDestination, symbol: "plus", title: "New destination…", emphasized: true)
				actionRow(.platforms, symbol: "square.stack.3d.up", title: "Platforms", emphasized: false)
			}
			.padding(6)
		}
		.frame(width: Self.width)
		.background {
			RoundedRectangle(cornerRadius: 10)
				.fill(VaultPalette.control)
				.shadow(color: VaultPalette.shadow.opacity(0.18), radius: 17, y: 14)
		}
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		.background {
			VaultMenuKeys { key in
				switch key {
				case .up: highlighted = Self.item(after: highlighted, by: -1, in: items(entries))
				case .down: highlighted = Self.item(after: highlighted, by: 1, in: items(entries))
				case .open: if let highlighted { open(highlighted, in: entries) }
				case .close: isPresented = false
				}
				return true
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Saved destinations")
	}

	private var header: some View {
		HStack(spacing: 8) {
			Text("SAVED DESTINATIONS · \(summaries.count)").vaultSectionLabel()
			Spacer(minLength: 8)
			if let source = Self.sharedSource(of: summaries) {
				Text("from \(VaultProject.displayName(for: source))")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
		}
		.padding(EdgeInsets(top: 10, leading: 12, bottom: 4, trailing: 12))
	}

	private func destinationList(_ entries: [Entry]) -> some View {
		let rows = VStack(alignment: .leading, spacing: 1) {
			ForEach(entries) { entry in destinationRow(entry) }
		}
		.padding(EdgeInsets(top: 2, leading: 6, bottom: 6, trailing: 6))
		return CappedHeight(maximum: Self.maximumListHeight) {
			ViewThatFits(in: .vertical) {
				rows
				ScrollViewReader { proxy in
					ScrollView { rows }
						.onChange(of: highlighted) { _, item in
							if let item { proxy.scrollTo(item) }
						}
				}
			}
		}
	}

	private func destinationRow(_ entry: Entry) -> some View {
		let item = Item.destination(entry.id)
		return Button { open(item, in: [entry]) } label: {
			HStack(spacing: 10) {
				PlatformLogo(platform: entry.platform, size: 24)
				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 6) {
						Text(entry.title)
							.font(VaultTypography.tabular(12, .semibold))
							.foregroundStyle(VaultPalette.textPrimary)
							.lineLimit(1)
							.truncationMode(.head)
						VaultTagBadge(text: entry.part, foreground: VaultPalette.textSecondary, background: VaultPalette.neutralTint, size: 11)
					}
					Text(entry.detail)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
				}
				Spacer(minLength: 6)
				Text(entry.when)
					.font(VaultTypography.tabular(11))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize()
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.background(RoundedRectangle(cornerRadius: 7).fill(highlighted == item ? VaultPalette.sidebarHover : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.id(item)
		.onHover { hovering in hover(item, hovering) }
		.help(entry.help)
		.accessibilityLabel(entry.accessibilityLabel)
		.accessibilityAddTraits(highlighted == item ? .isSelected : [])
	}

	private func actionRow(_ item: Item, symbol: String, title: String, emphasized: Bool) -> some View {
		Button { open(item, in: []) } label: {
			HStack(spacing: 9) {
				Image(systemName: symbol)
					.font(.system(size: emphasized ? 11 : 12, weight: emphasized ? .bold : .regular))
					.foregroundStyle(emphasized ? VaultPalette.accentText : VaultPalette.textSecondary)
					.frame(width: 24)
					.accessibilityHidden(true)
				Text(title)
					.font(.system(size: 12.5, weight: emphasized ? .semibold : .regular))
					.foregroundStyle(emphasized ? VaultPalette.accentText : VaultPalette.textPrimary)
				Spacer(minLength: 4)
				if item == .platforms {
					Image(systemName: "chevron.right")
						.font(.system(size: 9, weight: .semibold))
						.foregroundStyle(VaultPalette.textTertiary)
						.accessibilityHidden(true)
				}
			}
			.padding(.horizontal, 10)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 7).fill(highlighted == item ? VaultPalette.sidebarHover : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering in hover(item, hovering) }
		.accessibilityAddTraits(highlighted == item ? .isSelected : [])
	}

	private func hover(_ item: Item, _ hovering: Bool) {
		if hovering {
			highlighted = item
		} else if highlighted == item {
			highlighted = nil
		}
	}

	private func items(_ entries: [Entry]) -> [Item] {
		entries.map { Item.destination($0.id) } + [.newDestination, .platforms]
	}

	/// The item a step down or up from `current` highlights, around from either end, as in a menu.
	static func item(after current: Item?, by step: Int, in items: [Item]) -> Item? {
		guard !items.isEmpty else { return nil }
		guard let current, let index = items.firstIndex(of: current) else { return step > 0 ? items.first : items.last }
		return items[(index + step % items.count + items.count) % items.count]
	}

	private func open(_ item: Item, in entries: [Entry]) {
		switch item {
		case .destination(let id):
			guard let entry = entries.first(where: { $0.id == id }) else { return }
			isPresented = false
			onPublish(entry.destination)
		case .newDestination:
			isPresented = false
			onPublish(nil)
		case .platforms:
			isPresented = false
			onPlatforms()
		}
	}

	/// The environment every destination publishes from, when they share one.
	static func sharedSource(of summaries: [PublishDestinationSummary]) -> String? {
		guard let first = summaries.first?.destination.sourceEnvironment,
			summaries.allSatisfy({ $0.destination.sourceEnvironment == first })
		else { return nil }
		return first
	}

	/// What a saved destination's row says.
	struct Entry: Identifiable, Equatable {
		let destination: PublishDestination
		/// The place, such as a Vercel project or a Worker.
		let title: String
		/// The part of the place written to, in its pill.
		let part: String
		/// Where it publishes from, and the account holding the place.
		let detail: String
		/// When this Mac last published there.
		let when: String
		let accessibilityLabel: String
		/// The whole place and account, for the tooltip.
		let help: String

		var id: UUID { destination.id }
		var platform: PublishPlatform { destination.target.platform }

		/// Each summary's row. A row names its connection's detail, such as a
		/// Vercel team's slug, only when another destination's account on the
		/// same platform has the same name through another connection.
		static func entries(for summaries: [PublishDestinationSummary], now: Date) -> [Entry] {
			struct Account: Hashable {
				let platform: PublishPlatform
				let name: String
			}
			var connections: [Account: Set<String>] = [:]
			for summary in summaries {
				let target = summary.destination.target
				guard let connection = target.connectionID else { continue }
				connections[Account(platform: target.platform, name: target.accountName), default: []].insert(connection)
			}
			return summaries.map { summary in
				let target = summary.destination.target
				let shared = (connections[Account(platform: target.platform, name: target.accountName)]?.count ?? 0) > 1
				return Entry(summary, distinguishingAccount: shared, now: now)
			}
		}

		init(_ summary: PublishDestinationSummary, distinguishingAccount: Bool = false, now: Date) {
			let target = summary.destination.target
			destination = summary.destination
			title = target.placeTitle
			part = target.placePart
			let account = target.placeAccountName.map { name in
				guard distinguishingAccount, let detail = summary.accountDetail else { return name }
				return "\(name) (\(detail))"
			}
			let source = "from \(VaultProject.displayName(for: summary.destination.sourceEnvironment))"
			detail = [source, account, target.placeDetail].compactMap { $0 }.joined(separator: " · ")
			let published = summary.lastPublishedAt.map { RelativeTimestampFormatter.string(from: $0, now: now) }
			when = published ?? "Never"
			accessibilityLabel = [title, part, target.platform.displayName, detail, published.map { "published \($0)" } ?? "never published"]
				.joined(separator: ", ")
			help = ["\(target.placeName) on \(target.platform.displayName)", detail, summary.accountDetail.map { "Through \(target.connectionName) (\($0))" }]
				.compactMap { $0 }
				.joined(separator: "\n")
		}
	}
}

/// As tall as its content up to `maximum`, which its content is offered, however
/// much room there is: a `maxHeight` frame would grow to the maximum instead.
private struct CappedHeight: Layout {
	let maximum: CGFloat

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		guard let content = subviews.first else { return .zero }
		let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: maximum))
		return CGSize(width: proposal.width ?? size.width, height: min(size.height, maximum))
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
	}
}

/// Where the Publish button is, so its menu opens under it.
struct VaultPublishButtonAnchor: PreferenceKey {
	static var defaultValue: Anchor<CGRect>? { nil }

	static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
		value = value ?? nextValue()
	}
}
