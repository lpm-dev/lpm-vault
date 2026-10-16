import SwiftUI

/// The platform accounts LPM Vault publishes to, and connecting new ones.
struct PlatformsView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var pendingDisconnect: PlatformConnection?
	@State private var connectingCoolify = false

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
					netlifySection
					coolifySection

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

					Text("Disconnecting forgets a token on this Mac only. To remove LPM Vault's access to Vercel, uninstall the integration from your Vercel team's Integrations settings. Uninstalling deletes the variables LPM Vault created there; variables that already existed keep their last published values. To remove its access to Netlify, revoke LPM Vault under Applications → Authorized applications in your Netlify user settings. To remove its access to Coolify, delete its API token in Coolify's Keys & Tokens.")
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
		} message: { connection in
			switch connection.platform {
			case .vercel:
				Text("LPM Vault forgets its token on this Mac. The integration stays installed on Vercel, and variables already published stay as they are.")
			case .coolify:
				Text("LPM Vault forgets its token on this Mac. The token keeps working in Coolify until you delete it there, and variables already published stay as they are.")
			case .netlify:
				Text("LPM Vault forgets its token on this Mac. LPM Vault stays authorized on Netlify until you revoke it there, and variables already published stay as they are.")
			}
		}
		.sheet(isPresented: $connectingCoolify) {
			ConnectCoolifySheet(platforms: platforms)
		}
		.onChange(of: isObscured) { _, obscured in
			if obscured { pendingDisconnect = nil }
		}
		.onChange(of: store.isUnlocked) { _, unlocked in
			if !unlocked { connectingCoolify = false }
		}
	}

	private var vercelSection: some View {
		section(.vercel, empty: "No Vercel accounts connected yet.") { browserConnectControls(.vercel) }
	}

	private var netlifySection: some View {
		section(.netlify, empty: "No Netlify accounts connected yet.") { browserConnectControls(.netlify) }
	}

	private var coolifySection: some View {
		section(.coolify, empty: "No Coolify teams connected yet.") {
			VStack(alignment: .leading, spacing: 8) {
				VaultBarButton(systemImage: "plus", title: "Connect Coolify", filled: true) {
					connectingCoolify = true
				}
				Text("Connects a team on your Coolify instance with an API token you create there.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	private func section<Controls: View>(
		_ platform: PublishPlatform,
		empty: String,
		@ViewBuilder controls: () -> Controls
	) -> some View {
		let connections = platforms.connections.filter { $0.platform == platform }
		return VStack(alignment: .leading, spacing: 8) {
			Text(platform.displayName.uppercased()).vaultSectionLabel()
			VStack(alignment: .leading, spacing: 0) {
				if connections.isEmpty {
					Text(platforms.isLoading ? "Loading…" : empty)
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.padding(14)
				}
				ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
					if index > 0 { VaultHairline() }
					connectionRow(connection)
				}
				VaultHairline()
				controls().padding(14)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.sidebar))
			.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		}
	}

	private func connectionRow(_ connection: PlatformConnection) -> some View {
		HStack(spacing: 12) {
			Image(systemName: connection.platform.systemImage)
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

	/// Connect and Cancel for a platform that connects in the browser, which
	/// needs an LPM sign-in. One browser connection runs at a time, so the
	/// other platform's Connect waits for it.
	private func browserConnectControls(_ platform: BrowserPlatform) -> some View {
		let isConnectingHere = platforms.connecting == platform.publishPlatform
		let needsSignIn = !store.isLoggedIn
		return VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				VaultBarButton(
					systemImage: "plus",
					title: isConnectingHere ? "Connecting…" : "Connect \(platform.displayName)",
					filled: true,
					disabled: platforms.isConnecting || needsSignIn
				) {
					switch platform {
					case .vercel: platforms.connectVercel()
					case .netlify: platforms.connectNetlify()
					}
				}
				if isConnectingHere {
					ProgressView().controlSize(.small)
					VaultBarButton(title: "Cancel", action: platforms.cancelConnecting)
				}
			}
			if needsSignIn {
				HStack(spacing: 6) {
					Text("Sign in to LPM to connect \(platform.displayName).")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
					Button("Open Account", action: store.showAccount)
						.buttonStyle(.plain)
						.font(.system(size: 11.5, weight: .medium))
						.foregroundStyle(VaultPalette.accentForeground)
				}
			} else {
				Text(Self.browserGuidance(platform, waiting: isConnectingHere && platforms.phase == .waitingForBrowser))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	static func browserGuidance(_ platform: BrowserPlatform, waiting: Bool) -> String {
		switch (platform, waiting) {
		case (.vercel, true):
			"Finish in your browser: choose the Vercel team and the projects LPM Vault can reach, then come back here."
		case (.netlify, true):
			"Finish in your browser: authorize LPM Vault on Netlify, then come back here."
		case (.netlify, false):
			"Opens Netlify in your browser to authorize LPM Vault. It reaches the sites of every team your Netlify account belongs to."
		case (.vercel, false):
			"Opens Vercel in your browser to install the LPM Vault integration for a team or your personal account."
		}
	}

	private func subtitle(_ connection: PlatformConnection) -> String {
		let kind: String
		switch connection.account {
		case .vercel(let account):
			kind = account.isTeam ? "Team\(account.slug.map { " · \($0)" } ?? "")" : "Personal account"
		case .coolify(let account):
			kind = account.instance.address
		case .netlify(let account):
			kind = account.email ?? "Netlify account"
		}
		let connected = connection.connectedAt.formatted(date: .abbreviated, time: .omitted)
		return "\(kind) · Connected \(connected)"
	}
}
