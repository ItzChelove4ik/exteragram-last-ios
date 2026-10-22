import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import ExteraPreferences
import ExteraResources

private struct ExteraToggle {
    let titleKey: String
    let preference: ExteraPreference<Bool>
    let table: String

    init(titleKey: String, preference: ExteraPreference<Bool>, table: String = "Extera") {
        self.titleKey = titleKey
        self.preference = preference
        self.table = table
    }
}

// Only preferences connected to real consumers are shown here.
private let exteraToggles: [ExteraToggle] = [
    ExteraToggle(titleKey: "FormatTimeWithSeconds", preference: ExteraSettings.formatTimeWithSeconds),
    ExteraToggle(titleKey: "DisableNumberRounding", preference: ExteraSettings.disableNumberRounding),
    ExteraToggle(titleKey: "ReplaceEditedWithIcon", preference: ExteraSettings.replaceEditedWithIcon),
    ExteraToggle(titleKey: "HideShareButton", preference: ExteraSettings.hideShareButton),
    ExteraToggle(titleKey: "HideStories", preference: ExteraSettings.hideStories),
    ExteraToggle(titleKey: "HidePhoneNumber", preference: ExteraSettings.hidePhoneNumber),
    ExteraToggle(titleKey: "HideKeyboardOnScroll", preference: ExteraSettings.hideKeyboardOnScroll),
    ExteraToggle(titleKey: "DisableGreetingSticker", preference: ExteraSettings.disableGreetingSticker),
    ExteraToggle(titleKey: "FilterZalgo", preference: ExteraSettings.filterZalgo),
    ExteraToggle(titleKey: "DisableMarkdown", preference: ExteraSettings.disableMarkdown),
    ExteraToggle(titleKey: "HideSendAsPeer", preference: ExteraSettings.hideSendAsPeer),
    ExteraToggle(titleKey: "InAppVibration", preference: ExteraSettings.inAppVibration),
    ExteraToggle(titleKey: "HideReactionsInChannels", preference: ExteraSettings.hideReactionsInChannels, table: "ExteraPort"),
    ExteraToggle(titleKey: "HideReactionsInGroups", preference: ExteraSettings.hideReactionsInGroups, table: "ExteraPort"),
    ExteraToggle(titleKey: "HideReactionsInPrivateChats", preference: ExteraSettings.hideReactionsInPrivateChats, table: "ExteraPort")
]

private final class ExteraPreferencesArguments {
    let update: (Int32, Bool) -> Void
    let chooseTranslator: () -> Void
    init(update: @escaping (Int32, Bool) -> Void, chooseTranslator: @escaping () -> Void) {
        self.update = update
        self.chooseTranslator = chooseTranslator
    }
}

private struct ExteraPreferencesEntry: ItemListNodeEntry {
    let stableId: Int32
    let title: String
    let value: Bool
    var label: String? = nil
    var section: ItemListSectionId { return 0 }

    static func < (lhs: ExteraPreferencesEntry, rhs: ExteraPreferencesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ExteraPreferencesArguments
        if let label = self.label {
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: self.title,
                label: label,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.chooseTranslator() }
            )
        }
        return ItemListSwitchItem(
            presentationData: presentationData,
            systemStyle: .glass,
            title: self.title,
            value: self.value,
            sectionId: self.section,
            style: .blocks,
            updated: { value in arguments.update(self.stableId, value) }
        )
    }
}

public func exteraGramPreferencesController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)
    var presentController: ((ViewController) -> Void)?
    let arguments = ExteraPreferencesArguments(update: { id, value in
        let index = Int(id)
        guard exteraToggles.indices.contains(index) else { return }
        do {
            try store.set(value, for: exteraToggles[index].preference)
        } catch {
            return
        }
        reload.set(revision.modify { $0 + 1 })
    }, chooseTranslator: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let sheet = ActionSheetController(presentationData: presentationData)
        let items: [ActionSheetItem] = [(Int32(0), "Telegram"), (Int32(1), "Google"), (Int32(2), "Yandex")].map { id, name in
            ActionSheetButtonItem(title: name, action: { [weak sheet] in
                sheet?.dismissAnimated()
                do {
                    try store.set(id, for: ExteraSettings.translationProvider)
                    reload.set(revision.modify { $0 + 1 })
                } catch {
                    return
                }
            })
        }
        sheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { [weak sheet] in
                sheet?.dismissAnimated()
            })])
        ])
        presentController?(sheet)
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, ExteraPreferencesArguments)) in
        let state = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("exteraGram Lite"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let languageCode = presentationData.strings.primaryComponent.languageCode
        var entries: [ExteraPreferencesEntry] = exteraToggles.enumerated().map { index, item in
            var title = ExteraLocalization.text(item.titleKey, languageCode: languageCode, table: item.table)
            if item.preference.key == ExteraSettings.replaceEditedWithIcon.key {
                title = String(format: title, presentationData.strings.Conversation_MessageEditedLabel as NSString)
            } else if item.preference.key == ExteraSettings.hideShareButton.key {
                title = String(format: title, presentationData.strings.Conversation_ContextMenuShare as NSString)
            }
            return ExteraPreferencesEntry(
                stableId: Int32(index),
                title: title,
                value: store.value(for: item.preference)
            )
        }
        let translatorNames: [Int32: String] = [0: "Telegram", 1: "Google", 2: "Yandex", 3: "Microsoft"]
        entries.append(ExteraPreferencesEntry(
            stableId: 1000,
            title: ExteraLocalization.text("TranslationProvider", languageCode: languageCode),
            value: false,
            label: translatorNames[store.value(for: ExteraSettings.translationProvider)] ?? "Google"
        ))
        let list = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: true
        )
        return (state, (list, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentController = { [weak controller] child in
        controller?.present(child, in: .window(.root))
    }
    return controller
}
