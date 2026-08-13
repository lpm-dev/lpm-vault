import SwiftUI

/// Column 1: Narrow rail showing user avatar + org avatars + settings gear.
struct AccountRailView: View {
	@Bindable var store: VaultStore

	var body: some View {
		VStack(spacing: 12) {
			// User avatar (personal vaults)
			Button {
				store.selectAccount(.personal)
			} label: {
				avatarView(
					url: store.currentUser?.avatarUrl,
					fallback: store.currentUser?.username.prefix(1).uppercased() ?? "?",
					isSelected: !store.showAuthStatus && store.selectedAccount == .personal,
					isOrg: false
				)
			}
			.buttonStyle(.plain)
			.help(store.currentUser?.username ?? "Personal")
			.accessibilityLabel("Personal env projects")
			.accessibilityAddTraits(
				!store.showAuthStatus && store.selectedAccount == .personal ? .isSelected : []
			)

			// Org avatars (rounded squares)
			ForEach(store.userOrgs) { org in
				Button {
					store.selectAccount(.org(org.slug))
				} label: {
					avatarView(
						url: nil,
						fallback: String(org.name.prefix(1)).uppercased(),
						isSelected: !store.showAuthStatus && store.selectedAccount == .org(org.slug),
						isOrg: true
					)
				}
				.buttonStyle(.plain)
				.help(org.name)
				.accessibilityLabel("\(org.name) env projects")
				.accessibilityAddTraits(
					!store.showAuthStatus && store.selectedAccount == .org(org.slug) ? .isSelected : []
				)
			}

			Spacer()

			// Settings gear → auth status
			Button {
				store.showSettings()
			} label: {
				Image(systemName: "gearshape.fill")
					.font(.system(size: 16))
					.foregroundStyle(store.showAuthStatus ? .white : .secondary)
					.frame(width: 44, height: 44)
					.contentShape(Rectangle())
					.background(
						store.showAuthStatus ? Color.accentColor : Color.clear,
						in: RoundedRectangle(cornerRadius: 10)
					)
			}
			.buttonStyle(.plain)
			.help("Settings")
			.accessibilityLabel("Settings")
			.accessibilityAddTraits(store.showAuthStatus ? .isSelected : [])

			// Lock button
			Button {
				store.lock()
			} label: {
				Image(systemName: "lock.open.fill")
					.font(.system(size: 14))
					.foregroundStyle(.secondary)
					.frame(width: 44, height: 44)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help("Lock vault")
			.accessibilityLabel("Lock LPM Vault")
		}
		.padding(.top, 12)
		.padding(.bottom, 12)
		.frame(width: 70)
	}

	@ViewBuilder
	private func avatarView(url: String?, fallback: String, isSelected: Bool, isOrg: Bool) -> some View {
		let shape = isOrg ? AnyShape(RoundedRectangle(cornerRadius: 10)) : AnyShape(Circle())

		Group {
			if let avatarUrl = url, let imageURL = URL(string: avatarUrl) {
				AsyncImage(url: imageURL) { image in
					image.resizable().scaledToFill()
				} placeholder: {
					textAvatar(fallback, isOrg: isOrg)
				}
			} else {
				textAvatar(fallback, isOrg: isOrg)
			}
		}
		.frame(width: 40, height: 40)
		.clipShape(shape)
		.overlay(
			shape.stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
		)
		.overlay(
			Group {
				#if DEBUG
				if store.appEnvironment == .development && isSelected {
					Text("D")
						.font(.system(size: 7, weight: .bold))
						.foregroundStyle(.white)
						.frame(width: 12, height: 12)
						.background(.orange, in: Circle())
						.offset(x: 14, y: 14)
				}
				#endif
			}
		)
	}

	private func textAvatar(_ text: String, isOrg: Bool = false) -> some View {
		Group {
			if isOrg {
				RoundedRectangle(cornerRadius: 10).fill(.quaternary)
			} else {
				Circle().fill(.quaternary)
			}
		}
		.overlay {
			Text(text)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(.secondary)
		}
	}
}
