import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import LPMVault

@Suite("Project CLI link")
struct ProjectCLILinkTests {
	private let vaultId = "7f3a1e2c-5b9d-4a8f-b6c1-9b1d2e3f4a5b"

	private func makeFolder() throws -> URL {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-vault-link-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder
	}

	private func writeConfig(_ contents: String, in folder: URL) throws {
		try Data(contents.utf8).write(to: folder.appendingPathComponent("lpm.json"))
	}

	private func readConfig(in folder: URL) throws -> [String: Any] {
		let data = try Data(contentsOf: folder.appendingPathComponent("lpm.json"))
		return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
	}

	@Test("a project without a folder on this Mac has no link")
	func noFolder() {
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: "") == .noFolder)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: "/nonexistent/\(UUID().uuidString)") == .noFolder)
		#expect(throws: ProjectCLILinkError.noFolder) { try ProjectCLILink.link(vaultId: vaultId, folder: "") }
	}

	@Test("a folder without lpm.json or without a vault field is not linked")
	func notLinked() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .notLinked)
		try writeConfig(#"{ "tasks": {} }"#, in: folder)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .notLinked)
	}

	@Test("matching and different vault IDs are reported")
	func linkedStates() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try writeConfig(#"{ "vault": "\#(vaultId)" }"#, in: folder)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .linked)
		try writeConfig(#"{ "vault": "other-vault" }"#, in: folder)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .linkedToOtherVault("other-vault"))
	}

	@Test("a null vault field is unset and can be linked without losing settings")
	func nullVaultCanBeLinked() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try writeConfig(#"{"vault":null,"custom":true}"#, in: folder)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .notLinked)
		try ProjectCLILink.link(vaultId: vaultId, folder: folder.path)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .linked)
		#expect(try readConfig(in: folder)["custom"] as? Bool == true)
	}

	@Test("linking requires explicit replacement when the folder already links another vault")
	func existingLinkRequiresReplacement() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let original = #"{"vault":"other-vault","custom":true}"#
		try writeConfig(original, in: folder)
		#expect(throws: ProjectCLILinkError.vaultChanged) { try ProjectCLILink.link(vaultId: vaultId, folder: folder.path) }
		#expect(try String(contentsOf: folder.appendingPathComponent("lpm.json"), encoding: .utf8) == original)
	}

	@Test("a replacement refuses a vault ID changed since inspection")
	func staleReplacementPreservesConfig() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let original = #"{"vault":"newer-vault","custom":true}"#
		try writeConfig(original, in: folder)
		#expect(throws: ProjectCLILinkError.vaultChanged) {
			try ProjectCLILink.link(vaultId: vaultId, folder: folder.path, replacingVaultId: "previous-vault")
		}
		#expect(try String(contentsOf: folder.appendingPathComponent("lpm.json"), encoding: .utf8) == original)
	}

	@Test("an explicit replacement leaves an invalid vault field untouched")
	func invalidReplacementPreservesConfig() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let original = #"{"vault":42,"custom":true}"#
		try writeConfig(original, in: folder)
		#expect(throws: ProjectCLILinkError.invalidJSON) {
			try ProjectCLILink.link(vaultId: vaultId, folder: folder.path, replacingVaultId: "previous-vault")
		}
		#expect(try String(contentsOf: folder.appendingPathComponent("lpm.json"), encoding: .utf8) == original)
	}

	@Test("a configuration changed while staging a replacement is preserved", arguments: [false, true])
	func concurrentReplacementPreservesConfig(initiallyPresent: Bool) throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let config = folder.appendingPathComponent("lpm.json")
		if initiallyPresent { try writeConfig(#"{"vault":"inspected-vault"}"#, in: folder) }
		let newer = Data(#"{"vault":"concurrent-vault","concurrentSetting":true}"#.utf8)
		#expect(throws: ProjectConfigFile.FileError.vaultChanged) {
			try ProjectConfigFile.writeVaultID(
				vaultId, to: config,
				policy: initiallyPresent ? .replacing("inspected-vault") : .unlinked,
				fileWriter: { data, destination, replaceExisting, validation in
					try SecureFileWriter.write(
						data, to: destination, permissions: 0o644, replaceExisting: replaceExisting,
						beforeReplacement: {
							try newer.write(to: destination, options: .atomic)
							try validation()
						}
					)
				}
			)
		}
		#expect(try Data(contentsOf: config) == newer)
		#expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["lpm.json"])
	}

	@Test("a new destination created at replacement time is never overwritten")
	func newlyCreatedConfigIsPreserved() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let config = folder.appendingPathComponent("lpm.json")
		let newer = Data(#"{"vault":"concurrent-vault"}"#.utf8)
		#expect(throws: SecureFileWriter.WriteError.replaceFailed(EEXIST)) {
			try SecureFileWriter.write(
				Data(#"{"vault":"app-vault"}"#.utf8), to: config,
				replaceExisting: false,
				beforeReplacement: { try newer.write(to: config) }
			)
		}
		#expect(try Data(contentsOf: config) == newer)
		#expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["lpm.json"])
	}

	@Test("malformed lpm.json and symbolic links are unreadable")
	func unreadable() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try writeConfig("{ not json", in: folder)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .unreadable)
		try writeConfig(#"{ "vault": 42 }"#, in: folder)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .unreadable)

		let target = folder.appendingPathComponent("real.json")
		try Data(#"{ "vault": "\#(vaultId)" }"#.utf8).write(to: target)
		try FileManager.default.removeItem(at: folder.appendingPathComponent("lpm.json"))
		try FileManager.default.createSymbolicLink(
			at: folder.appendingPathComponent("lpm.json"), withDestinationURL: target
		)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .unreadable)
		#expect(throws: ProjectCLILinkError.unsafeFile) { try ProjectCLILink.link(vaultId: vaultId, folder: folder.path) }
	}

	@Test("linking creates lpm.json when the folder has none")
	func linkCreatesConfig() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }

		try ProjectCLILink.link(vaultId: vaultId, folder: folder.path)
		#expect(try readConfig(in: folder)["vault"] as? String == vaultId)
		#expect(ProjectCLILink.status(vaultId: vaultId, folder: folder.path) == .linked)
	}

	@Test("linking replaces only the vault field and keeps other settings")
	func linkPreservesSettings() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try writeConfig(#"{ "vault": "other-vault", "tasks": { "dev": { "env": "development" } } }"#, in: folder)

		try ProjectCLILink.link(vaultId: vaultId, folder: folder.path, replacingVaultId: "other-vault")
		let config = try readConfig(in: folder)
		#expect(config["vault"] as? String == vaultId)
		#expect((config["tasks"] as? [String: Any])?["dev"] != nil)
	}

	@Test("linking leaves malformed lpm.json untouched")
	func linkRefusesMalformedConfig() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try writeConfig("{ not json", in: folder)

		#expect(throws: ProjectCLILinkError.invalidJSON) { try ProjectCLILink.link(vaultId: vaultId, folder: folder.path) }
		let contents = try String(contentsOf: folder.appendingPathComponent("lpm.json"), encoding: .utf8)
		#expect(contents == "{ not json")
	}
}

@Suite("Connect CLI rendering", .serialized)
@MainActor
struct ConnectCLIRenderingTests {
	private func makeStore(path: String) -> VaultStore {
		let environments: [String: [String: String]] = ["default": [:]]
		let keychain = MockKeychainService()
		keychain.envStorage["7f3a1e2c-5b9d-4a8f-b6c1-9b1d2e3f4a5b"] = (name: "my-api-server", path: path, environments: environments)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = [VaultProject(
			id: "7f3a1e2c-5b9d-4a8f-b6c1-9b1d2e3f4a5b",
			name: "my-api-server",
			path: path,
			environments: environments
		)]
		store.selectedProjectId = "7f3a1e2c-5b9d-4a8f-b6c1-9b1d2e3f4a5b"
		store.isUnlocked = true
		return store
	}

	@Test("the sheet shows the vault ID, lpm.json snippet, and terminal commands")
	func rendersSheet() throws {
		let store = makeStore(path: "")
		let text = try renderedText(
			of: ConnectCLISheet(store: store, projectId: "7f3a1e2c-5b9d-4a8f-b6c1-9b1d2e3f4a5b"),
			size: NSSize(width: 600, height: 560),
			named: "connect-cli-sheet.png"
		)

		for expected in [
			"Connect to the LPM CLI", "my-api-server", "Vault ID", "Copy", "Add it to your project",
			"Optional task environments", "lpm.json", "Copy JSON", "vault", "lpm env list", "lpm dev", "lpm run", "Docs", "Done",
		] {
			#expect(text.contains(expected), "missing \(expected)")
		}
	}

	@Test("the connection sheet explicitly selects the named environment")
	func rendersSelectedEnvironment() throws {
		let store = makeStore(path: "")
		store.projects[0].environments["staging"] = ["TOKEN": "dummy"]
		store.selectedEnvironment = "staging"
		let text = try renderedText(
			of: ConnectCLISheet(store: store, projectId: store.projects[0].id),
			size: NSSize(width: 600, height: 620),
			named: "connect-cli-staging.png"
		)
		#expect(text.contains("--env=staging"))
		#expect(text.contains("Run from the linked project folder"))
	}

	@Test("the title bar chip reads Connect CLI")
	func rendersTitleBarChip() throws {
		let store = makeStore(path: "")
		let text = try renderedText(
			of: VaultTitleBarView(store: store, mode: .matrix, onConnectCLI: {}, onPull: {}, onPush: {})
				.environment(UpdateChecker()),
			size: NSSize(width: 1040, height: VaultMetrics.titleBar),
			named: "title-bar-connect-cli.png"
		)

		#expect(text.contains("Connect CLI"))
		#expect(!text.contains("vault 7f3a1e2c"))
	}

	private func renderedText<V: View>(of view: V, size: NSSize, named name: String) throws -> OCRText {
		let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
		host.frame = NSRect(origin: .zero, size: size)
		host.layoutSubtreeIfNeeded()
		let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: bitmap)
		let image = try #require(bitmap.cgImage)
		let data = try #require(bitmap.representation(using: .png, properties: [:]))
		Attachment.record(data, named: name)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = false
		try VNImageRequestHandler(cgImage: image).perform([request])
		return OCRText((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
	}
}

@Suite("CLI environment commands")
struct ProjectCLICommandTests {
	@Test("commands explicitly select default instead of a script task mapping")
	func selectsDefault() {
		let guidance = ProjectCLICommands(environment: "default", configuration: .object([
			"tasks": .object(["dev": .object(["env": .string("production")])])
		]))
		#expect(guidance.commands == ["lpm env list --env=default", "lpm dev --env=default", "lpm run --env=default <script>"])
		#expect(guidance.warning == nil)
	}

	@Test("a redirecting alias withholds commands unless the canonical name is declared")
	func rejectsRedirectingAlias() {
		let alias = LPMJSONValue.object(["staging": .string(".env.production")])
		let redirected = ProjectCLICommands(environment: "staging", configuration: .object(["env": alias]))
		#expect(redirected.commands.isEmpty)
		#expect(redirected.warning?.contains("production") == true)
		let declared = ProjectCLICommands(environment: "staging", configuration: .object([
			"env": alias, "environments": .object(["staging": .object([:])])
		]))
		#expect(declared.commands.count == 3)
		#expect(declared.warning == nil)
	}

	@Test("unverified configuration warns without pretending the CLI is installed")
	func warnsWithoutConfiguration() {
		let guidance = ProjectCLICommands(environment: "staging", configuration: nil)
		#expect(guidance.commands.first == "lpm env list --env=staging")
		#expect(guidance.warning != nil)
	}

	@Test("invalid environment names never enter copied commands", arguments: ["a b", "a;echo", "$(id)", "../prod", "__index__", ""])
	func rejectsUnsafeCommands(environment: String) {
		#expect(ProjectCLICommands(environment: environment, configuration: nil).commands.isEmpty)
	}

	@Test("long and leading-hyphen names remain one flag value")
	func supportsPortableNames() {
		for name in [String(repeating: "a", count: 64), "-staging", "dev.local"] {
			#expect(ProjectCLICommands(environment: name, configuration: .object([:])).commands.first == "lpm env list --env=\(name)")
		}
	}
}

@Suite("CLI task environment examples")
struct ProjectCLITaskExampleTests {
	@Test("the optional example uses the vault's development and staging environments")
	func usesExistingEnvironments() throws {
		let example = try #require(ProjectCLITaskExample(vaultId: "vault-id", environments: ["default", "staging", "development"], selectedEnvironment: "default"))
		let object = try #require(try JSONSerialization.jsonObject(with: Data(example.json.utf8)) as? [String: Any])
		let tasks = try #require(object["tasks"] as? [String: [String: String]])
		#expect(object["vault"] as? String == "vault-id")
		#expect(tasks == ["dev": ["env": "development"], "start": ["env": "staging"]])
		#expect(example.json.split(separator: "\n").count == 7)
	}

	@Test("examples exclude environment names redirected by project aliases")
	func excludesRedirectingAliases() throws {
		let config = LPMJSONValue.object(["env": .object(["development": .string(".env.production")])])
		let example = try #require(ProjectCLITaskExample(vaultId: "id", environments: ["development", "staging"], selectedEnvironment: "development", configuration: config))
		let object = try #require(try JSONSerialization.jsonObject(with: Data(example.json.utf8)) as? [String: Any])
		#expect(object["tasks"] as? [String: [String: String]] == ["dev": ["env": "staging"], "start": ["env": "staging"]])
		#expect(example.warning == nil)
		let declared = LPMJSONValue.object(["env": .object(["development": .string(".env.production")]), "environments": .object(["development": .object([:])])])
		let canonical = try #require(ProjectCLITaskExample(vaultId: "id", environments: ["development"], selectedEnvironment: "development", configuration: declared))
		#expect(canonical.json.contains("development"))
		#expect(ProjectCLITaskExample(vaultId: "id", environments: ["development"], selectedEnvironment: "development", configuration: config) == nil)
		#expect(ProjectCLITaskExample(vaultId: "id", environments: ["default"], selectedEnvironment: "default")?.warning != nil)
	}

	@Test("the example never invents missing environments and escapes vault identifiers")
	func usesAvailableNames() throws {
		let example = try #require(ProjectCLITaskExample(vaultId: "a\"b", environments: ["qa", "default", "bad name"], selectedEnvironment: "qa"))
		let object = try #require(try JSONSerialization.jsonObject(with: Data(example.json.utf8)) as? [String: Any])
		#expect(object["vault"] as? String == "a\"b")
		#expect(object["tasks"] as? [String: [String: String]] == ["dev": ["env": "default"], "start": ["env": "qa"]])
		#expect(ProjectCLITaskExample(vaultId: "id", environments: ["bad name"], selectedEnvironment: "default") == nil)
		#expect(ProjectCLITaskExample(vaultId: "id", environments: ["qa", "alpha"], selectedEnvironment: "missing") == ProjectCLITaskExample(vaultId: "id", environments: ["alpha", "qa"], selectedEnvironment: "missing"))
	}
}

extension SheetInteractionTests {
	@Test("expanding and copying the optional task example does not write project settings")
	@MainActor
	func taskExampleIsOptional() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cli-example-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let original = Data(#"{"tasks":{"dev":{"command":"npm run dev","env":"qa"}},"custom":true}"#.utf8)
		let url = folder.appendingPathComponent("lpm.json")
		try original.write(to: url)
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(), apiService: MockAPIService())
		store.projects = [VaultProject(id: "example", name: "Example", path: folder.path, environments: ["development": [:], "staging": [:]])]
		store.isUnlocked = true
		store.selectedProjectId = "example"
		store.selectedEnvironment = "development"
		defer { store.lock() }
		let host = SheetTestHost(ConnectCLISheet(store: store, projectId: "example").environment(\.colorScheme, .light), size: NSSize(width: 600, height: 780), keepsRequestedSize: true, usesHostingView: true)
		defer { host.window.close() }
		#expect(try await !host.text().contains("Copy example"))
		try await host.click("Optional task environments")
		#expect(try await host.waitForText("Copy example"))
		try await host.click("Copy example")
		let copied = try #require(NSPasteboard.general.string(forType: .string))
		#expect(copied == ProjectCLITaskExample(vaultId: "example", environments: ["development", "staging"], selectedEnvironment: "development", configuration: ProjectConfigFile.readJSON(at: url))?.json)
		#expect(try Data(contentsOf: url) == original)
		try ProjectCLILink.link(vaultId: "example", folder: folder.path)
		let linked = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
		#expect(linked["tasks"] as? [String: [String: String]] == ["dev": ["command": "npm run dev", "env": "qa"]])
	}
}

extension SheetInteractionTests {
	@Test("an expanded task example fits a constrained sheet with visible footer actions")
	@MainActor
	func expandedExampleFitsShortWindow() async throws {
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(), apiService: MockAPIService())
		store.projects = [VaultProject(id: "example", name: "Example", path: "", environments: ["development": [:], "staging": [:]])]
		store.isUnlocked = true
		store.selectedProjectId = "example"
		defer { store.lock() }
		let host = SheetTestHost(ConnectCLISheet(store: store, projectId: "example", showsTaskExample: true).environment(\.colorScheme, .light), size: NSSize(width: 600, height: 620), keepsRequestedSize: true, usesHostingView: true)
		defer { host.window.close() }
		#expect(try await host.waitForText("Done", footer: 70))
		#expect(try await host.waitForText("Docs", footer: 70))
		try await host.click("Copy example")
		#expect(NSPasteboard.general.string(forType: .string)?.contains("tasks") == true)
	}
}
