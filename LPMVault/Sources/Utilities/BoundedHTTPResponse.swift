import Foundation

struct PreparedRemoteOperation<Value: Sendable>: Sendable {
	private let startOperation: @Sendable () -> StartedRemoteOperation<Value>

	init(start: @escaping @Sendable () -> StartedRemoteOperation<Value>) {
		startOperation = start
	}

	static func completed(_ value: Value) -> PreparedRemoteOperation<Value> {
		PreparedRemoteOperation { .completed(value) }
	}

	func start() -> StartedRemoteOperation<Value> {
		startOperation()
	}
}

struct StartedRemoteOperation<Value: Sendable>: Sendable {
	private let cancelOperation: @Sendable () -> Void
	private let resultOperation: @Sendable () async -> Value

	init(
		cancel: @escaping @Sendable () -> Void,
		result: @escaping @Sendable () async -> Value
	) {
		cancelOperation = cancel
		resultOperation = result
	}

	static func run(
		_ operation: @escaping @Sendable () async -> Value
	) -> StartedRemoteOperation<Value> {
		let task = Task(operation: operation)
		return StartedRemoteOperation(
			cancel: { task.cancel() },
			result: { await task.value }
		)
	}

	static func completed(_ value: Value) -> StartedRemoteOperation<Value> {
		StartedRemoteOperation(cancel: {}, result: { value })
	}

	func value() async -> Value {
		await withTaskCancellationHandler(
			operation: resultOperation,
			onCancel: cancelOperation
		)
	}
}

/// Streams an HTTP response while enforcing a hard in-memory size limit.
///
/// `URLSession.data(for:)` buffers the complete response before returning, so
/// checking `Data.count` afterward does not protect the process from a server
/// that sends an unexpectedly large body.
enum BoundedHTTPResponse {
	static func ephemeralConfiguration(
		requestTimeout: TimeInterval,
		resourceTimeout: TimeInterval
	) -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpShouldSetCookies = false
		configuration.httpCookieStorage = nil
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = requestTimeout
		configuration.timeoutIntervalForResource = resourceTimeout
		return configuration
	}

	enum LoadError: Error, Equatable {
		case invalidLimit
		case responseTooLarge(limit: Int)
		case streamingDelegateRequired
	}

	struct Started: Sendable {
		private let cancelOperation: @Sendable () -> Void
		private let resultOperation:
			@Sendable () async throws -> (data: Data, response: URLResponse)

		init(
			cancel: @escaping @Sendable () -> Void,
			result: @escaping @Sendable () async throws -> (
				data: Data,
				response: URLResponse
			)
		) {
			cancelOperation = cancel
			resultOperation = result
		}

		func value() async throws -> (data: Data, response: URLResponse) {
			try await withTaskCancellationHandler(
				operation: resultOperation,
				onCancel: cancelOperation
			)
		}

		func map<Value: Sendable>(
			_ transform: @escaping @Sendable (
				Result<(data: Data, response: URLResponse), Error>
			) -> Value
		) -> StartedRemoteOperation<Value> {
			StartedRemoteOperation(
				cancel: cancelOperation,
				result: {
					do {
						return transform(.success(try await resultOperation()))
					} catch {
						return transform(.failure(error))
					}
				}
			)
		}
	}

	final class Accumulator: @unchecked Sendable {
		private let lock = NSLock()
		private let maximumBytes: Int
		private var data = Data()
		private var response: URLResponse?
		private var failure: Error?
		private var result:
			Result<(data: Data, response: URLResponse), Error>?
		private var continuation:
			CheckedContinuation<(data: Data, response: URLResponse), Error>?

		init(maximumBytes: Int) {
			self.maximumBytes = maximumBytes
		}

		func receive(_ response: URLResponse) -> Bool {
			lock.withLock {
				guard failure == nil, result == nil else { return false }
				guard response.expectedContentLength <= Int64(maximumBytes) else {
					failure = LoadError.responseTooLarge(limit: maximumBytes)
					return false
				}
				self.response = response
				if response.expectedContentLength > 0 {
					data.reserveCapacity(Int(response.expectedContentLength))
				}
				return true
			}
		}

		func receive(_ bytes: Data) -> Bool {
			lock.withLock {
				guard failure == nil, result == nil else { return false }
				guard bytes.count <= maximumBytes - data.count else {
					failure = LoadError.responseTooLarge(limit: maximumBytes)
					return false
				}
				data.append(bytes)
				return true
			}
		}

		func complete(error: Error?) {
			let completion: (
				CheckedContinuation<(data: Data, response: URLResponse), Error>?,
				Result<(data: Data, response: URLResponse), Error>
			) = lock.withLock {
				let completed: Result<(data: Data, response: URLResponse), Error>
				if let failure {
					completed = .failure(failure)
				} else if let error {
					completed = .failure(error)
				} else if let response {
					completed = .success((data, response))
				} else {
					completed = .failure(URLError(.badServerResponse))
				}
				result = completed
				let waiter = continuation
				continuation = nil
				return (waiter, completed)
			}
			completion.0?.resume(with: completion.1)
		}

		func value() async throws -> (data: Data, response: URLResponse) {
			try await withCheckedThrowingContinuation { waiter in
				let completed: Result<
					(data: Data, response: URLResponse), Error
				>? = lock.withLock {
					if let result { return result }
					precondition(continuation == nil)
					continuation = waiter
					return nil
				}
				if let completed { waiter.resume(with: completed) }
			}
		}
	}

	static func start(
		for request: URLRequest,
		using session: URLSession,
		maximumBytes: Int
	) throws -> Started {
		guard maximumBytes >= 0 else { throw LoadError.invalidLimit }
		guard let starter = session.delegate as? any BoundedHTTPResponseStarting else {
			throw LoadError.streamingDelegateRequired
		}
		return try starter.startBoundedResponse(
			for: request,
			using: session,
			maximumBytes: maximumBytes
		)
	}

	static func load(
		for request: URLRequest,
		using session: URLSession,
		maximumBytes: Int
	) async throws -> (data: Data, response: URLResponse) {
		try await start(
			for: request,
			using: session,
			maximumBytes: maximumBytes
		).value()
	}

}

protocol BoundedHTTPResponseStarting: AnyObject {
	func startBoundedResponse(
		for request: URLRequest,
		using session: URLSession,
		maximumBytes: Int
	) throws -> BoundedHTTPResponse.Started
}

class BoundedHTTPResponseDelegate: NSObject, URLSessionDataDelegate,
	BoundedHTTPResponseStarting, @unchecked Sendable
{
	private let lock = NSLock()
	private var accumulators: [Int: BoundedHTTPResponse.Accumulator] = [:]

	func startBoundedResponse(
		for request: URLRequest,
		using session: URLSession,
		maximumBytes: Int
	) throws -> BoundedHTTPResponse.Started {
		guard maximumBytes >= 0 else { throw BoundedHTTPResponse.LoadError.invalidLimit }
		let accumulator = BoundedHTTPResponse.Accumulator(maximumBytes: maximumBytes)
		let task = session.dataTask(with: request)
		lock.withLock { accumulators[task.taskIdentifier] = accumulator }
		// Returning only after dispatch prevents authorization generation changes
		// from linearizing between response preparation and network start.
		task.resume()
		return BoundedHTTPResponse.Started(
			cancel: { task.cancel() },
			result: { try await accumulator.value() }
		)
	}

	func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive response: URLResponse,
		completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
	) {
		guard let accumulator = accumulator(for: dataTask.taskIdentifier) else {
			completionHandler(.allow)
			return
		}
		completionHandler(accumulator.receive(response) ? .allow : .cancel)
	}

	func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive data: Data
	) {
		guard let accumulator = accumulator(for: dataTask.taskIdentifier) else { return }
		if !accumulator.receive(data) { dataTask.cancel() }
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		didCompleteWithError error: Error?
	) {
		let accumulator = lock.withLock {
			accumulators.removeValue(forKey: task.taskIdentifier)
		}
		accumulator?.complete(error: error)
	}

	private func accumulator(
		for taskIdentifier: Int
	) -> BoundedHTTPResponse.Accumulator? {
		lock.withLock { accumulators[taskIdentifier] }
	}
}
