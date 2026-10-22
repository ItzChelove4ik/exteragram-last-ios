import Foundation
import XCTest
@testable import ExteraSpeech

private final class MockTask: ExteraSpeechTask, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class MockBackend: ExteraSpeechBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var authorizationCallback: (@Sendable (Result<Void, ExteraSpeechError>) -> Void)?
    private var resultCallback: (@Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void)?
    private var recognitionCount = 0
    let task = MockTask()
    let authorizeImmediately: Bool
    let offlineAvailable: Bool
    let authorization: Result<Void, ExteraSpeechError>
    let locales: [String]

    init(authorizeImmediately: Bool = true, offlineAvailable: Bool = true,
         authorization: Result<Void, ExteraSpeechError> = .success(()), locales: [String] = ["en-US"]) {
        self.authorizeImmediately = authorizeImmediately
        self.offlineAvailable = offlineAvailable
        self.authorization = authorization
        self.locales = locales
    }

    func authorize(_ completion: @escaping @Sendable (Result<Void, ExteraSpeechError>) -> Void) {
        if authorizeImmediately { completion(authorization) }
        else { lock.lock(); authorizationCallback = completion; lock.unlock() }
    }
    func completeAuthorization() {
        lock.lock(); let callback = authorizationCallback; authorizationCallback = nil; lock.unlock()
        callback?(authorization)
    }
    func supportedLocaleIdentifiers() -> [String] { locales }
    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool { offlineAvailable }
    func recognize(fileURL: URL, localeIdentifier: String,
                   receive: @escaping @Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void) -> any ExteraSpeechTask {
        lock.lock(); recognitionCount += 1; resultCallback = receive; lock.unlock()
        return task
    }
    func emit(_ result: Result<ExteraSpeechTranscript, ExteraSpeechError>) {
        lock.lock(); let callback = resultCallback; lock.unlock(); callback?(result)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return recognitionCount }
}

final class ExteraSpeechTests: XCTestCase {
    private var directory: URL!
    private var audio: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audio = directory.appendingPathComponent("test.m4a")
        // The fake engine reads no audio; this fixture tests coordinator behavior.
        try Data([1, 2, 3]).write(to: audio)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testLocaleSelectionUsesExactRegionAndExplicitLanguageFallback() {
        let supported = ["en_US", "en-GB", "ru-RU"]
        XCTAssertEqual(ExteraSpeechLocale.resolve("en-US", supported: supported, preferred: "ru_RU"), "en_US")
        XCTAssertEqual(ExteraSpeechLocale.resolve("en", supported: supported, preferred: "en-GB"), "en-GB")
        XCTAssertNil(ExteraSpeechLocale.resolve("en-AU", supported: supported, preferred: "en-US"))
        XCTAssertNil(ExteraSpeechLocale.resolve("none", supported: supported, preferred: "en-US"))
        XCTAssertNil(ExteraSpeechLocale.resolve("", supported: supported, preferred: "en-US"))
    }

    func testPartialAndFinalTranscriptAndExactlyOneCompletion() {
        let backend = MockBackend()
        let transcriber = ExteraSpeechTranscriber(backend: backend)
        let partial = expectation(description: "partial")
        let final = expectation(description: "final")
        final.assertForOverFulfill = true
        let task = transcriber.transcribe(fileURL: audio, localeIdentifier: "en-US", partial: { value in
            XCTAssertEqual(value, ExteraSpeechTranscript(text: "hello", isFinal: false)); partial.fulfill()
        }, completion: { result in
            XCTAssertEqual(result, .success(ExteraSpeechTranscript(text: "hello world", isFinal: true))); final.fulfill()
        })
        backend.emit(.success(ExteraSpeechTranscript(text: " hello ", isFinal: false)))
        backend.emit(.success(ExteraSpeechTranscript(text: " hello world \n", isFinal: true)))
        backend.emit(.failure(.recognitionFailed("late error")))
        task.cancel()
        wait(for: [partial, final], timeout: 1, enforceOrder: true)
        XCTAssertTrue(backend.task.cancelled)
    }

    func testOfflineModelUnavailableNeverStartsRecognition() {
        let backend = MockBackend(offlineAvailable: false)
        let completed = expectation(description: "offline unavailable")
        let transcriber = ExteraSpeechTranscriber(backend: backend)
        let task = transcriber.transcribe(fileURL: audio, localeIdentifier: "en-US") { result in
            XCTAssertEqual(result, .failure(.onDeviceRecognitionUnavailable("en-US"))); completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(backend.count, 0)
        withExtendedLifetime(task) {}
    }

    func testDeniedPermissionDoesNotStartRecognition() {
        let backend = MockBackend(authorization: .failure(.authorizationDenied))
        let completed = expectation(description: "denied")
        let transcriber = ExteraSpeechTranscriber(backend: backend)
        let task = transcriber.transcribe(fileURL: audio, localeIdentifier: "en-US") { result in
            XCTAssertEqual(result, .failure(.authorizationDenied)); completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(backend.count, 0)
        withExtendedLifetime(task) {}
    }

    func testCancellationWhileAuthorizationPendingDoesNotStartRecognition() {
        let backend = MockBackend(authorizeImmediately: false)
        let transcriber = ExteraSpeechTranscriber(backend: backend)
        let completed = expectation(description: "cancelled")
        completed.assertForOverFulfill = true
        let task = transcriber.transcribe(fileURL: audio, localeIdentifier: "en-US") { result in
            XCTAssertEqual(result, .failure(.cancelled)); completed.fulfill()
        }
        task.cancel()
        backend.completeAuthorization()
        task.cancel()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(backend.count, 0)
    }

    func testTimeoutCancelsInFlightRecognition() {
        let backend = MockBackend()
        let transcriber = ExteraSpeechTranscriber(backend: backend, timeout: 0.02)
        let completed = expectation(description: "timed out")
        let task = transcriber.transcribe(fileURL: audio, localeIdentifier: "en-US") { result in
            XCTAssertEqual(result, .failure(.timedOut)); completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertTrue(backend.task.cancelled)
        withExtendedLifetime(task) {}
    }

    func testRemoteURLIsRejectedBeforeAuthorization() {
        let backend = MockBackend()
        let transcriber = ExteraSpeechTranscriber(backend: backend)
        let completed = expectation(description: "remote URL rejected")
        let task = transcriber.transcribe(fileURL: URL(string: "https://example.invalid/audio.m4a")!, localeIdentifier: "en-US") { result in
            XCTAssertEqual(result, .failure(.nonLocalFile)); completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(backend.count, 0)
        withExtendedLifetime(task) {}
    }

    func testEmptyFileAndEmptySpeechAreDifferentFailures() throws {
        let empty = directory.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        let backend = MockBackend()
        let transcriber = ExteraSpeechTranscriber(backend: backend)
        let invalid = expectation(description: "empty file")
        let noSpeech = expectation(description: "empty recognized text")
        let first = transcriber.transcribe(fileURL: empty, localeIdentifier: "en-US") { result in
            XCTAssertEqual(result, .failure(.invalidAudio)); invalid.fulfill()
        }
        let second = transcriber.transcribe(fileURL: audio, localeIdentifier: "en-US") { result in
            XCTAssertEqual(result, .failure(.noSpeech)); noSpeech.fulfill()
        }
        backend.emit(.success(ExteraSpeechTranscript(text: " \n", isFinal: true)))
        wait(for: [invalid, noSpeech], timeout: 1)
        withExtendedLifetime((first, second)) {}
    }
}
