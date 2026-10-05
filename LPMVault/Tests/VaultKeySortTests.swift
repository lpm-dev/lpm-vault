import Testing

@testable import LPMVault

@Suite("Key sort order")
struct VaultKeySortTests {
	/// `KEY_10` and `Zeta` differ between environments; `api_url` and `BETA` are missing from production.
	private let project = VaultProject(
		id: "project",
		name: "Project",
		path: "",
		environments: [
			"default": ["KEY_10": "a", "KEY_2": "b", "api_url": "c", "Zeta": "d", "BETA": "f"],
			"production": ["KEY_10": "x", "KEY_2": "b", "Zeta": "e"],
		]
	)

	/// One way of looking at the keys, and the keys it lists from A to Z.
	struct Listing: CustomTestStringConvertible, Sendable {
		let mode: VaultWorkspaceMode
		let filter: VaultWorkspaceFilter
		let searchText: String
		let ascending: [String]

		var environment: String {
			if case .environment(let name) = mode { name } else { "default" }
		}

		var testDescription: String {
			"\(mode == .matrix ? "all variables" : "environment"), \(filter.rawValue), search \"\(searchText)\""
		}
	}

	@Test("Z to A lists every view's keys in reverse", arguments: [
		Listing(mode: .matrix, filter: .all, searchText: "", ascending: ["api_url", "BETA", "KEY_2", "KEY_10", "Zeta"]),
		Listing(mode: .matrix, filter: .drift, searchText: "", ascending: ["KEY_10", "Zeta"]),
		Listing(mode: .matrix, filter: .all, searchText: "key", ascending: ["KEY_2", "KEY_10"]),
		Listing(mode: .matrix, filter: .missing, searchText: "a", ascending: ["api_url", "BETA"]),
		Listing(mode: .environment("production"), filter: .all, searchText: "", ascending: ["KEY_2", "KEY_10", "Zeta"]),
		Listing(mode: .environment("default"), filter: .all, searchText: "e", ascending: ["BETA", "KEY_2", "KEY_10", "Zeta"]),
	])
	func reverseOrder(listing: Listing) {
		let snapshot = VaultWorkspaceSnapshot(project: project)

		#expect(keys(of: listing, in: project, snapshot: snapshot, sortOrder: .ascending) == listing.ascending)
		#expect(keys(of: listing, in: project, snapshot: snapshot, sortOrder: .descending) == listing.ascending.reversed())
	}

	@Test("searching a single-environment project lists matches in the chosen order")
	func singleEnvironmentSearch() {
		let project = VaultProject(id: "single", name: "Single", path: "",
			environments: ["default": ["KEY_10": "a", "KEY_2": "b", "OTHER": "c"]])
		let snapshot = VaultWorkspaceSnapshot(project: project)
		let listing = Listing(mode: .environment("default"), filter: .all, searchText: "KEY", ascending: ["KEY_2", "KEY_10"])

		#expect(keys(of: listing, in: project, snapshot: snapshot, sortOrder: .ascending) == listing.ascending)
		#expect(keys(of: listing, in: project, snapshot: snapshot, sortOrder: .descending) == ["KEY_10", "KEY_2"])
	}

	@Test("unfiltered Z to A views show the snapshot's keys without copying them", arguments: [false, true])
	func descendingReusesSnapshotBuffers(singleEnvironment: Bool) {
		let project = singleEnvironment
			? VaultProject(id: "single", name: "Single", path: "", environments: ["default": ["B": "2", "A": "1"]])
			: self.project
		let snapshot = VaultWorkspaceSnapshot(project: project)
		let matrix = derivation(.matrix, in: project, snapshot: snapshot)
		let environment = derivation(.environment("default"), in: project, snapshot: snapshot)
		let descendingKeys = snapshot.keys(.descending)
		let descendingEnvironmentKeys = snapshot.sortedKeys(for: "default", .descending)

		#expect(matrix.filteredKeys == descendingKeys)
		#expect(baseAddress(of: matrix.filteredKeys) == baseAddress(of: descendingKeys))
		#expect(baseAddress(of: environment.environmentKeys) == baseAddress(of: descendingEnvironmentKeys))
		if singleEnvironment {
			#expect(descendingKeys == ["B", "A"])
			#expect(baseAddress(of: descendingKeys) == baseAddress(of: descendingEnvironmentKeys))
		}
	}

	@Test("clicking the header reverses the order each time")
	func reversed() {
		#expect(VaultKeySortOrder.ascending.reversed == .descending)
		#expect(VaultKeySortOrder.descending.reversed == .ascending)
	}

	private func keys(of listing: Listing, in project: VaultProject, snapshot: VaultWorkspaceSnapshot, sortOrder: VaultKeySortOrder) -> [String] {
		let derivation = VaultContentDerivation(
			project: project,
			snapshot: snapshot,
			selectedEnvironment: listing.environment,
			mode: listing.mode,
			filter: listing.filter,
			searchText: listing.searchText,
			sortOrder: sortOrder,
			revealedKeys: []
		)
		return listing.mode == .matrix ? derivation.filteredKeys : derivation.environmentKeys
	}

	private func derivation(_ mode: VaultWorkspaceMode, in project: VaultProject, snapshot: VaultWorkspaceSnapshot) -> VaultContentDerivation {
		VaultContentDerivation(
			project: project,
			snapshot: snapshot,
			selectedEnvironment: "default",
			mode: mode,
			filter: .all,
			searchText: "",
			sortOrder: .descending,
			revealedKeys: []
		)
	}

	private func baseAddress(of keys: [String]) -> UnsafePointer<String>? {
		keys.withUnsafeBufferPointer(\.baseAddress)
	}
}
