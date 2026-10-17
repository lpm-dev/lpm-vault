import Foundation
import os
import Testing

@testable import LPMVault

@Suite("Writes quitting waits for")
@MainActor
struct VaultWritesTests {
	@Test("with nothing running, finishing returns at once")
	func nothingRunning() async {
		let writes = VaultWrites()
		#expect(await writes.finish(within: .zero))
		writes.end(writes.begin())
		#expect(!writes.isWriting)
		#expect(await writes.finish(within: .zero))
	}

	@Test("finishing waits for the last running write, and ending a write twice doesn't end another")
	func waitsForTheLast() async throws {
		let writes = VaultWrites()
		let first = writes.begin(), second = writes.begin()
		let finished = Task { await writes.finish(within: testWaitLimit) }
		writes.end(first)
		writes.end(first)
		#expect(writes.isWriting)
		try #require(try await waitUntil { writes.hasWaiters })
		writes.end(second)
		#expect(await finished.value)
	}

	@Test("finishing gives up when its time runs out or its task is cancelled, and the write still ends later")
	func givesUp() async throws {
		let writes = VaultWrites()
		let write = writes.begin()
		#expect(await !writes.finish(within: .milliseconds(20)))
		let waiting = Task { await writes.finish(within: testWaitLimit) }
		try #require(try await waitUntil { writes.hasWaiters })
		waiting.cancel()
		#expect(await !waiting.value)
		writes.end(write)
		#expect(await writes.finish(within: .zero))
	}

	enum Kind: String, CaseIterable {
		case addSecret, addEnvironment, createProject, deleteProject, saveKey
	}

	@Test("quitting waits for every write to the Keychain, not only key saves", arguments: Kind.allCases)
	func storeWaitsForEveryWrite(_ kind: Kind) async throws {
		let keychain = MockKeychainService()
		keychain.envStorage["first"] = (name: "First", path: "", environments: ["default": ["TOKEN": "one"]])
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		#expect(await store.loadProjects())
		store.isUnlocked = true
		#expect(await store.openProjectForSaving("first", timeout: testWaitLimit))
		defer { store.lock() }
		let project = try #require(store.projects.first { $0.id == "first" })
		let entered = OSAllocatedUnfairLock(initialState: false), release = DispatchSemaphore(value: 0)
		keychain.blockNextVaultTransaction = {
			entered.withLock { $0 = true }
			release.wait()
		}
		if kind == .saveKey { store.keyDrafts.edit(project, key: "TOKEN") { $0.setValue("two", in: "default") } }
		let write = Task { () -> Bool in
			switch kind {
			case .addSecret: return await store.addSecret(to: "first", environment: "default", key: "ADDED", value: "v") == .success
			case .addEnvironment: return await store.addEnvironment(to: "first", name: "staging")
			case .createProject: return await store.addProjectWithVaultId(vaultId: "third", name: "Third", environments: ["default": [:]])
			case .deleteProject: return await store.deleteLocalVault(project)
			case .saveKey:
				do {
					try await store.saveKeyDraft(.init(projectID: "first", key: "TOKEN"))
					return true
				} catch {
					return false
				}
			}
		}
		guard try await waitUntil({ entered.withLock { $0 } }) else {
			release.signal()
			Issue.record("\(kind) never reached the Keychain")
			return
		}
		#expect(await !store.finishWritesInProgress(within: .milliseconds(100)), "\(kind) is still being written")
		release.signal()
		#expect(await store.finishWritesInProgress(within: testWaitLimit))
		#expect(await write.value)
	}
}
