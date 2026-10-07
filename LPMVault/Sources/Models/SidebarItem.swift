import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Which account context is selected in the account rail (Column 1).
enum SelectedAccount: Hashable, Sendable {
	case personal
	case org(String)  // org slug
}

struct VaultSidebarProjectDrag: Codable, Transferable, Sendable {
	static let contentType = UTType(exportedAs: "dev.lpm.vault.sidebar-project", conformingTo: .data)
	let projectId: String
	let sessionId: UUID

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: contentType)
			.visibility(.ownProcess)
	}
}

enum VaultProjectPlacement: Equatable {
	case before
	case after

	static func at(y: CGFloat, rowHeight: CGFloat) -> Self {
		y < rowHeight / 2 ? .before : .after
	}
}
