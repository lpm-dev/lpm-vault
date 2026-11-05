import SwiftUI

/// The key inspector's HISTORY: the last few changes to the key in each
/// environment, each with Roll Back… to its value before that change, and
/// Show All, which opens the History page on the key.
struct VaultKeyHistorySection: View {
	let store: VaultStore
	let project: VaultProject
	let key: String

	@State private var changes: Changes = .reading
	@State private var failure: String?

	private enum Changes: Equatable {
		case reading
		case read([HistoryEngine.Entry])
		case unavailable
	}

	/// What the section reads again on: the project, the key, and its values.
	private struct Input: Equatable {
		let projectID: String
		let key: String
		let values: [String: ExactText]
	}

	private static let perEnvironment = 3
	private static let readLimit = 40

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: Date()) }

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Text("HISTORY").vaultSectionLabel()
					.accessibilityAddTraits(.isHeader)
				Spacer(minLength: 4)
				Button("Show All") { history.show(project.id, key: key) }
					.buttonStyle(.plain)
					.font(.system(size: 11.5, weight: .semibold))
					.foregroundStyle(VaultPalette.accentForeground)
					.vaultPointingHand()
					.help("Show every change to \(key) on the History page")
					.accessibilityLabel("Show All changes to \(key)")
			}
			content
			if let failure {
				Text(failure)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 14)
		.task(id: input) { await read() }
	}

	private var input: Input {
		Input(
			projectID: project.id, key: key,
			values: project.environments.compactMapValues { $0[key].map(ExactText.init) })
	}

	@ViewBuilder
	private var content: some View {
		switch changes {
		case .reading:
			ProgressView().controlSize(.small).accessibilityLabel("Reading the history of \(key)")
		case .unavailable:
			Text("Local history can’t be read right now.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
		case .read(let entries) where entries.isEmpty:
			Text("No changes to \(key) are kept on this Mac yet.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		case .read(let entries):
			let ordered = store.orderedEnvironmentNames(for: project)
			ForEach(groups(entries, ordered: ordered), id: \.name) { group in
				VStack(alignment: .leading, spacing: 4) {
					HStack(spacing: 6) {
						VaultEnvSwatch(color: VaultHistoryEnvironmentChip(group.name, in: ordered).color, size: 7)
						Text(group.name)
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(VaultPalette.textPrimary)
					}
					.accessibilityElement(children: .combine)
					ForEach(group.changes, id: \.entry.id) { change in
						changeRow(change, environment: group.name, exists: ordered.contains(group.name))
					}
				}
			}
		}
	}

	private struct Change {
		let entry: HistoryEngine.Entry
		let keyChange: HistoryEngine.KeyChange
	}

	private struct Group {
		let name: String
		var changes: [Change]
	}

	/// Each environment's newest changes to the key, under every name it had,
	/// environments in the project's order, then any that are gone.
	private func groups(_ entries: [HistoryEngine.Entry], ordered: [String]) -> [Group] {
		var groups: [String: Group] = [:]
		var order: [String] = []
		// Newest first, so a rename adds the name the key had before it.
		var names: Set<String> = [key]
		for entry in entries {
			var earlier: [String] = []
			for environment in entry.environments {
				guard let change = environment.keys?.first(where: { names.contains($0.key) }) else { continue }
				if let from = change.renamedFrom { earlier.append(from) }
				if groups[environment.name] == nil {
					groups[environment.name] = Group(name: environment.name, changes: [])
					order.append(environment.name)
				}
				if groups[environment.name]!.changes.count < Self.perEnvironment {
					groups[environment.name]!.changes.append(Change(entry: entry, keyChange: change))
				}
			}
			names.formUnion(earlier)
		}
		let rank = Dictionary(ordered.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
		return order.enumerated()
			.sorted { (rank[$0.element] ?? .max, $0.offset) < (rank[$1.element] ?? .max, $1.offset) }
			.compactMap { groups[$0.element] }
	}

	private func changeRow(_ change: Change, environment: String, exists: Bool) -> some View {
		let badge = VaultHistoryText.badge(change.entry)
		let moment = text.moment(VaultHistoryText.date(change.entry.time))
		return HStack(spacing: 6) {
			Text(moment)
				.font(VaultTypography.tabular(11.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.fixedSize()
			VaultTagBadge(text: badge.text, foreground: badge.foreground, background: badge.warns ? VaultPalette.orangeTint : badge.background, size: 9.5)
			Text(Self.kind(change.keyChange))
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
				.truncationMode(.tail)
				.layoutPriority(-1)
			Spacer(minLength: 4)
			if exists {
				Button("Roll Back…") {
					Task { await rollBack(change, environment: environment) }
				}
				.buttonStyle(.plain)
				.font(.system(size: 11.5, weight: .semibold))
				.foregroundStyle(VaultPalette.accentForeground)
				.fixedSize()
				.vaultPointingHand()
				.help("Roll \(key) in \(environment) back to its value before this change")
				.accessibilityLabel("Roll Back \(key) in \(environment) to its value before \(moment)")
			}
		}
		.accessibilityElement(children: .contain)
	}

	private static func kind(_ change: HistoryEngine.KeyChange) -> String {
		switch change.change {
		case "added": "Added"
		case "removed": "Removed"
		case "renamed": change.renamedFrom.map { "Renamed from \($0)" } ?? "Renamed"
		default: "Changed"
		}
	}

	private func read() async {
		switch await history.changes(to: key, in: project.id, limit: Self.readLimit) {
		case .success(let entries): changes = .read(entries)
		case .failure: changes = .unavailable
		}
	}

	private func rollBack(_ change: Change, environment: String) async {
		failure = await history.reviewRollback(
			.key(key, environment: environment, entry: change.entry.id), in: project.id, entry: change.entry)?.description
	}
}
