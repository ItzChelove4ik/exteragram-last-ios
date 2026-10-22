import Foundation
import XCTest
@testable import ExteraExport

final class ExteraExportTests: XCTestCase {
    private func message(_ id: Int32, text: String = "text") -> ExteraExportMessage {
        ExteraExportMessage(id: id, timestamp: Int64(id), authorId: "user-1", author: "Имя", text: text)
    }

    func testHistoryRequiresSuccessfulEmptyEndPageAndOrdersByServerId() throws {
        var export = ExteraExportAccumulator()
        try export.append(ExteraExportPage(messages: [message(9), message(7)], sourceIds: [9, 7], reachedEnd: false))
        XCTAssertEqual(export.offsetId, 7)
        XCTAssertEqual(export.snapshotMaxMessageId, 9)
        XCTAssertThrowsError(try export.document(peerId: "chat", title: "Chat"))
        try export.append(ExteraExportPage(messages: [message(3)], sourceIds: [3], reachedEnd: false))
        try export.append(ExteraExportPage(messages: [], sourceIds: [], reachedEnd: true))
        XCTAssertEqual(try export.document(peerId: "chat", title: "Chat").messages.map(\.id), [3, 7, 9])
    }

    func testRepeatedOrNewerPageCannotCreateFalseCompleteExport() throws {
        var export = ExteraExportAccumulator()
        try export.append(ExteraExportPage(messages: [message(9)], sourceIds: [9], reachedEnd: false))
        XCTAssertThrowsError(try export.append(ExteraExportPage(messages: [message(9)], sourceIds: [9], reachedEnd: false)))
        var newer = ExteraExportAccumulator()
        try newer.append(ExteraExportPage(messages: [message(9)], sourceIds: [9], reachedEnd: false))
        XCTAssertThrowsError(try newer.append(ExteraExportPage(messages: [message(10)], sourceIds: [10], reachedEnd: false)))
        XCTAssertFalse(export.completed)
        XCTAssertTrue(export.failed)
        XCTAssertThrowsError(try export.append(ExteraExportPage(messages: [], sourceIds: [], reachedEnd: true)))
        XCTAssertThrowsError(try export.document(peerId: "chat", title: "Chat"))
    }

    func testOmittedRecordsStillAdvanceCursor() throws {
        var export = ExteraExportAccumulator()
        try export.append(ExteraExportPage(messages: [], sourceIds: [8, 6], omittedEphemeralMessages: 2, reachedEnd: false))
        XCTAssertEqual(export.offsetId, 6)
        try export.append(ExteraExportPage(messages: [], sourceIds: [], reachedEnd: true))
        let doc = try export.document(peerId: "chat", title: "Chat")
        XCTAssertEqual(doc.omittedEphemeralMessages, 2)
        XCTAssertTrue(doc.messages.isEmpty)
    }

    func testCapAndMalformedPageFailWithoutCompleting() throws {
        var export = ExteraExportAccumulator(maximumMessages: 1)
        XCTAssertThrowsError(try export.append(ExteraExportPage(messages: [message(2), message(1)], sourceIds: [2, 1], reachedEnd: false)))
        for page in [ExteraExportPage(messages: [message(1)], sourceIds: [], reachedEnd: true),
                     ExteraExportPage(messages: [], sourceIds: [0], reachedEnd: false),
                     ExteraExportPage(messages: [message(1)], sourceIds: [1, 1], reachedEnd: false)] {
            var invalid = ExteraExportAccumulator()
            XCTAssertThrowsError(try invalid.append(page))
            XCTAssertTrue(invalid.failed)
        }
        XCTAssertFalse(export.completed)
        XCTAssertEqual(export.messageCount, 0)
    }

    func testJSONRoundTripUnicodeMetadataAndStableDates() throws {
        let attachment = ExteraExportAttachment(kind: "document", id: "123", fileName: "../Привет.pdf", mimeType: "application/pdf", size: 10)
        let message = ExteraExportMessage(id: 1, timestamp: 0, author: "🙂", text: "\"\n世界", editedTimestamp: 3, replyToMessageId: 2, attachments: [attachment])
        let doc = ExteraExportDocument(peerId: "9223372036854775807", title: "Chat", exportedAt: Date(timeIntervalSince1970: 0), snapshotMaxMessageId: 1, omittedEphemeralMessages: 0, messages: [message])
        let encoded = try ExteraExportEncoder.json(doc)
        XCTAssertEqual(try JSONDecoder().decode(ExteraExportDocument.self, from: encoded), doc)
        XCTAssertEqual(doc.exportedAt, "1970-01-01T00:00:00Z")
        XCTAssertFalse(doc.messages[0].attachments[0].binaryIncluded)
        XCTAssertEqual(try ExteraExportEncoder.json(doc), encoded)
    }

    func testContentBudgetRejectsLargeTextOrMetadataWithoutMutation() throws {
        var export = ExteraExportAccumulator(maximumContentBytes: 1100)
        let large = message(4, text: String(repeating: "a", count: 100))
        XCTAssertThrowsError(try export.append(ExteraExportPage(messages: [large], sourceIds: [4], reachedEnd: false))) { error in
            XCTAssertEqual(error as? ExteraExportError, .tooMuchContent(1100))
        }
        XCTAssertEqual(export.messageCount, 0)
        XCTAssertEqual(export.offsetId, 0)
        XCTAssertEqual(export.estimatedContentBytes, 0)
        XCTAssertNil(export.snapshotMaxMessageId)
        let attachment = ExteraExportAttachment(kind: "document", fileName: String(repeating: "x", count: 100))
        let metadata = ExteraExportMessage(id: 3, timestamp: 0, text: "", attachments: [attachment])
        var metadataExport = ExteraExportAccumulator(maximumContentBytes: 2000)
        XCTAssertThrowsError(try metadataExport.append(ExteraExportPage(messages: [metadata], sourceIds: [3], reachedEnd: false))) { error in
            XCTAssertEqual(error as? ExteraExportError, .tooMuchContent(2000))
        }
        XCTAssertFalse(export.completed)
    }

    func testHTMLNeverInterpolatesActiveMarkupOrAttachmentPaths() {
        let payload = "<script>alert('x')</script>&\""
        let doc = ExteraExportDocument(peerId: payload, title: payload, exportedAt: Date(timeIntervalSince1970: 0), snapshotMaxMessageId: 1, omittedEphemeralMessages: 0,
                                       messages: [ExteraExportMessage(id: 1, timestamp: 0, author: payload, text: payload, attachments: [ExteraExportAttachment(kind: payload, fileName: "../../evil<img src=x>")])])
        let html = ExteraExportEncoder.html(doc)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("href="))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&amp;&quot;"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
    }
}
