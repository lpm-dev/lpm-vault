import Foundation
import Observation

/// What stands between the person and a value while the vault is unlocked:
/// Touch ID or the Mac's password again once an approval is older than the
/// Security setting allows, and masking revealed values again after a while.
/// Unlocking counts as an approval. Every reveal and every copy of a value
/// comes through here.
@Observable
@MainActor
final class VaultValueAccess {
	/// Moves each time revealed values are to be masked again; every view
	/// that reveals values clears what it shows when it changes.
	private(set) var hideGeneration = 0
	/// Called as revealed values are masked again, for what keeps revealed
	/// values outside a view, such as local history's.
	@ObservationIgnored var onHide: (@MainActor () -> Void)?

	@ObservationIgnored private let approval: @MainActor () -> VaultValueApproval
	@ObservationIgnored private let rehide: @MainActor () -> VaultRehideInterval
	@ObservationIgnored private let confirm: @MainActor (String) async -> Bool
	@ObservationIgnored private let now: @Sendable () -> TimeInterval
	@ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
	@ObservationIgnored private var approvedAt: TimeInterval?
	@ObservationIgnored private var asking: Task<Bool, Never>?
	@ObservationIgnored private var rehideTask: Task<Void, Never>?
	@ObservationIgnored private var generation = 0

	/// The reason Touch ID shows: "LPM Vault is trying to show or copy a value".
	static let reason = "show or copy a value"

	init(
		approval: @escaping @MainActor () -> VaultValueApproval,
		rehide: @escaping @MainActor () -> VaultRehideInterval,
		confirm: @escaping @MainActor (String) async -> Bool,
		now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
		sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
	) {
		self.approval = approval
		self.rehide = rehide
		self.confirm = confirm
		self.now = now
		self.sleep = sleep
	}

	/// Access that never asks and never masks again, for a view tested on its own.
	static let unguarded = VaultValueAccess(approval: { .never }, rehide: { .never }, confirm: { _ in true })

	/// Whether the next reveal or copy asks first.
	var needsApproval: Bool {
		guard let interval = approval().seconds else { return false }
		guard let approvedAt else { return true }
		let elapsed = now() - approvedAt
		return elapsed < 0 || elapsed >= interval
	}

	/// Runs `action`, which copies a value, at once while the last approval
	/// holds, or after the person approves again; never when they don't.
	func copy(_ action: @escaping @MainActor () -> Void) {
		perform(action)
	}

	/// Runs `action`, which reveals values, as `copy` does, and starts the
	/// time after which they're masked again.
	func reveal(_ action: @escaping @MainActor () -> Void) {
		perform { [weak self] in
			action()
			self?.startRehideTimer()
		}
	}

	/// Unlocking approves, as asking again would.
	func noteUnlocked() {
		generation &+= 1
		approvedAt = now()
		asking?.cancel()
		asking = nil
	}

	/// Forgets the approval and masks everything, as the vault locks.
	func reset() {
		generation &+= 1
		approvedAt = nil
		asking?.cancel()
		asking = nil
		rehideTask?.cancel()
		rehideTask = nil
		hide()
	}

	/// The Security setting for masking again changed: a shorter time starts
	/// from now, and Never stops the time running.
	func rehideSettingChanged() {
		guard rehideTask != nil else { return }
		startRehideTimer()
	}

	/// Masks every revealed value now.
	func hideRevealed() {
		rehideTask?.cancel()
		rehideTask = nil
		hide()
	}

	private func hide() {
		hideGeneration &+= 1
		onHide?()
	}

	private func perform(_ action: @escaping @MainActor () -> Void) {
		guard needsApproval else {
			action()
			return
		}
		let session = generation
		let request: Task<Bool, Never>
		if let asking {
			request = asking
		} else {
			request = Task { @MainActor [confirm] in await confirm(Self.reason) }
			asking = request
		}
		Task { @MainActor [weak self] in
			let approved = await request.value
			guard let self, session == generation else { return }
			if asking == request { asking = nil }
			guard approved else { return }
			approvedAt = now()
			action()
		}
	}

	private func startRehideTimer() {
		rehideTask?.cancel()
		rehideTask = nil
		guard let interval = rehide().seconds else { return }
		let session = generation
		rehideTask = Task { @MainActor [weak self, sleep] in
			do { try await sleep(.seconds(interval)) } catch { return }
			guard let self, !Task.isCancelled, session == generation else { return }
			rehideTask = nil
			hide()
		}
	}
}
