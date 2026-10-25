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

private enum ModSection: Int32, CaseIterable {
    case privacy
    case appearance
    case media
    case data
    case commands
}

private struct ModFeature {
    enum Kind {
        case toggle(ExteraPreference<Bool>)
        case disclosure(() -> Void)
        case infoText
    }

    let titleKey: String
    let infoKey: String?
    let kind: Kind
    let section: ModSection
    let searchableTerms: [String]
}

// MARK: - Localization helper

private func modText(_ key: String, languageCode: String) -> String {
    return ExteraLocalization.text(key, languageCode: languageCode, table: "ExteraPort")
}// MARK: - Main mod settings controller

public func exteraGramPreferencesController(context: AccountContext) -> ViewController {
    let store = ExteraPreferences.standard
    let revision = Atomic<Int>(value: 0)
    let reload = ValuePromise<Int>(0, ignoreRepeated: false)
    var presentController: ((ViewController) -> Void)?
    var pushController: ((ViewController) -> Void)?

    func setPreference<Value: Codable & Equatable & Sendable>(_ value: Value, for preference: ExteraPreference<Value>) {
        try? store.set(value, for: preference)
        reload.set(revision.modify { $0 + 1 })
    }

    // MARK: Argument actions for every feature

    func openProxySearch() {
        pushController?(exteraProxySearchController(context: context))
    }

    func openDeletedLog() {
        pushController?(exteraDeletedLogController(context: context))
    }

    func openPrivacyLens() {
        pushController?(exteraPrivacyLensController(context: context))
    }

    func openObservatory() {
        pushController?(exteraObservatoryController(context: context))
    }

    func openRoundVideoSettings() {
        pushController?(exteraRoundVideoController(context: context))
    }

    func openBackgroundSettings() {
        pushController?(exteraChatListBackgroundController(context: context))
    }

    func openProfileBannerSettings() {
        pushController?(exteraProfileBannerController(context: context))
    }

    func openTranslationLanguagePicker() {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let russian = languageCode.lowercased().hasPrefix("ru")
        let sheet = ActionSheetController(presentationData: presentationData)
        let languages: [(String, String)] = [
            ("en", russian ? "Английский" : "English"),
            ("ru", russian ? "Русский" : "Russian"),
            ("de", "Deutsch"),
            ("es", "Español"),
            ("fr", "Français"),
            ("it", "Italiano"),
            ("pt", "Português"),
            ("uk", russian ? "Украинский" : "Ukrainian"),
            ("kk", russian ? "Казахский" : "Kazakh"),
            ("tr", "Türkçe"),
            ("zh", russian ? "Китайский" : "Chinese")
        ]
        let current = store.value(for: ExteraSettings.modTranslationTarget)
        let items: [ActionSheetItem] = languages.map { code, name in
            ActionSheetButtonItem(title: code == current ? name + " ✓" : name, action: { [weak sheet] in
                sheet?.dismissAnimated()
                setPreference(code, for: ExteraSettings.modTranslationTarget)
            })
        }
        sheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { [weak sheet] in
                sheet?.dismissAnimated()
            })])
        ])
        presentController?(sheet)
    }

    let arguments = ExteraModPreferencesArguments(
        update: { id, value in
            _ = id
            _ = value
        },
        toggle: { preference in
            let current = store.value(for: preference)
            setPreference(!current, for: preference)
        },
        openProxySearch: openProxySearch,
        openDeletedLog: openDeletedLog,
        openPrivacyLens: openPrivacyLens,
        openObservatory: openObservatory,
        openRoundVideoSettings: openRoundVideoSettings,
        openBackgroundSettings: openBackgroundSettings,
        openProfileBannerSettings: openProfileBannerSettings,
        openTranslationLanguagePicker: openTranslationLanguagePicker,
        openCommandsHelp: {
            pushController?(exteraCommandsHelpController(context: context))
        }
    )

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, reload.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, ExteraModPreferencesArguments)) in
        let languageCode = presentationData.strings.primaryComponent.languageCode
        let state = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(modText("ModSettingsTitle", languageCode: languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let entries = ExteraModMenuBuilder.entries(store: store, languageCode: languageCode, arguments: arguments)
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
    pushController = { [weak controller] child in
        (controller?.navigationController as? NavigationController)?.pushViewController(child)
    }
    return controller
}

// MARK: - Arguments

private final class ExteraModPreferencesArguments {
    let update: (Int32, Bool) -> Void
    let toggle: (ExteraPreference<Bool>) -> Void
    let openProxySearch: () -> Void
    let openDeletedLog: () -> Void
    let openPrivacyLens: () -> Void
    let openObservatory: () -> Void
    let openRoundVideoSettings: () -> Void
    let openBackgroundSettings: () -> Void
    let openProfileBannerSettings: () -> Void
    let openTranslationLanguagePicker: () -> Void
    let openCommandsHelp: () -> Void

    init(update: @escaping (Int32, Bool) -> Void,
         toggle: @escaping (ExteraPreference<Bool>) -> Void,
         openProxySearch: @escaping () -> Void,
         openDeletedLog: @escaping () -> Void,
         openPrivacyLens: @escaping () -> Void,
         openObservatory: @escaping () -> Void,
         openRoundVideoSettings: @escaping () -> Void,
         openBackgroundSettings: @escaping () -> Void,
         openProfileBannerSettings: @escaping () -> Void,
         openTranslationLanguagePicker: @escaping () -> Void,
         openCommandsHelp: @escaping () -> Void) {
        self.update = update
        self.toggle = toggle
        self.openProxySearch = openProxySearch
        self.openDeletedLog = openDeletedLog
        self.openPrivacyLens = openPrivacyLens
        self.openObservatory = openObservatory
        self.openRoundVideoSettings = openRoundVideoSettings
        self.openBackgroundSettings = openBackgroundSettings
        self.openProfileBannerSettings = openProfileBannerSettings
        self.openTranslationLanguagePicker = openTranslationLanguagePicker
        self.openCommandsHelp = openCommandsHelp
    }
}

// MARK: - Menu entry building

private enum ExteraModMenuEntryTag: ItemListItemTag {
    case ghostMode
    case afkMode
    case autoTranslate
    case proxySearch

    func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? ExteraModMenuEntryTag {
            return self == other
        }
        return false
    }
}

private final class ExteraModMenuEntry: ItemListNodeEntry {
    enum Content {
        case sectionHeader(String)
        case toggle(title: String, info: String?, value: Bool, action: (Bool) -> Void, tag: ExteraModMenuEntryTag?)
        case disclosure(title: String, info: String?, label: String?, action: () -> Void)
    }

    let stableId: Int32
    let content: Content
    let section: ItemListSectionId

    init(stableId: Int32, content: Content, section: ItemListSectionId) {
        self.stableId = stableId
        self.content = content
        self.section = section
    }

    var index: Int32 { return self.stableId }

    static func == (lhs: ExteraModMenuEntry, rhs: ExteraModMenuEntry) -> Bool {
        return lhs === rhs
    }

    static func < (lhs: ExteraModMenuEntry, rhs: ExteraModMenuEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self.content {
        case let .sectionHeader(title):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: title, sectionId: self.section)
        case let .toggle(title, info, value, action, tag):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                text: info,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { newValue in
                    action(newValue)
                },
                tag: tag
            )
        case let .disclosure(title, info, label, action):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: nil,
                title: title,
                label: label ?? "",
                additionalDetailLabel: info,
                additionalDetailLabelColor: .generic,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    action()
                }
            )
        }
    }
}

private enum ExteraModMenuBuilder {
    static func entries(store: ExteraPreferences, languageCode: String, arguments: ExteraModPreferencesArguments) -> [ExteraModMenuEntry] {
        var entries: [ExteraModMenuEntry] = []
        var stableId: Int32 = 0
        var sectionId: ItemListSectionId = 0

        func addSectionHeader(_ key: String) {
            entries.append(ExteraModMenuEntry(stableId: stableId, content: .sectionHeader(modText(key, languageCode: languageCode)), section: sectionId))
            stableId += 1
            sectionId += 1
        }

        func addToggle(titleKey: String, infoKey: String?, preference: ExteraPreference<Bool>, action: @escaping (Bool) -> Void = { _ in }, tag: ExteraModMenuEntryTag? = nil) {
            let title = modText(titleKey, languageCode: languageCode)
            let info = infoKey.flatMap { modText($0, languageCode: languageCode) }
            let value = store.value(for: preference)
            entries.append(ExteraModMenuEntry(stableId: stableId, content: .toggle(title: title, info: info, value: value, action: { newValue in
                try? store.set(newValue, for: preference)
                action(newValue)
                NotificationCenter.default.post(name: .exteraPreferencesDidChange, object: nil)
            }, tag: tag), section: sectionId))
            stableId += 1
        }

        func addDisclosure(titleKey: String, infoKey: String?, label: String? = nil, action: @escaping () -> Void) {
            let title = modText(titleKey, languageCode: languageCode)
            let info = infoKey.flatMap { modText($0, languageCode: languageCode) }
            entries.append(ExteraModMenuEntry(stableId: stableId, content: .disclosure(title: title, info: info, label: label, action: action), section: sectionId))
            stableId += 1
        }

        // Privacy
        addSectionHeader("ModSectionPrivacy")
        addToggle(titleKey: "ModGhostMode", infoKey: "ModGhostModeInfo", preference: ExteraSettings.ghostModeEnabled, tag: .ghostMode)
        addToggle(titleKey: "ModAfkMode", infoKey: "ModAfkModeInfo", preference: ExteraSettings.afkModeEnabled, tag: .afkMode)
        addToggle(titleKey: "ModAutoTranslate", infoKey: "ModAutoTranslateInfo", preference: ExteraSettings.autoTranslateIncoming, tag: .autoTranslate)
        let targetName = ExteraTranslationLanguageName.name(store.value(for: ExteraSettings.modTranslationTarget), languageCode: languageCode)
        addDisclosure(titleKey: "ModTranslationTarget", infoKey: "ModTranslationTargetInfo", label: targetName, action: arguments.openTranslationLanguagePicker)

        // Appearance
        addSectionHeader("ModSectionAppearance")
        addDisclosure(titleKey: "ModProfileBanner", infoKey: "ModProfileBannerInfo", label: store.value(for: ExteraSettings.profileBanner) == nil ? nil : "✓", action: arguments.openProfileBannerSettings)
        addDisclosure(titleKey: "ModChatListBackground", infoKey: "ModChatListBackgroundInfo", label: store.value(for: ExteraSettings.customChatListBackground) == nil ? nil : "✓", action: arguments.openBackgroundSettings)

        // Media
        addSectionHeader("ModSectionMedia")
        addDisclosure(titleKey: "ModRoundVideo", infoKey: "ModRoundVideoInfo", action: arguments.openRoundVideoSettings)

        // Data
        addSectionHeader("ModSectionData")
        addToggle(titleKey: "ModDeletedLog", infoKey: nil, preference: ExteraSettings.keepDeletedLog)
        addDisclosure(titleKey: "ModDeletedLogInfo", infoKey: nil, label: nil, action: arguments.openDeletedLog)
        addDisclosure(titleKey: "ModChatObservatory", infoKey: "ModChatObservatoryInfo", action: arguments.openObservatory)
        addDisclosure(titleKey: "ModProxySearch", infoKey: "ModProxySearchInfo", action: arguments.openProxySearch)

        // Privacy Lens
        addSectionHeader("ModPrivacyLens")
        addDisclosure(titleKey: "ModPrivacyLensInfo", infoKey: nil, action: arguments.openPrivacyLens)

        // Commands
        addSectionHeader("ModSectionCommands")
        addDisclosure(titleKey: "ModCommandsTitle", infoKey: nil, action: arguments.openCommandsHelp)

        return entries
    }
}

private enum ExteraTranslationLanguageName {
    static func name(_ code: String, languageCode: String) -> String {
        let russian = languageCode.lowercased().hasPrefix("ru")
        let names: [String: String] = [
            "en": russian ? "Английский" : "English",
            "ru": russian ? "Русский" : "Russian",
            "de": "Deutsch",
            "es": "Español",
            "fr": "Français",
            "it": "Italiano",
            "pt": "Português",
            "uk": russian ? "Українська" : "Ukrainian",
            "kk": russian ? "Қазақша" : "Kazakh",
            "tr": "Türkçe",
            "zh": russian ? "Китайский" : "Chinese"
        ]
        return names[code] ?? code.uppercased()
    }
}
