import SwiftUI

struct TokenListView: View {
	@Bindable var store: VaultStore
	let title: String
	let tokens: [LPMToken]
	let orgSlug: String?

	@State private var showRevokeConfirmation = false
	@State private var tokenToRevoke: LPMToken?
	@State private var localSearch = ""
	@State private var showSearch = false
	@FocusState private var isSearchFocused: Bool

	private var filteredTokens: [LPMToken] {
		guard !localSearch.isEmpty else { return tokens }
		let query = localSearch.lowercased()
		return tokens.filter { $0.name.lowercased().contains(query) }
	}

	var body: some View {
		VStack(spacing: 0) {
			// Custom header bar
			customToolbar
			Divider()

			// Search bar
			if showSearch {
				searchBar
				Divider()
			}

			if filteredTokens.isEmpty {
				emptyState
			} else {
				List {
					ForEach(filteredTokens) { token in
						tokenRow(token)
					}
				}
			}
		}
		.alert(
			"Revoke \"\(tokenToRevoke?.name ?? "")\"?",
			isPresented: $showRevokeConfirmation
		) {
			Button("Cancel", role: .cancel) {
				tokenToRevoke = nil
			}
			Button("Revoke", role: .destructive) {
				if let token = tokenToRevoke {
					Task {
						if let slug = orgSlug {
							await store.revokeOrgToken(token, orgSlug: slug)
						} else {
							await store.revokePersonalToken(token)
						}
					}
				}
				tokenToRevoke = nil
			}
		} message: {
			Text("This token will be permanently revoked and can no longer be used for authentication.")
		}
	}

	// MARK: - Custom Toolbar

	private var customToolbar: some View {
		HStack(spacing: 8) {
			Text(title)
				.font(.title3)
				.fontWeight(.semibold)

			Spacer()

			// Create token
			ToolbarButtonGroup {
				ToolbarIconButton(icon: "plus", help: "Create token on lpm.dev") {
					NSWorkspace.shared.open(URL(string: "https://lpm.dev/dashboard/settings/tokens")!)
				}
			}

			// Search
			ToolbarButtonGroup {
				ToolbarIconButton(
					icon: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass",
					help: "Search tokens"
				) {
					showSearch.toggle()
					if showSearch {
						isSearchFocused = true
					} else {
						localSearch = ""
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}

	// MARK: - Search Bar

	private var searchBar: some View {
		HStack {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(.secondary)
			TextField("Filter tokens...", text: $localSearch)
				.textFieldStyle(.plain)
				.focused($isSearchFocused)
				.onExitCommand {
					showSearch = false
					localSearch = ""
				}
			if !localSearch.isEmpty {
				Button {
					localSearch = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	// MARK: - Token Row

	@ViewBuilder
	private func tokenRow(_ token: LPMToken) -> some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 6) {
					Text(token.name)
						.fontWeight(.medium)

					if let scope = token.scope {
						Text(scope)
							.font(.caption)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(
								scope == "publish" ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15),
								in: Capsule()
							)
							.foregroundStyle(scope == "publish" ? .orange : .blue)
					}

					expiryBadge(token)
				}

				HStack(spacing: 12) {
					if let created = token.createdAt {
						Label("Created \(formatDate(created))", systemImage: "calendar")
					}
					if let expiresAt = token.expiresAt {
						Label("Expires \(formatDate(expiresAt))", systemImage: "clock.badge.exclamationmark")
					}
					if let lastUsed = token.lastUsedAt {
						Label("Last used \(formatDate(lastUsed))", systemImage: "clock")
					}
					if let count = token.downloadCount, count > 0 {
						Label("\(count) requests", systemImage: "arrow.left.arrow.right")
					}
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)
			}

			Spacer()

			Button(role: .destructive) {
				tokenToRevoke = token
				showRevokeConfirmation = true
			} label: {
				Text("Revoke")
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
		}
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private func expiryBadge(_ token: LPMToken) -> some View {
		switch token.expiryStatus {
		case .critical:
			Label("\(token.daysUntilExpiry ?? 0)d left", systemImage: "exclamationmark.triangle.fill")
				.font(.caption)
				.foregroundStyle(.red)
		case .warning:
			Label("\(token.daysUntilExpiry ?? 0)d left", systemImage: "clock.badge.exclamationmark")
				.font(.caption)
				.foregroundStyle(.orange)
		case .expired:
			Label("Expired", systemImage: "xmark.circle.fill")
				.font(.caption)
				.foregroundStyle(.red)
		case .healthy, .noExpiry:
			EmptyView()
		}
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			Image(systemName: "key.slash")
				.font(.system(size: 36))
				.foregroundStyle(.secondary)
			Text("No tokens")
				.font(.title3)
				.foregroundStyle(.secondary)
			Button("Create token on lpm.dev") {
				NSWorkspace.shared.open(URL(string: "https://lpm.dev/dashboard/settings/tokens")!)
			}
			.buttonStyle(.borderedProminent)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func formatDate(_ iso: String) -> String {
		let formatters: [ISO8601DateFormatter] = {
			let withFrac = ISO8601DateFormatter()
			withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			let plain = ISO8601DateFormatter()
			return [withFrac, plain]
		}()

		var date: Date?
		for fmt in formatters {
			if let d = fmt.date(from: iso) {
				date = d
				break
			}
		}
		guard let date else { return iso }

		let relative = RelativeDateTimeFormatter()
		relative.unitsStyle = .full
		return relative.localizedString(for: date, relativeTo: Date())
	}
}
