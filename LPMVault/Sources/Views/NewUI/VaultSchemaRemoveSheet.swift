import SwiftUI

/// Confirms removing a key from lpm.json, with a fix for each rule that names
/// it. The removal and its fixes join the draft as one change once every
/// reference is settled; nothing changes before.
struct VaultSchemaRemoveSheet: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let key: String
	@Environment(\.dismiss) private var dismiss

	@State private var chosen: [ProjectEnvSchemaDraft.Item: ProjectEnvSchemaReference.Fix] = [:]

	private var references: [ProjectEnvSchemaReference] {
		let rules = store.latestSchemaDraftEvaluation(for: project.id)?.overview ?? store.keyDescriptions[project.id]?.schema?.overview
		return ProjectEnvSchemaReference.references(to: key, in: store.schemaDraftOrBase(for: project.id), rules: rules)
	}

	var body: some View {
		let references = references
		let left = references.filter { chosen[$0.id] == nil }.count
		let stored = project.environments.values.filter { $0[key] != nil }.count
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 6) {
				(Text("Remove ") + Text(key).font(VaultTypography.mono(16, .bold)) + Text(" from the schema?"))
					.font(.system(size: 16, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text(Self.consequence(stored: stored))
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(20)

			if !references.isEmpty {
				VaultHairline()
				VStack(alignment: .leading, spacing: 8) {
					HStack(spacing: 8) {
						Text("REFERENCED BY · \(references.count)").vaultSectionLabel()
						Text("resolve these first — fixes join the same draft")
							.font(.system(size: 11))
							.foregroundStyle(VaultPalette.textTertiary)
					}
					VStack(spacing: 0) {
						ForEach(Array(references.enumerated()), id: \.element.id) { index, reference in
							referenceRow(reference)
								.overlay(alignment: .top) { if index > 0 { VaultHairline() } }
						}
					}
					.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
				}
				.padding(20)
			}

			VaultSheetFooter {
				Text(left == 0 ? (references.isEmpty ? "Nothing else refers to it." : "Every reference is settled.") : (left == 1 ? "1 reference left" : "\(left) references left"))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Cancel", height: 28) { dismiss() }
					.keyboardShortcut(.cancelAction)
				VaultBarButton(title: "Add to draft", filled: true, disabled: left > 0 || !store.canEditSchema(of: project.id), height: 28) {
					let fixes = references.compactMap { reference in chosen[reference.id].map { (item: reference.item, declaration: reference.fixed(by: $0)) } }
					store.removeSchemaKey(key, fixes: fixes, in: project.id)
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.frame(width: 520)
		.background(VaultPalette.content)
	}

	/// What removing does to the values stored under the key.
	static func consequence(stored: Int) -> String {
		let values = switch stored {
		case 0: "No environment stores a value for it."
		case 1: "Its stored value stays in the Keychain — the LPM CLI just stops checking it."
		default: "Stored values stay in the Keychain in all \(stored) envs — the LPM CLI just stops checking them."
		}
		return "Adds the removal to your draft. \(values)"
	}

	private func referenceRow(_ reference: ProjectEnvSchemaReference) -> some View {
		HStack(alignment: .center, spacing: 10) {
			Image(systemName: reference.kind.isGroup ? "square.stack.3d.up" : "link")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
				.frame(width: 14)
			VStack(alignment: .leading, spacing: 2) {
				Text(reference.title)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.tail)
					.help(reference.title)
				Text(reference.location)
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(VaultPalette.textFaint)
					.lineLimit(1)
					.truncationMode(.middle)
				if let unfixable = reference.unfixable {
					Text(unfixable)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.redText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 8)
			if let fix = chosen[reference.id] {
				HStack(spacing: 6) {
					Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
					Text(fix.done).font(.system(size: 11))
				}
				.foregroundStyle(VaultPalette.greenTintText)
				Button("Undo") { chosen[reference.id] = nil }
					.buttonStyle(.plain)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.accessibilityLabel("Undo \(fix.done.lowercased())")
			} else {
				ForEach(reference.fixes, id: \.self) { fix in
					VaultBarButton(title: fix.title, height: 24) { chosen[reference.id] = fix }
						.fixedSize()
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.accessibilityElement(children: .contain)
	}
}

/// Explains why a key declared in an imported schema or a preset can't be
/// removed in lpm.json, with what can be done instead.
struct VaultSchemaElsewhereSheet: View {
	let key: String
	/// The file that declares it, as shown.
	let source: String
	/// The file to open, inside the project folder; nil when it can't be edited there.
	let file: URL?
	/// lpm.json overrides it.
	let isOverridden: Bool
	let onOverride: () -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "lock")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
					.frame(width: 28, height: 28)
					.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.neutralTint))
				VStack(alignment: .leading, spacing: 5) {
					(Text(key).font(VaultTypography.mono(14, .bold)) + Text(" can't be removed here").font(.system(size: 14, weight: .bold)))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(explanation)
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(20)
			HStack(spacing: 8) {
				Spacer()
				VaultBarButton(title: "Cancel", height: 28) { dismiss() }
					.keyboardShortcut(.cancelAction)
				if let file {
					VaultBarButton(systemImage: "doc", title: "Open \(file.lastPathComponent.escapingDirectionControls)", height: 28) {
						ProjectConfigOpener.open(file)
						dismiss()
					}
				}
				VaultBarButton(title: isOverridden ? "Reset to original" : "Override rules", filled: true, height: 28) {
					onOverride()
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 16)
		}
		.frame(width: 440)
		.background(VaultPalette.content)
	}

	private var explanation: String {
		let place = file == nil ? "\(source), which can't be edited here" : "\(source), which lpm.json imports"
		if isOverridden {
			return "It's declared in \(place); lpm.json only overrides its rules. Remove it there, or reset the override to bring back the original rules."
		}
		return file == nil
			? "It's declared in \(place). Override its rules in lpm.json instead."
			: "It's declared in \(place). Remove it there, or override its rules in lpm.json."
	}
}

private extension ProjectEnvSchemaReference.Kind {
	var isGroup: Bool { if case .group = self { true } else { false } }
}
