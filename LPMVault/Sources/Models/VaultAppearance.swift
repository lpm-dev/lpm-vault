import AppKit
import SwiftUI

enum VaultAppearance: String, CaseIterable, Identifiable {
	case system, light, dark

	var id: String { rawValue }

	var title: String {
		switch self {
		case .system: "System"
		case .light: "Light"
		case .dark: "Dark"
		}
	}

	var nativeAppearance: NSAppearance? {
		switch self {
		case .system: nil
		case .light: NSAppearance(named: .aqua)
		case .dark: NSAppearance(named: .darkAqua)
		}
	}
}

@Observable
@MainActor
final class VaultAppearanceSettings {
	static let defaultsKey = "lpm-vault-appearance"
	@ObservationIgnored private let defaults: UserDefaults

	var selection: VaultAppearance {
		didSet { defaults.set(selection.rawValue, forKey: Self.defaultsKey) }
	}

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		selection = defaults.string(forKey: Self.defaultsKey).flatMap(VaultAppearance.init(rawValue:)) ?? .system
	}
}

extension View {
	/// Applies the person's appearance choice to the whole app; windows, sheets,
	/// and popovers inherit it. `preferredColorScheme` is not used because it pins
	/// a scene's window to Light or Dark and leaves it there when the choice
	/// returns to System.
	func vaultAppearance(_ selection: VaultAppearance) -> some View {
		onChange(of: selection, initial: true) { _, selection in
			NSApplication.shared.appearance = selection.nativeAppearance
		}
	}
}
