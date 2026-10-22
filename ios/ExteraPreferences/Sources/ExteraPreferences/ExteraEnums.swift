import Foundation

// Raw values preserve the supplied APK's enum ordinals. These are configuration
// identities, not a claim that Android camera/rendering backends exist on iOS.
public enum ExteraIconPackType: Int32, Codable, CaseIterable, Sendable {
    case `default` = 0
    case solar = 1
    case remix = 2
}

public enum ExteraDividerStyle: Int32, Codable, CaseIterable, Sendable {
    case hidden = 0
    case line = 1
    case segments = 2
}

public enum ExteraTabIconsMode: Int32, Codable, CaseIterable, Sendable {
    case iconsAndTitles = 0
    case titlesOnly = 1
    case iconsOnly = 2
}

public enum ExteraTabCounterMode: Int32, Codable, CaseIterable, Sendable {
    case all = 0
    case unmuted = 1
    case hidden = 2
}

public enum ExteraTransitionAnimation: Int32, Codable, CaseIterable, Sendable {
    case `default` = 0
    case aosp = 1
    case spring = 2
}

public enum ExteraGlassOutlineStyle: Int32, Codable, CaseIterable, Sendable {
    case glare = 0
    case solid = 1
    case hidden = 2
}

public enum ExteraStickerTimeMode: Int32, Codable, CaseIterable, Sendable {
    case `default` = 0
    case side = 1
    case hidden = 2
}

public enum ExteraCameraType: Int32, Codable, CaseIterable, Sendable {
    case camera1 = 0
    case camera2 = 1
    case cameraX = 2
}

public enum ExteraVideoMessagesCamera: Int32, Codable, CaseIterable, Sendable {
    case front = 0
    case rear = 1
    case ask = 2
}

public extension ExteraSettings {
    static let iconPack = ExteraPreference<ExteraIconPackType>(key: "iconPack", defaultValue: .default)
    static let dividerStyle = ExteraPreference<ExteraDividerStyle>(key: "dividerStyle", defaultValue: .line)
    static let tabIcons = ExteraPreference<ExteraTabIconsMode>(key: "tabIcons", defaultValue: .titlesOnly)
    static let tabCounterMode = ExteraPreference<ExteraTabCounterMode>(key: "tabCounterMode", defaultValue: .all)
    static let transitionAnimation = ExteraPreference<ExteraTransitionAnimation>(key: "transitionAnimation", defaultValue: .spring)
    static let glassOutlineStyle = ExteraPreference<ExteraGlassOutlineStyle>(key: "glassOutlineStyle", defaultValue: .glare)
    static let stickerTimeMode = ExteraPreference<ExteraStickerTimeMode>(key: "stickerTimeMode", defaultValue: .default)
    static let videoMessagesCamera = ExteraPreference<ExteraVideoMessagesCamera>(key: "videoMessagesCamera", defaultValue: .front)

    /// Exact Android default rule, exposed explicitly so iOS integration must
    /// select its own backend policy instead of pretending that CameraX exists.
    static func cameraType(androidDevicePerformanceClass: Int32) -> ExteraPreference<ExteraCameraType> {
        ExteraPreference(key: "cameraType", defaultValue: androidDevicePerformanceClass == 2 ? .cameraX : .camera1)
    }

    /// DEBUG_VERSION in the selected Lite APK is false. This only preserves the
    /// original preference default; no Google Crashlytics SDK is linked here.
    static let useGoogleCrashlytics = ExteraPreference<Bool>(key: "useGoogleCrashlytics", defaultValue: false)
    static let doubleTapAction = ExteraPreference<Int32>(key: "doubleTapAction", defaultValue: 1, normalize: { ExteraDoubleTap.sanitizeSetting($0) })
    static let doubleTapActionOutOwner = ExteraPreference<Int32>(key: "doubleTapActionOutOwner", defaultValue: 1, normalize: { ExteraDoubleTap.sanitizeSetting($0) })
}
