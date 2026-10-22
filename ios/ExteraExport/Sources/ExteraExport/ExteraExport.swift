import Foundation

public struct ExteraExportAttachment: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String?
    public let fileName: String?
    public let mimeType: String?
    public let size: Int64?
    public let binaryIncluded: Bool

    public init(kind: String, id: String? = nil, fileName: String? = nil, mimeType: String? = nil, size: Int64? = nil) {
        self.kind = kind; self.id = id; self.fileName = fileName; self.mimeType = mimeType; self.size = size
        self.binaryIncluded = false
    }
}

public struct ExteraExportMessage: Codable, Equatable, Sendable {
    public let id: Int32
    public let timestamp: Int64
    public let authorId: String?
    public let author: String?
    public let text: String
    public let kind: String
    public let editedTimestamp: Int64?
    public let replyToMessageId: Int32?
    public let attachments: [ExteraExportAttachment]

    public init(id: Int32, timestamp: Int64, authorId: String? = nil, author: String? = nil, text: String,
                kind: String = "message", editedTimestamp: Int64? = nil, replyToMessageId: Int32? = nil,
                attachments: [ExteraExportAttachment] = []) {
        self.id = id; self.timestamp = timestamp; self.authorId = authorId; self.author = author; self.text = text
        self.kind = kind; self.editedTimestamp = editedTimestamp; self.replyToMessageId = replyToMessageId; self.attachments = attachments
    }
}

public struct ExteraExportDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generator: String
    public let peerId: String
    public let title: String
    public let exportedAt: String
    public let scope: String
    public let completed: Bool
    public let snapshotMaxMessageId: Int32?
    public let omittedEphemeralMessages: Int
    public let limitations: [String]
    public let messages: [ExteraExportMessage]

    public init(peerId: String, title: String, exportedAt: Date, snapshotMaxMessageId: Int32?, omittedEphemeralMessages: Int,
                messages: [ExteraExportMessage]) {
        schemaVersion = 1
        generator = "exteraGram iOS"
        self.peerId = peerId; self.title = title
        self.exportedAt = ExteraExportEncoder.utcDate(exportedAt)
        scope = "All cloud history returned for this peer up to snapshotMaxMessageId"
        completed = true
        self.snapshotMaxMessageId = snapshotMaxMessageId
        self.omittedEphemeralMessages = omittedEphemeralMessages
        limitations = ["Text and attachment metadata only; media binaries are not included.",
                      "Deleted, inaccessible and ephemeral messages are not included.",
                      "History before a group migration belongs to a different peer and is not included.",
                      "This is a live paginated export; messages edited or deleted during export can change the result.",
                      "Rich-text entities, reactions, poll choices and detailed service-action payloads are not encoded."]
        self.messages = messages.sorted { $0.id < $1.id }
    }
}

public struct ExteraExportPage: Equatable, Sendable {
    public let messages: [ExteraExportMessage]
    /// Every server record ID, including omitted ephemeral and unrenderable records.
    public let sourceIds: [Int32]
    public let omittedEphemeralMessages: Int
    /// True only after a successful server response with no records.
    public let reachedEnd: Bool

    public init(messages: [ExteraExportMessage], sourceIds: [Int32], omittedEphemeralMessages: Int = 0, reachedEnd: Bool) {
        self.messages = messages; self.sourceIds = sourceIds
        self.omittedEphemeralMessages = omittedEphemeralMessages; self.reachedEnd = reachedEnd
    }
}

public enum ExteraExportError: Error, Equatable, Sendable {
    case invalidPage
    case nonAdvancingPage
    case tooManyMessages(Int)
    case tooMuchContent(Int)
    case notCompleted
}

/// One peer's strictly descending server-ID cursor, with a fixed first-page
/// upper bound. A failed, repeated or capped request cannot become success.
public struct ExteraExportAccumulator: Sendable {
    public private(set) var offsetId: Int32 = 0
    public private(set) var snapshotMaxMessageId: Int32?
    public private(set) var completed = false
    public private(set) var failed = false
    public private(set) var omittedEphemeralMessages = 0
    public private(set) var estimatedContentBytes = 0
    private var records: [Int32: ExteraExportMessage] = [:]
    private var sourceCount = 0
    private let maximumMessages: Int
    private let maximumContentBytes: Int

    public init(maximumMessages: Int = 100_000, maximumContentBytes: Int = 20 * 1024 * 1024) {
        self.maximumMessages = max(1, maximumMessages)
        self.maximumContentBytes = max(1, maximumContentBytes)
    }
    public var messageCount: Int { records.count }

    public mutating func append(_ page: ExteraExportPage) throws {
        guard !failed else { throw ExteraExportError.invalidPage }
        do { try appendValidated(page) }
        catch { failed = true; throw error }
    }

    private mutating func appendValidated(_ page: ExteraExportPage) throws {
        guard !completed, page.omittedEphemeralMessages >= 0, page.omittedEphemeralMessages <= page.sourceIds.count,
              page.reachedEnd == page.sourceIds.isEmpty,
              page.sourceIds.allSatisfy({ $0 > 0 }),
              Set(page.sourceIds).count == page.sourceIds.count,
              Set(page.messages.map(\.id)).count == page.messages.count,
              page.messages.allSatisfy({ page.sourceIds.contains($0.id) }) else { throw ExteraExportError.invalidPage }
        if page.reachedEnd {
            guard page.messages.isEmpty, page.omittedEphemeralMessages == 0 else { throw ExteraExportError.invalidPage }
            completed = true
            return
        }
        guard let minimum = page.sourceIds.min(), let maximum = page.sourceIds.max(),
              offsetId == 0 || maximum < offsetId else { throw ExteraExportError.nonAdvancingPage }
        guard sourceCount <= maximumMessages - page.sourceIds.count else { throw ExteraExportError.tooManyMessages(maximumMessages) }
        // Bound retained content as well as message count. Twelve bytes per
        // input UTF-8 byte cover worst-case escaping in both output formats;
        // fixed per-record/attachment allowances cover surrounding structure.
        let contentLimit = maximumContentBytes
        let remaining = contentLimit - estimatedContentBytes
        var added = 0
        func charge(_ count: Int, factor: Int = 1) throws {
            guard count <= (remaining - added) / factor else { throw ExteraExportError.tooMuchContent(contentLimit) }
            added += count * factor
        }
        try charge(page.messages.count, factor: 1024)
        for message in page.messages {
            for value in [message.text, message.author, message.authorId, message.kind].compactMap({ $0 }) { try charge(value.utf8.count, factor: 12) }
            try charge(message.attachments.count, factor: 512)
            for attachment in message.attachments {
                for value in [attachment.kind, attachment.id, attachment.fileName, attachment.mimeType].compactMap({ $0 }) { try charge(value.utf8.count, factor: 12) }
            }
        }
        if snapshotMaxMessageId == nil { snapshotMaxMessageId = maximum }
        guard maximum <= (snapshotMaxMessageId ?? maximum) else { throw ExteraExportError.invalidPage }
        for message in page.messages { records[message.id] = message }
        sourceCount += page.sourceIds.count
        omittedEphemeralMessages += page.omittedEphemeralMessages
        estimatedContentBytes += added
        offsetId = minimum
    }

    public func document(peerId: String, title: String, exportedAt: Date = Date()) throws -> ExteraExportDocument {
        guard completed && !failed else { throw ExteraExportError.notCompleted }
        return ExteraExportDocument(peerId: peerId, title: title, exportedAt: exportedAt, snapshotMaxMessageId: snapshotMaxMessageId,
                                    omittedEphemeralMessages: omittedEphemeralMessages, messages: Array(records.values))
    }
}

public enum ExteraExportEncoder {
    public static func utcDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func json(_ document: ExteraExportDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// All dynamic content is text. No external assets, scripts, active links,
    /// or document paths derived from attachment file names are generated.
    public static func html(_ document: ExteraExportDocument) -> String {
        var result = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>\(escapeHTML(document.title))</title><style>body{font:16px system-ui;max-width:56rem;margin:2rem auto;padding:0 1rem;color:#17212b}article{border-top:1px solid #ddd;padding:1rem 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}small{color:#555}li{overflow-wrap:anywhere}</style></head><body>"
        result += "<h1>\(escapeHTML(document.title))</h1><p>Peer: \(escapeHTML(document.peerId)) · Exported: \(escapeHTML(document.exportedAt))</p><p>\(escapeHTML(document.scope))</p><p>Messages: \(document.messages.count). Omitted ephemeral records: \(document.omittedEphemeralMessages).</p><ul>"
        for limitation in document.limitations { result += "<li>\(escapeHTML(limitation))</li>" }
        result += "</ul>"
        for message in document.messages {
            let date = utcDate(Date(timeIntervalSince1970: TimeInterval(message.timestamp)))
            result += "<article id=\"message-\(message.id)\"><b>\(escapeHTML(message.author ?? message.authorId ?? "Unknown author"))</b><br><small>#\(message.id) · \(escapeHTML(date)) · \(escapeHTML(message.kind))</small>"
            if let reply = message.replyToMessageId { result += "<p>Reply to #\(reply)</p>" }
            if let edited = message.editedTimestamp { result += "<p>Edited: \(escapeHTML(utcDate(Date(timeIntervalSince1970: TimeInterval(edited)))))</p>" }
            result += "<pre>\(escapeHTML(message.text))</pre>"
            if !message.attachments.isEmpty {
                result += "<ul>"
                for attachment in message.attachments {
                    let fields = [attachment.kind, attachment.fileName, attachment.mimeType, attachment.size.map { "\($0) bytes" }, attachment.id].compactMap { $0 }
                    result += "<li>\(escapeHTML(fields.joined(separator: " · "))) (binary not included)</li>"
                }
                result += "</ul>"
            }
            result += "</article>"
        }
        return result + "</body></html>"
    }

    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
