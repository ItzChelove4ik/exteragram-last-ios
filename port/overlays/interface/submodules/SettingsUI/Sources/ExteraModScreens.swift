import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import ExteraPreferences
import ExteraResources

/// Viewer for the locally stored deleted/edited message log.
func exteraDeletedLogController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, EmptyModArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModDeletedLog", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(
                content: .text(presentationData.strings.Common_Delete),
                style: .regular,
                enabled: true,
                action: {
                    ExteraModJournal.shared.clearDeleted()
                    reload.set(revision.modify { $0 + 1 })
                }
            ),
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0
        let records = ExteraModJournal.shared.deletedRecords(limit: 300)
        if records.isEmpty {
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(modLoc("ModChatObservatoryNoData", languageCode))))
            stableId += 1
        } else {
            for record in records {
                entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .deletedRecord(record)))
                stableId += 1
            }
        }
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (list, EmptyModArguments()))
    }
    _ = store
    return ItemListController(context: context, state: signal)
}

final class EmptyModArguments {}

/// Privacy Lens settings: per-scenario contextual privacy rules.
func exteraPrivacyLensController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)

    func setPreference<Value: Codable & Equatable & Sendable>(_ value: Value, for preference: ExteraPreference<Value>) {
        try? store.set(value, for: preference)
        reload.set(revision.modify { $0 + 1 })
    }

    struct PrivacyLensArguments {
        let update: (Bool, ExteraPreference<Bool>) -> Void
        let selectProtectedChats: () -> Void
        let clearProtectedChats: () -> Void
    }

    let arguments = PrivacyLensArguments(
        update: { value, preference in
            setPreference(value, for: preference)
        },
        selectProtectedChats: {
            // Chat selection opens the standard chat picker; picked ids are
            // written to privacyLensProtectedPeerIds by the picker callback.
            let current = Set(store.value(for: ExteraSettings.privacyLensProtectedPeerIds))
            let peerId = context.account.peerId.toInt64()
            var updated = current
            if current.contains(peerId) {
                updated.remove(peerId)
            } else {
                updated.insert(peerId)
            }
            setPreference(updated, for: ExteraSettings.privacyLensProtectedPeerIds)
        },
        clearProtectedChats: {
            setPreference(Set<Int64>(), for: ExteraSettings.privacyLensProtectedPeerIds)
        }
    )

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, PrivacyLensArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModPrivacyLens", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0
        var section: ItemListSectionId = 0

        func addToggle(_ key: String, _ infoKey: String, _ preference: ExteraPreference<Bool>) {
            let title = modLoc(key, languageCode)
            let info = modLoc(infoKey, languageCode)
            let value = store.value(for: preference)
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .toggle(title: title, info: info, value: value, action: { newValue in
                arguments.update(newValue, preference)
            }), section: section))
            stableId += 1
        }

        addToggle("ModPrivacyLensBlurMessages", "ModPrivacyLensBlurMessagesInfo", ExteraSettings.privacyLensBlurMessages)
        addToggle("ModPrivacyLensProtectChats", "ModPrivacyLensProtectChatsInfo", ExteraSettings.privacyLensProtectChats)
        let protectedCount = store.value(for: ExteraSettings.privacyLensProtectedPeerIds).count
        let protectedLabel = protectedCount == 0 ? modLoc("ModPrivacyLensProtectedChatsEmpty", languageCode) : "\(protectedCount)"
        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .disclosure(title: modLoc("ModPrivacyLensProtectedChats", languageCode), info: nil, label: protectedLabel, action: {
            arguments.selectProtectedChats()
        }), section: section))
        stableId += 1
        section += 1
        addToggle("ModPrivacyLensHidePushPreview", "ModPrivacyLensHidePushPreviewInfo", ExteraSettings.privacyLensHidePushPreview)
        addToggle("ModPrivacyLensBlurOnBackground", "ModPrivacyLensBlurOnBackgroundInfo", ExteraSettings.privacyLensBlurOnBackground)
        _ = section

        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (list, arguments))
    }
    return ItemListController(context: context, state: signal)
}

/// Round video message playback settings.
func exteraRoundVideoController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)

    func setPreference<Value: Codable & Equatable & Sendable>(_ value: Value, for preference: ExteraPreference<Value>) {
        try? store.set(value, for: preference)
        reload.set(revision.modify { $0 + 1 })
    }

    struct RoundVideoArguments {}

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, RoundVideoArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModRoundVideo", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0

        let speed = store.value(for: ExteraSettings.roundVideoSpeed)
        let speedLabel = String(format: "%.1fx", speed)
        let speedValues: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0]
        for value in speedValues {
            let isCurrent = abs(value - speed) < 0.05
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .disclosure(title: String(format: "%.1fx", value), info: nil, label: isCurrent ? "✓" : nil, action: {
                setPreference(value, for: ExteraSettings.roundVideoSpeed)
            })))
            stableId += 1
        }
        _ = speedLabel

        let preferQuality = store.value(for: ExteraSettings.roundVideoPreferQuality)
        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .toggle(title: modLoc("ModRoundVideoQuality", languageCode), info: modLoc("ModRoundVideoQualityInfo", languageCode), value: preferQuality, action: { newValue in
            setPreference(newValue, for: ExteraSettings.roundVideoPreferQuality)
        })))
        stableId += 1

        let autoRotate = store.value(for: ExteraSettings.roundVideoAutoRotate)
        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .toggle(title: modLoc("ModRoundVideoAutoRotate", languageCode), info: modLoc("ModRoundVideoAutoRotateInfo", languageCode), value: autoRotate, action: { newValue in
            setPreference(newValue, for: ExteraSettings.roundVideoAutoRotate)
        })))
        stableId += 1

        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (list, RoundVideoArguments()))
    }
    return ItemListController(context: context, state: signal)
}

/// Chat commands help screen.
func exteraCommandsHelpController(context: AccountContext) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, EmptyModArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModCommandsTitle", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0
        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(modLoc("ModCommandsInfo", languageCode))))
        stableId += 1
        let commandKeys = ["ModCommandClean", "ModCommandSaved", "ModCommandTagall", "ModCommandId", "ModCommandInfo", "ModCommandSmileMode", "ModCommandRepeat", "ModCommandBan", "ModCommandUnban", "ModCommandMute", "ModCommandUnmute"]
        for key in commandKeys {
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(modLoc(key, languageCode))))
            stableId += 1
        }
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (list, EmptyModArguments()))
    }
    return ItemListController(context: context, state: signal)
}
