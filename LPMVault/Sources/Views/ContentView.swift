import SwiftUI

struct ContentView: View {
	@Bindable var store: VaultStore
	@State private var showingAddProject = false

	var body: some View {
		NavigationSplitView {
			ProjectListView(store: store, showingAddProject: $showingAddProject)
				.navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
		} detail: {
			if store.selectedProject != nil {
				SecretListView(store: store)
			} else {
				emptyState
			}
		}
		.searchable(text: $store.searchQuery, prompt: "Search secrets...")
		.sheet(isPresented: $showingAddProject) {
			AddProjectSheet(store: store)
		}
		.toolbar {
			ToolbarItem(placement: .automatic) {
				Button {
					if store.isUnlocked {
						store.lock()
					} else {
						Task { await store.unlock() }
					}
				} label: {
					Image(systemName: store.isUnlocked ? "lock.open" : "lock")
				}
				.help(store.isUnlocked ? "Lock vault" : "Unlock vault")
				.keyboardShortcut("l", modifiers: .command)
			}
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
				Text("Use `lpm env vars set` to create your first vault,\nor add a project manually.")
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
