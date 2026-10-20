import SwiftUI

/// What opens the import sheet: the project and environment shown, and a
/// file dropped on the window.
struct EnvImportRequest: Identifiable {
	let id = UUID()
	let projectID: String
	let environment: String
	let file: URL?
}

/// The step before an import's review: what to import, from a file or pasted
/// text, and which environment it goes into, or a new one. The review, or
/// what an import without one did, then shows in the same sheet.
struct EnvImportSheet: View {
	enum Target: Hashable {
		case environment(String)
		case newEnvironment
	}

	private enum Step {
		case choosing
		case reviewing(EnvFileImportReview)
		case imported(EnvFileImportReview)
	}

	private enum Work {
		case reviewing, importing, creating
	}

	@Bindable var store: VaultStore
	let projectID: String
	@Environment(\.dismiss) private var dismiss

	@State private var source: EnvImportSourceState
	@State private var target: Target
	@State private var newName = ""
	@State private var reviewsFirst = true
	@State private var step = Step.choosing
	@State private var work: Work?
	@State private var task: Task<Void, Never>?
	@State private var failure: String?

	/// `file` is one dropped on the window, which the sheet opens reading.
	init(store: VaultStore, projectID: String, environment: String, file: URL? = nil) {
		_store = Bindable(wrappedValue: store)
		self.projectID = projectID
		_source = State(initialValue: EnvImportSourceState(file: file))
		_target = State(initialValue: .environment(environment))
	}

	private var project: VaultProject? { store.projects.first { $0.id == projectID } }
	private var environments: [String] { project.map { store.orderedEnvironmentNames(for: $0) } ?? [] }

	var body: some View {
		Group {
			switch step {
			case .choosing: choosing
			case .reviewing(let review): EnvFileImportReviewSheet(store: store, review: review)
			case .imported(let review): EnvFileImportReviewSheet(store: store, review: review, importedWithoutReview: true)
			}
		}
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { close() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != projectID { close() } }
		.onChange(of: store.selectedAccount) { _, _ in close() }
		.onChange(of: store.isShowingAccountPage) { _, showing in if showing { close() } }
		.onChange(of: project == nil) { _, gone in if gone { close() } }
		.onDisappear {
			task?.cancel()
			task = nil
		}
	}

	// MARK: - Choosing

	private var choosing: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			VStack(alignment: .leading, spacing: 18) {
				EnvImportSourcePicker(store: store, projectID: projectID, state: $source, disabled: work != nil)
				targetSection
				reviewOption
				if let failure {
					Text(failure)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.redText)
						.lineLimit(3)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(.horizontal, 24)
			.padding(.top, 18)
			.padding(.bottom, 20)
			footer
		}
		.frame(width: 520)
		.background(VaultPalette.content)
		.vaultUnsavedSheetWork(store, projectID: projectID, projectName: project?.name ?? "", title: "Import variables",
			detail: source.source.map { "\($0.name) into \(targetName)" })
		.onChange(of: source.file) { _, file in suggestName(from: file) }
		.onChange(of: target) { _, target in
			failure = nil
			if target == .newEnvironment { suggestName(from: source.file) }
		}
		.onChange(of: source.textRevision) { _, _ in failure = nil }
		.onChange(of: source.fileRevision) { _, _ in failure = nil }
		.onChange(of: environments) { _, names in
			// The environment was deleted meanwhile, as from the LPM CLI.
			guard case .environment(let name) = target, !names.contains(name) else { return }
			target = names.contains(store.selectedEnvironment) ? .environment(store.selectedEnvironment) : .newEnvironment
		}
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Import variables")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("into \(Text(project?.name ?? "").fontWeight(.semibold).foregroundStyle(VaultPalette.textSecondary))")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: close)
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	private var targetSection: some View {
		let names = environments
		let rows = (names.count + 1 + 2) / 3
		return VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				VaultFieldLabel(title: "Import into")
				Spacer()
				Text("one file per import")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textFaint)
			}
			ScrollView(.vertical) {
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), alignment: .leading, spacing: 8) {
					ForEach(Array(names.enumerated()), id: \.element) { index, name in
						EnvImportTargetTile(
							title: VaultProject.displayName(for: name), swatch: VaultPalette.environment(index),
							selected: target == .environment(name)
						) { target = .environment(name) }
					}
					EnvImportTargetTile(title: "New file", swatch: nil, selected: target == .newEnvironment) {
						target = .newEnvironment
					}
				}
			}
			.frame(height: CGFloat(min(rows, 3)) * EnvImportTargetTile.height + CGFloat(min(rows, 3) - 1) * 8)
			.disabled(work != nil)
			.accessibilityElement(children: .contain)
			.accessibilityLabel("Import into")
			if target == .newEnvironment {
				VaultEnvironmentNameField(
					name: $newName, existing: Set(names), swatch: VaultPalette.environment(names.count),
					focusesOnAppear: true, disabled: work != nil, onSubmit: submit)
			}
		}
	}

	private var reviewOption: some View {
		let isNew = target == .newEnvironment
		let caption = isNew
			? "A new file has nothing to compare, so it's created as it is"
			: reviewsFirst ? "See new, changed and unchanged keys first" : "Adds new keys and keeps every existing value"
		return HStack(spacing: 10) {
			Toggle("Review before applying", isOn: isNew ? .constant(false) : $reviewsFirst)
				.toggleStyle(.switch)
				.controlSize(.small)
				.labelsHidden()
				.disabled(isNew || work != nil)
			VStack(alignment: .leading, spacing: 1) {
				// The switch says its name.
				Text("Review before applying")
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(isNew ? VaultPalette.textTertiary : VaultPalette.textPrimary)
					.accessibilityHidden(true)
				Text(caption)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.neutralTint.opacity(0.4)))
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private var footer: some View {
		VaultSheetFooter {
			Text("Parsed locally. Comments and blank lines are ignored.")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textFaint)
				.lineLimit(2)
		} actions: {
			VaultBarButton(title: "Cancel", height: 30, action: close)
				.keyboardShortcut(.cancelAction)
			VaultBarButton(title: primaryTitle, shortcut: "⏎", filled: true, disabled: !canSubmit, height: 30, action: submit)
				.keyboardShortcut(.defaultAction)
		}
	}

	private var newEnvironmentName: String? {
		let name = newName.trimmingCharacters(in: .whitespaces)
		return VaultEnvironmentNameField.isValid(name, existing: Set(environments)) ? name : nil
	}

	private var targetName: String {
		switch target {
		case .environment(let name): VaultProject.displayName(for: name)
		case .newEnvironment: newEnvironmentName.map(VaultProject.displayName(for:)) ?? "a new file"
		}
	}

	private var primaryTitle: String {
		switch work {
		case .reviewing: return "Reviewing…"
		case .importing: return "Importing…"
		case .creating: return "Creating…"
		case nil: break
		}
		// The count read last stays while newer pasted text is read, so it doesn't flicker as it's typed.
		let count = (try? source.shownRead?.get()).map { " \($0.countDescription)" } ?? ""
		if target == .newEnvironment {
			return newEnvironmentName.map { "Create \(VaultProject.displayName(for: $0))" } ?? "Create file"
		}
		return (reviewsFirst ? "Review" : "Import") + count
	}

	private var canSubmit: Bool {
		guard work == nil, source.imported != nil else { return false }
		return target != .newEnvironment || newEnvironmentName != nil
	}

	// MARK: - Actions

	private func suggestName(from file: URL?) {
		guard let file, newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
		newName = VaultEnvironmentNameField.suggestedName(forFile: file)
	}

	private func submit() {
		guard canSubmit, let imported = source.imported, let origin = source.source else { return }
		failure = nil
		store.recordUserActivity()
		switch target {
		case .newEnvironment:
			guard let name = newEnvironmentName else { return }
			work = .creating
			task = Task {
				let added = await store.addEnvironment(to: projectID, name: name, secrets: imported.secrets)
				guard !Task.isCancelled else { return }
				work = nil
				task = nil
				if added { dismiss() }
			}
		case .environment(let environment):
			// The window shows the environment the import goes into, under the
			// sheet; the review holds only while it does.
			store.selectEnvironment(environment)
			guard store.selectedEnvironment == environment else {
				failure = EnvFileImportError.targetUnavailable.description(for: origin)
				return
			}
			let reviews = reviewsFirst
			work = reviews ? .reviewing : .importing
			task = Task {
				let prepared = await store.prepareEnvImport(imported, from: origin, to: projectID, environment: environment)
				guard !Task.isCancelled else { return }
				let review: EnvFileImportReview
				switch prepared {
				case .success(let prepared): review = prepared
				case .failure(let error): return fail(error, from: origin)
				}
				guard !reviews else { return show(.reviewing(review)) }
				let applied = await store.applyEnvFileImport(review, replacingKeys: [])
				guard !Task.isCancelled else { return }
				switch applied {
				case .success: show(.imported(review))
				case .failure(let error): fail(error, from: origin)
				}
			}
		}
	}

	private func show(_ next: Step) {
		work = nil
		task = nil
		step = next
	}

	private func fail(_ error: EnvFileImportError, from origin: EnvImportSource) {
		work = nil
		task = nil
		switch error {
		case .cancelled, .vaultLocked: close()
		default: failure = error.description(for: origin)
		}
	}

	private func close() {
		task?.cancel()
		task = nil
		dismiss()
	}
}

/// One environment an import can go into, or a new one, chosen as a radio button is.
private struct EnvImportTargetTile: View {
	static let height: CGFloat = 36

	let title: String
	/// The environment's color; nil for a new file.
	let swatch: Color?
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		let stroke = selected ? VaultPalette.accent : (hovering ? VaultPalette.textFaint.opacity(0.5) : VaultPalette.border)
		Button(action: action) {
			HStack(spacing: 8) {
				if let swatch {
					VaultEnvSwatch(color: swatch, size: 6)
				} else {
					Image(systemName: "plus")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
				}
				Text(title)
					.font(swatch == nil ? .system(size: 12) : VaultTypography.tabular(12))
					.foregroundStyle(selected ? VaultPalette.textPrimary : (swatch == nil ? VaultPalette.textTertiary : VaultPalette.textSecondary))
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 10)
			.frame(height: Self.height)
			.background(RoundedRectangle(cornerRadius: 8).fill(selected ? VaultPalette.accent.opacity(0.14) : .clear))
			.overlay {
				RoundedRectangle(cornerRadius: 8)
					.strokeBorder(stroke, style: StrokeStyle(lineWidth: 1.5, dash: swatch == nil && !selected ? [4, 3] : []))
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.vaultPointingHand()
		.help(title)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}
