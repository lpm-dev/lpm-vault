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
						.onSubmit {
							commitEdit()
						}
						.onExitCommand {
							isEditing = false
						}
				} else if isUnlocked {
					Text(secret.value)
						.font(.system(.body, design: .monospaced))
						.foregroundStyle(.primary)
						.lineLimit(1)
						.onTapGesture(count: 2) {
							startEdit()
						}
				} else {
					Text(String(repeating: "\u{2022}", count: 12))
						.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			// Actions
			HStack(spacing: 4) {
				if !isEditing {
					if isUnlocked {
						// Copy
						Button {
							ClipboardManager.shared.copy(secret.value)
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
							.foregroundStyle(copyFeedback ? .green : .secondary)
						}
						.buttonStyle(.plain)
						.help(copyFeedback ? "Copied! Clears in 30s" : "Copy value")

						// Edit
						Button {
							startEdit()
						} label: {
							Image(systemName: "pencil")
								.foregroundStyle(.secondary)
						}
						.buttonStyle(.plain)
						.help("Edit value")
					} else {
						// Reveal
						Button {
							onReveal()
						} label: {
							Image(systemName: "eye")
								.foregroundStyle(.secondary)
						}
						.buttonStyle(.plain)
						.help("Reveal value (requires authentication)")
					}

					// Delete
					Button {
						showDeleteConfirmation = true
					} label: {
						Image(systemName: "trash")
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.help("Delete secret")
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
			Text("This secret will be removed from the vault. This action cannot be undone.")
		}
	}

	private func startEdit() {
		editValue = secret.value
		isEditing = true
	}

	private func commitEdit() {
		if !editValue.isEmpty && editValue != secret.value {
			onUpdate(editValue)
		}
		isEditing = false
	}
}
