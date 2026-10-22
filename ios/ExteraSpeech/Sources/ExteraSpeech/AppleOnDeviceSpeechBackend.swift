import Foundation

#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
import Speech
import AVFoundation

/// Uses Apple's installed, genuinely available on-device language model.
/// It never overrides supportsOnDeviceRecognition to pretend a model exists.
public final class AppleOnDeviceSpeechBackend: ExteraSpeechBackend, @unchecked Sendable {
    public init() {}

    public func authorize(_ completion: @escaping @Sendable (Result<Void, ExteraSpeechError>) -> Void) {
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(.missingUsageDescription)); return
        }
        DispatchQueue.main.async {
            SFSpeechRecognizer.requestAuthorization { status in
                let result: Result<Void, ExteraSpeechError>
                switch status {
                case .authorized: result = .success(())
                case .denied: result = .failure(.authorizationDenied)
                case .restricted: result = .failure(.authorizationRestricted)
                case .notDetermined: result = .failure(.authorizationUnavailable)
                @unknown default: result = .failure(.authorizationUnavailable)
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    public func supportedLocaleIdentifiers() -> [String] {
        SFSpeechRecognizer.supportedLocales().map(\.identifier)
    }

    public func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))?.supportsOnDeviceRecognition == true
    }

    public func recognize(fileURL: URL, localeIdentifier: String,
                          receive: @escaping @Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void) -> any ExteraSpeechTask {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            receive(.failure(.unsupportedLocale(localeIdentifier))); return EmptySpeechTask()
        }
        guard recognizer.supportsOnDeviceRecognition else {
            receive(.failure(.onDeviceRecognitionUnavailable(localeIdentifier))); return EmptySpeechTask()
        }
        do { _ = try AVAudioFile(forReading: fileURL) }
        catch { receive(.failure(.invalidAudio)); return EmptySpeechTask() }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        let token = AppleSpeechTask(recognizer: recognizer)
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                receive(.success(ExteraSpeechTranscript(text: result.bestTranscription.formattedString, isFinal: result.isFinal)))
                if result.isFinal { return }
            }
            if let error {
                receive(.failure(.recognitionFailed((error as NSError).localizedDescription)))
            }
        }
        token.install(task)
        return token
    }
}

private final class AppleSpeechTask: ExteraSpeechTask, @unchecked Sendable {
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    func install(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { self.task = task }
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        self.task = nil
        recognizer = nil
        lock.unlock()
        task?.cancel()
    }
}
#else
/// The production adapter is iOS-only. macOS package tests exercise the
/// coordinator with an injected backend and never prompt for speech access.
public struct AppleOnDeviceSpeechBackend: ExteraSpeechBackend {
    public init() {}
    public func authorize(_ completion: @escaping @Sendable (Result<Void, ExteraSpeechError>) -> Void) {
        completion(.failure(.unsupportedPlatform))
    }
    public func supportedLocaleIdentifiers() -> [String] { [] }
    public func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool { false }
    public func recognize(fileURL: URL, localeIdentifier: String,
                          receive: @escaping @Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void) -> any ExteraSpeechTask {
        receive(.failure(.unsupportedPlatform))
        return EmptySpeechTask()
    }
}
#endif

private struct EmptySpeechTask: ExteraSpeechTask {
    func cancel() {}
}
