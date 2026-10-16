import Foundation
import Observation

/// What ⌘Q takes to quit, so a stray press doesn't close the app.
enum VaultQuitShortcut: String, CaseIterable, Identifiable, Sendable {
	case direct
	case doublePress
	case hold

	static let defaultsKey = "lpm-vault-quit-shortcut"
	static let standard = VaultQuitShortcut.doublePress

	var id: String { rawValue }

	var title: String {
		switch self {
		case .direct: "Direct"
		case .doublePress: "Double press"
		case .hold: "Hold"
		}
	}

	var explanation: String {
		switch self {
		case .direct: "⌘Q quits immediately."
		case .doublePress: "Press ⌘Q twice."
		case .hold: "Hold ⌘Q, or press it twice."
		}
	}

	/// The saved choice, readable while the vault is locked or signed out.
	static func saved(in defaults: UserDefaults) -> VaultQuitShortcut {
		defaults.string(forKey: defaultsKey).flatMap(VaultQuitShortcut.init(rawValue:)) ?? standard
	}
}

@Observable
@MainActor
final class VaultQuitSettings {
	@ObservationIgnored private let defaults: UserDefaults

	var selection: VaultQuitShortcut {
		didSet { defaults.set(selection.rawValue, forKey: VaultQuitShortcut.defaultsKey) }
	}

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		selection = VaultQuitShortcut.saved(in: defaults)
	}
}
