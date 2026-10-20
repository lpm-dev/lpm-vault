import SwiftUI

/// A question asked before an action: an icon that sets the stakes, a short
/// question, what happens, what it acts on, and the buttons that answer it.
struct VaultConfirmation {
	enum Tone {
		/// The action loses something: the icon and the action are red, and Return never presses it.
		case destructive
		/// Something went wrong: the icon is orange, and the answer only acknowledges it.
		case warning
		case standard
	}

	/// What the action acts on, named apart from the question so a long name truncates instead of wrapping it.
	struct Subject {
		enum Mark {
			case platform(PublishPlatform)
			case project(ProjectIconAppearance)
			case environment(Color)
			case initials(String)
			case symbol(String)
		}

		let mark: Mark
		let name: String
		var detail: String?
	}

	struct Action {
		enum Role {
			/// Filled, in the tone's color.
			case primary
			/// Outlined, as Cancel is.
			case secondary
		}

		let title: String
		var role: Role = .primary
		/// The action's name for accessibility, when the button's title needs its subject.
		var label: String?
		let perform: () -> Void
	}

	let symbol: String
	var tone: Tone = .destructive
	let title: String
	let message: String
	var subject: Subject?
	/// Nil when the only answer is to acknowledge, which `actions`' one button does.
	var cancelTitle: String? = "Cancel"
	/// Shown after Cancel, left to right.
	let actions: [Action]
	var onCancel: () -> Void = {}
}

/// A question that takes a name, such as renaming an environment.
struct VaultPrompt {
	let symbol: String
	let title: String
	let message: String
	/// Shown in place of `message` when the name can't be used, so the person sees why.
	var problem: String?
	let placeholder: String
	let text: Binding<String>
	let confirmTitle: String
	/// Whether the confirm button is on.
	var canConfirm = true
	/// Runs on the confirm button or Return, and checks the name as it is
	/// then: Return can come before the field shows the name's last edit.
	/// The caller ends the prompt once the name is taken.
	let confirm: () -> Void
	var onCancel: () -> Void = {}
}

struct VaultConfirmDialog: View {
	let confirmation: VaultConfirmation
	/// Ends the question, after Cancel or an action.
	let close: () -> Void

	var body: some View {
		VaultDialogFrame(symbol: confirmation.symbol, tone: confirmation.tone, title: confirmation.title) {
			Text(confirmation.message)
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.lineSpacing(3)
				.fixedSize(horizontal: false, vertical: true)
			if let subject = confirmation.subject {
				VaultDialogSubjectCard(subject: subject)
			}
		} buttons: {
			if let cancelTitle = confirmation.cancelTitle {
				VaultBarButton(title: cancelTitle, height: 28) {
					confirmation.onCancel()
					close()
				}
				.keyboardShortcut(.cancelAction)
			}
			ForEach(Array(confirmation.actions.enumerated()), id: \.offset) { index, action in
				actionButton(action, isLast: index == confirmation.actions.count - 1)
			}
		}
	}

	@ViewBuilder
	private func actionButton(_ action: VaultConfirmation.Action, isLast: Bool) -> some View {
		let button = VaultBarButton(
			title: action.title,
			filled: action.role == .primary,
			destructive: confirmation.tone == .destructive && action.role == .primary,
			height: 28
		) {
			action.perform()
			close()
		}
		.accessibilityLabel(action.label ?? action.title)
		// Return answers only a question whose answer loses nothing; with no Cancel, Esc acknowledges too.
		if isLast, confirmation.tone != .destructive {
			if confirmation.cancelTitle == nil {
				button.keyboardShortcut(.defaultAction).background { VaultEscapeShortcut(action: { action.perform(); close() }) }
			} else {
				button.keyboardShortcut(.defaultAction)
			}
		} else {
			button
		}
	}
}

struct VaultPromptDialog: View {
	let prompt: VaultPrompt
	let close: () -> Void

	@FocusState private var focused: Bool

	var body: some View {
		VaultDialogFrame(symbol: prompt.symbol, tone: .standard, title: prompt.title) {
			Text(prompt.problem ?? prompt.message)
				.font(.system(size: 12.5))
				.foregroundStyle(prompt.problem == nil ? VaultPalette.textSecondary : VaultPalette.redText)
				.lineSpacing(3)
				.fixedSize(horizontal: false, vertical: true)
			TextField(prompt.placeholder, text: prompt.text)
				.textFieldStyle(.plain)
				.font(.system(size: 13))
				.foregroundStyle(VaultPalette.textPrimary)
				.autocorrectionDisabled()
				.focused($focused)
				.onSubmit(prompt.confirm)
				.padding(.horizontal, 10)
				.frame(height: 30)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.content))
				.overlay {
					RoundedRectangle(cornerRadius: 7)
						.stroke(focused ? VaultPalette.accent.opacity(0.6) : VaultPalette.border, lineWidth: 1)
				}
		} buttons: {
			VaultBarButton(title: "Cancel", height: 28) {
				prompt.onCancel()
				close()
			}
			.keyboardShortcut(.cancelAction)
			VaultBarButton(title: prompt.confirmTitle, filled: true, disabled: !prompt.canConfirm, height: 28, action: prompt.confirm)
				.keyboardShortcut(.defaultAction)
		}
		.onAppear { focused = true }
	}
}

/// The confirmation sheet's layout, which a prompt shares: the icon tile, then the title over the body, then the buttons on the right.
private struct VaultDialogFrame<Content: View, Buttons: View>: View {
	let symbol: String
	let tone: VaultConfirmation.Tone
	let title: String
	@ViewBuilder let content: Content
	@ViewBuilder let buttons: Buttons

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(alignment: .top, spacing: 14) {
				Image(systemName: symbol)
					.font(.system(size: 17, weight: .medium))
					.foregroundStyle(iconColors.foreground)
					.frame(width: 40, height: 40)
					.background(RoundedRectangle(cornerRadius: 10).fill(iconColors.background))
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 8) {
					Text(title)
						.font(.system(size: 14, weight: .bold))
						.foregroundStyle(VaultPalette.textPrimary)
						.fixedSize(horizontal: false, vertical: true)
						.accessibilityAddTraits(.isHeader)
					content
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			HStack(spacing: 8) {
				Spacer(minLength: 0)
				buttons
			}
		}
		.padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
		.frame(width: 420)
		.background(VaultPalette.control)
	}

	private var iconColors: (foreground: Color, background: Color) {
		switch tone {
		case .destructive: (VaultPalette.redText, VaultPalette.redTint)
		case .warning: (VaultPalette.orangeTintText, VaultPalette.orangeTint)
		case .standard: (VaultPalette.accentText, VaultPalette.accentTint)
		}
	}
}

private struct VaultDialogSubjectCard: View {
	let subject: VaultConfirmation.Subject

	var body: some View {
		HStack(spacing: 10) {
			mark
			VStack(alignment: .leading, spacing: 1) {
				Text(subject.name)
					.font(.system(size: 12.5, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
				if let detail = subject.detail {
					Text(detail)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 11)
		.padding(.vertical, 9)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.sidebar))
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
		.help([subject.name, subject.detail].compactMap { $0 }.joined(separator: "\n"))
		.accessibilityElement(children: .combine)
	}

	@ViewBuilder
	private var mark: some View {
		switch subject.mark {
		case .platform(let platform):
			PlatformLogo(platform: platform, size: 22)
		case .project(let appearance):
			VaultProjectIconView(appearance: appearance, size: 22)
				.accessibilityHidden(true)
		case .environment(let color):
			VaultEnvSwatch(color: color, size: 8)
				.frame(width: 22, height: 22)
				.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.neutralTint))
				.accessibilityHidden(true)
		case .initials(let initials):
			VaultInitialsAvatar(initials: initials, size: 22)
				.accessibilityHidden(true)
		case .symbol(let name):
			Image(systemName: name)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.textSecondary)
				.frame(width: 22, height: 22)
				.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.neutralTint))
				.accessibilityHidden(true)
		}
	}
}

/// Esc for a sheet whose only button takes Return.
private struct VaultEscapeShortcut: View {
	let action: () -> Void

	var body: some View {
		Button("", action: action)
			.keyboardShortcut(.cancelAction)
			.buttonStyle(.plain)
			.frame(width: 0, height: 0)
			.opacity(0)
			.accessibilityHidden(true)
	}
}

extension View {
	/// Asks the confirmation `content` makes from `item` in a sheet while
	/// `item` is set. The sheet keeps the item it opened with, so it
	/// doesn't change as it closes.
	func vaultConfirmation<Item: Identifiable>(
		item: Binding<Item?>,
		_ content: @escaping (Item) -> VaultConfirmation
	) -> some View {
		sheet(item: item) { shown in
			VaultConfirmDialog(confirmation: content(shown)) { item.wrappedValue = nil }
		}
	}

	/// Asks `confirmation` in a sheet while `isPresented`.
	func vaultConfirmation(isPresented: Binding<Bool>, _ confirmation: @escaping () -> VaultConfirmation) -> some View {
		sheet(isPresented: isPresented) {
			VaultConfirmDialog(confirmation: confirmation()) { isPresented.wrappedValue = false }
		}
	}

	/// Asks for a name in a sheet while `item` is set.
	func vaultPrompt<Item: Identifiable>(item: Binding<Item?>, _ content: @escaping (Item) -> VaultPrompt) -> some View {
		sheet(item: item) { shown in
			VaultPromptDialog(prompt: content(shown)) { item.wrappedValue = nil }
		}
	}
}
