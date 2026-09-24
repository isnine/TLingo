//
//  RealtimeHistoryCheckpointTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("RealtimeHistoryCheckpoint")
struct RealtimeHistoryCheckpointTests {
    @Test("Creates a snapshot from the first complete realtime transcript")
    func snapshotsFirstCompleteTranscript() throws {
        var checkpoint = RealtimeHistoryCheckpoint()

        let snapshot = checkpoint.snapshot(
            sourceText: "hello world",
            translatedText: "hola mundo"
        )
        try checkpoint.acknowledge(#require(snapshot))

        #expect(snapshot?.sourceText == "hello world")
        #expect(snapshot?.translatedText == "hola mundo")
    }

    @Test("Returns only text added after the previous snapshot")
    func snapshotsOnlyNewTranscriptText() throws {
        var checkpoint = RealtimeHistoryCheckpoint()

        let firstSnapshot = checkpoint.snapshot(
            sourceText: "hello world",
            translatedText: "hola mundo"
        )
        try checkpoint.acknowledge(#require(firstSnapshot))
        let snapshot = checkpoint.snapshot(
            sourceText: "hello world\n\ngood morning",
            translatedText: "hola mundo\n\nbuenos dias"
        )

        #expect(snapshot?.sourceText == "good morning")
        #expect(snapshot?.translatedText == "buenos dias")
    }

    @Test("Does not snapshot unchanged transcript text")
    func skipsUnchangedTranscriptText() throws {
        var checkpoint = RealtimeHistoryCheckpoint()

        let firstSnapshot = checkpoint.snapshot(
            sourceText: "hello world",
            translatedText: "hola mundo"
        )
        try checkpoint.acknowledge(#require(firstSnapshot))
        let snapshot = checkpoint.snapshot(
            sourceText: "hello world",
            translatedText: "hola mundo"
        )

        #expect(snapshot == nil)
    }

    @Test("Retries an unchanged snapshot until persistence is acknowledged")
    func retriesSnapshotAfterFailedPersistence() throws {
        var checkpoint = RealtimeHistoryCheckpoint()

        let firstAttempt = try #require(checkpoint.snapshot(
            sourceText: "hello world",
            translatedText: "hola mundo"
        ))
        let retry = try #require(checkpoint.snapshot(
            sourceText: "hello world",
            translatedText: "hola mundo"
        ))

        #expect(retry == firstAttempt)

        checkpoint.acknowledge(retry)
        #expect(checkpoint.snapshot(
            sourceText: "hello world",
            translatedText: "hola mundo"
        ) == nil)
    }
}
