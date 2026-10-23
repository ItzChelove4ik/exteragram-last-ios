import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One MTProto proxy candidate recovered by the search.
public struct ExteraProxyCandidate: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Equatable, Sendable {
        case mtprotoproxyList
        case proxyListPlus
        case manual
    }

    public let id: String
    public let host: String
    public let port: Int32
    /// Hex-encoded MTProto secret, ready for ProxyServerConnection.mtp(secret:).
    public let secretHex: String
    public let source: Source

    public init(host: String, port: Int32, secretHex: String, source: Source) {
        self.id = "\(host):\(port)"
        self.host = host
        self.port = port
        self.secretHex = secretHex
        self.source = source
    }
}

/// Validation state of a single proxy candidate.
public struct ExteraProxyValidation: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case pending
        case reachable
        case dead
        case invalidSecret
    }

    public let candidateId: String
    public let state: State
    /// TCP round-trip latency in milliseconds for reachable proxies.
    public let pingMilliseconds: Double?
    public let checkedAt: Date

    public init(candidateId: String, state: State, pingMilliseconds: Double? = nil, checkedAt: Date = Date()) {
        self.candidateId = candidateId
        self.state = state
        self.pingMilliseconds = pingMilliseconds
        self.checkedAt = checkedAt
    }
}

public enum ExteraProxySearchError: Error, Equatable, Sendable {
    case badURL
    case transport(String)
    case invalidData
    case cancelled
}

extension ExteraProxySearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badURL: return "The proxy list URL is invalid."
        case .transport(let message): return "Proxy list fetch failed: \(message)"
        case .invalidData: return "The proxy list could not be parsed."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Parser for the public MTProto proxy lists. The wsbypass plugin ships a
/// hard-coded server table; the port instead fetches fresh lists from the
/// public MTProto community endpoints and keeps the plugin's validation
/// discipline: parse, then TCP-ping before presenting.
public enum ExteraProxyListParser {
    /// Parses lines like "host:port:secret" (with optional "secret@" or
    /// "tg://proxy?..." forms rejected as unsupported).
    public static func parse(text: String, source: ExteraProxyCandidate.Source) -> [ExteraProxyCandidate] {
        var result: [ExteraProxyCandidate] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            let host = parts[0].trimmingCharacters(in: .whitespaces)
            let portText = parts[1].trimmingCharacters(in: .whitespaces)
            let secret = parts[2].trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, secret.count >= 32 else { continue }
            guard let port = Int32(portText), (1...65535).contains(port) else { continue }
            guard normalizeSecret(secret) != nil else { continue }
            let candidate = ExteraProxyCandidate(host: host, port: port, secretHex: secret.lowercased(), source: source)
            if !seen.contains(candidate.id) {
                seen.insert(candidate.id)
                result.append(candidate)
            }
        }
        return result
    }

    /// Accepts plain hex or base64 secrets; returns canonical lowercase hex.
    public static func normalizeSecret(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let hexSet = Set("0123456789abcdef")
        let isHex = lowered.count == 32 || lowered.count == 34 || lowered.count >= 34
        if isHex, lowered.allSatisfy({ hexSet.contains($0) }), (lowered.count == 32 || lowered.count == 34) {
            return lowered
        }
        // base64url fallback: decode, then re-encode to hex.
        var base64 = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        if let data = Data(base64Encoded: base64), data.count >= 16 {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }
}

/// TCP connect + teardown latency probe, the same reachability check the
/// wsbypass plugin performs before registering a worker endpoint.
public actor ExteraProxyValidator {
    public static let shared = ExteraProxyValidator()

    private let connectTimeout: Double

    public init(connectTimeout: Double = 5.0) {
        self.connectTimeout = connectTimeout
    }

    /// Measures TCP handshake latency to host:port. Returns milliseconds,
    /// or nil when the endpoint is unreachable within the timeout.
    public func measureLatency(host: String, port: Int32) async -> Double? {
        let timeout = self.connectTimeout
        return await withCheckedContinuation { continuation in
            let started = CFAbsoluteTimeGetCurrent()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port))!, using: .tcp)
            var settled = false
            let settleLock = NSLock()
            let finish: (Double?) -> Void = { latency in
                settleLock.lock()
                let already = settled
                settled = true
                settleLock.unlock()
                guard !already else { return }
                connection.cancel()
                continuation.resume(returning: latency)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish((CFAbsoluteTimeGetCurrent() - started) * 1000.0)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    /// Validates one candidate end to end and reports the resulting state.
    public func validate(candidate: ExteraProxyCandidate) async -> ExteraProxyValidation {
        guard ExteraProxyListParser.normalizeSecret(candidate.secretHex) != nil else {
            return ExteraProxyValidation(candidateId: candidate.id, state: .invalidSecret)
        }
        if let milliseconds = await measureLatency(host: candidate.host, port: candidate.port) {
            return ExteraProxyValidation(candidateId: candidate.id, state: .reachable, pingMilliseconds: milliseconds)
        }
        return ExteraProxyValidation(candidateId: candidate.id, state: .dead)
    }

    /// Validates candidates concurrently, emitting progress through the
    /// async stream as each check finishes.
    public func validateAll(candidates: [ExteraProxyCandidate], concurrency: Int = 6) -> AsyncStream<ExteraProxyValidation> {
        AsyncStream { continuation in
            let task = Task {
                var buffer = candidates
                var inFlight = 0
                let limit = max(1, concurrency)
                let allDone = { inFlight == 0 && buffer.isEmpty }
                while !allDone() {
                    while inFlight < limit, !buffer.isEmpty {
                        let candidate = buffer.removeFirst()
                        inFlight += 1
                        Task { [weak self] in
                            let validation: ExteraProxyValidation
                            if let self {
                                validation = await self.validate(candidate: candidate)
                            } else {
                                validation = ExteraProxyValidation(candidateId: candidate.id, state: .dead)
                            }
                            continuation.yield(validation)
                            inFlight -= 1
                        }
                    }
                    // Let concurrent validations run before refilling slots.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Fetches and merges the public MTProto proxy lists.
public actor ExteraProxyListFetcher {
    public static let shared = ExteraProxyListFetcher()

    public let listURLs: [URL]

    public init(listURLs: [URL]? = nil) {
        if let listURLs {
            self.listURLs = listURLs
        } else {
            self.listURLs = [
                URL(string: "https://mtprotoproxylist.github.io")!,
                URL(string: "https://raw.githubusercontent.com/hook-s3c/proxy-list-for-telegram/main/proxy-list.txt")!
            ]
        }
    }

    public func fetchAll() async throws -> [ExteraProxyCandidate] {
        var result: [ExteraProxyCandidate] = []
        var seen = Set<String>()
        try await withThrowingTaskGroup(of: (ExteraProxyCandidate.Source, String).self) { group in
            for url in self.listURLs {
                group.addTask {
                    let (data, response) = try await self.fetch(url: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw ExteraProxySearchError.invalidData
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw ExteraProxySearchError.invalidData
                    }
                    let source: ExteraProxyCandidate.Source = url.host?.contains("mtprotoproxylist") == true ? .mtprotoproxyList : .proxyListPlus
                    return (source, text)
                }
            }
            for try await (source, text) in group {
                for candidate in ExteraProxyListParser.parse(text: text, source: source) {
                    if !seen.contains(candidate.id) {
                        seen.insert(candidate.id)
                        result.append(candidate)
                    }
                }
            }
        }
        return result
    }

    private func fetch(url: URL) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(from: url)
    }
}
