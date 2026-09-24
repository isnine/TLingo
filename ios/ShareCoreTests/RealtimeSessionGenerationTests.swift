//
//  RealtimeSessionGenerationTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("Realtime session generation")
    struct RealtimeSessionGenerationTests {
        @Test("Accepts callback from active session")
        func acceptsActiveSessionCallback() {
            let sessionID = UUID()

            #expect(RealtimeSessionStore.shouldAcceptRealtimeCallback(
                sessionID: sessionID,
                activeSessionID: sessionID,
                isStopping: false
            ))
        }

        @Test("Rejects callback from stale session")
        func rejectsStaleSessionCallback() {
            #expect(!RealtimeSessionStore.shouldAcceptRealtimeCallback(
                sessionID: UUID(),
                activeSessionID: UUID(),
                isStopping: false
            ))
        }

        @Test("Rejects callback while stopping")
        func rejectsCallbackWhileStopping() {
            let sessionID = UUID()

            #expect(!RealtimeSessionStore.shouldAcceptRealtimeCallback(
                sessionID: sessionID,
                activeSessionID: sessionID,
                isStopping: true
            ))
        }

        @Test("Accepts active callback while its producer is draining")
        func acceptsActiveCallbackDuringDrain() {
            let sessionID = UUID()

            #expect(RealtimeSessionStore.shouldAcceptRealtimeCallbackDuringDrain(
                sessionID: sessionID,
                activeSessionID: sessionID,
                isStopping: true,
                drainingSessionID: sessionID
            ))
        }

        @Test("Rejects stale callback while another producer is draining")
        func rejectsStaleCallbackDuringDrain() {
            #expect(!RealtimeSessionStore.shouldAcceptRealtimeCallbackDuringDrain(
                sessionID: UUID(),
                activeSessionID: UUID(),
                isStopping: true,
                drainingSessionID: UUID()
            ))
        }

        @Test("Callback drain completes after registered callback leaves")
        func callbackDrainCompletesAfterLeave() async {
            let drain = RealtimeCallbackDrain()
            drain.enter()

            let waiter = Task {
                await drain.wait()
                return true
            }
            await Task.yield()
            drain.leave()

            #expect(await waiter.value)
        }

        @MainActor
        @Test("Failure callback can await stop drain without joining itself")
        func failureCallbackDoesNotJoinDrain() async {
            let drain = RealtimeCallbackDrain()

            let failureTask = drain.untrackedMainActorTask {
                await drain.wait()
            }

            await failureTask.value
        }

        @Test("Live speech rejects stale callback before mutating failure state")
        func liveSpeechRejectsStaleCallback() {
            #expect(!RealtimeLiveSpeechTranscriber.shouldAcceptCallback(
                sessionID: UUID(),
                activeSessionID: UUID(),
                isStopping: false
            ))
        }
    }
#endif
