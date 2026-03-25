import SwiftUI

struct AuthStatusView: View {
	@Bindable var store: VaultStore

	var body: some View {
		VStack(spacing: 0) {
			if let user = store.currentUser {
				List {
					Section("Account") {
						HStack(spacing: 12) {
							// Avatar placeholder
							Circle()
								.fill(.quaternary)
								.frame(width: 48, height: 48)
								.overlay {
									Text(String(user.username.prefix(1)).uppercased())
										.font(.title2)
										.fontWeight(.medium)
										.foregroundStyle(.secondary)
								}

							VStack(alignment: .leading, spacing: 2) {
								Text("@\(user.username)")
									.font(.title3)
									.fontWeight(.semibold)
								if let name = user.name, !name.isEmpty {
									Text(name)
										.foregroundStyle(.secondary)
								}
								if let email = user.email {
									Text(email)
										.font(.caption)
										.foregroundStyle(.tertiary)
								}
							}
						}
						.padding(.vertical, 4)
					}

					if let plan = store.currentUser?.plan {
						Section("Plan") {
							Label(plan.capitalized, systemImage: "creditcard")
						}
					}

					Section("Token Summary") {
						LabeledContent("Personal tokens") {
							Text("\(store.personalTokens.count)")
						}
						LabeledContent("Organizations") {
							Text("\(store.userOrgs.count)")
						}

						if !store.expiringTokens.isEmpty {
							Label(
								"\(store.expiringTokens.count) token\(store.expiringTokens.count == 1 ? "" : "s") expiring soon",
								systemImage: "exclamationmark.triangle.fill"
							)
							.foregroundStyle(.orange)
						}
					}

					Section {
						Link(destination: URL(string: "https://lpm.dev/dashboard/settings")!) {
							Label("Manage account on lpm.dev", systemImage: "arrow.up.right.square")
						}
					}
				}
			} else {
				VStack(spacing: 12) {
					Image(systemName: "person.crop.circle.badge.questionmark")
						.font(.system(size: 48))
						.foregroundStyle(.secondary)
					Text("Not logged in")
						.font(.title2)
						.foregroundStyle(.secondary)
					Text("Run `lpm login` in your terminal to authenticate")
						.font(.callout)
						.foregroundStyle(.tertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.navigationTitle("Auth Status")
	}
}
