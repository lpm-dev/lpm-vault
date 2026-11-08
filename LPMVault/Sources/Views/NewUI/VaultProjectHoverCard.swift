import SwiftUI

/// A project at a glance, beside its sidebar row while the pointer rests on
/// it: how the LPM CLI reaches it, whether its values pass lpm.json, when it
/// last changed, and its environments, drift and missing keys. It says only
/// what the app knows already, and reads the last change from local history.
struct VaultProjectHoverCard: View {
	let store: VaultStore
	let project: VaultProject

	@Environment(\.vaultClock) private var clock
	@State private var lastChange: LastChange = .reading

	private enum LastChange: Equatable {
		case reading
		case none
		case at(Date)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// The project's icon heads the column the lines' icons sit in, so its name starts where their text does.
			HStack(spacing: Self.iconGap) {
				VaultProjectIconView(appearance: store.projectIcons.appearance(for: project.id), size: Self.iconColumn)
				Text(project.name)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(2)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(.bottom, 12)

			VStack(alignment: .leading, spacing: 8) {
				line(approval)
				line(schema)
				line(changed)
			}
			VaultHairline().padding(.vertical, 11)
			// The worst first, as the matrix's marks are: invalid, missing, then drifting.
			VStack(alignment: .leading, spacing: 8) {
				line(.init(symbol: "doc", text: project.environmentNames.count.counted("env file")))
				if let invalid = invalidKeyCount, invalid > 0 {
					line(.init(symbol: VaultSmartView.invalid.symbol, text: "\(invalid) invalid", tint: VaultSmartView.invalid.tint))
				}
				if let snapshot = store.workspaceSnapshots[project.id] {
					line(.init(symbol: VaultSmartView.missing.symbol, text: "\(snapshot.missingKeyCount) missing",
						tint: snapshot.missingKeyCount > 0 ? VaultSmartView.missing.tint : nil))
					line(.init(symbol: VaultSmartView.drift.symbol, text: "\(snapshot.driftingKeyCount) drifting"))
				}
			}
		}
		.padding(14)
		.frame(width: 264, alignment: .leading)
		.task(id: project.id) {
			lastChange = await store.history.lastChange(of: project.id).map(LastChange.at) ?? .none
		}
	}

	struct Line {
		let symbol: String
		let text: String
		var tint: Color?
	}

	/// The icon column's width, which the project's icon fills and each line's icon is centered in.
	private static let iconColumn: CGFloat = 22
	private static let iconGap: CGFloat = 10

	private func line(_ line: Line) -> some View {
		HStack(spacing: Self.iconGap) {
			Image(systemName: line.symbol)
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(line.tint ?? VaultPalette.textTertiary)
				.frame(width: Self.iconColumn)
				.accessibilityHidden(true)
			Text(line.text)
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
				.lineLimit(1)
		}
	}

	private var approval: Line {
		switch store.projectCliAccess[project.id] {
		case .requireApproval?: .init(symbol: "lock.fill", text: "CLI approval on", tint: VaultPalette.accentForeground)
		case .automatic?: .init(symbol: "lock.open", text: "CLI approval off")
		case nil: .init(symbol: "questionmark.circle", text: "CLI approval can't be read")
		}
	}

	/// Keys whose stored values fail lpm.json, once they've been checked.
	private var invalidKeyCount: Int? {
		store.valueChecks[project.id].map { Set($0.environments.values.flatMap(\.problems.keys)).count }
	}

	private var schema: Line {
		Self.schemaLine(state: store.keyDescriptions[project.id]?.schema, check: store.valueChecks[project.id], hasFolder: !project.path.isEmpty)
	}

	/// What the project's lpm.json says of its values, from what's been read.
	static func schemaLine(state: ProjectEnvSchemaState?, check: ProjectEnvValueCheck?, hasFolder: Bool) -> Line {
		let symbol = "curlybraces"
		let noFolder = Line(symbol: "folder.badge.questionmark", text: "No project folder on this Mac")
		guard hasFolder else { return noFolder }
		switch state {
		case nil: return .init(symbol: symbol, text: "lpm.json not read yet")
		case .noFolder?: return noFolder
		case .unreadable?: return .init(symbol: symbol, text: "lpm.json can't be read", tint: VaultPalette.warningMark)
		case .loaded(let overview, _)?:
			guard !overview.rules.isEmpty else { return .init(symbol: symbol, text: "No rules in lpm.json") }
			let failing = Set(check?.environments.values.flatMap(\.problems.keys) ?? []).count
			guard let check, !check.environments.isEmpty else { return .init(symbol: symbol, text: "Values not checked yet") }
			return failing == 0
				? .init(symbol: symbol, text: "Values pass lpm.json")
				: .init(symbol: symbol, text: failing == 1 ? "1 key fails lpm.json" : "\(failing) keys fail lpm.json", tint: VaultPalette.problemMark)
		}
	}

	private var changed: Line {
		switch lastChange {
		case .reading: .init(symbol: "clock.arrow.circlepath", text: "Reading history…")
		case .none: .init(symbol: "clock.arrow.circlepath", text: "No changes in history yet")
		case .at(let date): .init(symbol: "clock.arrow.circlepath", text: "Changed \(Self.relative(date, now: clock.now()))")
		}
	}

	/// "2 hours ago", "yesterday", or "just now" within a minute.
	static func relative(_ date: Date, now: Date) -> String {
		if now.timeIntervalSince(date) < 60 { return "just now" }
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .full
		formatter.dateTimeStyle = .named
		return formatter.localizedString(for: date, relativeTo: now)
	}
}
