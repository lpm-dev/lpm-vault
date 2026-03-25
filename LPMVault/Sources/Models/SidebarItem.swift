import Foundation

enum SidebarItem: Hashable {
	case project(String)        // vault ID
	case personalTokens
	case orgTokens(String)      // org slug
	case authStatus
}
