import Foundation
import TelegramCore
import ExteraPreferences

/// Smile mode: the mod deletes its own outgoing text-only messages,
/// keeping only emoji-only content. Deletion is local-first: the message
/// is never enqueued while the mode is on.
enum ExteraSmileModeLocal {
    static func shouldDeleteOutgoing(messages: [EnqueueMessage]) -> Bool {
        guard ExteraPreferences.standard.value(for: ExteraSettings.smileModeEnabled) else { return false }
        // The mode applies to plain text sends only; media, forwards and
        // scheduled sends pass through untouched.
        guard messages.count == 1 else { return false }
        for message in messages {
            switch message {
            case let .message(text, _, _, mediaReference, _, _, _, _, _, _):
                if mediaReference != nil { return false }
                return !ExteraSmileMode.isEmojiOnly(text)
            default:
                return false
            }
        }
        return false
    }
}
