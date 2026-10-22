import Foundation
import XCTest
@testable import ExteraResources

final class ExteraResourcesTests: XCTestCase {
    func testNativePortTableUsesEnglishFallbackForUntranslatedLanguage() {
        XCTAssertEqual(ExteraLocalization.text("HideReactionsInChannels", languageCode: "ru", table: "ExteraPort"), "Скрыть реакции в каналах")
        XCTAssertEqual(ExteraLocalization.text("HideReactionsInChannels", languageCode: "de", table: "ExteraPort"), "Hide Reactions in Channels")
    }

    func testDeterministicEnglishAndRussianLookup() {
        XCTAssertEqual(ExteraLocalization.text("Preferences", languageCode: "en"), "exteraGram Preferences")
        XCTAssertEqual(ExteraLocalization.text("Preferences", languageCode: "ru"), "Настройки exteraGram")
    }

    func testUnknownLanguageFallsBackToEnglish() {
        XCTAssertEqual(ExteraLocalization.text("Preferences", languageCode: "xx-unknown"), "exteraGram Preferences")
    }

    func testUnknownKeyReturnsTheKey() {
        XCTAssertEqual(ExteraLocalization.text("__missing_key__", languageCode: "ru"), "__missing_key__")
    }

    func testAndroidEscapesAndObjectFormatsWereConverted() {
        XCTAssertEqual(ExteraLocalization.text("FilterZalgo", languageCode: "en"), "Filter \"Zalgo\"")
        let template = ExteraLocalization.text("FilterZalgoInfo", languageCode: "en")
        XCTAssertTrue(template.contains("%1$@"))
        XCTAssertFalse(template.contains("%1$s"))
        XCTAssertEqual(String(format: template, "test" as NSString), "Removes \"test\" symbols in names and messages.")
    }
}
