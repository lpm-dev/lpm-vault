import Foundation

/// Which account context is selected in the account rail (Column 1).
/// A page about the person's setup rather than a project, shown in the
/// Settings overlay over the workspace.
enum AccountPage: Hashable, Sendable {
	case settings
	case platforms
}

/// The parts of the Settings overlay, in the order its menu lists them.
/// Platforms is one, shown as `AccountPage.platforms`.
enum VaultSettingsCategory: String, CaseIterable, Identifiable, Sendable {
	case general
	case appearance
	case account
	case cli
	case platforms
	case backup
	case updates

	var id: String { rawValue }

	var title: String {
		switch self {
		case .general: "General"
		case .appearance: "Appearance"
		case .account: "Account & Sync"
		case .cli: "CLI"
		case .platforms: "Platforms"
		case .backup: "Backup & Restore"
		case .updates: "Updates"
		}
	}

	var systemImage: String {
		switch self {
		case .general: "gearshape"
		case .appearance: "circle.lefthalf.filled"
		case .account: "person.crop.circle"
		case .cli: "terminal"
		case .platforms: "square.stack.3d.up"
		case .backup: "externaldrive"
		case .updates: "arrow.down.circle"
		}
	}
}

enum SelectedAccount: Hashable, Sendable {
	case personal
	case org(String)  // org slug
}

enum VaultProjectPlacement: Equatable {
	case before
	case after
}
