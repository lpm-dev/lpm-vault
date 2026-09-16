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

	var colorScheme: ColorScheme? {
		switch self {
		case .system: nil
		case .light: .light
		case .dark: .dark
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
