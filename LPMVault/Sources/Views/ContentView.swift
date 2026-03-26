import SwiftUI

private let sidebarColor = Color(hex: 0x191919)

struct ContentView: View {
	@Bindable var store: VaultStore
	@State private var showingAddProject = false
	@State private var showingOrgVaults = false
	@State private var updateChecker = UpdateChecker()

	var body: some View {
		Group {
			if store.isUnlocked {
				unlockedContent
			} else {
				lockScreen
			}
		}
	}

	@FocusState private var passwordFieldFocused: Bool

	private var lockScreen: some View {
		VStack(spacing: 16) {
			Image(systemName: "lock.fill")
				.font(.system(size: 48))
				.foregroundStyle(.secondary)

			Text("LPM Vault is Locked")
				.font(.title3)
				.fontWeight(.semibold)

			Text("Click the Touch ID icon or enter your password to unlock.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)

			// Password field with inline Touch ID button (like Passwords app)
			HStack(spacing: 0) {
				SecureField("Enter password", text: .constant(""))
					.textFieldStyle(.plain)
					.focused($passwordFieldFocused)
					.onSubmit {
						// Enter key triggers system auth (password + Touch ID)
						Task { await store.unlock() }
					}

				Button {
					Task { await store.unlock() }
				} label: {
					Image(systemName: "touchid")
						.font(.system(size: 18))
						.foregroundStyle(.pink)
				}
				.buttonStyle(.plain)
				.help("Unlock with Touch ID")
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(.quinary, in: RoundedRectangle(cornerRadius: 7))
			.overlay(
				RoundedRectangle(cornerRadius: 7)
					.stroke(.quaternary, lineWidth: 1)
			)
			.frame(width: 280)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.frame(minWidth: 700, minHeight: 450)
		.onAppear {
			passwordFieldFocused = true
		}
	}

	@State private var sidebarWidth: CGFloat = 240
	@GestureState private var dragOffset: CGFloat = 0

	private var effectiveSidebarWidth: CGFloat {
		min(max(sidebarWidth + dragOffset, 180), 400)
	}

	private var unlockedContent: some View {
		VStack(spacing: 0) {
			// Update banner
			if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
				HStack {
					Image(systemName: "arrow.up.circle.fill")
						.foregroundStyle(.blue)
					Text("Update available: \(updateChecker.currentVersion) → \(latest)")
						.font(.callout)
					Spacer()
					if let url = updateChecker.releaseURL {
						Link("Download", destination: url)
							.font(.callout.bold())
					}
					Button {
						updateChecker.updateAvailable = false
					} label: {
						Image(systemName: "xmark")
							.font(.caption)
					}
					.buttonStyle(.plain)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 8)
				.background(.blue.opacity(0.1))
			}

		HStack(spacing: 0) {
			ProjectListView(store: store, showingAddProject: $showingAddProject, showingOrgVaults: $showingOrgVaults)
				.frame(width: effectiveSidebarWidth)
				.background(sidebarColor)
				.tint(Color(hex: 0x17793A))

			// Draggable resize handle
			Color.clear
				.frame(width: 6)
				.overlay(Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 1))
				.contentShape(Rectangle())
				.gesture(
					DragGesture(minimumDistance: 1, coordinateSpace: .global)
						.updating($dragOffset) { value, state, _ in
							state = value.translation.width
						}
						.onEnded { value in
							sidebarWidth = min(max(sidebarWidth + value.translation.width, 180), 400)
						}
				)
				.onHover { hovering in
					if hovering {
						NSCursor.resizeLeftRight.push()
					} else {
						NSCursor.pop()
					}
				}

			detailView
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.ignoresSafeArea(.container, edges: .top)
		.sheet(isPresented: $showingAddProject) {
			AddProjectSheet(store: store)
		}
		.sheet(isPresented: $showingOrgVaults) {
			OrgVaultsSheet(store: store)
		}
		.frame(minWidth: 700, minHeight: 450)
		.onChange(of: store.selectedSidebarItem) { _, _ in store.resetAutoLock() }
		.onChange(of: store.selectedProjectId) { _, _ in store.resetAutoLock() }
		.onHover { hovering in
			if hovering { store.resetAutoLock() }
		}
		} // end outer VStack
		.task { await updateChecker.checkForUpdate() }
	}

	@ViewBuilder
	private var detailView: some View {
		switch store.selectedSidebarItem {
		case .project:
			if store.selectedProject != nil {
				SecretListView(store: store)
			} else {
				emptyState
			}
		case .personalTokens:
			TokenListView(
				store: store,
				title: "Personal Tokens",
				tokens: store.filteredPersonalTokens,
				orgSlug: nil
			)
		case .orgTokens(let slug):
			TokenListView(
				store: store,
				title: "\(store.userOrgs.first { $0.slug == slug }?.name ?? slug) Tokens",
				tokens: store.filteredOrgTokens[slug] ?? [],
				orgSlug: slug
			)
		case .authStatus:
			AuthStatusView(store: store)
		case nil:
			emptyState
		}
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			Image(systemName: "lock.shield")
				.font(.system(size: 48))
				.foregroundStyle(.secondary)
			Text("No project selected")
				.font(.title2)
				.foregroundStyle(.secondary)
			if store.projects.isEmpty {
				Text(
					"Use `lpm env vars set` to create your first vault,\nor add a project manually."
				)
				.font(.callout)
				.foregroundStyle(.tertiary)
				.multilineTextAlignment(.center)
				Button("Add Project") {
					showingAddProject = true
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
