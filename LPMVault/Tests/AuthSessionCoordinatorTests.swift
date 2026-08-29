import Foundation
import Testing

@testable import LPMVault

@Suite("Cross-process auth session coordination", .serialized)
struct AuthSessionCoordinatorTests {
	private let registryURL = "https://lpm.dev"
	private let baseURL = URL(string: "https://lpm.dev")!
	private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

	@Test("session commit stores refresh first and writes Rust-compatible metadata")
	func refreshFirstCommit() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let coordinator = makeCoordinator(home: home, backend: backend)
		let credentials = session(
			access: "access-one",
			refresh: "refresh-one",
			expiresAt: fixedNow.addingTimeInterval(3_600)
		)

		try await coordinator.persist(credentials, registryURL: registryURL)

		#expect(backend.writeAccounts == [
			AuthSessionStore.scopedRefreshAccount(registryURL: registryURL),
			AuthSessionStore.scopedAccessAccount(registryURL: registryURL),
		])
		let authority = try jsonObject(
			at: home.appendingPathComponent(".lpm/.credential-authority.json")
		)
		#expect(authority["version"] as? Int == 1)
		let records = try #require(authority["credentials"] as? [String: [String: Any]])
		let refreshID = try #require(
			AuthSessionStore.authorityID(kind: "refresh", registryURL: registryURL)
		)
		let accessID = try #require(
			AuthSessionStore.authorityID(kind: "access", registryURL: registryURL)
		)
		#expect(records[refreshID]?["state"] as? String == "active")
		#expect(records[refreshID]?["backend"] as? String == "keychain")
		#expect(records[refreshID]?["stale_file_cleanup_pending"] as? Bool == false)
		#expect(records[accessID]?["state"] as? String == "active")

		let expiries = try jsonObject(
			at: home.appendingPathComponent(".lpm/.token-expiry.json")
		)
		let record = try #require(expiries[registryURL] as? [String: Any])
		#expect(record["session_access_expires_at"] as? String == credentials.expiresAt)
		#expect(record["otp_required"] as? Bool == false)
	}

	@Test("server RFC 3339 expiry with milliseconds is accepted")
	func fractionalSecondExpiryIsAccepted() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let coordinator = makeCoordinator(home: home, backend: backend)
		let credentials = AuthSessionCredentials(
			token: "access-one",
			refreshToken: "refresh-one",
			expiresIn: 3_600,
			expiresAt: "2030-08-22T12:00:00.000Z"
		)

		try await coordinator.persist(credentials, registryURL: registryURL)

		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == "refresh-one"
		)
	}

	@Test("whitespace-only credentials are rejected before storage")
	func whitespaceCredentialIsRejected() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let coordinator = makeCoordinator(home: home, backend: backend)
		let credentials = AuthSessionCredentials(
			token: "   ",
			refreshToken: "refresh-one",
			expiresIn: 3_600,
			expiresAt: ISO8601DateFormatter().string(
				from: fixedNow.addingTimeInterval(3_600)
			)
		)

		await #expect(throws: AuthSessionCoordinatorError.self) {
			try await coordinator.persist(credentials, registryURL: registryURL)
		}
		#expect(backend.writeAccounts.isEmpty)
	}

	@Test("concurrent coordinators perform one refresh and reuse the peer rotation")
	func concurrentRefreshIsSingleFlight() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)

		let gate = ControlledRefresh(
			credentials: session(
				access: "access-rotated",
				refresh: "refresh-rotated",
				expiresAt: fixedNow.addingTimeInterval(3_600)
			)
		)
		let firstCoordinator = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { token, _, _ in try await gate.rotate(token: token) }
		)
		let secondCoordinator = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { token, _, _ in try await gate.rotate(token: token) }
		)

		let first = Task {
			try await firstCoordinator.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		await gate.waitUntilEntered()
		let second = Task {
			try await secondCoordinator.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		try await Task.sleep(for: .milliseconds(50))
		await gate.release()

		let values = try await [first.value, second.value]
		#expect(values == ["access-rotated", "access-rotated"])
		#expect(await gate.callCount == 1)
	}

	@Test("a consumed refresh rotation reports persistence failure")
	func refreshPersistenceFailureIsPropagated() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		backend.failWrites(
			to: AuthSessionStore.scopedAccessAccount(registryURL: registryURL)
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { refreshToken, _, _ in
				if refreshToken == "refresh-old" {
					return self.session(
						access: "access-rotated",
						refresh: "refresh-rotated",
						expiresAt: self.fixedNow.addingTimeInterval(3_600)
					)
				}
				return self.session(
					access: "access-recovered",
					refresh: "refresh-recovered",
					expiresAt: self.fixedNow.addingTimeInterval(3_600)
				)
			}
		)

		await #expect(throws: TestCredentialBackendError.self) {
			try await subject.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == "refresh-rotated"
		)

		backend.allowWrites(
			to: AuthSessionStore.scopedAccessAccount(registryURL: registryURL)
		)
		let recovered = try await subject.currentAccessToken(
			registryURL: registryURL,
			baseURL: baseURL
		)
		#expect(recovered == "access-recovered")
	}

	@Test("a refresh response cannot reuse the consumed refresh credential")
	func reusedRefreshCredentialIsRejected() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { _, _, _ in
				self.session(
					access: "access-new",
					refresh: "refresh-old",
					expiresAt: self.fixedNow.addingTimeInterval(3_600)
				)
			}
		)

		await #expect(throws: AuthSessionCoordinatorError.self) {
			try await subject.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
	}

	@Test("a transient refresh failure may reuse an unexpired access credential")
	func transientRefreshFailureUsesUnexpiredAccess() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { _, _, _ in throw AuthSessionRefreshError.transport }
		)

		let access = try await subject.currentAccessToken(
			registryURL: registryURL,
			baseURL: baseURL
		)

		#expect(access == "access-old")
	}

	@Test("a transient refresh failure without usable access is reported")
	func transientRefreshFailureWithoutAccessIsPropagated() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.writeCredentialWithoutSessionLockForTesting(
			"refresh-only",
			kind: "refresh",
			registryURL: registryURL
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { _, _, _ in throw AuthSessionRefreshError.transport }
		)

		await #expect(throws: AuthSessionRefreshError.self) {
			try await subject.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
	}

	@Test("caller cancellation waits for an accepted rotation to become durable")
	func cancellationAfterRefreshDispatchPersistsRotation() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		let gate = ControlledRefresh(
			credentials: session(
				access: "access-rotated",
				refresh: "refresh-rotated",
				expiresAt: fixedNow.addingTimeInterval(3_600)
			)
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { token, _, _ in try await gate.rotate(token: token) }
		)
		let refresh = Task {
			try await subject.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		await gate.waitUntilEntered()

		refresh.cancel()
		await gate.release()

		await #expect(throws: CancellationError.self) { try await refresh.value }
		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == "refresh-rotated"
		)
		#expect(
			backend.value(
				for: AuthSessionStore.scopedAccessAccount(registryURL: registryURL)
			) == "access-rotated"
		)
	}

	@Test("a rejected old refresh cannot erase credentials replaced in flight")
	func rejectedRefreshPreservesPeerRotation() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let peer = makeCoordinator(home: home, backend: backend)
		try await peer.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		let peerCredentials = session(
			access: "access-peer",
			refresh: "refresh-peer",
			expiresAt: fixedNow.addingTimeInterval(3_600)
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { _, _, _ in
				try await peer.persistWithoutSessionLockForTesting(
					peerCredentials,
					registryURL: registryURL
				)
				throw AuthSessionRefreshError.rejected
			}
		)

		let rejectedResult = try await subject.currentAccessToken(
			registryURL: registryURL,
			baseURL: baseURL
		)
		let survivingResult = try await peer.currentAccessToken(
			registryURL: registryURL,
			baseURL: baseURL
		)

		#expect(rejectedResult == nil)
		#expect(survivingResult == "access-peer")
		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == "refresh-peer"
		)
	}

	@Test("logout waits for an in-flight refresh and removes its rotation")
	func logoutWaitsForRefresh() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		let gate = ControlledRefresh(
			credentials: session(
				access: "access-rotated",
				refresh: "refresh-rotated",
				expiresAt: fixedNow.addingTimeInterval(3_600)
			)
		)
		let refresher = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { token, _, _ in try await gate.rotate(token: token) }
		)
		let refresh = Task {
			try await refresher.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		await gate.waitUntilEntered()
		let logout = Task {
			try await bootstrap.clear(registryURL: registryURL)
		}
		try await Task.sleep(for: .milliseconds(50))

		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == "refresh-old"
		)
		await gate.release()
		#expect(try await refresh.value == "access-rotated")
		try await logout.value

		#expect(
			backend.value(
				for: AuthSessionStore.scopedAccessAccount(registryURL: registryURL)
			) == nil
		)
		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == nil
		)
	}

	@Test("a refresh-only partial peer commit is recovered without using the predecessor")
	func refreshOnlyPartialCommitRecovers() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let peer = makeCoordinator(home: home, backend: backend)
		try await peer.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		try await peer.writeCredentialWithoutSessionLockForTesting(
			"refresh-partial",
			kind: "refresh",
			registryURL: registryURL
		)

		let recorder = RefreshTokenRecorder(
			credentials: session(
				access: "access-recovered",
				refresh: "refresh-recovered",
				expiresAt: fixedNow.addingTimeInterval(3_600)
			)
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { token, _, _ in await recorder.rotate(token: token) }
		)

		let result = try await subject.currentAccessToken(
			registryURL: registryURL,
			baseURL: baseURL
		)

		#expect(result == "access-recovered")
		#expect(await recorder.tokens == ["refresh-partial"])
	}

	@Test("a rejected current refresh revokes exactly the submitted session")
	func rejectedCurrentRefreshIsCleared() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-rejected",
				refresh: "refresh-rejected",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { token, _, _ in
				#expect(token == "refresh-rejected")
				throw AuthSessionRefreshError.rejected
			}
		)

		let result = try await subject.currentAccessToken(
			registryURL: registryURL,
			baseURL: baseURL
		)

		#expect(result == nil)
		#expect(
			backend.value(
				for: AuthSessionStore.scopedAccessAccount(registryURL: registryURL)
			) == nil
		)
		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == nil
		)
		let expiries = try jsonObject(
			at: home.appendingPathComponent(".lpm/.token-expiry.json")
		)
		#expect(expiries[registryURL] == nil)
	}

	@Test("rejected-session expiry cleanup remains inside the credential transaction")
	func rejectedSessionCleanupRetainsCredentialLock() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let bootstrap = makeCoordinator(home: home, backend: backend)
		try await bootstrap.persist(
			session(
				access: "access-rejected",
				refresh: "refresh-rejected",
				expiresAt: fixedNow.addingTimeInterval(60)
			),
			registryURL: registryURL
		)
		let expiryControl = LockBodyControl()
		let expiryLockURL = home.appendingPathComponent(".lpm/.token-expiry.lock")
		let expiryHolder = Task {
			try await CrossProcessFileLock.withExclusive(at: expiryLockURL) {
				await expiryControl.hold()
			}
		}
		await expiryControl.waitUntilEntered()
		let subject = makeCoordinator(
			home: home,
			backend: backend,
			refresh: { _, _, _ in throw AuthSessionRefreshError.rejected }
		)
		let rejection = Task {
			try await subject.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		let credentialLockURL = subject.sessionLockURL(
			registryURL: "lpm-auth://credential-store"
		)
		var observedCredentialLock = false
		for _ in 0..<100 {
			if try independentExclusiveLockStatus(at: credentialLockURL) == 42 {
				observedCredentialLock = true
				break
			}
			try await Task.sleep(for: .milliseconds(5))
		}
		guard observedCredentialLock else {
			await expiryControl.release()
			try await expiryHolder.value
			_ = try await rejection.value
			Issue.record("Rejected-session cleanup never acquired the credential-store lock.")
			return
		}
		try await Task.sleep(for: .milliseconds(30))

		#expect(try independentExclusiveLockStatus(at: credentialLockURL) == 42)
		await expiryControl.release()
		try await expiryHolder.value
		#expect(try await rejection.value == nil)
	}

	@Test("corrupt expiry metadata blocks a new commit before any credential write")
	func corruptMetadataFailsClosed() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let coordinator = makeCoordinator(home: home, backend: backend)
		try await coordinator.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(3_600)
			),
			registryURL: registryURL
		)
		backend.resetWriteLog()
		try Data("not-json".utf8).write(
			to: home.appendingPathComponent(".lpm/.token-expiry.json")
		)

		var failed = false
		do {
			try await coordinator.persist(
				session(
					access: "access-new",
					refresh: "refresh-new",
					expiresAt: fixedNow.addingTimeInterval(7_200)
				),
				registryURL: registryURL
			)
		} catch {
			failed = true
		}

		#expect(failed)
		#expect(backend.writeAccounts.isEmpty)
		#expect(
			backend.value(
				for: AuthSessionStore.scopedRefreshAccount(registryURL: registryURL)
			) == "refresh-old"
		)
	}

	@Test("logout revokes authority so an opaque Rust fallback cannot resurrect")
	func logoutRevokesOpaqueFallback() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let lpmDirectory = home.appendingPathComponent(".lpm")
		try FileManager.default.createDirectory(
			at: lpmDirectory,
			withIntermediateDirectories: true
		)
		try Data("opaque-encrypted-rust-store".utf8).write(
			to: lpmDirectory.appendingPathComponent(".credentials")
		)
		let backend = MemoryAuthCredentialBackend()
		let coordinator = makeCoordinator(home: home, backend: backend)
		try await coordinator.persist(
			session(
				access: "access-old",
				refresh: "refresh-old",
				expiresAt: fixedNow.addingTimeInterval(3_600)
			),
			registryURL: registryURL
		)

		let activeAuthority = try jsonObject(
			at: lpmDirectory.appendingPathComponent(".credential-authority.json")
		)
		let activeRecords = try #require(
			activeAuthority["credentials"] as? [String: [String: Any]]
		)
		let refreshID = try #require(
			AuthSessionStore.authorityID(kind: "refresh", registryURL: registryURL)
		)
		#expect(
			activeRecords[refreshID]?["stale_file_cleanup_pending"] as? Bool == true
		)

		try await coordinator.clear(registryURL: registryURL)

		let revokedAuthority = try jsonObject(
			at: lpmDirectory.appendingPathComponent(".credential-authority.json")
		)
		let revokedRecords = try #require(
			revokedAuthority["credentials"] as? [String: [String: Any]]
		)
		let accessID = try #require(
			AuthSessionStore.authorityID(kind: "access", registryURL: registryURL)
		)
		#expect(revokedRecords[accessID]?["state"] as? String == "revoked")
		#expect(revokedRecords[refreshID]?["state"] as? String == "revoked")
		#expect(
			backend.value(
				for: AuthSessionStore.scopedAccessAccount(registryURL: registryURL)
			) == nil
		)
		#expect(
			try await coordinator.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			) == nil
		)
	}

	@Test("an unclassified scoped Keychain credential is not promoted over an opaque fallback")
	func opaqueFallbackBlocksScopedCredentialPromotion() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let lpmDirectory = home.appendingPathComponent(".lpm")
		try FileManager.default.createDirectory(
			at: lpmDirectory,
			withIntermediateDirectories: true
		)
		try Data("opaque-encrypted-rust-store".utf8).write(
			to: lpmDirectory.appendingPathComponent(".credentials")
		)
		let backend = MemoryAuthCredentialBackend()
		try backend.write(
			"keychain-access",
			account: AuthSessionStore.scopedAccessAccount(registryURL: registryURL)
		)
		let coordinator = makeCoordinator(home: home, backend: backend)

		await #expect(throws: AuthSessionCoordinatorError.self) {
			try await coordinator.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		#expect(
			!FileManager.default.fileExists(
				atPath: lpmDirectory.appendingPathComponent(
					".credential-authority.json"
				).path
			)
		)
	}

	@Test("an unclassified legacy Keychain credential is not promoted over an opaque fallback")
	func opaqueFallbackBlocksLegacyCredentialPromotion() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let lpmDirectory = home.appendingPathComponent(".lpm")
		try FileManager.default.createDirectory(
			at: lpmDirectory,
			withIntermediateDirectories: true
		)
		try Data("opaque-encrypted-rust-store".utf8).write(
			to: lpmDirectory.appendingPathComponent(".credentials")
		)
		let backend = MemoryAuthCredentialBackend()
		try backend.write(
			"legacy-access",
			account: "auth-token:\(registryURL)"
		)
		let coordinator = makeCoordinator(home: home, backend: backend)

		await #expect(throws: AuthSessionCoordinatorError.self) {
			try await coordinator.currentAccessToken(
				registryURL: registryURL,
				baseURL: baseURL
			)
		}
		#expect(
			!FileManager.default.fileExists(
				atPath: lpmDirectory.appendingPathComponent(
					".credential-authority.json"
				).path
			)
		)
	}

	@Test("the Swift lock is visible to an independent flock process")
	func lockIsHeldAcrossAsyncBody() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let lockURL = home.appendingPathComponent("locks/session.lock")

		let status = try await CrossProcessFileLock.withExclusive(at: lockURL) {
			await Task.yield()
			return try independentExclusiveLockStatus(at: lockURL)
		}

		#expect(status == 42)
	}

	@Test("a cancelled in-process waiter never enters the critical section")
	func cancelledLockWaiterDoesNotRun() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let lockURL = home.appendingPathComponent("locks/session.lock")
		let control = LockBodyControl()
		let execution = ExecutionRecorder()
		let holder = Task {
			try await CrossProcessFileLock.withExclusive(at: lockURL) {
				await control.hold()
			}
		}
		await control.waitUntilEntered()
		let waiter = Task {
			try await CrossProcessFileLock.withExclusive(at: lockURL) {
				await execution.record()
			}
		}
		try await Task.sleep(for: .milliseconds(20))

		waiter.cancel()

		await #expect(throws: CancellationError.self) { try await waiter.value }
		#expect(await !execution.didRun)
		await control.release()
		try await holder.value
	}

	@Test("cancellation after critical-section admission acknowledges a committed result")
	func cancellationAfterLockAdmissionReturnsCommittedResult() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let lockURL = home.appendingPathComponent("locks/session.lock")
		let control = LockBodyControl()
		let operation = Task {
			try await CrossProcessFileLock.withExclusive(at: lockURL) {
				await control.hold()
				return 42
			}
		}
		await control.waitUntilEntered()

		operation.cancel()
		await control.release()

		#expect(try await operation.value == 42)
	}

	@Test("many in-process waiters do not starve a suspended lock holder")
	func lockContentionDoesNotStarveCooperativeExecutor() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let lockURL = home.appendingPathComponent("locks/session.lock")
		let control = LockBodyControl()
		let holder = Task {
			try await CrossProcessFileLock.withExclusive(at: lockURL) {
				await control.hold()
			}
		}
		await control.waitUntilEntered()
		let waiters = (0..<128).map { value in
			Task {
				try await CrossProcessFileLock.withExclusive(at: lockURL) { value }
			}
		}
		try await Task.sleep(for: .milliseconds(50))

		await control.release()
		try await holder.value
		var values: [Int] = []
		values.reserveCapacity(waiters.count)
		for waiter in waiters { values.append(try await waiter.value) }

		#expect(values.sorted() == Array(0..<128))
	}

	@Test("device identity initialization is stable across concurrent coordinators")
	func concurrentDeviceIdentity() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let backend = MemoryAuthCredentialBackend()
		let first = makeCoordinator(home: home, backend: backend)
		let second = makeCoordinator(home: home, backend: backend)

		async let firstID = Task.detached { try first.deviceFingerprint() }.value
		async let secondID = Task.detached { try second.deviceFingerprint() }.value
		let values = try await [firstID, secondID]

		#expect(values[0] == values[1])
		#expect(values[0].count == 64)
	}

	@Test("device identity storage failures are explicit and never mint transient identities")
	func deviceIdentityStorageFailureIsExplicit() throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		try Data("not-a-directory".utf8).write(to: home.appendingPathComponent(".lpm"))
		let coordinator = makeCoordinator(home: home, backend: MemoryAuthCredentialBackend())

		#expect(throws: Error.self) { try coordinator.deviceFingerprint() }
		#expect(throws: Error.self) { try coordinator.deviceFingerprint() }
	}

	private func makeCoordinator(
		home: URL,
		backend: MemoryAuthCredentialBackend,
		refresh: @escaping AuthSessionCoordinator.RefreshOperation = { _, _, _ in
			throw AuthSessionRefreshError.invalidResponse
		}
	) -> AuthSessionCoordinator {
		AuthSessionCoordinator(
			homeDirectory: home,
			credentialBackend: backend,
			refreshOperation: refresh,
			now: { fixedNow }
		)
	}

	private func session(
		access: String,
		refresh: String,
		expiresAt: Date
	) -> AuthSessionCredentials {
		AuthSessionCredentials(
			token: access,
			refreshToken: refresh,
			expiresIn: 3_600,
			expiresAt: ISO8601DateFormatter().string(from: expiresAt)
		)
	}

	private func temporaryHome() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-auth-session-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private func jsonObject(at url: URL) throws -> [String: Any] {
		let data = try Data(contentsOf: url)
		return try #require(
			JSONSerialization.jsonObject(with: data) as? [String: Any]
		)
	}

	private func independentExclusiveLockStatus(at url: URL) throws -> Int32 {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
		process.arguments = [
			"-c",
			"import fcntl, os, sys; f=os.open(sys.argv[1], os.O_CREAT|os.O_RDWR, 0o600); "
				+ "\ntry:\n fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(0)"
				+ "\nexcept BlockingIOError:\n sys.exit(42)",
			url.path,
		]
		try process.run()
		process.waitUntilExit()
		return process.terminationStatus
	}
}

private final class MemoryAuthCredentialBackend: AuthCredentialBackend, @unchecked Sendable {
	private let lock = NSLock()
	private var credentials: [String: String] = [:]
	private var writes: [String] = []
	private var failingWriteAccounts: Set<String> = []

	var writeAccounts: [String] {
		lock.withLock { writes }
	}

	func read(account: String) throws -> String? {
		lock.withLock { credentials[account] }
	}

	func write(_ credential: String, account: String) throws {
		try lock.withLock {
			if failingWriteAccounts.contains(account) {
				throw TestCredentialBackendError.writeFailed
			}
			credentials[account] = credential
			writes.append(account)
		}
	}

	func delete(account: String) throws {
		_ = lock.withLock { credentials.removeValue(forKey: account) }
	}

	func value(for account: String) -> String? {
		lock.withLock { credentials[account] }
	}

	func resetWriteLog() {
		lock.withLock { writes = [] }
	}

	func failWrites(to account: String) {
		_ = lock.withLock { failingWriteAccounts.insert(account) }
	}

	func allowWrites(to account: String) {
		_ = lock.withLock { failingWriteAccounts.remove(account) }
	}
}

private enum TestCredentialBackendError: Error {
	case writeFailed
}

private actor ControlledRefresh {
	let credentials: AuthSessionCredentials
	private(set) var callCount = 0
	private var entered = false
	private var released = false
	private var entryWaiters: [CheckedContinuation<Void, Never>] = []
	private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

	init(credentials: AuthSessionCredentials) {
		self.credentials = credentials
	}

	func rotate(token: String) async throws -> AuthSessionCredentials {
		#expect(token == "refresh-old")
		callCount += 1
		entered = true
		entryWaiters.forEach { $0.resume() }
		entryWaiters = []
		guard !released else { return credentials }
		await withCheckedContinuation { releaseWaiters.append($0) }
		return credentials
	}

	func waitUntilEntered() async {
		guard !entered else { return }
		await withCheckedContinuation { entryWaiters.append($0) }
	}

	func release() {
		released = true
		releaseWaiters.forEach { $0.resume() }
		releaseWaiters = []
	}
}

private actor RefreshTokenRecorder {
	let credentials: AuthSessionCredentials
	private(set) var tokens: [String] = []

	init(credentials: AuthSessionCredentials) {
		self.credentials = credentials
	}

	func rotate(token: String) -> AuthSessionCredentials {
		tokens.append(token)
		return credentials
	}
}

private actor LockBodyControl {
	private var entered = false
	private var released = false
	private var entryWaiters: [CheckedContinuation<Void, Never>] = []
	private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

	func hold() async {
		entered = true
		entryWaiters.forEach { $0.resume() }
		entryWaiters = []
		guard !released else { return }
		await withCheckedContinuation { releaseWaiters.append($0) }
	}

	func waitUntilEntered() async {
		guard !entered else { return }
		await withCheckedContinuation { entryWaiters.append($0) }
	}

	func release() {
		released = true
		releaseWaiters.forEach { $0.resume() }
		releaseWaiters = []
	}
}

private actor ExecutionRecorder {
	private(set) var didRun = false

	func record() {
		didRun = true
	}
}
