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
	@Environment(\.vaultClock) private var clock

	private enum Changes: Equatable {
		case reading
		/// Each environment's newest changes to the key, environments in the
		/// project's order.
		case read([Group])
		case off
		case unavailable
	}

	/// What the section reads again on: the project, the key, its values, and
	/// the environments' names.
	private struct Input: Equatable {
		let projectID: String
		let key: String
		let environments: [String]
		let values: [String: ExactText]
	}

	private static let perEnvironment = 2

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: clock.now()) }

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Text("HISTORY").vaultSectionLabel()
					.accessibilityAddTraits(.isHeader)
				Spacer(minLength: 4)
				Button("Show All") { history.show(project.id, key: key) }
					.buttonStyle(.plain)
					.font(.system(size: 12, weight: .medium))
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
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.task(id: input) { await read() }
	}

	private var input: Input {
		Input(
			projectID: project.id, key: key, environments: store.orderedEnvironmentNames(for: project),
			values: project.environments.compactMapValues { $0[key].map(ExactText.init) })
	}

	@ViewBuilder
	private var content: some View {
		switch changes {
		case .reading:
			ProgressView().controlSize(.small).accessibilityLabel("Reading the history of \(key)")
		case .off:
			Text("Local history is off for this project.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
		case .unavailable:
			Text("Local history can’t be read right now.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
		case .read(let groups) where groups.isEmpty:
			Text("No changes to \(key) are kept on this Mac yet.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		case .read(let groups):
			let ordered = store.orderedEnvironmentNames(for: project)
			ForEach(groups, id: \.environment) { group in
				// The environment labels the group; each change reads as a plain line under it.
				VStack(alignment: .leading, spacing: 8) {
					HStack(spacing: 7) {
						VaultEnvSwatch(color: VaultHistoryEnvironmentChip(group.environment, in: ordered).color, size: 7)
						Text(VaultProject.displayName(for: group.environment))
							.font(.system(size: 11.5, weight: .semibold))
							.foregroundStyle(VaultPalette.textSecondary)
					}
					.accessibilityElement(children: .combine)
					ForEach(group.changes, id: \.entry.id) { change in
						changeRow(change, environment: group.environment)
					}
				}
			}
		}
	}

	struct Change: Equatable {
		let entry: HistoryEngine.Entry
		/// The key's change in the entry, nil when the entry kept no keys.
		let keyChange: HistoryEngine.KeyChange?
	}

	struct Group: Equatable {
		/// The environment's name now.
		let environment: String
		let changes: [Change]
	}

	/// Each environment's changes to the key as the engine matched them,
	/// newest first, with the key's change in each: within one environment's
	/// changes, a rename names the environment and the key as they were before it.
	static func groups(_ changes: [String: [HistoryEngine.Entry]], key: String, environments: [String], limit: Int) -> [Group] {
		environments.compactMap { environment in
			guard let entries = changes[environment], !entries.isEmpty else { return nil }
			var environmentName = environment
			var keyName = key
			var found: [Change] = []
			for entry in entries {
				let changed = entry.environments.first { $0.name == environmentName }
				let keyChange = changed?.keys?.first { $0.key == keyName }
				if found.count < limit { found.append(Change(entry: entry, keyChange: keyChange)) }
				if let from = keyChange?.renamedFrom { keyName = from }
				if let from = changed?.renamedFrom { environmentName = from }
			}
			return Group(environment: environment, changes: found)
		}
	}

	/// What changed on the first line, when and by what on the second, and
	/// the rollback on the trailing edge.
	private func changeRow(_ change: Change, environment: String) -> some View {
		let badge = VaultHistoryText.badge(change.entry)
		let moment = text.moment(VaultHistoryText.date(change.entry.time))
		return HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(Self.kind(change.keyChange))
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
				HStack(spacing: 5) {
					Text(moment)
						.font(VaultTypography.tabular(11))
					Text("·")
					Text(badge.text)
						.font(.system(size: 11))
						.foregroundStyle(badge.warns ? VaultPalette.orangeTintText : VaultPalette.textTertiary)
				}
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
			}
			.accessibilityElement(children: .combine)
			Spacer(minLength: 4)
			VaultRowIconButton(
				systemImage: "arrow.uturn.backward",
				help: "Roll \(key) in \(VaultProject.displayName(for: environment)) back to its value before this change",
				label: "Roll Back… \(key) in \(environment) to its value before \(moment)",
				compact: true
			) {
				Task { await rollBack(change, environment: environment) }
			}
		}
		.padding(.leading, 14)
		.accessibilityElement(children: .contain)
	}

	private static func kind(_ change: HistoryEngine.KeyChange?) -> String {
		switch change?.change {
		case "added": "Added"
		case "removed": "Removed"
		case "renamed": change?.renamedFrom.map { "Renamed from \($0)" } ?? "Renamed"
		default: "Changed"
		}
	}

	private func read() async {
		let environments = store.orderedEnvironmentNames(for: project)
		switch await history.changes(to: key, in: project.id, environments: environments, limit: Self.perEnvironment) {
		case .success(let changes):
			self.changes = .read(Self.groups(changes, key: key, environments: environments, limit: Self.perEnvironment))
		case .failure(.history(code: "history.off", _)):
			changes = .off
		case .failure:
			changes = .unavailable
		}
	}

	private func rollBack(_ change: Change, environment: String) async {
		failure = await history.reviewRollback(
			.key(key, environment: environment, entry: change.entry.id), in: project.id, entry: change.entry)?.description
	}
}
