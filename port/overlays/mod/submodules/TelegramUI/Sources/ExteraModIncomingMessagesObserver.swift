import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import ExteraPreferences
import ExteraTranslation

/// Subscribes to incoming notification messages and runs the mod's
/// local, silent features: Chat Observatory counters and auto-translation.
final class ExteraModIncomingMessagesObserver {
    private var disposable: Disposable?
    private var seenMessageIds = Set<MessageId>()
    private var translationInFlight = Set<MessageId>()
    private let translationLock = NSLock()

    init(context: AccountContext) {
        self.disposable = (context.account.stateManager.notificationMessages
        |> deliverOnMainQueue).start(next: { [weak self] batches in
            guard let self else { return }
            for (messages, _, _, _) in batches {
                for message in messages {
                    self.process(message: message, context: context)
                }
            }
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    private func process(message: Message, context: AccountContext) {
        // Chat Observatory: count every incoming message once.
        if !seenMessageIds.contains(message.id) {
            seenMessageIds.insert(message.id)
            if seenMessageIds.count > 20000 {
                seenMessageIds = Set(seenMessageIds.suffix(10000))
            }
            if ExteraPreferences.standard.value(for: ExteraSettings.chatObservatoryEnabled) {
                ExteraModJournal.shared.recordMessageReceived(at: Date(timeIntervalSince1970: TimeInterval(message.timestamp)))
            }
        }

        // Auto-translate incoming text messages.
        if ExteraPreferences.standard.value(for: ExteraSettings.autoTranslateIncoming) {
            autoTranslate(message: message, context: context)
        }
    }

    private func autoTranslate(message: Message, context: AccountContext) {
        guard message.flags.intersection(.IsIncomingMask).contains(.Incoming) else { return }
        guard !message.text.isEmpty, message.text.count <= 4000 else { return }
        guard !message.isCopyProtected() else { return }
        let store = ExteraPreferences.standard
        let target = store.value(for: ExteraSettings.modTranslationTarget)
        let appLanguage = context.sharedContext.currentPresentationData.with { $0 }.strings.primaryComponent.languageCode
        let resolvedTarget = target.isEmpty ? appLanguage : target
        for attribute in message.attributes {
            if let translation = attribute as? TranslationMessageAttribute, translation.toLang == resolvedTarget {
                return
            }
        }
        let provider = ExteraTranslationProvider(rawValue: store.value(for: ExteraSettings.translationProvider)) ?? .google
        guard provider != .telegram else { return }

        translationLock.lock()
        let alreadyRunning = translationInFlight.contains(message.id)
        if !alreadyRunning {
            translationInFlight.insert(message.id)
        }
        translationLock.unlock()
        guard !alreadyRunning else { return }

        let client = ExteraTranslationClient()
        let messageId = message.id
        let text = message.text
        Task { [weak context] in
            defer {
                self.translationLock.lock()
                self.translationInFlight.remove(messageId)
                self.translationLock.unlock()
            }
            guard let context else { return }
            do {
                let translated = try await client.translate(text, to: resolvedTarget, provider: provider)
                let attribute = TranslationMessageAttribute(text: translated, entities: [], toLang: resolvedTarget)
                let _ = (context.account.postbox.transaction({ transaction -> Void in
                    transaction.updateMessage(messageId, update: { currentMessage in
                        var attributes = currentMessage.attributes
                        attributes.removeAll(where: { $0 is TranslationMessageAttribute })
                        attributes.append(attribute)
                        var storeForwardInfo: StoreMessageForwardInfo?
                        if let forwardInfo = currentMessage.forwardInfo {
                            storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                        }
                        return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
                    })
                })).start()
            } catch {
                // Best-effort: leave the original text untouched.
            }
        }
    }
}
