import Foundation
@testable import ShareCore
import Testing

@Suite("Text translation timing", .serialized)
struct TranslationTimingTests {
    @Test("Header overhead excludes generation and preserves first milestones")
    func headerOverhead() throws {
        let start = ContinuousClock.now
        let trace = TranslationTimingTrace(startedAt: start)
        trace.mark(.requestPrepared, at: start.advanced(by: .milliseconds(100)))
        let url = try #require(URL(string: "https://example.com"))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Upstream-TTFB": "200"]
        ))
        trace.receiveHeaders(response, at: start.advanced(by: .milliseconds(800)))
        trace.mark(.streamFinished, at: start.advanced(by: .seconds(20)))
        #expect(trace.clientHeaderOverhead == 0.5)
        trace.mark(.firstContent, at: start.advanced(by: .milliseconds(500)))
        trace.mark(.firstContent, at: start.advanced(by: .milliseconds(600)))
        trace.mark(.lastContent, at: start.advanced(by: .milliseconds(500)))
        trace.mark(.lastContent, at: start.advanced(by: .milliseconds(900)))
        #expect(trace.snapshot().milliseconds["firstContent"] == 500)
        #expect(trace.snapshot().milliseconds["lastContent"] == 900)
    }

    @Test("Invalid upstream duration does not produce a network estimate")
    func invalidHeaders() throws {
        for value in ["nan", "inf", "-1", "invalid"] {
            let trace = TranslationTimingTrace()
            let url = try #require(URL(string: "https://example.com"))
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["X-Upstream-TTFB": value]
            ))
            trace.receiveHeaders(response)
            #expect(trace.snapshot().upstreamHeaderMilliseconds == nil)
            #expect(trace.clientHeaderOverhead == nil)
        }
    }

    @Test("Network debug reports preserve correlated timing across Codable round trips")
    func debugTimingReport() throws {
        let trace = TranslationTimingTrace()
        trace.mark(.requestPrepared)
        trace.receiveContent()
        trace.mark(.streamFinished)
        trace.mark(.resultApplied)
        let record = NetworkRequestRecord(
            source: .app, httpMethod: "POST", url: "https://example.com/model/chat/completions",
            requestHeaders: ["X-Request-ID": trace.requestID],
            statusCode: 200, translationTiming: trace.snapshot()
        )
        let restored = try JSONDecoder().decode(NetworkRequestRecord.self, from: JSONEncoder().encode(record))
        let report = restored.sanitizedForDebug().debugReport
        #expect(report.contains("Correlation ID: \(trace.requestID)"))
        #expect(report.contains("firstContent:"))
        #expect(report.contains("resultApplied:"))
        #expect(report.contains("not tokenizer tokens"))
        var legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacyJSON.removeValue(forKey: "translationTiming")
        let legacy = try JSONDecoder().decode(
            NetworkRequestRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        #expect(legacy.translationTiming == nil)
    }

    private final class CapturedValues: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) {
            lock.withLock { storage.append(value) }
        }

        var values: [String] {
            lock.withLock { storage }
        }
    }

    @Test("Empty structured prefixes cannot delay first useful output")
    func firstUsefulOutput() {
        let captured = CapturedValues()
        let coalescer = StreamingUpdateCoalescer { update in
            if case let .text(text) = update {
                captured.append(text)
            }
        }
        coalescer.append(.text(""))
        coalescer.append(.sentencePairs([]))
        coalescer.append(.text("Hello"))
        #expect(captured.values == ["Hello"])
        coalescer.cancel()
    }

    @Test("Latest snapshot is delivered even when the network pauses")
    func latestSnapshot() async throws {
        let captured = CapturedValues()
        let coalescer = StreamingUpdateCoalescer(interval: .milliseconds(20)) { update in
            if case let .text(text) = update {
                captured.append(text)
            }
        }
        coalescer.append(.text("A"))
        coalescer.append(.text("AB"))
        coalescer.append(.text("ABC"))
        for _ in 0 ..< 25 {
            if captured.values == ["A", "ABC"] {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(captured.values == ["A", "ABC"])
        coalescer.cancel()
    }

    @Test("Completion flushes the latest output; cancellation cannot publish stale text")
    func flushAndCancel() async throws {
        let captured = CapturedValues()
        let coalescer = StreamingUpdateCoalescer { update in
            if case let .text(text) = update {
                captured.append(text)
            }
        }
        coalescer.append(.text("A"))
        coalescer.append(.text("Final"))
        coalescer.flush()
        #expect(captured.values == ["A", "Final"])
        coalescer.append(.text("Stale"))
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(captured.values == ["A", "Final"])
    }
}
