import SwiftUI

/// The platform accounts LPM Vault publishes to, and connecting new ones.
struct PlatformsView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var pendingDisconnect: PlatformConnection?
	@State private var connectingCoolify = false
	@State private var renaming: PlatformConnection?
	@State private var renameDraft = ""
	@State private var renameError: String?
	/// Whether the privacy curtain is up, as the Cloudflare question's handlers read it when AppKit calls them, after the curtain moved.
	@State private var promptCurtained = false

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
					githubSection
					if offersCloudflare { cloudflareSection }
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

					Text(Self.disconnectingNote(offersCloudflare: offersCloudflare))
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
			case .github:
				Text("LPM Vault forgets its token on this Mac. The LPM Vault app stays authorized and installed on GitHub until you revoke or uninstall it there, and secrets and variables already published stay as they are.")
			case .cloudflare:
				Text(Self.cloudflareDisconnectMessage(connection, others: platforms.otherLogins(reaching: connection)))
			}
		}
		.confirmationDialog(
			Self.cloudflarePromptTitle(platforms.cloudflarePrompt),
			// Behind the privacy curtain the question waits, unanswered, and shows again with the page.
			// A dismissal cancels only the question it dismissed, never one asked after it.
			isPresented: Binding(
				get: { platforms.cloudflarePrompt != nil && !isObscured },
				set: { [number = platforms.cloudflarePromptNumber] shown in
					if !shown, !promptCurtained { platforms.answerCloudflare(.cancel, to: number) }
				}),
			titleVisibility: .visible,
			presenting: platforms.cloudflarePrompt.map { (number: platforms.cloudflarePromptNumber, prompt: $0) }
		) { shown in
			// Dismissing the dialog runs its Cancel button, which the curtain going up mustn't.
			let cancel = { if !promptCurtained { platforms.answerCloudflare(.cancel, to: shown.number) } }
			switch shown.prompt {
			case .otherLogin(let reconnecting):
				Button("Add It Separately") { platforms.answerCloudflare(.addSeparately, to: shown.number) }
				Button("Replace \(reconnecting)", role: .destructive) { platforms.answerCloudflare(.replace, to: shown.number) }
				Button("Cancel", role: .cancel, action: cancel)
			case .losesAccounts:
				Button("Connect Anyway", role: .destructive) { platforms.answerCloudflare(.proceed, to: shown.number) }
				Button("Cancel", role: .cancel, action: cancel)
			}
		} message: { shown in
			Text(Self.cloudflarePromptMessage(shown.prompt))
		}
		.alert(
			"Rename \(renaming?.name ?? "login")",
			isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
			presenting: renaming
		) { connection in
			TextField("Name", text: $renameDraft)
			Button("Rename") { rename(connection) }
			Button("Cancel", role: .cancel) {}
		} message: { _ in
			Text(renameError ?? "LPM Vault shows this name for the Cloudflare login on this Mac, in reviews and in confirmations.")
		}
		.sheet(isPresented: $connectingCoolify) {
			ConnectCoolifySheet(platforms: platforms, store: store)
		}
		.onChange(of: isObscured) { _, obscured in
			promptCurtained = obscured
			if obscured {
				pendingDisconnect = nil
				renaming = nil
			}
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

	private var githubSection: some View {
		section(.github, empty: "No GitHub accounts connected yet.") { browserConnectControls(.github) }
	}

	/// Whether Cloudflare can be connected through the Registry the app is
	/// signed in to, or this Mac has Cloudflare logins, or cleanups of them, to show.
	private var offersCloudflare: Bool {
		CloudflareOAuth.isAvailable(through: store.appEnvironment.issuer) || platforms.connections.contains { $0.platform == .cloudflare }
			|| !platforms.retiring.isEmpty || !platforms.markers.isEmpty
	}

	private var cloudflareSection: some View {
		section(.cloudflare, empty: "No Cloudflare logins connected yet.") {
			VStack(alignment: .leading, spacing: 10) {
				if !platforms.retiring.isEmpty {
					cleanupNote(
						systemImage: platforms.retiringAwaitsSignIn ? "person.crop.circle.badge.exclamationmark" : "hourglass",
						text: Self.retiringMessage(
							count: platforms.retiring.count, awaitingSignIn: platforms.retiringAwaitsSignIn, signedIn: store.isLoggedIn),
						isError: false)
				}
				if !platforms.markers.isEmpty {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						cleanupNote(
							systemImage: "exclamationmark.triangle.fill",
							text: PlatformConnections.unrevokedMessage(count: platforms.markers.count),
							isError: true)
						Spacer(minLength: 4)
						Button("Dismiss") { platforms.dismissMarkers() }
							.buttonStyle(.plain)
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
							.accessibilityLabel(
								platforms.markers.count == 1
									? "Dismiss the note about an unconfirmed revocation" : "Dismiss the note about unconfirmed revocations")
					}
				}
				browserConnectControls(.cloudflare)
			}
		}
	}

	private func cleanupNote(systemImage: String, text: String, isError: Bool) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: systemImage).font(.system(size: 11)).accessibilityHidden(true)
			Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
		}
		.foregroundStyle(isError ? VaultPalette.orangeTintText : VaultPalette.textTertiary)
		.accessibilityElement(children: .combine)
	}

	/// Every account a Cloudflare login reaches, when its row names only some of them.
	static func reachedAccounts(_ connection: PlatformConnection) -> String? {
		guard case .cloudflare(let login) = connection.account, login.accounts.count > 2 else { return nil }
		return "Reaches " + ListFormatter.localizedString(byJoining: login.accounts.map(\.name))
	}

	/// What disconnecting does on each platform, naming Cloudflare only where it's offered.
	static func disconnectingNote(offersCloudflare: Bool) -> String {
		let forgets = offersCloudflare
			? "Disconnecting forgets a token on this Mac only, except for Cloudflare, whose access LPM Vault revokes as it disconnects."
			: "Disconnecting forgets a token on this Mac only."
		return forgets + " To remove LPM Vault's access to Vercel, uninstall the integration from your Vercel team's Integrations settings. Uninstalling deletes the variables LPM Vault created there; variables that already existed keep their last published values. To remove its access to Netlify, revoke LPM Vault under Applications → Authorized applications in your Netlify user settings. To remove its access to GitHub, revoke it under Applications → Authorized GitHub Apps in your GitHub settings, and uninstall it under Installed GitHub Apps in your settings; an organization's owner uninstalls it in the organization's settings. To remove its access to Coolify, delete its API token in Coolify's Keys & Tokens."
	}

	/// What the note about cleanups still revoking says: that they go on, or,
	/// when some wait for a sign-in to the Registry that issued their tokens, what finishes them.
	static func retiringMessage(count: Int, awaitingSignIn: Bool = false, signedIn: Bool = true) -> String {
		switch (awaitingSignIn, signedIn) {
		case (true, false):
			"Sign in to LPM to finish revoking Cloudflare access LPM Vault no longer uses."
		case (true, true):
			"LPM Vault can't finish revoking Cloudflare access it no longer uses through the LPM environment it's signed in to. Sign in through the one that access was connected in."
		case (false, _) where count == 1:
			"LPM Vault is still revoking a Cloudflare login's access it no longer uses. It finishes once lpm.dev confirms it."
		case (false, _):
			"LPM Vault is still revoking the access of \(count) Cloudflare logins it no longer uses. It finishes once lpm.dev confirms it."
		}
	}

	static func cloudflareDisconnectMessage(_ connection: PlatformConnection, others: [(account: String, logins: [String])]) -> String {
		var message = "LPM Vault revokes its access to \(connection.name) on Cloudflare, through lpm.dev, and forgets it on this Mac. Secrets already published stay as they are."
		for other in others {
			message += " Destinations in \(other.account) go on publishing through \(other.logins.joined(separator: " or "))."
		}
		return message
	}

	static func cloudflarePromptTitle(_ prompt: PlatformConnections.CloudflarePrompt?) -> String {
		switch prompt {
		case .otherLogin(let reconnecting)?: "You approved a different Cloudflare login, not \(reconnecting)"
		case .losesAccounts(let label, _)?: "\(label) would reach fewer accounts"
		case nil: ""
		}
	}

	static func cloudflarePromptMessage(_ prompt: PlatformConnections.CloudflarePrompt) -> String {
		switch prompt {
		case .otherLogin(let reconnecting):
			"Add the login you approved beside \(reconnecting), or put it in \(reconnecting)'s place, which revokes \(reconnecting)'s access. Destinations stay with their Cloudflare accounts either way."
		case .losesAccounts(let label, let accounts):
			"LPM Vault would no longer reach \(ListFormatter.localizedString(byJoining: accounts)) through \(label), so destinations there stop publishing until a login that reaches them is connected."
		}
	}

	private func rename(_ connection: PlatformConnection) {
		let draft = renameDraft
		Task {
			if let error = await platforms.rename(connection, to: draft) {
				renameError = error
				renaming = connection
			} else {
				renameError = nil
			}
		}
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
					.help(Self.reachedAccounts(connection) ?? "")
				if platforms.expired.contains(connection.id) {
					Text(connection.platform == .cloudflare
						? "No longer works. Reconnect to keep publishing through it."
						: "Expired. Connect \(connection.platform.displayName) again to keep publishing.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.orangeTintText)
				}
			}
			Spacer(minLength: 8)
			if connection.platform == .github {
				VaultBarButton(title: "Install on GitHub") { platforms.openInstallPage(for: connection) }
					.accessibilityLabel("Install on GitHub for \(connection.name)")
			}
			if connection.platform == .cloudflare {
				if platforms.expired.contains(connection.id) {
					let title = platforms.reconnecting == connection.id ? "Reconnecting…" : "Reconnect"
					VaultBarButton(title: title, disabled: platforms.isConnecting || !store.isLoggedIn) { platforms.reconnectCloudflare(connection) }
						.accessibilityLabel("\(title) \(connection.name)")
				}
				VaultBarButton(title: "Rename") {
					renameDraft = connection.name
					renameError = nil
					renaming = connection
				}
				.accessibilityLabel("Rename \(connection.name)")
			}
			let disconnectTitle = platforms.disconnecting.contains(connection.id) ? "Disconnecting…" : "Disconnect"
			VaultBarButton(title: disconnectTitle, disabled: platforms.disconnecting.contains(connection.id)) {
				pendingDisconnect = connection
			}
			.accessibilityLabel("\(disconnectTitle) \(connection.name)")
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
					case .github: platforms.connectGitHub()
					case .cloudflare: platforms.connectCloudflare()
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
		case (.github, true):
			"Finish in your browser: authorize LPM Vault on GitHub, then come back here."
		case (.github, false):
			"Opens GitHub in your browser to authorize LPM Vault. It reaches the repositories you can reach on the accounts where its GitHub App is installed."
		case (.cloudflare, true):
			"Finish in your browser: choose the Cloudflare accounts LPM Vault can reach, approve it, then come back here."
		case (.cloudflare, false):
			"Opens Cloudflare in your browser to approve LPM Vault for the accounts you choose. It publishes your Workers' runtime secrets."
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
		case .github(let account):
			kind = "@\(account.login)"
		case .cloudflare(let account):
			kind = account.accountsSummary
		}
		let connected = connection.connectedAt.formatted(date: .abbreviated, time: .omitted)
		return "\(kind) · Connected \(connected)"
	}
}
