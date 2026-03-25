import SwiftUI

struct AddProjectSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var path = ""
	@FocusState private var focusedField: Field?

	private enum Field {
		case name
	}

	private var canCreate: Bool {
		!name.isEmpty && !path.isEmpty
	}

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Add Project")
					.font(.headline)
				Spacer()
				Button {
					dismiss()
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.keyboardShortcut(.escape, modifiers: [])
			}
			.padding()

			Divider()

			// Form
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 6) {
					Text("Project Name")
						.font(.subheadline)
						.fontWeight(.medium)
					TextField("e.g. my-api-server", text: $name)
						.textFieldStyle(.roundedBorder)
						.focused($focusedField, equals: .name)
				}

				VStack(alignment: .leading, spacing: 6) {
					Text("Project Path")
						.font(.subheadline)
						.fontWeight(.medium)
					HStack {
						TextField("Select a folder...", text: $path)
							.textFieldStyle(.roundedBorder)
							.disabled(true)
						Button("Browse...") {
							selectFolder()
						}
					}
				}
			}
			.padding()

			Divider()

			// Actions
			HStack {
				Spacer()
				Button("Cancel") {
					dismiss()
				}

				Button("Create") {
					store.addProject(name: name, path: path)
					dismiss()
				}
				.buttonStyle(.borderedProminent)
				.disabled(!canCreate)
				.keyboardShortcut(.return, modifiers: .command)
			}
			.padding()
		}
		.frame(width: 420)
		.onAppear {
			focusedField = .name
		}
	}

	private func selectFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.message = "Select the project directory"

		if panel.runModal() == .OK, let url = panel.url {
			path = url.path(percentEncoded: false)
			if name.isEmpty {
				name = url.lastPathComponent
			}
		}
	}
}
