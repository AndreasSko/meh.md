import Foundation
import XCTest
@testable import AssistantCore

final class LoopbackCallbackListenerTests: XCTestCase {
    func testBrowserStyleCallbackOverRealLoopbackSocket() async throws {
        let listener = LoopbackCallbackListener()
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        let result = Task { try await listener.callback(expectedState: "fixture-state") }
        defer { Task { await listener.stop() } }
        await Task.yield()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let invalid = URL(string: redirect.absoluteString + "?state=wrong&code=fake")!
        let (_, rejected) = try await session.data(from: invalid)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)

        let valid = URL(string: redirect.absoluteString
            + "?state=fixture-state&code=fictional-code&client_id=fictional-client")!
        let (body, accepted) = try await session.data(from: valid)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.value(
            forHTTPHeaderField: "Cache-Control"
        ), "no-store")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fictional-code"))
        let returned = try await result.value
        XCTAssertEqual(returned, valid)
    }

    func testParserRejectsWrongHostPathDuplicateStateAndAbsoluteRequest() {
        let redirect = URL(string: "http://127.0.0.1:1455/auth/callback")!
        func parse(_ target: String, host: String = "127.0.0.1:1455") -> URL? {
            LoopbackCallbackListener.callbackURL(
                request: Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8),
                redirectURI: redirect, expectedState: "s"
            )
        }
        XCTAssertNotNil(parse("/auth/callback?state=s&code=c"))
        XCTAssertNotNil(parse("/auth/callback?state=s&error=access_denied"))
        XCTAssertNil(parse("/auth/callback?state=s&code=c", host: "localhost:1455"))
        XCTAssertNil(parse("/other?state=s&code=c"))
        XCTAssertNil(parse("/auth/callback?state=s&state=s&code=c"))
        XCTAssertNil(parse("/auth/callback?state=s&code=c&error=access_denied"))
        XCTAssertNil(parse("http://127.0.0.1:1455/auth/callback?state=s&code=c"))
        XCTAssertNil(parse("//evil.example/auth/callback?state=s&code=c"))
        XCTAssertNil(parse("/auth/callback?state=s"))
    }

    func testStoppingListenerCancelsPendingCallback() async throws {
        let listener = LoopbackCallbackListener()
        _ = try await listener.start()
        let result = Task { try await listener.callback(expectedState: "s") }
        await Task.yield()
        await listener.stop()
        do {
            _ = try await result.value
            XCTFail("A stopped listener must not return a callback")
        } catch {
            XCTAssertTrue(error is CancellationError
                || error is LoopbackCallbackListener.CallbackError)
        }
    }
}
