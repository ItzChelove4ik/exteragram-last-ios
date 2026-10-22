import Foundation

public enum ExteraSpeechError: Error, Equatable, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case authorizationUnavailable
    case missingUsageDescription
    case unsupportedPlatform
    case unsupportedLocale(String)
    case onDeviceRecognitionUnavailable(String)
    case fileNotFound
    case invalidAudio
    case nonLocalFile
    case noSpeech
    case cancelled
    case timedOut
    case recognitionFailed(String)
}

public struct ExteraSpeechTranscript: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public protocol ExteraSpeechTask: Sendable {
    func cancel()
}

/// Implementations must keep recognition local. No network-fallback option is
/// exposed by this API; the Apple adapter requires on-device recognition.
public protocol ExteraSpeechBackend: Sendable {
    func authorize(_ completion: @escaping @Sendable (Result<Void, ExteraSpeechError>) -> Void)
    func supportedLocaleIdentifiers() -> [String]
    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool
    func recognize(fileURL: URL, localeIdentifier: String,
                   receive: @escaping @Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void) -> any ExteraSpeechTask
}

public enum ExteraSpeechLocale {
    /// Exact regional locale first. A language-only code may select the user's
    /// preferred regional variant; an explicitly unsupported region is not
    /// silently changed to a different recognition model.
    public static func resolve(_ requested: String, supported: [String], preferred: String) -> String? {
        func canonical(_ value: String) -> String {
            value.replacingOccurrences(of: "-", with: "_").lowercased()
        }
        let wanted = canonical(requested)
        guard !wanted.isEmpty, wanted != "none" else { return nil }
        let sorted = supported.sorted()
        if let exact = sorted.first(where: { canonical($0) == wanted }) {
            return exact
        }
        guard !wanted.contains("_") else { return nil }
        let variants = sorted.filter { canonical($0).split(separator: "_").first.map(String.init) == wanted }
        return variants.first(where: { canonical($0) == canonical(preferred) }) ?? variants.first
    }
}

/// File-only transcription. This class never requests microphone access or
/// uploads a downloaded voice message. Permission is requested by an explicit
/// transcription action and cancellation prevents a pending authorization
/// callback from starting recognition afterwards.
public final class ExteraSpeechTranscriber: Sendable {
    private let backend: any ExteraSpeechBackend
    private let delivery: DispatchQueue
    private let timeout: TimeInterval
    private let preferredLocale: String

    public init(backend: any ExteraSpeechBackend = AppleOnDeviceSpeechBackend(),
                callbackQueue: DispatchQueue = .main, timeout: TimeInterval = 120,
                preferredLocale: String = Locale.current.identifier) {
        self.backend = backend
        self.delivery = DispatchQueue(label: "ExteraSpeech.callbacks", target: callbackQueue)
        self.timeout = timeout.isFinite && timeout >= 0 ? timeout : 120
        self.preferredLocale = preferredLocale
    }

    @discardableResult
    public func transcribe(fileURL: URL, localeIdentifier: String,
                           partial: (@Sendable (ExteraSpeechTranscript) -> Void)? = nil,
                           completion: @escaping @Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void) -> any ExteraSpeechTask {
        let job = SpeechJob(backend: backend, delivery: delivery, timeout: timeout,
                            preferredLocale: preferredLocale, partial: partial, completion: completion)
        job.start(fileURL: fileURL, requestedLocale: localeIdentifier)
        return job
    }
}

private final class SpeechJob: ExteraSpeechTask, @unchecked Sendable {
    private let backend: any ExteraSpeechBackend
    private let delivery: DispatchQueue
    private let timeout: TimeInterval
    private let preferredLocale: String
    private let partial: (@Sendable (ExteraSpeechTranscript) -> Void)?
    private let completion: @Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void
    private let lock = NSLock()
    private var finished = false
    private var task: (any ExteraSpeechTask)?
    private var timer: DispatchSourceTimer?

    init(backend: any ExteraSpeechBackend, delivery: DispatchQueue, timeout: TimeInterval,
         preferredLocale: String, partial: (@Sendable (ExteraSpeechTranscript) -> Void)?,
         completion: @escaping @Sendable (Result<ExteraSpeechTranscript, ExteraSpeechError>) -> Void) {
        self.backend = backend
        self.delivery = delivery
        self.timeout = timeout
        self.preferredLocale = preferredLocale
        self.partial = partial
        self.completion = completion
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func start(fileURL: URL, requestedLocale: String) {
        guard fileURL.isFileURL else { finish(.failure(.nonLocalFile)); return }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { finish(.failure(.fileNotFound)); return }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            finish(.failure(.invalidAudio)); return
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(.timedOut)) }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()

        backend.authorize { [self] authorization in
            guard !isFinished else { return }
            if case let .failure(error) = authorization { finish(.failure(error)); return }
            guard let locale = ExteraSpeechLocale.resolve(requestedLocale, supported: backend.supportedLocaleIdentifiers(), preferred: preferredLocale) else {
                finish(.failure(.unsupportedLocale(requestedLocale))); return
            }
            guard backend.supportsOnDeviceRecognition(localeIdentifier: locale) else {
                finish(.failure(.onDeviceRecognitionUnavailable(locale))); return
            }
            guard !isFinished else { return }
            let token = backend.recognize(fileURL: fileURL, localeIdentifier: locale) { [self] result in
                guard !isFinished else { return }
                switch result {
                case let .failure(error): finish(.failure(error))
                case let .success(transcript):
                    let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if transcript.isFinal {
                        finish(text.isEmpty ? .failure(.noSpeech) : .success(ExteraSpeechTranscript(text: text, isFinal: true)))
                    } else if !text.isEmpty {
                        deliverPartial(text)
                    }
                }
            }
            lock.lock()
            let alreadyFinished = finished
            if !alreadyFinished { task = token }
            lock.unlock()
            if alreadyFinished { token.cancel() }
        }
    }

    func cancel() {
        finish(.failure(.cancelled))
    }

    private func deliverPartial(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let partial else { return }
        delivery.async { partial(ExteraSpeechTranscript(text: text, isFinal: false)) }
    }

    private func finish(_ result: Result<ExteraSpeechTranscript, ExteraSpeechError>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let task = self.task
        self.task = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        task?.cancel()
        delivery.async { [completion] in completion(result) }
    }
}
