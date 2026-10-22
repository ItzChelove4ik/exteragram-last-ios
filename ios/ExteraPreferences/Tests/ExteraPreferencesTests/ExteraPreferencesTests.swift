import Foundation
import XCTest
@testable import ExteraPreferences

final class ExteraPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ExteraPreferences!

    override func setUpWithError() throws {
        suiteName = "ExteraPreferencesTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = ExteraPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
    }

    func testFalseIsDistinctFromMissingTrueDefault() throws {
        XCTAssertTrue(store.value(for: ExteraSettings.inAppVibration))
        try store.set(false, for: ExteraSettings.inAppVibration)
        XCTAssertFalse(store.value(for: ExteraSettings.inAppVibration))
        let reopened = ExteraPreferences(defaults: defaults)
        XCTAssertFalse(reopened.value(for: ExteraSettings.inAppVibration))
        reopened.reset(ExteraSettings.inAppVibration)
        XCTAssertTrue(reopened.value(for: ExteraSettings.inAppVibration))
    }

    func testOptionalStringCanBeCleared() throws {
        XCTAssertNil(store.value(for: ExteraSettings.editingIconPackId))
        try store.set("test-pack", for: ExteraSettings.editingIconPackId)
        XCTAssertEqual(store.value(for: ExteraSettings.editingIconPackId), "test-pack")
        try store.set(nil, for: ExteraSettings.editingIconPackId)
        XCTAssertNil(store.value(for: ExteraSettings.editingIconPackId))
    }

    func testNumericAndUnicodeValuesRoundTrip() throws {
        XCTAssertEqual(store.value(for: ExteraSettings.avatarCorners), 28)
        try store.set(Float(12.5), for: ExteraSettings.avatarCorners)
        XCTAssertEqual(store.value(for: ExteraSettings.avatarCorners), 12.5)
        try store.set("Архив 📁", for: ExteraSettings.customSavePath)
        XCTAssertEqual(store.value(for: ExteraSettings.customSavePath), "Архив 📁")
    }

    func testCorruptOrWrongTypeDataUsesRecoveredDefault() {
        defaults.set(Data("invalid-json".utf8), forKey: "extera.v1.inAppVibration")
        XCTAssertTrue(store.value(for: ExteraSettings.inAppVibration))
        defaults.set(Data("123".utf8), forKey: "extera.v1.inAppVibration")
        XCTAssertTrue(store.value(for: ExteraSettings.inAppVibration))
    }

    func testNamespacesAreIsolated() throws {
        let other = ExteraPreferences(defaults: defaults, namespace: "other")
        try store.set(false, for: ExteraSettings.inAppVibration)
        XCTAssertTrue(other.value(for: ExteraSettings.inAppVibration))
    }

    func testEnumOrdinalsAndInvalidValueFallback() throws {
        XCTAssertEqual(ExteraIconPackType.remix.rawValue, 2)
        XCTAssertEqual(ExteraDividerStyle.line.rawValue, 1)
        XCTAssertEqual(ExteraTabIconsMode.titlesOnly.rawValue, 1)
        XCTAssertEqual(ExteraTabCounterMode.all.rawValue, 0)
        XCTAssertEqual(ExteraTransitionAnimation.spring.rawValue, 2)
        XCTAssertEqual(ExteraGlassOutlineStyle.glare.rawValue, 0)
        XCTAssertEqual(ExteraStickerTimeMode.side.rawValue, 1)
        XCTAssertEqual(ExteraCameraType.cameraX.rawValue, 2)
        XCTAssertEqual(ExteraVideoMessagesCamera.ask.rawValue, 2)
        XCTAssertEqual(store.value(for: ExteraSettings.dividerStyle), .line)
        try store.set(.segments, for: ExteraSettings.dividerStyle)
        XCTAssertEqual(store.value(for: ExteraSettings.dividerStyle), .segments)
        XCTAssertEqual(defaults.data(forKey: "extera.v1.dividerStyle"), Data("2".utf8))
        defaults.set(Data("99".utf8), forKey: "extera.v1.dividerStyle")
        store.invalidate(ExteraSettings.dividerStyle)
        XCTAssertEqual(store.value(for: ExteraSettings.dividerStyle), .line)
    }

    func testSanitizerPreservesAssignedCacheAndNormalizesPersistence() throws {
        try store.set(100, for: ExteraSettings.doubleTapAction)
        XCTAssertEqual(store.value(for: ExteraSettings.doubleTapAction), 100)
        store.invalidate(ExteraSettings.doubleTapAction)
        XCTAssertEqual(store.value(for: ExteraSettings.doubleTapAction), 9)
        try store.set(-10, for: ExteraSettings.doubleTapAction)
        let reopened = ExteraPreferences(defaults: defaults)
        XCTAssertEqual(reopened.value(for: ExteraSettings.doubleTapAction), 0)
    }

    func testDoubleTapActionsDependOnMessageOwnership() {
        XCTAssertEqual(ExteraDoubleTap.action(setting: 5, outgoingOwner: true), .edit)
        XCTAssertEqual(ExteraDoubleTap.action(setting: 5, outgoingOwner: false), .save)
        XCTAssertEqual(ExteraDoubleTap.action(setting: 8, outgoingOwner: false), .translate)
        XCTAssertEqual(ExteraDoubleTap.action(setting: 9, outgoingOwner: false), .disabled)
        XCTAssertEqual(ExteraDoubleTap.action(setting: -1, outgoingOwner: true), .disabled)
        XCTAssertEqual(ExteraDoubleTap.action(setting: 20, outgoingOwner: true), .translate)
        XCTAssertEqual(ExteraDoubleTap.availableActions(outgoingOwner: true).count, 10)
        XCTAssertEqual(ExteraDoubleTap.availableActions(outgoingOwner: false).count, 9)
    }

    func testDynamicCameraDefaultRequiresAnExplicitPlatformPolicy() {
        XCTAssertEqual(store.value(for: ExteraSettings.cameraType(androidDevicePerformanceClass: 2)), .cameraX)
        let isolated = ExteraPreferences(defaults: defaults, namespace: "camera-policy")
        XCTAssertEqual(isolated.value(for: ExteraSettings.cameraType(androidDevicePerformanceClass: 1)), .camera1)
    }

    func testStoredNilIsDistinctFromNonNilDefault() throws {
        let preference = ExteraPreference<String?>(key: "optional-nonnil-default", defaultValue: "fallback")
        XCTAssertEqual(store.value(for: preference), "fallback")
        try store.set(nil, for: preference)
        store.invalidate(preference)
        XCTAssertNil(store.value(for: preference))
    }

    func testChangeNotificationIsPostedAfterReleasingLock() throws {
        let notification = expectation(description: "preference change")
        let currentStore = try XCTUnwrap(store)
        let token = NotificationCenter.default.addObserver(forName: .exteraPreferencesDidChange, object: currentStore, queue: nil) { event in
            XCTAssertEqual(event.userInfo?["key"] as? String, "inAppVibration")
            XCTAssertFalse(currentStore.value(for: ExteraSettings.inAppVibration))
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.set(false, for: ExteraSettings.inAppVibration)
        wait(for: [notification], timeout: 1)
    }
}
