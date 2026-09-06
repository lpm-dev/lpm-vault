import SwiftUI

struct VaultInspectorView: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let snapshot: VaultWorkspaceSnapshot
	let environments: [String]
	let mode: VaultWorkspaceMode
	let selectedKey: String?
	@Binding var revealedKeys: Set<String>
	let onClose: () -> Void
	let onCopySecret: (String, String) -> Void
	let onDeleteSecret: (String, String) -> Void

	private var environment: String { store.selectedEnvironment }

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				if let key = selectedKey {
					identity(key)
					VaultHairline()
					valueSection(key)
					VaultHairline()
					VaultSecretEditor(
						store: store,
						projectID: project.id,
						environment: environment,
						key: key,
						value: project.value(for: key, in: environment),
						isRevealed: revealedKeys.contains(key)
					)
					.id("\(project.id)-\(environment)-\(key)")
					VaultHairline()
					acrossEnvironments(key)
					if case .environment = mode {
						VaultHairline()
						comparison
					}
				} else {
					emptySelection
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.background(VaultPalette.inspector)
	}

	private func identity(_ key: String) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Text("SELECTED KEY").vaultSectionLabel()
				Spacer(minLength: 4)
				Button(action: onClose) {
					Image(systemName: "xmark")
						.font(.system(size: 9, weight: .bold))
						.foregroundStyle(VaultPalette.textTertiary)
						.frame(width: 20, height: 20)
				}
				.buttonStyle(.plain)
				.help("Hide inspector")
				.accessibilityLabel("Hide inspector")
			}

			Text(key)
				.font(VaultTypography.mono(15, .bold))
				.foregroundStyle(VaultPalette.textPrimary)
				.fixedSize(horizontal: false, vertical: true)

			HStack(spacing: 6) {
				VaultTagBadge(text: "ENCRYPTED", foreground: VaultPalette.accent, background: VaultPalette.accentTint)
				Text("used in \(snapshot.environmentCount(for: key)) envs")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.padding(.horizontal, 18)
		.padding(.top, 16)
		.padding(.bottom, 12)
	}

	private func valueSection(_ key: String) -> some View {
		let value = project.value(for: key, in: environment)
		let revealed = revealedKeys.contains(key)
		return VStack(alignment: .leading, spacing: 12) {
			Text("VALUE IN \(VaultProject.displayName(for: environment).uppercased())").vaultSectionLabel()

			VaultValueText(
				text: value == nil ? "Not set" : (revealed ? (value ?? "") : "••••••••••••••••"),
				masked: value != nil && !revealed,
				size: 11.5
			)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 11)
			.padding(.vertical, 10)
			.background(RoundedRectangle(cornerRadius: 8).fill(.white))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
			.accessibilityLabel(value == nil ? "Value not set" : (revealed ? "Value revealed visually" : "Value hidden"))

			if value != nil {
				HStack(spacing: 6) {
					VaultInspectorButton(title: "Copy", systemImage: "doc.on.doc", filled: true) {
						onCopySecret(key, environment)
					}
					VaultInspectorButton(title: revealed ? "Hide" : "Reveal") {
						toggleReveal(key)
					}
					VaultInspectorButton(systemImage: "trash", destructive: true) {
						onDeleteSecret(key, environment)
					}
				}
			}
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 14)
	}

	private func acrossEnvironments(_ key: String) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("ACROSS ENVIRONMENTS").vaultSectionLabel()
			ForEach(Array(environments.enumerated()), id: \.element) { index, candidate in
				HStack(spacing: 8) {
					VaultEnvSwatch(color: VaultPalette.environment(index))
					Text(VaultProject.displayName(for: candidate))
						.font(VaultTypography.mono(11.5))
						.foregroundStyle(VaultPalette.textSecondary)
					Spacer(minLength: 4)
					Text(candidate == environment ? "editing" : (project.value(for: key, in: candidate) == nil ? "not set" : "set"))
						.font(.system(size: 11, weight: candidate == environment ? .semibold : .regular))
						.foregroundStyle(candidate == environment ? VaultPalette.accent : VaultPalette.textTertiary)
				}
			}
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 14)
	}

	private var comparison: some View {
		let drifting = snapshot.driftingKeyCount
		let missing = snapshot.missingKeyCount(for: environment)
		return VStack(alignment: .leading, spacing: 9) {
			Text("ENVIRONMENT STATUS").vaultSectionLabel()
			HStack(spacing: 8) {
				VaultTagBadge(text: "\(drifting) DIFFER", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint)
				Text("values differ across environments").font(.system(size: 11.5)).foregroundStyle(VaultPalette.textTertiary)
			}
			HStack(spacing: 8) {
				VaultTagBadge(text: "\(missing) MISSING", foreground: VaultPalette.redText, background: VaultPalette.redTint)
				Text("not present in this environment").font(.system(size: 11.5)).foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 14)
	}

	private var emptySelection: some View {
		VStack(alignment: .leading, spacing: 9) {
			HStack {
				Text("INSPECTOR").vaultSectionLabel()
				Spacer()
				Button(action: onClose) { Image(systemName: "xmark") }
					.buttonStyle(.plain)
					.accessibilityLabel("Hide inspector")
			}
			Text("Select a key to inspect or edit its value.")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
		}
		.padding(18)
	}

	private func toggleReveal(_ key: String) {
		if revealedKeys.contains(key) { revealedKeys.remove(key) } else { revealedKeys.insert(key) }
	}
}

private struct VaultSecretEditor: View {
	@Bindable var store: VaultStore
	let projectID: String
	let environment: String
	let key: String
	let value: String?
	let isRevealed: Bool

	@State private var editDraft: VaultSecretEditDraft
	@FocusState private var focused: Bool

	init(
		store: VaultStore,
		projectID: String,
		environment: String,
		key: String,
		value: String?,
		isRevealed: Bool
	) {
		self.store = store
		self.projectID = projectID
		self.environment = environment
		self.key = key
		self.value = value
		self.isRevealed = isRevealed
		_editDraft = State(initialValue: VaultSecretEditDraft(value: value ?? ""))
	}

	private var draftBinding: Binding<String> {
		Binding(get: { editDraft.draft }, set: { editDraft.draft = $0 })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("EDIT VALUE").vaultSectionLabel()
			if value == nil {
				Text("This key is not set in \(VaultProject.displayName(for: environment)). Use New key to add it.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				Group {
					if isRevealed {
						TextField("Value", text: draftBinding, axis: .vertical)
							.lineLimit(1...4)
					} else {
						SecureField("Value", text: draftBinding)
					}
				}
				.textFieldStyle(.plain)
				.font(VaultTypography.mono(11.5))
				.foregroundStyle(VaultPalette.textPrimary)
				.focused($focused)
				.padding(.horizontal, 11)
				.padding(.vertical, 9)
				.background(RoundedRectangle(cornerRadius: 8).fill(.white))
				.overlay { RoundedRectangle(cornerRadius: 8).stroke(focused ? VaultPalette.accent : VaultPalette.border, lineWidth: 1) }
				.onSubmit { save() }

				HStack(spacing: 6) {
					VaultInspectorButton(
						title: "Save", filled: true,
						disabled: !editDraft.canSave,
						action: save
					)
					VaultInspectorButton(title: "Revert", disabled: !editDraft.canRevert) {
						editDraft.revert()
					}
				}
				if editDraft.hasExternalConflict {
					Text("This value changed outside the editor. Revert, then apply your edit again.")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.redText)
				} else if editDraft.isDirty {
					Text("Unsaved change in \(VaultProject.displayName(for: environment))")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.orangeTintText)
				}
			}
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 14)
		.onChange(of: value) { _, updated in
			editDraft.receiveExternalValue(updated ?? "")
		}
	}

	private func save() {
		let expectedValue = editDraft.baseline
		guard let submittedValue = editDraft.beginSave() else { return }
		Task { @MainActor in
			let succeeded = await store.updateSecretAndWait(
				in: projectID,
				environment: environment,
				key: key,
				expectedValue: expectedValue,
				newValue: submittedValue
			)
			editDraft.finishSave(succeeded: succeeded)
		}
	}
}

private struct VaultInspectorButton: View {
	var title: String?
	var systemImage: String?
	var filled = false
	var destructive = false
	var disabled = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
				if let title { Text(title).font(.system(size: 12, weight: filled ? .semibold : .regular)) }
			}
			.foregroundStyle(foreground)
			.frame(maxWidth: title == nil ? 28 : .infinity)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 7).fill(filled ? VaultPalette.accent : .white))
			.overlay { RoundedRectangle(cornerRadius: 7).stroke(filled ? .clear : (destructive ? VaultPalette.red.opacity(0.5) : VaultPalette.border), lineWidth: 1) }
		}
		.buttonStyle(.plain)
		.frame(width: title == nil ? 28 : nil)
		.disabled(disabled)
		.opacity(disabled ? 0.45 : 1)
	}

	private var foreground: Color {
		if destructive { return VaultPalette.red }
		return filled ? .white : VaultPalette.textSecondary
	}
}
