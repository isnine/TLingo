#if os(macOS) && arch(arm64) && canImport(FluidAudio)
    import AVFoundation
    import Darwin
    import Foundation
    @testable import ShareCore
    import Testing

    /// Opt-in long-session benchmark: streams a long audio file through the production realtime recognizer
    /// faster than realtime and records memory, processing speed and transcript growth per audio minute.
    @Suite("Realtime long session benchmark")
    struct RealtimeLongSessionBenchmarkTests {
        private static let chunkDuration: TimeInterval = 0.32
        /// Keeps the recognizer's queue well under its 15 s backlog limit.
        private static let maximumLag: TimeInterval = 5

        private static let models: [RecognitionModelDescriptor] = [
            .parakeetEOU320, .parakeetEOU1280,
            .nemotronStreaming560, .nemotronStreaming1120, .nemotronStreaming2240,
            .nemotronMultilingual2240,
        ]

        @Test("Records memory and speed per audio minute")
        func recordsLongSessionMetrics() async throws {
            guard Self.environmentValue("RUN_REALTIME_LONG_SESSION_BENCHMARK") == "1" else { return }
            let inputURL = try URL(fileURLWithPath: #require(Self.environmentValue("REALTIME_AUDIO_FIXTURE_PATH")))
            let outputURL = try URL(
                fileURLWithPath: #require(Self.environmentValue("REALTIME_AUDIO_BENCHMARK_OUTPUT_DIR")),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let modelIDs = (Self.environmentValue("REALTIME_AUDIO_MODEL_IDS") ?? RecognitionModelDescriptor.nemotronStreaming560
                .id)
                .split(separator: ",").map(String.init)

            for modelID in modelIDs {
                let model = try #require(Self.models.first { $0.id == modelID })
                if !(await RecognitionModelStore.shared.isModelCached(model)) {
                    _ = try await RecognitionModelStore.shared.downloadModel(model)
                }
                let rows = try await run(model: model, inputURL: inputURL)
                let header = "audio_min\twall_s\trtf\tfootprint_mb\tstable_segments\tvisible_chars\tpending_chars"
                try ([header] + rows).joined(separator: "\n").appending("\n")
                    .write(to: outputURL.appendingPathComponent("\(model.id).tsv"), atomically: true, encoding: .utf8)
            }
        }

        /// Replays a cumulative partial stream (as non-EOU engines emit it) through the transcript state and the
        /// main-actor presentation path, timing each stage per update as the transcript grows.
        @Test("Records per-update cost as the transcript grows")
        func recordsPerUpdateCost() throws {
            guard Self.environmentValue("RUN_REALTIME_LONG_SESSION_BENCHMARK") == "1" else { return }
            let outputURL = try URL(
                fileURLWithPath: #require(Self.environmentValue("REALTIME_AUDIO_BENCHMARK_OUTPUT_DIR")),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let sentenceCount = Int(Self.environmentValue("REALTIME_SYNTHETIC_SENTENCES") ?? "") ?? 750
            let sentences = (0 ..< sentenceCount).map { index in
                "Speaker note \(index) covers the release plan and the next review before the deadline."
            }

            var transcriptState = RealtimeStreamingTranscriptState()
            var accumulator = RealtimeTranscriptAccumulator()
            var translationState = RealtimeIncrementalTranslationState()
            var cumulative: [Substring] = []
            var totals = (state: 0.0, snapshot: 0.0, presentation: 0.0, schedule: 0.0, updates: 0)
            var rows = ["sentences\tstable_segments\tpartial_words\tstate_ms\tsnapshot_ms\tpresentation_ms\tschedule_ms"]
            let clock = ContinuousClock()
            func milliseconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            }

            for (index, sentence) in sentences.enumerated() {
                let words = sentence.split(separator: " ")
                // Three growing partials per sentence, the last one completing it.
                for step in [words.count / 3, 2 * words.count / 3, words.count] {
                    let partial = (cumulative + words.prefix(step)).joined(separator: " ")
                    let offset = TimeInterval(index) * 3.2 + TimeInterval(step) * 0.3

                    var start = clock.now
                    transcriptState.updatePartial(partial, audioOffset: offset)
                    totals.state += milliseconds(start.duration(to: clock.now))

                    start = clock.now
                    let result = RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                        stableSegments: transcriptState.stableSegments,
                        pendingSegment: transcriptState.pendingSegment,
                        audioOffset: offset
                    ))
                    totals.snapshot += milliseconds(start.duration(to: clock.now))

                    start = clock.now
                    _ = accumulator.append(result, afterLongSilence: false)
                    translationState.updateSources(from: accumulator)
                    totals.presentation += milliseconds(start.duration(to: clock.now))

                    // Mirrors RealtimeSessionStore.scheduleTranslation with translations landing immediately.
                    start = clock.now
                    translationState.updateCachedSentencePairs(
                        provider: .appleTranslator,
                        sourceLanguage: .englishUnitedStates,
                        targetLanguage: .simplifiedChinese
                    )
                    let requests = translationState.makeFinalTranslationRequests(
                        provider: .appleTranslator,
                        sourceLanguage: .englishUnitedStates,
                        source: SourceLanguageOption.englishUnitedStates.localeLanguage,
                        targetLanguage: .simplifiedChinese
                    )
                    for request in requests {
                        _ = translationState.applyFinalTranslationSuccess(
                            ModelExecutionResult(
                                modelID: "benchmark",
                                duration: 0,
                                response: .success("译文 " + request.translationText)
                            ),
                            request: request
                        )
                    }
                    totals.schedule += milliseconds(start.duration(to: clock.now))
                    totals.updates += 1
                }
                cumulative += words
                if (index + 1) % 50 == 0 {
                    let count = Double(totals.updates)
                    rows.append([
                        String(index + 1),
                        String(transcriptState.stableSegments.count),
                        String(cumulative.count),
                        String(format: "%.3f", totals.state / count),
                        String(format: "%.3f", totals.snapshot / count),
                        String(format: "%.3f", totals.presentation / count),
                        String(format: "%.3f", totals.schedule / count),
                    ].joined(separator: "\t"))
                    totals = (0, 0, 0, 0, 0)
                }
            }
            try rows.joined(separator: "\n").appending("\n")
                .write(to: outputURL.appendingPathComponent("per-update-cost.tsv"), atomically: true, encoding: .utf8)
        }

        private func run(model: RecognitionModelDescriptor, inputURL: URL) async throws -> [String] {
            let file = try AVAudioFile(forReading: inputURL, commonFormat: .pcmFormatInt16, interleaved: false)
            #expect(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
            let collector = ResultCollector()
            let recognizer = RealtimeFluidAudioRecognizer(delegate: collector)
            try await recognizer.start(model: model, locale: Locale(identifier: "en-US"), sessionID: UUID())

            let chunkFrames = AVAudioFrameCount(Self.chunkDuration * 16000)
            var rows: [String] = []
            var nextMinute = 1
            let startedAt = Date()
            var minuteStartedAt = startedAt
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { break }
                try file.read(into: buffer, frameCount: min(chunkFrames, AVAudioFrameCount(file.length - file.framePosition)))
                guard buffer.frameLength > 0 else { break }
                recognizer.append(buffer)
                while true {
                    let diagnostics = recognizer.diagnostics
                    guard diagnostics.inputAudioOffset - diagnostics.processedAudioOffset > Self.maximumLag else { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let processed = recognizer.diagnostics.processedAudioOffset
                if processed >= Double(nextMinute * 60) {
                    let now = Date()
                    let wall = now.timeIntervalSince(minuteStartedAt)
                    rows.append(row(minute: nextMinute, wall: wall, collector: collector))
                    minuteStartedAt = now
                    nextMinute += 1
                }
            }
            await recognizer.stop()
            rows.append(row(minute: -1, wall: Date().timeIntervalSince(startedAt), collector: collector))
            return rows
        }

        private func row(minute: Int, wall: TimeInterval, collector: ResultCollector) -> String {
            let snapshot = collector.latest
            return [
                minute < 0 ? "final" : String(minute),
                String(format: "%.1f", wall),
                minute < 0 ? "-" : String(format: "%.3f", wall / 60),
                String(format: "%.0f", Self.physFootprintMB()),
                String(snapshot?.stableSegments.count ?? 0),
                String(snapshot?.visibleText.count ?? 0),
                String(snapshot?.pendingSegment?.text.count ?? 0),
            ].joined(separator: "\t")
        }

        private static func physFootprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }

        private static func environmentValue(_ key: String) -> String? {
            let environment = ProcessInfo.processInfo.environment
            return environment[key] ?? environment["TEST_RUNNER_\(key)"]
        }
    }

    private final class ResultCollector: RealtimeFluidAudioRecognizerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var latestSnapshot: RealtimeRecognitionSnapshot?

        var latest: RealtimeRecognitionSnapshot? {
            lock.withLock { latestSnapshot }
        }

        func realtimeFluidAudioRecognizer(
            _: RealtimeFluidAudioRecognizer,
            sessionID _: UUID,
            didRecognize result: RealtimeRecognitionResult
        ) {
            lock.withLock { latestSnapshot = result.snapshot }
        }

        func realtimeFluidAudioRecognizer(_: RealtimeFluidAudioRecognizer, sessionID _: UUID, didFail error: Error) {
            Issue.record(error)
        }
    }
#endif
