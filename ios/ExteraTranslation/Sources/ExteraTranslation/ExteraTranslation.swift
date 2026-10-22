import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ordinals match the selected Lite APK's TranslationProviders.ALL.
public enum ExteraTranslationProvider: Int32, Codable, CaseIterable, Sendable {
    case telegram = 0
    case google = 1
    case yandex = 2
    case microsoft = 3

    public var displayName: String {
        switch self {
        case .telegram: return "Telegram"
        case .google: return "Google"
        case .yandex: return "Yandex"
        case .microsoft: return "Microsoft"
        }
    }
}

/// The user's own Azure resource credentials. No Android-app credential is used.
public struct ExteraMicrosoftCredentials: Sendable {
    public let subscriptionKey: String
    public let region: String?
    public init(subscriptionKey: String, region: String? = nil) {
        self.subscriptionKey = subscriptionKey
        self.region = region
    }
}

public enum ExteraTranslationError: Error, Equatable, Sendable {
    case nativeProviderRequired
    case configurationRequired
    case invalidLanguage
    case textTooLong
    case invalidResponse
    case unsupportedLanguage
    case rateLimited(retryAfterSeconds: Double)
    case temporaryServiceFailure(Int)
    case serviceRejected(Int)
    case transport(Int)
}

extension ExteraTranslationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nativeProviderRequired: return "Use the Telegram client's native translator for this provider."
        case .configurationRequired: return "This translator needs your own service credentials."
        case .invalidLanguage: return "The selected translation language is invalid."
        case .textTooLong: return "This text cannot be split within the translator's size limit."
        case .invalidResponse: return "The translator returned an unexpected response."
        case .unsupportedLanguage: return "The translator does not support this language."
        case .rateLimited: return "The translator is temporarily rate limited. Try again later."
        case .temporaryServiceFailure: return "The translator is temporarily unavailable."
        case .serviceRejected: return "The translator rejected the request."
        case .transport: return "The translator could not be reached."
        }
    }
}

/// A user-selected translator. Requests never fall back to another provider.
/// Google/Yandex protocols are recovered application protocols, not official
/// guaranteed public APIs. Cancellation is propagated to URLSession requests.
public actor ExteraTranslationClient {
    private let session: URLSession
    private let microsoft: ExteraMicrosoftCredentials?
    private let maxAttempts: Int
    private let requestIdentifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    public init(session: URLSession? = nil, microsoft: ExteraMicrosoftCredentials? = nil, maxAttempts: Int = 4) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: ExteraTranslationRedirectPolicy(), delegateQueue: nil)
        }
        self.microsoft = microsoft
        self.maxAttempts = min(max(maxAttempts, 1), 4)
    }

    public func translate(_ text: String, from source: String = "auto", to target: String,
                          provider: ExteraTranslationProvider) async throws -> String {
        return try await translate([text], from: source, to: target, provider: provider)[0]
    }

    public func translate(_ texts: [String], from source: String = "auto", to target: String,
                          provider: ExteraTranslationProvider) async throws -> [String] {
        try Task.checkCancellation()
        guard provider != .telegram else { throw ExteraTranslationError.nativeProviderRequired }
        guard validLanguage(target), source == "auto" || validLanguage(source) else {
            throw ExteraTranslationError.invalidLanguage
        }
        guard texts.reduce(0, { $0 + $1.utf16.count }) <= 1_000_000 else { throw ExteraTranslationError.textTooLong }
        let plans = try texts.map { try Self.pieces($0, limit: 5_000) }
        let payloads = plans.flatMap { $0 }.compactMap { piece -> String? in
            if case let .translate(text) = piece { return text }
            return nil
        }
        var translated: [String] = []
        let requestLimit = provider == .google ? 8_000 : 5_000
        var cursor = 0
        while cursor < payloads.count {
            try Task.checkCancellation()
            var end = cursor
            var units = 0
            while end < payloads.count, end - cursor < 20,
                  units + payloads[end].utf16.count <= requestLimit {
                units += payloads[end].utf16.count
                end += 1
            }
            let batch = Array(payloads[cursor..<end])
            let request = try makeRequest(batch, source: source, target: target, provider: provider)
            translated += try await execute(request, provider: provider, expectedCount: batch.count)
            cursor = end
        }
        var resultCursor = 0
        return plans.map { pieces in
            pieces.map { piece in
                switch piece {
                case let .literal(text): return text
                case .translate:
                    defer { resultCursor += 1 }
                    return translated[resultCursor]
                }
            }.joined()
        }
    }

    private func makeRequest(_ texts: [String], source: String, target: String,
                             provider: ExteraTranslationProvider) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        switch provider {
        case .google:
            components.host = "translate.googleapis.com"
            components.path = "/translate_a/t"
            components.queryItems = [URLQueryItem(name: "client", value: "gtx"),
                URLQueryItem(name: "sl", value: source), URLQueryItem(name: "tl", value: target),
                URLQueryItem(name: "dt", value: "t"), URLQueryItem(name: "format", value: "text"),
                URLQueryItem(name: "ie", value: "UTF-8"), URLQueryItem(name: "oe", value: "UTF-8")]
                + texts.map { URLQueryItem(name: "q", value: $0) }
        case .yandex:
            components.host = "translate.yandex.net"
            components.path = "/api/v1/tr.json/translate"
            components.queryItems = [URLQueryItem(name: "srv", value: "android"),
                URLQueryItem(name: "id", value: requestIdentifier + "-0-0")]
        case .microsoft:
            guard let microsoft, !microsoft.subscriptionKey.isEmpty,
                  !microsoft.subscriptionKey.contains(where: { $0.isNewline }),
                  microsoft.region?.contains(where: { $0.isNewline }) != true else {
                throw ExteraTranslationError.configurationRequired
            }
            components.host = "api.cognitive.microsofttranslator.com"
            components.path = "/translate"
            components.queryItems = [URLQueryItem(name: "api-version", value: "3.0"),
                                     URLQueryItem(name: "to", value: target)]
            if source != "auto" { components.queryItems?.append(URLQueryItem(name: "from", value: source)) }
        case .telegram:
            throw ExteraTranslationError.nativeProviderRequired
        }
        // URLQueryItem otherwise leaves literal + unescaped in a query.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ExteraTranslationError.invalidLanguage }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("GlowGram-iOS/1", forHTTPHeaderField: "User-Agent")
        if provider == .yandex {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = (["lang=" + Self.formEncode(target)] + texts.map { "text=" + Self.formEncode($0) })
                .joined(separator: "&").data(using: .utf8)
        } else if provider == .microsoft {
            request.httpMethod = "POST"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue(microsoft?.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            if let region = microsoft?.region { request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
            request.httpBody = try JSONSerialization.data(withJSONObject: texts.map { ["Text": $0] })
        }
        return request
    }

    private func execute(_ request: URLRequest, provider: ExteraTranslationProvider,
                         expectedCount: Int) async throws -> [String] {
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse, data.count <= 2_000_000 else {
                    throw ExteraTranslationError.invalidResponse
                }
                return try Self.parse(data, response: response, provider: provider, expectedCount: expectedCount)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let failure = (error as? ExteraTranslationError) ?? .transport((error as? URLError)?.code.rawValue ?? -1)
                let delay: Double
                switch failure {
                case let .rateLimited(seconds):
                    // Leave a long server cooldown to an explicit later retry.
                    // Never shorten Retry-After and send a request too early.
                    guard seconds <= 30 else { throw failure }
                    delay = max(seconds, pow(2, Double(attempt)))
                case .temporaryServiceFailure, .transport, .invalidResponse: delay = min(pow(2, Double(attempt)), 30)
                default: throw failure
                }
                if attempt + 1 == maxAttempts { throw failure }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw ExteraTranslationError.invalidResponse
    }

    static func parse(_ data: Data, response: HTTPURLResponse, provider: ExteraTranslationProvider,
                      expectedCount: Int) throws -> [String] {
        let status = response.statusCode
        let retry = max(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0, 0)
        if status == 429 { throw ExteraTranslationError.rateLimited(retryAfterSeconds: retry) }
        if (500..<600).contains(status) { throw ExteraTranslationError.temporaryServiceFailure(status) }
        if provider != .yandex, !(200..<300).contains(status) {
            throw ExteraTranslationError.serviceRejected(status)
        }
        guard !data.isEmpty else { throw ExteraTranslationError.invalidResponse }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            if !(200..<300).contains(status) { throw ExteraTranslationError.serviceRejected(status) }
            throw ExteraTranslationError.invalidResponse
        }
        let values: [String]
        switch provider {
        case .google:
            guard (200..<300).contains(status) else { throw ExteraTranslationError.serviceRejected(status) }
            guard let rows = object as? [Any] else { throw ExteraTranslationError.invalidResponse }
            values = try rows.map { row in
                if let text = row as? String { return text }
                if let tuple = row as? [Any], let text = tuple.first as? String { return text }
                throw ExteraTranslationError.invalidResponse
            }
        case .yandex:
            guard let body = object as? [String: Any] else { throw ExteraTranslationError.invalidResponse }
            let code = body["code"] as? Int ?? status
            if code == 429 || code == 1052 { throw ExteraTranslationError.rateLimited(retryAfterSeconds: retry) }
            if code == 501 { throw ExteraTranslationError.unsupportedLanguage }
            guard (200..<300).contains(status), code == 200 else { throw ExteraTranslationError.serviceRejected(code) }
            guard let text = body["text"] as? [String] else { throw ExteraTranslationError.invalidResponse }
            values = text
        case .microsoft:
            guard (200..<300).contains(status) else { throw ExteraTranslationError.serviceRejected(status) }
            guard let rows = object as? [[String: Any]] else { throw ExteraTranslationError.invalidResponse }
            values = try rows.map { row in
                guard let translations = row["translations"] as? [[String: Any]],
                      let text = translations.first?["text"] as? String else { throw ExteraTranslationError.invalidResponse }
                return text
            }
        case .telegram:
            throw ExteraTranslationError.nativeProviderRequired
        }
        guard values.count == expectedCount, values.allSatisfy({ !$0.isEmpty }) else { throw ExteraTranslationError.invalidResponse }
        return values
    }

    private func validLanguage(_ code: String) -> Bool {
        return code.range(of: "^[A-Za-z][A-Za-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    private static func formEncode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
    }

    private enum Piece {
        case literal(String)
        case translate(String)
    }

    private static func pieces(_ text: String, limit: Int) throws -> [Piece] {
        var result: [Piece] = []
        var line: [Character] = []
        func appendLine() throws {
            var cursor = 0
            while cursor < line.count {
                let start = cursor
                while cursor < line.count, line[cursor].isWhitespace { cursor += 1 }
                if cursor > start { result.append(.literal(String(line[start..<cursor]))) }
                if cursor == line.count { break }
                var end = cursor
                var units = 0
                var boundary: Int?
                while end < line.count, units + String(line[end]).utf16.count <= limit {
                    units += String(line[end]).utf16.count
                    if line[end].isWhitespace { boundary = end }
                    end += 1
                }
                guard end > cursor else { throw ExteraTranslationError.textTooLong }
                if end < line.count, let boundary, boundary > cursor { end = boundary }
                var trimmedEnd = end
                while trimmedEnd > cursor, line[trimmedEnd - 1].isWhitespace { trimmedEnd -= 1 }
                if trimmedEnd > cursor { result.append(.translate(String(line[cursor..<trimmedEnd]))) }
                if trimmedEnd < end { result.append(.literal(String(line[trimmedEnd..<end]))) }
                cursor = end
            }
            line.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character.isNewline {
                try appendLine()
                result.append(.literal(String(character)))
            } else {
                line.append(character)
            }
        }
        try appendLine()
        return result
    }
}

/// Never forward translated text or a configured Azure key to another host.
private final class ExteraTranslationRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let allowed = request.url?.scheme == "https" && request.url?.host == original?.host
        completionHandler(allowed ? request : nil)
    }
}
