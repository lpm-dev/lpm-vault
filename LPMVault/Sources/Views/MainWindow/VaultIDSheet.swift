import SwiftUI

/// Instruction lightbox shown when clicking the vault ID in the footer.
struct VaultIDSheet: View {
	let vaultId: String
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Vault Configuration")
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
				// Vault ID
				VStack(alignment: .leading, spacing: 4) {
					Text("Vault ID")
						.font(.subheadline)
						.fontWeight(.medium)
					HStack {
						Text(vaultId)
							.font(.system(.body, design: .monospaced))
							.textSelection(.enabled)
						Spacer()
						Button {
							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(vaultId, forType: .string)
						} label: {
							Image(systemName: "doc.on.doc")
						}
						.buttonStyle(.plain)
						.help("Copy vault ID")
					}
					.padding(8)
					.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
				}

				// lpm.json instruction
				VStack(alignment: .leading, spacing: 4) {
					Text("Add to your project")
						.font(.subheadline)
						.fontWeight(.medium)
					Text("Create or update `lpm.json` in your project root:")
						.font(.caption)
						.foregroundStyle(.secondary)

					let jsonContent = "{\n  \"vault\": \"\(vaultId)\"\n}"
					Text(jsonContent)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)
						.padding(8)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

					HStack {
						Button {
							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(jsonContent, forType: .string)
						} label: {
							Label("Copy JSON", systemImage: "doc.on.doc")
								.font(.caption)
						}
						.buttonStyle(.bordered)
						.controlSize(.small)
					}
				}

				// CLI commands
				VStack(alignment: .leading, spacing: 4) {
					Text("CLI Commands")
						.font(.subheadline)
						.fontWeight(.medium)

					VStack(alignment: .leading, spacing: 6) {
						cliCommand("Pull secrets into your project:", "lpm env vars pull")
						cliCommand("Push local changes to cloud:", "lpm env vars push")
						cliCommand("Use secrets in scripts:", "lpm run <command>")
					}
				}
			}
			.padding()

			Divider()

			HStack {
				Spacer()
				Button("Done") { dismiss() }
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.return, modifiers: .command)
			}
			.padding()
		}
		.frame(width: 480)
	}

	private func cliCommand(_ label: String, _ command: String) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(label)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(command)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.padding(.horizontal, 8)
				.padding(.vertical, 4)
				.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
		}
	}
}
