import XCTest
@testable import ExteraPreferences

final class ExteraModCoreTests: XCTestCase {
    func testGhostModeHidesEverything() {
        let state = ExteraPrivacyMode.resolve(ghost: true, afk: false)
        XCTAssertTrue(state.hideOnline)
        XCTAssertTrue(state.hideReadReceipts)
        XCTAssertTrue(state.hideTypingActivity)
    }

    func testAfkModeKeepsTyping() {
        let state = ExteraPrivacyMode.resolve(ghost: false, afk: true)
        XCTAssertTrue(state.hideOnline)
        XCTAssertTrue(state.hideReadReceipts)
        XCTAssertFalse(state.hideTypingActivity)
    }

    func testNoModeIsFullyVisible() {
        let state = ExteraPrivacyMode.resolve(ghost: false, afk: false)
        XCTAssertEqual(state, .visible)
    }

    func testGhostWinsOverAfk() {
        let state = ExteraPrivacyMode.resolve(ghost: true, afk: true)
        XCTAssertTrue(state.hideTypingActivity)
    }

    func testSmileModeEmojiOnly() {
        XCTAssertTrue(ExteraSmileMode.isEmojiOnly("🔥"))
        XCTAssertTrue(ExteraSmileMode.isEmojiOnly("🔥❤️"))
        XCTAssertTrue(ExteraSmileMode.isEmojiOnly("  👍 "))
        XCTAssertFalse(ExteraSmileMode.isEmojiOnly("hello"))
        XCTAssertFalse(ExteraSmileMode.isEmojiOnly("🔥 lol"))
        XCTAssertFalse(ExteraSmileMode.isEmojiOnly("123"))
        XCTAssertFalse(ExteraSmileMode.isEmojiOnly(""))
    }

    func testMuteDurationsParse() {
        XCTAssertEqual(ExteraMuteDuration.parse("1 min"), .oneMinute)
        XCTAssertEqual(ExteraMuteDuration.parse("5min"), .fiveMinutes)
        XCTAssertEqual(ExteraMuteDuration.parse("30 мин"), .thirtyMinutes)
        XCTAssertEqual(ExteraMuteDuration.parse("1 час"), .oneHour)
        XCTAssertNil(ExteraMuteDuration.parse("2 hours"))
        XCTAssertEqual(ExteraMuteDuration.oneHour.seconds, 3600)
    }

    func testMuteExpiryLifecycle() {
        let now = Date()
        var expiries: [Int64: Double] = [:]
        expiries = ExteraPeerMuting.mute(peerId: 42, duration: .fiveMinutes, now: now, expiries: expiries)
        XCTAssertEqual(ExteraPeerMuting.activeMutes(now: now, expiries: expiries), [42])
        let later = now.addingTimeInterval(301)
        XCTAssertEqual(ExteraPeerMuting.activeMutes(now: later, expiries: expiries), [])
        XCTAssertEqual(ExteraPeerMuting.prune(now: later, expiries: expiries), [:])
        expiries = ExteraPeerMuting.mute(peerId: 7, duration: .oneHour, now: now, expiries: expiries)
        expiries = ExteraPeerMuting.unmute(peerId: 7, expiries: expiries)
        XCTAssertFalse(ExteraPeerMuting.activeMutes(now: now, expiries: expiries).contains(7))
    }

    func testCommandParsing() {
        XCTAssertEqual(ExteraChatCommand.parse("/clean"), .clean)
        XCTAssertEqual(ExteraChatCommand.parse("/saved"), .saved)
        XCTAssertEqual(ExteraChatCommand.parse("/tagall"), .tagall)
        XCTAssertEqual(ExteraChatCommand.parse("/id"), .id)
        XCTAssertEqual(ExteraChatCommand.parse("hello"), nil)
        XCTAssertEqual(ExteraChatCommand.parse("/unknown"), nil)
        XCTAssertEqual(ExteraChatCommand.parse("/info @nick"), .info("@nick"))
        XCTAssertEqual(ExteraChatCommand.parse("/smile mode"), .smileMode)
        XCTAssertEqual(ExteraChatCommand.parse("/smile off"), nil)
        XCTAssertEqual(ExteraChatCommand.parse("/repeat"), .repeatText(nil))
        XCTAssertEqual(ExteraChatCommand.parse("/repeat hello world"), .repeatText("hello world"))
        XCTAssertEqual(ExteraChatCommand.parse("/ban @user"), .ban("@user"))
        XCTAssertEqual(ExteraChatCommand.parse("/unban @user"), .unban("@user"))
        XCTAssertEqual(ExteraChatCommand.parse("/mute @user 5 min"), .mute("@user", .fiveMinutes))
        XCTAssertEqual(ExteraChatCommand.parse("/mute 30 мин"), .mute(nil, .thirtyMinutes))
        XCTAssertEqual(ExteraChatCommand.parse("/unmute @user"), .unmute("@user"))
        XCTAssertTrue(ExteraChatCommand.parse("/clean")!.isLocalOnly)
    }

    func testCommandWhitespaceTolerance() {
        XCTAssertEqual(ExteraChatCommand.parse("  /clean  \n"), .clean)
        XCTAssertEqual(ExteraChatCommand.parse("/INFO nick"), .info("nick"))
    }
}

final class ExteraModJournalTests: XCTestCase {
    private var directory: URL!
    private var journal: ExteraModJournal!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("journal-tests-\(UUID().uuidString)")
        journal = ExteraModJournal(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        journal = nil
        directory = nil
        super.tearDown()
    }

    func testDeletedRecordRoundTrip() {
        let record = ExteraModJournal.DeletedRecord(peerId: 1, messageId: 2, namespace: 0, text: "hello", author: "User", timestamp: 100, edited: false, previousText: nil)
        journal.recordDeleted(record)
        XCTAssertEqual(journal.deletedRecords(), [record])
    }

    func testDeletedRecordDeduplication() {
        let record = ExteraModJournal.DeletedRecord(peerId: 1, messageId: 2, namespace: 0, text: "hello", author: "User", timestamp: 100, edited: false, previousText: nil)
        journal.recordDeleted(record)
        journal.recordDeleted(record)
        XCTAssertEqual(journal.deletedRecords().count, 1)
    }

    func testDeletedLogPersistsAcrossInstances() {
        let record = ExteraModJournal.DeletedRecord(peerId: 5, messageId: 6, namespace: 0, text: "persisted", author: "A", timestamp: 3, edited: true, previousText: "old")
        journal.recordDeleted(record)
        let reopened = ExteraModJournal(directory: directory)
        XCTAssertEqual(reopened.deletedRecords(), [record])
    }

    func testClearDeleted() {
        journal.recordDeleted(ExteraModJournal.DeletedRecord(peerId: 1, messageId: 2, namespace: 0, text: "x", author: "A", timestamp: 1, edited: false, previousText: nil))
        journal.clearDeleted()
        XCTAssertTrue(journal.deletedRecords().isEmpty)
    }

    func testObservatoryCounters() {
        journal.recordMessageSent(at: Date(timeIntervalSince1970: 1_700_000_000))
        journal.recordMessageReceived(at: Date(timeIntervalSince1970: 1_700_000_000))
        journal.recordForegroundSeconds(30)
        let totals = journal.observatoryTotals()
        XCTAssertEqual(totals.sent, 1)
        XCTAssertEqual(totals.received, 1)
        XCTAssertEqual(totals.hourHistogram.reduce(0, +), 2)
        XCTAssertEqual(totals.days.values.reduce(0.0) { $0 + $1.secondsInApp }, 30.0, accuracy: 0.001)
    }

    func testObservatoryReset() {
        journal.recordMessageSent()
        journal.resetObservatory()
        let totals = journal.observatoryTotals()
        XCTAssertEqual(totals.sent, 0)
        XCTAssertTrue(totals.days.isEmpty)
    }
}

final class ExteraModPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ExteraPreferences!

    override func setUpWithError() throws {
        suiteName = "ExteraModTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = ExteraPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
    }

    func testGhostModeRoundsTrip() throws {
        XCTAssertFalse(store.value(for: ExteraSettings.ghostModeEnabled))
        try store.set(true, for: ExteraSettings.ghostModeEnabled)
        XCTAssertTrue(store.value(for: ExteraSettings.ghostModeEnabled))
    }

    func testMuteExpiriesMapRoundsTrip() throws {
        let value: [Int64: Double] = [42: 123.5, 7: 99.0]
        try store.set(value, for: ExteraSettings.mutedPeerExpiries)
        XCTAssertEqual(store.value(for: ExteraSettings.mutedPeerExpiries), value)
    }

    func testProtectedPeerSetRoundsTrip() throws {
        let value: Set<Int64> = [1, 2, 3]
        try store.set(value, for: ExteraSettings.privacyLensProtectedPeerIds)
        XCTAssertEqual(store.value(for: ExteraSettings.privacyLensProtectedPeerIds), value)
    }

    func testRoundVideoSpeedRoundsTrip() throws {
        try store.set(Float(2.0), for: ExteraSettings.roundVideoSpeed)
        XCTAssertEqual(store.value(for: ExteraSettings.roundVideoSpeed), 2.0)
    }

    func testProfileBannerOptionalRoundsTrip() throws {
        XCTAssertNil(store.value(for: ExteraSettings.profileBanner))
        try store.set("base64data", for: ExteraSettings.profileBanner)
        XCTAssertEqual(store.value(for: ExteraSettings.profileBanner), "base64data")
        try store.set(nil, for: ExteraSettings.profileBanner)
        XCTAssertNil(store.value(for: ExteraSettings.profileBanner))
    }
}
