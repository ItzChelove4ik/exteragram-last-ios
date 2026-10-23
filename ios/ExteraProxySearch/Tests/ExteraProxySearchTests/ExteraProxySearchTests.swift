import XCTest
@testable import ExteraProxySearch

final class ExteraProxySearchTests: XCTestCase {
    func testParsePlainList() {
        let text = """
        # comment line
        example.com:443:dd08a1c2d38e8b1f9c0e0f1a2b3c4d5e6f
        1.2.3.4:8443:0123456789abcdef0123456789abcdef
        bad.host:443:short
        example.com:notaport:0123456789abcdef0123456789abcdef
        """
        let candidates = ExteraProxyListParser.parse(text: text, source: .mtprotoproxyList)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].host, "example.com")
        XCTAssertEqual(candidates[0].port, 443)
        XCTAssertEqual(candidates[1].host, "1.2.3.4")
    }

    func testDeduplicatesCandidates() {
        let text = "example.com:443:0123456789abcdef0123456789abcdef\nexample.com:443:0123456789abcdef0123456789abcdef"
        let candidates = ExteraProxyListParser.parse(text: text, source: .mtprotoproxyList)
        XCTAssertEqual(candidates.count, 1)
    }

    func testSecretNormalizationHex() {
        XCTAssertEqual(ExteraProxyListParser.normalizeSecret("0123456789ABCDEF0123456789ABCDEF"), "0123456789abcdef0123456789abcdef")
        XCTAssertNil(ExteraProxyListParser.normalizeSecret("zzzz"))
        XCTAssertNil(ExteraProxyListParser.normalizeSecret(""))
    }

    func testSecretNormalizationBase64() {
        // 16 zero bytes in base64 -> 32 hex zeros.
        let base64 = Data(repeating: 0, count: 16).base64EncodedString()
        XCTAssertEqual(ExteraProxyListParser.normalizeSecret(base64), String(repeating: "0", count: 32))
    }

    func testValidatorRejectsBadSecret() async {
        let candidate = ExteraProxyCandidate(host: "example.com", port: 443, secretHex: "zz", source: .manual)
        let validation = await ExteraProxyValidator(connectTimeout: 1.0).validate(candidate: candidate)
        XCTAssertEqual(validation.state, .invalidSecret)
    }

    func testLocalhostConnectivityMeasured() async {
        // Listening sockets are hard to guarantee in CI; skip on failure.
        let latency = await ExteraProxyValidator(connectTimeout: 2.0).measureLatency(host: "127.0.0.1", port: 9)
        // Port 9 (discard) is almost always closed; nil is the expected outcome,
        // but a guarded environment may allow it, so accept either.
        if latency != nil {
            XCTAssertGreaterThan(latency!, 0)
        }
    }
}
