//
//  DebugNetworkProtocol.swift
//  ShareCore
//
//  Created by Copilot on 2026/02/28.
//

import Foundation

/// Custom URLProtocol that intercepts HTTP(S) requests and logs them to NetworkRequestLogger.
public final class DebugNetworkProtocol: URLProtocol, URLSessionDataDelegate {
    private static let bodyCountKey = "com.zanderwang.DebugNetworkProtocol.bodyCount"
    private static let bodyKey = "com.zanderwang.DebugNetworkProtocol.body"
    private static let handledKey = "com.zanderwang.DebugNetworkProtocol.handled"

    /// One shared session keeps connection reuse; a new session per request forces a fresh TLS handshake.
    private static let router = InnerTaskRouter()
    private static let innerSession: URLSession = {
        // The forwarded request is sent by this session, so it needs the app User-Agent too.
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": ClientUserAgent.value]
        return URLSession(configuration: config, delegate: router, delegateQueue: nil)
    }()

    private var innerTask: URLSessionDataTask?
    private var responseBodyByteCount = 0
    private var responseBody = Data()
    private var capturesBodies = false
    private var startTime: Date?
    private var httpResponse: HTTPURLResponse?

    // MARK: - URLProtocol Overrides

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme, ["http", "https"].contains(scheme) else {
            return false
        }
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }
        return true
    }

    /// URLSession can replace httpBody with a stream before URLProtocol sees the request.
    static func preserveBodyForDebug(in request: inout URLRequest) {
        guard DeveloperMode.isEnabledNonisolated, let body = request.httpBody,
              let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(Data(body.prefix(NetworkRequestRecord.bodyCaptureLimit + 1)), forKey: bodyKey, in: mutable)
        URLProtocol.setProperty(body.count, forKey: bodyCountKey, in: mutable)
        request = mutable as URLRequest
    }

    @MainActor
    public static func refreshLoggingEnabled() {}

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override public func startLoading() {
        startTime = Date()
        capturesBodies = DeveloperMode.isEnabledNonisolated

        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        let task = Self.innerSession.dataTask(with: mutableRequest as URLRequest)
        Self.router.register(self, for: task)
        innerTask = task
        task.resume()
    }

    override public func stopLoading() {
        if let innerTask {
            Self.router.unregister(innerTask)
            innerTask.cancel()
        }
        innerTask = nil
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        httpResponse = response as? HTTPURLResponse
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    public func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        responseBodyByteCount += data.count
        if capturesBodies, responseBody.count <= NetworkRequestRecord.bodyCaptureLimit {
            responseBody.append(data.prefix(NetworkRequestRecord.bodyCaptureLimit + 1 - responseBody.count))
        }
        client?.urlProtocol(self, didLoad: data)
    }

    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Self.router.unregister(task)
        if let error {
            logRecord(error: error)
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            logRecord(error: nil)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    // MARK: - Logging

    private func logRecord(error: Error?) {
        let latency = startTime.map { Date().timeIntervalSince($0) }
        let source: NetworkRequestRecord.Source = Bundle.main.bundleURL.pathExtension == "appex" ? .extension : .app

        let requestHeaders = request.allHTTPHeaderFields ?? [:]

        var responseHeaders: [String: String]?
        if let headers = httpResponse?.allHeaderFields as? [String: String] {
            responseHeaders = headers
        }

        let record = NetworkRequestRecord(
            timestamp: startTime ?? Date(),
            source: source,
            httpMethod: request.httpMethod ?? "GET",
            url: FeedbackLogSanitizer.sanitizeURL(request.url),
            requestHeaders: FeedbackLogSanitizer.sanitizeHeaders(requestHeaders),
            requestBody: capturesBodies ? (request.httpBody ?? URLProtocol.property(forKey: Self.bodyKey, in: request) as? Data) :
                nil,
            requestBodyByteCount: request.httpBody?.count ?? URLProtocol.property(forKey: Self.bodyCountKey, in: request) as? Int,
            statusCode: httpResponse?.statusCode,
            responseHeaders: responseHeaders.map(FeedbackLogSanitizer.sanitizeHeaders),
            responseBody: capturesBodies ? responseBody : nil,
            responseBodyByteCount: responseBodyByteCount,
            latency: latency,
            errorDescription: error.map { "\(($0 as NSError).domain) (\(($0 as NSError).code)): \($0.localizedDescription)" }
        )

        NetworkRequestLogger.addRecord(record)
    }
}

/// Forwards shared-session delegate callbacks to the protocol instance that owns each task.
private final class InnerTaskRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [Int: DebugNetworkProtocol] = [:]

    func register(_ owner: DebugNetworkProtocol, for task: URLSessionTask) {
        lock.withLock { owners[task.taskIdentifier] = owner }
    }

    func unregister(_ task: URLSessionTask) {
        _ = lock.withLock { owners.removeValue(forKey: task.taskIdentifier) }
    }

    private func owner(of task: URLSessionTask) -> DebugNetworkProtocol? {
        lock.withLock { owners[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let owner = owner(of: dataTask) else {
            completionHandler(.cancel)
            return
        }
        owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner(of: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner(of: task)?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
