import Foundation
import os

/// Monotonic, request-scoped milestones. Content chunks are not tokenizer tokens.
public final class TranslationTimingTrace: @unchecked Sendable {
    public static let processStartedAt = ContinuousClock.now

    public enum Stage: String, Sendable {
        case languageResolved
        case requestPrepared
        case responseHeaders
        case firstContent
        case firstUsefulContent
        case lastContent
        case streamFinished
        case firstUIUpdate
        case resultApplied
        case diffComputed
        case markdownParsed
        case firstUIFrame
        case finalUIFrame
    }

    public struct NetworkTransactionTiming: Codable, Sendable, Equatable {
        public let networkProtocolName: String?
        public let isReusedConnection: Bool
        public let dnsLookupMs: Double?
        public let tcpConnectMs: Double?
        public let tlsHandshakeMs: Double?
        public let requestSendMs: Double?
        public let responseWaitMs: Double?
        public let responseReceiveMs: Double?
        public let totalTransactionMs: Double?

        public init(
            networkProtocolName: String? = nil,
            isReusedConnection: Bool = false,
            dnsLookupMs: Double? = nil,
            tcpConnectMs: Double? = nil,
            tlsHandshakeMs: Double? = nil,
            requestSendMs: Double? = nil,
            responseWaitMs: Double? = nil,
            responseReceiveMs: Double? = nil,
            totalTransactionMs: Double? = nil
        ) {
            self.networkProtocolName = networkProtocolName
            self.isReusedConnection = isReusedConnection
            self.dnsLookupMs = dnsLookupMs
            self.tcpConnectMs = tcpConnectMs
            self.tlsHandshakeMs = tlsHandshakeMs
            self.requestSendMs = requestSendMs
            self.responseWaitMs = responseWaitMs
            self.responseReceiveMs = responseReceiveMs
            self.totalTransactionMs = totalTransactionMs
        }
    }

    public struct SegmentBreakdown: Codable, Sendable {
        public let launchToSubmitMs: Double?
        public let languageResolutionMs: Double?
        public let requestPreparationMs: Double?
        public let dnsLookupMs: Double?
        public let tcpConnectMs: Double?
        public let tlsHandshakeMs: Double?
        public let isReusedConnection: Bool?
        public let workerPreUpstreamMs: Double?
        public let upstreamHeaderTTFBMs: Double?
        public let clientToWorkerTransitResidualMs: Double?
        public let headersToFirstContentMs: Double?
        public let jsonPrefixToFirstUsefulContentMs: Double?
        public let firstContentToFirstUIUpdateMs: Double?
        public let firstUIUpdateToFirstFrameMs: Double?
        public let timeToFirstVisibleTextMs: Double?
        public let streamingGenerationMs: Double?
        public let streamTailToFinishMs: Double?
        public let finalParseAndApplyMs: Double?
        public let diffComputeMs: Double?
        public let markdownParseMs: Double?
        public let resultApplyToFinalFrameMs: Double?
        public let totalEndToEndMs: Double?
    }

    public struct Snapshot: Codable, Sendable {
        public let requestID: String
        public let actionID: String?
        public let modelID: String?
        public let inputCharacters: Int?
        public let outputCharacters: Int?
        public let milliseconds: [String: Double]
        public let contentChunks: Int
        public let upstreamHeaderMilliseconds: Double?
        public let workerPreUpstreamMilliseconds: Double?
        public let serverTiming: String?
        public let responseContentType: String?
        public let cfRay: String?
        public let cfPlacement: String?
        public let networkTransaction: NetworkTransactionTiming?
        public let breakdown: SegmentBreakdown?
    }

    private final class WeakTrace {
        weak var value: TranslationTimingTrace?

        init(_ value: TranslationTimingTrace) {
            self.value = value
        }
    }

    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [String: WeakTrace] = [:]

    public let requestID = UUID().uuidString
    private let startedAt: ContinuousClock.Instant
    private let lock = NSLock()
    private var actionID: String?
    private var modelID: String?
    private var inputCharacters: Int?
    private var outputCharacters: Int?
    private var stages: [String: Double] = [:]
    private var contentChunks = 0
    private var upstreamHeaderMilliseconds: Double?
    private var workerPreUpstreamMilliseconds: Double?
    private var serverTiming: String?
    private var responseContentType: String?
    private var cfRay: String?
    private var cfPlacement: String?
    private var networkTransaction: NetworkTransactionTiming?
    private let signpostID = PerformanceSignposts.signposter.makeSignpostID()
    private var signpostInterval: OSSignpostIntervalState?

    public init(startedAt: ContinuousClock.Instant = .now) {
        self.startedAt = startedAt
        signpostInterval = PerformanceSignposts.signposter.beginInterval("Translation Run", id: signpostID)
        Self.register(self)
    }

    deinit {
        Self.unregister(requestID: requestID)
        if let signpostInterval {
            PerformanceSignposts.signposter.endInterval("Translation Run", signpostInterval, "incomplete")
        }
    }

    public static func recordNetworkTransaction(_ timing: NetworkTransactionTiming, forRequestID requestID: String) {
        trace(forRequestID: requestID)?.recordNetworkTransaction(timing)
    }

    private static func register(_ trace: TranslationTimingTrace) {
        registryLock.withLock {
            if registry.count >= 128 {
                registry = registry.filter { $0.value.value != nil }
            }
            registry[trace.requestID] = WeakTrace(trace)
        }
    }

    private static func unregister(requestID: String) {
        _ = registryLock.withLock {
            registry.removeValue(forKey: requestID)
        }
    }

    private static func trace(forRequestID requestID: String) -> TranslationTimingTrace? {
        registryLock.withLock {
            registry[requestID]?.value
        }
    }

    public func recordActionAndModel(actionID: String, modelID: String, inputCharacters: Int) {
        lock.withLock {
            self.actionID = actionID
            self.modelID = modelID
            self.inputCharacters = inputCharacters
        }
    }

    public func recordOutputCharacters(_ count: Int) {
        lock.withLock {
            outputCharacters = count
        }
    }

    public func recordNetworkTransaction(_ timing: NetworkTransactionTiming) {
        lock.withLock {
            networkTransaction = timing
        }
    }

    public func mark(_ stage: Stage, at instant: ContinuousClock.Instant = .now) {
        let milliseconds = Self.milliseconds(from: startedAt, to: instant)
        let (isFirstMark, endingInterval) = lock.withLock { () -> (Bool, OSSignpostIntervalState?) in
            let isFirstMark = stages[stage.rawValue] == nil
            if stage == .lastContent || stage == .finalUIFrame || isFirstMark {
                stages[stage.rawValue] = milliseconds
            }
            guard isFirstMark, stage == .resultApplied, let interval = signpostInterval else { return (isFirstMark, nil) }
            signpostInterval = nil
            return (isFirstMark, interval)
        }
        // lastContent fires per chunk; only first marks become events.
        if isFirstMark, stage != .lastContent {
            PerformanceSignposts.signposter.emitEvent(
                "Translation Stage",
                id: signpostID,
                "\(stage.rawValue, privacy: .public) \(milliseconds, format: .fixed(precision: 0), privacy: .public)ms"
            )
        }
        if let endingInterval {
            PerformanceSignposts.signposter.endInterval("Translation Run", endingInterval)
        }
    }

    func receiveContent() {
        let now = ContinuousClock.now
        mark(.firstContent, at: now)
        mark(.lastContent, at: now)
        lock.withLock { contentChunks += 1 }
    }

    func receiveHeaders(_ response: HTTPURLResponse, at instant: ContinuousClock.Instant = .now) {
        mark(.responseHeaders, at: instant)
        recordResponseMetadata(response)
    }

    func recordResponseMetadata(_ response: HTTPURLResponse) {
        let headerTiming = response.value(forHTTPHeaderField: "Server-Timing")
        let parsedServerTiming = Self.parseServerTiming(headerTiming)
        let explicitUpstream = response.value(forHTTPHeaderField: "X-Upstream-TTFB")
            .flatMap(Double.init)
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }

        lock.withLock {
            serverTiming = headerTiming
            workerPreUpstreamMilliseconds = parsedServerTiming.preUpstream
            upstreamHeaderMilliseconds = explicitUpstream ?? parsedServerTiming.upstream
            responseContentType = response.value(forHTTPHeaderField: "Content-Type")
            cfRay = response.value(forHTTPHeaderField: "CF-Ray")
            cfPlacement = response.value(forHTTPHeaderField: "X-CF-Placement")
        }
    }

    /// Header wait minus upstream header wait; includes Worker overhead, not generation.
    var clientHeaderOverhead: TimeInterval? {
        let snapshot = snapshot()
        guard let prepared = snapshot.milliseconds[Stage.requestPrepared.rawValue],
              let headers = snapshot.milliseconds[Stage.responseHeaders.rawValue],
              let upstream = snapshot.upstreamHeaderMilliseconds
        else { return nil }
        return max(headers - prepared - upstream, 0) / 1000
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            let breakdown = Self.makeBreakdown(
                startedAt: startedAt,
                stages: stages,
                upstreamHeaderMs: upstreamHeaderMilliseconds,
                workerPreUpstreamMs: workerPreUpstreamMilliseconds,
                networkTransaction: networkTransaction
            )
            return Snapshot(
                requestID: requestID,
                actionID: actionID,
                modelID: modelID,
                inputCharacters: inputCharacters,
                outputCharacters: outputCharacters,
                milliseconds: stages,
                contentChunks: contentChunks,
                upstreamHeaderMilliseconds: upstreamHeaderMilliseconds,
                workerPreUpstreamMilliseconds: workerPreUpstreamMilliseconds,
                serverTiming: serverTiming,
                responseContentType: responseContentType,
                cfRay: cfRay,
                cfPlacement: cfPlacement,
                networkTransaction: networkTransaction,
                breakdown: breakdown
            )
        }
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    private static func parseServerTiming(_ header: String?) -> (preUpstream: Double?, upstream: Double?) {
        guard let header, !header.isEmpty else { return (nil, nil) }
        var preUpstream: Double?
        var upstream: Double?
        for entry in header.split(separator: ",") {
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let metricName = parts.first?.lowercased(),
                  let durPart = parts.dropFirst().first(where: { $0.lowercased().hasPrefix("dur=") }),
                  let value = Double(durPart.dropFirst(4)),
                  value.isFinite, value >= 0
            else { continue }
            switch metricName {
            case "preupstream":
                preUpstream = value
            case "upstream":
                upstream = value
            default:
                break
            }
        }
        return (preUpstream, upstream)
    }

    private static func makeBreakdown(
        startedAt: ContinuousClock.Instant,
        stages: [String: Double],
        upstreamHeaderMs: Double?,
        workerPreUpstreamMs: Double?,
        networkTransaction: NetworkTransactionTiming?
    ) -> SegmentBreakdown {
        func delta(_ later: Stage, _ earlier: Stage) -> Double? {
            guard let end = stages[later.rawValue], let start = stages[earlier.rawValue] else { return nil }
            return end - start
        }

        let prepared = stages[Stage.requestPrepared.rawValue]
        let headers = stages[Stage.responseHeaders.rawValue]
        let transitResidualMs: Double? = if let prepared, let headers, upstreamHeaderMs != nil || workerPreUpstreamMs != nil {
            max((headers - prepared) - (workerPreUpstreamMs ?? 0) - (upstreamHeaderMs ?? 0), 0)
        } else {
            nil
        }

        let launchToSubmitMs = max(milliseconds(from: processStartedAt, to: startedAt), 0)
        let firstVisible = stages[Stage.firstUIFrame.rawValue]
            ?? stages[Stage.firstUIUpdate.rawValue]
            ?? stages[Stage.firstUsefulContent.rawValue]
        let totalEndToEnd = stages[Stage.finalUIFrame.rawValue]
            ?? stages[Stage.diffComputed.rawValue]
            ?? stages[Stage.markdownParsed.rawValue]
            ?? stages[Stage.resultApplied.rawValue]

        return SegmentBreakdown(
            launchToSubmitMs: launchToSubmitMs,
            languageResolutionMs: stages[Stage.languageResolved.rawValue],
            requestPreparationMs: prepared,
            dnsLookupMs: networkTransaction?.dnsLookupMs,
            tcpConnectMs: networkTransaction?.tcpConnectMs,
            tlsHandshakeMs: networkTransaction?.tlsHandshakeMs,
            isReusedConnection: networkTransaction?.isReusedConnection,
            workerPreUpstreamMs: workerPreUpstreamMs,
            upstreamHeaderTTFBMs: upstreamHeaderMs,
            clientToWorkerTransitResidualMs: transitResidualMs,
            headersToFirstContentMs: delta(.firstContent, .responseHeaders),
            jsonPrefixToFirstUsefulContentMs: delta(.firstUsefulContent, .firstContent),
            firstContentToFirstUIUpdateMs: delta(.firstUIUpdate, .firstUsefulContent),
            firstUIUpdateToFirstFrameMs: delta(.firstUIFrame, .firstUIUpdate),
            timeToFirstVisibleTextMs: firstVisible,
            streamingGenerationMs: delta(.lastContent, .firstUsefulContent),
            streamTailToFinishMs: delta(.streamFinished, .lastContent),
            finalParseAndApplyMs: delta(.resultApplied, .streamFinished),
            diffComputeMs: delta(.diffComputed, .resultApplied),
            markdownParseMs: delta(.markdownParsed, .resultApplied),
            resultApplyToFinalFrameMs: delta(.finalUIFrame, .resultApplied),
            totalEndToEndMs: totalEndToEnd
        )
    }
}
