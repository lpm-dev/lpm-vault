import SwiftUI

struct VaultInspectorView: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let snapshot: VaultWorkspaceSnapshot
	let environments: [String]
	let mode: VaultWorkspaceMode
	let selectedKey: String?
	var isCopied = false
	@Binding var revealedKeys: Set<String>
	let onClose: () -> Void
	let onCopySecret: (String, String) -> Void
	let onDeleteSecret: (String, String) -> Void
	var onEditSessionCreated: (VaultSecretEditingSession) -> Void = { _ in }

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
						projectName: project.name,
						environment: environment,
						key: key,
						value: project.value(for: key, in: environment),
						isRevealed: store.canUseLocalSecrets && revealedKeys.contains(key),
						onSessionCreated: onEditSessionCreated
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
				VaultTagBadge(text: "ENCRYPTED", foreground: VaultPalette.accentForeground, background: VaultPalette.accentTint)
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
		let revealed = store.canUseLocalSecrets && revealedKeys.contains(key)
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
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
			.accessibilityLabel(value == nil ? "Value not set" : (revealed ? "Value revealed visually" : "Value hidden"))

			if value != nil {
				HStack(spacing: 6) {
					VaultInspectorButton(title: isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc", filled: true, disabled: !store.canUseLocalSecrets) {
						onCopySecret(key, environment)
					}
					.help(isCopied ? "Copied to the clipboard" : "Copy this value")
					VaultInspectorButton(title: revealed ? "Hide" : "Reveal", disabled: !store.canUseLocalSecrets) {
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
						.foregroundStyle(candidate == environment ? VaultPalette.accentForeground : VaultPalette.textTertiary)
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
		guard store.canUseLocalSecrets else { return }
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

	@State private var editingSession: VaultSecretEditingSession
	private var editDraft: VaultSecretEditDraft {
		get { editingSession.editDraft }
		nonmutating set { editingSession.editDraft = newValue }
	}
	let onSessionCreated: (VaultSecretEditingSession) -> Void
	@FocusState private var focused: Bool

	init(
		store: VaultStore,
		projectID: String,
		projectName: String,
		environment: String,
		key: String,
		value: String?,
		isRevealed: Bool,
		onSessionCreated: @escaping (VaultSecretEditingSession) -> Void
	) {
		self.store = store
		self.projectID = projectID
		self.environment = environment
		self.key = key
		self.value = value
		self.isRevealed = isRevealed
		self.onSessionCreated = onSessionCreated
		_editingSession = State(initialValue: VaultSecretEditingSession(projectID: projectID, projectName: projectName, environment: environment, key: key, account: store.selectedAccount, value: value ?? ""))
	}

	private var draftBinding: Binding<String> {
		Binding(get: { editDraft.draft }, set: { editDraft.draft = $0 })
	}

	private var canGenerate: Bool {
		VaultSensitiveActionContext(projectID: projectID, environment: environment).isCurrent(in: store)
			&& value != nil && !editDraft.isSaveInFlight && !editDraft.hasExternalConflict
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("EDIT VALUE").vaultSectionLabel()
			if value == nil && !editDraft.isDirty {
				Text("This key is not set in \(VaultProject.displayName(for: environment)). Use New key to add it.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				HStack(spacing: 6) {
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
					.onSubmit { save() }
					.padding(.vertical, 9)

					SecretGeneratorButton(disabled: !canGenerate) { generated in
						guard canGenerate else { return }
						editDraft.draft = generated
					}
				}
				.padding(.leading, 11)
				.padding(.trailing, 4)
				.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
				.overlay { RoundedRectangle(cornerRadius: 8).stroke(focused ? VaultPalette.accent : VaultPalette.border, lineWidth: 1) }

				HStack(spacing: 6) {
					VaultInspectorButton(
						title: "Save", filled: true,
						disabled: !editDraft.canSave || value == nil || !store.canUseLocalSecrets,
						action: save
					)
					VaultInspectorButton(title: "Revert", disabled: !editDraft.canRevert) {
						editDraft.revert()
					}
				}
				if value == nil {
					Text("This key was deleted outside the editor. Your unsaved value is kept here. Use New key to add it again.")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.redText)
				} else if editDraft.hasExternalConflict {
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
		.onAppear { onSessionCreated(editingSession) }
		.onChange(of: value) { _, updated in
			editDraft.receiveExternalValue(updated ?? "")
		}
	}

	private func save() {
		guard value != nil, store.canUseLocalSecrets else { return }
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
			.background(RoundedRectangle(cornerRadius: 7).fill(filled ? VaultPalette.accent : VaultPalette.control))
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

struct VaultRemovedDraftView: View {
	@Bindable var session: VaultSecretEditingSession
	let onCopy: () -> Void
	let onDiscard: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("UNSAVED VALUE").vaultSectionLabel()
			Text(session.key).font(VaultTypography.mono(15, .bold))
			Text("\(session.projectName) · \(VaultProject.displayName(for: session.environment))")
				.font(.system(size: 12)).foregroundStyle(VaultPalette.textSecondary)
			Text("The original project or environment disappeared. Your unsaved value is kept here. Copy it before you discard it.")
				.font(.system(size: 12)).foregroundStyle(VaultPalette.redText)
			SecureField("Unsaved value", text: $session.editDraft.draft)
				.textFieldStyle(.roundedBorder)
				.font(VaultTypography.mono(11.5))
			HStack {
				VaultInspectorButton(title: "Copy draft", filled: true, action: onCopy)
				VaultInspectorButton(title: "Discard", action: onDiscard)
			}
			Spacer()
		}.padding(18).background(VaultPalette.inspector)
	}
}
