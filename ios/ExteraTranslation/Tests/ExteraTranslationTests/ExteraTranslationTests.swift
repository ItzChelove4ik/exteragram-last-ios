import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteraTranslation

private final class TranslationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    static func install(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let (status, headers, body) = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status,
                                                       httpVersion: "HTTP/1.1", headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class ExteraTranslationTests: XCTestCase {
    private func client(microsoft: ExteraMicrosoftCredentials? = nil) -> ExteraTranslationClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranslationURLProtocol.self]
        return ExteraTranslationClient(session: URLSession(configuration: config), microsoft: microsoft, maxAttempts: 1)
    }

    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testGoogleQueryEncodingAndBothResponseShapes() async throws {
        TranslationURLProtocol.install { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "translate.googleapis.com")
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.filter { $0.name == "q" }.compactMap(\.value), ["a+b &? Привет", "world"])
            XCTAssertEqual(items.first { $0.name == "sl" }?.value, "auto")
            XCTAssertEqual(items.first { $0.name == "tl" }?.value, "ru")
            XCTAssertTrue(url.absoluteString.contains("%2B"))
            return (200, [:], try self.json([["первый", "en"], "второй"]))
        }
        let result = try await client().translate(["a+b &? Привет", "world"], to: "ru", provider: .google)
        XCTAssertEqual(result, ["первый", "второй"])
    }

    func testPreservesWhitespaceAndNewlinesWithoutSendingThem() async throws {
        TranslationURLProtocol.install { request in
            let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            let texts = items.filter { $0.name == "q" }.compactMap(\.value)
            XCTAssertEqual(texts, ["hello", "world"])
            return (200, [:], try self.json(texts.map { $0.uppercased() }))
        }
        let result = try await client().translate(" \thello \r\n\n world\t ", to: "ru", provider: .google)
        XCTAssertEqual(result, " \tHELLO \r\n\n WORLD\t ")
    }

    func testBatchLimitsKeepResultsInOrder() async throws {
        var sizes: [Int] = []
        TranslationURLProtocol.install { request in
            let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            let texts = items.filter { $0.name == "q" }.compactMap(\.value)
            sizes.append(texts.count)
            XCTAssertLessThanOrEqual(texts.reduce(0) { $0 + $1.utf16.count }, 8_000)
            return (200, [:], try self.json(texts))
        }
        let input = [String(repeating: "a", count: 3_000), String(repeating: "b", count: 3_000), String(repeating: "c", count: 3_000)]
        let result = try await client().translate(input, to: "ru", provider: .google)
        XCTAssertEqual(result, input)
        XCTAssertEqual(sizes, [2, 1])
    }

    func testSplitsEmojiWithoutBreakingGraphemes() async throws {
        TranslationURLProtocol.install { request in
            let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            let texts = items.filter { $0.name == "q" }.compactMap(\.value)
            for text in texts {
                XCTAssertLessThanOrEqual(text.utf16.count, 5_000)
                XCTAssertTrue(text.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
            }
            return (200, [:], try self.json(texts))
        }
        let input = String(repeating: "👨‍👩‍👧‍👦", count: 600)
        let result = try await client().translate(input, to: "ru", provider: .google)
        XCTAssertEqual(result, input)
    }

    func testYandexPostFormAndResponse() async throws {
        TranslationURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "translate.yandex.net")
            // URLSession may convert httpBody into a stream; this request is small
            // enough for a direct body on the supported Darwin test runtime.
            if let data = request.httpBody, let body = String(data: data, encoding: .utf8) {
                XCTAssertEqual(body, "lang=ru&text=a%2Bb+%26c&text=two")
            }
            return (200, [:], try self.json(["code": 200, "text": ["один", "два"]]))
        }
        let result = try await client().translate(["a+b &c", "two"], to: "ru", provider: .yandex)
        XCTAssertEqual(result, ["один", "два"])
    }

    func testMicrosoftRequiresUserCredentialsBeforeNetwork() async throws {
        TranslationURLProtocol.install { _ in XCTFail("No configured credentials must mean no request"); return (500, [:], Data()) }
        do {
            _ = try await client().translate("hello", to: "ru", provider: .microsoft)
            XCTFail("Expected configurationRequired")
        } catch let error as ExteraTranslationError { XCTAssertEqual(error, .configurationRequired) }
    }

    func testMicrosoftUsesOfficialUserSubscriptionHeader() async throws {
        TranslationURLProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"), "test-region")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Mt-Signature"))
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, [:], try self.json([["translations": [["text": "привет", "to": "ru"]]]]))
        }
        let credentials = ExteraMicrosoftCredentials(subscriptionKey: "test-key", region: "test-region")
        let result = try await client(microsoft: credentials).translate("hello", to: "ru", provider: .microsoft)
        XCTAssertEqual(result, "привет")
    }

    func testResponseCountMismatchDoesNotReturnPartialTranslation() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try ExteraTranslationClient.parse(json(["one"]), response: response, provider: .google, expectedCount: 2)) {
            XCTAssertEqual($0 as? ExteraTranslationError, .invalidResponse)
        }
    }

    func testRateLimitPreservesRetryAfter() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"]))
        XCTAssertThrowsError(try ExteraTranslationClient.parse(Data(), response: response, provider: .google, expectedCount: 1)) {
            XCTAssertEqual($0 as? ExteraTranslationError, .rateLimited(retryAfterSeconds: 120))
        }
    }

    func testLongServerCooldownDoesNotRetryEarly() async throws {
        var requests = 0
        TranslationURLProtocol.install { _ in
            requests += 1
            return (429, ["Retry-After": "120"], Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranslationURLProtocol.self]
        let translator = ExteraTranslationClient(session: URLSession(configuration: config), maxAttempts: 4)
        do {
            _ = try await translator.translate("hello", to: "ru", provider: .google)
            XCTFail("Expected cooldown")
        } catch let error as ExteraTranslationError {
            XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 120))
        }
        XCTAssertEqual(requests, 1)
    }

    func testHTMLForbiddenIsRejectedWithoutJSONRetry() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 403, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try ExteraTranslationClient.parse(Data("<html>Forbidden</html>".utf8), response: response, provider: .google, expectedCount: 1)) {
            XCTAssertEqual($0 as? ExteraTranslationError, .serviceRejected(403))
        }
    }

    func testYandexSemanticErrors() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try ExteraTranslationClient.parse(json(["code": 501]), response: response, provider: .yandex, expectedCount: 1)) {
            XCTAssertEqual($0 as? ExteraTranslationError, .unsupportedLanguage)
        }
        XCTAssertThrowsError(try ExteraTranslationClient.parse(json(["code": 1052]), response: response, provider: .yandex, expectedCount: 1)) {
            XCTAssertEqual($0 as? ExteraTranslationError, .rateLimited(retryAfterSeconds: 0))
        }
    }

    func testWhitespaceAndEmptyInputsMakeNoRequest() async throws {
        TranslationURLProtocol.install { _ in XCTFail("Whitespace is local"); return (500, [:], Data()) }
        let result = try await client().translate([" \r\n\t", ""], to: "ru", provider: .google)
        XCTAssertEqual(result, [" \r\n\t", ""])
    }

    func testInvalidLanguageMakesNoRequest() async throws {
        TranslationURLProtocol.install { _ in XCTFail("Invalid language is local"); return (500, [:], Data()) }
        do {
            _ = try await client().translate("hello", to: "ru&other=value", provider: .google)
            XCTFail("Expected invalidLanguage")
        } catch let error as ExteraTranslationError { XCTAssertEqual(error, .invalidLanguage) }
    }

    func testCancelledTaskMakesNoRequest() async throws {
        TranslationURLProtocol.install { _ in XCTFail("Cancelled task must not send text"); return (500, [:], Data()) }
        let translator = client()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await translator.translate("hello", to: "ru", provider: .google)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
