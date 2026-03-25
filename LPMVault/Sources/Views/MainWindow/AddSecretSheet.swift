import SwiftUI

struct AddSecretSheet: View {
	@Bindable var store: VaultStore
	let projectId: String
	@Environment(\.dismiss) private var dismiss
	@State private var key = ""
	@State private var value = ""
	@State private var error: String?
	@FocusState private var focusedField: Field?

	private enum Field {
		case key, value
	}

	private var project: VaultProject? {
		store.projects.first { $0.id == projectId }
	}

	private var isDuplicate: Bool {
		project?.secrets[key] != nil
	}

	private var canAdd: Bool {
		!key.isEmpty && !isDuplicate
	}

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Add Secret")
					.font(.headline)
				Spacer()
				Button {
					dismiss()
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.keyboardShortcut(.escape, modifiers: [])
			}
			.padding()

			Divider()

			// Form
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 6) {
					Text("Key")
						.font(.subheadline)
						.fontWeight(.medium)
					TextField("e.g. DATABASE_URL", text: $key)
						.textFieldStyle(.roundedBorder)
						.font(.system(.body, design: .monospaced))
						.focused($focusedField, equals: .key)

					if isDuplicate {
						Text("A secret with this key already exists")
							.font(.caption)
							.foregroundStyle(.red)
					}
				}

				VStack(alignment: .leading, spacing: 6) {
					Text("Value")
						.font(.subheadline)
						.fontWeight(.medium)
					TextField("Secret value", text: $value)
						.textFieldStyle(.roundedBorder)
						.font(.system(.body, design: .monospaced))
						.focused($focusedField, equals: .value)
				}

				if let error {
					Text(error)
						.font(.caption)
						.foregroundStyle(.red)
				}
			}
			.padding()

			Divider()

			// Actions
			HStack {
				Spacer()
				Button("Cancel") {
					dismiss()
				}
				.keyboardShortcut(.escape, modifiers: [])

				Button("Add") {
					addSecret()
				}
				.buttonStyle(.borderedProminent)
				.disabled(!canAdd)
				.keyboardShortcut(.return, modifiers: .command)
			}
			.padding()
		}
		.frame(width: 420)
		.onAppear {
			focusedField = .key
		}
	}

	private func addSecret() {
		guard canAdd else { return }

		store.addSecret(to: projectId, key: key, value: value)

		if store.error != nil {
			error = store.error
		} else {
			dismiss()
		}
	}
}
