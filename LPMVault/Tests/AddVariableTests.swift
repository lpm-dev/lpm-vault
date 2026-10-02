import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import LPMVault

/// Deterministic generator so format tests can pin exact output.
private struct SplitMix64: RandomNumberGenerator {
	var state: UInt64

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

@Suite("Secret value generator")
struct SecretValueGeneratorTests {
	@Test("base64 encodes the requested number of random bytes")
	func base64Length() throws {
		var rng = SplitMix64(state: 1)
		let value = SecretValueGenerator.generate(.base64, length: 32, using: &rng)
		#expect(value.count == 44)
		let decoded = try #require(Data(base64Encoded: value))
		#expect(decoded.count == 32)
	}

	@Test("hex emits two lowercase digits per byte")
	func hexLength() {
		var rng = SplitMix64(state: 2)
		let value = SecretValueGenerator.generate(.hex, length: 16, using: &rng)
		#expect(value.count == 32)
		#expect(value.allSatisfy { "0123456789abcdef".contains($0) })
	}

	@Test("UUIDs carry the version 4 and RFC variant bits", arguments: 0..<64)
	func uuidVersionBits(seed: UInt64) throws {
		var rng = SplitMix64(state: seed)
		let value = SecretValueGenerator.generate(.uuid, length: 99, using: &rng)
		let pattern = try Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
		#expect(value.wholeMatch(of: pattern) != nil)
		#expect(UUID(uuidString: value) != nil)
	}

	@Test("alphanumeric values use only letters and digits")
	func alphanumericCharset() {
		var rng = SplitMix64(state: 3)
		let value = SecretValueGenerator.generate(.alphanumeric, length: 200, using: &rng)
		#expect(value.count == 128)
		#expect(value.allSatisfy { SecretValueGenerator.alphanumericCharacters.contains($0) })
	}

	@Test("passwords include every character class from dotenv-safe sets", arguments: 0..<64)
	func passwordClasses(seed: UInt64) {
		var rng = SplitMix64(state: seed)
		let value = SecretValueGenerator.generate(.password, length: 16, using: &rng)
		let allowed = Set(SecretValueGenerator.alphanumericCharacters + SecretValueGenerator.passwordSymbols)
		#expect(value.count == 16)
		#expect(value.allSatisfy { allowed.contains($0) })
		#expect(value.contains { $0.isLowercase })
		#expect(value.contains { $0.isUppercase })
		#expect(value.contains { $0.isNumber })
		#expect(value.contains { SecretValueGenerator.passwordSymbols.contains($0) })
	}

	@Test("passwords shorter than the class count still honor the length")
	func shortPassword() {
		var rng = SplitMix64(state: 4)
		#expect(SecretValueGenerator.generate(.password, length: 3, using: &rng).count == 3)
	}

	@Test("lengths are clamped to the supported range")
	func lengthClamping() {
		var rng = SplitMix64(state: 5)
		#expect(SecretValueGenerator.generate(.hex, length: 0, using: &rng).count == 2)
		#expect(SecretValueGenerator.generate(.hex, length: 10_000, using: &rng).count == 256)
	}

	@Test("the system generator produces distinct values")
	func systemGeneratorIsRandom() {
		let values = Set((0..<32).map { _ in SecretValueGenerator.generate(.base64, length: 32) })
		#expect(values.count == 32)
	}

	@Test("length units match what each kind counts")
	func lengthUnits() {
		#expect(SecretValueKind.base64.lengthUnit == .bytes)
		#expect(SecretValueKind.hex.lengthUnit == .bytes)
		#expect(SecretValueKind.alphanumeric.lengthUnit == .characters)
		#expect(SecretValueKind.password.lengthUnit == .characters)
		#expect(SecretValueKind.uuid.lengthUnit == nil)
	}
}

@Suite("Add variable draft")
struct AddVariableDraftTests {
	private func makeDraft(selection: Set<String> = ["default"]) -> AddVariableDraft {
		AddVariableDraft(
			environments: ["default", "staging", "production"],
			secretsByEnvironment: [
				"default": ["API_URL": "local"],
				"staging": ["API_URL": "stg", "Token": "x"],
				"production": [:],
			],
			selection: selection
		)
	}

	@Test("submit title names one environment or counts several")
	func submitTitle() {
		var draft = makeDraft(selection: [])
		#expect(draft.submitTitle == "Add variable")
		draft.selection = ["staging"]
		#expect(draft.submitTitle == "Add to .env.staging")
		draft.selection = ["default", "production"]
		#expect(draft.submitTitle == "Add to 2 environments")
	}

	@Test("selection ignores environments the project does not have")
	func selectionIsIntersected() {
		let draft = makeDraft(selection: ["default", "preview"])
		#expect(draft.selection == ["default"])
	}

	@Test("existing keys are reported for selected environments in display order")
	func existingKeyIssue() {
		var draft = makeDraft(selection: ["staging", "default", "production"])
		draft.key = "API_URL"
		#expect(draft.keyIssue == .exists(environments: ["default", "staging"]))
		#expect(draft.keyIssue?.message == "Already exists in .env and .env.staging.")
		#expect(draft.conflicts(in: "default"))
		#expect(!draft.conflicts(in: "production"))
		#expect(!draft.canSubmit)
	}

	@Test("keys only present in unselected environments are allowed")
	func unselectedConflictIsAllowed() {
		var draft = makeDraft(selection: ["production"])
		draft.key = "API_URL"
		#expect(draft.keyIssue == nil)
		#expect(draft.canSubmit)
	}

	@Test("case-only collisions are rejected")
	func caseCollision() {
		var draft = makeDraft(selection: ["staging"])
		draft.key = "TOKEN"
		#expect(draft.keyIssue == .collides(existingKey: "Token", environment: "staging"))
		#expect(draft.conflicts(in: "staging"))
	}

	@Test("invalid names and empty selections cannot be submitted")
	func invalidInput() {
		var draft = makeDraft()
		draft.key = "1BAD"
		#expect(draft.keyIssue == .invalidName)
		#expect(!draft.canSubmit)
		draft.key = "GOOD"
		draft.selection = []
		#expect(draft.keyIssue == nil)
		#expect(!draft.canSubmit)
	}

	@Test("select all toggles between every environment and none")
	func toggleAll() {
		var draft = makeDraft()
		draft.toggleAll()
		#expect(draft.allSelected)
		draft.toggleAll()
		#expect(draft.selection.isEmpty)
	}
}

@Suite("Add variable to several environments", .serialized)
@MainActor
struct AddVariableStoreTests {
	private func makeStore() -> (VaultStore, MockKeychainService) {
		let environments: [String: [String: String]] = [
			"default": ["EXISTING": "1"],
			"staging": [:],
			"production": [:],
		]
		let keychain = MockKeychainService()
		keychain.envStorage["id-1"] = (name: "api", path: "/tmp/api", environments: environments)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			envFileImportService: MockEnvFileImportService(),
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)
		store.projects = [VaultProject(id: "id-1", name: "api", path: "/tmp/api", environments: environments)]
		store.isUnlocked = true
		return (store, keychain)
	}

	@Test("one Keychain write adds the value to every selected environment")
	func addsToSelectedEnvironments() async {
		let (store, keychain) = makeStore()

		let result = await store.addSecret(
			to: "id-1", environments: ["default", "staging"], key: "JWT_SECRET", value: "s3cret"
		)

		#expect(result == .success)
		#expect(keychain.updateEnvironmentsCallCount == 1)
		#expect(keychain.envStorage["id-1"]?.environments["default"] == ["EXISTING": "1", "JWT_SECRET": "s3cret"])
		#expect(keychain.envStorage["id-1"]?.environments["staging"] == ["JWT_SECRET": "s3cret"])
		#expect(keychain.envStorage["id-1"]?.environments["production"] == [:])
		#expect(store.projects[0].environments["staging"] == ["JWT_SECRET": "s3cret"])
	}

	@Test("a key that exists in one target leaves every environment unchanged")
	func duplicateInOneTargetAddsNothing() async {
		let (store, keychain) = makeStore()

		let result = await store.addSecret(
			to: "id-1", environments: ["default", "staging"], key: "EXISTING", value: "2"
		)

		#expect(result == .failure(.duplicate))
		#expect(keychain.updateEnvironmentsCallCount == 0)
		#expect(keychain.envStorage["id-1"]?.environments["staging"] == [:])
	}

	@Test("an empty selection is rejected before any write")
	func emptySelection() async {
		let (store, keychain) = makeStore()

		let result = await store.addSecret(to: "id-1", environments: [], key: "TOKEN", value: "x")

		#expect(result == .failure(.noEnvironments))
		#expect(keychain.updateEnvironmentsCallCount == 0)
	}

	@Test("an unknown environment is rejected before any write")
	func unknownEnvironment() async {
		let (store, keychain) = makeStore()

		let result = await store.addSecret(
			to: "id-1", environments: ["default", "preview"], key: "TOKEN", value: "x"
		)

		#expect(result == .failure(.targetUnavailable))
		#expect(keychain.updateEnvironmentsCallCount == 0)
	}

	@Test("a CLI write of the same key during the transaction aborts every environment")
	func concurrentCLIWriteAbortsAtomically() async {
		let (store, keychain) = makeStore()
		keychain.onGetEnvironments = {
			keychain.simulateCLISet(vaultId: "id-1", environment: "staging", key: "TOKEN", value: "cli")
		}

		let result = await store.addSecret(
			to: "id-1", environments: ["default", "staging"], key: "TOKEN", value: "vault"
		)

		#expect(result == .failure(.targetUnavailable))
		#expect(keychain.updateEnvironmentsCallCount == 0)
		#expect(keychain.envStorage["id-1"]?.environments["default"] == ["EXISTING": "1"])
		#expect(keychain.envStorage["id-1"]?.environments["staging"] == ["TOKEN": "cli"])
	}
}

@Suite("Add variable sheet rendering", .serialized)
@MainActor
struct AddVariableSheetRenderingTests {
	@Test("the sheet renders its fields, environments, and submit action")
	func rendersSheet() throws {
		let environments: [String: [String: String]] = ["default": [:], "staging": [:], "production": [:]]
		let keychain = MockKeychainService()
		keychain.envStorage["id-1"] = (name: "my-api-server", path: "/tmp/api", environments: environments)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = [VaultProject(id: "id-1", name: "my-api-server", path: "/tmp/api", environments: environments)]
		store.isUnlocked = true

		let text = try renderedText(
			of: AddVariableSheet(store: store, projectId: "id-1", environment: "staging"),
			size: NSSize(width: 560, height: 520),
			named: "add-variable-sheet.png"
		)

		for expected in ["Add variable", "my-api-server", "Key", "Value", "Generate", "Environments", ".env.staging", "adds and keeps the sheet open", "Cancel"] {
			#expect(text.contains(expected), "missing \(expected)")
		}
	}

	@Test("the generator panel lists every value kind")
	func rendersGeneratorPanel() throws {
		let text = try renderedText(
			of: SecretGeneratorPanel(kind: .constant(.base64), length: .constant(32), onGenerate: {}),
			size: NSSize(width: 300, height: 330),
			named: "secret-generator-panel.png"
		)

		for expected in ["GENERATE VALUE", "Base64 random", "openssl rand -base64 32", "Hexadecimal", "UUID v4", "Alphanumeric", "Password", "Length", "Regenerate"] {
			#expect(text.contains(expected), "missing \(expected)")
		}
	}

	private func renderedText<V: View>(of view: V, size: NSSize, named name: String) throws -> String {
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
		return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
	}
}
