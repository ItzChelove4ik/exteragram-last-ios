import Foundation

public enum ExteraMessageAction: Int32, Codable, CaseIterable, Sendable {
    case disabled = 0
    case reaction = 1
    case reply = 2
    case copy = 3
    case forward = 4
    case edit = 5
    case save = 6
    case repeatMessage = 7
    case delete = 8
    case translate = 9
}

/// Platform-neutral semantics recovered from DoubleTapUtils in classes4.dex.
public enum ExteraDoubleTap {
    public static func sanitizeSetting(_ value: Int32) -> Int32 {
        min(max(value, 0), 9)
    }

    public static func action(setting: Int32, outgoingOwner: Bool) -> ExteraMessageAction {
        let value = sanitizeSetting(setting)
        if outgoingOwner {
            return ExteraMessageAction(rawValue: value) ?? .disabled
        }
        switch value {
        case 0...4:
            return ExteraMessageAction(rawValue: value) ?? .disabled
        case 5...8:
            return ExteraMessageAction(rawValue: value + 1) ?? .disabled
        default:
            return .disabled
        }
    }

    public static func availableActions(outgoingOwner: Bool) -> [ExteraMessageAction] {
        outgoingOwner ? ExteraMessageAction.allCases : ExteraMessageAction.allCases.filter { $0 != .edit }
    }
}
