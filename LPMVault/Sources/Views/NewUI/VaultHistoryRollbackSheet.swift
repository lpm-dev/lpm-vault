import SwiftUI

/// Reviews a rollback before it's applied: an environment back to a point,
/// one key back to its value before a change, or an undo. Each key that
/// changes shows its value now and after, masked until revealed, with a
/// switch to keep its value now.
struct VaultHistoryRollbackSheet: View {
	let store: VaultStore
	let project: VaultProject
	@Environment(\.vaultContentObscured) private var obscured
	@Environment(\.vaultClock) private var clock
	@State private var revealed: Set<HistoryRollbackSkip> = []
	@State private var working = false
	@State private var failure: Failure?
	@State private var listHeight: CGFloat = 0
	@State private var choosingEnvironment = false

	private enum Failure: Equatable {
		/// The values changed since the review, so it has to be made again.
		case changed
		case message(String)
	}

	private struct Group: Identifiable {
		let title: String
		let rows: [Int]
		var id: String { title }
	}

	private static let maximumListHeight: CGFloat = 420
	private static let fieldWidth: CGFloat = 128

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: clock.now()) }

	var body: some View {
		if let review = history.rollbackReview {
			content(review)
		}
	}

	private func content(_ review: VaultLocalHistory.RollbackReview) -> some View {
		let entry = review.pointEntry
		return VStack(alignment: .leading, spacing: 0) {
			header(review, entry: entry)
			VaultHairline()
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					ForEach(review.plan.environments.indices, id: \.self) { index in
						environmentSection(review, index: index, entry: entry)
					}
					if review.plan.environments.allSatisfy({ $0.rows.isEmpty }) {
						Text("Every key already has the value it would go back to.")
							.font(.system(size: 12.5))
							.foregroundStyle(VaultPalette.textTertiary)
					}
				}
				.padding(.horizontal, 24)
				.padding(.vertical, 16)
				.background {
					GeometryReader { proxy in Color.clear.preference(key: RollbackListHeight.self, value: proxy.size.height) }
				}
			}
			.frame(height: min(max(listHeight, 1), Self.maximumListHeight))
			.onPreferenceChange(RollbackListHeight.self) { listHeight = $0 }
			.disabled(working)
			if let failure { failureNote(failure, review: review) }
			VaultSheetFooter {
				Text(VaultHistoryText.rollbackFootnote(undoes: review.plan.kind == "undo"))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			} actions: {
				VaultBarButton(title: "Cancel", disabled: working, height: 28) { history.rollbackReview = nil }
					.keyboardShortcut(.cancelAction)
				// Deleting an environment is destructive, which Return never presses.
				let deletes = review.plan.environments.indices.contains(where: review.deletesEnvironment)
				VaultBarButton(
					title: primaryTitle(review), filled: true, destructive: deletes,
					disabled: working || !review.changesAnything || failure == .changed, height: 28
				) { apply() }
					.keyboardShortcut(deletes ? nil : .defaultAction)
			}
		}
		.frame(width: 620)
		.background(VaultPalette.content)
		.onChange(of: obscured) { _, covered in if covered { revealed = [] } }
		.onChange(of: review.id) { _, _ in revealed = [] }
	}

	// MARK: - Header

	private func header(_ review: VaultLocalHistory.RollbackReview, entry: HistoryEngine.Entry?) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					Text(text.rollbackTitle(review.target, at: review.plan.point.time))
						.font(.system(size: 15, weight: .bold))
						.foregroundStyle(VaultPalette.textPrimary)
						.fixedSize(horizontal: false, vertical: true)
						.accessibilityAddTraits(.isHeader)
					Text(text.rollbackDetail(review, entry: entry))
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textSecondary)
						.lineSpacing(2)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 8)
				VaultSheetCloseButton(label: "Cancel") { history.rollbackReview = nil }
					.disabled(working)
			}
			if case .environment(let name, let entryID, let side, _) = review.target, let entry, entry.environments.count > 1 {
				environmentPicker(name, names: entry.environments.map(\.name), entry: entryID, side: side)
			}
			HStack(spacing: 6) {
				countChip(review, change: "added", tint: VaultPalette.greenTint, foreground: VaultPalette.greenTintText)
				countChip(review, change: "changed", tint: VaultPalette.accentTint, foreground: VaultPalette.accentText)
				countChip(review, change: "removed", tint: VaultPalette.redTint, foreground: VaultPalette.redText)
				Spacer(minLength: 8)
				Text("current → after \(review.plan.kind == "undo" ? "undo" : "rollback")\(revealed.isEmpty || obscured ? " · values hidden" : "")")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 14)
	}

	private func environmentPicker(_ current: String, names: [String], entry: String, side: String) -> some View {
		let ordered = store.orderedEnvironmentNames(for: project)
		return HStack(spacing: 8) {
			Text("Environment:")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
			Button { choosingEnvironment.toggle() } label: {
				HStack(spacing: 5) {
					VaultHistoryEnvironmentChip(current, in: ordered)
					Image(systemName: "chevron.down")
						.font(.system(size: 8, weight: .bold))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(VaultPressStyle(cornerRadius: 6))
			.fixedSize()
			.disabled(working)
			.accessibilityLabel("Environment: \(current)")
			.accessibilityHint("Shows a menu")
			.vaultMenu(isPresented: $choosingEnvironment, rows: names.map { VaultMenuList<String>.Row(id: $0, title: $0, isChecked: $0 == current) },
				width: 220, label: "Environment") { name in
				Task { await review(.environment(name, entry: entry, side: side), entry: history.rollbackReview?.pointEntry) }
			}
			Text("This entry touched \(names.formatted(.list(type: .and))). A rollback acts on one.")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	@ViewBuilder
	private func countChip(_ review: VaultLocalHistory.RollbackReview, change: String, tint: Color, foreground: Color) -> some View {
		let count = review.plan.environments.reduce(0) { total, environment in
			total + environment.rows.filter { $0.change == change && $0.changes }.count
		}
		if count > 0 {
			Text("\(count) \(change)")
				.font(.system(size: 11.5, weight: .semibold))
				.foregroundStyle(foreground)
				.padding(.horizontal, 7)
				.padding(.vertical, 3)
				.background(RoundedRectangle(cornerRadius: 5).fill(tint))
		}
	}

	// MARK: - Environments and rows

	private func environmentSection(_ review: VaultLocalHistory.RollbackReview, index: Int, entry: HistoryEngine.Entry?) -> some View {
		let environment = review.plan.environments[index]
		let name = environment.target ?? environment.current ?? ""
		let ordered = store.orderedEnvironmentNames(for: project)
		return VStack(alignment: .leading, spacing: 12) {
			if review.plan.environments.count > 1 {
				HStack(spacing: 6) {
					VaultEnvSwatch(color: VaultHistoryEnvironmentChip(name, in: ordered).color, size: 8)
					Text(name)
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text("· \(environment.rows.count.counted("key"))")
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textSecondary)
				}
				.accessibilityElement(children: .combine)
				.accessibilityAddTraits(.isHeader)
			}
			if let note = text.environmentNote(environment, deletedAt: deletedAt(environment), undoes: review.plan.kind == "undo") {
				Text(note)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			if let reason = environment.unnamedKeys {
				VaultHistoryNotice(text: VaultHistoryText.unnamedKeys(reason, environment: name))
			}
			ForEach(groups(environment)) { group in
				VStack(alignment: .leading, spacing: 6) {
					Text("\(group.title) · \(group.rows.count)").vaultSectionLabel()
					VStack(spacing: 0) {
						ForEach(Array(group.rows.enumerated()), id: \.element) { position, row in
							rowView(review, environment: index, row: row, entry: entry, offersDeletion: environment.offersDeletion)
								.overlay(alignment: .top) { if position > 0 { VaultHairline() } }
						}
					}
					.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
					.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
				}
			}
			if environment.offersDeletion, let current = environment.current {
				deletionSwitch(review, index: index, name: current, ordered: ordered)
			}
		}
	}

	/// The environment's rows by what the rollback does to them, unknown last.
	private func groups(_ environment: HistoryEngine.PlanEnvironment) -> [Group] {
		[("changed", "CHANGED"), ("added", "ADDED"), ("removed", "REMOVED"), ("unknown", "UNAVAILABLE")].compactMap { change, title in
			let rows = environment.rows.indices.filter { environment.rows[$0].change == change }
			return rows.isEmpty ? nil : Group(title: title, rows: rows)
		}
	}

	private func deletedAt(_ environment: HistoryEngine.PlanEnvironment) -> Int64? {
		guard environment.recreates, let name = environment.target else { return nil }
		return history.timeline?.environments.first { $0.name == name && $0.deletedAt != nil }?.deletedAt
	}

	private func deletionSwitch(_ review: VaultLocalHistory.RollbackReview, index: Int, name: String, ordered: [String]) -> some View {
		let empties = review.plan.environments[index].rows.indices.allSatisfy { review.applies(environment: index, row: $0) }
		return HStack(spacing: 8) {
			Text("Also delete the empty environment")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textPrimary)
			VaultHistoryEnvironmentChip(name, in: ordered)
			Spacer(minLength: 8)
			Toggle("Also delete the empty environment \(name)", isOn: Binding(
				get: { empties && !review.keptEnvironments.contains(index) },
				set: { delete in
					if delete { history.rollbackReview?.keptEnvironments.remove(index) } else { history.rollbackReview?.keptEnvironments.insert(index) }
				}
			))
			.toggleStyle(VaultSwitchStyle())
			.controlSize(.mini)
			.disabled(!empties)
			.help(empties ? "Delete \(name) once its keys are gone" : "Keys you keep stay in \(name), so it isn't deleted")
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
		.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
	}

	private func rowView(
		_ review: VaultLocalHistory.RollbackReview, environment: Int, row index: Int, entry: HistoryEngine.Entry?, offersDeletion: Bool
	) -> some View {
		let row = review.plan.environments[environment].rows[index]
		let values = review.values[environment][index]
		let unknown = row.change == "unknown"
		let skip = HistoryRollbackSkip(environment: environment, row: index)
		let shows = revealed.contains(skip) && !obscured
		let after = review.plan.kind == "undo" ? "after the undo" : "after the rollback"
		return VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Text(row.key)
					.font(VaultTypography.tabular(12.5, .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
					.frame(maxWidth: .infinity, alignment: .leading)
					.help(row.key)
				kindBadge(row)
				VaultHistoryValueField(
					content: field(values.current, present: row.current != nil, shows: shows),
					label: "Value of \(row.key) now"
				)
				.frame(width: Self.fieldWidth)
				Image(systemName: "arrow.right")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
				VaultHistoryValueField(
					content: unknown
						? .unknown(VaultHistoryText.unknownTarget(row.reason))
						: field(values.target, present: row.target != nil, shows: shows),
					label: "Value of \(row.key) \(after)"
				)
				.frame(width: Self.fieldWidth)
				VaultRowIconButton(
					systemImage: shows ? "eye.slash" : "eye",
					help: shows ? "Hide the values of \(row.key)" : "Reveal the values of \(row.key)",
					disabled: obscured || (row.current == nil && row.target == nil)
				) {
					if revealed.contains(skip) { revealed.remove(skip) } else { revealed.insert(skip) }
				}
				Toggle("Apply \(row.key)", isOn: Binding(
					get: { review.applies(environment: environment, row: index) },
					set: { history.rollbackReview?.setApplies($0, environment: environment, row: index) }
				))
				.toggleStyle(VaultSwitchStyle())
				.controlSize(.mini)
				.disabled(unknown)
				.help(unknown ? "Its earlier value isn’t known, so it keeps its value now" : "Switch off to keep its value now")
			}
			.opacity(unknown ? 0.75 : 1)
			notices(review, row: row, entry: entry, offersDeletion: offersDeletion)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.accessibilityElement(children: .contain)
	}

	private func field(_ value: String?, present: Bool, shows: Bool) -> VaultHistoryValueField.Content {
		guard present else { return .absent }
		return shows ? .shown(value ?? "") : .hidden
	}

	private func kindBadge(_ row: HistoryEngine.PlanRow) -> some View {
		let (title, foreground, background): (String, Color, Color) = switch row.change {
		case "added": ("Added", VaultPalette.greenTintText, VaultPalette.greenTint)
		case "removed": ("Removed", VaultPalette.redText, VaultPalette.redTint)
		case "unknown": ("Unknown", VaultPalette.textSecondary, VaultPalette.neutralTint)
		default: ("Changed", VaultPalette.accentText, VaultPalette.accentTint)
		}
		return VaultTagBadge(text: title, foreground: foreground, background: background)
	}

	@ViewBuilder
	private func notices(
		_ review: VaultLocalHistory.RollbackReview, row: HistoryEngine.PlanRow, entry: HistoryEngine.Entry?, offersDeletion: Bool
	) -> some View {
		if row.change == "unknown" {
			VaultHistoryNotice(text: VaultHistoryText.unknownReason(row.reason), warns: false)
		}
		if let pulled = row.pulled {
			VaultHistoryNotice(text: text.pulled(pulled, key: row.key, undoes: review.plan.kind == "undo"), boxed: true)
		}
		ForEach(Array(row.gaps.enumerated()), id: \.offset) { _, gap in
			VaultHistoryNotice(text: text.gap(gap))
		}
		if let again = row.changedAgain {
			VaultHistoryNotice(text: text.changedAgain(again))
		}
		if !row.linked.isEmpty {
			let others = row.linked.formatted(.list(type: .and))
			VaultHistoryNotice(
				text: row.change == "added"
					? "Comes back from \(others), its name since. They switch together."
					: "Goes back to its earlier name, \(others). They switch together.",
				warns: false)
		} else if review.plan.kind == "undo", row.change == "removed", !offersDeletion {
			VaultHistoryNotice(text: "Undoing removes this key: it was added by \(VaultHistoryText.change(entry)).", warns: false)
		}
	}

	// MARK: - Applying

	private func primaryTitle(_ review: VaultLocalHistory.RollbackReview) -> String {
		let undoes = review.plan.kind == "undo"
		let verb = undoes ? "Undo" : "Roll Back"
		if review.changing > 0 { return "\(verb) \(review.changing.counted("Key"))" }
		return review.changesAnything ? verb : (undoes ? "Nothing to undo" : "Nothing to roll back")
	}

	private func apply() {
		working = true
		failure = nil
		Task {
			let outcome = await history.applyRollback()
			working = false
			switch outcome {
			case .saved: break
			case .changed: failure = .changed
			case .unavailable: failure = .message("\(project.name) isn’t available right now, so nothing was changed.")
			case .failed(let message): failure = .message(message)
			}
		}
	}

	private func review(_ target: HistoryEngine.RollbackTarget, entry: HistoryEngine.Entry?) async {
		working = true
		failure = nil
		revealed = []
		if let error = await history.reviewRollback(target, in: project.id, entry: entry) { failure = .message(error.description) }
		working = false
	}

	private func failureNote(_ failure: Failure, review: VaultLocalHistory.RollbackReview) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.orange)
				.accessibilityHidden(true)
			switch failure {
			case .changed:
				Text("\(project.name)’s values changed since you reviewed the rollback, so nothing was changed. Review it again.")
					.frame(maxWidth: .infinity, alignment: .leading)
				VaultBarButton(title: "Review Again", disabled: working, height: 24) {
					Task { await self.review(review.target, entry: review.pointEntry) }
				}
				.fixedSize()
			case .message(let message):
				Text(message)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.font(.system(size: 12))
		.foregroundStyle(VaultPalette.textPrimary)
		.fixedSize(horizontal: false, vertical: true)
		.padding(.horizontal, 24)
		.padding(.vertical, 10)
		.background(VaultPalette.orangeTint)
	}
}

private struct RollbackListHeight: PreferenceKey {
	static let defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
