import SwiftUI

struct ContentView: View {
	@Bindable var store: VaultStore
	@State private var showingAddProject = false

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

	private var unlockedContent: some View {
		NavigationSplitView {
			ProjectListView(store: store, showingAddProject: $showingAddProject)
				.navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
		} detail: {
			detailView
		}
		.sheet(isPresented: $showingAddProject) {
			AddProjectSheet(store: store)
		}
		.frame(minWidth: 700, minHeight: 450)
		.onChange(of: store.selectedSidebarItem) { _, _ in store.resetAutoLock() }
		.onChange(of: store.selectedProjectId) { _, _ in store.resetAutoLock() }
		.onHover { hovering in
			if hovering { store.resetAutoLock() }
		}
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
		VStack(spacing: 0) {
			// Lock button header (consistent with other views)
			HStack {
				Spacer()
				ToolbarButtonGroup {
					ToolbarIconButton(icon: "lock.open.fill", help: "Lock vault") {
						store.lock()
					}
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)

			Spacer()
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
			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
