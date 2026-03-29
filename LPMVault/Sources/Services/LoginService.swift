import AppKit
import Foundation
import Network

/// Handles the browser-based login flow — same UX as `lpm login`.
///
/// Flow:
/// 1. Start local HTTP server on a random port
/// 2. Open browser to `lpm.dev/cli/login?port={port}`
/// 3. User authenticates on the web (handles MFA too)
/// 4. Server redirects to `localhost:{port}/callback?token=lpm_xxx`
/// 5. Capture token, store in Keychain (shared with CLI)
enum LoginService {

	enum LoginError: LocalizedError {
		case listenerFailed(String)
		case timeout
		case noToken
		case stateMismatch

		var errorDescription: String? {
			switch self {
			case .listenerFailed(let msg): "Login server failed: \(msg)"
			case .timeout: "Login timed out after 2 minutes. Try again."
			case .noToken: "No token received from login callback"
			case .stateMismatch: "Login state mismatch — possible CSRF attack. Try again."
			}
		}
	}

	/// Start the login flow. Opens the browser and waits for the callback token.
	/// Returns the raw token string on success.
	static func login(registryURL: String = "https://lpm.dev") async throws -> String {
		let lock = NSLock()
		var resumed = false
		// Random state parameter to prevent CSRF on the callback
		let loginState = UUID().uuidString

		return try await withCheckedThrowingContinuation { continuation in
			let resumeOnce: (Result<String, Error>) -> Void = { result in
				lock.lock()
				defer { lock.unlock() }
				guard !resumed else { return }
				resumed = true
				continuation.resume(with: result)
			}

			let listener: NWListener
			do {
				listener = try NWListener(using: .tcp, on: .any)
			} catch {
				resumeOnce(.failure(LoginError.listenerFailed(error.localizedDescription)))
				return
			}

			listener.stateUpdateHandler = { state in
				switch state {
				case .ready:
					guard let port = listener.port?.rawValue else {
						resumeOnce(.failure(LoginError.listenerFailed("no port assigned")))
						return
					}
					let url = URL(string: "\(registryURL)/cli/login?port=\(port)&state=\(loginState)")!
					DispatchQueue.main.async {
						NSWorkspace.shared.open(url)
					}
				case .failed(let error):
					resumeOnce(.failure(LoginError.listenerFailed(error.localizedDescription)))
				default:
					break
				}
			}

			listener.newConnectionHandler = { connection in
				handleConnection(connection, expectedState: loginState) { result in
					resumeOnce(result)
					listener.cancel()
				}
			}

			listener.start(queue: .global(qos: .userInitiated))

			// 2-minute timeout (same as CLI)
			DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
				resumeOnce(.failure(LoginError.timeout))
				listener.cancel()
			}
		}
	}

	// MARK: - Keychain Write/Delete

	/// Write auth token to Keychain (shared with CLI).
	/// Uses `security` CLI to avoid ACL issues with ad-hoc signing.
	static func writeAuthToken(_ token: String, registryURL: String = "https://lpm.dev") {
		let service = VaultConstants.cliAuthService
		let account = "auth-token:\(registryURL)"

		// Delete existing entry first (security add fails if exists)
		runSecurity(args: ["delete-generic-password", "-s", service, "-a", account])

		// Auth token does NOT use -A — only the creating app (`security` CLI)
		// can read without prompt. Unlike vault secrets, auth tokens don't need
		// cross-app access because both CLI and Swift app write their own tokens.
		runSecurity(args: ["add-generic-password", "-s", service, "-a", account, "-w", token])
	}

	/// Remove auth token from Keychain.
	static func clearAuthToken(registryURL: String = "https://lpm.dev") {
		let service = VaultConstants.cliAuthService
		let account = "auth-token:\(registryURL)"
		runSecurity(args: ["delete-generic-password", "-s", service, "-a", account])
	}

	// MARK: - Private

	private static func handleConnection(
		_ connection: NWConnection,
		expectedState: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		connection.start(queue: .global(qos: .userInitiated))
		connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
			guard let data, let request = String(data: data, encoding: .utf8) else {
				connection.cancel()
				completion(.failure(LoginError.noToken))
				return
			}

			if let (token, callbackState) = extractTokenAndState(from: request),
				callbackState == expectedState
			{
				let html = """
					<html>
					<head>
					<style>
					body{font-family:system-ui,-apple-system;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#111;color:#fff}
					div{text-align:center}
					h1{color:#17793A;margin-bottom:8px}
					p{color:#888;font-size:15px}
					</style>
					</head>
					<body><div>
					<h1>Login successful</h1>
					<p>You can close this tab and return to LPM Vault.</p>
					</div></body></html>
					"""
				let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
				connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
					connection.cancel()
				})
				completion(.success(token))
			} else {
				let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body><p>Login failed — no token received.</p></body></html>"
				connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
					connection.cancel()
				})
				completion(.failure(LoginError.noToken))
			}
		}
	}

	/// Parse `GET /callback?token=lpm_xxx&state=uuid HTTP/1.1` from the raw HTTP request.
	/// Returns (token, state) tuple for CSRF validation.
	private static func extractTokenAndState(from request: String) -> (token: String, state: String)? {
		guard let firstLine = request.split(separator: "\r\n").first else { return nil }
		let parts = firstLine.split(separator: " ")
		guard parts.count >= 2 else { return nil }
		let path = String(parts[1])
		guard let components = URLComponents(string: path) else { return nil }
		let queryItems = components.queryItems ?? []
		guard let token = queryItems.first(where: { $0.name == "token" })?.value,
			let state = queryItems.first(where: { $0.name == "state" })?.value
		else { return nil }
		return (token, state)
	}

	@discardableResult
	private static func runSecurity(args: [String]) -> Int32 {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		process.arguments = args
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice

		let sem = DispatchSemaphore(value: 0)
		var exitCode: Int32 = -1
		process.terminationHandler = { p in
			exitCode = p.terminationStatus
			sem.signal()
		}

		do { try process.run() } catch { return -1 }
		_ = sem.wait(timeout: .now() + 10)
		return exitCode
	}
}
