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

final class AvatarSessionDelegate: BoundedHTTPResponseDelegate, @unchecked Sendable {
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

@MainActor
final class SecureAvatarImageCache {
	typealias Loader = @Sendable (URL) async throws -> NSImage

	static let shared = SecureAvatarImageCache(loader: loadValidatedImage)

	private let cache = NSCache<NSURL, NSImage>()
	private let loader: Loader
	private var inFlight: [URL: (id: UUID, task: Task<NSImage, Error>)] = [:]

	init(
		maximumCost: Int = 16 * 1024 * 1024,
		maximumCount: Int = 64,
		loader: @escaping Loader
	) {
		self.loader = loader
		cache.totalCostLimit = maximumCost
		cache.countLimit = maximumCount
	}

	func image(for url: URL) async throws -> NSImage {
		if let cached = cache.object(forKey: url as NSURL) { return cached }
		if let pending = inFlight[url] { return try await pending.task.value }

		let id = UUID()
		let loader = self.loader
		let task = Task { try await loader(url) }
		inFlight[url] = (id, task)
		do {
			let image = try await task.value
			if inFlight[url]?.id == id { inFlight.removeValue(forKey: url) }
			cache.setObject(image, forKey: url as NSURL, cost: Self.pixelCost(image))
			return image
		} catch {
			if inFlight[url]?.id == id { inFlight.removeValue(forKey: url) }
			throw error
		}
	}

	private static func loadValidatedImage(_ url: URL) async throws -> NSImage {
		let data = try await SecureAvatarLoader.load(url)
		return try await Task.detached(priority: .utility) {
			guard let image = NSImage(data: data) else {
				throw URLError(.cannotDecodeContentData)
			}
			return image
		}.value
	}

	private static func pixelCost(_ image: NSImage) -> Int {
		let pixels = image.representations.reduce(0) { current, representation in
			max(current, representation.pixelsWide * representation.pixelsHigh)
		}
		return max(1, pixels) * 4
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
				let loaded = try await SecureAvatarImageCache.shared.image(for: url)
				try Task.checkCancellation()
				image = loaded
			} catch {
				image = nil
			}
		}
	}
}
