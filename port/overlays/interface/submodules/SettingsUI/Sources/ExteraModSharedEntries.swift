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
import ExteraProxySearch

func modLoc(_ key: String, _ languageCode: String) -> String {
    ExteraLocalization.text(key, languageCode: languageCode, table: "ExteraPort")
}

/// Shared simple entry kind used by the mod's sub-screens.
enum ExteraModSimpleEntryKind {
    case info(String)
    case sectionHeader(String)
    case toggle(title: String, info: String?, value: Bool, action: (Bool) -> Void)
    case disclosure(title: String, info: String?, label: String?, action: () -> Void)
    case slider(title: String, value: Float, minimumValue: Float, maximumValue: Float, action: (Float) -> Void)
    case proxy(candidate: ExteraProxyCandidate, validation: ExteraProxyValidation)
    case deletedRecord(ExteraModJournal.DeletedRecord)
    case observatoryHeader(String)
    case counter(title: String, value: String)
    case hourBar(hour: Int, count: Int, maxCount: Int)
    case dayBar(label: String, count: Int, maxCount: Int)
}

final class ExteraModSimpleEntry: ItemListNodeEntry {
    let stableId: Int32
    let kind: ExteraModSimpleEntryKind
    let section: ItemListSectionId

    init(stableId: Int32, kind: ExteraModSimpleEntryKind, section: ItemListSectionId = 0) {
        self.stableId = stableId
        self.kind = kind
        self.section = section
    }

    var index: Int32 { return self.stableId }

    static func == (lhs: ExteraModSimpleEntry, rhs: ExteraModSimpleEntry) -> Bool {
        // Each refresh creates new entries, including fresh action closures.
        return lhs === rhs
    }

    static func < (lhs: ExteraModSimpleEntry, rhs: ExteraModSimpleEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self.kind {
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .sectionHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .toggle(title, info, value, action):
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
                }
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
        case let .slider(title, value, _, _, _):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                value: value > 0,
                sectionId: self.section,
                style: .blocks,
                updated: { _ in }
            )
        case let .proxy(candidate, validation):
            let languageCode = presentationData.strings.primaryComponent.languageCode
            let status: String
            switch validation.state {
            case .pending:
                status = modLoc("ModProxySearchChecking", languageCode)
            case .reachable:
                if let ping = validation.pingMilliseconds {
                    status = String(format: modLoc("ModProxyPing", languageCode), Int(ping))
                } else {
                    status = modLoc("ModProxyConnected", languageCode)
                }
            case .dead:
                status = modLoc("ModProxyDead", languageCode)
            case .invalidSecret:
                status = modLoc("ModProxyInvalidSecret", languageCode)
            }
            let arguments = arguments as? ExteraProxyArguments
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: nil,
                title: "\(candidate.host):\(candidate.port)",
                label: status,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments?.connect(candidate)
                }
            )
        case let .deletedRecord(record):
            let languageCode = presentationData.strings.primaryComponent.languageCode
            let deletedWord = modLoc("ModDeletedLogTab", languageCode)
            let title = record.edited ? "✎ \(record.author)" : "\(deletedWord): \(record.author)"
            let date = DateFormatter()
            date.dateFormat = "dd.MM HH:mm"
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: nil,
                title: title,
                label: date.string(from: Date(timeIntervalSince1970: TimeInterval(record.timestamp))),
                additionalDetailLabel: record.text,
                additionalDetailLabelColor: .generic,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {}
            )
        case let .observatoryHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .counter(title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: nil,
                title: title,
                label: value,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {}
            )
        case let .hourBar(hour, count, _):
            let label = String(format: "%02d:00 — %d", hour, count)
            return ItemListTextItem(presentationData: presentationData, text: .plain(label), sectionId: self.section)
        case let .dayBar(label, count, maxCount):
            let bar = String(repeating: "█", count: max(1, Int(Double(count) / Double(max(maxCount, 1)) * 20)))
            return ItemListTextItem(presentationData: presentationData, text: .plain("\(label) \(bar) \(count)"), sectionId: self.section)
        }
    }
}
