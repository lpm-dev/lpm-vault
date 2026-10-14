import SwiftUI

/// The platform accounts LPM Vault publishes to, and connecting new ones.
struct PlatformsView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var pendingDisconnect: PlatformConnection?

	private var platforms: PlatformConnections { store.platforms }

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Platforms")
					.font(.system(size: 19, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Spacer()
			}
			.padding(.horizontal, 20)
			.frame(height: 58)

			VaultHairline()

			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					Text("Connect the platforms LPM Vault publishes environments to. Their tokens stay in this Mac's Keychain.")
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)

					vercelSection

					if let notice = platforms.notice {
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
								.font(.system(size: 11))
							Text(notice.message)
								.font(.system(size: 11.5))
								.fixedSize(horizontal: false, vertical: true)
							Spacer(minLength: 4)
							Button("Dismiss", action: platforms.dismissNotice)
								.buttonStyle(.plain)
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.textTertiary)
						}
						.foregroundStyle(notice.isError ? VaultPalette.redText : VaultPalette.greenTintText)
						.accessibilityElement(children: .combine)
					}

					Text("Disconnecting forgets the token on this Mac only. To remove LPM Vault's access, uninstall the integration from your Vercel team's Integrations settings.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
				.padding(20)
				.frame(maxWidth: 640, alignment: .leading)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.background(VaultPalette.content)
		.confirmationDialog(
			"Disconnect \(pendingDisconnect?.name ?? "this account")?",
			isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }),
			titleVisibility: .visible,
			presenting: pendingDisconnect
		) { connection in
			Button("Disconnect", role: .destructive) { platforms.disconnect(connection) }
			Button("Cancel", role: .cancel) {}
		} message: { _ in
			Text("LPM Vault forgets its token on this Mac. The integration stays installed on Vercel, and variables already published stay as they are.")
		}
		.onChange(of: isObscured) { _, obscured in
			if obscured { pendingDisconnect = nil }
		}
	}

	private var vercelSection: some View {
		let connections = platforms.connections.filter { $0.platform == .vercel }
		return VStack(alignment: .leading, spacing: 8) {
			Text("VERCEL").vaultSectionLabel()
			VStack(alignment: .leading, spacing: 0) {
				if connections.isEmpty {
					Text(platforms.isLoading ? "Loading…" : "No Vercel accounts connected yet.")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.padding(14)
				}
				ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
					if index > 0 { VaultHairline() }
					connectionRow(connection)
				}
				VaultHairline()
				connectControls.padding(14)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.sidebar))
			.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		}
	}

	private func connectionRow(_ connection: PlatformConnection) -> some View {
		HStack(spacing: 12) {
			Image(systemName: "triangle.fill")
				.font(.system(size: 13))
				.foregroundStyle(VaultPalette.textPrimary)
				.frame(width: 28, height: 28)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				Text(connection.name)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text(subtitle(connection))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			Spacer(minLength: 8)
			VaultBarButton(
				title: platforms.disconnecting.contains(connection.id) ? "Disconnecting…" : "Disconnect",
				disabled: platforms.disconnecting.contains(connection.id)
			) {
				pendingDisconnect = connection
			}
			.accessibilityLabel("Disconnect \(connection.name)")
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 11)
	}

	@ViewBuilder
	private var connectControls: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				VaultBarButton(
					systemImage: "plus",
					title: platforms.isConnecting ? "Connecting…" : "Connect Vercel",
					filled: true,
					disabled: platforms.isConnecting || !store.isLoggedIn
				) {
					platforms.connectVercel()
				}
				if platforms.isConnecting {
					ProgressView().controlSize(.small)
					VaultBarButton(title: "Cancel", action: platforms.cancelConnecting)
				}
			}
			if !store.isLoggedIn {
				HStack(spacing: 6) {
					Text("Sign in to LPM to connect Vercel.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
					Button("Open Settings", action: store.showSettings)
						.buttonStyle(.plain)
						.font(.system(size: 11.5, weight: .medium))
						.foregroundStyle(VaultPalette.accentForeground)
				}
			} else if platforms.phase == .waitingForBrowser {
				Text("Finish in your browser: choose the Vercel team and the projects LPM Vault can reach, then come back here.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				Text("Opens Vercel in your browser to install the LPM Vault integration for a team or your personal account.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	private func subtitle(_ connection: PlatformConnection) -> String {
		let kind: String
		switch connection.account {
		case .vercel(let account):
			kind = account.isTeam ? "Team\(account.slug.map { " · \($0)" } ?? "")" : "Personal account"
		}
		let connected = connection.connectedAt.formatted(date: .abbreviated, time: .omitted)
		return "\(kind) · Connected \(connected)"
	}
}
