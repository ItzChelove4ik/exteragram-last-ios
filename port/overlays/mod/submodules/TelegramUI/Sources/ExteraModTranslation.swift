import Foundation
import Postbox
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import ExteraPreferences
import ExteraResources
import ExteraTranslation
import TranslateUI

/// Presentation entry point for the mod's Translate action on a message.
/// Reuses the fork's translation sheet with the mod-configured target
/// language and selected provider.
enum ExteraModTranslation {
    static func present(context: AccountContext, message: Message) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let store = ExteraPreferences.standard
        let provider = ExteraTranslationProvider(rawValue: store.value(for: ExteraSettings.translationProvider)) ?? .google
        let preferredTarget = store.value(for: ExteraSettings.modTranslationTarget)
        let appLanguage = presentationData.strings.primaryComponent.languageCode
        let target = preferredTarget.isEmpty ? appLanguage : preferredTarget
        var entities: [MessageTextEntity] = []
        for attribute in message.attributes {
            if let attribute = attribute as? TextEntitiesMessageAttribute {
                entities = attribute.entities
                break
            }
        }
        presentExteraTranslation(context: context, text: message.text, entities: entities, canCopy: !message.isCopyProtected(), fromLanguage: nil, toLanguage: target, provider: provider, replaceText: nil as ((String, [MessageTextEntity]) -> Void)?, wasDismissed: nil as (() -> Void)?)
    }

    /// Auto-translate hook for incoming messages. Runs silently and updates
    /// the message with a TranslationMessageAttribute so the chat renders
    /// the translated text inline, the same way native auto-translate does.
    static func autoTranslateIfNeeded(context: AccountContext, message: Message) {
        let store = ExteraPreferences.standard
        guard store.value(for: ExteraSettings.autoTranslateIncoming) else { return }
        guard !message.flags.intersection(.IsIncomingMask).isEmpty else { return }
        guard !message.text.isEmpty, message.text.count < 4000 else { return }
        guard !message.isCopyProtected() else { return }
        for attribute in message.attributes {
            if let translation = attribute as? TranslationMessageAttribute, translation.toLang == store.value(for: ExteraSettings.modTranslationTarget) {
                return
            }
        }
        let target = store.value(for: ExteraSettings.modTranslationTarget)
        let appLanguage = context.sharedContext.currentPresentationData.with { $0 }.strings.primaryComponent.languageCode
        let resolvedTarget = target.isEmpty ? appLanguage : target
        let provider = ExteraTranslationProvider(rawValue: store.value(for: ExteraSettings.translationProvider)) ?? .google
        guard provider != .telegram else { return }
        let client = ExteraTranslationClient()
        let messageId = message.id
        Task { [weak context] in
            guard let context else { return }
            do {
                let translated = try await client.translate(message.text, to: resolvedTarget, provider: provider)
                let attribute = TranslationMessageAttribute(text: translated, entities: [], toLang: resolvedTarget)
                let _ = context.account.postbox.transaction({ transaction -> Void in
                    transaction.updateMessage(messageId, update: { currentMessage in
                        var attributes = currentMessage.attributes
                        attributes.removeAll(where: { $0 is TranslationMessageAttribute })
                        attributes.append(attribute)
                        var storeForwardInfo: StoreMessageForwardInfo?
                        if let forwardInfo = currentMessage.forwardInfo {
                            storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                        }
                        return .update(StoreMessage(id: .Id(currentMessage.id), customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
                    })
                }).start()
            } catch {
                // Silent failure: auto-translation is best-effort.
            }
        }
    }
}
