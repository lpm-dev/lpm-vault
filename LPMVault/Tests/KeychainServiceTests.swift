import Foundation
import Testing

@testable import LPMVault

/// These tests use a unique service name to avoid polluting the real Keychain.
/// Each test creates and cleans up its own Keychain items.
@Suite("KeychainService — Real Keychain Integration", .serialized)
struct KeychainServiceTests {
	private func makeService() -> KeychainService {
		KeychainService(service: "dev.lpm.vault.test.\(UUID().uuidString)")
	}

	private func cleanup(service: KeychainService, vaultIds: [String]) {
		for id in vaultIds {
			_ = service.deleteProject(vaultId: id)
		}
	}

	// MARK: - CRUD

	@Test("round-trip: save then read returns same secrets")
	func roundTrip() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let secrets = ["DB_HOST": "localhost", "API_KEY": "sk-123", "PORT": "3000"]

		let result = service.saveSecrets(
			vaultId: vaultId,
			projectName: "test-project",
			projectPath: "/tmp/test-project",
			secrets: secrets
		)

		guard case .success = result else {
			Issue.record("Save failed: \(result)")
			return
		}

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == secrets)
	}

	@Test("update overwrites existing secrets")
	func update() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		// Create
		_ = service.saveSecrets(
			vaultId: vaultId,
			projectName: "project",
			projectPath: "/tmp/p",
			secrets: ["KEY": "old-value"]
		)

		// Update
		let result = service.saveSecrets(
			vaultId: vaultId,
			projectName: "project-renamed",
			projectPath: "/tmp/p-new",
			secrets: ["KEY": "new-value", "NEW_KEY": "added"]
		)

		guard case .success = result else {
			Issue.record("Update failed: \(result)")
			return
		}

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved?["KEY"] == "new-value")
		#expect(retrieved?["NEW_KEY"] == "added")
	}

	@Test("delete removes item")
	func delete() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"

		// Create
		_ = service.saveSecrets(
			vaultId: vaultId,
			projectName: "to-delete",
			projectPath: "/tmp/d",
			secrets: ["KEY": "val"]
		)

		// Delete
		let deleted = service.deleteProject(vaultId: vaultId)
		#expect(deleted == true)

		// Verify gone
		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == nil)
	}

	@Test("delete non-existent item returns true (idempotent)")
	func deleteNonExistent() {
		let service = makeService()
		let deleted = service.deleteProject(vaultId: "nonexistent-\(UUID().uuidString)")
		#expect(deleted == true)
	}

	@Test("get non-existent vault returns nil")
	func getNonExistent() {
		let service = makeService()
		let result = service.getSecrets(vaultId: "nonexistent-\(UUID().uuidString)")
		#expect(result == nil)
	}

	// MARK: - List

	@Test("list projects returns all vault items")
	func listProjects() {
		// Isolated service to avoid race conditions with parallel tests sharing the index
		let isolatedService = KeychainService(
			service: "dev.lpm.vault.list.\(UUID().uuidString.prefix(8))")
		let id1 = "list-\(UUID().uuidString.prefix(8))"
		let id2 = "list-\(UUID().uuidString.prefix(8))"
		defer {
			_ = isolatedService.deleteProject(vaultId: id1)
			_ = isolatedService.deleteProject(vaultId: id2)
		}

		_ = isolatedService.saveSecrets(
			vaultId: id1,
			projectName: "project-alpha",
			projectPath: "/tmp/alpha",
			secrets: ["A": "1"]
		)
		_ = isolatedService.saveSecrets(
			vaultId: id2,
			projectName: "project-beta",
			projectPath: "/tmp/beta",
			secrets: ["B": "2"]
		)

		let projects = isolatedService.listProjects()

		#expect(projects.count == 2)

		let alpha = projects.first { $0.id == id1 }
		#expect(alpha?.name == "project-alpha")
		#expect(alpha?.path == "/tmp/alpha")
		#expect(alpha?.secrets == ["A": "1"])

		let beta = projects.first { $0.id == id2 }
		#expect(beta?.name == "project-beta")
		#expect(beta?.secrets == ["B": "2"])
	}

	@Test("list projects when empty returns empty array")
	func listEmpty() {
		// Use a unique service that definitely has no items
		let service = KeychainService(
			service: "dev.lpm.vault.empty.\(UUID().uuidString.prefix(8))")
		let projects = service.listProjects()
		#expect(projects.isEmpty)
	}

	// MARK: - Edge Cases

	@Test("empty secrets dictionary is valid")
	func emptySecrets() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let result = service.saveSecrets(
			vaultId: vaultId,
			projectName: "empty-project",
			projectPath: "/tmp/empty",
			secrets: [:]
		)

		guard case .success = result else {
			Issue.record("Save empty secrets failed")
			return
		}

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == [:])
	}

	@Test("secrets with special characters preserved")
	func specialCharacters() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let secrets = [
			"URL": "postgres://user:p@ss=w0rd@host:5432/db?ssl=true&timeout=30",
			"JSON": "{\"key\": \"value\", \"nested\": {\"a\": 1}}",
			"MULTILINE": "line1\nline2\nline3",
			"UNICODE": "hello \u{1F512} world \u{00E9}\u{00E8}\u{00EA}",
		]

		_ = service.saveSecrets(
			vaultId: vaultId,
			projectName: "special",
			projectPath: "/tmp/special",
			secrets: secrets
		)

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == secrets)
	}
}
