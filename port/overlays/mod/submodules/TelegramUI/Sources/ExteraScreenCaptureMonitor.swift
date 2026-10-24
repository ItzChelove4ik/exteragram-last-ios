import Foundation
import UIKit
import ExteraPreferences

/// Watches UIScreen.isCaptured and applies the Privacy Lens blur while
/// the screen is recorded or mirrored, independent of background events.
final class ExteraScreenCaptureMonitor {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil, #available(iOS 11.0, *) else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard #available(iOS 11.0, *) else { return }
                if UIScreen.main.isCaptured {
                    ExteraPrivacyLensControllerHooks.applyCaptureBlur()
                } else {
                    ExteraPrivacyLensControllerHooks.removeCaptureBlur()
                }
            }
        }
    }

    static func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
