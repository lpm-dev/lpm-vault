import SwiftUI

struct AddProjectSheet: View {
	@Bindable var store: VaultStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var path = ""
	@State private var detectedEnvFiles: [EnvFileInfo] = []
	@FocusState private var focusedField: Field?

	private enum Field {
		case name
	}

	struct EnvFileInfo: Identifiable {
		let id = UUID()
		let fileName: String
		let fullPath: String
		var selected: Bool = true
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

				// Detected .env files
				if !detectedEnvFiles.isEmpty {
					VStack(alignment: .leading, spacing: 8) {
						Text("Environment Files Found")
							.font(.subheadline)
							.fontWeight(.medium)

						ForEach($detectedEnvFiles) { $file in
							HStack {
								Image(systemName: file.selected ? "checkmark.circle.fill" : "circle")
									.foregroundStyle(file.selected ? .green : .secondary)
									.onTapGesture { file.selected.toggle() }
								Text(file.fileName)
									.font(.system(.body, design: .monospaced))
								Spacer()
								Text("Import")
									.font(.caption)
									.foregroundStyle(file.selected ? .primary : .tertiary)
							}
						}

						Text("Selected files will be imported into the vault")
							.font(.caption)
							.foregroundStyle(.tertiary)
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

				Button(detectedEnvFiles.contains(where: { $0.selected }) ? "Create & Import" : "Create") {
					createProject()
				}
				.buttonStyle(.borderedProminent)
				.disabled(!canCreate)
				.keyboardShortcut(.return, modifiers: .command)
			}
			.padding()
		}
		.frame(width: 460)
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
			detectEnvFiles(at: url)
		}
	}

	private func detectEnvFiles(at url: URL) {
		let fm = FileManager.default
		guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }

		detectedEnvFiles = contents
			.filter { $0.hasPrefix(".env") && !$0.hasSuffix(".example") }
			.sorted()
			.map { fileName in
				EnvFileInfo(
					fileName: fileName,
					fullPath: url.appendingPathComponent(fileName).path
				)
			}
	}

	/// Extract environment name from filename: ".env.local" → "local", ".env" → "default"
	private func envNameFromFileName(_ fileName: String) -> String {
		if fileName == ".env" { return "default" }
		let prefix = ".env."
		if fileName.hasPrefix(prefix) {
			return String(fileName.dropFirst(prefix.count))
		}
		return "default"
	}

	private func createProject() {
		// Build environments from selected .env files
		let selectedFiles = detectedEnvFiles.filter { $0.selected }
		var environments: [String: [String: String]] = [:]

		if !selectedFiles.isEmpty {
			for file in selectedFiles {
				if let content = try? String(contentsOfFile: file.fullPath, encoding: .utf8) {
					let pairs = parseEnvContent(content)
					let envName = envNameFromFileName(file.fileName)
					var envSecrets: [String: String] = [:]
					for (key, value) in pairs {
						envSecrets[key] = value
					}
					environments[envName] = envSecrets
				}
			}
		}

		if environments.isEmpty {
			environments["default"] = [:]
		}

		store.addProject(name: name, path: path, environments: environments)

		// Select the first environment tab
		if let firstEnv = environments.keys.sorted().first {
			store.selectedEnvironment = firstEnv
		}

		dismiss()
	}

	/// Simple .env parser (matches the Rust CLI parser behavior)
	private func parseEnvContent(_ content: String) -> [(String, String)] {
		var result: [(String, String)] = []
		for line in content.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

			let line = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
			guard let eqIndex = line.firstIndex(of: "=") else { continue }

			let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
			var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

			// Remove surrounding quotes
			if (value.hasPrefix("\"") && value.hasSuffix("\""))
				|| (value.hasPrefix("'") && value.hasSuffix("'"))
			{
				value = String(value.dropFirst().dropLast())
			}

			if !key.isEmpty {
				result.append((key, value))
			}
		}
		return result
	}
}
