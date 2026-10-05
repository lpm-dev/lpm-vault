import Foundation
import Testing

@testable import LPMVault

@Suite("Environment schema scopes", .serialized)
@MainActor
struct EnvSchemaScopeTests {
	@Test("schema sync uses the remembered CLI folder", arguments: [false, true])
	func schemaSyncUsesRememberedFolder(emptyPath: Bool) async throws {
		let folder = FileManager.default.temporaryDirectory.appending(
			path: "env-schema-folder-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try #"{"vault":"project","envSchema":{"vars":{"VALUE":{"description":"Remembered"}}}}"#.write(
			to: folder.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
		let suite = "env-schema-preferences-\(UUID().uuidString)"
		let preferences = try #require(UserDefaults(suiteName: suite))
		defer { preferences.removePersistentDomain(forName: suite) }
		ProjectCLILink.rememberFolder(folder.path, vaultId: "project", defaults: preferences)
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), preferences: preferences,
			authTokenProvider: { _, _ in "session" }, authSessionClearer: { _ in })
		let project = VaultProject(
			id: "project", name: "Project", path: emptyPath ? "" : "/nonexistent/old-folder",
			environments: ["default": [:]])
		let schema = try await store.syncSchema(for: project)
		let value = try #require(schema)
		let wire = try LPMConfigJSON(parsing: JSONEncoder().encode(value))
		#expect(wire["envSchema"]?["VALUE"]?["description"] == .string("Remembered"))
		try #"{"vault":"other","envSchema":{"vars":{"VALUE":{}}}}"#.write(
			to: folder.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
		await #expect(throws: ProjectEnvSchemaFile.FileError.linkedToOtherVault) {
			_ = try await store.syncSchema(for: project)
		}
	}
}
