struct VaultSyncTarget: Identifiable, Equatable, Sendable {
	let projectId: String
	let account: SelectedAccount

	var id: String {
		switch account {
		case .personal: "personal:\(projectId)"
		case .org(let slug): "org:\(slug):\(projectId)"
		}
	}
}
