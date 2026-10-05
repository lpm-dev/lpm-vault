import AppKit
import LocalAuthentication
import SwiftUI
import Testing
import Vision

@testable import LPMVault

extension SheetInteractionTests {
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
			let text = try await renderedText(ContentView(store: store))
			#expect(text.contains("macOS did not allow Keychain access"))
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
			let text = try await renderedText(ContentView(store: store).environment(UpdateChecker()))
			#expect(text.contains("Retry"))
			#expect(text.contains("macOS did not allow Keychain access"))
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

		@Test("a failed refresh keeps showing why the selected project could not load", arguments: [true, false])
		func refreshFailureKeepsProjectRecovery(afterLoadFailure: Bool) async throws {
			let keychain = MockKeychainService()
			keychain.failProjectReads = true
			keychain.failureError = .keychainLocked
			let store = makeStore(keychain)
			let project = VaultProject(id: "project", name: "Dummy", path: "", environments: ["default": ["TOKEN": "dummy-secret"]])
			keychain.envStorage["project"] = (name: project.name, path: project.path, environments: project.environments)
			store.projects = [VaultProject(metadata: project.metadata)]
			store.isUnlocked = true
			store.openProject(id: "project")
			if afterLoadFailure {
				while store.isLoadingSelectedProject { await Task.yield() }
			}
			await store.refreshLocalState()
			#expect(store.localStateRefreshError != nil)
			let text = try await renderedText(ContentView(store: store).environment(UpdateChecker()))
			#expect(text.contains("macOS did not allow Keychain access"))
			#expect(!text.contains("Select an env project"))
			keychain.failProjectReads = false
			store.retrySelectedProjectLoad()
			await store.waitForLocalStateRefresh()
			while store.isLoadingSelectedProject { await Task.yield() }
			#expect(store.selectedProjectLoadFailure == nil)
			#expect(store.localStateRefreshError == nil)
			#expect(store.selectedProject?.secrets(for: "default")["TOKEN"] == "dummy-secret")
			store.lock()
		}

		@Test("project load failures do not become obsolete general alerts after navigation")
		func projectFailureOwnsItsPresentation() async {
			let keychain = MockKeychainService()
			keychain.failProjectReads = true
			keychain.failureError = .unexpectedStatus(-12345)
			keychain.envStorage["project"] = (name: "Dummy", path: "", environments: ["default": [:]])
			let store = makeStore(keychain)
			store.projects = [VaultProject(metadata: VaultProject(id: "project", name: "Dummy", path: "", environments: ["default": [:]]).metadata)]
			store.isUnlocked = true
			store.openProject(id: "project")
			while store.isLoadingSelectedProject { await Task.yield() }
			#expect(store.selectedProjectLoadFailure == .unavailable)
			#expect(store.error == nil)
			store.selectedProjectId = nil
			#expect(store.selectedProjectLoadFailure == nil)
			#expect(store.error == nil)
			store.lock()
		}

		@Test("retry preserves an independent operation error")
		func retryPreservesIndependentError() async {
			let keychain = MockKeychainService()
			keychain.failProjectReads = true
			keychain.envStorage["project"] = (name: "Dummy", path: "", environments: ["default": [:]])
			let store = makeStore(keychain)
			store.projects = [VaultProject(metadata: VaultProject(id: "project", name: "Dummy", path: "", environments: ["default": [:]]).metadata)]
			store.isUnlocked = true
			store.openProject(id: "project")
			while store.isLoadingSelectedProject { await Task.yield() }
			store.error = "Could not clear the shared LPM session."
			keychain.failProjectReads = false
			store.retrySelectedProjectLoad()
			#expect(store.error == "Could not clear the shared LPM session.")
			while store.isLoadingSelectedProject { await Task.yield() }
			#expect(store.selectedProjectLoadFailure == nil)
			#expect(store.error == "Could not clear the shared LPM session.")
			store.lock()
		}

		@Test("authentication cancellation clears a previous failure without reporting another")
		func cancellationIsQuiet() async {
			let biometric = MockBiometricService()
			biometric.shouldSucceed = false
			biometric.failureOutcome = .failed
			let store = makeStore(MockKeychainService(), biometric: biometric)
			await store.unlock()
			#expect(store.unlockFailure == .authentication)
			biometric.failureOutcome = .cancelled
			await store.unlock()
			#expect(store.unlockFailure == nil)
			#expect(!store.isUnlocked)
			#expect(!store.isUnlocking)
		}

		@Test("native authentication cancellations stay quiet", arguments: [LAError.Code.userCancel, .appCancel, .systemCancel, .userFallback])
		func nativeCancellationIsQuiet(code: LAError.Code) {
			#expect(BiometricService.outcome(for: NSError(domain: LAError.errorDomain, code: code.rawValue)) == .cancelled)
		}

		@Test("recovery messages distinguish macOS authentication from Keychain access")
		func recoveryMessagesNameTheSystem() {
			#expect(VaultLoadFailure.keychainLocked.message == "macOS did not allow Keychain access. Unlock your Mac and retry. If access still fails, check your login Keychain.")
			#expect(VaultLoadFailure.authentication.message == "Could not authenticate with macOS. Try Touch ID or your Mac login password again.")
		}

		@Test("native authentication failure is actionable without exposing native details")
		func nativeFailureIsActionable() {
			#expect(BiometricService.outcome(for: NSError(domain: LAError.errorDomain, code: LAError.Code.authenticationFailed.rawValue)) == .failed)
			#expect(!VaultLoadFailure(.unexpectedStatus(-12345)).message.contains("12345"))
			#expect(VaultLoadFailure(.missingEntitlement) == .unsupportedBuild)
			#expect(VaultLoadFailure(.encodingFailed) == .invalidState)
		}

		private func makeStore(_ keychain: MockKeychainService, biometric: MockBiometricService = MockBiometricService()) -> VaultStore {
			VaultStore(keychainService: keychain, biometricService: biometric, apiService: MockAPIService())
		}

		private func renderedText<V: View>(_ view: V) async throws -> OCRText {
			let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
			host.frame = NSRect(x: 0, y: 0, width: 1040, height: 640)
			host.layoutSubtreeIfNeeded()
			let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
			host.cacheDisplay(in: host.bounds, to: bitmap)
			let image = try #require(bitmap.cgImage)
			let lines = try await RenderedText.lines(in: image, level: .accurate)
			return OCRText(lines.map(\.text).joined(separator: "\n"))
		}
	}
}
