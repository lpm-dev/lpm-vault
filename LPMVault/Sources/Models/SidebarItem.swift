import Foundation

/// Which account context is selected in the account rail (Column 1).
enum SelectedAccount: Hashable {
	case personal
	case org(String)  // org slug
}
