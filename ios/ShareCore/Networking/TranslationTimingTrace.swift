import Foundation

/// Monotonic, request-scoped milestones. Content chunks are not tokenizer tokens.
public final class TranslationTimingTrace: @unchecked Sendable {
    public enum Stage: String, Sendable {
        case requestPrepared, responseHeaders, firstContent, firstUsefulContent, lastContent, streamFinished
        case firstUIUpdate, resultApplied, firstUIFrame, finalUIFrame
    }

    public struct Snapshot: Codable, Sendable {
        public let requestID: String
        public let milliseconds: [String: Double]
        public let contentChunks: Int
        public let upstreamHeaderMilliseconds: Double?
        public let serverTiming: String?
        public let responseContentType: String?
    }

    public let requestID = UUID().uuidString
    private let startedAt: ContinuousClock.Instant
    private let lock = NSLock()
    private var stages: [String: Double] = [:]
    private var contentChunks = 0
    private var upstreamHeaderMilliseconds: Double?
    private var serverTiming: String?
    private var responseContentType: String?

    public init(startedAt: ContinuousClock.Instant = .now) {
        self.startedAt = startedAt
    }

    public func mark(_ stage: Stage, at instant: ContinuousClock.Instant = .now) {
        let duration = startedAt.duration(to: instant).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        lock.withLock {
            if stage == .lastContent {
                stages[stage.rawValue] = milliseconds
            } else if stages[stage.rawValue] == nil {
                stages[stage.rawValue] = milliseconds
            }
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
        lock.withLock {
            upstreamHeaderMilliseconds = response.value(forHTTPHeaderField: "X-Upstream-TTFB")
                .flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            serverTiming = response.value(forHTTPHeaderField: "Server-Timing")
            responseContentType = response.value(forHTTPHeaderField: "Content-Type")
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
            Snapshot(
                requestID: requestID, milliseconds: stages, contentChunks: contentChunks,
                upstreamHeaderMilliseconds: upstreamHeaderMilliseconds,
                serverTiming: serverTiming, responseContentType: responseContentType
            )
        }
    }
}
