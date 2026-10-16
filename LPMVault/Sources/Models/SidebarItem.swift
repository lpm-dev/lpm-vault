import Foundation

/// Which account context is selected in the account rail (Column 1).
/// A page about the person's setup rather than a project, opened from the account menu.
enum AccountPage: Hashable, Sendable {
	case account
	case platforms
}

enum SelectedAccount: Hashable, Sendable {
	case personal
	case org(String)  // org slug
}

enum VaultProjectPlacement: Equatable {
	case before
	case after
}
