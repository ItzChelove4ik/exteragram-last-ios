import Foundation
import UIKit
import ExteraPreferences
import LocalAuthentication

/// Privacy Lens runtime: screen-capture blur, background blur, Face ID gate
/// for protected chats, and push preview hiding.
enum ExteraPrivacyLensControllerHooks {
    private static var blurView: UIVisualEffectView?

    /// Blurs the entire window while the screen is being captured/recorded.
    /// Enabled through the ModPrivacyLensBlurMessages setting.
    static func applyCaptureBlur() {
        guard ExteraPreferences.standard.value(for: ExteraSettings.privacyLensBlurMessages) else { return }
        installBlur()
    }

    static func removeCaptureBlur() {
        removeBlur()
    }

    /// Blurs the window when the app enters the background.
    static func applyBackgroundBlur() {
        guard ExteraPreferences.standard.value(for: ExteraSettings.privacyLensBlurOnBackground) else { return }
        installBlur()
    }

    static func removeBackgroundBlur() {
        removeBlur()
    }

    private static func installBlur() {
        guard blurView == nil, let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
        let effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        let view = UIVisualEffectView(effect: effect)
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.tag = 998877
        window.addSubview(view)
        blurView = view
    }

    private static func removeBlur() {
        blurView?.removeFromSuperview()
        blurView = nil
    }

    /// True when the chat with peerId requires Face ID / device passcode
    /// before it can be opened.
    static func isChatProtected(peerId: Int64) -> Bool {
        return ExteraPreferences.standard.value(for: ExteraSettings.privacyLensProtectChats)
            && ExteraPreferences.standard.value(for: ExteraSettings.privacyLensProtectedPeerIds).contains(peerId)
    }

    /// Runs the biometric gate. Calls completion(true) when access is granted
    /// (or biometrics are unavailable, so the feature never locks the user out).
    static func authorizeProtectedChat(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: ExteraPrivacyLensText.authorizationReason) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
}

private enum ExteraPrivacyLensText {
    static var authorizationReason: String {
        let languageCode = Locale.preferredLanguages.first ?? "en"
        if languageCode.hasPrefix("ru") {
            return "Разблокировать чат"
        }
        return "Unlock this chat"
    }
}
