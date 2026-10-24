import Foundation
import UIKit
import Postbox
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import ExteraPreferences
import ExteraResources
import AlertUI
import TemporaryCachedPeerDataManager
import ExteraTranslation

/// Executes GlowGram mod chat commands. Commands are intercepted before the
/// text message is ever enqueued, so nothing reaches the server.
public final class ExteraModCommandHandler {
    private let context: AccountContext
    private let controller: ChatControllerImpl
    private var lastOwnText: String?

    init(context: AccountContext, controller: ChatControllerImpl) {
        self.context = context
        self.controller = controller
    }

    /// Returns true when the input was a mod command and was handled.
    func handleInput(rawText: String, completion: @escaping () -> Void) -> Bool {
        guard ExteraPreferences.standard.value(for: ExteraSettings.modCommandsEnabled) else { return false }
        guard let command = ExteraChatCommand.parse(rawText) else { return false }
        execute(command, completion: completion)
        return true
    }

    /// Records the text of the user's own outgoing messages for /repeat.
    func noteOwnOutgoingMessage(text: String) {
        lastOwnText = text
    }

    private var languageCode: String {
        context.sharedContext.currentPresentationData.with { $0 }.strings.primaryComponent.languageCode
    }

    private func notice(_ key: String, arguments: [CVarArg] = []) {
        let text = String(format: ExteraLocalization.text(key, languageCode: languageCode, table: "ExteraPort"), arguments: arguments)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = textAlertController(context: context, title: nil, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ])
        self.controller.present(controller, in: .window(.root))
    }

    private func execute(_ command: ExteraChatCommand, completion: @escaping () -> Void) {
        switch command {
        case .clean:
            let bytes = ExteraModJournal.shared.storageBytes()
            ExteraModJournal.shared.clearAll()
            notice("ModCleanedCache", arguments: [max(1, Int(bytes / 1024))])
            completion()
        case .saved:
            let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] _ in
                guard let self else { return }
                let chatController = ChatControllerImpl(context: self.context, chatLocation: .peer(id: self.context.account.peerId))
                (self.controller.navigationController as? NavigationController)?.pushViewController(chatController)
                completion()
            })
        case .tagall:
            tagAll(completion: completion)
        case .id:
            let peerId = controller.chatLocation.peerId
            if let peerId = peerId {
                notice(peerId.namespace == Namespaces.Peer.CloudUser ? "ModUserId" : "ModChatId", arguments: [Int(peerId.id._internalGetInt64Value())])
            }
            completion()
        case let .info(address):
            resolveInfo(address: address, completion: completion)
        case .smileMode:
            let store = ExteraPreferences.standard
            let updated = !store.value(for: ExteraSettings.smileModeEnabled)
            try? store.set(updated, for: ExteraSettings.smileModeEnabled)
            if updated {
                notice("ModSmileModeActive")
            } else {
                notice("ModCommandExecuted")
            }
            completion()
        case let .repeatText(text):
            let finalText = text ?? lastOwnText
            if let finalText = finalText, !finalText.isEmpty {
                sendText(finalText)
            }
            completion()
        case let .ban(address):
            resolvePeer(address: address) { [weak self] peer in
                guard let self else { return }
                if let peer = peer {
                    let store = ExteraPreferences.standard
                    var banned = store.value(for: ExteraSettings.locallyBannedPeerIds)
                    let key = peer.id.toInt64()
                    if address != nil {
                        banned.insert(key)
                    } else if let peerId = self.controller.chatLocation.peerId {
                        banned.insert(peerId.toInt64())
                    }
                    try? store.set(banned, for: ExteraSettings.locallyBannedPeerIds)
                    self.notice("ModBannedLocally", arguments: [peer.debugDisplayTitle])
                }
                completion()
            }
        case let .unban(address):
            resolvePeer(address: address) { [weak self] peer in
                guard let self else { return }
                let store = ExteraPreferences.standard
                var banned = store.value(for: ExteraSettings.locallyBannedPeerIds)
                if let address = address, let peer = peer {
                    banned.remove(peer.id.toInt64())
                    self.notice("ModUnbannedLocally", arguments: [peer.debugDisplayTitle])
                } else if let peerId = self.controller.chatLocation.peerId {
                    banned.remove(peerId.toInt64())
                    self.notice("ModUnbannedLocally", arguments: [""])
                }
                try? store.set(banned, for: ExteraSettings.locallyBannedPeerIds)
                completion()
            }
        case let .mute(address, duration):
            let resolvedDuration = duration ?? .fiveMinutes
            resolvePeer(address: address) { [weak self] peer in
                guard let self else { return }
                let target: Int64
                if let peer = peer, address != nil {
                    target = peer.id.toInt64()
                } else if let peerId = self.controller.chatLocation.peerId {
                    target = peerId.toInt64()
                } else {
                    completion()
                    return
                }
                let store = ExteraPreferences.standard
                let expiries = ExteraPeerMuting.mute(peerId: target, duration: resolvedDuration, expiries: store.value(for: ExteraSettings.mutedPeerExpiries))
                try? store.set(expiries, for: ExteraSettings.mutedPeerExpiries)
                self.notice("ModMutedFor", arguments: [resolvedDuration.label])
                completion()
            }
        case let .unmute(address):
            resolvePeer(address: address) { [weak self] peer in
                guard let self else { return }
                let store = ExteraPreferences.standard
                var expiries = store.value(for: ExteraSettings.mutedPeerExpiries)
                if let peer = peer, address != nil {
                    expiries = ExteraPeerMuting.unmute(peerId: peer.id.toInt64(), expiries: expiries)
                } else if let peerId = self.controller.chatLocation.peerId {
                    expiries = ExteraPeerMuting.unmute(peerId: peerId.toInt64(), expiries: expiries)
                }
                try? store.set(expiries, for: ExteraSettings.mutedPeerExpiries)
                self.notice("ModCommandExecuted")
                completion()
            }
        }
    }

    private func sendText(_ text: String) {
        let peerId = controller.chatLocation.peerId
        guard let peerId = peerId else { return }
        let message = EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: controller.chatLocation.threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [message]).start()
        noteOwnOutgoingMessage(text: text)
    }

    private func tagAll(completion: @escaping () -> Void) {
        guard let peerId = controller.chatLocation.peerId else {
            completion()
            return
        }
        var completed = false
        let finish: () -> Void = { [weak self] in
            guard !completed else { return }
            completed = true
            completion()
            _ = self
        }
        let (disposable, _) = context.peerChannelMemberCategoriesContextsManager.recent(engine: context.engine, accountPeerId: context.account.peerId, peerId: peerId, searchQuery: nil, requestUpdate: false, updated: { [weak self] state in
            if case .ready = state.loadingState {
                let peers = state.list.compactMap { participant -> EnginePeer? in
                    if participant.peer.isDeleted || participant.peer.id == self?.context.account.peerId {
                        return nil
                    }
                    return EnginePeer(participant.peer)
                }
                DispatchQueue.main.async {
                    guard let self, !completed else { return }
                    completed = true
                    let mentions = peers.prefix(200).compactMap { peer -> String? in
                        if let addressName = peer.addressName {
                            return "@\(addressName)"
                        }
                        return nil
                    }
                    let text = mentions.joined(separator: " ")
                    if !text.isEmpty {
                        self.sendText(text)
                    }
                    completion()
                }
            }
        })
        // Give the member list two seconds; /tagall in a private chat or a
        // missing list simply does nothing rather than hanging forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            finish()
        }
        // The category context keeps its own lifetime; releasing the starter
        // disposable is safe after the first ready state arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            disposable.dispose()
        }
    }

    private func resolvePeer(address: String?, completion: @escaping (EnginePeer?) -> Void) {
        if let address = address?.trimmingCharacters(in: .whitespaces) {
            var cleaned = address
            if cleaned.hasPrefix("@") {
                cleaned = String(cleaned.dropFirst())
            }
            let _ = (context.engine.contacts.searchLocalPeers(query: cleaned)
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { peers in
                let exact = peers.first { $0.peer?.addressName == cleaned } ?? peers.first
                completion(exact?.peer)
            })
        } else if let peerId = controller.chatLocation.peerId {
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).startStandalone(next: { peer in
                completion(peer)
            })
        } else {
            completion(nil)
        }
    }

    private func resolveInfo(address: String?, completion: @escaping () -> Void) {
        resolvePeer(address: address) { [weak self] peer in
            guard let self else { return }
            guard let peer = peer else {
                completion()
                return
            }
            var lines: [String] = []
            lines.append(peer.debugDisplayTitle)
            if case let .user(user) = peer {
                if let name = user.addressName, !name.isEmpty {
                    lines.append("@\(name)")
                }
                if let phone = user.phone {
                    lines.append("+\(phone)")
                }
                if user.isPremium {
                    lines.append("Premium")
                }
            }
            lines.append("ID: \(peer.id.id._internalGetInt64Value())")
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let controller = textAlertController(context: context, title: nil, text: lines.joined(separator: "\n"), actions: [
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ])
            self.controller.present(controller, in: .window(.root))
            completion()
        }
    }
}
