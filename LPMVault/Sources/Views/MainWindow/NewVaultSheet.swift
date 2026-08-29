import SwiftUI

/// Sheet for creating a new vault with just a name.
struct NewVaultSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var isCreating = false
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
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 5) {
					Text("New env project")
						.font(.system(size: 17, weight: .bold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text("Create a new encrypted project in \(isOrg ? (orgSlug ?? "this organization") : "your personal vault").")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}

				VStack(alignment: .leading, spacing: 7) {
					Text("PROJECT NAME").vaultSectionLabel()
					TextField("my-api-server", text: $name)
						.textFieldStyle(.plain)
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textPrimary)
						.focused($isFocused)
						.onSubmit { create() }
						.padding(.horizontal, 11)
						.frame(height: 34)
						.background(RoundedRectangle(cornerRadius: 8).fill(.white))
						.overlay { RoundedRectangle(cornerRadius: 8).stroke(isFocused ? VaultPalette.accent : VaultPalette.border, lineWidth: 1) }
				}

				if isOrg {
					HStack(spacing: 6) {
						Image(systemName: "building.2")
							.foregroundStyle(VaultPalette.accent)
						Text("Will be shared with \(orgSlug ?? "org")")
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
					}
				}
			}
			.padding(20)

			VaultHairline()

			HStack(spacing: 8) {
				Spacer()
				VaultBarButton(title: "Cancel") { dismiss() }
					.keyboardShortcut(.escape, modifiers: [])
				VaultBarButton(
					title: "Create project",
					filled: true,
					disabled: name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating,
					action: create
				)
				.keyboardShortcut(.defaultAction)
			}
			.padding(16)
		}
		.frame(width: 420)
		.background(VaultPalette.content)
		.onAppear { isFocused = true }
	}

	private func create() {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, !isCreating else { return }
		isCreating = true
		Task {
			if await store.createVault(name: trimmed, orgSlug: orgSlug) {
				dismiss()
			} else {
				isCreating = false
			}
		}
	}
}
