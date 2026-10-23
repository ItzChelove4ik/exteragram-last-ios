import Foundation
import ExteraPreferences

/// Main-thread-friendly accessor for the resolved ghost/AFK privacy state.
/// Reading UserDefaults directly on each call is cheap (values are cached
/// by ExteraPreferences) and avoids threading preferences state through
/// every call site the patch touches.
public enum ExteraPrivacyLocal {
    public static var hideOnline: Bool {
        let store = ExteraPreferences.standard
        return store.value(for: ExteraSettings.ghostModeEnabled) || store.value(for: ExteraSettings.afkModeEnabled)
    }

    public static var hideReadReceipts: Bool {
        let store = ExteraPreferences.standard
        return store.value(for: ExteraSettings.ghostModeEnabled) || store.value(for: ExteraSettings.afkModeEnabled)
    }

    public static var hideTypingActivity: Bool {
        return ExteraPreferences.standard.value(for: ExteraSettings.ghostModeEnabled)
    }

    public static var smileModeActive: Bool {
        return ExteraPreferences.standard.value(for: ExteraSettings.smileModeEnabled)
    }

    /// Peer ids muted through /mute, pruned of expired entries.
    public static var activeMutedPeerIds: Set<Int64> {
        let store = ExteraPreferences.standard
        let now = Date().timeIntervalSince1970
        return Set(store.value(for: ExteraSettings.mutedPeerExpiries).filter { $0.value > now }.keys)
    }

    /// Peer ids banned locally through /ban.
    public static var locallyBannedPeerIds: Set<Int64> {
        return ExteraPreferences.standard.value(for: ExteraSettings.locallyBannedPeerIds)
    }
}
