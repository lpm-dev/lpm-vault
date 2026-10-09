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

	@State private var showsFrameworks = false
	/// lpm.json's prefix whose removal waits for confirmation, because keys rely on it.
	@State private var removing: String?

	/// Keys a list shows before "and N more".
	private static let shownKeys = 12

	private var canEdit: Bool { store.canEditSchema(of: project.id) }

	var body: some View {
		let availability = store.schemaPrefixAvailability(for: project.id)
		let context = availability.context
		let own = Prefixes.own(in: context?.draft ?? store.schemaDraftOrBase(for: project.id))
		// While the draft is checked, the rules last known stand in, so rows don't come and go.
		let importedSources = context?.imported ?? store.schemaImportedClientPrefixSources(for: project.id)
		let imported = VaultKeySortOrder.sortedAscending(Set(importedSources.keys).subtracting(own))
		let counts = (context?.rules ?? store.schemaOverview(for: project.id)).map { Prefixes.keyCounts(of: own + imported, rules: $0) } ?? [:]
		let removal = removing.flatMap { prefix in context.map { Prefixes.removing(prefix, in: $0) } }
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
				row(prefix, keys: counts[prefix], source: importedSources[prefix], removable: false, unavailable: availability.reason)
			}
			ForEach(own, id: \.self) { prefix in
				if removing == prefix, let removal, !removal.keys.isEmpty {
					removalConfirmation(prefix, removal: removal)
				} else {
					row(prefix, keys: counts[prefix], source: importedSources[prefix], removable: true, unavailable: availability.reason) { remove(prefix) }
				}
			}
			if canEdit {
				VaultSchemaPrefixField(store: store, project: project, availability: availability, onOpenKey: onOpenKey)
			}
			VaultHairline()
			HStack {
				Text("\(Set(own).union(importedSources.keys).count) of \(Prefixes.maximum)")
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
		// A removal waiting for confirmation ends when its prefix goes some other way, such as an undo.
		.onChange(of: own) { _, own in if let removing, !own.contains(removing) { self.removing = nil } }
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

	/// A prefix's row. `source` is the imported schema that lists it, when
	/// one does; `keys` is nil while the draft's rules aren't known, and
	/// `unavailable` says why the prefix can't be removed now.
	private func row(
		_ prefix: String, keys: Int?, source: String?, removable: Bool, unavailable: String?, onRemove: (() -> Void)? = nil
	) -> some View {
		let shown = prefix.escapingDirectionControls
		return HStack(spacing: 7) {
			Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(VaultPalette.publicText).accessibilityHidden(true)
			Text(shown)
				.font(VaultTypography.mono(12, .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 8)
			if let source {
				let file = source.escapingDirectionControls
				Text(removable ? "also imported" : "imported")
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.padding(.horizontal, 5)
					.overlay { RoundedRectangle(cornerRadius: 4).stroke(VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
					.help(removable
						? "\(file), which lpm.json imports, lists it too, so it stays in effect if you remove it here"
						: "Listed in \(file), which lpm.json imports, so it can't be removed here")
					.accessibilityLabel(removable ? "Also listed in \(file)" : "Listed in \(file)")
			}
			if let keys {
				Text(keys == 1 ? "1 key" : "\(keys) keys").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			}
			if !removable {
				Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(VaultPalette.textFaint).accessibilityHidden(true)
			} else if let onRemove {
				Button(action: onRemove) {
					Image(systemName: "xmark")
						.font(.system(size: 9, weight: .bold))
						.foregroundStyle(VaultPalette.textFaint)
						.frame(width: 20, height: 20)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(!canEdit || unavailable != nil)
				.help(unavailable ?? "Remove \(shown)")
				.accessibilityLabel("Remove \(shown)")
			}
		}
		.padding(.horizontal, 14)
		.frame(height: 30)
	}

	private func removalConfirmation(_ prefix: String, removal: Prefixes.Change) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 7) {
				Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(VaultPalette.publicText).accessibilityHidden(true)
				Text(prefix.escapingDirectionControls).font(VaultTypography.mono(12, .semibold)).foregroundStyle(VaultPalette.textPrimary)
				Spacer(minLength: 8)
			}
			HStack(alignment: .top, spacing: 6) {
				Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).padding(.top, 1)
				Text(removal.keys.count == 1
					? "1 public key uses it — it'll become private in the same change."
					: "\(removal.keys.count) public keys use it — they'll become private in the same change.")
					.font(.system(size: 11.5))
					.fixedSize(horizontal: false, vertical: true)
			}
			.foregroundStyle(VaultPalette.orangeTintText)
			Self.keyChips(removal.keys)
			Self.overrideNotes(removal, public: false)
			HStack(spacing: 6) {
				VaultBarButton(title: "Remove", filled: true, disabled: !canEdit, height: 24) {
					guard let context = store.schemaPrefixAvailability(for: project.id).context,
						let confirmed = Prefixes.confirmed(removal, removing: prefix, in: context)
					else { return }
					apply(confirmed)
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

	/// What a change does to imported keys: overrides it starts, and ones that go.
	@ViewBuilder
	static func overrideNotes(_ change: ProjectEnvSchemaClientPrefixes.Change, public isPublic: Bool) -> some View {
		let overridden = change.overridden.count
		let restored = change.restored.count
		if overridden > 0 {
			let them = overridden == 1 ? "it" : "them"
			Text((overridden == 1 ? "1 of them is declared in an imported schema" : "\(overridden) of them are declared in imported schemas")
				+ ", so lpm.json overrides \(them) with a copy of the imported rule that marks \(them) \(isPublic ? "public" : "private"). Later changes to that rule in the imported schema won't apply to \(them).")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.leading, 16)
		}
		if restored > 0 {
			Text(restored == 1
				? "1 of them goes back to its imported rule: lpm.json's override only marked it."
				: "\(restored) of them go back to their imported rules: lpm.json's overrides only marked them.")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.leading, 16)
		}
	}

	static func keyChips(_ keys: [String]) -> some View {
		VaultFlowLayout(spacing: 5, lineSpacing: 5) {
			ForEach(keys.prefix(shownKeys), id: \.self) { key in
				Text(key.escapingDirectionControls)
					.font(VaultTypography.mono(11))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.padding(.horizontal, 6)
					.frame(height: 20)
					.overlay { RoundedRectangle(cornerRadius: 4).stroke(VaultPalette.border, lineWidth: 1) }
			}
			if keys.count > shownKeys {
				Text("and \(keys.count - shownKeys) more").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary).frame(height: 20)
			}
		}
		.padding(.leading, 16)
	}

	// MARK: - Changing

	private func remove(_ prefix: String) {
		guard let context = store.schemaPrefixAvailability(for: project.id).context else { return }
		let removal = Prefixes.removing(prefix, in: context)
		// Keys that rely on it are named first; a prefix nothing relies on just goes.
		if removal.keys.isEmpty { apply(removal) } else { removing = prefix }
	}

	private func apply(_ change: ProjectEnvSchemaClientPrefixes.Change) {
		Self.apply(change, in: project.id, store: store)
	}

	static func apply(_ change: ProjectEnvSchemaClientPrefixes.Change, in projectID: String, store: VaultStore) {
		store.editSchemaDraft(in: projectID) { draft in
			draft.set(change.edits.map { (item: $0.item, declaration: $0.declaration) })
		}
	}
}

/// The field that adds a prefix, with what adding it does. Its own view, so
/// typing redraws only the field and what it shows. It stays in place while
/// the draft is checked, keeping focus between prefixes.
private struct VaultSchemaPrefixField: View {
	private typealias Prefixes = ProjectEnvSchemaClientPrefixes

	@Bindable var store: VaultStore
	let project: VaultProject
	let availability: ProjectEnvSchemaClientPrefixes.Availability
	let onOpenKey: (String) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var entry = ""
	@FocusState private var entryFocused: Bool

	var body: some View {
		let context = availability.context
		let prefix = entry.trimmingCharacters(in: .whitespaces)
		let issue = prefix.isEmpty ? nil : context.flatMap { Prefixes.issue(adding: prefix, in: $0) }
		let change = prefix.isEmpty || issue != nil ? nil : context.map { Prefixes.adding(prefix, in: $0) }
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 6) {
				TextField("NEW_PREFIX_", text: $entry)
					.textFieldStyle(.plain)
					.font(VaultTypography.mono(12))
					.autocorrectionDisabled()
					.focused($entryFocused)
					.onSubmit { if let change { add(prefix, shown: change) } }
					.padding(.horizontal, 8)
					.frame(height: 28)
					.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
					.overlay {
						RoundedRectangle(cornerRadius: 7)
							.stroke(issue != nil ? VaultPalette.red : (entryFocused ? VaultPalette.accent : VaultPalette.border), lineWidth: issue != nil || entryFocused ? 1.5 : 1)
					}
					.accessibilityLabel("New client prefix")
				VaultBarButton(title: "Add", filled: true, disabled: change == nil, height: 28) { if let change { add(prefix, shown: change) } }
			}
			if availability != .checking, let reason = availability.reason {
				Text(reason).font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			} else if let issue {
				VStack(alignment: .leading, spacing: 4) {
					HStack(alignment: .top, spacing: 6) {
						Image(systemName: "xmark.circle").font(.system(size: 10)).padding(.top, 1)
						Text(issue.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
					}
					.foregroundStyle(VaultPalette.redText)
					if case .secret(let key) = issue {
						Button("Open \(key.escapingDirectionControls)") {
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
						? "1 key becomes public with \(prefix.escapingDirectionControls), marked so in the same change."
						: "\(change.keys.count) keys become public with \(prefix.escapingDirectionControls), marked so in the same change.")
						.font(.system(size: 11))
						.fixedSize(horizontal: false, vertical: true)
				}
				.foregroundStyle(VaultPalette.publicText)
				VaultSchemaClientPrefixesPopover.keyChips(change.keys)
				ForEach(change.exposed, id: \.key) { exposure in
					HStack(alignment: .top, spacing: 6) {
						Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).padding(.top, 1)
						Text("\(exposure.source) marks \(exposure.key.escapingDirectionControls) Secret, and lpm.json's override doesn't, so its value becomes public.")
							.font(.system(size: 11, weight: .medium))
							.fixedSize(horizontal: false, vertical: true)
					}
					.foregroundStyle(VaultPalette.redText)
				}
				VaultSchemaClientPrefixesPopover.overrideNotes(change, public: true)
			}
		}
		.padding(.horizontal, 14)
		.padding(.top, 8)
		.padding(.bottom, 12)
	}

	private func add(_ prefix: String, shown: Prefixes.Change) {
		guard let context = store.schemaPrefixAvailability(for: project.id).context,
			let confirmed = Prefixes.confirmed(shown, adding: prefix, entry: entry, in: context)
		else { return }
		VaultSchemaClientPrefixesPopover.apply(confirmed, in: project.id, store: store)
		entry = ""
	}
}
