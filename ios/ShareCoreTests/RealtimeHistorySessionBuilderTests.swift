//
//  RealtimeHistorySessionBuilderTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("RealtimeHistorySessionBuilder")
struct RealtimeHistorySessionBuilderTests {
    @Test("Records offsets and keeps them across translation updates")
    func recordsOffsetsAndKeepsThemAcrossUpdates() {
        var builder = RealtimeHistorySessionBuilder()
        builder.start(at: Date(timeIntervalSince1970: 100))

        builder.sync(
            pairs: [SentencePair(original: "Hello.", translation: "Hola.")],
            at: Date(timeIntervalSince1970: 112)
        )
        let firstID = builder.segments[0].id

        builder.sync(
            pairs: [SentencePair(original: "Hello.", translation: "Hola!")],
            at: Date(timeIntervalSince1970: 120)
        )

        #expect(builder.segments[0].id == firstID)
        #expect(builder.segments[0].offset == 12)
        #expect(builder.segments[0].translatedText == "Hola!")
    }

    @Test("Replaces revised tail without moving its timestamp")
    func replacesRevisedTailWithoutMovingTimestamp() {
        var builder = RealtimeHistorySessionBuilder()
        builder.start(at: Date(timeIntervalSince1970: 100))
        builder.sync(
            pairs: [
                SentencePair(original: "Hello.", translation: "Hola."),
                SentencePair(original: "Good morning.", translation: "Buenos dias."),
            ],
            at: Date(timeIntervalSince1970: 130)
        )
        let tailID = builder.segments[1].id

        builder.sync(
            pairs: [
                SentencePair(original: "Hello.", translation: "Hola."),
                SentencePair(original: "Good day.", translation: "Buen dia."),
            ],
            at: Date(timeIntervalSince1970: 145)
        )

        #expect(builder.segments[1].id == tailID)
        #expect(builder.segments[1].offset == 30)
        #expect(builder.segments[1].sourceText == "Good day.")
        #expect(builder.segments[1].translatedText == "Buen dia.")
    }

    @Test("Stores each sentence pair as a separate segment")
    func storesEachSentencePairAsSeparateSegment() {
        var builder = RealtimeHistorySessionBuilder()
        builder.start(at: Date(timeIntervalSince1970: 100))

        builder.sync(
            pairs: [
                SentencePair(original: "First.", translation: "Primero."),
                SentencePair(original: "Second?", translation: "Segundo?"),
            ],
            at: Date(timeIntervalSince1970: 130)
        )

        #expect(builder.segments.map(\.sourceText) == ["First.", "Second?"])
        #expect(builder.segments.map(\.translatedText) == ["Primero.", "Segundo?"])
    }

    @Test("Excludes paused time from offsets")
    func excludesPausedTimeFromOffsets() {
        var builder = RealtimeHistorySessionBuilder()
        builder.start(at: Date(timeIntervalSince1970: 100))
        builder.pause(at: Date(timeIntervalSince1970: 110))
        builder.resume(at: Date(timeIntervalSince1970: 160))
        builder.sync(
            pairs: [SentencePair(original: "Ready.", translation: "Listo.")],
            at: Date(timeIntervalSince1970: 170)
        )

        #expect(builder.segments[0].offset == 20)
    }

    @Test("Places sentences at recognizer audio time, in order, after the timeline base")
    func placesSentencesAtRecognizerAudioTime() {
        var builder = RealtimeHistorySessionBuilder()
        builder.start(at: Date(timeIntervalSince1970: 100), recognitionTimelineBase: 1)
        builder.noteRecognition(timings: [
            RealtimeRecognitionTokenTiming(token: "Stale", startTime: 0.2, endTime: 0.8, confidence: 1),
            RealtimeRecognitionTokenTiming(token: "Hello,", startTime: 2, endTime: 2.5, confidence: 1),
            RealtimeRecognitionTokenTiming(token: " hello.", startTime: 2.5, endTime: 3, confidence: 1),
            RealtimeRecognitionTokenTiming(token: " Hello", startTime: 5, endTime: 5.5, confidence: 1),
            RealtimeRecognitionTokenTiming(token: " again.", startTime: 5.5, endTime: 6, confidence: 1),
        ])

        builder.sync(
            pairs: [
                SentencePair(original: "Hello, hello.", translation: "你好，你好。"),
                SentencePair(original: "Hello again.", translation: "又见面了。"),
            ],
            at: Date(timeIntervalSince1970: 110)
        )

        #expect(builder.segments.map(\.offset) == [1, 4])
    }
}
