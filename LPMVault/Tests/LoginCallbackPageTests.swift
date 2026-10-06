import Foundation
import Testing
@testable import LPMVault

struct LoginCallbackPageTests {
	@Test("callback pages identify the app and adapt to a narrow browser window", arguments: [true, false])
	func callbackPagesHaveAccessibleDocumentMetadata(success: Bool) {
		let response = LoginService.callbackResponse(success: success)
		#expect(response.contains("<html lang=\"en\">"))
		#expect(response.contains("<meta charset=\"utf-8\">"))
		#expect(response.contains("name=\"viewport\" content=\"width=device-width, initial-scale=1\""))
		#expect(response.contains("LPM Vault"))
		#expect(response.contains("<main"))
	}

	@Test("receiving the browser callback does not claim the token exchange finished")
	func callbackAcknowledgesAuthorizationWithoutClaimingSignInCompleted() {
		let response = LoginService.callbackResponse(success: true)
		#expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
		#expect(response.contains("Authorization received"))
		#expect(response.contains("Check the app for your connection status."))
		#expect(!response.contains("Access Granted"))
	}

	@Test("a rejected callback gives a safe retry action")
	func rejectedCallbackDirectsTheUserBackToTheApp() {
		let response = LoginService.callbackResponse(success: false)
		#expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
		#expect(response.contains("Sign-in could not continue"))
		#expect(response.contains("Return to LPM Vault and start sign-in again."))
		#expect(!response.contains("Authorization received"))
	}

	@Test("callback pages do not cache authorization results or load third-party resources", arguments: [true, false])
	func callbackPagesStayLocalAndUncached(success: Bool) throws {
		let response = LoginService.callbackResponse(success: success)
		let boundary = try #require(response.range(of: "\r\n\r\n"))
		let headers = response[..<boundary.lowerBound]
		let body = response[boundary.upperBound...]
		#expect(headers.contains("Cache-Control: no-store\r\n"))
		#expect(headers.contains("Referrer-Policy: no-referrer\r\n"))
		#expect(headers.contains("Content-Security-Policy: default-src 'none';"))
		#expect(headers.contains("Content-Length: \(body.utf8.count)"))
		#expect(!body.contains("<script"))
		#expect(!body.contains("https://"))
		#expect(!body.contains("http://"))
	}
}
