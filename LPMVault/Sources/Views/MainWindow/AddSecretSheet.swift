import SwiftUI

struct AddSecretSheet: View {
	@Bindable var store: VaultStore
	let projectId: String
	let environment: String
	@Environment(\.dismiss) private var dismiss
	@State private var key = ""
	@State private var value = ""
	@State private var error: String?
	@State private var isSubmitting = false
	@FocusState private var focusedField: Field?

	private enum Field {
		case key, value
	}

	private var project: VaultProject? {
		store.projects.first { $0.id == projectId }
	}

	private var validationError: String? {
		guard !key.isEmpty else { return nil }
		guard EnvValidation.isValidVariableName(key) else {
			return "Use letters, numbers, and underscores; the first character cannot be a number"
		}
		guard let secrets = project?.environments[environment] else { return nil }
		if secrets[key] != nil {
			return "A secret with this key already exists"
		}
		if let existingKey = EnvValidation.caseInsensitiveCollision(for: key, in: secrets.keys) {
			return "A key named \(existingKey) already exists. Rename one key for Windows compatibility"
		}
		return nil
	}

	private var canAdd: Bool {
		!key.isEmpty && validationError == nil && !isSubmitting
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
				.disabled(isSubmitting)
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
						.disabled(isSubmitting)

					if !isSubmitting, let validationError {
						Text(validationError)
								.font(.caption)
								.foregroundStyle(.red)
					}
				}

				VStack(alignment: .leading, spacing: 6) {
					Text("Value")
						.font(.subheadline)
						.fontWeight(.medium)
					SecureField("Secret value", text: $value)
						.textFieldStyle(.roundedBorder)
						.font(.system(.body, design: .monospaced))
						.focused($focusedField, equals: .value)
						.disabled(isSubmitting)
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
				.disabled(isSubmitting)

				Button {
					Task { await addSecret() }
				} label: {
					if isSubmitting {
						ProgressView()
							.controlSize(.small)
							.frame(minWidth: 26)
					} else {
						Text("Add")
					}
				}
				.buttonStyle(.borderedProminent)
				.disabled(!canAdd)
				.keyboardShortcut(.defaultAction)
				.accessibilityLabel(isSubmitting ? "Adding secret" : "Add secret")
			}
			.padding()
		}
		.frame(width: 420)
		.onAppear {
			focusedField = .key
		}
		.onChange(of: key) { _, _ in error = nil }
		.onChange(of: value) { _, _ in error = nil }
	}

	private func addSecret() async {
		guard canAdd else { return }
		isSubmitting = true
		error = nil

		let result = await store.addSecret(
			to: projectId,
			environment: environment,
			key: key,
			value: value
		)
		switch result {
		case .success:
			dismiss()
		case .failure(let addError):
			error = addError.localizedDescription
			isSubmitting = false
		}
	}
}
