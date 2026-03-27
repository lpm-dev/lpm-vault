import SwiftUI

/// Column 1: Narrow rail showing user avatar + org avatars + settings gear.
struct AccountRailView: View {
	@Bindable var store: VaultStore

	var body: some View {
		VStack(spacing: 12) {
			// User avatar (personal vaults)
			Button {
				store.selectedAccount = .personal
				store.showAuthStatus = false
			} label: {
				avatarCircle(
					url: store.currentUser?.avatarUrl,
					fallback: store.currentUser?.username.prefix(1).uppercased() ?? "?",
					isSelected: store.selectedAccount == .personal
				)
			}
			.buttonStyle(.plain)
			.help(store.currentUser?.username ?? "Personal")

			// Org avatars
			ForEach(store.userOrgs) { org in
				Button {
					store.selectedAccount = .org(org.slug)
					store.showAuthStatus = false
				} label: {
					avatarCircle(
						url: nil,
						fallback: String(org.name.prefix(1)).uppercased(),
						isSelected: store.selectedAccount == .org(org.slug)
					)
				}
				.buttonStyle(.plain)
				.help(org.name)
			}

			Spacer()

			// Settings gear → auth status
			Button {
				store.showAuthStatus = true
			} label: {
				Image(systemName: "gearshape.fill")
					.font(.system(size: 16))
					.foregroundStyle(store.showAuthStatus ? .white : .secondary)
					.frame(width: 40, height: 40)
					.background(
						store.showAuthStatus ? Color.accentColor : Color.clear,
						in: RoundedRectangle(cornerRadius: 8)
					)
			}
			.buttonStyle(.plain)
			.help("Settings")

			// Lock button
			Button {
				store.lock()
			} label: {
				Image(systemName: "lock.open.fill")
					.font(.system(size: 14))
					.foregroundStyle(.secondary)
					.frame(width: 40, height: 40)
			}
			.buttonStyle(.plain)
			.help("Lock vault")
		}
		.padding(.top, 38)
		.padding(.bottom, 12)
		.frame(width: 70)
	}

	@ViewBuilder
	private func avatarCircle(url: String?, fallback: String, isSelected: Bool) -> some View {
		Group {
			if let avatarUrl = url, let imageURL = URL(string: avatarUrl) {
				AsyncImage(url: imageURL) { image in
					image.resizable().scaledToFill()
				} placeholder: {
					textAvatar(fallback)
				}
			} else {
				textAvatar(fallback)
			}
		}
		.frame(width: 40, height: 40)
		.clipShape(Circle())
		.overlay(
			Circle()
				.stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
		)
		.overlay(
			// DEV badge
			Group {
				if store.appEnvironment == .development && isSelected {
					Text("D")
						.font(.system(size: 7, weight: .bold))
						.foregroundStyle(.white)
						.frame(width: 12, height: 12)
						.background(.orange, in: Circle())
						.offset(x: 12, y: 12)
				}
			}
		)
	}

	private func textAvatar(_ text: String) -> some View {
		Circle()
			.fill(.quaternary)
			.overlay {
				Text(text)
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(.secondary)
			}
	}
}
