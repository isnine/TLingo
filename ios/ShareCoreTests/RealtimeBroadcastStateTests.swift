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
        @Test("A late startup and duplicate stop cannot restart a drained pipeline")
        func stoppedPipelineRejectsLateStartup() async throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)
            let sessionID = UUID().uuidString
            store.reset(sessionID: sessionID, phase: .waiting)
            let pipeline = RealtimeLocalSpeechTranslationPipeline(stateStore: store, sessionID: sessionID)
            let completion = RealtimeBroadcastCompletion(store: store, sessionID: sessionID)
            await completion.finish { await pipeline.stop() }.value
            let terminal = try #require(store.load())
            #expect(terminal.phase == .stopped)
            // Invalid languages ensure this test cannot start real recognition even if the guard regresses.
            try await pipeline.start(sourceLanguage: .auto, targetLanguage: .appLanguage)
            await pipeline.stop()
            #expect(store.load() == terminal)
        }

        @Test("An abandoned broadcast drain is a failure, not a successful stop")
        func staleDrainIsActiveFailure() {
            let state = RealtimeBroadcastState(phase: .stopping)
            #expect(RealtimeSessionStore.isStaleActiveIPhoneAudioBroadcast(state))
        }

        @Test(
            "Broadcast completion publishes terminal state only after the production drain",
            arguments: [nil, "Recognition failed"] as [String?]
        )
        func completionWaitsForDrain(errorMessage: String?) async throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)
            store.reset(sessionID: "first", phase: .recognizing)
            let completion = RealtimeBroadcastCompletion(store: store, sessionID: "first")
            let task = completion.finish(errorMessage: errorMessage) {
                #expect(store.load()?.phase == .stopping)
                store.update { state in
                    state.phase = .translating
                    state.sourceText = "Final sentence."
                    state.translatedText = "Final translation."
                    state.realtimeHistorySession = RealtimeHistorySession(
                        requestID: UUID(),
                        startedAt: Date(),
                        endedAt: Date(),
                        duration: 1,
                        inputSource: "iPhone Audio",
                        sourceLanguage: "English",
                        targetLanguage: "Spanish",
                        modelID: "test",
                        modelDisplayName: "Test",
                        segments: [RealtimeHistorySegment(
                            offset: 0,
                            sourceText: "Final sentence.",
                            translatedText: "Final translation."
                        )]
                    )
                }
                #expect(store.load()?.phase == .stopping)
            }
            await task.value
            let terminal = try #require(store.load())
            #expect(terminal.phase == (errorMessage == nil ? .stopped : .failed))
            #expect(terminal.errorMessage == errorMessage)
            #expect(terminal.realtimeHistorySession?.segments.last?.sourceText == "Final sentence.")
            await completion.finish {
                Issue.record("A duplicate callback must not drain twice")
            }.value
            #expect(store.load() == terminal)
        }

        @Test("A bounded completion wait does not declare success or touch a newer session")
        func completionTimeoutAndSessionFence() async throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)
            store.reset(sessionID: "old", phase: .recognizing)
            let staleSnapshot = try #require(store.load())
            let completion = RealtimeBroadcastCompletion(store: store, sessionID: "old")
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let task = completion.finish {
                for await _ in stream {
                    break
                }
                store.save(staleSnapshot)
            }
            #expect(completion.waitForDrain(timeout: 0) == false)
            #expect(store.load()?.phase == .stopping)
            store.reset(sessionID: "new", phase: .broadcasting)
            store.requestStop()
            continuation.yield()
            continuation.finish()
            await task.value
            #expect(completion.waitForDrain(timeout: 0))
            #expect(store.load()?.sessionID == "new")
            #expect(store.load()?.phase == .stopping)
            #expect(store.load()?.stopRequested == true)
        }

        @Test("Producer snapshots cannot overwrite the host stop command")
        func producerCannotOverwriteStop() throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let host = RealtimeBroadcastStateStore(defaults: defaults)
            let producer = try RealtimeBroadcastStateStore(defaults: #require(UserDefaults(suiteName: suiteName)))
            host.reset(sessionID: "first", phase: .broadcasting)
            var staleSnapshot = try #require(producer.load())
            host.requestStop()
            staleSnapshot.audioSampleCount = 10
            producer.save(staleSnapshot)
            #expect(host.load()?.stopRequested == true)
            #expect(host.load()?.phase == .stopping)
            #expect(host.load()?.audioSampleCount == 10)
        }

        @Test("A stop arriving between a producer read and write is not lost", arguments: [false, true])
        func stopDuringProducerWrite(replaceSession: Bool) throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let producerDefaults = try #require(InterleavingBroadcastDefaults(suiteName: suiteName))
            let host = RealtimeBroadcastStateStore(defaults: defaults)
            let producer = RealtimeBroadcastStateStore(defaults: producerDefaults)
            host.reset(sessionID: "first", phase: .broadcasting)
            let snapshot = try #require(producer.load())
            producerDefaults.beforeDataWrite = {
                if replaceSession {
                    host.reset(sessionID: "new", phase: .broadcasting)
                }
                host.requestStop()
            }
            producer.save(snapshot)
            #expect(producerDefaults.beforeDataWrite == nil)
            #expect(host.load()?.sessionID == (replaceSession ? "new" : "first"))
            #expect(host.load()?.stopRequested == true)
            #expect(host.load()?.phase == .stopping)
        }

        @Test("Acknowledging one stop never clears a newer stop")
        func acknowledgementPreservesNewerStop() throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let producerDefaults = try #require(InterleavingBroadcastDefaults(suiteName: suiteName))
            let host = RealtimeBroadcastStateStore(defaults: defaults)
            let producer = RealtimeBroadcastStateStore(defaults: producerDefaults)
            host.reset(sessionID: "first", phase: .broadcasting)
            host.requestStop()
            producerDefaults.beforeAcknowledgement = { host.requestStop() }
            producer.clearStopRequested()
            #expect(producerDefaults.beforeAcknowledgement == nil)
            #expect(host.load()?.stopRequested == true)
            producer.clearStopRequested()
            #expect(host.load()?.stopRequested == false)
        }

        @Test("Old producers cannot replace a new session or clear its stop command")
        func oldProducerCannotReplaceNewSession() throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)
            store.reset(sessionID: "old", phase: .broadcasting)
            var oldSnapshot = try #require(store.load())
            store.reset(sessionID: "new", phase: .broadcasting)
            store.requestStop()
            oldSnapshot.markBroadcastFinished()
            store.save(oldSnapshot)
            #expect(store.load()?.sessionID == "new")
            #expect(store.load()?.stopRequested == true)
        }

        @Test("Late producer callbacks cannot resurrect a terminal session")
        func terminalCannotBeResurrected() throws {
            let suiteName = "RealtimeBroadcastStateTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = RealtimeBroadcastStateStore(defaults: defaults)
            store.reset(sessionID: "first", phase: .broadcasting)
            let staleSnapshot = try #require(store.load())
            var terminal = staleSnapshot
            terminal.markBroadcastFinished()
            store.save(terminal)
            store.save(staleSnapshot)
            #expect(store.load()?.phase == .stopped)
        }

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

        @Test("Marks a drained broadcast terminal")
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

    private final class InterleavingBroadcastDefaults: UserDefaults, @unchecked Sendable {
        var beforeDataWrite: (() -> Void)?
        var beforeAcknowledgement: (() -> Void)?

        override func set(_ value: Any?, forKey defaultName: String) {
            if value is Data, let callback = beforeDataWrite {
                beforeDataWrite = nil
                callback()
            }
            if defaultName.hasSuffix(".stopAcknowledged"), let callback = beforeAcknowledgement {
                beforeAcknowledgement = nil
                callback()
            }
            super.set(value, forKey: defaultName)
        }
    }
#endif
