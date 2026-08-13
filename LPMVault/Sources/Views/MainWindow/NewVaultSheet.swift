import SwiftUI

/// Sheet for creating a new vault with just a name.
struct NewVaultSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@FocusState private var isFocused: Bool

	private var isOrg: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}

	private var orgSlug: String? {
		if case .org(let slug) = store.selectedAccount { return slug }
		return nil
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("New Env Project")
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

			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 6) {
					Text("Project Name")
						.font(.subheadline)
						.fontWeight(.medium)
					TextField("e.g. my-api-server", text: $name)
						.textFieldStyle(.roundedBorder)
						.focused($isFocused)
						.onSubmit { create() }
				}

				if isOrg {
					HStack(spacing: 6) {
						Image(systemName: "building.2")
							.foregroundStyle(.blue)
						Text("Will be shared with \(orgSlug ?? "org")")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
			.padding()

			Divider()

			HStack {
				Spacer()
				Button("Cancel") { dismiss() }
				Button("Create") { create() }
					.buttonStyle(.borderedProminent)
					.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
					.keyboardShortcut(.return, modifiers: .command)
			}
			.padding()
		}
		.frame(width: 380)
		.onAppear { isFocused = true }
	}

	private func create() {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		store.createVault(name: trimmed, orgSlug: orgSlug)
		dismiss()
	}
}
