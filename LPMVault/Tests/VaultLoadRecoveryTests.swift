import AppKit
import LocalAuthentication
import SwiftUI
import Testing
import Vision

@testable import LPMVault

@Suite("Vault load recovery", .serialized)
@MainActor
struct VaultLoadRecoveryTests {
	@Test("failed protected-state loading explains recovery on the locked screen")
	func unlockFailureIsVisible() async throws {
		let keychain = MockKeychainService()
		keychain.failProjectReads = true
		keychain.failureError = .keychainLocked
		let store = makeStore(keychain)
		await store.unlock()
		#expect(!store.isUnlocked)
		let text = try renderedText(ContentView(store: store))
		#expect(text.contains("Keychain is locked"))
		#expect(text.contains("Support"))
		keychain.failProjectReads = false
		await store.unlock()
		#expect(store.isUnlocked)
		#expect(store.unlockFailure == nil)
	}

	@Test("failed project loading offers retry instead of an empty vault")
	func projectFailureIsVisible() async throws {
		let keychain = MockKeychainService()
		keychain.failProjectReads = true
		keychain.failureError = .keychainLocked
		let store = makeStore(keychain)
		let project = VaultProject(id: "project", name: "Dummy", path: "", environments: ["default": ["TOKEN": "dummy-secret"]])
		keychain.envStorage["project"] = (name: project.name, path: project.path, environments: project.environments)
		store.projects = [VaultProject(metadata: project.metadata)]
		store.isUnlocked = true
		store.openProject(id: "project")
		while store.isLoadingSelectedProject { await Task.yield() }
		let text = try renderedText(ContentView(store: store).environment(UpdateChecker()))
		#expect(text.contains("Retry"))
		#expect(text.contains("Keychain is locked"))
		#expect(!text.contains("dummy-secret"))
		keychain.failProjectReads = false
		store.retrySelectedProjectLoad()
		while store.isLoadingSelectedProject { await Task.yield() }
		#expect(store.selectedProjectLoadFailure == nil)
		#expect(store.selectedProject?.secrets(for: "default")["TOKEN"] == "dummy-secret")
		store.lock()
		#expect(store.selectedProjectLoadFailure == nil)
		#expect(store.selectedProject?.hasLoadedEnvironments == false)
	}

	@Test("authentication cancellation clears a previous failure without reporting another")
	func cancellationIsQuiet() async {
		let biometric = MockBiometricService()
		biometric.shouldSucceed = false
		biometric.lastAuthenticationFailure = .failed
		let store = makeStore(MockKeychainService(), biometric: biometric)
		await store.unlock()
		#expect(store.unlockFailure == .authentication)
		biometric.lastAuthenticationFailure = nil
		await store.unlock()
		#expect(store.unlockFailure == nil)
		#expect(!store.isUnlocked)
		#expect(!store.isUnlocking)
	}

	@Test("native authentication cancellations stay quiet", arguments: [LAError.Code.userCancel, .appCancel, .systemCancel, .userFallback])
	func nativeCancellationIsQuiet(code: LAError.Code) {
		#expect(BiometricService.failure(for: NSError(domain: LAError.errorDomain, code: code.rawValue)) == nil)
	}

	@Test("native authentication failure is actionable without exposing native details")
	func nativeFailureIsActionable() {
		#expect(BiometricService.failure(for: NSError(domain: LAError.errorDomain, code: LAError.Code.authenticationFailed.rawValue)) == .failed)
		#expect(!VaultLoadFailure(.unexpectedStatus(-12345)).message.contains("12345"))
		#expect(VaultLoadFailure(.missingEntitlement) == .unsupportedBuild)
		#expect(VaultLoadFailure(.encodingFailed) == .invalidState)
	}

	private func makeStore(_ keychain: MockKeychainService, biometric: MockBiometricService = MockBiometricService()) -> VaultStore {
		VaultStore(keychainService: keychain, biometricService: biometric, apiService: MockAPIService())
	}

	private func renderedText<V: View>(_ view: V) throws -> OCRText {
		let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
		host.frame = NSRect(x: 0, y: 0, width: 1040, height: 640)
		host.layoutSubtreeIfNeeded()
		let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: bitmap)
		let image = try #require(bitmap.cgImage)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = false
		try VNImageRequestHandler(cgImage: image).perform([request])
		return OCRText((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
	}
}
