import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit
import ExteraExport

public enum ExteraExportHistoryError: Error {
    case unavailablePeer
    case unsupportedPeer
    case copyProtected
    case requestFailed(String)
    case invalidResponse
}

/// Reads a cloud peer's history without converting RPC errors into an empty
/// successful page. It does not mark messages read or alter the local history.
/// Forum/monoforum/secret histories need separate scope semantics and are rejected.
public func exteraExportCloudHistoryPage(account: Account, peerId: EnginePeer.Id, offsetId: Int32,
                                        snapshotMaxMessageId: Int32?) -> Signal<ExteraExportPage, ExteraExportHistoryError> {
    return account.postbox.transaction { transaction -> Peer? in transaction.getPeer(peerId) }
    |> castError(ExteraExportHistoryError.self)
    |> mapToSignal { peer -> Signal<ExteraExportPage, ExteraExportHistoryError> in
        guard let peer, let inputPeer = apiInputPeer(peer) else { return .fail(.unavailablePeer) }
        guard peerId.namespace != Namespaces.Peer.SecretChat, !peer.isForumOrMonoForum else { return .fail(.unsupportedPeer) }
        guard !peer.isCopyProtectionEnabled else { return .fail(.copyProtected) }
        let maxId = snapshotMaxMessageId.map { $0 < Int32.max ? $0 + 1 : Int32.max } ?? Int32.max
        return account.network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: offsetId, offsetDate: 0,
            addOffset: 0, limit: 100, maxId: maxId, minId: 0, hash: 0), automaticFloodWait: false)
        |> mapError { ExteraExportHistoryError.requestFailed($0.errorDescription) }
        |> mapToSignal { result -> Signal<ExteraExportPage, ExteraExportHistoryError> in
            let messages: [Api.Message]
            let chats: [Api.Chat]
            let users: [Api.User]
            switch result {
            case let .messages(value): messages = value.messages; chats = value.chats; users = value.users
            case let .messagesSlice(value): messages = value.messages; chats = value.chats; users = value.users
            case let .channelMessages(value): messages = value.messages; chats = value.chats; users = value.users
            case .messagesNotModified: return .fail(.invalidResponse)
            }
            return account.postbox.transaction { transaction -> Result<ExteraExportPage, ExteraExportHistoryError> in
                // Merge only into this temporary rendering map; exporting must
                // not insert a remote history page into the user's Postbox.
                var peers: [PeerId: Peer] = [peer.id: peer]
                for user in users {
                    if let user = TelegramUser.merge(transaction.getPeer(user.peerId) as? TelegramUser, rhs: user) { peers[user.id] = user }
                }
                for chat in chats {
                    if let chat = mergeGroupOrChannel(lhs: transaction.getPeer(chat.peerId), rhs: chat) { peers[chat.id] = chat }
                }
                var records: [ExteraExportMessage] = []
                var omitted = 0
                for apiMessage in messages {
                    if case .messageEmpty = apiMessage {
                        records.append(ExteraExportMessage(id: apiMessage.rawId, timestamp: 0, text: "", kind: "unavailable"))
                        continue
                    }
                    guard let stored = StoreMessage(apiMessage: apiMessage, accountPeerId: account.peerId, peerIsForum: false),
                          let message = locallyRenderedMessage(message: stored, peers: peers), message.id.peerId == peerId else {
                        return .failure(.invalidResponse)
                    }
                    guard !message.isCopyProtected() else { return .failure(.copyProtected) }
                    if message.minAutoremoveOrClearTimeout != nil || message.containsSecretMedia { omitted += 1; continue }
                    var reply: Int32?
                    for attribute in message.attributes {
                        if let attribute = attribute as? ReplyMessageAttribute, attribute.messageId.peerId == peerId { reply = attribute.messageId.id }
                    }
                    var attachments: [ExteraExportAttachment] = []
                    var kind = "message"
                    for media in message.effectiveMedia {
                        if let file = media as? TelegramMediaFile {
                            attachments.append(ExteraExportAttachment(kind: file.isVoice ? "voice" : (file.isInstantVideo ? "round_video" : "document"),
                                id: String(file.fileId.id), fileName: file.fileName, mimeType: file.mimeType, size: file.size))
                        } else if let image = media as? TelegramMediaImage {
                            attachments.append(ExteraExportAttachment(kind: "photo", id: String(image.imageId.id)))
                        } else if media is TelegramMediaAction {
                            kind = "service"
                        } else {
                            attachments.append(ExteraExportAttachment(kind: "other_media"))
                        }
                    }
                    records.append(ExteraExportMessage(id: message.id.id, timestamp: Int64(message.timestamp),
                        authorId: message.author.map { String($0.id.toInt64()) }, author: message.author?.debugDisplayTitle,
                        text: message.text, kind: kind, editedTimestamp: message.editedTime.map(Int64.init), replyToMessageId: reply, attachments: attachments))
                }
                return .success(ExteraExportPage(messages: records, sourceIds: messages.map(\.rawId), omittedEphemeralMessages: omitted, reachedEnd: messages.isEmpty))
            }
            |> castError(ExteraExportHistoryError.self)
            |> mapToSignal { result -> Signal<ExteraExportPage, ExteraExportHistoryError> in
                switch result { case let .success(page): return .single(page); case let .failure(error): return .fail(error) }
            }
        }
    }
}
