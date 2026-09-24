import AVFoundation
import Foundation
import Testing

@testable import ShareCore

#if os(macOS)
    @Suite("Realtime pipeline coordinator")
    struct RealtimePipelineCoordinatorTests {
        @Test("Bounds startup audio buffering")
        func boundsStartupAudioBuffering() throws {
            let fanout = RealtimePipelineAudioFanout()
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 16000
            ))
            buffer.frameLength = 16000

            fanout.beginStartupBuffering()
            for _ in 0 ..< 20 {
                fanout.append(buffer)
            }

            #expect(fanout.startupBufferedDuration == 15)
            #expect(fanout.startupReplayBaseOffset == 5)
            fanout.resetTimeline()
            #expect(fanout.startupBufferedDuration == 0)
            #expect(fanout.startupReplayBaseOffset == 0)
        }

        @Test("Shares recognition nodes for lanes using the same model")
        func sharesRecognitionNodes() {
            let lanes = [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                    translationProvider: .appleTranslator
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                    translationProvider: .appleTranslationRealtime
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(RealtimePipelineCoordinator.distinctRecognitionModelIDs(in: lanes) == [
                RecognitionModelDescriptor.appleSpeech.id,
                RecognitionModelStore.selectableDescriptor(
                    forModelID: RecognitionModelDescriptor.parakeetEOU320.id
                ).id,
            ])
        }

        @Test("Rejects duplicate lane combinations")
        func rejectsDuplicateLaneCombinations() {
            let lane = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslator
            )

            #expect(throws: RealtimePipelineError.duplicateLane) {
                try RealtimePipelineCoordinator.validated([lane, lane])
            }
        }

        @MainActor
        @Test("Disables a lane when its first translation reports a missing language pack")
        func disablesLaneForInitialMissingLanguagePack() {
            let error = NSError(
                domain: "TranslationErrorDomain",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "TranslationError.notInstalled"]
            )

            #expect(RealtimeLaneRuntime.shouldDisableTranslation(
                after: error,
                hasSuccessfulTranslation: false
            ))
        }

        @MainActor
        @Test("Keeps a working lane active after a transient missing language pack error")
        func keepsWorkingLaneActiveAfterTransientMissingLanguagePackError() {
            let error = NSError(
                domain: "TranslationErrorDomain",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "TranslationError.notInstalled"]
            )

            #expect(!RealtimeLaneRuntime.shouldDisableTranslation(
                after: error,
                hasSuccessfulTranslation: true
            ))
        }

        @Test("Rounds and clamps realtime lane latency")
        func roundsAndClampsRealtimeLaneLatency() {
            let latency = RealtimeLaneLatency(
                recognitionLatency: 0.4196,
                translationLatency: -0.1
            )

            #expect(latency.recognitionMilliseconds == 420)
            #expect(latency.translationMilliseconds == 0)
            #expect(latency.totalMilliseconds == 420)
        }

        @MainActor
        @Test("Publishes latency after a final text translation succeeds")
        func publishesLatencyAfterFinalTranslation() async {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslator
            )
            var currentDate = Date(timeIntervalSinceReferenceDate: 100)
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .bilingual },
                elapsed: { 2 },
                now: { currentDate },
                translationExecutor: { request in
                    currentDate.addTimeInterval(0.25)
                    return ModelExecutionResult(
                        modelID: request.provider.modelID,
                        duration: 0.25,
                        response: .success("你好。"),
                        sentencePairs: [
                            SentencePair(original: request.translationText, translation: "你好。"),
                        ]
                    )
                }
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(
                text: "Hello.",
                confidence: 0.9,
                state: .final,
                audioOffset: 1
            ))
            for _ in 0 ..< 20 {
                guard runtime.snapshot.latency == nil else { break }
                await Task.yield()
            }

            #expect(runtime.snapshot.latency?.recognitionMilliseconds == 1000)
            #expect(runtime.snapshot.latency?.translationMilliseconds == 250)
            #expect(runtime.snapshot.latency?.totalMilliseconds == 1250)
        }

        @MainActor
        @Test("Publishes latency only for the latest segment in one recognition callback")
        func publishesLatencyOnlyForLatestRecognitionSegment() async {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslator
            )
            var currentDate = Date(timeIntervalSinceReferenceDate: 100)
            var translatedSources: [String] = []
            var continuations: [CheckedContinuation<Void, Never>] = []
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .bilingual },
                elapsed: { 12.2 },
                now: { currentDate },
                translationExecutor: { request in
                    translatedSources.append(request.translationText)
                    await withCheckedContinuation { continuation in
                        continuations.append(continuation)
                    }
                    currentDate.addTimeInterval(0.1)
                    return ModelExecutionResult(
                        modelID: request.provider.modelID,
                        duration: 0.1,
                        response: .success("译文"),
                        sentencePairs: [
                            SentencePair(original: request.translationText, translation: "译文"),
                        ]
                    )
                }
            )
            let segments = [
                RealtimeRecognitionSegment(
                    text: "First.",
                    startOffset: 0,
                    endOffset: 4,
                    boundaryReason: .punctuation
                ),
                RealtimeRecognitionSegment(
                    text: "Second.",
                    startOffset: 4,
                    endOffset: 8,
                    boundaryReason: .punctuation
                ),
                RealtimeRecognitionSegment(
                    text: "Third.",
                    startOffset: 8,
                    endOffset: 12,
                    boundaryReason: .punctuation
                ),
            ]

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableSegments: segments,
                audioOffset: 12
            )))
            for expectedCount in 1 ... 3 {
                while translatedSources.count < expectedCount {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                #expect(runtime.snapshot.latency == nil)
                continuations.removeFirst().resume()
            }
            while runtime.snapshot.latency == nil {
                await Task.yield()
            }

            #expect(translatedSources == ["First.", "Second.", "Third."])
            #expect(runtime.snapshot.latency?.recognitionMilliseconds == 200)
            #expect(runtime.snapshot.latency?.translationMilliseconds == 300)
            #expect(runtime.snapshot.latency?.totalMilliseconds == 500)
        }

        @MainActor
        @Test("Clears latency when a later translation fails")
        func clearsLatencyAfterTranslationFailure() async {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslator
            )
            var requestCount = 0
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .bilingual },
                elapsed: { 2 },
                translationExecutor: { request in
                    requestCount += 1
                    if requestCount == 2 {
                        throw NSError(domain: "Translation", code: 1)
                    }
                    return ModelExecutionResult(
                        modelID: request.provider.modelID,
                        duration: 0,
                        response: .success("译文"),
                        sentencePairs: [
                            SentencePair(original: request.translationText, translation: "译文"),
                        ]
                    )
                }
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(
                text: "First.",
                confidence: 0.9,
                state: .final,
                audioOffset: 1
            ))
            for _ in 0 ..< 20 {
                guard runtime.snapshot.latency == nil else { break }
                await Task.yield()
            }
            #expect(runtime.snapshot.latency != nil)

            runtime.receiveRecognition(RealtimeRecognitionResult(
                text: "First.\n\nSecond.",
                confidence: 0.9,
                state: .final,
                audioOffset: 2
            ))
            for _ in 0 ..< 20 {
                guard requestCount < 2 else { break }
                await Task.yield()
            }

            #expect(requestCount == 2)
            #expect(runtime.snapshot.latency == nil)
        }

        @MainActor
        @Test("Transcription only lane publishes source text without translation")
        func transcriptionOnlyLanePublishesSourceText() {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .transcriptionOnly
            )
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .bilingual },
                elapsed: { 1 }
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(
                text: "Source text only.",
                confidence: 0.9,
                state: .final,
                audioOffset: 1
            ))

            #expect(runtime.snapshot.sourceText == "Source text only.")
            #expect(runtime.snapshot.translatedText.isEmpty)
            #expect(runtime.snapshot.sentencePairs.isEmpty)
            #expect(runtime.snapshot.captionLines.map(\.kind) == [.source])
            #expect(runtime.snapshot.latency == nil)
            #expect(runtime.trackSnapshot().segments.allSatisfy { $0.relation == .sourceOnly })
        }

        @MainActor
        @Test("Canonical revisions preserve source history identity and offset")
        func canonicalRevisionsPreserveSourceHistoryIdentity() throws {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .transcriptionOnly
            )
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .sourceOnly },
                elapsed: { 20 }
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableText: "First sentence.",
                audioOffset: 10
            )))
            let initial = try #require(runtime.trackSnapshot().segments.first)

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableText: "First corrected sentence. Second sentence.",
                audioOffset: 20
            )))
            let revised = runtime.trackSnapshot().segments

            #expect(revised.count == 2)
            #expect(revised[0].id == initial.id)
            #expect(revised[0].offset == initial.offset)
            #expect(revised[1].offset > revised[0].offset)
        }

        @MainActor
        @Test("Bounds unpunctuated source History without changing captions")
        func boundsUnpunctuatedSourceHistory() {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .transcriptionOnly
            )
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .sourceOnly },
                elapsed: { 30 }
            )
            let text = (1 ... 50).map { "word\($0)" }.joined(separator: " ")

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableText: text,
                audioOffset: 30
            )))

            #expect(runtime.snapshot.sourceText == text)
            #expect(runtime.snapshot.captionLines.map(\.text) == [text])
            #expect(runtime.trackSnapshot().segments.map {
                $0.sourceText.split(separator: " ").count
            } == [24, 24, 2])
        }

        @MainActor
        @Test("Preserves model EOU boundaries in captions and History")
        func preservesModelEOUBoundaries() {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                translationProvider: .transcriptionOnly
            )
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .sourceOnly },
                elapsed: { 12 }
            )
            let first = RealtimeRecognitionSegment(
                text: "First utterance without punctuation",
                startOffset: 0,
                endOffset: 5,
                boundaryReason: .modelEOU
            )
            let second = RealtimeRecognitionSegment(
                text: "Second utterance also has no punctuation",
                startOffset: 5,
                endOffset: 12,
                boundaryReason: .modelEOU
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableSegments: [first, second],
                audioOffset: 12
            )))

            #expect(runtime.snapshot.captionLines.map(\.text) == [first.text, second.text])
            #expect(runtime.trackSnapshot().segments.map(\.id) == [first.id, second.id])
            #expect(runtime.trackSnapshot().segments.map(\.offset) == [0, 5])
        }

        @Test("Rejects more than three lanes")
        func rejectsMoreThanThreeLanes() {
            let lanes = RealtimeTranslationProvider.availableCases.map {
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                    translationProvider: $0
                )
            } + [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(throws: RealtimePipelineError.maximumLaneCount) {
                try RealtimePipelineCoordinator.validated(lanes)
            }
        }

        @Test("Maps start configuration blockers")
        func mapsStartConfigurationBlockers() {
            let appleLane = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslator
            )
            let duplicateLanes = [appleLane, appleLane]
            let unsupportedLane = RealtimeLaneConfiguration(
                recognitionModelID: "unsupported-model",
                translationProvider: .appleTranslator
            )
            let tooManyLanes = RealtimeTranslationProvider.availableCases.map {
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                    translationProvider: $0
                )
            } + [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: [],
                hasImportedAudio: false,
                isMemoryConstrained: false
            ) == .missingLane)
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: [appleLane],
                hasImportedAudio: false,
                isMemoryConstrained: true
            ) == .memoryPressure)
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: duplicateLanes,
                hasImportedAudio: false,
                isMemoryConstrained: false
            ) == .duplicateLane)
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: [unsupportedLane],
                hasImportedAudio: false,
                isMemoryConstrained: false
            ) == .unsupportedRecognitionModel("unsupported-model"))
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: tooManyLanes,
                hasImportedAudio: false,
                isMemoryConstrained: false
            ) == .maximumLaneCount)
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: [appleLane],
                hasImportedAudio: false,
                isMemoryConstrained: false
            ) == nil)
        }

        @Test("Requires imported audio for MOSS")
        func requiresImportedAudioForMOSS() {
            let lane = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                translationProvider: .transcriptionOnly
            )

            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: [lane],
                hasImportedAudio: false,
                isMemoryConstrained: false
            ) == .importedAudioRequired(RecognitionModelDescriptor.mossTranscribeDiarize.title))
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: [lane],
                hasImportedAudio: true,
                isMemoryConstrained: false
            ) == nil)
        }

        @Test("Maps local model limits to start blockers")
        func mapsLocalModelLimitsToStartBlockers() {
            let lanes = [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.nemotronStreaming1120.id,
                    translationProvider: .appleTranslator
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: lanes,
                hasImportedAudio: false,
                isMemoryConstrained: false,
                physicalMemory: 16 * 1024 * 1024 * 1024
            ) == .tooManyLocalRecognitionModels)
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: lanes,
                hasImportedAudio: false,
                isMemoryConstrained: false,
                physicalMemory: 24 * 1024 * 1024 * 1024
            ) == nil)
            #expect(RealtimeSessionStore.startConfigurationBlocker(
                configurations: lanes,
                hasImportedAudio: false,
                isMemoryConstrained: false,
                physicalMemory: 32 * 1024 * 1024 * 1024
            ) == nil)
        }

        @Test("Limits distinct FluidAudio models on sixteen gigabyte Macs")
        func limitsDistinctFluidAudioModels() {
            let lanes = [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.nemotronStreaming1120.id,
                    translationProvider: .appleTranslator
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(throws: RealtimePipelineError.tooManyLocalRecognitionModels) {
                try RealtimePipelineCoordinator.validated(
                    lanes,
                    physicalMemory: 16 * 1024 * 1024 * 1024
                )
            }
        }

        @Test("Allows MOSS beside one FluidAudio model on sixteen gigabyte Macs")
        func allowsMOSSBesideOneFluidAudioModel() throws {
            let lanes = [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                    translationProvider: .transcriptionOnly
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(try RealtimePipelineCoordinator.validated(
                lanes,
                physicalMemory: 16 * 1024 * 1024 * 1024
            ) == lanes)
        }

        @Test("Serializes MOSS after FluidAudio on low-memory Macs")
        func serializesMOSSAfterFluidAudioOnLowMemory() {
            let lanes = [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                    translationProvider: .transcriptionOnly
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(RealtimeSessionStore.shouldSerializeMOSS(
                configurations: lanes,
                physicalMemory: 16 * 1024 * 1024 * 1024
            ))
            #expect(!RealtimeSessionStore.shouldSerializeMOSS(
                configurations: lanes,
                physicalMemory: 24 * 1024 * 1024 * 1024
            ))
        }

        @Test("Scales FluidAudio limits with physical memory")
        func scalesFluidAudioLimitsWithPhysicalMemory() throws {
            let lanes = [
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.nemotronStreaming1120.id,
                    translationProvider: .appleTranslator
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
                RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.nemotronStreaming560.id,
                    translationProvider: .appleTranslator
                ),
            ]

            #expect(throws: RealtimePipelineError.tooManyLocalRecognitionModels) {
                try RealtimePipelineCoordinator.validated(
                    lanes,
                    physicalMemory: 24 * 1024 * 1024 * 1024
                )
            }
            #expect(try RealtimePipelineCoordinator.validated(
                lanes,
                physicalMemory: 32 * 1024 * 1024 * 1024
            ) == lanes)
        }

        @Test("Persists lane order and primary lane")
        func persistsLaneOrderAndPrimaryLane() throws {
            let suiteName = "RealtimePipelineCoordinatorTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let first = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslator
            )
            let second = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslationRealtime
            )
            RealtimeLaneConfigurationPersistence.save(
                configurations: [first, second],
                primaryLaneID: second.id,
                defaults: defaults
            )

            let loaded = RealtimeLaneConfigurationPersistence.load(
                defaults: defaults,
                fallbackRecognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                fallbackTranslationProvider: .appleTranslator
            )

            #expect(loaded.configurations == [first, second])
            #expect(loaded.primaryLaneID == second.id)
        }

        @Test("Migrates retired Azure provider without dropping other lanes")
        func migratesRetiredAzureProvider() throws {
            let suiteName = "RealtimePipelineCoordinatorTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let retiredLaneID = UUID()
            let retainedLaneID = UUID()
            let storedLanes: [[String: String]] = [
                [
                    "id": retiredLaneID.uuidString,
                    "recognitionModelID": RecognitionModelDescriptor.appleSpeech.id,
                    "translationProvider": "azure_gpt_realtime_translator",
                ],
                [
                    "id": retainedLaneID.uuidString,
                    "recognitionModelID": RecognitionModelDescriptor.nemotronStreaming1120.id,
                    "translationProvider": RealtimeTranslationProvider.appleTranslationRealtime.rawValue,
                ],
            ]
            let storedData = try JSONSerialization.data(withJSONObject: storedLanes)
            defaults.set(storedData, forKey: "realtime_lane_configurations")
            defaults.set(retainedLaneID.uuidString, forKey: "realtime_primary_lane_id")

            let loaded = RealtimeLaneConfigurationPersistence.load(
                defaults: defaults,
                fallbackRecognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                fallbackTranslationProvider: .appleTranslator
            )

            #expect(loaded.configurations.map(\.id) == [retiredLaneID, retainedLaneID])
            #expect(loaded.configurations.map(\.translationProvider) == [
                .appleTranslator,
                .appleTranslationRealtime,
            ])
            #expect(loaded.primaryLaneID == retainedLaneID)
        }

        @Test("Does not restore MOSS as a live recognition model")
        func doesNotRestoreMOSSForLiveAudio() throws {
            let suiteName = "RealtimePipelineCoordinatorTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let lane = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                translationProvider: .transcriptionOnly
            )
            RealtimeLaneConfigurationPersistence.save(
                configurations: [lane],
                primaryLaneID: lane.id,
                defaults: defaults
            )

            let loaded = RealtimeLaneConfigurationPersistence.load(
                defaults: defaults,
                fallbackRecognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                fallbackTranslationProvider: .appleTranslator
            )

            #expect(loaded.configurations.first?.recognitionModelID == RecognitionModelDescriptor.appleSpeech.id)
        }

        @MainActor
        @Test("Preserves imported MOSS speaker metadata in source-only history")
        func preservesMOSSSpeakerMetadata() throws {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                translationProvider: .transcriptionOnly
            )
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                audioSource: .importedAudio,
                startedOffset: 0,
                displayMode: { .sourceOnly },
                elapsed: { 5 }
            )
            let segment = RealtimeRecognitionSegment(
                text: "Speaker text.",
                startOffset: 1.25,
                endOffset: 3.75,
                speakerID: "S01",
                boundaryReason: .terminal
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableSegments: [segment],
                audioOffset: segment.endOffset,
                isTerminal: true
            )))

            let track = runtime.trackSnapshot()
            #expect(track.audioSource == .importedAudio)
            #expect(track.segments.first?.speakerID == "S01")
            #expect(track.segments.first?.offset == 1.25)
            #expect(track.segments.first?.duration == 2.5)
        }

        @MainActor
        @Test("Preserves MOSS speaker metadata when one segment becomes multiple translation sentences")
        func preservesMOSSSpeakerMetadataAcrossTranslationSentences() {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                translationProvider: .appleTranslator
            )
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: .english,
                targetLanguage: .english,
                audioSource: .importedAudio,
                startedOffset: 0,
                displayMode: { .bilingual },
                elapsed: { 5 }
            )
            let segment = RealtimeRecognitionSegment(
                text: "First sentence. Second sentence.",
                startOffset: 1,
                endOffset: 5,
                speakerID: "S01",
                boundaryReason: .terminal
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableSegments: [segment],
                audioOffset: segment.endOffset,
                isTerminal: true
            )))

            let segments = runtime.trackSnapshot().segments
            #expect(segments.count == 2)
            #expect(segments.allSatisfy { $0.speakerID == "S01" })
            #expect(segments.first?.offset == 1)
            #expect(abs(segments.reduce(0) { $0 + $1.duration } - 4) < 0.001)
        }

        @Test("Migrates persisted legacy recognition models")
        func migratesPersistedLegacyRecognitionModels() throws {
            let suiteName = "RealtimePipelineCoordinatorTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let legacy = RealtimeLaneConfiguration(
                recognitionModelID: "parakeet-flash",
                translationProvider: .appleTranslator
            )
            RealtimeLaneConfigurationPersistence.save(
                configurations: [legacy],
                primaryLaneID: legacy.id,
                defaults: defaults
            )

            let loaded = RealtimeLaneConfigurationPersistence.load(
                defaults: defaults,
                fallbackRecognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                fallbackTranslationProvider: .appleTranslator
            )

            #expect(
                loaded.configurations[0].recognitionModelID ==
                    RecognitionModelStore.selectableDescriptor(
                        forModelID: "parakeet-flash"
                    ).id
            )
            #expect(loaded.primaryLaneID == legacy.id)
        }

        @Test("Tracks one shared audio timeline")
        func tracksSharedAudioTimeline() throws {
            let fanout = RealtimePipelineAudioFanout()
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 1600
            ))
            buffer.frameLength = 1600

            fanout.append(buffer)
            #expect(abs(fanout.currentAudioOffset - 0.1) < 0.0001)

            fanout.resetTimeline()
            #expect(fanout.currentAudioOffset == 0)
        }
    }
#endif

@Suite("Realtime multi-track history")
struct RealtimeMultiTrackHistoryTests {
    @Test("Round trips tracks and primary track")
    func roundTripsTracks() throws {
        let first = makeTrack(
            recognitionModelID: "apple-speech",
            provider: .appleTranslator,
            text: "Hello",
            translation: "Hola"
        )
        let second = makeTrack(
            recognitionModelID: "qwen3-asr-int8",
            provider: .appleTranslationRealtime,
            text: "Hello",
            translation: "Buenos dias"
        )
        let session = RealtimeHistorySession(
            requestID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: "Mac Audio",
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: first.translationProviderID,
            modelDisplayName: first.translationProviderDisplayName,
            segments: first.legacySegments,
            tracks: [first, second],
            primaryTrackID: second.id
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RealtimeHistorySession.self, from: data)

        #expect(decoded.tracks == [first, second])
        #expect(decoded.primaryTrackID == second.id)
        #expect(decoded.primaryTrack == second)
    }

    @Test("Synthesizes one track when decoding legacy history")
    func synthesizesLegacyTrack() throws {
        let legacy = """
        {
          "requestID": "\(UUID().uuidString)",
          "startedAt": 100,
          "endedAt": 120,
          "duration": 20,
          "inputSource": "Mac Audio",
          "sourceLanguage": "English",
          "targetLanguage": "Spanish",
          "modelID": "apple-translate",
          "modelDisplayName": "Apple Translate",
          "segments": [
            {
              "id": "\(UUID().uuidString)",
              "offset": 2,
              "sourceText": "Hello",
              "translatedText": "Hola"
            }
          ],
          "audioRecordings": [],
          "delayedTranscriptSegments": [],
          "delayedConversationItems": [],
          "transcriptionModels": []
        }
        """

        let session = try JSONDecoder().decode(
            RealtimeHistorySession.self,
            from: Data(legacy.utf8)
        )

        #expect(session.tracks.count == 1)
        #expect(session.primaryTrack?.legacySegments == session.segments)
    }

    @MainActor
    @Test("Keeps newer track content when an older autosave arrives")
    func keepsNewerTrackContent() {
        let trackID = UUID()
        let currentTrack = RealtimeHistoryTrack(
            id: trackID,
            recognitionModelID: "apple-speech",
            recognitionModelDisplayName: "Apple Speech",
            translationProviderID: "apple_translator",
            translationProviderDisplayName: "Apple Translator",
            segments: [
                RealtimeHistoryTrackSegment(
                    offset: 2,
                    sourceText: "New source",
                    translatedText: "New translation",
                    relation: .paired
                ),
            ],
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let staleTrack = RealtimeHistoryTrack(
            id: trackID,
            recognitionModelID: "apple-speech",
            recognitionModelDisplayName: "Apple Speech",
            translationProviderID: "apple_translator",
            translationProviderDisplayName: "Apple Translator",
            segments: [
                RealtimeHistoryTrackSegment(
                    offset: 2,
                    sourceText: "Old source",
                    translatedText: "Old translation",
                    relation: .paired
                ),
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let current = makeSession(track: currentTrack)
        let incoming = makeSession(track: staleTrack)

        let merged = TranslationHistoryService.mergingRealtimeAutosave(incoming, into: current)

        #expect(merged.tracks.first == currentTrack)
    }

    private func makeTrack(
        recognitionModelID: String,
        provider: RealtimeTranslationProvider,
        text: String,
        translation: String
    ) -> RealtimeHistoryTrack {
        RealtimeHistoryTrack(
            recognitionModelID: recognitionModelID,
            recognitionModelDisplayName: recognitionModelID,
            translationProviderID: provider.rawValue,
            translationProviderDisplayName: provider.title,
            segments: [
                RealtimeHistoryTrackSegment(
                    offset: 2,
                    sourceText: text,
                    translatedText: translation,
                    relation: .paired
                ),
            ]
        )
    }

    private func makeSession(track: RealtimeHistoryTrack) -> RealtimeHistorySession {
        RealtimeHistorySession(
            requestID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: "Mac Audio",
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: track.translationProviderID,
            modelDisplayName: track.translationProviderDisplayName,
            segments: track.legacySegments,
            tracks: [track],
            primaryTrackID: track.id
        )
    }
}
