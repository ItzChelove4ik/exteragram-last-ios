import Foundation

/// Localization resources recovered from the selected exteraGram Lite APK.
/// These resources do not implement or enable the features named in their text.
public enum ExteraLocalization {
    private static let englishBundle: Bundle? = {
        guard let path = Bundle.module.path(forResource: "en", ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }()

    /// Returns localized text with English fallback, then the resource key.
    /// Android %s placeholders are converted to Foundation %@ placeholders.
    /// Markup in the original strings is retained for the caller to render.
    public static func text(_ key: String, languageCode: String? = nil, table: String = "Extera") -> String {
        let english = englishBundle?.localizedString(forKey: key, value: key, table: table) ?? key
        if let languageCode {
            guard let path = Bundle.module.path(forResource: languageCode, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return english
            }
            return bundle.localizedString(forKey: key, value: english, table: table)
        }
        return Bundle.module.localizedString(forKey: key, value: english, table: table)
    }
}
