import Foundation

/// Preserve the normal shared container when the signing profile grants it.
/// A re-signed main app without App Groups can still keep its own account data
/// in its sandbox. Extensions must not use this fallback: their sandboxes are
/// separate and cannot safely share this database or its encryption key.
func exteraSideloadContainerURL(appGroupIdentifier: String) -> URL? {
    let fileManager = FileManager.default
    if let shared = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
        return shared
    }

    do {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let container = support.appendingPathComponent("ExteraSideload", isDirectory: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true, attributes: nil)
        // The existing Telegram root initializer appends this directory. Ensure
        // its device-specific encryption key can be persisted on first launch.
        try fileManager.createDirectory(at: container.appendingPathComponent("telegram-data", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
        return container
    } catch {
        // Keep the existing fatal-storage error screen rather than silently
        // switching to temporary storage, losing keys, or creating a new account.
        return nil
    }
}
