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
	@State private var listHeight: CGFloat = 0

	private static let maximumListHeight: CGFloat = 320

	/// The rules references are found in.
	private enum Rules {
		/// lpm.json's, or the draft's as evaluated now, which imports' references need.
		case ready(ProjectEnvSchemaOverview?)
		case checking
		/// The engine rejects the draft, so imported schemas' references can't be found.
		case rejected

		var isReady: Bool { if case .ready = self { true } else { false } }
	}

	private var rules: Rules {
		guard store.schemaDraft(for: project.id) != nil else { return .ready(store.keyDescriptions[project.id]?.schema?.overview) }
		guard let evaluation = store.currentSchemaDraftEvaluation(for: project.id) else { return .checking }
		return evaluation.overview.map(Rules.ready) ?? .rejected
	}

	var body: some View {
		let rules = rules
		let references: [ProjectEnvSchemaReference] = if case .ready(let overview) = rules {
			ProjectEnvSchemaReference.references(to: key, in: store.schemaDraftOrBase(for: project.id), rules: overview)
		} else {
			[]
		}
		let settled = references.compactMap { reference in chosen[reference.id].flatMap { reference.fixes.contains($0) ? (reference: reference, fix: $0) : nil } }
		let left = references.count - settled.count
		let stored = project.environments.values.filter { $0[key] != nil }.count
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 6) {
				(Text("Remove ") + Text(key.escapingDirectionControls).font(VaultTypography.mono(16, .bold)) + Text(" from the schema?"))
					.font(.system(size: 16, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.fixedSize(horizontal: false, vertical: true)
				Text(Self.consequence(stored: stored))
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(20)

			switch rules {
			case .checking:
				VaultHairline()
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Checking the rules…").font(.system(size: 12)).foregroundStyle(VaultPalette.textTertiary)
				}
				.padding(20)
			case .rejected:
				VaultHairline()
				Text("Your draft has a problem the LPM CLI would reject, so what refers to \(key.escapingDirectionControls) in imported schemas can't be found yet. Fix the problem first.")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
					.padding(20)
			case .ready:
				if !references.isEmpty {
					VaultHairline()
					referenceList(references, left: left)
				}
			}

			VaultSheetFooter {
				Text(footerText(references: references.count, left: left))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Cancel", height: 28) { dismiss() }
					.keyboardShortcut(.cancelAction)
				VaultBarButton(title: "Add to draft", filled: true, disabled: !rules.isReady || left > 0 || !store.canEditSchema(of: project.id), height: 28) {
					store.removeSchemaKey(key, settling: settled, in: project.id)
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.frame(width: 520)
		.background(VaultPalette.content)
	}

	private func footerText(references: Int, left: Int) -> String {
		guard rules.isReady else { return "" }
		if left == 0 { return references == 0 ? "Nothing else refers to it." : "Every reference is settled." }
		return left == 1 ? "1 reference left" : "\(left) references left"
	}

	private func referenceList(_ references: [ProjectEnvSchemaReference], left: Int) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Text("REFERENCED BY · \(references.count)").vaultSectionLabel()
				Text("resolve these first — fixes join the same draft")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
				Spacer(minLength: 8)
				if left > 1 {
					Button("Settle all") {
						for reference in references where chosen[reference.id].map(reference.fixes.contains) != true {
							chosen[reference.id] = reference.fixes.first
						}
					}
					.buttonStyle(.plain)
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(VaultPalette.accentForeground)
					.help("Choose each reference's first fix")
					.vaultPointingHand()
				}
			}
			// Only the rows on screen are built, so a key many rules name stays quick.
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(Array(references.enumerated()), id: \.element.id) { index, reference in
						referenceRow(reference)
							.overlay(alignment: .top) { if index > 0 { VaultHairline() } }
					}
				}
				.background {
					GeometryReader { proxy in Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height) }
				}
			}
			.frame(height: min(max(listHeight, 1), Self.maximumListHeight))
			.onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
		}
		.padding(20)
	}

	/// What removing does to the values stored under the key.
	nonisolated static func consequence(stored: Int) -> String {
		let values = switch stored {
		case 0: "No environment stores a value for it."
		case 1: "Its value stays in the Keychain, and the LPM CLI stops checking it."
		default: "Its values stay in the Keychain in \(stored) environments, and the LPM CLI stops checking them."
		}
		return "Adds the removal to your draft. \(values)"
	}

	private func referenceRow(_ reference: ProjectEnvSchemaReference) -> some View {
		let fix = chosen[reference.id].flatMap { reference.fixes.contains($0) ? $0 : nil }
		return HStack(alignment: .center, spacing: 10) {
			Image(systemName: reference.kind.isGroup ? "square.stack.3d.up" : "link")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
				.frame(width: 14)
				.accessibilityHidden(true)
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
				if let fix, let note = reference.note(for: fix) {
					Text(note)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.orangeTintText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 8)
			if let fix {
				HStack(spacing: 6) {
					Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
					Text(reference.done(by: fix)).font(.system(size: 11))
				}
				.foregroundStyle(VaultPalette.greenTintText)
				.fixedSize()
				Button("Undo") { chosen[reference.id] = nil }
					.buttonStyle(.plain)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.accessibilityLabel("Undo \(reference.done(by: fix).lowercased())")
			} else {
				ForEach(reference.fixes, id: \.self) { fix in
					VaultBarButton(title: reference.title(of: fix), height: 24) { chosen[reference.id] = fix }
						.fixedSize()
						.help(reference.note(for: fix) ?? "")
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.accessibilityElement(children: .contain)
	}
}

private struct ListHeightKey: PreferenceKey {
	static let defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Where a key or a group that can't be removed in lpm.json is declared.
struct VaultSchemaElsewhere: Hashable, Identifiable {
	/// The file that declares it, as shown.
	let source: String
	/// That file's path in the project folder when it can be edited there:
	/// not a preset, and not an installed package's.
	let path: String?
	/// lpm.json overrides it.
	let isOverridden: Bool
	/// Another imported file that overrides it, as shown.
	var overriddenBy: String?
	var isGroup = false
	/// Why lpm.json's override can't be reset here; nil when it can.
	var resetBlocker: String?

	var id: Self { self }

	/// `path` when it can be edited in the project folder.
	static func editable(_ path: String?) -> String? {
		guard let path, !path.hasPrefix("preset:"),
			// Folded the way the file system compares names, so no spelling of the folder slips through.
			!path.split(separator: "/").contains(where: { $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) == "node_modules" })
		else { return nil }
		return path
	}
}

/// Explains why a key or a group declared in an imported schema or a preset
/// can't be removed in lpm.json, with what can be done instead.
struct VaultSchemaElsewhereSheet: View {
	/// The key or group's name.
	let name: String
	let elsewhere: VaultSchemaElsewhere
	/// The project folder, which the file to open has to be in.
	let folder: String?
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
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 5) {
					(Text(name.escapingDirectionControls).font(VaultTypography.mono(14, .bold)) + Text(" can't be removed here").font(.system(size: 14, weight: .bold)))
						.foregroundStyle(VaultPalette.textPrimary)
						.fixedSize(horizontal: false, vertical: true)
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
					VaultBarButton(systemImage: "doc", title: "Open file", height: 28) {
						ProjectConfigOpener.open(file.url, within: file.folder)
						dismiss()
					}
					.help(elsewhere.source)
				}
				if elsewhere.resetBlocker == nil {
					VaultBarButton(title: elsewhere.isOverridden ? "Reset to original" : (elsewhere.isGroup ? "Override group" : "Override rules"), filled: true,
						height: 28) {
						onOverride()
						dismiss()
					}
					.keyboardShortcut(.defaultAction)
				}
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 16)
		}
		.frame(width: 440)
		.background(VaultPalette.content)
	}

	/// The file to open, built only when there's one.
	private var file: (url: URL, folder: URL)? {
		guard let path = elsewhere.path, let folder, !folder.isEmpty else { return nil }
		let root = URL(filePath: folder, directoryHint: .isDirectory)
		return (root.appending(path: path, directoryHint: .notDirectory), root)
	}

	private var explanation: String { Self.explanation(for: elsewhere, editable: file != nil) }

	/// Why the key can't be removed in lpm.json, and what can be done, given
	/// whether the file that declares it can be opened from the project.
	nonisolated static func explanation(for elsewhere: VaultSchemaElsewhere, editable: Bool) -> String {
		let source = elsewhere.source
		// A key's override replaces its rules; a group's replaces the group.
		let what = elsewhere.isGroup ? "it" : "its rules"
		if elsewhere.isOverridden {
			if let blocker = elsewhere.resetBlocker {
				return editable
					? "It's declared in \(source), which lpm.json imports, and lpm.json overrides \(what). To remove it, delete it in \(source). \(blocker)"
					: "It's declared in \(source), which can't be edited here, and lpm.json overrides \(what). \(blocker)"
			}
			let original = elsewhere.isGroup ? "the original group" : "the original rules"
			return editable
				? "It's declared in \(source), which lpm.json imports, and lpm.json overrides \(what). To remove it, delete it in \(source) and reset the override here: lpm.json can't override \(elsewhere.isGroup ? "a group" : "a key") its imports don't declare."
				: "It's declared in \(source), which can't be edited here, and lpm.json overrides \(what). Reset the override to bring back \(original)."
		}
		if let overriddenBy = elsewhere.overriddenBy {
			return editable
				? "It's declared in \(source), and \(overriddenBy) overrides \(what). Remove it from both, or override \(what) in lpm.json."
				: "It's declared in \(source), which can't be edited here, and \(overriddenBy) overrides \(what). Override \(what) in lpm.json instead."
		}
		return editable
			? "It's declared in \(source), which lpm.json imports. Remove it there, or override \(what) in lpm.json."
			: "It's declared in \(source), which can't be edited here. Override \(what) in lpm.json instead."
	}
}

private extension ProjectEnvSchemaReference.Kind {
	var isGroup: Bool { if case .group = self { true } else { false } }
}
