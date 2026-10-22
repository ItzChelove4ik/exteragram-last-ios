import Foundation
import Postbox
import TelegramCore
import ExteraPreferences

enum ExteraReactionChatKind: Equatable {
    case channel
    case group
    case privateChat
    case unknown
}

func exteraReactionChatKind(peer: Peer?, namespace: PeerId.Namespace) -> ExteraReactionChatKind {
    if let channel = peer as? TelegramChannel {
        switch channel.info {
        case .broadcast:
            return .channel
        case .group:
            return .group
        }
    }
    if peer is TelegramGroup || namespace == Namespaces.Peer.CloudGroup {
        return .group
    }
    if peer is TelegramUser || namespace == Namespaces.Peer.CloudUser || namespace == Namespaces.Peer.SecretChat {
        return .privateChat
    }
    // A missing CloudChannel peer does not tell us whether it is a channel or
    // supergroup. Keep its reactions rather than apply the wrong preference.
    return .unknown
}

func exteraHideReactions(kind: ExteraReactionChatKind, channels: Bool, groups: Bool, privateChats: Bool) -> Bool {
    switch kind {
    case .channel:
        return channels
    case .group:
        return groups
    case .privateChat:
        return privateChats
    case .unknown:
        return false
    }
}

/// Display policy only. Never modifies the message's attributes or engine data.
public func exteraShouldHideMessageReactions(message: Message) -> Bool {
    let kind = exteraReactionChatKind(peer: message.peers[message.id.peerId], namespace: message.id.peerId.namespace)
    let settings = ExteraPreferences.standard
    return exteraHideReactions(
        kind: kind,
        channels: settings.value(for: ExteraSettings.hideReactionsInChannels),
        groups: settings.value(for: ExteraSettings.hideReactionsInGroups),
        privateChats: settings.value(for: ExteraSettings.hideReactionsInPrivateChats)
    )
}

/// A UI projection of the original merged attributes, including pending local
/// reactions. Returning nil only suppresses their presentation in chat cells.
public func exteraVisibleMessageReactions(message: Message, isTags: Bool) -> ReactionsMessageAttribute? {
    if exteraShouldHideMessageReactions(message: message) {
        return nil
    }
    return mergedMessageReactions(attributes: message.attributes, isTags: isTags)
}

/// Used by inline date/status renderers for both reaction buttons and peer icons.
public func exteraVisibleMessageReactionsAndPeers(accountPeerId: EnginePeer.Id, accountPeer: EnginePeer?, message: Message) -> (reactions: [MessageReaction], peers: [(MessageReaction.Reaction, EnginePeer)]) {
    if exteraShouldHideMessageReactions(message: message) {
        return ([], [])
    }
    return mergedMessageReactionsAndPeers(accountPeerId: accountPeerId, accountPeer: accountPeer, message: message)
}
