import AVFoundation
import Foundation
import Testing

@testable import ShareCore

#if os(macOS)
    @Suite("Realtime pipeline reliability")
    struct RealtimePipelineReliabilityTests {
        @Test("Paused fanout does not advance the audio timeline")
        func pausedFanoutDoesNotAdvanceTimeline() throws {
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
            fanout.setPaused(true)
            fanout.append(buffer)
            #expect(abs(fanout.currentAudioOffset - 0.1) < 0.0001)

            fanout.setPaused(false)
            fanout.append(buffer)
            #expect(abs(fanout.currentAudioOffset - 0.2) < 0.0001)
        }

        #if arch(arm64) && canImport(FluidAudio)
            @Test("Bounds pending FluidAudio input")
            func boundsPendingFluidAudioInput() {
                #expect(RealtimeFluidAudioRecognizer.acceptsPendingAudio(
                    pendingSampleCount: 14 * 16000,
                    incomingSampleCount: 16000,
                    sampleRate: 16000
                ))
                #expect(!RealtimeFluidAudioRecognizer.acceptsPendingAudio(
                    pendingSampleCount: 15 * 16000,
                    incomingSampleCount: 1,
                    sampleRate: 16000
                ))
            }
        #endif

        @MainActor
        @Test("New structured lane ignores recognition before activation")
        func newStructuredLaneIgnoresEarlierRecognition() {
            let runtime = RealtimeLaneRuntime(
                configuration: RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .transcriptionOnly
                ),
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 10,
                displayMode: { .sourceOnly },
                elapsed: { 15 }
            )
            let earlier = RealtimeRecognitionSegment(
                text: "Earlier.",
                startOffset: 0,
                endOffset: 5,
                boundaryReason: .modelEOU
            )
            let active = RealtimeRecognitionSegment(
                text: "Active.",
                startOffset: 10,
                endOffset: 15,
                boundaryReason: .modelEOU
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableSegments: [earlier, active],
                audioOffset: 15
            )))

            #expect(runtime.snapshot.sourceText == "Active.")
            #expect(runtime.trackSnapshot().segments.map(\.id) == [active.id])
        }

        @MainActor
        @Test("New Apple Speech lane removes its subscription baseline")
        func newAppleSpeechLaneRemovesBaseline() {
            let baseline = RealtimeRecognitionSnapshot(stableText: "Earlier.")
            let runtime = RealtimeLaneRuntime(
                configuration: RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                    translationProvider: .transcriptionOnly
                ),
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 10,
                recognitionBaseline: baseline,
                displayMode: { .sourceOnly },
                elapsed: { 15 }
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableText: "Earlier. Active.",
                audioOffset: 15
            )))

            #expect(runtime.snapshot.sourceText == "Active.")
            #expect(runtime.trackSnapshot().segments.map(\.sourceText) == ["Active."])
        }

        @MainActor
        @Test("Matches translated History metadata by source text")
        func matchesTranslatedHistoryMetadataBySourceText() async {
            let runtime = RealtimeLaneRuntime(
                configuration: RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.parakeetEOU320.id,
                    translationProvider: .appleTranslator
                ),
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                startedOffset: 0,
                displayMode: { .bilingual },
                elapsed: { 10 },
                translationExecutor: { request in
                    if request.translationText == "First." {
                        throw NSError(domain: "Translation", code: 1)
                    }
                    return ModelExecutionResult(
                        modelID: request.provider.modelID,
                        duration: 0,
                        response: .success("第二句。"),
                        sentencePairs: [
                            SentencePair(original: request.translationText, translation: "第二句。"),
                        ]
                    )
                }
            )
            let first = RealtimeRecognitionSegment(
                text: "First.",
                startOffset: 0,
                endOffset: 4,
                boundaryReason: .modelEOU
            )
            let second = RealtimeRecognitionSegment(
                text: "Second.",
                startOffset: 5,
                endOffset: 10,
                boundaryReason: .modelEOU
            )

            runtime.receiveRecognition(RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableSegments: [first, second],
                audioOffset: 10
            )))
            for _ in 0 ..< 50 {
                guard runtime.snapshot.sentencePairs.count < 1 else { break }
                await Task.yield()
            }

            let segment = runtime.trackSnapshot().segments.first
            #expect(segment?.sourceText == "Second.")
            #expect(segment?.id == second.id)
            #expect(segment?.offset == 5)
        }
    }
#endif
