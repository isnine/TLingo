#if DEBUG && os(iOS)
import SwiftUI
import UIKit

@MainActor
public struct DebugStreamingRenderView: View {
    public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-TLingoDebugRenderStreams")

    @StateObject private var viewModel = HomeViewModel(
        configurationStore: AppConfigurationStore(snapshot: true),
        supportsAppleTranslate: false,
        initialModels: []
    )
    @Environment(\.scenePhase) private var scenePhase
    @State private var runID = UUID()
    @State private var isRunning = true
    @State private var interrupted = false
    @State private var summary = "Preparing local streams…"

    private let config = RenderReplayConfiguration()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(config.streamCount) local streams · \(config.expanded ? "Expanded" : "Collapsed")")
                        .font(.headline)
                    Text(verbatim: summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Replay") { runID = UUID() }
                    .disabled(isRunning)
            }
            .padding()
            Divider()
            HomeView(viewModel: viewModel, showsOnlyResults: true, initiallyExpandsResults: config.expanded)
                .id(runID)
                .allowsHitTesting(!isRunning)
        }
        .task(id: runID) { await replay() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, isRunning { interrupted = true }
        }
    }

    private func replay() async {
        isRunning = true
        interrupted = false
        summary = "Replaying \(config.fixture.rawValue) · no server"
        defer { isRunning = false }

        let reportURL = URL.documentsDirectory.appendingPathComponent("debug-streaming-render.json")
        try? FileManager.default.removeItem(at: reportURL)
        defer { viewModel.requestGenerationTracker.cancel() }

        let models = (1 ... config.streamCount).map { number in
            ModelConfig(id: "render-replay-\(number)", displayName: "Local #\(number)")
        }
        let start = Date()
        viewModel.modelRuns = models.map { .init(model: $0, status: .running(start: start)) }
        let context = HomeViewModel.RequestContext(
            generation: runID,
            historyRequestID: runID,
            text: "Offline rendering benchmark",
            images: [],
            action: BuiltInActionCatalog.sentenceTranslateAction,
            languages: .init(target: .simplifiedChinese, sourceCode: "en"),
            showsDiff: false,
            refreshEntitlement: false,
            cachedIsPremium: false
        )
        let runTokens = Dictionary(uniqueKeysWithValues: models.map { ($0.id, UUID()) })
        viewModel.requestGenerationTracker.begin(generation: context.generation, runTokens: runTokens)
        let coalescers = viewModel.makeStreamingCoalescers(models, context: context, runTokens: runTokens)
        let streams = models.compactMap { coalescers[$0.id] }
        defer { streams.forEach { $0.cancel() } }

        do {
            let recorder = RenderFrameRecorder()
            defer { recorder.stop() }
            try await Task.sleep(for: .milliseconds(350))
            recorder.start()
            try await Task.sleep(for: .milliseconds(150))

            let worker = Task.detached(priority: .userInitiated) { try await config.feed(streams) }
            let replay = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let finishRequested = replay.lastBatch
            for (model, update) in zip(models, replay.finals) {
                guard let runToken = runTokens[model.id] else { continue }
                let result = switch update {
                case let .text(text):
                    ModelExecutionResult(modelID: model.id, duration: replay.duration, response: .success(text))
                case let .sentencePairs(pairs):
                    ModelExecutionResult(
                        modelID: model.id, duration: replay.duration, response: .success(""), sentencePairs: pairs
                    )
                }
                viewModel.finishStreamingRun(result, coalescer: coalescers[model.id], context: context, runToken: runToken)
            }
            try await Task.sleep(for: .milliseconds(500))
            let end = CACurrentMediaTime()
            recorder.stop()
            guard !interrupted else {
                summary = "Interrupted · keep the app in the foreground and replay"
                return
            }

            let burstEnd = replay.firstBatch + 0.25
            let burst = recorder.metrics(from: replay.firstBatch, to: burstEnd)
            let streaming = recorder.metrics(from: burstEnd, to: finishRequested)
            let completion = recorder.metrics(from: finishRequested, to: end)
            let report = RenderReplayReport(
                streamCount: config.streamCount,
                expanded: config.expanded,
                fixture: config.fixture,
                batches: config.batchCount,
                intervalMs: config.intervalMs,
                firstBatchSpreadMs: replay.firstBatchSpreadMs,
                burst: burst,
                streaming: streaming,
                completion: completion
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            if let p95 = streaming.p95Ms {
                summary = "Streaming P95 \(p95.formatted(.number.precision(.fractionLength(1)))) ms"
                    + " · \(streaming.estimatedMissedFrames) missed"
            } else {
                summary = "No display callbacks during streaming"
            }
        } catch is CancellationError {
            return
        } catch {
            summary = error.localizedDescription
        }
    }
}

private struct RenderReplayConfiguration: Sendable {
    enum Fixture: String, Codable, Sendable {
        case text
        case markdown
        case pairs
    }

    let streamCount: Int
    let expanded: Bool
    let fixture: Fixture
    let batchCount = 180
    let intervalMs = 20

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        streamCount = min(30, max(1, value(after: "-TLingoDebugRenderStreams").flatMap(Int.init) ?? 30))
        expanded = arguments.contains("-TLingoDebugRenderExpanded")
        fixture = value(after: "-TLingoDebugRenderFixture").flatMap(Fixture.init(rawValue:)) ?? .text
    }

    struct Replay: Sendable {
        let firstBatch: CFTimeInterval
        let lastBatch: CFTimeInterval
        let firstBatchSpreadMs: Double
        let finals: [StreamingUpdate]

        var duration: TimeInterval { lastBatch - firstBatch }
    }

    func feed(_ streams: [StreamingUpdateCoalescer]) async throws -> Replay {
        let updates = streams.indices.map(snapshots(for:))
        let clock = ContinuousClock()
        var deadline = clock.now
        var firstBatch: CFTimeInterval = 0
        var lastBatch: CFTimeInterval = 0
        var firstBatchSpreadMs = 0.0
        for batch in 0 ..< batchCount {
            try Task.checkCancellation()
            let begin = CACurrentMediaTime()
            for (stream, snapshots) in zip(streams, updates) {
                stream.append(snapshots[batch])
            }
            lastBatch = CACurrentMediaTime()
            if batch == 0 {
                firstBatch = begin
                firstBatchSpreadMs = (lastBatch - begin) * 1000
            }
            if batch + 1 < batchCount {
                deadline = deadline.advanced(by: .milliseconds(intervalMs))
                try await clock.sleep(until: deadline)
            }
        }
        return Replay(
            firstBatch: firstBatch,
            lastBatch: lastBatch,
            firstBatchSpreadMs: firstBatchSpreadMs,
            finals: updates.compactMap(\.last)
        )
    }

    private func snapshots(for stream: Int) -> [StreamingUpdate] {
        let paragraphs = [
            "我们正在准备下一次更新，希望文字在生成时就能自然呈现。\n\n",
            "结果陆续到达时，已显示的段落应该保持稳定，方便继续阅读。\n\n",
            "即使同时比较多种译法，也能快速找到更适合当前语境的表达。\n\n",
        ]
        var text = "模拟结果 \(stream + 1)\n\n"
        var pairs: [SentencePair] = []
        return (0 ..< batchCount).map { batch in
            let paragraph = paragraphs[(batch / 3) % paragraphs.count]
            let piece = switch batch % 3 {
            case 0: String(paragraph.prefix(10))
            case 1: String(paragraph.dropFirst(10).prefix(10))
            default: String(paragraph.dropFirst(20))
            }
            switch fixture {
            case .text:
                text += piece
                return .text(text)
            case .markdown:
                if batch % 3 == 0 { text += batch % 12 == 0 ? "## " : "- " }
                text += piece
                return .text(text)
            case .pairs:
                if batch % 3 == 0 {
                    pairs.append(.init(
                        original: "Example \(batch / 3 + 1): Keep the result readable while the translation arrives.",
                        translation: paragraph.trimmingCharacters(in: .newlines)
                    ))
                }
                return .sentencePairs(pairs)
            }
        }
    }
}

private struct RenderReplayReport: Encodable {
    let streamCount: Int
    let expanded: Bool
    let fixture: RenderReplayConfiguration.Fixture
    let batches: Int
    let intervalMs: Int
    let firstBatchSpreadMs: Double
    let burst: RenderFrameRecorder.Metrics
    let streaming: RenderFrameRecorder.Metrics
    let completion: RenderFrameRecorder.Metrics
}

@MainActor
private final class RenderFrameRecorder: NSObject {
    struct Metrics: Encodable {
        let samples: Int
        let p95Ms: Double?
        let maxMs: Double?
        let estimatedMissedFrames: Int
    }

    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var samples: [(timestamp: CFTimeInterval, interval: CFTimeInterval)] = []
    private let framesPerSecond = 60.0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        if let previous, timestamp > previous {
            samples.append((timestamp, timestamp - previous))
        }
        previous = timestamp
    }

    func metrics(from start: CFTimeInterval, to end: CFTimeInterval) -> Metrics {
        let intervals = samples
            .filter { $0.timestamp >= start && $0.timestamp < end }
            .map(\.interval)
            .sorted()
        let p95 = intervals.isEmpty ? nil : intervals[Int(ceil(Double(intervals.count) * 0.95)) - 1]
        return Metrics(
            samples: intervals.count,
            p95Ms: p95.map { $0 * 1000 },
            maxMs: intervals.last.map { $0 * 1000 },
            estimatedMissedFrames: intervals.reduce(0) { count, interval in
                count + max(0, Int((interval * framesPerSecond).rounded()) - 1)
            }
        )
    }
}
#endif
