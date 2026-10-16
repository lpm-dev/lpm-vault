import SwiftUI

/// Connects a team on a Coolify instance with its address and an API token
/// created there. The token is checked with Coolify before it's saved.
struct ConnectCoolifySheet: View {
	let platforms: PlatformConnections
	/// Where what's typed is listed among what quitting would discard.
	var store: VaultStore?
	@Environment(\.dismiss) private var dismiss

	@State private var address = ""
	@State private var token = ""
	@State private var error: String?
	@State private var connectTask: Task<Void, Never>?
	@FocusState private var focusedField: Field?

	private enum Field {
		case address
		case token
	}

	private var isConnecting: Bool { connectTask != nil }

	/// What quitting would discard: the address typed, never the token.
	private var unsavedWork: String? {
		let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
		if !address.isEmpty { return address }
		return token.isEmpty ? nil : "An API token"
	}

	private var canConnect: Bool {
		!address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isConnecting
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			VStack(alignment: .leading, spacing: 16) {
				field("Coolify address") {
					TextField("https://coolify.example.com", text: $address)
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(12.5))
						.foregroundStyle(VaultPalette.textPrimary)
						.autocorrectionDisabled()
						.focused($focusedField, equals: .address)
						.onSubmit { focusedField = .token }
						.padding(.horizontal, 11)
						.frame(height: 34)
						.vaultInputField(focused: focusedField == .address)
				}
				field("API token") {
					SecureField("Paste the token", text: $token)
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(12.5))
						.foregroundStyle(VaultPalette.textPrimary)
						.focused($focusedField, equals: .token)
						.onSubmit(connect)
						.padding(.horizontal, 11)
						.frame(height: 34)
						.vaultInputField(focused: focusedField == .token)
				}
				guidance
				if let error {
					Text(error)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.redText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.disabled(isConnecting)
			.padding(24)
			VaultSheetFooter {
				Label("The token stays in this Mac's Keychain", systemImage: "lock")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Cancel", height: 28, action: close)
					.keyboardShortcut(.escape, modifiers: [])
				VaultBarButton(
					title: isConnecting ? "Connecting…" : "Connect",
					filled: true,
					disabled: !canConnect,
					height: 28,
					action: connect)
			}
		}
		.frame(width: 520)
		.background(VaultPalette.content)
		.vaultUnsavedSheetWork(store, projectID: nil, projectName: "Platforms", title: "Connect Coolify", detail: unsavedWork)
		.onAppear { focusedField = .address }
		.onDisappear(perform: cancel)
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 14) {
			Image(systemName: "server.rack")
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(VaultPalette.accentForeground)
				.frame(width: 38, height: 38)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.accentTint))
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 3) {
				Text("Connect Coolify")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Publish to the applications and services of a team on your Coolify instance.")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: close)
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	private var guidance: some View {
		VStack(alignment: .leading, spacing: 6) {
			step(1, "Turn on API access in Coolify's Settings → Advanced.")
			step(2, "In Keys & Tokens → API Tokens, create a token with the Read and Write permissions. LPM Vault doesn't need Root, Deploy or Read Sensitive.")
			step(3, "The token reaches the team you had selected when you created it.")
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.sidebar))
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func step(_ number: Int, _ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("\(number).")
				.font(.system(size: 11.5, weight: .semibold))
				.foregroundStyle(VaultPalette.textSecondary)
			Text(text)
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			VaultFieldLabel(title: title)
			content()
		}
	}

	private func connect() {
		guard canConnect else { return }
		error = nil
		let address = address
		let token = token
		connectTask = Task {
			let outcome = await platforms.connectCoolify(address: address, token: token)
			guard !Task.isCancelled else { return }
			connectTask = nil
			switch outcome {
			case .connected, .dropped:
				dismiss()
			case .failed(let message):
				error = message
			}
		}
	}

	private func cancel() {
		connectTask?.cancel()
		connectTask = nil
	}

	private func close() {
		cancel()
		dismiss()
	}
}
