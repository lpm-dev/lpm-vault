import AppKit
import SwiftUI

struct NewEnvironmentSheet: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	@Environment(\.dismiss) private var dismiss
	@State private var nameDraft = VaultEnvironmentNameDraft()
	@State private var source = EnvImportSourceState()
	@State private var creationTask: Task<Void, Never>?
	@State private var creationID: UUID?

	private var name: String { nameDraft.name }
	private var existing: Set<String> { Set(project.environments.keys) }
	private var isValid: Bool { VaultEnvironmentNameField.isValid(name, existing: existing) }
	/// The values the environment starts with: none, or what the file or text
	/// holds once it's read without a problem.
	private var values: [String: String]? { source.isEmpty ? [:] : source.imported?.secrets }

	/// What quitting would discard: the environment's name, or the variables chosen for it.
	private var unsavedWork: String? {
		let name = name.trimmingCharacters(in: .whitespaces)
		if !name.isEmpty { return name }
		return source.source.map { $0 == .pastedText ? "Pasted variables" : "Variables from \($0.name)" }
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
			VStack(alignment: .leading, spacing: 18) {
				VStack(alignment: .leading, spacing: 7) {
					Text("ENVIRONMENT NAME").vaultSectionLabel()
					VaultEnvironmentNameField(
						name: $nameDraft.name, existing: existing, swatch: VaultPalette.environment(project.environments.count),
						focusesOnAppear: true, disabled: creationTask != nil, onSubmit: create)
				}
				VStack(alignment: .leading, spacing: 7) {
					HStack(spacing: 8) {
						Text("VALUES").vaultSectionLabel()
						Spacer()
						Text("optional")
							.font(.system(size: 11))
							.foregroundStyle(VaultPalette.textFaint)
					}
					EnvImportSourcePicker(store: store, projectID: project.id, state: $source, disabled: creationTask != nil)
				}
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
					disabled: !isValid || values == nil || creationTask != nil,
					action: create
				)
			}
			.padding(16)
		}
		.frame(width: 520)
		.background(VaultPalette.content)
		.vaultUnsavedSheetWork(store, projectID: project.id, projectName: project.name, title: "New environment", detail: unsavedWork)
		.onChange(of: source.source) { _, source in nameDraft.follow(source) }
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { cancelWork(); dismiss() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != project.id { cancelWork(); dismiss() } }
		.onDisappear(perform: cancelWork)
	}

	private func create() {
		guard isValid, creationTask == nil, let values else { return }
		let resolvedName = name.trimmingCharacters(in: .whitespaces)
		let requestID = UUID()
		creationID = requestID
		creationTask = Task {
			let added = await store.addEnvironment(to: project.id, name: resolvedName, secrets: values)
			guard creationID == requestID else { return }
			creationTask = nil
			creationID = nil
			if added, store.isUnlocked, store.selectedProjectId == project.id {
				dismiss()
			}
		}
	}

	private func cancelWork() {
		creationTask?.cancel()
		creationTask = nil
		creationID = nil
		source = EnvImportSourceState()
	}
}

/// A new environment's name, after the `.env.` its file starts with, and
/// what's wrong with it, said under it.
struct VaultEnvironmentNameField: View {
	@Binding var name: String
	let existing: Set<String>
	let swatch: Color
	var focusesOnAppear = false
	var disabled = false
	var onSubmit: () -> Void = {}

	@FocusState private var focused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				VaultEnvSwatch(color: swatch)
				Text(".env.")
					.font(VaultTypography.tabular(12.5))
					.foregroundStyle(VaultPalette.textTertiary)
				TextField("staging", text: $name)
					.textFieldStyle(.plain)
					.font(VaultTypography.tabular(12.5))
					.foregroundStyle(VaultPalette.textPrimary)
					.autocorrectionDisabled()
					.focused($focused)
					.onSubmit(onSubmit)
					.disabled(disabled)
					.accessibilityLabel("Environment name")
			}
			.padding(.horizontal, 11)
			.frame(height: 34)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(focused ? VaultPalette.accent : VaultPalette.border, lineWidth: 1) }
			if let problem = Self.problem(with: name, existing: existing) {
				Text(problem)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.onAppear { if focusesOnAppear { focused = true } }
	}

	static func isValid(_ name: String, existing: Set<String>) -> Bool {
		let candidate = name.trimmingCharacters(in: .whitespaces)
		return EnvValidation.isValidEnvironmentName(candidate) && !existing.contains(candidate)
	}

	/// Nothing until there's a name to check.
	static func problem(with name: String, existing: Set<String>) -> String? {
		let candidate = name.trimmingCharacters(in: .whitespaces)
		guard !candidate.isEmpty else { return nil }
		guard EnvValidation.isValidEnvironmentName(candidate) else {
			return "Use 1–64 ASCII letters, numbers, dots, dashes, or underscores. Do not use __index__ or '..'."
		}
		return existing.contains(candidate) ? "That environment already exists." : nil
	}
}

/// A new environment's name, which follows the file its values come from
/// until a name is typed.
struct VaultEnvironmentNameDraft: Equatable {
	var name = ""
	/// What the source suggested last; `name` still holds it unless one was typed.
	private var suggestion: String?

	/// Takes the name `source` suggests, a file's or none for pasted text, in
	/// place of the one suggested before. A typed name stays.
	mutating func follow(_ source: EnvImportSource?) {
		let next: String? = if case .file(let url) = source { Self.suggestedName(forFile: url) } else { nil }
		if name.trimmingCharacters(in: .whitespaces).isEmpty || name == suggestion { name = next ?? "" }
		suggestion = next
	}

	/// The environment a file's name suggests: `.env` is the default one, and
	/// `.env.staging` is staging.
	private static func suggestedName(forFile url: URL) -> String {
		let fileName = url.lastPathComponent
		if fileName == ".env" { return "default" }
		if fileName.hasPrefix(".env.") { return String(fileName.dropFirst(".env.".count)) }
		return fileName
	}
}
