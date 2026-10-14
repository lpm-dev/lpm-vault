import Foundation
import Network

/// The small HTTP surface of a listener on 127.0.0.1 that a browser returns
/// to after a flow on lpm.dev or a platform: one bounded request read per
/// connection, and one self-contained page sent back before closing.
enum LoopbackHTTP {
	static let maximumRequestBytes = 8 * 1024
	static let requestReadTimeout: TimeInterval = 10

	private final class RequestBuffer: @unchecked Sendable {
		private let lock = NSLock()
		private var data = Data()
		private var completed = false

		func append(_ chunk: Data, limit: Int) -> Data? {
			lock.lock()
			defer { lock.unlock() }
			guard !completed else { return nil }
			data.append(chunk)
			return data.count <= limit ? data : nil
		}

		func claimCompletion() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			guard !completed else { return false }
			completed = true
			return true
		}
	}

	/// Reads one request, or nil when it's too large, too slow or broken.
	static func readRequest(
		_ connection: NWConnection,
		completion: @escaping @Sendable (Data?) -> Void
	) {
		let buffer = RequestBuffer()
		DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + requestReadTimeout) {
			guard buffer.claimCompletion() else { return }
			connection.cancel()
			completion(nil)
		}
		@Sendable func receive() {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, complete, error in
				guard error == nil, let data else {
					if buffer.claimCompletion() { completion(nil) }
					return
				}
				guard let request = buffer.append(data, limit: maximumRequestBytes) else {
					if buffer.claimCompletion() { completion(nil) }
					return
				}
				if requestIsComplete(request) || complete {
					if buffer.claimCompletion() { completion(request) }
				} else {
					receive()
				}
			}
		}
		receive()
	}

	static func send(_ response: String, on connection: NWConnection) {
		connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
			connection.cancel()
		})
	}

	static func requestIsComplete(_ data: Data) -> Bool {
		guard let request = String(data: data, encoding: .utf8),
			let headerEnd = request.range(of: "\r\n\r\n")
		else { return false }
		let header = String(request[..<headerEnd.lowerBound])
		let expectedBody = contentLength(from: header) ?? 0
		return request[headerEnd.upperBound...].utf8.count >= expectedBody
	}

	/// The request line's method and target, with the header block and body.
	static func split(_ request: Data) -> (method: String, target: String, header: String, body: Substring)? {
		guard request.count <= maximumRequestBytes,
			let rawRequest = String(data: request, encoding: .utf8),
			let headerEnd = rawRequest.range(of: "\r\n\r\n")
		else { return nil }
		let header = String(rawRequest[..<headerEnd.lowerBound])
		guard let requestLine = header.components(separatedBy: "\r\n").first else { return nil }
		let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
		guard parts.count >= 2 else { return nil }
		return (String(parts[0]), String(parts[1]), header, rawRequest[headerEnd.upperBound...])
	}

	/// Form or query fields, percent-decoded; the first of a repeated name
	/// wins. A form that isn't validly encoded has no fields.
	static func parseForm(_ form: String) -> [String: String] {
		guard let components = URLComponents(string: "?" + form) else { return [:] }
		var values: [String: String] = [:]
		for item in components.queryItems ?? [] where values[item.name] == nil {
			values[item.name] = item.value ?? ""
		}
		return values
	}

	static func contentType(from headers: String) -> String? {
		headerValue(named: "content-type", in: headers)?
			.split(separator: ";", maxSplits: 1)
			.first
			.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
	}

	static func contentLength(from headers: String) -> Int? {
		guard let value = headerValue(named: "content-length", in: headers) else { return nil }
		return Int(value.trimmingCharacters(in: .whitespaces))
	}

	private static func headerValue(named name: String, in headers: String) -> String? {
		for line in headers.components(separatedBy: "\r\n").dropFirst() {
			guard let separator = line.firstIndex(of: ":") else { continue }
			if line[..<separator].lowercased() == name {
				return String(line[line.index(after: separator)...])
			}
		}
		return nil
	}
}

/// The page a loopback listener sends back: self-contained, uncached, and
/// telling the person to return to LPM Vault.
enum LoopbackPage {
	/// A link to offer on the page; only https URLs are shown.
	struct Link: Equatable, Sendable {
		let title: String
		let url: URL
	}

	static func response(
		success: Bool,
		title: String,
		label: String,
		detail: String,
		link: Link? = nil
	) -> String {
		let status = success ? "200 OK" : "400 Bad Request"
		let symbol = success ? "M6 12l4 4 8-8" : "M7 7l10 10M17 7L7 17"
		let state = success ? "success" : "failure"
		let linkHTML = link.flatMap { link -> String? in
			guard link.url.scheme == "https" else { return nil }
			return "\n      <p class=\"next-step\"><a href=\"\(escaped(link.url.absoluteString))\" rel=\"noreferrer\">\(escaped(link.title))</a></p>"
		} ?? ""
		let body = """
		<!doctype html>
		<html lang="en">
		<head>
		  <meta charset="utf-8">
		  <meta name="viewport" content="width=device-width, initial-scale=1">
		  <meta name="color-scheme" content="light dark">
		  <title>\(escaped(title)) | LPM Vault</title>
		  <style>
		    :root {
		      color-scheme: light dark;
		      --background: #f7f7f5; --surface: #fff; --text: #1b1b1d;
		      --muted: #626269; --border: #e4e4e7; --accent: #167345; --tint: #edf8f1;
		    }
		    * { box-sizing: border-box; }
		    body {
		      margin: 0; min-height: 100vh; min-height: 100svh;
		      display: grid; place-items: center; padding: 32px 20px;
		      background: var(--background); color: var(--text);
		      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
		      -webkit-font-smoothing: antialiased;
		    }
		    main { width: 100%; max-width: 460px; }
		    .brand { display: flex; align-items: center; justify-content: center; gap: 12px; margin-bottom: 24px; }
		    .wordmark { font-size: 20px; font-weight: 750; letter-spacing: -.8px; }
		    .product { border-left: 1px solid var(--border); padding-left: 12px; font-size: 14px; color: var(--muted); }
		    .card {
		      padding: 40px 32px 28px; border: 1px solid var(--border); border-radius: 20px;
		      background: var(--surface); text-align: center; box-shadow: 0 8px 40px rgb(0 0 0 / 3%);
		    }
		    .failure { --accent: #b53631; --tint: #fff0ee; }
		    .status-icon {
		      display: grid; place-items: center; width: 64px; height: 64px; margin: 0 auto 22px;
		      border: 1px solid var(--border); border-radius: 50%; background: var(--tint); color: var(--accent);
		    }
		    .status { margin: 0 0 12px; font-size: 12px; font-weight: 650; letter-spacing: .04em; color: var(--accent); }
		    h1 { margin: 0 0 14px; font-size: clamp(23px, 5vw, 28px); line-height: 1.2; letter-spacing: -.8px; }
		    .detail { margin: 0; font-size: 15px; line-height: 1.65; color: var(--muted); text-wrap: pretty; }
		    .next-step { border-top: 1px solid var(--border); padding-top: 22px; margin: 26px 0 0; font-size: 13px; color: var(--muted); }
		    .next-step a { color: var(--accent); }
		    .footer { margin: 22px 0 0; text-align: center; font-size: 12px; color: var(--muted); }
		    @media (prefers-color-scheme: dark) {
		      :root {
		        --background: #101012; --surface: #18181b; --text: #fafafa;
		        --muted: #a6a6af; --border: #303036; --accent: #66d99b; --tint: #173125;
		      }
		      .failure { --accent: #ff9e98; --tint: #3b211f; }
		    }
		    @media (max-width: 380px) { .card { padding: 32px 22px 24px; } }
		  </style>
		</head>
		<body>
		  <main aria-labelledby="title">
		    <div class="brand"><span class="wordmark">LPM</span><span class="product">LPM Vault</span></div>
		    <section class="card \(state)">
		      <div class="status-icon" aria-hidden="true">
		        <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
		          <path d="\(symbol)"></path>
		        </svg>
		      </div>
		      <p class="status">\(escaped(label))</p>
		      <h1 id="title">\(escaped(title))</h1>
		      <p class="detail">\(escaped(detail))</p>
		      <p class="next-step">You can close this tab.</p>\(linkHTML)
		    </section>
		    <p class="footer">LPM &middot; Environment variables, kept private.</p>
		  </main>
		</body>
		</html>
		"""
		return "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
	}

	private static func escaped(_ text: String) -> String {
		var result = ""
		result.reserveCapacity(text.utf8.count)
		for character in text {
			switch character {
			case "&": result += "&amp;"
			case "<": result += "&lt;"
			case ">": result += "&gt;"
			case "\"": result += "&quot;"
			case "'": result += "&#39;"
			default: result.append(character)
			}
		}
		return result
	}
}
