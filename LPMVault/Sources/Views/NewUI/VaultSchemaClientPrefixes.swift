import SwiftUI

/// The Schema page's client prefixes: the frameworks', the ones imported
/// schemas declare, and lpm.json's own, which can be added and removed. A
/// change marks the keys it makes public or private in the same draft edit.
struct VaultSchemaClientPrefixesPopover: View {
	private typealias Prefixes = ProjectEnvSchemaClientPrefixes

	@Bindable var store: VaultStore
	let project: VaultProject
	/// Opens a key in the side panel, such as the Secret key that blocks a prefix.
	let onOpenKey: (String) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var entry = ""
	@State private var showsFrameworks = false
	/// lpm.json's prefix whose removal waits for confirmation, because keys rely on it.
	@State private var removing: String?
	@FocusState private var entryFocused: Bool

	/// Keys a list shows before "and N more".
	private static let shownKeys = 12

	private var canEdit: Bool { store.canEditSchema(of: project.id) }

	var body: some View {
		let draft = store.schemaDraftOrBase(for: project.id)
		let rules = store.schemaOverview(for: project.id)
		let own = Prefixes.own(in: draft)
		let importedSet = Prefixes.imported(store.keyDescriptions[project.id]?.importedClientPrefixes, draft: draft, rules: rules)
		let imported = VaultKeySortOrder.sortedAscending(importedSet.subtracting(own))
		let count = importedSet.union(own).count
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Client prefixes").font(.system(size: 13, weight: .semibold)).foregroundStyle(VaultPalette.textPrimary)
				(Text("Keys starting with these are public. ") + Text("lpm.json › envSchema.clientPrefixes").font(VaultTypography.mono(11)))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(.horizontal, 14)
			.padding(.top, 14)
			.padding(.bottom, 10)

			frameworks
			ForEach(imported, id: \.self) { prefix in
				row(prefix, keys: Prefixes.keyCount(of: prefix, rules: rules), imported: true)
			}
			ForEach(own, id: \.self) { prefix in
				if removing == prefix {
					removalConfirmation(prefix, keys: Prefixes.keys(removing: prefix, imported: importedSet, draft: draft, rules: rules),
						imported: importedSet)
				} else {
					row(prefix, keys: Prefixes.keyCount(of: prefix, rules: rules), imported: false, alsoImported: importedSet.contains(prefix)) {
						let keys = Prefixes.keys(removing: prefix, imported: importedSet, draft: draft, rules: rules)
						if keys.isEmpty { apply(Prefixes.removing(prefix, imported: importedSet, draft: draft, rules: rules)) } else { removing = prefix }
					}
				}
			}
			if canEdit {
				addField(draft: draft, rules: rules)
			}
			VaultHairline()
			HStack {
				Text("\(count) of \(Prefixes.maximum)")
				Spacer(minLength: 8)
				Text("Changes join the draft")
			}
			.font(.system(size: 11))
			.foregroundStyle(VaultPalette.textTertiary)
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
		}
		.frame(width: 340)
		.background(VaultPalette.content)
	}

	// MARK: - Rows

	private var frameworks: some View {
		VStack(alignment: .leading, spacing: 4) {
			Button {
				showsFrameworks.toggle()
			} label: {
				HStack(spacing: 6) {
					Image(systemName: showsFrameworks ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
					Text("Framework prefixes — always public").font(.system(size: 11.5))
					Spacer(minLength: 8)
					Text("\(ProjectEnvSchemaRule.frameworkPrefixes.count)").font(.system(size: 11))
				}
				.foregroundStyle(VaultPalette.textTertiary)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel(showsFrameworks ? "Hide framework prefixes" : "Show framework prefixes")
			if showsFrameworks {
				VaultFlowLayout(spacing: 5, lineSpacing: 5) {
					ForEach(ProjectEnvSchemaRule.frameworkPrefixes, id: \.self) { prefix in
						Text(prefix)
							.font(VaultTypography.mono(11))
							.foregroundStyle(VaultPalette.textSecondary)
							.padding(.horizontal, 6)
							.frame(height: 20)
							.overlay { RoundedRectangle(cornerRadius: 4).stroke(VaultPalette.border, lineWidth: 1) }
					}
				}
				.padding(.leading, 15)
			}
		}
		.padding(.horizontal, 14)
		.padding(.bottom, 8)
	}

	private func row(_ prefix: String, keys: Int, imported: Bool, alsoImported: Bool = false, onRemove: (() -> Void)? = nil) -> some View {
		HStack(spacing: 7) {
			Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(VaultPalette.publicText).accessibilityHidden(true)
			Text(prefix.escapingDirectionControls)
				.font(VaultTypography.mono(12, .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 8)
			if imported || alsoImported {
				Text(alsoImported ? "also imported" : "imported")
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.padding(.horizontal, 5)
					.overlay { RoundedRectangle(cornerRadius: 4).stroke(VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
					.help(alsoImported
						? "A schema lpm.json imports declares it too, so it stays in effect without lpm.json's"
						: "Declared in a schema lpm.json imports, so it can't be removed here")
			}
			Text(keys == 1 ? "1 key" : "\(keys) keys").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			if imported {
				Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(VaultPalette.textFaint).accessibilityHidden(true)
			} else if let onRemove {
				Button(action: onRemove) {
					Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(VaultPalette.textFaint)
				}
				.buttonStyle(.plain)
				.disabled(!canEdit)
				.accessibilityLabel("Remove \(prefix)")
			}
		}
		.padding(.horizontal, 14)
		.frame(height: 30)
	}

	private func removalConfirmation(_ prefix: String, keys: [String], imported: Set<String>) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 7) {
				Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(VaultPalette.publicText).accessibilityHidden(true)
				Text(prefix.escapingDirectionControls).font(VaultTypography.mono(12, .semibold)).foregroundStyle(VaultPalette.textPrimary)
				Spacer(minLength: 8)
			}
			HStack(alignment: .top, spacing: 6) {
				Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).padding(.top, 1)
				Text(keys.count == 1
					? "1 public key uses it — it'll become private in the same change."
					: "\(keys.count) public keys use it — they'll become private in the same change.")
					.font(.system(size: 11.5))
					.fixedSize(horizontal: false, vertical: true)
			}
			.foregroundStyle(VaultPalette.orangeTintText)
			keyChips(keys)
			HStack(spacing: 6) {
				VaultBarButton(title: "Remove", filled: true, disabled: !canEdit, height: 24) {
					let draft = store.schemaDraftOrBase(for: project.id)
					apply(Prefixes.removing(prefix, imported: imported, draft: draft, rules: store.schemaOverview(for: project.id)))
					removing = nil
				}
				VaultBarButton(title: "Cancel", height: 24) { removing = nil }
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.orangeTint))
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.orange.opacity(0.6), lineWidth: 1) }
		.padding(.horizontal, 10)
		.padding(.vertical, 4)
	}

	private func keyChips(_ keys: [String]) -> some View {
		VaultFlowLayout(spacing: 5, lineSpacing: 5) {
			ForEach(keys.prefix(Self.shownKeys), id: \.self) { key in
				Text(key.escapingDirectionControls)
					.font(VaultTypography.mono(11))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.padding(.horizontal, 6)
					.frame(height: 20)
					.overlay { RoundedRectangle(cornerRadius: 4).stroke(VaultPalette.border, lineWidth: 1) }
			}
			if keys.count > Self.shownKeys {
				Text("and \(keys.count - Self.shownKeys) more").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary).frame(height: 20)
			}
		}
		.padding(.leading, 16)
	}

	// MARK: - Adding

	private func addField(draft: ProjectEnvSchemaDraft, rules: ProjectEnvSchemaOverview?) -> some View {
		let prefix = entry.trimmingCharacters(in: .whitespaces)
		let issue = prefix.isEmpty ? nil : Prefixes.issue(adding: prefix, draft: draft, rules: rules)
		let change = prefix.isEmpty || issue != nil ? nil : Prefixes.adding(prefix, draft: draft, rules: rules)
		return VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 6) {
				TextField("NEW_PREFIX_", text: $entry)
					.textFieldStyle(.plain)
					.font(VaultTypography.mono(12))
					.autocorrectionDisabled()
					.focused($entryFocused)
					.onSubmit { if let change { add(change) } }
					.padding(.horizontal, 8)
					.frame(height: 28)
					.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
					.overlay {
						RoundedRectangle(cornerRadius: 7)
							.stroke(issue != nil ? VaultPalette.red : (entryFocused ? VaultPalette.accent : VaultPalette.border), lineWidth: issue != nil || entryFocused ? 1.5 : 1)
					}
					.accessibilityLabel("New client prefix")
				VaultBarButton(title: "Add", filled: true, disabled: change == nil, height: 28) { if let change { add(change) } }
			}
			if let issue {
				VStack(alignment: .leading, spacing: 4) {
					HStack(alignment: .top, spacing: 6) {
						Image(systemName: "xmark.circle").font(.system(size: 10)).padding(.top, 1)
						Text(issue.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
					}
					.foregroundStyle(VaultPalette.redText)
					if case .secret(let key) = issue {
						Button("Open \(key)") {
							onOpenKey(key)
							dismiss()
						}
							.buttonStyle(.plain)
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(VaultPalette.accentForeground)
							.padding(.leading, 16)
							.vaultPointingHand()
					}
				}
			} else if let change, !change.keys.isEmpty {
				HStack(alignment: .top, spacing: 6) {
					Image(systemName: "globe").font(.system(size: 10)).padding(.top, 1)
					Text(change.keys.count == 1
						? "1 key starts with \(prefix.escapingDirectionControls) — it'll be marked Public in the same change."
						: "\(change.keys.count) keys start with \(prefix.escapingDirectionControls) — they'll be marked Public in the same change.")
						.font(.system(size: 11))
						.fixedSize(horizontal: false, vertical: true)
				}
				.foregroundStyle(VaultPalette.publicText)
				keyChips(change.keys)
				if !change.overridden.isEmpty {
					Text(change.overridden.count == 1
						? "1 of them is declared in an imported schema; lpm.json overrides it to mark it Public."
						: "\(change.overridden.count) of them are declared in imported schemas; lpm.json overrides them to mark them Public.")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
						.padding(.leading, 16)
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.top, 8)
		.padding(.bottom, 12)
	}

	private func add(_ change: ProjectEnvSchemaClientPrefixes.Change) {
		apply(change)
		entry = ""
	}

	private func apply(_ change: ProjectEnvSchemaClientPrefixes.Change) {
		store.editSchemaDraft(in: project.id) { draft in
			draft.set(change.edits.map { (item: $0.item, declaration: $0.declaration) })
		}
	}
}
