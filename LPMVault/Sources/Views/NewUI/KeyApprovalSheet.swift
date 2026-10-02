import SwiftUI

/// Security sheet shown when an org push detects new or changed member keys.
/// The push is blocked until the user explicitly approves or rejects each key.
struct KeyApprovalSheet: View {
	@Bindable var store: VaultStore

	private var pending: PendingOrgPush? { store.pendingOrgPush }
	private var approvals: [PendingKeyApproval] { pending?.pendingApprovals ?? [] }

	private var approvalSections: (
		newMembers: [PendingKeyApproval],
		changedKeys: [PendingKeyApproval]
	) {
		approvals.reduce(into: ([], [])) { sections, approval in
			if approval.isNewMember {
				sections.0.append(approval)
			} else {
				sections.1.append(approval)
			}
		}
	}

	var body: some View {
		let sections = approvalSections
		VStack(alignment: .leading, spacing: 16) {
			// Header
			HStack(spacing: 10) {
				Image(systemName: "exclamationmark.shield.fill")
					.font(.title2)
					.foregroundStyle(.orange)

				Text("Member Key Approval Required")
					.font(.headline)
			}

			Text("The following member keys must be approved before the env project can be shared. Rejecting will cancel the push.")
				.font(.subheadline)
				.foregroundStyle(.secondary)

			if let orgSlug = pending?.orgSlug {
				LabeledContent("Organization", value: orgSlug)
					.font(.subheadline)
			}

			Divider()

			ScrollView {
				LazyVStack(alignment: .leading, spacing: 12) {
					// Changed keys (higher severity)
					if !sections.changedKeys.isEmpty {
						Label("Changed Keys", systemImage: "exclamationmark.triangle.fill")
							.font(.subheadline.bold())
							.foregroundStyle(.red)

						Text("These members' public keys have changed. This could indicate key rotation or a security compromise.")
							.font(.caption)
							.foregroundStyle(.secondary)

						ForEach(sections.changedKeys) { approval in
							keyRow(approval)
						}
					}

					// New members
					if !sections.newMembers.isEmpty {
						if !sections.changedKeys.isEmpty { Divider() }

						Label("New Members", systemImage: "person.badge.plus")
							.font(.subheadline.bold())
							.foregroundStyle(.blue)

						Text("These members have not been seen before. Verify their identity before approving.")
							.font(.caption)
							.foregroundStyle(.secondary)

						ForEach(sections.newMembers) { approval in
							keyRow(approval)
						}
					}
				}
			}
			.frame(maxHeight: 260)

			Divider()

			// Buttons
			HStack {
				Text("\(approvals.count) key\(approvals.count == 1 ? "" : "s") pending")
					.font(.caption)
					.foregroundStyle(.secondary)

				Spacer()

				Button("Reject All", role: .destructive) {
					store.rejectPendingOrgPush()
				}
				.keyboardShortcut(.escape, modifiers: [])

				Button("Approve All & Push") {
					Task {
						await store.approveAndContinueOrgPush(approved: approvals)
					}
				}
				.keyboardShortcut(.return, modifiers: [])
				.buttonStyle(.borderedProminent)
				.tint(.green)
				.disabled(pending == nil || store.isSyncing)
			}
		}
		.padding(20)
		.frame(width: 480)
	}

	private func keyRow(_ approval: PendingKeyApproval) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Image(systemName: approval.isNewMember ? "person.badge.plus" : "arrow.triangle.2.circlepath")
					.foregroundStyle(approval.isNewMember ? .blue : .orange)

				Text(approval.memberId)
					.font(.subheadline.monospaced())

				Spacer()

				Text(approval.isNewMember ? "NEW" : "CHANGED")
					.font(.caption2.bold())
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(
						(approval.isNewMember ? Color.blue : Color.orange).opacity(0.15),
						in: RoundedRectangle(cornerRadius: 4)
					)
			}

			// Fingerprint
			Text("Fingerprint: \(formatFingerprint(approval.fingerprint))")
				.font(.caption.monospaced())
				.foregroundStyle(.secondary)

			if let old = approval.oldFingerprint {
				Text("Previous:    \(formatFingerprint(old))")
					.font(.caption.monospaced())
					.foregroundStyle(.red.opacity(0.7))
			}
		}
		.padding(8)
		.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
	}

	/// Show first 16 and last 8 hex chars for readability.
	private func formatFingerprint(_ hex: String) -> String {
		guard hex.count > 24 else { return hex }
		let prefix = hex.prefix(16)
		let suffix = hex.suffix(8)
		return "\(prefix)...\(suffix)"
	}
}
