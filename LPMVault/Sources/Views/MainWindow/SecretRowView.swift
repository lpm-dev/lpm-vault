import SwiftUI

struct SecretRowView: View {
	let secret: VaultSecret
	let isUnlocked: Bool
	let onReveal: () -> Void
	let onUpdate: (String) -> Void
	let onDelete: () -> Void

	@State private var isEditing = false
	@State private var editValue = ""
	@State private var showDeleteConfirmation = false
	@State private var copyFeedback = false
	@State private var isRevealed = false
	@FocusState private var editFieldFocused: Bool

	var body: some View {
		HStack(spacing: 12) {
			// Key
			Text(secret.key)
				.font(.system(.body, design: .monospaced))
				.fontWeight(.medium)
				.frame(minWidth: 120, alignment: .leading)

			// Value
			Group {
				if isEditing {
					TextField("Value", text: $editValue)
						.textFieldStyle(.roundedBorder)
						.font(.system(.body, design: .monospaced))
						.focused($editFieldFocused)
						.onSubmit {
							commitEdit()
						}
						.onExitCommand {
							isEditing = false
						}
						.accessibilityLabel("Value for \(secret.key)")
				} else if isUnlocked && isRevealed {
					Text(secret.value)
						.font(.system(.body, design: .monospaced))
						.foregroundStyle(.primary)
						.lineLimit(1)
						.accessibilityHidden(true)
						.onTapGesture(count: 2) {
							startEdit()
						}
				} else {
					Text(String(repeating: "\u{2022}", count: 12))
						.foregroundStyle(.secondary)
						.accessibilityLabel("Hidden value for \(secret.key)")
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			// Actions
			HStack(spacing: 6) {
				if !isEditing {
					if isUnlocked {
						Button {
							isRevealed.toggle()
						} label: {
							Image(systemName: isRevealed ? "eye.slash" : "eye")
								.frame(width: 14, height: 14)
						}
						.buttonStyle(.bordered)
						.controlSize(.small)
						.help(isRevealed ? "Hide value" : "Reveal value")
						.accessibilityLabel("\(isRevealed ? "Hide" : "Reveal") \(secret.key)")

						// Copy
						Button {
							ClipboardManager.shared.copy("\(secret.key)=\(secret.value)")
							withAnimation {
								copyFeedback = true
							}
							DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
								withAnimation {
									copyFeedback = false
								}
							}
						} label: {
							Image(
								systemName: copyFeedback
									? "checkmark.circle.fill" : "doc.on.doc"
							)
							.frame(width: 14, height: 14)
						}
						.buttonStyle(.bordered)
						.controlSize(.small)
						.tint(copyFeedback ? .green : nil)
						.help(copyFeedback ? "Copied! Clears in 10s" : "Copy value")
						.accessibilityLabel(copyFeedback ? "Copied \(secret.key)" : "Copy \(secret.key)")

						// Edit
						Button {
							startEdit()
						} label: {
							Image(systemName: "pencil")
								.frame(width: 14, height: 14)
						}
						.buttonStyle(.bordered)
						.controlSize(.small)
						.help("Edit value")
						.accessibilityLabel("Edit \(secret.key)")
					} else {
						// Reveal
						Button {
							onReveal()
						} label: {
							Image(systemName: "eye")
								.frame(width: 14, height: 14)
						}
						.buttonStyle(.bordered)
						.controlSize(.small)
						.help("Reveal value (requires authentication)")
						.accessibilityLabel("Reveal \(secret.key)")
					}

					// Delete
					Button(role: .destructive) {
						showDeleteConfirmation = true
					} label: {
						Image(systemName: "trash")
							.frame(width: 14, height: 14)
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
					.help("Delete secret")
					.accessibilityLabel("Delete \(secret.key)")
				} else {
					Button("Save") {
						commitEdit()
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.small)

					Button("Cancel") {
						isEditing = false
					}
					.controlSize(.small)
				}
			}
		}
		.padding(.vertical, 4)
		.confirmationDialog(
			"Delete \"\(secret.key)\"?",
			isPresented: $showDeleteConfirmation,
			titleVisibility: .visible
		) {
			Button("Delete", role: .destructive) {
				onDelete()
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This secret will be removed from the env project. This action cannot be undone.")
		}
	}

	private func startEdit() {
		editValue = secret.value
		isRevealed = true
		isEditing = true
		editFieldFocused = true
	}

	private func commitEdit() {
		if !editValue.isEmpty && editValue != secret.value {
			onUpdate(editValue)
		}
		isEditing = false
	}
}
