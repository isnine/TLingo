//
//  NetworkRequestRecord.swift
//  ShareCore
//
//  Created by Copilot on 2026/02/28.
//

import Foundation

/// A single network request/response record for debug inspection.
public struct NetworkRequestRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let source: Source

    // Request
    public let httpMethod: String
    public let url: String
    public let requestHeaders: [String: String]
    public let requestBody: Data?
    public let requestBodyByteCount: Int?

    // Response
    public var statusCode: Int?
    public var responseHeaders: [String: String]?
    public var responseBody: Data?
    public var responseBodyByteCount: Int?
    public var latency: TimeInterval?
    public var errorDescription: String?
    public var translationTiming: TranslationTimingTrace.Snapshot?

    public enum Source: String, Codable, Sendable {
        case app
        case `extension`
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: Source,
        httpMethod: String,
        url: String,
        requestHeaders: [String: String],
        requestBody: Data? = nil,
        requestBodyByteCount: Int? = nil,
        statusCode: Int? = nil,
        responseHeaders: [String: String]? = nil,
        responseBody: Data? = nil,
        responseBodyByteCount: Int? = nil,
        latency: TimeInterval? = nil,
        errorDescription: String? = nil,
        translationTiming: TranslationTimingTrace.Snapshot? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.httpMethod = httpMethod
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.requestBodyByteCount = requestBodyByteCount
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseBodyByteCount = responseBodyByteCount
        self.latency = latency
        self.errorDescription = errorDescription
        self.translationTiming = translationTiming
    }
}

// MARK: - Display Helpers

public extension NetworkRequestRecord {
    /// Short path component for list display (e.g. "/gpt-4o/chat/completions")
    var urlPath: String {
        guard let components = URLComponents(string: url) else { return url }
        return components.path
    }

    var requestBodyString: String? {
        guard let data = requestBody else { return nil }
        return prettyJSON(data) ?? String(data: data, encoding: .utf8)
    }

    var responseBodyString: String? {
        guard let data = responseBody else { return nil }
        return prettyJSON(data) ?? String(data: data, encoding: .utf8)
    }

    var formattedLatency: String {
        guard let latency else { return "—" }
        if latency < 1 {
            return String(format: "%.0f ms", latency * 1000)
        }
        return String(format: "%.2f s", latency)
    }

    var statusColor: StatusColor {
        if errorDescription != nil {
            return .serverError
        }
        guard let code = statusCode else { return .unknown }
        switch code {
        case 200 ..< 300: return .success
        case 400 ..< 500: return .clientError
        case 500...: return .serverError
        default: return .unknown
        }
    }

    enum StatusColor: Sendable {
        case success, clientError, serverError, unknown
    }

    private func prettyJSON(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }
}

extension NetworkRequestRecord {
    static let bodyCaptureLimit = 64 * 1024

    var outcome: String {
        if errorDescription != nil {
            return "Network error"
        }
        guard let statusCode else { return "No response" }
        return (200 ..< 300).contains(statusCode) ? "HTTP success" : "HTTP error"
    }

    func sanitizedForDebug() -> NetworkRequestRecord {
        NetworkRequestRecord(
            id: id, timestamp: timestamp, source: source, httpMethod: httpMethod,
            url: FeedbackLogSanitizer.sanitizeURL(URL(string: url)),
            requestHeaders: FeedbackLogSanitizer.sanitizeHeaders(requestHeaders),
            requestBody: Self.sanitizedBody(requestBody),
            requestBodyByteCount: requestBodyByteCount ?? requestBody?.count,
            statusCode: statusCode,
            responseHeaders: responseHeaders.map(FeedbackLogSanitizer.sanitizeHeaders),
            responseBody: Self.sanitizedBody(responseBody),
            responseBodyByteCount: responseBodyByteCount ?? responseBody?.count,
            latency: latency,
            errorDescription: errorDescription.map(FeedbackLogSanitizer.sanitizeLogMessage),
            translationTiming: translationTiming
        )
    }

    private static func sanitizedBody(_ data: Data?) -> Data? {
        guard let data else { return nil }
        // Do not export a partial JSON object: secrets may straddle the capture boundary.
        guard data.count <= bodyCaptureLimit else { return Data("<body exceeded capture limit>".utf8) }
        if let json = try? JSONSerialization.jsonObject(with: data), json is [String: Any] || json is [Any] {
            return FeedbackLogSanitizer.sanitizeBody(data).map { Data($0.utf8) }
        }
        guard let text = String(data: data, encoding: .utf8) else { return Data("<binary body omitted>".utf8) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
            text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        {
            return Data("<incomplete JSON body omitted>".utf8)
        }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("data:"), let payload = line.dropFirst(5).data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: payload)) != nil
            {
                guard let sanitized = FeedbackLogSanitizer.sanitizeBody(payload),
                      let sanitizedData = sanitized.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: sanitizedData),
                      let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                else {
                    return "data: <event exceeded capture limit>"
                }
                return "data: " + String(decoding: compact, as: UTF8.self)
            }
            if line.hasPrefix("data:"), !line.contains("[DONE]") {
                return "data: <incomplete event omitted>"
            }
            return FeedbackLogSanitizer.sanitizeLogMessage(line)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private var responseForReport: String? {
        guard let raw = responseBodyString, raw.contains("data:") else { return responseBodyString }
        var output = ""
        var count = 0
        var reasons: [String] = []
        var complete = false
        for line in raw.components(separatedBy: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                complete = true
                continue
            }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["error"] == nil,
                  let choices = event["choices"] as? [[String: Any]] else { return raw }
            count += 1
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String {
                    output += content
                }
                if let reason = choice["finish_reason"] as? String {
                    reasons.append(reason)
                }
            }
        }
        guard !output.isEmpty else { return raw }
        return """
        SSE events: \(count)
        Stream terminator: \(complete ? "[DONE]" : "missing")
        Finish reason: \(reasons.joined(separator: ", "))

        Model output:
        \(output)
        """
    }

    var debugReport: String {
        let safe = sanitizedForDebug()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        func headers(_ values: [String: String]) -> String {
            values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        func body(_ data: Data?, count: Int?) -> String {
            guard let data else { return "<not captured; \(count.map(String.init) ?? "unknown") bytes>" }
            return String(decoding: data, as: UTF8.self)
        }
        let timingReport = safe.translationTiming.map { timing in
            let milestones = timing.milliseconds.sorted { $0.value < $1.value }
                .map { "\($0.key): \(String(format: "%.1f", $0.value)) ms" }.joined(separator: "\n")
            return """
            ## Translation timing
            Correlation ID: \(timing.requestID)
            Milestones relative to submission (monotonic clock):
            \(milestones)
            Content delta events (not tokenizer tokens): \(timing.contentChunks)
            Upstream response headers: \(timing.upstreamHeaderMilliseconds.map { String(format: "%.1f ms", $0) } ?? "unavailable")
            Server-Timing: \(timing.serverTiming ?? "unavailable")
            Display callbacks, when present, are frame approximations, not pixel visibility measurements.
            """
        } ?? ""
        return """
        # TLingo Network Debug
        App: \(version) (\(build))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Request ID: \(safe.id.uuidString)
        Time: \(ISO8601DateFormatter().string(from: safe.timestamp))
        Source: \(safe.source.rawValue)
        Result: \(safe.outcome) (\(safe.statusCode.map(String.init) ?? "no HTTP status"))
        Duration: \(safe.formattedLatency)
        Error: \(safe.errorDescription ?? "none")
        Note: HTTP success does not verify translation correctness. Captured text may contain your input.

        ## Request
        \(safe.httpMethod) \(safe.url)
        \(headers(safe.requestHeaders))
        Body bytes: \(safe.requestBodyByteCount.map(String.init) ?? "unknown")
        \(body(safe.requestBody, count: safe.requestBodyByteCount))

        ## Response
        \(headers(safe.responseHeaders ?? [:]))
        Body bytes: \(safe.responseBodyByteCount.map(String.init) ?? "unknown")
        \(safe.responseForReport ?? body(nil, count: safe.responseBodyByteCount))

        \(timingReport)
        """
    }
}
