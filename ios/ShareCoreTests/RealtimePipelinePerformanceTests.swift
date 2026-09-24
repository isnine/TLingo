#if os(macOS) && arch(arm64) && canImport(FluidAudio)
    import AVFoundation
    import FluidAudio
    import Testing

    @testable import ShareCore

    @Suite("Realtime pipeline performance")
    struct RealtimePipelinePerformanceTests {
        @Test("Replaces streaming partial text without appending")
        func replacesStreamingPartialText() {
            var state = RealtimeStreamingTranscriptState()

            let firstUpdate = state.updatePartial("First draft", audioOffset: 1)
            #expect(firstUpdate)
            let pendingID = state.pendingSegment?.id
            let secondUpdate = state.updatePartial("Revised words", audioOffset: 1.2)
            #expect(secondUpdate)
            #expect(state.pendingText == "Revised words")
            #expect(state.pendingSegment?.id == pendingID)
            #expect(state.stableSegments.isEmpty)
        }

        @Test("Commits complete sentences and keeps the unfinished suffix pending")
        func commitsAtSentenceTerminators() {
            var state = RealtimeStreamingTranscriptState()
            state.updatePartial("First sentence", audioOffset: 1)
            let pendingID = state.pendingSegment?.id

            let update = state.updatePartial("First sentence. Second sentence", audioOffset: 2)
            #expect(update)
            #expect(state.stableSegments.count == 1)
            #expect(state.stableSegments.first?.id == pendingID)
            #expect(state.stableSegments.first?.text == "First sentence.")
            #expect(state.pendingText == "Second sentence")
        }

        @Test("Does not duplicate punctuation segments from cumulative partials")
        func doesNotDuplicateCompletedSentences() {
            var state = RealtimeStreamingTranscriptState()

            let firstUpdate = state.updatePartial("First sentence.", audioOffset: 1)
            let secondUpdate = state.updatePartial("First sentence. Second sentence.", audioOffset: 2)
            #expect(firstUpdate)
            #expect(secondUpdate)
            #expect(state.stableSegments.map(\.text) == ["First sentence.", "Second sentence."])
        }

        @Test("Uses a likely sentence start after twenty words")
        func commitsAtLikelySentenceStart() {
            var state = RealtimeStreamingTranscriptState()
            let firstSentence = (1 ... 22).map { "word\($0)" }
            let words = firstSentence + ["I", "started", "another", "thought"]

            let update = state.updatePartial(words.joined(separator: " "), audioOffset: 3)

            #expect(update)
            #expect(state.stableSegments.first?.text == firstSentence.joined(separator: " "))
            #expect(state.stableSegments.first?.boundaryReason == .lengthFallback)
            #expect(state.pendingText == "I started another thought")
        }

        @Test("Does not split a pronoun after a connector")
        func doesNotSplitConnectedPronoun() {
            var state = RealtimeStreamingTranscriptState()
            let words = (1 ... 20).map { "word\($0)" } + ["and", "I", "continued"]

            state.updatePartial(words.joined(separator: " "), audioOffset: 3)

            #expect(state.stableSegments.isEmpty)
            #expect(state.pendingText == words.joined(separator: " "))
        }

        @Test("Uses a thirty-six word hard fallback")
        func commitsAtHardWordLimit() {
            var state = RealtimeStreamingTranscriptState()
            let words = (1 ... 40).map { "word\($0)" }

            state.updatePartial(words.joined(separator: " "), audioOffset: 4)

            #expect(state.stableSegments.first?.text == words.prefix(36).joined(separator: " "))
            #expect(state.pendingText == words.suffix(4).joined(separator: " "))
        }

        @Test("Maps TLingo Chinese locale identifiers to Nemotron prompts")
        func mapsNemotronLanguageCodes() {
            #expect(RealtimeFluidAudioLanguageMapper.nemotronLanguageCode("zh-Hans") == "zh-CN")
            #expect(RealtimeFluidAudioLanguageMapper.nemotronLanguageCode("zh-Hant") == "zh-TW")
            #expect(RealtimeFluidAudioLanguageMapper.nemotronLanguageCode("ja") == "ja")
        }

        @Test("EOU commit cannot be submitted twice")
        func eouCommitCannotBeSubmittedTwice() {
            var state = RealtimeStreamingTranscriptState()
            state.updatePartial("One utterance", audioOffset: 2)

            let firstCommit = state.commit(boundaryReason: .modelEOU, audioOffset: 2.2)
            let secondCommit = state.commit(boundaryReason: .stableWindow, audioOffset: 3)
            #expect(firstCommit)
            #expect(!secondCommit)
            #expect(state.stableSegments.count == 1)
        }

        @Test(
            "Flushes native streaming models on the realtime fixture",
            .enabled(if: ProcessInfo.processInfo.environment["RUN_REALTIME_STREAMING_BENCHMARK"] == "1")
        )
        func flushesNativeStreamingModels() async throws {
            let fixturePath = try #require(
                ProcessInfo.processInfo.environment["REALTIME_AUDIO_FIXTURE_PATH"]
            )
            let fixtureURL = URL(fileURLWithPath: fixturePath)
            let models: [RecognitionModelDescriptor] = [
                .parakeetEOU320,
                .parakeetEOU1280,
                .nemotronStreaming560,
                .nemotronStreaming1120,
                .nemotronStreaming2240,
                .nemotronMultilingual2240,
            ]
            try FileManager.default.createDirectory(
                at: Self.benchmarkOutputDirectory,
                withIntermediateDirectories: true
            )

            for model in models {
                if !(await RecognitionModelStore.shared.isModelCached(model)) {
                    _ = try await RecognitionModelStore.shared.downloadModel(model)
                }
                let collector = RealtimeFluidAudioBenchmarkCollector()
                let recognizer = RealtimeFluidAudioRecognizer(delegate: collector)
                try await recognizer.start(
                    model: model,
                    locale: Locale(identifier: "en-US"),
                    sessionID: UUID()
                )
                try await Self.forEachAudioBuffer(at: fixtureURL) { buffer in
                    recognizer.append(buffer)
                }
                await recognizer.stop()
                let text = try #require(collector.terminalText, "\(model.title) did not publish terminal text.")
                try text.write(
                    to: Self.benchmarkOutputDirectory.appendingPathComponent("\(model.id)-tlingo.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                #expect(!Self.normalized(text).isEmpty)
                #expect(!Self.containsRepeatedPrefix(text))
            }
        }

        @MainActor
        @Test(
            "Runs three lanes for ten minutes",
            .enabled(if: ProcessInfo.processInfo.environment["RUN_REALTIME_10_MIN_BENCHMARK"] == "1")
        )
        func runsThreeLanesForTenMinutes() async throws {
            let models = [
                RecognitionModelDescriptor.parakeetEOU320,
                RecognitionModelDescriptor.nemotronStreaming1120,
            ]
            for model in models {
                try #require(await RecognitionModelStore.shared.isModelCached(model), "\(model.title) is not cached.")
            }

            let configurations = [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslationRealtime
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.nemotronStreaming1120.id,
                    translationProvider: .appleTranslator
                ),
            ]
            let coordinator = RealtimePipelineCoordinator()
            try await coordinator.start(
                configurations: configurations,
                primaryLaneID: configurations[0].id,
                sourceLanguage: .englishUnitedStates,
                targetLanguage: .englishUnitedStates,
                captionDisplayMode: .bilingual
            )

            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("build/realtime-fixtures/english_realtime_sample_3min_16k.wav")
            let benchmarkSeconds = Int(
                ProcessInfo.processInfo.environment["REALTIME_BENCHMARK_SECONDS"] ?? ""
            ) ?? 600
            let memorySamples = try await Self.feedFixture(
                fixtureURL,
                for: benchmarkSeconds,
                into: coordinator
            )

            let feedEndedOffset = coordinator.audioFanout.currentAudioOffset
            await coordinator.stop()

            let peakBytes = memorySamples.map(\.bytes).max() ?? 0
            let warmupMaxBytes = memorySamples
                .filter { 120 ... 240 ~= $0.audioSecond }
                .map(\.bytes)
                .max() ?? peakBytes
            let tailMaxBytes = memorySamples
                .filter { $0.audioSecond >= 420 }
                .map(\.bytes)
                .max() ?? peakBytes
            let allowedGrowthBytes: UInt64 = 1500 * 1_048_576
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            let latestTrackOffset = coordinator.tracks
                .flatMap(\.segments)
                .map(\.offset)
                .max() ?? 0
            let completedTracks = coordinator.tracks
            let completionLag = max(0, latestTrackOffset - feedEndedOffset)

            print(
                """
                Realtime benchmark complete peakMiB=\(peakBytes / 1_048_576) \
                warmupMiB=\(warmupMaxBytes / 1_048_576) \
                tailMiB=\(tailMaxBytes / 1_048_576) \
                latestTrackOffset=\(latestTrackOffset) \
                feedEndedOffset=\(feedEndedOffset) \
                completionLag=\(completionLag)
                """
            )

            let encounteredCriticalMemoryPressure = coordinator.didEncounterCriticalMemoryPressure
            let encounteredSustainedRecognitionLag = coordinator.didEncounterSustainedRecognitionLag
            #expect(!encounteredCriticalMemoryPressure)
            #expect(peakBytes < physicalMemory * 8 / 10)
            #expect(tailMaxBytes <= warmupMaxBytes + allowedGrowthBytes)
            #expect(completedTracks.count == configurations.count)
            #expect(completedTracks.allSatisfy { !$0.segments.isEmpty })
            #expect(!encounteredSustainedRecognitionLag)
        }

        private static func feedFixture(
            _ fixtureURL: URL,
            for duration: Int,
            into coordinator: RealtimePipelineCoordinator
        ) async throws -> [(audioSecond: Int, bytes: UInt64)] {
            try await Task.detached(priority: .userInitiated) {
                let audioFile = try AVAudioFile(forReading: fixtureURL)
                let chunkFrameCount: AVAudioFrameCount = 1600
                let totalChunkCount = duration * 10
                var samples: [(audioSecond: Int, bytes: UInt64)] = []

                for chunkIndex in 0 ..< totalChunkCount {
                    if audioFile.framePosition >= audioFile.length {
                        audioFile.framePosition = 0
                    }
                    let remainingFrames = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                    let framesToRead = min(chunkFrameCount, remainingFrames)
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: audioFile.processingFormat,
                        frameCapacity: framesToRead
                    ) else {
                        throw RealtimePipelinePerformanceError.audioBufferAllocationFailed
                    }
                    try audioFile.read(into: buffer, frameCount: framesToRead)
                    coordinator.append(buffer)

                    if chunkIndex % 100 == 0,
                       let residentBytes = SystemInfo.currentResidentMemoryBytes()
                    {
                        samples.append((chunkIndex / 10, residentBytes))
                        print(
                            "Realtime benchmark second=\(chunkIndex / 10) " +
                                "residentMiB=\(residentBytes / 1_048_576)"
                        )
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                return samples
            }.value
        }

        private static func forEachAudioBuffer(
            at url: URL,
            _ body: (AVAudioPCMBuffer) async throws -> Void
        ) async throws {
            let audioFile = try AVAudioFile(forReading: url)
            while audioFile.framePosition < audioFile.length {
                let remainingFrames = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                let frameCount = min(AVAudioFrameCount(1600), remainingFrames)
                let buffer = try #require(AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: frameCount
                ))
                try audioFile.read(into: buffer, frameCount: frameCount)
                try await body(buffer)
            }
        }

        private static func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        private static var benchmarkOutputDirectory: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("build/realtime-benchmarks/20260710-2234", isDirectory: true)
        }

        private static func containsRepeatedPrefix(_ text: String) -> Bool {
            let words = normalized(text).split(separator: " ")
            guard words.count >= 40 else { return false }
            let prefix = Array(words.prefix(20))
            for start in 20 ... words.count - prefix.count
                where Array(words[start ..< start + prefix.count]) == prefix
            {
                return true
            }
            return false
        }
    }

    private final class RealtimeFluidAudioBenchmarkCollector: RealtimeFluidAudioRecognizerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var storedTerminalText: String?
        private var storedTerminalAudioOffset: TimeInterval?
        private var storedFirstPreviewAudioOffset: TimeInterval?

        var terminalText: String? {
            lock.withLock { storedTerminalText }
        }

        var terminalAudioOffset: TimeInterval? {
            lock.withLock { storedTerminalAudioOffset }
        }

        var firstPreviewAudioOffset: TimeInterval? {
            lock.withLock { storedFirstPreviewAudioOffset }
        }

        func realtimeFluidAudioRecognizer(
            _: RealtimeFluidAudioRecognizer,
            sessionID _: UUID,
            didRecognize result: RealtimeRecognitionResult
        ) {
            lock.withLock {
                if result.snapshot?.isTerminal == true {
                    storedTerminalText = result.snapshot?.stableText
                    storedTerminalAudioOffset = result.snapshot?.audioOffset
                } else if storedFirstPreviewAudioOffset == nil,
                          result.snapshot?.pendingSegment?.text.isEmpty == false
                {
                    storedFirstPreviewAudioOffset = result.snapshot?.pendingSegment?.endOffset
                }
            }
        }

        func realtimeFluidAudioRecognizer(
            _: RealtimeFluidAudioRecognizer,
            sessionID _: UUID,
            didFail error: Error
        ) {
            Issue.record(error)
        }
    }

    private enum RealtimePipelinePerformanceError: Error {
        case audioBufferAllocationFailed
    }
#endif
