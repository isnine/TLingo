#if (DEBUG || TLINGO_LOCAL_DEVICE_BENCHMARK) && os(iOS)
    import AVFoundation
    import SwiftUI
    import UIKit

    @MainActor
    public struct DebugDevicePerformanceView: View {
        public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-TLingoDebugDevicePerf")

        @Environment(\.scenePhase) private var scenePhase
        @State private var summary = "Preparing benchmark…"
        @State private var interrupted = false

        public init() {}

        public var body: some View {
            VStack(spacing: 12) {
                Text("Device Performance").font(.headline)
                Text(verbatim: summary).font(.body.monospacedDigit())
            }
            .padding()
            .task { await run() }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if oldPhase == .active, newPhase != .active {
                    interrupted = true
                }
            }
        }

        private func run() async {
            let arguments = ProcessInfo.processInfo.arguments
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            let url = URL.documentsDirectory.appendingPathComponent("debug-device-performance.json")
            try? FileManager.default.removeItem(at: url)
            let scenario = value(after: "-TLingoDebugDevicePerf") ?? ""
            let start = CACurrentMediaTime()
            let elapsed = TranslationTimingTrace.processStartedAt.duration(to: .now).components
            var report = Report(
                scenario: scenario, label: value(after: "-TLingoDebugPerfLabel"),
                debugLaunchToTaskMs: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                thermalStateAtStart: ProcessInfo.processInfo.thermalState.rawValue
            )
            do {
                summary = "Running \(scenario)…"
                switch scenario {
                case "ocr":
                    report.ocr = try await Self.runOCR()
                case "history":
                    let count = min(20000, max(100, value(after: "-TLingoDebugHistoryCount").flatMap(Int.init) ?? 5000))
                    report.history = try Self.runHistory(count: count)
                case "history-audio":
                    let bucketCount = min(4096, max(1, value(after: "-TLingoDebugWaveformBuckets").flatMap(Int.init) ?? 256))
                    report.historyAudio = try await Self.runHistoryAudio(bucketCount: bucketCount)
                case "realtime", "realtime-lifecycle":
                    #if arch(arm64) && canImport(FluidAudio)
                        let model = value(after: "-TLingoDebugRealtimeModel") ?? "nemotron-streaming-1120ms"
                        let seconds = min(3600, max(1, value(after: "-TLingoDebugAudioSeconds").flatMap(Int.init) ?? 60))
                        let allowsDownload = arguments.contains("-TLingoDebugAllowModelDownload")
                        let worker = Task.detached(priority: .userInitiated) { () async throws
                            -> (DeviceRealtimeBenchmark.Report?, DeviceRealtimeBenchmark.LifecycleReport?) in
                            if scenario == "realtime-lifecycle" {
                                let lifecycle = try await DeviceRealtimeBenchmark.runLifecycle(
                                    modelID: model, seconds: seconds, allowsDownload: allowsDownload
                                )
                                return (nil, lifecycle)
                            }
                            let realtime = try await DeviceRealtimeBenchmark.run(
                                modelID: model, seconds: seconds, allowsDownload: allowsDownload
                            )
                            return (realtime, nil)
                        }
                        (report.realtime, report.realtimeLifecycle) = try await withTaskCancellationHandler {
                            try await worker.value
                        } onCancel: {
                            worker.cancel()
                        }
                    #else
                        throw DevicePerformanceError("FluidAudio is unavailable on this build.")
                    #endif
                default:
                    throw DevicePerformanceError("Choose ocr, history, history-audio, realtime, or realtime-lifecycle.")
                }
                summary = interrupted ? "Interrupted · discard this run" : "Complete · JSON report saved"
            } catch {
                report.error = error.localizedDescription
                summary = error.localizedDescription
            }
            report.interrupted = interrupted
            report.wallMs = (CACurrentMediaTime() - start) * 1000
            report.thermalStateAtEnd = ProcessInfo.processInfo.thermalState.rawValue
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(report).write(to: url, options: .atomic)
            } catch {
                summary = error.localizedDescription
            }
        }

        private struct Report: Encodable {
            let scenario: String
            let label: String?
            let debugLaunchToTaskMs: Double
            let thermalStateAtStart: Int
            var thermalStateAtEnd: Int?
            var wallMs: Double?
            var interrupted = false
            var error: String?
            var ocr: OCRReport?
            var history: HistoryReport?
            var historyAudio: HistoryAudioReport?
            #if arch(arm64) && canImport(FluidAudio)
                var realtime: DeviceRealtimeBenchmark.Report?
                var realtimeLifecycle: DeviceRealtimeBenchmark.LifecycleReport?
            #endif
        }

        private struct OCRReport: Encodable {
            let pixelsWide: Int
            let pixelsHigh: Int
            let fixtureRows: Int
            let recognitionMs: [Double]
            let recognizedCharacters: [Int]
        }

        private static func runOCR() async throws -> OCRReport {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let size = CGSize(width: 3024, height: 4032)
            let rowCount = 56
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 44),
                    .foregroundColor: UIColor.black,
                ]
                for row in 1 ... rowCount {
                    let english = "\(row). The next meeting will include a review of the revised release schedule."
                    let chinese = "\(row). 请在会议前确认发布时间和测试进度。我们会一起检查本次更新。"
                    (row.isMultiple(of: 3) ? chinese : english)
                        .draw(at: CGPoint(x: 120, y: 120 + row * 64), withAttributes: attributes)
                }
            }
            guard let input = image.cgImage else { throw DevicePerformanceError("Could not create OCR fixture.") }
            var timings: [Double] = []
            var counts: [Int] = []
            for _ in 0 ..< 5 {
                try Task.checkCancellation()
                let start = CACurrentMediaTime()
                let text = try await OCRTextRecognizer.recognizeText(in: input)
                timings.append((CACurrentMediaTime() - start) * 1000)
                counts.append(text.count)
            }
            guard counts.allSatisfy({ $0 > 0 }) else { throw DevicePerformanceError("OCR returned no text.") }
            return OCRReport(
                pixelsWide: input.width, pixelsHigh: input.height, fixtureRows: rowCount,
                recognitionMs: timings, recognizedCharacters: counts
            )
        }

        private struct HistoryReport: Encodable {
            struct Page: Encodable {
                let offset: Int
                let count: Int
                let fetchMs: Double
                let readPayloadMs: Double
                let characters: Int
            }

            let records: Int
            let seedMs: Double
            let reopenMs: Double
            let pages: [Page]
        }

        private static func runHistory(count: Int) throws -> HistoryReport {
            let identifier = "TLingo.DebugHistory.\(UUID().uuidString)"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
            let storeURL = directory.appendingPathComponent("history.store")
            guard let defaults = UserDefaults(suiteName: identifier) else {
                throw DevicePerformanceError("Could not create isolated history defaults.")
            }
            defer {
                defaults.removePersistentDomain(forName: identifier)
                try? FileManager.default.removeItem(at: directory)
            }
            let seedStart = CACurrentMediaTime()
            try autoreleasepool {
                let store = TranslationHistoryService(storeURL: storeURL, userDefaults: defaults, pruneAudioRecordings: false)
                let source = String(repeating: "Please review the updated notes before tomorrow's meeting. ", count: 8)
                let result = String(repeating: "请在明天开会前查看更新后的笔记。", count: 16)
                for index in 0 ..< count {
                    try Task.checkCancellation()
                    try store.saveThrowing(
                        requestID: UUID(), sourceText: "\(index) \(source)", resultText: result,
                        actionName: "Translate", targetLanguage: "zh-Hans",
                        modelID: "fixture", modelDisplayName: "Fixture", duration: 1
                    )
                }
            }
            let seedMs = (CACurrentMediaTime() - seedStart) * 1000
            return try autoreleasepool {
                let reopenStart = CACurrentMediaTime()
                let store = TranslationHistoryService(storeURL: storeURL, userDefaults: defaults, pruneAudioRecordings: false)
                let reopenMs = (CACurrentMediaTime() - reopenStart) * 1000
                let pageSize = 50
                let pages = try [0, pageSize, count / 2, count - pageSize, 0].map { offset in
                    let fetchStart = CACurrentMediaTime()
                    let records = store.fetchTextRecords(offset: offset, limit: pageSize)
                    let fetchMs = (CACurrentMediaTime() - fetchStart) * 1000
                    guard records.count == pageSize else { throw DevicePerformanceError("History fixture page is incomplete.") }
                    let readStart = CACurrentMediaTime()
                    let characters = try records.reduce(0) { total, record in
                        try total + record.sourceText.count + record.decodedModelResults().reduce(0) { $0 + $1.resultText.count }
                    }
                    return HistoryReport.Page(
                        offset: offset, count: records.count, fetchMs: fetchMs,
                        readPayloadMs: (CACurrentMediaTime() - readStart) * 1000, characters: characters
                    )
                }
                return HistoryReport(records: count, seedMs: seedMs, reopenMs: reopenMs, pages: pages)
            }
        }

        private struct HistoryAudioReport: Encodable {
            let audioSeconds: Double
            let segmentCount: Int
            let compositionMs: Double
            let waveformMs: Double
            let waveformBuckets: Int
        }

        private static func runHistoryAudio(bucketCount: Int) async throws -> HistoryAudioReport {
            let fixture = URL.documentsDirectory.appendingPathComponent("debug-realtime-fixture.wav")
            let file = try AVAudioFile(forReading: fixture)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            guard duration >= 10, duration <= 60,
                  let root = RealtimeHistoryAudioStorage.rootURL()
            else {
                throw DevicePerformanceError("Use a 10–60 second WAV fixture and an available app group.")
            }
            let folder = "debug-history-audio-\(UUID().uuidString)"
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("fixture.wav"))
            let segments = (0 ..< Int(3600 / duration)).map { index in
                RealtimeHistoryAudioSegment(
                    relativePath: "\(folder)/fixture.wav",
                    offset: Double(index) * duration,
                    duration: duration,
                    byteCount: 0
                )
            }
            let recording = RealtimeHistoryAudioRecording(
                directoryName: folder, format: "wav", sampleRate: file.fileFormat.sampleRate,
                channelCount: Int(file.fileFormat.channelCount), segments: segments
            )
            let compositionStart = CACurrentMediaTime()
            let composition = try await RealtimeHistoryAudioTimeline.composition(for: recording)
            let compositionMs = (CACurrentMediaTime() - compositionStart) * 1000
            let waveformStart = CACurrentMediaTime()
            let waveform = try await RealtimeHistoryAudioTimeline.waveformLevels(for: recording, bucketCount: bucketCount)
            let waveformMs = (CACurrentMediaTime() - waveformStart) * 1000
            guard waveform.contains(where: { $0 > 0 }) else {
                throw DevicePerformanceError("History audio fixture produced no waveform.")
            }
            let audioSeconds = try await composition.load(.duration).seconds
            return HistoryAudioReport(
                audioSeconds: audioSeconds, segmentCount: segments.count,
                compositionMs: compositionMs, waveformMs: waveformMs, waveformBuckets: waveform.count
            )
        }
    }

    struct DevicePerformanceError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }
#endif
