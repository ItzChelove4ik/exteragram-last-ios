import XCTest
@testable import ExteraPreferences

final class ExteraTextFilterTests: XCTestCase {
    func testOrdinaryAccentsScriptsAndEmojiAreUnchanged() {
        let text = "е\u{0308} café العربية नमस्ते 👨‍👩‍👧‍👦"
        XCTAssertEqual(ExteraTextFilter.filterZalgo(text), text)
    }

    func testCommonMarksPermitTwoButReplaceWholeLongSequence() {
        XCTAssertEqual(ExteraTextFilter.filterZalgo("a\u{0301}\u{0302}"), "a\u{0301}\u{0302}")
        XCTAssertEqual(ExteraTextFilter.filterZalgo("a\u{0301}\u{0302}\u{0303}b"), "a" + String(repeating: "\u{2060}", count: 3) + "b")
    }

    func testOtherMarksAllowFourAndKeepSupplementaryUTF16Offsets() {
        let mark = "\u{1E944}"
        XCTAssertEqual(ExteraTextFilter.filterZalgo("a" + String(repeating: mark, count: 4)), "a" + String(repeating: mark, count: 4))
        let input = "😀a" + String(repeating: mark, count: 5) + " link"
        let output = ExteraTextFilter.filterZalgo(input)
        XCTAssertEqual(output, "😀a" + String(repeating: "\u{2060}", count: 10) + " link")
        XCTAssertEqual(Array(output.utf16).count, Array(input.utf16).count)
        XCTAssertEqual((output as NSString).range(of: "link"), (input as NSString).range(of: "link"))
    }

    func testDirectionControlsAreReplacedButJoinersRemain() {
        XCTAssertEqual(ExteraTextFilter.filterZalgo("a\u{202E}b\u{2066}c\u{200D}d"), "a\u{2060}b\u{2060}c\u{200D}d")
    }
}
