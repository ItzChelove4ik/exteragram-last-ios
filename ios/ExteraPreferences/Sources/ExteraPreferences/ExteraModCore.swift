import Foundation

/// Resolved privacy state for the current moment. Ghost Mode hides
/// presence, reads and typing; AFK Mode hides only presence and reads.
public struct ExteraPrivacyState: Equatable, Sendable {
    public let hideOnline: Bool
    public let hideReadReceipts: Bool
    public let hideTypingActivity: Bool

    public static let visible = ExteraPrivacyState(hideOnline: false, hideReadReceipts: false, hideTypingActivity: false)

    public init(hideOnline: Bool, hideReadReceipts: Bool, hideTypingActivity: Bool) {
        self.hideOnline = hideOnline
        self.hideReadReceipts = hideReadReceipts
        self.hideTypingActivity = hideTypingActivity
    }
}

/// Pure resolution of ghost/AFK preferences into a single privacy state.
/// Ghost wins when both modes are somehow enabled at once.
public enum ExteraPrivacyMode {
    public static func resolve(ghost: Bool, afk: Bool) -> ExteraPrivacyState {
        if ghost {
            return ExteraPrivacyState(hideOnline: true, hideReadReceipts: true, hideTypingActivity: true)
        }
        if afk {
            return ExteraPrivacyState(hideOnline: true, hideReadReceipts: true, hideTypingActivity: false)
        }
        return .visible
    }
}

/// Message classification for smile mode: a message survives only when
/// its visible content is emoji-only (no letters or digits).
public enum ExteraSmileMode {
    private static let scalarRanges: [(ClosedRange<UInt32>)] = [
        0x1F300...0x1FAFF,   // emoji symbols
        0x2600...0x27BF,     // misc symbols & dingbats
        0x2190...0x21FF,     // arrows
        0x2B00...0x2BFF,     // misc symbols and arrows
        0x1F000...0x1F0FF,   // mahjong / cards
        0xFE00...0xFE0F,     // variation selectors
        0x200D...0x200D,     // zero-width joiner
        0x20E3...0x20E3      // combining enclosing keycap
    ]

    public static func isEmojiOnly(_ text: String) -> Bool {
        var hasContent = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            if scalar.value == 0x200D || scalar.value == 0xFE0F { continue }
            let value = scalar.value
            if scalarRanges.contains(where: { $0.contains(value) }) {
                hasContent = true
                continue
            }
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                return false
            }
            hasContent = true
        }
        return hasContent
    }
}

/// Mute windows accepted by the /mute command.
public enum ExteraMuteDuration: CaseIterable, Sendable {
    case oneMinute
    case fiveMinutes
    case thirtyMinutes
    case oneHour

    public var seconds: Double {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        }
    }

    public var label: String {
        switch self {
        case .oneMinute: return "1 min"
        case .fiveMinutes: return "5 min"
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 hour"
        }
    }

    public static func parse(_ text: String) -> ExteraMuteDuration? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "1", "1m", "1min", "1 min", "1мин", "мин", "1 минута", "минута": return .oneMinute
        case "5", "5m", "5min", "5 min", "5мин", "5 минут", "минуты", "5 мин", "5 мин.": return .fiveMinutes
        case "30", "30m", "30min", "30 min", "30мин", "30 минут", "30 мин", "30 мин.": return .thirtyMinutes
        case "60", "1h", "1 hour", "1ч", "1 час", "час", "60 мин", "60мин": return .oneHour
        default: return nil
        }
    }
}

/// Local bookkeeping for muted and locally banned peers, persisted through
/// ExteraPreferences. All operations are lock-free value transforms that
/// the caller applies through the preferences store.
public enum ExteraPeerMuting {
    public static func activeMutes(now: Date = Date(), expiries: [Int64: Double]) -> Set<Int64> {
        var active: Set<Int64> = []
        for (peerId, expiry) in expiries where expiry > now.timeIntervalSince1970 {
            active.insert(peerId)
        }
        return active
    }

    public static func prune(now: Date = Date(), expiries: [Int64: Double]) -> [Int64: Double] {
        var result: [Int64: Double] = [:]
        let timestamp = now.timeIntervalSince1970
        for (peerId, expiry) in expiries where expiry > timestamp {
            result[peerId] = expiry
        }
        return result
    }

    public static func mute(peerId: Int64, duration: ExteraMuteDuration, now: Date = Date(), expiries: [Int64: Double]) -> [Int64: Double] {
        var result = prune(now: now, expiries: expiries)
        result[peerId] = now.timeIntervalSince1970 + duration.seconds
        return result
    }

    public static func unmute(peerId: Int64, expiries: [Int64: Double]) -> [Int64: Double] {
        var result = expiries
        result.removeValue(forKey: peerId)
        return result
    }
}

/// Chat command parser: recognizes the mod's slash commands typed in the
/// message input field. Returns nil for ordinary messages.
public enum ExteraChatCommand: Equatable, Sendable {
    case clean
    case saved
    case tagall
    case id
    case info(String?)
    case smileMode
    case repeatText(String?)
    case ban(String?)
    case unban(String?)
    case mute(String?, ExteraMuteDuration?)
    case unmute(String?)

    public static func parse(_ raw: String) -> ExteraChatCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first?.lowercased(), !head.isEmpty else { return nil }
        let firstArg = parts.count > 1 ? parts[1] : nil
        let rest = parts.count > 2 ? parts[2] : nil
        switch head {
        case "clean": return parts.count == 1 ? .clean : nil
        case "saved": return parts.count == 1 ? .saved : nil
        case "tagall": return parts.count == 1 ? .tagall : nil
        case "id": return parts.count == 1 ? .id : nil
        case "info": return .info(firstArg)
        case "smile":
            if parts.count == 2, parts[1].lowercased() == "mode" { return .smileMode }
            return nil
        case "repeat": return .repeatText(parts.count > 1 ? parts[1...].joined(separator: " ") : nil)
        case "ban": return .ban(firstArg)
        case "unban": return .unban(firstArg)
        case "mute":
            guard let arg = firstArg, !arg.isEmpty else { return .mute(nil, nil) }
            // Either "/mute @user 5 min" or "/mute 5 min" (peer = current chat).
            if let duration = ExteraMuteDuration.parse(arg) {
                return .mute(nil, duration)
            }
            let duration = parts.count > 2 ? ExteraMuteDuration.parse(parts[2...].joined(separator: " ")) : nil
            return .mute(arg, duration)
        case "unmute": return .unmute(firstArg)
        default: return nil
        }
    }

    /// True when the command should never be transmitted to the server.
    public var isLocalOnly: Bool {
        switch self {
        case .clean, .saved, .tagall, .id, .info, .smileMode, .repeatText, .ban, .unban, .mute, .unmute:
            return true
        }
    }
}
