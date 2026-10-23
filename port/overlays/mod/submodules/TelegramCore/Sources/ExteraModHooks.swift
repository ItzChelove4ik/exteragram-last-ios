import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit
import MtProtoKit
import ExteraPreferences

/// Core-side hooks for GlowGram mod behavior. Each function is called from
/// patched call sites in TelegramCore and decides whether an outgoing
/// privacy-bearing request should proceed.

enum ExteraModCoreHooks {
    /// Blocks messages.readHistory / readMessageContents push requests while
    /// Ghost or AFK mode hides read receipts.
    static func shouldSuppressReadReports() -> Bool {
        return ExteraPrivacyCore.hideReadReceipts
    }

    /// Blocks messages.setTyping while Ghost mode hides the typing indicator.
    static func shouldSuppressTyping() -> Bool {
        return ExteraPrivacyCore.hideTypingActivity
    }
}

enum ExteraPrivacyCore {
    static var hideOnline: Bool {
        let store = ExteraPreferences.standard
        return store.value(for: ExteraSettings.ghostModeEnabled) || store.value(for: ExteraSettings.afkModeEnabled)
    }

    static var hideReadReceipts: Bool {
        let store = ExteraPreferences.standard
        return store.value(for: ExteraSettings.ghostModeEnabled) || store.value(for: ExteraSettings.afkModeEnabled)
    }

    static var hideTypingActivity: Bool {
        return ExteraPreferences.standard.value(for: ExteraSettings.ghostModeEnabled)
    }
}

/// Deletes locally muted or banned peer messages and journals deleted/edited
/// message history for the mod's local log.
enum ExteraModMessageFilter {
    /// True when the message should be hidden from the local view entirely.
    static func isHidden(peerId: PeerId) -> Bool {
        let store = ExteraPreferences.standard
        let now = Date().timeIntervalSince1970
        let muted = store.value(for: ExteraSettings.mutedPeerExpiries)[peerId.toInt64()] ?? 0 > now
        let banned = store.value(for: ExteraSettings.locallyBannedPeerIds).contains(peerId.toInt64())
        return muted || banned
    }
}
