import Testing

@testable import LPMVault

@Suite("VaultProject Model")
struct VaultProjectTests {
	@Test("sorted secrets returns alphabetical order")
	func sortedSecrets() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: ["default": ["ZEBRA": "z", "APPLE": "a", "MANGO": "m", "banana": "b"]]
		)

		let sorted = project.sortedSecrets(for: "default")
		#expect(sorted.count == 4)
		#expect(sorted[0].key == "APPLE")
		#expect(sorted[1].key == "banana")
		#expect(sorted[2].key == "MANGO")
		#expect(sorted[3].key == "ZEBRA")
	}

	@Test("sorted secrets use an exact-case tie breaker")
	func sortedSecretsCaseTieBreaker() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "",
			environments: ["default": ["Hey": "mixed", "HEY": "upper"]]
		)

		#expect(project.sortedSecrets.map(\.key) == ["HEY", "Hey"])
	}

	@Test("empty secrets returns empty array")
	func emptySortedSecrets() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: ["default": [:]]
		)

		#expect(project.sortedSecrets(for: "default").isEmpty)
	}

	@Test("secret count across environments")
	func secretCount() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: [
				"local": ["A": "1", "B": "2"],
				"live": ["A": "x", "C": "3"],
			]
		)

		#expect(project.secretCount == 4)  // total across all envs
		#expect(project.secretCount(for: "local") == 2)
		#expect(project.secretCount(for: "live") == 2)
	}

	@Test("environment names sorted")
	func environmentNames() {
		let project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: ["live": [:], "ci": [:], "local": [:]]
		)

		#expect(project.environmentNames == ["ci", "live", "local"])
	}

	@Test("backwards compatible secrets property uses default env")
	func backwardsCompatSecrets() {
		var project = VaultProject(
			id: "test-id",
			name: "test",
			path: "/tmp/test",
			environments: ["default": ["KEY": "val"]]
		)

		#expect(project.secrets["KEY"] == "val")

		project.secrets["NEW"] = "added"
		#expect(project.environments["default"]?["NEW"] == "added")
	}

	@Test("identifiable: same vault ID means same identity")
	func identifiable() {
		let a = VaultProject(id: "same-id", name: "A", path: "/a", environments: ["default": ["K": "V"]])
		let b = VaultProject(id: "same-id", name: "B", path: "/b", environments: [:])

		#expect(a.id == b.id)
	}

	@Test("identifiable: different vault ID means different identity")
	func differentIdentity() {
		let a = VaultProject(id: "id-1", name: "Same", path: "/a", environments: [:])
		let b = VaultProject(id: "id-2", name: "Same", path: "/a", environments: [:])

		#expect(a.id != b.id)
	}

	@Test("workspace key union is stable across dynamic environments")
	func workspaceKeyUnion() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["ZEBRA": "1", "ALPHA": "2"],
				"staging": ["MIDDLE": "3", "ALPHA": "4"],
			]
		)

		#expect(project.allSecretKeys == ["ALPHA", "MIDDLE", "ZEBRA"])
	}

	@Test("workspace derives drift only from differing stored values")
	func workspaceDrift() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["SAME": "value", "DIFF": "one", "LOCAL_ONLY": "local"],
				"staging": ["SAME": "value", "DIFF": "two"],
			]
		)

		#expect(!project.hasDrift(for: "SAME"))
		#expect(project.hasDrift(for: "DIFF"))
		#expect(!project.hasDrift(for: "LOCAL_ONLY"))
	}

	@Test("workspace derives missing keys across arbitrary environments")
	func workspaceMissing() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["EVERYWHERE": "one", "MISSING": "one"],
				"ci": ["EVERYWHERE": "two"],
				"production": ["EVERYWHERE": "three", "MISSING": "three"],
			]
		)

		#expect(!project.isMissingSomewhere("EVERYWHERE"))
		#expect(project.isMissingSomewhere("MISSING"))
		#expect(project.environmentCount(for: "MISSING") == 2)
	}

	@Test("workspace snapshot aggregates key status once")
	func workspaceSnapshot() {
		let project = VaultProject(
			id: "id",
			name: "project",
			path: "",
			environments: [
				"default": ["SAME": "one", "DIFF": "one", "MISSING": "one"],
				"staging": ["SAME": "one", "DIFF": "two"],
			]
		)
		let snapshot = VaultWorkspaceSnapshot(project: project)

		#expect(snapshot.allSecretKeys == ["DIFF", "MISSING", "SAME"])
		#expect(snapshot.driftingKeyCount == 1)
		#expect(snapshot.missingKeyCount == 1)
		#expect(snapshot.environmentCount(for: "MISSING") == 1)
	}
}

@Suite("VaultSecret Model")
struct VaultSecretTests {
	@Test("id is the key")
	func idIsKey() {
		let secret = VaultSecret(key: "API_KEY", value: "sk-123")
		#expect(secret.id == "API_KEY")
	}

	@Test("hashable: same key and value = equal")
	func hashable() {
		let a = VaultSecret(key: "KEY", value: "same")
		let b = VaultSecret(key: "KEY", value: "same")

		#expect(a == b)
		#expect(a.hashValue == b.hashValue)
	}

	@Test("hashable: different values = not equal")
	func hashableDifferentValues() {
		let a = VaultSecret(key: "KEY", value: "value1")
		let b = VaultSecret(key: "KEY", value: "value2")

		#expect(a != b)
	}
}
