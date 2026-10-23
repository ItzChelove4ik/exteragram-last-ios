import Foundation
import ExteraPreferences

/// Local storage for the mod's deleted/edited message log and the
/// Chat Observatory usage counters. Everything stays on-device in the
/// host app's Application Support directory.
public final class ExteraModJournal: @unchecked Sendable {
    public struct DeletedRecord: Codable, Equatable, Sendable {
        public let peerId: Int64
        public let messageId: Int64
        public let namespace: Int32
        public let text: String
        public let author: String
        public let timestamp: Int32
        public let edited: Bool
        public let previousText: String?
    }

    public struct ObservatoryDay: Codable, Equatable, Sendable {
        public var sent: Int
        public var received: Int
        public var secondsInApp: Double
    }

    public struct ObservatoryTotals: Codable, Equatable, Sendable {
        public var sent: Int
        public var received: Int
        public var hourHistogram: [Int]
        public var days: [String: ObservatoryDay]
    }

    public static let shared = ExteraModJournal()

    private let lock = NSLock()
    private let fileURL: URL
    private let maxRecords = 5000

    private struct Store: Codable {
        var deleted: [DeletedRecord] = []
        var totals: ObservatoryTotals = ObservatoryTotals(sent: 0, received: 0, hourHistogram: Array(repeating: 0, count: 24), days: [:])
        var foregroundSecondsToday: Double = 0.0
        var foregroundDayKey: String = Self.dayKey(Date())
    }

    private var store: Store
    private var saveCounter = 0
    private let saveInterval = 5
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Test hook: build a journal bound to a specific directory.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let folder = (base ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("GlowGram", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent("mod-journal.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? self.decoder.decode(Store.self, from: data) {
            self.store = decoded
        } else {
            self.store = Store()
        }
        // A persisted journal never crosses an account reset silently:
        // validate the histogram length so older files cannot crash later reads.
        if self.store.totals.hourHistogram.count != 24 {
            self.store.totals.hourHistogram = Array(repeating: 0, count: 24)
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func mutate(_ f: (inout Store) -> Void, immediate: Bool = false) {
        lock.lock()
        f(&store)
        let shouldSave = immediate || (saveCounter % saveInterval == 0)
        saveCounter += 1
        let snapshot = shouldSave ? store : nil
        lock.unlock()
        if let snapshot, let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Deleted messages log

    public func recordDeleted(_ record: DeletedRecord) {
        mutate { store in
            if store.deleted.contains(where: { $0.peerId == record.peerId && $0.messageId == record.messageId }) { return }
            store.deleted.insert(record, at: 0)
            if store.deleted.count > maxRecords {
                store.deleted.removeLast(store.deleted.count - maxRecords)
            }
        }
    }

    public func deletedRecords(limit: Int = 500) -> [DeletedRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(store.deleted.prefix(limit))
    }

    public func deletedRecords(peerId: Int64, limit: Int = 500) -> [DeletedRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(store.deleted.filter { $0.peerId == peerId }.prefix(limit))
    }

    public func clearDeleted() {
        mutate({ $0.deleted.removeAll() }, immediate: true)
    }

    // MARK: Observatory

    public func recordMessageSent(at date: Date = Date()) {
        mutate { store in
            store.totals.sent += 1
            store.totals.hourHistogram[max(0, min(23, Calendar.current.component(.hour, from: date)))] += 1
            Self.rollDayIfNeeded(&store, date: date).sent += 1
        }
    }

    public func recordMessageSent(count: Int, at date: Date = Date()) {
        guard count > 0 else { return }
        mutate { store in
            store.totals.sent += count
            store.totals.hourHistogram[max(0, min(23, Calendar.current.component(.hour, from: date)))] += count
            Self.rollDayIfNeeded(&store, date: date).sent += count
        }
    }

    public func recordMessageReceived(at date: Date = Date()) {
        mutate { store in
            store.totals.received += 1
            store.totals.hourHistogram[max(0, min(23, Calendar.current.component(.hour, from: date)))] += 1
            Self.rollDayIfNeeded(&store, date: date).received += 1
        }
    }

    public func recordForegroundSeconds(_ seconds: Double, at date: Date = Date()) {
        mutate { store in
            Self.rollDayIfNeeded(&store, date: date).secondsInApp += max(0, seconds)
        }
    }

    public func observatoryTotals() -> ObservatoryTotals {
        lock.lock()
        defer { lock.unlock() }
        return store.totals
    }

    public func resetObservatory() {
        mutate({ store in
            store.totals = ObservatoryTotals(sent: 0, received: 0, hourHistogram: Array(repeating: 0, count: 24), days: [:])
            store.foregroundSecondsToday = 0.0
        }, immediate: true)
    }

    @discardableResult
    private static func rollDayIfNeeded(_ store: inout Store, date: Date) -> ObservatoryDay {
        let key = dayKey(date)
        if store.foregroundDayKey != key {
            store.foregroundDayKey = key
            store.foregroundSecondsToday = 0.0
            if store.totals.days[key] == nil {
                store.totals.days[key] = ObservatoryDay(sent: 0, received: 0, secondsInApp: 0)
            }
        }
        if store.totals.days[key] == nil {
            store.totals.days[key] = ObservatoryDay(sent: 0, received: 0, secondsInApp: 0)
        }
        return store.totals.days[key]!
    }

    /// Total bytes used by the journal file, used by the /clean command report.
    public func storageBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    public func clearAll() {
        mutate({ store in
            store = Store()
        }, immediate: true)
    }
}
