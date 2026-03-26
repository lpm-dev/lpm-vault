import SwiftUI

/// Confirmation sheet shown before push/pull operations.
struct SyncConfirmationSheet: View {
	let action: String  // "push" or "pull"
	let projectName: String
	let keyCount: Int
	let onConfirm: () -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			// Header
			HStack(spacing: 10) {
				Image(systemName: action == "push" ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
					.font(.title2)
					.foregroundStyle(action == "push" ? .orange : .blue)

				Text(action == "push" ? "Push to Cloud" : "Pull from Cloud")
					.font(.headline)
			}

			// Warning
			if action == "push" {
				Text("This will overwrite the cloud vault with your local secrets.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
			} else {
				Text("This will merge cloud secrets into your local vault. Cloud values take priority on conflicts.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}

			// Details
			VStack(alignment: .leading, spacing: 6) {
				LabeledContent("Project", value: projectName)
				LabeledContent("Local secrets", value: "\(keyCount) keys")
			}
			.font(.subheadline)

			Divider()

			// Buttons
			HStack {
				Spacer()

				Button("Cancel", role: .cancel) {
					onCancel()
				}
				.keyboardShortcut(.escape, modifiers: [])

				Button(action == "push" ? "Push" : "Pull") {
					onConfirm()
				}
				.keyboardShortcut(.return, modifiers: [])
				.buttonStyle(.borderedProminent)
				.tint(action == "push" ? .orange : .blue)
			}
		}
		.padding(20)
		.frame(width: 380)
	}
}

/// Conflict resolution sheet shown when push fails due to version conflict.
struct ConflictResolutionSheet: View {
	let projectName: String
	let onPullAndMerge: () -> Void
	let onForcePush: () -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack(spacing: 10) {
				Image(systemName: "exclamationmark.triangle.fill")
					.font(.title2)
					.foregroundStyle(.yellow)

				Text("Version Conflict")
					.font(.headline)
			}

			Text("Your local vault is behind the cloud version. Someone else may have pushed changes.")
				.font(.subheadline)
				.foregroundStyle(.secondary)

			LabeledContent("Project", value: projectName)
				.font(.subheadline)

			Divider()

			HStack {
				Spacer()

				Button("Cancel", role: .cancel) {
					onCancel()
				}
				.keyboardShortcut(.escape, modifiers: [])

				Button("Pull & Merge") {
					onPullAndMerge()
				}
				.buttonStyle(.bordered)

				Button("Force Push") {
					onForcePush()
				}
				.buttonStyle(.borderedProminent)
				.tint(.orange)
			}
		}
		.padding(20)
		.frame(width: 400)
	}
}
