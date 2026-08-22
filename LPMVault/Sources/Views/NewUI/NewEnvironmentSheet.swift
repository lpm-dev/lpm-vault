import AppKit
import SwiftUI

struct NewEnvironmentSheet: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	@Environment(\.dismiss) private var dismiss

	@State private var name = ""
	@State private var importedSecrets: [String: String] = [:]
	@State private var previewTask: Task<Void, Never>?
	@State private var previewID: UUID?
	@State private var creationTask: Task<Void, Never>?
	@State private var creationID: UUID?
	@FocusState private var nameFocused: Bool

	private var candidate: String { name.trimmingCharacters(in: .whitespaces) }
	private var isValid: Bool {
		EnvValidation.isValidEnvironmentName(candidate) && project.environments[candidate] == nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 5) {
				Text("New environment")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Add another encrypted .env file to \(project.name).")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.padding(20)

			VaultHairline()

			VStack(alignment: .leading, spacing: 14) {
				VStack(alignment: .leading, spacing: 7) {
					Text("ENVIRONMENT NAME").vaultSectionLabel()
					HStack(spacing: 8) {
						VaultEnvSwatch(color: VaultPalette.environment(project.environments.count))
						Text(".env.")
							.font(VaultTypography.mono(12.5))
							.foregroundStyle(VaultPalette.textTertiary)
						TextField("staging", text: $name)
							.textFieldStyle(.plain)
							.font(VaultTypography.mono(12.5))
							.foregroundStyle(VaultPalette.textPrimary)
							.focused($nameFocused)
							.onSubmit(create)
							.disabled(isBusy)
					}
					.padding(.horizontal, 11)
					.frame(height: 34)
					.background(RoundedRectangle(cornerRadius: 8).fill(.white))
					.overlay { RoundedRectangle(cornerRadius: 8).stroke(nameFocused ? VaultPalette.accent : VaultPalette.border, lineWidth: 1) }

					if !candidate.isEmpty, !EnvValidation.isValidEnvironmentName(candidate) {
						Text("Use 1–64 ASCII letters, numbers, dots, dashes, or underscores. Do not use __index__ or '..'.")
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.redText)
					}
					if project.environments[candidate] != nil {
						Text("That environment already exists.")
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.redText)
					}
				}

				Button(action: importFile) {
					HStack(spacing: 8) {
						Image(systemName: previewTask == nil ? "doc.badge.plus" : "hourglass")
						Text(previewTask == nil ? "Import values from an .env file" : "Reading .env file…")
						Spacer()
						if !importedSecrets.isEmpty {
							VaultTagBadge(
								text: "\(importedSecrets.count) KEYS",
								foreground: VaultPalette.greenTintText,
								background: VaultPalette.greenTint
							)
						}
					}
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.padding(.horizontal, 12)
					.frame(height: 38)
					.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.sidebar))
					.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
				}
				.buttonStyle(.plain)
				.disabled(isBusy)
				.accessibilityLabel(importedSecrets.isEmpty ? "Import values from env file" : "\(importedSecrets.count) values imported")
			}
			.padding(20)

			VaultHairline()

			HStack(spacing: 8) {
				Spacer()
				VaultBarButton(title: "Cancel") {
					cancelWork()
					dismiss()
				}
				.keyboardShortcut(.escape, modifiers: [])
				VaultBarButton(
					title: creationTask == nil ? "Create environment" : "Creating…",
					filled: true,
					disabled: !isValid || isBusy,
					action: create
				)
			}
			.padding(16)
		}
		.frame(width: 440)
		.background(VaultPalette.content)
		.onAppear { nameFocused = true }
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { cancelWork(); dismiss() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != project.id { cancelWork(); dismiss() } }
		.onDisappear(perform: cancelWork)
	}

	private var isBusy: Bool { previewTask != nil || creationTask != nil }

	private func create() {
		guard isValid, !isBusy else { return }
		let resolvedName = candidate
		let values = importedSecrets
		let requestID = UUID()
		creationID = requestID
		creationTask = Task {
			let added = await store.addEnvironment(to: project.id, name: resolvedName, secrets: values)
			guard creationID == requestID else { return }
			creationTask = nil
			creationID = nil
			if added, store.isUnlocked, store.selectedProjectId == project.id {
				cancelPreview()
				dismiss()
			}
		}
	}

	private func importFile() {
		guard !isBusy else { return }
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "Select an .env file to import"
		guard runVaultPrivacyAwareModal(panel) == .OK, let url = panel.url else { return }

		if candidate.isEmpty {
			let fileName = url.lastPathComponent
			if fileName == ".env" { name = "default" }
			else if fileName.hasPrefix(".env.") { name = String(fileName.dropFirst(".env.".count)) }
			else { name = fileName }
		}

		let requestID = UUID()
		previewID = requestID
		importedSecrets = [:]
		previewTask = Task {
			let result = await store.loadEnvFilePreview(at: url, for: project.id)
			guard previewID == requestID,
				store.isUnlocked,
				store.selectedProjectId == project.id
			else { return }
			previewTask = nil
			previewID = nil
			switch result {
			case .success(let imported): importedSecrets = imported.secrets
			case .failure(let error) where error != .cancelled: store.error = error.localizedDescription
			case .failure: break
			}
		}
	}

	private func cancelPreview() {
		previewTask?.cancel()
		previewTask = nil
		previewID = nil
	}

	private func cancelWork() {
		creationTask?.cancel()
		creationTask = nil
		creationID = nil
		cancelPreview()
		importedSecrets = [:]
	}
}
