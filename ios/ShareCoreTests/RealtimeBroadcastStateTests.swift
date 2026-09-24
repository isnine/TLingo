//
//  RealtimeBroadcastStateTests.swift
//  ShareCoreTests
//

#if os(iOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("RealtimeBroadcastState")
    struct RealtimeBroadcastStateTests {
        @Test("Round trips through defaults storage")
        func roundTripsThroughDefaultsStorage() throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)
            let state = RealtimeBroadcastState(
                sessionID: "session-1",
                phase: .translating,
                sourceText: "Hello world.",
                translatedText: "Hola mundo.",
                translationSourceText: "Hello",
                sentencePairs: [SentencePair(original: "Hello", translation: "Hola")],
                pendingSourceText: "world.",
                pendingTranslatedText: "mundo.",
                audioSampleCount: 12,
                audioLevel: -18,
                errorMessage: nil,
                lastUpdatedAt: Date(timeIntervalSince1970: 100),
                stopRequested: false
            )

            store.save(state)

            #expect(store.load() == state)
        }

        @Test("Decodes legacy state without incremental caption fields")
        func decodesLegacyStateWithoutIncrementalCaptionFields() throws {
            let data = Data("""
            {
              "sessionID": "legacy-session",
              "phase": "recognizing",
              "sourceText": "Hello world.",
              "translatedText": "Hola mundo.",
              "audioSampleCount": 3,
              "lastUpdatedAt": 100,
              "stopRequested": false
            }
            """.utf8)

            let state = try JSONDecoder().decode(RealtimeBroadcastState.self, from: data)

            #expect(state.translationSourceText == "Hello world.")
            #expect(state.sentencePairs.isEmpty)
            #expect(state.pendingSourceText.isEmpty)
            #expect(state.pendingTranslatedText.isEmpty)
            #expect(state.realtimeHistorySession == nil)
        }

        @Test("Round trips realtime history session")
        func roundTripsRealtimeHistorySession() throws {
            let session = RealtimeHistorySession(
                requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 112),
                duration: 12,
                inputSource: "iPhone Audio",
                sourceLanguage: "English",
                targetLanguage: "Spanish",
                modelID: "apple-translate",
                modelDisplayName: "Apple Translate",
                segments: [
                    RealtimeHistorySegment(offset: 12, sourceText: "Hello.", translatedText: "Hola."),
                ]
            )
            let state = RealtimeBroadcastState(
                sessionID: "session-1",
                phase: .stopped,
                realtimeHistorySession: session
            )

            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(RealtimeBroadcastState.self, from: data)

            #expect(decoded.realtimeHistorySession == session)
        }

        @Test("Detects stale state")
        func detectsStaleState() {
            let state = RealtimeBroadcastState(
                sessionID: "session-1",
                phase: .broadcasting,
                lastUpdatedAt: Date(timeIntervalSince1970: 100)
            )

            #expect(!state.isStale(referenceDate: Date(timeIntervalSince1970: 104), timeout: 5))
            #expect(state.isStale(referenceDate: Date(timeIntervalSince1970: 106), timeout: 5))
        }

        @Test("Marks stop requested without losing transcript")
        func marksStopRequestedWithoutLosingTranscript() throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)
            store.save(RealtimeBroadcastState(
                sessionID: "session-1",
                phase: .recognizing,
                sourceText: "Hello",
                translatedText: "Hola",
                audioSampleCount: 4,
                lastUpdatedAt: Date(timeIntervalSince1970: 100)
            ))

            store.requestStop()

            let updated = try #require(store.load())
            #expect(updated.stopRequested)
            #expect(updated.phase == .stopping)
            #expect(updated.sourceText == "Hello")
            #expect(updated.translatedText == "Hola")
        }

        @Test("Round trips paused broadcast state")
        func roundTripsPausedBroadcastState() throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)

            store.save(RealtimeBroadcastState(sessionID: "session-1", phase: .paused))

            let updated = try #require(store.load())
            #expect(updated.phase == .paused)
        }

        @Test("Broadcast finish writes terminal state synchronously")
        func broadcastFinishWritesTerminalState() {
            var state = RealtimeBroadcastState(
                phase: .recognizing,
                stopRequested: true
            )

            state.markBroadcastFinished()

            #expect(state.phase == .stopped)
            #expect(!state.stopRequested)
        }

        @Test("Broadcast finish preserves failure terminal state")
        func broadcastFinishPreservesFailure() {
            var state = RealtimeBroadcastState(
                phase: .failed,
                errorMessage: "Failure",
                stopRequested: true
            )

            state.markBroadcastFinished()

            #expect(state.phase == .failed)
            #expect(state.errorMessage == "Failure")
            #expect(!state.stopRequested)
        }
    }
#endif
