import SwiftUI

/// Reviews removing one value from the places chosen in a project's history:
/// the chosen key's places switched on, other keys with the same value off,
/// and a place that still holds it now disabled. Removing asks for Touch ID.
struct VaultHistoryRemovalSheet: View {
	let store: VaultStore
	let project: VaultProject
	@Environment(\.vaultContentObscured) private var obscured
	@Environment(\.vaultClock) private var clock
	@State private var shows = false
	@State private var revealGeneration = 0
	@State private var working = false
	@State private var failure: Failure?

	private enum Failure: Equatable {
		case changed
		case message(String)
	}

	private struct RevealTarget: Equatable {
		let id: UUID
		let projectID: String
		let entry: String
		let environment: String
		let key: String
		let side: String

		init(_ review: VaultLocalHistory.RemovalReview) {
			id = review.id
			projectID = review.projectID
			entry = review.entry
			environment = review.environment
			key = review.key
			side = review.side
		}
	}

	private var history: VaultLocalHistory { store.history }
	private var text: VaultHistoryText { VaultHistoryText(now: clock.now()) }

	var body: some View {
		Group {
			if let review = history.removalReview {
				content(review)
			}
		}
		.onChange(of: history.removalReview.map(RevealTarget.init)) { _, _ in hideValue() }
		.onChange(of: store.valueAccess.hideGeneration) { _, _ in hideValue() }
		.onDisappear { hideValue() }
	}

	private func content(_ review: VaultLocalHistory.RemovalReview) -> some View {
		let places = review.review.places
		let thisKey = places.indices.filter { places[$0].group == "thisKey" }
		let otherKeys = places.indices.filter { places[$0].group != "thisKey" }
		let count = review.selection.count
		return VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					Text("Remove this value from history?")
						.font(.system(size: 15, weight: .bold))
						.foregroundStyle(VaultPalette.textPrimary)
						.accessibilityAddTraits(.isHeader)
					Text("Removes one value from the places you choose in this project’s history.")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textSecondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 8)
				VaultSheetCloseButton(label: "Cancel") { history.removalReview = nil }
					.disabled(working)
			}
			.padding(.horizontal, 24)
			.padding(.top, 20)
			.padding(.bottom, 14)
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					subject(review)
					if !thisKey.isEmpty {
						group("THIS KEY", note: nil, places: thisKey, review: review)
					}
					if !otherKeys.isEmpty {
						group(
							"OTHER KEYS WITH THE SAME VALUE",
							note: "Unrelated keys can share a value such as true or 3000. Switch one on only if it’s a copy of this value.",
							places: otherKeys, review: review)
					}
					Text("LPM Vault and the LPM CLI can’t read it any more. Copies in Time Machine, APFS snapshots or other backups of this Mac can remain. Current values don’t change.")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textSecondary)
						.lineSpacing(2)
						.fixedSize(horizontal: false, vertical: true)
				}
				.padding(.horizontal, 24)
				.padding(.bottom, 18)
			}
			.frame(maxHeight: 460)
			.fixedSize(horizontal: false, vertical: true)
			.disabled(working)
			if let failure { failureNote(failure, review: review) }
			VaultSheetFooter {
				Label("Touch ID follows.", systemImage: "touchid")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Cancel", disabled: working, height: 28) { history.removalReview = nil }
					.keyboardShortcut(.cancelAction)
				VaultBarButton(
					title: count == 0 ? "Nothing to remove" : "Remove from \(count.counted("Place"))",
					filled: true, destructive: true, disabled: working || count == 0 || failure == .changed, height: 28
				) { remove() }
			}
		}
		.frame(width: 600)
		.background(VaultPalette.content)
		.onChange(of: obscured) { _, covered in if covered { hideValue() } }
	}

	private func subject(_ review: VaultLocalHistory.RemovalReview) -> some View {
		let entry = history.entry(review.entry)
		let side = history.side(entry: review.entry, environment: review.environment, key: review.key, side: review.side)
		let value = shows && !obscured ? side.flatMap(history.value(of:)) : nil
		return VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Text(review.key)
					.font(VaultTypography.tabular(13, .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
				VaultHistoryEnvironmentChip(review.environment, in: store.orderedEnvironmentNames(for: project))
			}
			HStack(spacing: 8) {
				VaultHistoryValueField(content: value.map { .shown($0) } ?? .hidden, label: "The value of \(review.key) to remove")
				VaultRowIconButton(
					systemImage: shows ? "eye.slash" : "eye",
					help: shows ? "Hide the value" : "Reveal the value",
					disabled: obscured
				) {
					toggleReveal(review)
				}
			}
			if let entry {
				Text(text.removalSubject(entry, side: review.side))
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
			}
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
		.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
	}

	private func toggleReveal(_ review: VaultLocalHistory.RemovalReview) {
		if shows { return hideValue() }
		let target = RevealTarget(review)
		let generation = revealGeneration
		let hideGeneration = store.valueAccess.hideGeneration
		store.valueAccess.reveal {
			guard canReveal(target, generation: generation, hideGeneration: hideGeneration) else { return }
			shows = true
			Task {
				guard canReveal(target, generation: generation, hideGeneration: hideGeneration) else { return }
				await history.reveal(review.entry)
			}
		}
	}

	private func canReveal(_ target: RevealTarget, generation: Int, hideGeneration: Int) -> Bool {
		generation == revealGeneration && hideGeneration == store.valueAccess.hideGeneration && !obscured && !working && store.isUnlocked
			&& store.selectedProjectId == project.id && history.projectID == project.id && history.removalReview.map(RevealTarget.init) == target
	}

	private func hideValue() {
		revealGeneration &+= 1
		shows = false
	}

	private func group(_ title: String, note: String?, places: [Int], review: VaultLocalHistory.RemovalReview) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title).vaultSectionLabel()
				.accessibilityAddTraits(.isHeader)
			if let note {
				Text(note)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			VStack(spacing: 0) {
				ForEach(Array(places.enumerated()), id: \.element) { position, index in
					placeRow(review, index: index)
						.overlay(alignment: .top) { if position > 0 { VaultHairline() } }
				}
			}
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border, lineWidth: 1) }
		}
	}

	private func placeRow(_ review: VaultLocalHistory.RemovalReview, index: Int) -> some View {
		let place = review.review.places[index]
		let ordered = store.orderedEnvironmentNames(for: project)
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				VStack(alignment: .leading, spacing: 2) {
					Text(place.key)
						.font(VaultTypography.tabular(12.5, .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.middle)
					if !place.renamedFrom.isEmpty {
						Text("was \(place.renamedFrom.formatted(.list(type: .or)))")
							.font(.system(size: 11))
							.foregroundStyle(VaultPalette.textTertiary)
							.lineLimit(1)
					}
				}
				.frame(width: 170, alignment: .leading)
				VaultHistoryEnvironmentChip(place.environment, in: ordered)
				Text(text.occurrences(place.occurrences))
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.lineLimit(1)
					.truncationMode(.tail)
					.frame(maxWidth: .infinity, alignment: .leading)
				Toggle("Remove from \(place.key) in \(place.environment)", isOn: Binding(
					get: { review.selection.contains(index) },
					set: { on in
						if on { history.removalReview?.selection.insert(index) } else { history.removalReview?.selection.remove(index) }
					}
				))
				.toggleStyle(VaultSwitchStyle())
				.controlSize(.mini)
				.disabled(place.current)
			}
			.opacity(place.current ? 0.75 : 1)
			if place.current {
				VaultHistoryNotice(
					text: "It’s still the current value of \(place.key) in \(place.environment). Change it first, then remove the old value from history.",
					warns: false)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.accessibilityElement(children: .contain)
	}

	private func remove() {
		working = true
		failure = nil
		Task {
			if let error = await history.remove() {
				if case .history(code: "history.changed_since_review", _) = error {
					failure = .changed
				} else {
					failure = .message(error.description)
				}
			}
			working = false
		}
	}

	private func failureNote(_ failure: Failure, review: VaultLocalHistory.RemovalReview) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.orange)
				.accessibilityHidden(true)
			switch failure {
			case .changed:
				Text("\(project.name)’s history changed since you reviewed this, so nothing was removed. Review it again.")
					.frame(maxWidth: .infinity, alignment: .leading)
				VaultBarButton(title: "Review Again", disabled: working, height: 24) {
					Task {
						working = true
						if let error = await history.reviewRemoval(
							entry: review.entry, environment: review.environment, key: review.key, side: review.side)
						{
							self.failure = .message(error.description)
						} else {
							self.failure = nil
						}
						working = false
					}
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
