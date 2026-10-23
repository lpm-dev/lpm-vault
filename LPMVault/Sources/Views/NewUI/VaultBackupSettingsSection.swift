import SwiftUI

/// The Settings page's Backup & Restore card: why a backup matters, the
/// actions, and when the last one was made.
struct VaultBackupSettingsSection: View {
	@Bindable var store: VaultStore
	let exportBackup: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "archivebox")
					.font(.system(size: 15, weight: .medium))
					.foregroundStyle(VaultPalette.accentForeground)
					.frame(width: 36, height: 36)
					.background(RoundedRectangle(cornerRadius: 9).fill(VaultPalette.accentTint))
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 3) {
					Text("Your Keychain data stays on this Mac")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text("A backup is an encrypted file you keep yourself. It’s how you move LPM Vault to a new Mac, or keep your projects through erasing this one.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			VaultHairline(color: VaultPalette.rowDivider)
			HStack(spacing: 8) {
				VaultBarButton(systemImage: "square.and.arrow.up", title: "Export backup…", disabled: !store.canUseLocalSecrets, height: 28, action: exportBackup)
				Spacer(minLength: 12)
				Text(Self.lastBackupText(store.lastBackup))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
		}
	}

	static func lastBackupText(_ record: VaultBackupRecord?) -> String {
		guard let record else { return "No backup yet" }
		let date = record.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
		return "Last backup \(date) · \(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))"
	}
}
