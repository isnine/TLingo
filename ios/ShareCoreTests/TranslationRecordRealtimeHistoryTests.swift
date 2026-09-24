//
//  TranslationRecordRealtimeHistoryTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("TranslationRecord realtime history")
struct TranslationRecordRealtimeHistoryTests {
    @Test("Decodes model result JSON, ignoring any legacy realtime session field")
    func decodesModelResultJSONIgnoringLegacyRealtimeSession() throws {
        let data = Data("""
        [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "modelID": "apple-translate",
            "modelDisplayName": "Apple Translate",
            "resultText": "Hola",
            "duration": 0.2,
            "realtimeSession": { "ignored": true }
          }
        ]
        """.utf8)

        let results = try JSONDecoder().decode([ModelResult].self, from: data)

        #expect(results.count == 1)
        #expect(results[0].resultText == "Hola")
    }

    @Test("Stores the realtime session at the record level")
    func storesRealtimeSessionAtRecordLevel() {
        let audioRecording = RealtimeHistoryAudioRecording(
            directoryName: "00000000-0000-0000-0000-000000000002",
            sampleRate: 16000,
            channelCount: 1,
            segments: [
                RealtimeHistoryAudioSegment(
                    relativePath: "00000000-0000-0000-0000-000000000002/segment-0001.m4a",
                    offset: 0,
                    duration: 5,
                    byteCount: 1024
                ),
            ]
        )
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 112),
            duration: 12,
            inputSource: "Microphone",
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(offset: 12, sourceText: "Hello.", translatedText: "Hola."),
            ],
            audioRecording: audioRecording
        )

        let plain = TranslationRecord(sourceText: "Hello.")
        #expect(plain.realtimeSession == nil)
        #expect(plain.isRealtimeRecord == false)

        let legacyRecord = TranslationRecord(sourceText: "Hello.", actionName: TranslationRecord.realtimeActionName)
        #expect(legacyRecord.realtimeSession == nil)
        #expect(legacyRecord.isRealtimeRecord)

        let record = TranslationRecord(sourceText: "Hello.", actionName: TranslationRecord.realtimeActionName)
        record.realtimeSession = session
        #expect(record.realtimeSession == session)
        #expect(record.realtimeSession?.audioRecording == audioRecording)
        #expect(record.realtimeSession?.audioRecordings == [audioRecording])
        #expect(record.isRealtimeRecord)
    }

    @Test("Uses a generated title and decodes legacy sessions without one")
    func realtimeHistoryDisplayTitle() throws {
        var session = RealtimeHistorySession(
            requestID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 112),
            duration: 12,
            inputSource: "Microphone",
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(
                    offset: 0,
                    sourceText: "Original first sentence.",
                    translatedText: "Original."
                ),
            ]
        )

        #expect(session.displayTitle(fallback: "Fallback") == "Original first sentence.")
        session.generatedTitle = "Meeting project update"
        #expect(session.displayTitle(fallback: "Fallback") == "Meeting project update")

        let data = try JSONEncoder().encode(session)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "generatedTitle")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(RealtimeHistorySession.self, from: legacyData)
        #expect(legacy.generatedTitle == nil)
        #expect(legacy.displayTitle(fallback: "Fallback") == "Original first sentence.")
    }

    @Test("Decodes legacy realtime session without audio recording")
    func decodesLegacyRealtimeSessionWithoutAudioRecording() throws {
        let data = Data("""
        {
          "requestID": "00000000-0000-0000-0000-000000000003",
          "startedAt": 100,
          "endedAt": 112,
          "duration": 12,
          "inputSource": "Microphone",
          "sourceLanguage": "English",
          "targetLanguage": "Spanish",
          "modelID": "apple-translate",
          "modelDisplayName": "Apple Translate",
          "segments": [
            {
              "id": "00000000-0000-0000-0000-000000000004",
              "offset": 12,
              "sourceText": "Hello.",
              "translatedText": "Hola."
            }
          ]
        }
        """.utf8)

        let session = try JSONDecoder().decode(RealtimeHistorySession.self, from: data)

        #expect(session.audioRecording == nil)
        #expect(session.audioRecordings.isEmpty)
        #expect(session.segments.count == 1)
    }

    @Test("Decodes legacy realtime audio recording as multi recording")
    func decodesLegacyRealtimeAudioRecordingAsMultiRecording() throws {
        let data = Data("""
        {
          "requestID": "00000000-0000-0000-0000-000000000005",
          "startedAt": 100,
          "endedAt": 112,
          "duration": 12,
          "inputSource": "Mac Audio",
          "sourceLanguage": "English",
          "targetLanguage": "Spanish",
          "modelID": "apple-translate",
          "modelDisplayName": "Apple Translate",
          "segments": [
            {
              "id": "00000000-0000-0000-0000-000000000006",
              "offset": 12,
              "sourceText": "Hello.",
              "translatedText": "Hola."
            }
          ],
          "audioRecording": {
            "id": "00000000-0000-0000-0000-000000000007",
            "directoryName": "00000000-0000-0000-0000-000000000005",
            "format": "m4a",
            "sampleRate": 16000,
            "channelCount": 1,
            "segments": [
              {
                "id": "00000000-0000-0000-0000-000000000008",
                "relativePath": "00000000-0000-0000-0000-000000000005/segment-0001.m4a",
                "offset": 0,
                "duration": 5,
                "byteCount": 1024
              }
            ]
          }
        }
        """.utf8)

        let session = try JSONDecoder().decode(RealtimeHistorySession.self, from: data)

        #expect(session.audioRecordings.count == 1)
        #expect(session.audioRecordings[0].source == .macAudio)
        #expect(session.audioRecording == session.audioRecordings[0])
    }

    @Test("Conversation builder removes microphone duplicates of Mac audio")
    func conversationBuilderRemovesMicrophoneDuplicatesOfMacAudio() {
        let items = RealtimeHistoryConversationBuilder.build(from: [
            RealtimeHistoryTranscriptSegment(
                source: .macAudio,
                offset: 0,
                duration: 5,
                text: "Hello from the meeting.",
                translatedText: "Hola desde la reunion."
            ),
            RealtimeHistoryTranscriptSegment(
                source: .microphone,
                offset: 0.4,
                duration: 5,
                text: "hello from the meeting",
                translatedText: "Hola desde la reunion."
            ),
            RealtimeHistoryTranscriptSegment(
                source: .microphone,
                offset: 7,
                duration: 4,
                text: "I have a question.",
                translatedText: "Tengo una pregunta."
            ),
        ])

        #expect(items.map(\.source) == [.macAudio, .microphone])
        #expect(items.map(\.text) == ["Hello from the meeting.", "I have a question."])
    }

    @Test("Conversation builder merges realtime history and microphone transcript by offset")
    func conversationBuilderMergesRealtimeHistoryAndMicrophoneTranscriptByOffset() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let microphoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(id: firstID, offset: 0, sourceText: "Welcome.", translatedText: "Bienvenido."),
                RealtimeHistorySegment(id: secondID, offset: 10, sourceText: "Let's continue.", translatedText: "Continuemos."),
            ],
            delayedTranscriptSegments: [
                RealtimeHistoryTranscriptSegment(
                    id: microphoneID,
                    source: .microphone,
                    offset: 5,
                    duration: 5,
                    text: "I have a question.",
                    translatedText: "Tengo una pregunta."
                ),
            ]
        )

        let items = RealtimeHistoryConversationBuilder.build(from: session)

        #expect(items.map(\.source) == [.macAudio, .microphone, .macAudio])
        #expect(items.map(\.text) == ["Welcome.", "I have a question.", "Let's continue."])
        #expect(items.map(\.id) == [firstID, microphoneID, secondID])
        #expect(RealtimeHistoryConversationBuilder.build(from: session).map(\.id) == items.map(\.id))
    }

    @Test("Conversation builder folds microphone echo when building from session")
    func conversationBuilderFoldsMicrophoneEchoWhenBuildingFromSession() {
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(
                    offset: 0,
                    sourceText: "Hello from the meeting.",
                    translatedText: "Hola desde la reunion."
                ),
            ],
            delayedTranscriptSegments: [
                RealtimeHistoryTranscriptSegment(
                    source: .microphone,
                    offset: 0.4,
                    duration: 5,
                    text: "hello from the meeting",
                    translatedText: "Hola desde la reunion."
                ),
                RealtimeHistoryTranscriptSegment(
                    source: .microphone,
                    offset: 7,
                    duration: 4,
                    text: "I have a question.",
                    translatedText: "Tengo una pregunta."
                ),
            ]
        )

        let items = RealtimeHistoryConversationBuilder.build(from: session)

        #expect(items.map(\.source) == [.macAudio, .microphone])
        #expect(items.map(\.text) == ["Hello from the meeting.", "I have a question."])
    }

    @Test("Copy text prefixes each realtime line with offset and source")
    func copyTextPrefixesEachRealtimeLineWithOffsetAndSource() {
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [],
            delayedConversationItems: [
                RealtimeHistoryConversationItem(
                    source: .macAudio,
                    offset: 0,
                    text: "Welcome.\nBack.",
                    translatedText: "Bienvenido."
                ),
                RealtimeHistoryConversationItem(
                    source: .microphone,
                    offset: 5,
                    text: "I have a question.",
                    translatedText: "Tengo una pregunta."
                ),
            ]
        )

        #expect(session.sourceTextForCopy == """
        [00:00] Mac Audio: Welcome.
        [00:00] Mac Audio: Back.
        [00:05] Microphone: I have a question.
        """)
        #expect(session.translatedTextForCopy == """
        [00:00] Mac Audio: Bienvenido.
        [00:05] Microphone: Tengo una pregunta.
        """)
        #expect(session.bilingualTextForCopy == """
        [00:00] Mac Audio: Welcome.
        [00:00] Mac Audio: Back.
        [00:00] Mac Audio: Bienvenido.

        [00:05] Microphone: I have a question.
        [00:05] Microphone: Tengo una pregunta.
        """)
    }

    @Test("Microphone post processor reports missing microphone recording before requesting speech")
    func microphonePostProcessorReportsMissingMicrophoneRecording() async {
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 112),
            duration: 12,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(offset: 0, sourceText: "Hello.", translatedText: "Hola."),
            ]
        )

        do {
            _ = try await RealtimeHistoryAudioPostProcessor.processMicrophoneRecording(
                session,
                recognitionModelID: RecognitionModelDescriptor.nemotronStreaming1120.id
            )
            Issue.record("Expected missing microphone recording error")
        } catch let error as RealtimeHistoryAudioPostProcessorError {
            #expect(error == .microphoneRecordingUnavailable)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

private enum RealtimeHistoryTranslationTestError: Error {
    case translationFailed
}

@Suite("Realtime history microphone translation")
struct RealtimeHistoryMicTranslationTests {
    @Test("Retries a failed segment and keeps translating later segments")
    func retriesFailedSegmentAndContinues() async throws {
        let segments = [
            microphoneTranslationSegment("Retry this.", offset: 0),
            microphoneTranslationSegment("Translate later.", offset: 5),
            microphoneTranslationSegment("Broken segment.", offset: 10),
            microphoneTranslationSegment("Translate after failure.", offset: 15),
        ]
        var attempts: [String: Int] = [:]

        let translated = try await RealtimeHistoryAudioPostProcessor.translateTranscriptSegments(
            segments,
            sourceLanguage: .english,
            targetLanguage: .spanish,
            translateText: { text in
                attempts[text, default: 0] += 1
                if text == "Retry this.", attempts[text] == 1 {
                    throw RealtimeHistoryTranslationTestError.translationFailed
                }
                if text == "Broken segment." {
                    throw RealtimeHistoryTranslationTestError.translationFailed
                }
                return "es: \(text)"
            }
        )

        #expect(translated.map(\.translatedText) == [
            "es: Retry this.",
            "es: Translate later.",
            "",
            "es: Translate after failure.",
        ])
        #expect(attempts["Retry this."] == 2)
        #expect(attempts["Broken segment."] == 2)
        #expect(attempts["Translate after failure."] == 1)
    }

    @Test("Cancellation stops translation before publishing a partial result")
    func cancellationStopsPartialPublishing() async {
        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (releaseStream, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        var published = false

        let task = Task {
            try await RealtimeHistoryAudioPostProcessor.translateTranscriptSegments(
                [microphoneTranslationSegment("Cancel this.", offset: 0)],
                sourceLanguage: .english,
                targetLanguage: .spanish,
                translateText: { text in
                    startedContinuation.yield()
                    for await _ in releaseStream {
                        break
                    }
                    return "es: \(text)"
                },
                onSegmentTranslated: { _ in
                    published = true
                }
            )
        }
        var startedIterator = startedStream.makeAsyncIterator()
        _ = await startedIterator.next()
        task.cancel()
        releaseContinuation.yield()
        releaseContinuation.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!published)
    }

    @Test("Out of order progress tokens cannot replace newer partial results")
    func progressGateRejectsOutOfOrderUpdates() {
        let gate = RealtimeHistoryProgressGate()
        let phase = gate.currentPhase()
        let older = gate.nextToken(for: phase)
        let newer = gate.nextToken(for: phase)

        #expect(gate.shouldPublish(newer))
        #expect(!gate.shouldPublish(older))

        gate.advance()
        #expect(!gate.shouldPublish(newer))
    }

    @Test("Microphone processing merges owned fields into the latest session")
    func microphoneProcessingMergesIntoLatestSession() {
        let requestID = UUID()
        var staleProcessed = realtimeHistorySession(
            requestID: requestID,
            sourceText: "Old primary",
            translatedText: "Old translation",
            duration: 10
        )
        staleProcessed.delayedTranscriptSegments = [
            microphoneTranslationSegment("Microphone text", offset: 3),
        ]
        staleProcessed.transcriptionModels = [
            RealtimeHistoryTranscriptionModel(
                source: .microphone,
                modelID: "speech",
                modelDisplayName: "Speech"
            ),
        ]

        let latest = realtimeHistorySession(
            requestID: requestID,
            sourceText: "New primary",
            translatedText: "New translation",
            duration: 20
        )
        let merged = RealtimeHistoryAudioPostProcessor.mergingMicrophonePostProcessing(
            staleProcessed,
            into: latest
        )

        #expect(merged.segments == latest.segments)
        #expect(merged.duration == 20)
        #expect(merged.delayedTranscriptSegments == staleProcessed.delayedTranscriptSegments)
        #expect(merged.transcriptionModels == staleProcessed.transcriptionModels)
    }
}

private func microphoneTranslationSegment(_ text: String, offset: TimeInterval) -> RealtimeHistoryTranscriptSegment {
    RealtimeHistoryTranscriptSegment(source: .microphone, offset: offset, duration: 4, text: text)
}

private func realtimeHistorySession(
    requestID: UUID,
    sourceText: String,
    translatedText: String,
    duration: TimeInterval
) -> RealtimeHistorySession {
    RealtimeHistorySession(
        requestID: requestID,
        startedAt: Date(timeIntervalSince1970: 100),
        endedAt: Date(timeIntervalSince1970: 100 + duration),
        duration: duration,
        inputSource: "Mac Audio",
        inputSourceID: .macAudio,
        sourceLanguage: "English",
        targetLanguage: "Spanish",
        modelID: "apple-translate",
        modelDisplayName: "Apple Translate",
        segments: [
            RealtimeHistorySegment(offset: 0, sourceText: sourceText, translatedText: translatedText),
        ]
    )
}

@Suite("Realtime history source captions")
struct RealtimeHistorySourceCaptionTests {
    @Test("Source caption builder keeps microphone text without deduplication")
    func sourceCaptionBuilderKeepsMicrophoneTextWithoutDeduplication() {
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(
                    offset: 0,
                    sourceText: "Hello from the meeting.",
                    translatedText: "Hola desde la reunion."
                ),
            ],
            delayedTranscriptSegments: [
                RealtimeHistoryTranscriptSegment(
                    source: .microphone,
                    offset: 0.4,
                    duration: 5,
                    text: "hello from the meeting",
                    translatedText: "Hola desde la reunion."
                ),
                RealtimeHistoryTranscriptSegment(
                    source: .microphone,
                    offset: 7,
                    duration: 4,
                    text: "I have a question.",
                    translatedText: "Tengo una pregunta."
                ),
            ]
        )

        let macItems = RealtimeHistoryConversationBuilder.build(from: session, source: .macAudio)
        let microphoneItems = RealtimeHistoryConversationBuilder.build(from: session, source: .microphone)

        #expect(macItems.map(\.text) == ["Hello from the meeting."])
        #expect(microphoneItems.map(\.text) == ["hello from the meeting", "I have a question."])
        #expect(microphoneItems.map(\.source) == [.microphone, .microphone])
    }

    @Test("Source copy text follows the selected realtime caption source")
    func sourceCopyTextFollowsSelectedRealtimeCaptionSource() {
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: RealtimeHistoryAudioSource.macAudio.title,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(
                    offset: 0,
                    sourceText: "Welcome.",
                    translatedText: "Bienvenido."
                ),
            ],
            delayedTranscriptSegments: [
                RealtimeHistoryTranscriptSegment(
                    source: .microphone,
                    offset: 5,
                    duration: 5,
                    text: "I have a question.",
                    translatedText: "Tengo una pregunta."
                ),
            ]
        )

        #expect(session.sourceTextForCopy(source: .macAudio) == "[00:00] Mac Audio: Welcome.")
        #expect(session.translatedTextForCopy(source: .macAudio) == "[00:00] Mac Audio: Bienvenido.")
        #expect(session.bilingualTextForCopy(source: .microphone) == """
        [00:05] Microphone: I have a question.
        [00:05] Microphone: Tengo una pregunta.
        """)
    }

    @Test("iPhone audio history defaults to microphone captions")
    func iPhoneAudioHistoryDefaultsToMicrophoneCaptions() {
        let session = RealtimeHistorySession(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: "iPhone Audio",
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(offset: 0, sourceText: "Welcome.", translatedText: "Bienvenido."),
            ]
        )

        #expect(session.primaryAudioSource == .microphone)
        #expect(session.sourceTextForCopy(source: .microphone) == "[00:00] Microphone: Welcome.")
    }

    @Test("Stable input source identity does not depend on localized display text")
    func stableInputSourceIdentityIgnoresDisplayText() throws {
        let session = RealtimeHistorySession(
            requestID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            duration: 20,
            inputSource: "Audio du Mac",
            inputSourceID: .macAudio,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: []
        )

        let decoded = try JSONDecoder().decode(
            RealtimeHistorySession.self,
            from: JSONEncoder().encode(session)
        )

        #expect(decoded.inputSourceID == .macAudio)
        #expect(decoded.primaryAudioSource == .macAudio)
    }
}
