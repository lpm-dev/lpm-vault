import Foundation

/// Streams an HTTP response while enforcing a hard in-memory size limit.
///
/// `URLSession.data(for:)` buffers the complete response before returning, so
/// checking `Data.count` afterward does not protect the process from a server
/// that sends an unexpectedly large body.
enum BoundedHTTPResponse {
	enum LoadError: Error, Equatable {
		case invalidLimit
		case responseTooLarge(limit: Int)
	}

	static func load(
		for request: URLRequest,
		using session: URLSession,
		maximumBytes: Int
	) async throws -> (data: Data, response: URLResponse) {
		guard maximumBytes >= 0 else { throw LoadError.invalidLimit }

		let (bytes, response) = try await session.bytes(for: request)
		if response.expectedContentLength > Int64(maximumBytes) {
			throw LoadError.responseTooLarge(limit: maximumBytes)
		}

		var data = Data()
		let expected = response.expectedContentLength
		if expected > 0 {
			data.reserveCapacity(Int(min(expected, Int64(maximumBytes))))
		}

		for try await byte in bytes {
			guard data.count < maximumBytes else {
				throw LoadError.responseTooLarge(limit: maximumBytes)
			}
			data.append(byte)
		}
		return (data, response)
	}
}
