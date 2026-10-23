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

/// Chat Observatory: local-only usage statistics with counters and bar charts.
func exteraObservatoryController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, EmptyModArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModChatObservatory", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(
                content: .text(modLoc("ModChatObservatoryReset", languageCode)),
                style: .regular,
                enabled: true,
                action: {
                    ExteraModJournal.shared.resetObservatory()
                    reload.set(revision.modify { $0 + 1 })
                }
            ),
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0
        var section: ItemListSectionId = 0

        let enabled = store.value(for: ExteraSettings.chatObservatoryEnabled)
        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .toggle(title: modLoc("ModChatObservatoryEnabled", languageCode), info: nil, value: enabled, action: { newValue in
            try? store.set(newValue, for: ExteraSettings.chatObservatoryEnabled)
            reload.set(revision.modify { $0 + 1 })
        }), section: section))
        stableId += 1

        let totals = ExteraModJournal.shared.observatoryTotals()
        if totals.sent == 0 && totals.received == 0 && totals.days.isEmpty {
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(modLoc("ModChatObservatoryNoData", languageCode)), section: section))
            stableId += 1
        } else {
            section += 1
            let messagesLabel = modLoc("ModChatObservatoryMessagesLabel", languageCode)
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .counter(title: modLoc("ModChatObservatorySent", languageCode), value: "\(totals.sent) \(messagesLabel)"), section: section))
            stableId += 1
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .counter(title: modLoc("ModChatObservatoryReceived", languageCode), value: "\(totals.received) \(messagesLabel)"), section: section))
            stableId += 1
            let totalSeconds = totals.days.values.reduce(0.0) { $0 + $1.secondsInApp }
            let hoursLabel = modLoc("ModChatObservatoryHoursLabel", languageCode)
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .counter(title: modLoc("ModChatObservatoryTimeInApp", languageCode), value: String(format: "%.1f %@", totalSeconds / 3600.0, hoursLabel)), section: section))
            stableId += 1

            // Most active hours as a histogram of text bars.
            section += 1
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .sectionHeader(modLoc("ModChatObservatoryActiveHours", languageCode)), section: section))
            stableId += 1
            let maxHour = totals.hourHistogram.max() ?? 0
            if maxHour > 0 {
                for hour in 0..<24 where totals.hourHistogram[hour] > 0 {
                    entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .hourBar(hour: hour, count: totals.hourHistogram[hour], maxCount: maxHour), section: section))
                    stableId += 1
                }
            }

            // Daily dynamics for the last 7 days with data.
            section += 1
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .sectionHeader(modLoc("ModChatObservatoryDynamics", languageCode)), section: section))
            stableId += 1
            let sortedDays = totals.days.sorted { $0.key < $1.key }.suffix(7)
            let maxDay = sortedDays.map { $0.value.sent + $0.value.received }.max() ?? 0
            for (day, data) in sortedDays {
                entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .dayBar(label: day, count: data.sent + data.received, maxCount: maxDay), section: section))
                stableId += 1
            }
        }

        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (list, EmptyModArguments()))
    }
    return ItemListController(context: context, state: signal)
}

/// Custom chat list background settings: pick an image, adjust row transparency.
func exteraChatListBackgroundController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)

    func setPreference<Value: Codable & Equatable & Sendable>(_ value: Value, for preference: ExteraPreference<Value>) {
        try? store.set(value, for: preference)
        reload.set(revision.modify { $0 + 1 })
    }

    struct BackgroundArguments {
        let chooseImage: () -> Void
        let removeImage: () -> Void
    }

    let arguments = BackgroundArguments(
        chooseImage: {
            ExteraModImagePicker.pickImage { image in
                if let data = ExteraModImagePicker.jpegData(from: image, maxDimension: 1280) {
                    setPreference(data.base64EncodedString(), for: ExteraSettings.customChatListBackground)
                }
            }
        },
        removeImage: {
            setPreference(nil as String?, for: ExteraSettings.customChatListBackground)
        }
    )

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, BackgroundArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModChatListBackground", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0

        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(modLoc("ModChatListBackgroundInfo", languageCode))))
        stableId += 1
        let hasImage = store.value(for: ExteraSettings.customChatListBackground) != nil
        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .disclosure(title: modLoc("ModChooseImage", languageCode), info: nil, label: nil, action: {
            arguments.chooseImage()
        })))
        stableId += 1
        if hasImage {
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .disclosure(title: modLoc("ModRemoveImage", languageCode), info: nil, label: nil, action: {
                arguments.removeImage()
            })))
            stableId += 1
            let dimming = store.value(for: ExteraSettings.chatListBackgroundDimming)
            // Transparency presented as discrete steps to keep ItemListUI-only UI.
            for value: Float in stride(from: 0.1, through: 0.9, by: 0.2) {
                let isCurrent = abs(value - dimming) < 0.11
                entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .disclosure(title: String(format: "%.0f%%", value * 100), info: modLoc("ModChatListBackgroundDimming", languageCode), label: isCurrent ? "✓" : nil, action: {
                    setPreference(value, for: ExteraSettings.chatListBackgroundDimming)
                })))
                stableId += 1
            }
        }

        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (list, arguments))
    }
    return ItemListController(context: context, state: signal)
}

/// Profile banner settings: pick or remove a banner image shown above the avatar.
func exteraProfileBannerController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)

    func setPreference<Value: Codable & Equatable & Sendable>(_ value: Value, for preference: ExteraPreference<Value>) {
        try? store.set(value, for: preference)
        reload.set(revision.modify { $0 + 1 })
    }

    struct BannerArguments {
        let chooseImage: () -> Void
        let removeImage: () -> Void
    }

    let arguments = BannerArguments(
        chooseImage: {
            ExteraModImagePicker.pickImage { image in
                if let data = ExteraModImagePicker.jpegData(from: image, maxDimension: 1600) {
                    setPreference(data.base64EncodedString(), for: ExteraSettings.profileBanner)
                }
            }
        },
        removeImage: {
            setPreference(nil as String?, for: ExteraSettings.profileBanner)
        }
    )

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, BannerArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modLoc("ModProfileBanner", languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries: [ExteraModSimpleEntry] = []
        var stableId: Int32 = 0

        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .info(modLoc("ModProfileBannerInfo", languageCode))))
        stableId += 1
        entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .disclosure(title: modLoc("ModChooseImage", languageCode), info: nil, label: nil, action: {
            arguments.chooseImage()
        })))
        stableId += 1
        if store.value(for: ExteraSettings.profileBanner) != nil {
            entries.append(ExteraModSimpleEntry(stableId: stableId, kind: .disclosure(title: modLoc("ModRemoveImage", languageCode), info: nil, label: nil, action: {
                arguments.removeImage()
            })))
            stableId += 1
        }

        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (list, arguments))
    }
    return ItemListController(context: context, state: signal)
}
