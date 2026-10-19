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
			header

			VaultHairline()

			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					if let notice = platforms.notice { noticeBanner(notice) }
					connectedSection
					addPlatformSection
					Text(Self.revocationNote(offersCloudflare: offersCloudflare))
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineSpacing(2)
						.fixedSize(horizontal: false, vertical: true)
				}
				.padding(.horizontal, 24)
				.padding(.top, 16)
				.padding(.bottom, 18)
				.frame(maxWidth: 900, alignment: .leading)
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

	private var header: some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text("Platforms")
				.font(.system(size: 19, weight: .bold))
				.foregroundStyle(VaultPalette.textPrimary)
				.accessibilityAddTraits(.isHeader)
			Text("Tokens stay in this Mac's Keychain")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 24)
		.frame(height: 58)
	}

	private func noticeBanner(_ notice: PlatformConnections.Notice) -> some View {
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
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.background(RoundedRectangle(cornerRadius: 8).fill(notice.isError ? VaultPalette.redTint : VaultPalette.greenTint))
		.accessibilityElement(children: .combine)
	}

	// MARK: Connected

	/// The order the page lists platforms in, Cloudflare's place kept where it isn't offered.
	static let pageOrder: [PublishPlatform] = [.vercel, .netlify, .github, .cloudflare, .coolify]

	/// Connections grouped by platform, in the page's order, each platform's in the order they're given.
	static func grouped(_ connections: [PlatformConnection]) -> [PlatformConnection] {
		pageOrder.flatMap { platform in connections.filter { $0.platform == platform } }
	}

	private var connectedSection: some View {
		let connections = Self.grouped(platforms.connections)
		let label = Text(connections.isEmpty ? "CONNECTED" : "CONNECTED · \(connections.count)")
			.vaultSectionLabel()
			.accessibilityAddTraits(.isHeader)
		return VStack(alignment: .leading, spacing: 7) {
			if connections.isEmpty {
				label
			} else {
				let note = Text(Self.disconnectingNote(revokesCloudflare: connections.contains { $0.platform == .cloudflare }))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
				ViewThatFits(in: .horizontal) {
					HStack(spacing: 8) {
						label
						Spacer(minLength: 8)
						note.lineLimit(1)
					}
					VStack(alignment: .leading, spacing: 4) {
						label
						note.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			VStack(alignment: .leading, spacing: 0) {
				if connections.isEmpty {
					if platforms.isLoading {
						Text("Loading…")
							.font(.system(size: 12.5))
							.foregroundStyle(VaultPalette.textTertiary)
							.padding(14)
					} else {
						emptyState
					}
				}
				ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
					if index > 0 { VaultHairline(color: VaultPalette.rowDivider) }
					connectionRow(connection)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.vaultPlatformCard()
			cleanupNotes
		}
	}

	private var emptyState: some View {
		VStack(spacing: 8) {
			Image(systemName: "cloud")
				.font(.system(size: 17, weight: .medium))
				.foregroundStyle(VaultPalette.textTertiary)
				.frame(width: 40, height: 40)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.neutralTint))
				.accessibilityHidden(true)
			Text("No platforms connected")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
			Text("Connect one below to publish environments to it. Touch ID or your password confirms every publish.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
				.multilineTextAlignment(.center)
				.lineSpacing(2)
				.frame(maxWidth: 380)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 26)
		.frame(maxWidth: .infinity)
	}

	private func connectionRow(_ connection: PlatformConnection) -> some View {
		let isExpired = platforms.expired.contains(connection.id)
		let details = VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 8) {
				Text(connection.name)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				Text("on \(connection.platform.displayName)")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize()
				statusPill(expired: isExpired, platform: connection.platform)
			}
			Text(subtitle(connection))
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.help(Self.reachedAccounts(connection) ?? "")
			if isExpired {
				Text(Self.expiredNote(connection.platform, signedIn: store.isLoggedIn))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.orangeTintText)
			}
		}
		let isWaitingHere = platforms.reconnecting == connection.id && platforms.phase == .waitingForBrowser
		let logo = PlatformLogo(platform: connection.platform, size: 28)
		return VStack(alignment: .leading, spacing: 6) {
			// The buttons go under the details when both don't fit on one line.
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 12) {
					logo
					details
					Spacer(minLength: 8)
					rowActions(connection, expired: isExpired)
				}
				HStack(alignment: .top, spacing: 12) {
					logo
					VStack(alignment: .leading, spacing: 8) {
						details.fixedSize(horizontal: false, vertical: true)
						rowActions(connection, expired: isExpired)
					}
				}
			}
			if isWaitingHere, let browser = BrowserPlatform(connection.platform) {
				Text(Self.browserGuidance(browser, waiting: true))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.leading, 40)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 9)
	}

	private func statusPill(expired: Bool, platform: PublishPlatform) -> some View {
		Text(expired ? Self.expiredStatus(platform) : "Connected")
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(expired ? VaultPalette.orangeTintText : VaultPalette.greenTintText)
			.padding(.horizontal, 7)
			.frame(height: 20)
			.background(RoundedRectangle(cornerRadius: 6).fill(expired ? VaultPalette.orangeTint : VaultPalette.greenTint))
			.fixedSize()
	}

	/// What an expired connection's status says: a Cloudflare login's
	/// renewal can also fail because its access was revoked, so it says only that it stopped working.
	static func expiredStatus(_ platform: PublishPlatform) -> String {
		platform == .cloudflare ? "No longer works" : "Expired"
	}

	/// What an expired connection's row says to do about it. Browser
	/// platforms reconnect only through an LPM sign-in.
	static func expiredNote(_ platform: PublishPlatform, signedIn: Bool) -> String {
		BrowserPlatform(platform) != nil && !signedIn
			? "Sign in to LPM, then reconnect to keep publishing through it."
			: "Reconnect to keep publishing through it."
	}

	private func rowActions(_ connection: PlatformConnection, expired: Bool) -> some View {
		HStack(spacing: 6) {
			if expired {
				if platforms.reconnecting == connection.id {
					ProgressView().controlSize(.small)
					VaultBarButton(title: "Reconnecting…", filled: true, disabled: true) {}
						.accessibilityLabel("Reconnecting… \(connection.name)")
					VaultBarButton(title: "Cancel", action: platforms.cancelConnecting)
						.accessibilityLabel("Cancel reconnecting \(connection.name)")
				} else {
					let needsSignIn = BrowserPlatform(connection.platform) != nil && !store.isLoggedIn
					VaultBarButton(systemImage: "arrow.clockwise", title: "Reconnect", filled: true, disabled: platforms.isConnecting || needsSignIn) {
						if connection.platform == .coolify { connectingCoolify = true } else { platforms.reconnect(connection) }
					}
					.accessibilityLabel("Reconnect \(connection.name)")
				}
			}
			if connection.platform == .github {
				VaultBarButton(title: "Install on GitHub") { platforms.openInstallPage(for: connection) }
					.accessibilityLabel("Install on GitHub for \(connection.name)")
			}
			if connection.platform == .cloudflare {
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
		.fixedSize()
	}

	@ViewBuilder
	private var cleanupNotes: some View {
		if !platforms.retiring.isEmpty {
			cleanupNote(
				systemImage: platforms.retiringAwaitsSignIn ? "person.crop.circle.badge.exclamationmark" : "hourglass",
				text: Self.retiringMessage(count: platforms.retiring.count, awaitingSignIn: platforms.retiringAwaitsSignIn, signedIn: store.isLoggedIn),
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

	/// What disconnecting the listed connections does, naming Cloudflare only when a login of it is listed.
	static func disconnectingNote(revokesCloudflare: Bool) -> String {
		revokesCloudflare
			? "Disconnecting forgets a token on this Mac only, except for Cloudflare, whose access LPM Vault revokes as it disconnects"
			: "Disconnecting forgets a token on this Mac only"
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

	// MARK: Adding a platform

	/// Whether Cloudflare can be connected through the Registry the app is
	/// signed in to, or this Mac has Cloudflare logins, or cleanups of them, to show.
	private var offersCloudflare: Bool {
		CloudflareOAuth.isAvailable(through: store.appEnvironment.issuer) || platforms.connections.contains { $0.platform == .cloudflare }
			|| !platforms.retiring.isEmpty || !platforms.markers.isEmpty
	}

	private var addPlatformSection: some View {
		let offered = Self.pageOrder.filter { $0 != .cloudflare || offersCloudflare }
		var counts: [PublishPlatform: Int] = [:]
		for connection in platforms.connections { counts[connection.platform, default: 0] += 1 }
		return VStack(alignment: .leading, spacing: 7) {
			Text("ADD A PLATFORM")
				.vaultSectionLabel()
				.accessibilityAddTraits(.isHeader)
			if !store.isLoggedIn {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text("Sign in to LPM to connect \(Self.browserPlatformNames(offered)).")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
					Button("Open Account", action: store.showAccount)
						.buttonStyle(.plain)
						.font(.system(size: 11.5, weight: .medium))
						.foregroundStyle(VaultPalette.accentForeground)
						.vaultPointingHand()
				}
				.padding(.bottom, 2)
			}
			PlatformTileGrid {
				ForEach(offered, id: \.self) { platform in
					tile(platform, connected: counts[platform] ?? 0)
				}
			}
		}
	}

	/// The browser platforms among `platforms`, as the sign-in note lists them: "Vercel, Netlify or GitHub".
	static func browserPlatformNames(_ platforms: [PublishPlatform]) -> String {
		let names = platforms.filter { BrowserPlatform($0) != nil }.map(\.displayName)
		guard let last = names.last else { return "" }
		return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
	}

	private func tile(_ platform: PublishPlatform, connected: Int) -> some View {
		let browser = BrowserPlatform(platform)
		// Reconnecting shows on the row being reconnected, not here.
		let isConnectingHere = browser != nil && platforms.connecting == platform && platforms.reconnecting == nil
		return VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 10) {
				PlatformLogo(platform: platform, size: 32)
				VStack(alignment: .leading, spacing: 1) {
					Text(platform.displayName)
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					// Until the first listing ends, how many are connected isn't known yet; the line keeps its place.
					let isCounting = connected == 0 && platforms.isLoading
					Text(connected == 0 ? "Not connected" : "\(connected) connected")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.opacity(isCounting ? 0 : 1)
						.accessibilityHidden(isCounting)
				}
			}
			Text(browser.map { Self.browserGuidance($0, waiting: isConnectingHere && platforms.phase == .waitingForBrowser) }
				?? "Connects a team on your Coolify instance with an API token you create there.")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineSpacing(2)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
			HStack(spacing: 8) {
				let title = isConnectingHere ? "Connecting…" : "Connect"
				VaultBarButton(
					systemImage: isConnectingHere ? nil : "plus",
					title: title,
					disabled: browser != nil && (platforms.isConnecting || !store.isLoggedIn)
				) {
					switch browser {
					case .vercel?: platforms.connectVercel()
					case .netlify?: platforms.connectNetlify()
					case .github?: platforms.connectGitHub()
					case .cloudflare?: platforms.connectCloudflare()
					case nil: connectingCoolify = true
					}
				}
				.accessibilityLabel("\(title) \(platform.displayName)")
				if isConnectingHere {
					ProgressView().controlSize(.small)
					VaultBarButton(title: "Cancel", action: platforms.cancelConnecting)
				}
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.vaultPlatformCard()
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

	// MARK: Removing access

	/// Where to end LPM Vault's access on each platform, in the page's order, naming Cloudflare only where it's offered.
	static func revocationSteps(offersCloudflare: Bool) -> [(platform: PublishPlatform, step: String)] {
		var steps: [(platform: PublishPlatform, step: String)] = [
			(.vercel, "Integrations settings, where uninstalling deletes the variables LPM Vault created"),
			(.netlify, "Authorized applications"),
			(.github, "Authorized GitHub Apps and Installed GitHub Apps; an organization's owner uninstalls it in the organization's settings"),
		]
		if offersCloudflare { steps.append((.cloudflare, "disconnecting here revokes it")) }
		steps.append((.coolify, "Keys & Tokens"))
		return steps
	}

	static func revocationNote(offersCloudflare: Bool) -> AttributedString {
		var note = AttributedString("To remove LPM Vault's access entirely, revoke it on the platform: ")
		for (index, step) in revocationSteps(offersCloudflare: offersCloudflare).enumerated() {
			if index > 0 { note += AttributedString(" · ") }
			var name = AttributedString(step.platform.displayName)
			name.swiftUI.font = .system(size: 11.5, weight: .semibold)
			name.swiftUI.foregroundColor = VaultPalette.textSecondary
			note += name
			note += AttributedString(" → \(step.step)")
		}
		note += AttributedString(".")
		return note
	}

	// MARK: Cloudflare

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
}

extension View {
	fileprivate func vaultPlatformCard() -> some View {
		background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.sidebar))
			.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
	}
}

/// Lays tiles out in as many columns at least `minimumColumnWidth` wide as
/// fit, up to `maximumColumns`, with every tile in a row as tall as the
/// row's tallest, so their bottom edges, and what they pin there, line up.
struct PlatformTileGrid: Layout {
	var minimumColumnWidth: CGFloat = 220
	var maximumColumns = 3
	var spacing: CGFloat = 12

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
		let heights = rowHeights(subviews, width: width)
		return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let columns = columnCount(for: bounds.width)
		let width = columnWidth(bounds.width, columns: columns)
		var y = bounds.minY
		for (row, height) in rowHeights(subviews, width: bounds.width).enumerated() {
			for column in 0..<columns {
				let index = row * columns + column
				guard index < subviews.count else { break }
				subviews[index].place(
					at: CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing), y: y),
					proposal: ProposedViewSize(width: width, height: height))
			}
			y += height + spacing
		}
	}

	private var idealWidth: CGFloat {
		minimumColumnWidth * CGFloat(maximumColumns) + spacing * CGFloat(maximumColumns - 1)
	}

	func columnCount(for width: CGFloat) -> Int {
		max(1, min(maximumColumns, Int((width + spacing) / (minimumColumnWidth + spacing))))
	}

	private func columnWidth(_ width: CGFloat, columns: Int) -> CGFloat {
		max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
	}

	private func rowHeights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
		let columns = columnCount(for: width)
		let proposal = ProposedViewSize(width: columnWidth(width, columns: columns), height: nil)
		return stride(from: 0, to: subviews.count, by: columns).map { start in
			subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(proposal).height }.max() ?? 0
		}
	}
}
