import SwiftUI

struct AddSecretSheet: View {
	@Bindable var store: VaultStore
	let projectId: String
	@Environment(\.dismiss) private var dismiss
	@State private var selectedEnvironment: String
	@State private var key = ""
	@State private var value = ""
	@State private var error: String?
	@State private var isSubmitting = false
	@FocusState private var focusedField: Field?

	private enum Field {
		case key, value
	}

	init(store: VaultStore, projectId: String, environment: String) {
		self.store = store
		self.projectId = projectId
		_selectedEnvironment = State(initialValue: environment)
	}

	private var project: VaultProject? {
		store.projects.first { $0.id == projectId }
	}

	private var environments: [String] {
		guard let project else { return [] }
		return store.orderedEnvironmentNames(for: project)
	}

	private var validationError: String? {
		guard !key.isEmpty else { return nil }
		guard EnvValidation.isValidVariableName(key) else {
			return "Use letters, numbers, and underscores; the first character cannot be a number"
		}
		guard let secrets = project?.environments[selectedEnvironment] else { return nil }
		if secrets[key] != nil {
			return "A secret with this key already exists"
		}
		if let existingKey = EnvValidation.caseInsensitiveCollision(for: key, in: secrets.keys) {
			return "A key named \(existingKey) already exists. Rename one key for Windows compatibility"
		}
		return nil
	}

	private var canAdd: Bool {
		!key.isEmpty
			&& project?.environments[selectedEnvironment] != nil
			&& validationError == nil
			&& !isSubmitting
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 5) {
				Text("New key")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Stored encrypted in \(VaultProject.displayName(for: selectedEnvironment)).")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.padding(20)

			VaultHairline()

			VStack(alignment: .leading, spacing: 14) {
				modalField(label: "KEY", error: isSubmitting ? nil : validationError) {
					TextField("DATABASE_URL", text: $key)
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(12.5))
						.foregroundStyle(VaultPalette.textPrimary)
						.focused($focusedField, equals: .key)
						.disabled(isSubmitting)
						.onSubmit { focusedField = .value }
				}

				modalField(label: "VALUE") {
					SecureField("Secret value", text: $value)
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(12.5))
						.foregroundStyle(VaultPalette.textPrimary)
						.focused($focusedField, equals: .value)
						.disabled(isSubmitting)
						.onSubmit { if canAdd { Task { await addSecret() } } }
				}

				HStack(spacing: 8) {
					Text("ENVIRONMENT").vaultSectionLabel()
					Spacer()
					if environments.count > 1 {
						Menu {
							Picker("Environment", selection: $selectedEnvironment) {
								ForEach(environments, id: \.self) { environment in
									Text(VaultProject.displayName(for: environment))
										.tag(environment)
								}
							}
						} label: {
							HStack(spacing: 5) {
								VaultTagBadge(
									text: VaultProject.displayName(for: selectedEnvironment),
									foreground: VaultPalette.accentForeground,
									background: VaultPalette.accentTint
								)
								Image(systemName: "chevron.up.chevron.down")
									.font(.system(size: 8, weight: .semibold))
									.foregroundStyle(VaultPalette.textTertiary)
							}
						}
						.menuStyle(.borderlessButton)
						.accessibilityLabel("Environment")
						.accessibilityValue(VaultProject.displayName(for: selectedEnvironment))
					} else {
						VaultTagBadge(
							text: VaultProject.displayName(for: selectedEnvironment),
							foreground: VaultPalette.accentForeground,
							background: VaultPalette.accentTint
						)
					}
				}

				if let error {
					Text(error)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.redText)
				}
			}
			.padding(20)

			VaultHairline()

			HStack(spacing: 8) {
				Spacer()
				VaultBarButton(title: "Cancel", disabled: isSubmitting) { dismiss() }
					.keyboardShortcut(.escape, modifiers: [])
				VaultBarButton(
					title: isSubmitting ? "Adding…" : "Add key",
					filled: true,
					disabled: !canAdd
				) { Task { await addSecret() } }
				.keyboardShortcut(.defaultAction)
				.accessibilityLabel(isSubmitting ? "Adding secret" : "Add secret")
			}
			.padding(16)
		}
		.frame(width: 420)
		.background(VaultPalette.content)
		.onAppear {
			if project?.environments[selectedEnvironment] == nil,
				let first = environments.first
			{
				selectedEnvironment = first
			}
			focusedField = .key
		}
		.onChange(of: key) { _, _ in error = nil }
		.onChange(of: value) { _, _ in error = nil }
		.onChange(of: selectedEnvironment) { _, _ in error = nil }
	}

	private func modalField<Content: View>(
		label: String,
		error: String? = nil,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			Text(label).vaultSectionLabel()
			content()
				.padding(.horizontal, 11)
				.frame(height: 34)
				.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
				.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
			if let error {
				Text(error)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
			}
		}
	}

	private func addSecret() async {
		guard canAdd else { return }
		isSubmitting = true
		error = nil

		let result = await store.addSecret(
			to: projectId,
			environment: selectedEnvironment,
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
