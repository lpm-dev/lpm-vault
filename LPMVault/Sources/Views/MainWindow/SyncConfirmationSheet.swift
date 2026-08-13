import SwiftUI

enum SyncConfirmationAction: String {
	case push
	case pull
	case share

	var title: String {
		switch self {
		case .push: "Push to Cloud"
		case .pull: "Pull from Cloud"
		case .share: "Share with Organization"
		}
	}

	var buttonTitle: String {
		switch self {
		case .push: "Push"
		case .pull: "Pull"
		case .share: "Share"
		}
	}

	var systemImage: String {
		switch self {
		case .push: "arrow.up.circle.fill"
		case .pull: "arrow.down.circle.fill"
		case .share: "person.2.circle.fill"
		}
	}

	var tint: Color { self == .pull ? .blue : .orange }

	var detail: String {
		switch self {
		case .push:
			"This will update the cloud env project with your local secrets."
		case .pull:
			"This will merge cloud secrets into your local env project. Cloud values take priority on conflicts."
		case .share:
			"This will encrypt and share the env project with approved organization members."
		}
	}
}

/// Confirmation sheet shown before push/pull operations.
struct SyncConfirmationSheet: View {
	let action: SyncConfirmationAction
	let projectName: String
	let keyCount: Int
	let onConfirm: () -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			// Header
			HStack(spacing: 10) {
				Image(systemName: action.systemImage)
					.font(.title2)
					.foregroundStyle(action.tint)

				Text(action.title)
					.font(.headline)
			}

			Text(action.detail)
				.font(.subheadline)
				.foregroundStyle(.secondary)

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

				Button(action.buttonTitle) {
					onConfirm()
				}
				.keyboardShortcut(.return, modifiers: [])
				.buttonStyle(.borderedProminent)
				.tint(action.tint)
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

			Text("Your local env project is behind the cloud version. Someone else may have pushed changes.")
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
