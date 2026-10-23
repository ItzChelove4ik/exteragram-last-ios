import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import ExteraPreferences

/// Journals deleted and edited messages before they are removed from the
/// postbox. Called from patched state replay in AccountStateManagementUtils,
/// where the transaction still holds the message content.
enum ExteraModJournalHooks {
    private static let queue = DispatchQueue(label: "extera.mod.journal", qos: .utility)

    /// Records a message that is about to be deleted.
    static func recordDeletion(transaction: Transaction, ids: [MessageId]) {
        guard ExteraPreferences.standard.value(for: ExteraSettings.keepDeletedLog), !ids.isEmpty else { return }
        let records = ids.compactMap { id -> ExteraModJournal.DeletedRecord? in
            guard let message = transaction.getMessage(id) else { return nil }
            return record(from: message, edited: false, previousText: nil)
        }
        guard !records.isEmpty else { return }
        queue.async {
            for record in records {
                ExteraModJournal.shared.recordDeleted(record)
            }
        }
    }

    /// Records a message that was edited, keeping the previous text.
    static func recordEdit(previous: Message, updatedText: String) {
        guard ExteraPreferences.standard.value(for: ExteraSettings.keepDeletedLog) else { return }
        let record = ExteraModJournal.DeletedRecord(
            peerId: previous.id.peerId.toInt64(),
            messageId: previous.id.id,
            namespace: previous.id.namespace,
            text: updatedText,
            author: previous.author?.displayTitle ?? "",
            timestamp: max(previous.timestamp, Int32(Date().timeIntervalSince1970)),
            edited: true,
            previousText: previous.text
        )
        queue.async {
            ExteraModJournal.shared.recordDeleted(record)
        }
    }

    private static func record(from message: Message, edited: Bool, previousText: String?) -> ExteraModJournal.DeletedRecord? {
        let authorName: String
        if let author = message.author {
            authorName = author.displayTitle
        } else if message.flags.contains(.Incoming) {
            authorName = message.peers[message.id.peerId]?.displayTitle ?? ""
        } else {
            authorName = ""
        }
        let text = message.text.isEmpty ? (message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile).flatMap { $0.fileName ?? "📎" } ?? "📎" : message.text
        return ExteraModJournal.DeletedRecord(
            peerId: message.id.peerId.toInt64(),
            messageId: message.id.id,
            namespace: message.id.namespace,
            text: text,
            author: authorName,
            timestamp: Int32(Date().timeIntervalSince1970),
            edited: edited,
            previousText: previousText
        )
    }
}
