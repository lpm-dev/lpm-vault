import AppKit
import Foundation
import ImageIO
import SwiftUI

enum AvatarURLPolicy {
	private static let approvedHosts: Set<String> = [
		"lpm.dev",
		"www.lpm.dev",
		"avatars.githubusercontent.com",
	]

	static func validatedURL(_ value: String?) -> URL? {
		guard let value,
			let url = URL(string: value),
			url.scheme?.lowercased() == "https",
			let host = url.host?.lowercased(),
			approvedHosts.contains(host),
			url.user == nil,
			url.password == nil,
			url.port == nil || url.port == 443
		else { return nil }
		return url
	}
}

private final class AvatarSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	private let pinnedDelegate = PinnedSessionDelegate()

	func urlSession(
		_ session: URLSession,
		didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
	) {
		let host = challenge.protectionSpace.host.lowercased()
		if host == "lpm.dev" || host == "www.lpm.dev" {
			pinnedDelegate.urlSession(
				session,
				didReceive: challenge,
				completionHandler: completionHandler
			)
		} else {
			completionHandler(.performDefaultHandling, nil)
		}
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		guard let source = response.url,
			let destination = request.url,
			AvatarURLPolicy.validatedURL(destination.absoluteString) != nil,
			PinnedSessionDelegate.isSameOrigin(source, destination)
		else {
			completionHandler(nil)
			return
		}
		completionHandler(request)
	}
}

enum SecureAvatarLoader {
	static let maximumResponseBytes = 512 * 1024
	static let maximumPixelDimension = 1_024

	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 10
		configuration.timeoutIntervalForResource = 15
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		return URLSession(
			configuration: configuration,
			delegate: AvatarSessionDelegate(),
			delegateQueue: nil
		)
	}()

	static func load(_ url: URL) async throws -> Data {
		guard AvatarURLPolicy.validatedURL(url.absoluteString) == url else {
			throw URLError(.unsupportedURL)
		}
		var request = URLRequest(url: url)
		request.timeoutInterval = 10
		let (data, response) = try await BoundedHTTPResponse.load(
			for: request,
			using: session,
			maximumBytes: maximumResponseBytes
		)
		guard let http = response as? HTTPURLResponse,
			http.statusCode == 200,
			let mime = http.mimeType?.lowercased(),
			mime.hasPrefix("image/"),
			isSafeImageData(data)
		else { throw URLError(.cannotDecodeContentData) }
		return data
	}

	static func isSafeImageData(_ data: Data) -> Bool {
		guard !data.isEmpty,
			data.count <= maximumResponseBytes,
			let source = CGImageSourceCreateWithData(data as CFData, nil),
			CGImageSourceGetCount(source) == 1,
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
				as? [CFString: Any],
			let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
			let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
			width.intValue > 0,
			height.intValue > 0,
			width.intValue <= maximumPixelDimension,
			height.intValue <= maximumPixelDimension
		else { return false }
		return true
	}
}

struct SecureAvatarImage<Placeholder: View>: View {
	let urlString: String?
	@ViewBuilder let placeholder: () -> Placeholder
	@State private var image: NSImage?

	var body: some View {
		Group {
			if let image {
				Image(nsImage: image).resizable().scaledToFill()
			} else {
				placeholder()
			}
		}
		.task(id: urlString) {
			image = nil
			guard let url = AvatarURLPolicy.validatedURL(urlString) else { return }
			do {
				let data = try await SecureAvatarLoader.load(url)
				try Task.checkCancellation()
				image = NSImage(data: data)
			} catch {
				image = nil
			}
		}
	}
}
