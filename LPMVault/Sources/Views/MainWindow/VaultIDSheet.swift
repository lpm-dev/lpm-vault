import SwiftUI

struct VaultIDSheet: View {
	let vaultId: String
	@Environment(\.dismiss) private var dismiss

	private var jsonContent: String {
		"{\n  \"vault\": \"\(vaultId)\"\n}"
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 5) {
				Text("Env project configuration")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Connect this encrypted project to the LPM CLI.")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.padding(20)

			VaultHairline()

			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					configurationSection("ENV PROJECT ID") {
						HStack(spacing: 10) {
							Text(vaultId)
								.font(VaultTypography.mono(12))
								.foregroundStyle(VaultPalette.textPrimary)
								.textSelection(.enabled)
							Spacer(minLength: 8)
							VaultOutlineButton(systemImage: "doc.on.doc", help: "Copy env project ID") {
								copy(vaultId)
							}
							.accessibilityLabel("Copy env project ID")
						}
					}

					configurationSection("ADD TO YOUR PROJECT") {
						VStack(alignment: .leading, spacing: 10) {
							Text("Create or update lpm.json in your project root:")
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.textTertiary)

							Text(jsonContent)
								.font(VaultTypography.mono(11.5))
								.foregroundStyle(VaultPalette.textSecondary)
								.textSelection(.enabled)
								.padding(12)
								.frame(maxWidth: .infinity, alignment: .leading)
								.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.content))
								.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }

							VaultBarButton(systemImage: "doc.on.doc", title: "Copy JSON") {
								copy(jsonContent)
							}
						}
					}

					configurationSection("CLI COMMANDS") {
						VStack(alignment: .leading, spacing: 10) {
							cliCommand("Pull secrets into your project", "lpm env pull")
							cliCommand("Push local changes to cloud", "lpm env push")
							cliCommand("Use secrets in scripts", "lpm run <command>")
						}
					}
				}
				.padding(20)
			}

			VaultHairline()

			HStack {
				Spacer()
				VaultBarButton(title: "Done", filled: true) { dismiss() }
					.keyboardShortcut(.defaultAction)
			}
			.padding(16)
		}
		.frame(width: 520)
		.background(VaultPalette.content)
		.onExitCommand { dismiss() }
	}

	private func configurationSection<Content: View>(
		_ title: String,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).vaultSectionLabel()
			content()
				.padding(12)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.sidebar))
				.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		}
	}

	private func cliCommand(_ label: String, _ command: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(label)
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
			Text(command)
				.font(VaultTypography.mono(11.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.textSelection(.enabled)
				.padding(.horizontal, 9)
				.padding(.vertical, 6)
				.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.content))
				.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
		}
	}

	private func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}
