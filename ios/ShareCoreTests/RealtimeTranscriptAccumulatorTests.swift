//
//  RealtimeTranscriptAccumulatorTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("RealtimeTranscriptAccumulator")
struct RealtimeTranscriptAccumulatorTests {
    @Test("Canonical snapshots replace the full transcript without replay")
    func canonicalSnapshotsReplaceWithoutReplay() {
        var accumulator = RealtimeTranscriptAccumulator()
        let earlier = "Graduation ceremony. Well I remember this. That was five years ago."

        _ = accumulator.append(
            RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableText: earlier,
                volatileText: "I graduated from my high school"
            )),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                stableText: "\(earlier) I graduated from my high school.",
                volatileText: "And I remember my teacher"
            )),
            afterLongSilence: false
        )

        #expect(result == "\(earlier) I graduated from my high school. And I remember my teacher")
        #expect(result.components(separatedBy: "Graduation ceremony.").count == 2)
        #expect(!result.contains("\n"))
    }

    @Test("Extends partial recognition without duplicating earlier words")
    func extendsPartialRecognition() {
        var accumulator = RealtimeTranscriptAccumulator()

        let first = accumulator.append("hello", afterLongSilence: false)
        let second = accumulator.append("hello world", afterLongSilence: false)

        #expect(first == "hello")
        #expect(second == "hello world")
        #expect(accumulator.visibleText == "hello world")
    }

    @Test("Splits cumulative partial recognition after long silence")
    func splitsCumulativePartialRecognitionAfterLongSilence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "hello", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "hello world", confidence: 0.5, state: .partial),
            afterLongSilence: true
        )

        #expect(result == "hello\n\nworld")
        #expect(accumulator.committedText == "hello")
        #expect(accumulator.partialText == "world")
    }

    @Test("Does not duplicate repeated partial recognition after long silence")
    func doesNotDuplicateRepeatedPartialRecognitionAfterLongSilence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "hello", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "hello", confidence: 0.5, state: .partial),
            afterLongSilence: true
        )

        #expect(result == "hello")
        #expect(accumulator.committedText == "hello")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Drops committed tail overlap after long silence")
    func dropsCommittedTailOverlapAfterLongSilence() {
        var accumulator = RealtimeTranscriptAccumulator(
            committedText: """
            Uploaded.

            I decided to leave my software engineering job at Google.

            I wanted to talk about that today.
            """,
            partialText: ""
        )

        let result = accumulator.append(
            """
            I decided to leave my software engineering job at Google. I wanted to talk about that today. So the first reason
            """,
            afterLongSilence: true
        )

        #expect(result == """
        Uploaded.

        I decided to leave my software engineering job at Google.

        I wanted to talk about that today.

        So the first reason
        """)
        #expect(accumulator.committedText == """
        Uploaded.

        I decided to leave my software engineering job at Google.

        I wanted to talk about that today.
        """)
        #expect(accumulator.partialText == "So the first reason")
    }

    @Test("Replaces revised cumulative partial after long silence")
    func replacesRevisedCumulativePartialAfterLongSilence() {
        var accumulator = RealtimeTranscriptAccumulator(
            committedText: "And that's really kind of\n\nwhat it came down to.",
            partialText: "Uh I didn't really feel a lot of passion for the things that I was doing and that is true"
        )

        let result = accumulator.append(
            """
            Uh, I didn't really feel a lot of passion for the things that I was doing, and that is true at Google.
            """,
            afterLongSilence: true
        )

        #expect(result == """
        And that's really kind of

        what it came down to.

        Uh, I didn't really feel a lot of passion for the things that I was doing, and that is true at Google.
        """)
        #expect(accumulator.committedText == "And that's really kind of\n\nwhat it came down to.")
        #expect(accumulator.partialText == """
        Uh, I didn't really feel a lot of passion for the things that I was doing, and that is true at Google.
        """)
    }

    @Test("Splits Chinese cumulative partial recognition after long silence")
    func splitsChineseCumulativePartialRecognitionAfterLongSilence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "绿色地冰先生", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "绿色地冰先生也许我的一", confidence: 0.5, state: .partial),
            afterLongSilence: true
        )

        #expect(result == "绿色地冰先生\n\n也许我的一")
        #expect(accumulator.committedText == "绿色地冰先生")
        #expect(accumulator.partialText == "也许我的一")
    }

    @Test("Final recognition after long silence does not duplicate the partial")
    func finalRecognitionAfterLongSilenceDoesNotDuplicatePartial() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "hello", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "hello world", confidence: 0.9, state: .final),
            afterLongSilence: true
        )

        #expect(result == "hello world")
        #expect(accumulator.committedText == "hello world")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Final cumulative snapshots replace the previous committed segment")
    func finalCumulativeSnapshotsReplacePreviousCommittedSegment() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "who", confidence: 0.5, state: .final),
            afterLongSilence: false
        )
        let second = accumulator.append(
            RealtimeRecognitionResult(text: "who was", confidence: 0.5, state: .final),
            afterLongSilence: false
        )
        let third = accumulator.append(
            RealtimeRecognitionResult(text: "who was walking", confidence: 0.5, state: .final),
            afterLongSilence: false
        )

        #expect(second == "who was")
        #expect(third == "who was walking")
        #expect(accumulator.committedText == "who was walking")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Final cumulative snapshot replaces committed segment after matching partial")
    func finalCumulativeSnapshotReplacesCommittedSegmentAfterMatchingPartial() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "I I may", confidence: 0.5, state: .final),
            afterLongSilence: false
        )
        _ = accumulator.append(
            RealtimeRecognitionResult(text: "I I may Twitter", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "I I may Twitter", confidence: 0.5, state: .final),
            afterLongSilence: false
        )

        #expect(result == "I I may Twitter")
        #expect(accumulator.committedText == "I I may Twitter")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Partial cumulative snapshot replaces previous committed segment")
    func partialCumulativeSnapshotReplacesPreviousCommittedSegment() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "巴西", confidence: 0.5, state: .final),
            afterLongSilence: false
        )
        let partial = accumulator.append(
            RealtimeRecognitionResult(text: "巴西原", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        let final = accumulator.append(
            RealtimeRecognitionResult(text: "巴西原", confidence: 0.5, state: .final),
            afterLongSilence: false
        )

        #expect(partial == "巴西原")
        #expect(final == "巴西原")
        #expect(accumulator.committedText == "巴西原")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Final cumulative snapshot keeps unfinished partial suffix")
    func finalCumulativeSnapshotKeepsUnfinishedPartialSuffix() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "I I may Twitter Where", confidence: 0.5, state: .final),
            afterLongSilence: false
        )
        _ = accumulator.append(
            RealtimeRecognitionResult(text: "I I may Twitter Where here technical", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "I I may Twitter Where here", confidence: 0.5, state: .final),
            afterLongSilence: false
        )

        #expect(result == "I I may Twitter Where here\n\ntechnical")
        #expect(accumulator.committedText == "I I may Twitter Where here")
        #expect(accumulator.partialText == "technical")
    }

    @Test("Azure cumulative snapshots keep committed prefix and pending suffix")
    func azureCumulativeSnapshotsKeepCommittedPrefixAndPendingSuffix() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "已经 everyone", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        _ = accumulator.append(
            RealtimeRecognitionResult(text: "已经", confidence: 0.5, state: .final),
            afterLongSilence: false
        )
        let partial = accumulator.append(
            RealtimeRecognitionResult(text: "已经 everyone is", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        _ = accumulator.append(
            RealtimeRecognitionResult(text: "已经 everyone", confidence: 0.5, state: .final),
            afterLongSilence: false
        )
        let final = accumulator.append(
            RealtimeRecognitionResult(text: "已经 everyone is by", confidence: 0.5, state: .final),
            afterLongSilence: false
        )

        #expect(partial == "已经\n\neveryone is")
        #expect(final == "已经 everyone is by")
        #expect(accumulator.committedText == "已经 everyone is by")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Commits previous partial after long silence")
    func commitsAfterLongSilence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("hello world", afterLongSilence: false)
        let result = accumulator.append("good morning", afterLongSilence: true)

        #expect(result == "hello world\n\ngood morning")
        #expect(accumulator.visibleText == "hello world\n\ngood morning")
    }

    @Test("Commits previous partial when recognition starts a new phrase")
    func commitsWhenRecognitionStartsNewPhrase() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("hello world", afterLongSilence: false)
        let result = accumulator.append("good morning", afterLongSilence: false)

        #expect(result == "hello world\n\ngood morning")
        #expect(accumulator.visibleText == "hello world\n\ngood morning")
    }

    @Test("Replaces case-only recognition revisions without duplicating the sentence")
    func replacesCaseOnlyRecognitionRevisions() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("where is it?", afterLongSilence: false)
        let result = accumulator.append("Where is it?", afterLongSilence: false)

        #expect(result == "Where is it?")
        #expect(accumulator.visibleText == "Where is it?")
    }

    @Test("Replaces same-sentence recognition corrections without duplicating the sentence")
    func replacesSameSentenceRecognitionCorrections() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("This is the Sec sauce.", afterLongSilence: false)
        let result = accumulator.append("This is the secret sauce.", afterLongSilence: false)

        #expect(result == "This is the secret sauce.")
        #expect(accumulator.visibleText == "This is the secret sauce.")
    }

    @Test("Keeps short Chinese recognition revisions in the same partial sentence")
    func keepsShortChineseRecognitionRevisionsInSamePartialSentence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("绿色地冰线", afterLongSilence: false)
        let result = accumulator.append("绿色地冰先生", afterLongSilence: false)

        #expect(result == "绿色地冰先生")
        #expect(accumulator.committedText.isEmpty)
        #expect(accumulator.partialText == "绿色地冰先生")
    }

    @Test("Keeps Chinese realtime revisions in one sentence until final recognition")
    func keepsChineseRealtimeRevisionsInOneSentenceUntilFinalRecognition() {
        var accumulator = RealtimeTranscriptAccumulator()

        func appendPartial(_ text: String) {
            _ = accumulator.append(
                RealtimeRecognitionResult(text: text, confidence: 0.5, state: .partial),
                afterLongSilence: false
            )
        }

        appendPartial("绿色地冰线")
        appendPartial("绿色地冰先生")
        appendPartial("绿色地平先生我")
        appendPartial("绿色地平先生我专")
        appendPartial("绿色地平先生我穿着")
        appendPartial("绿色地平先生我穿着这次")
        appendPartial("绿色地平先生我穿着这次堕落")
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "绿色地冰先生我穿着这次堕落", confidence: 0.9, state: .final),
            afterLongSilence: false
        )

        #expect(result == "绿色地冰先生我穿着这次堕落")
        #expect(accumulator.committedText == "绿色地冰先生我穿着这次堕落")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Final Chinese cumulative snapshots replace the previous committed segment")
    func finalChineseCumulativeSnapshotsReplacePreviousCommittedSegment() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "绿色地平先生我穿着这次堕落", confidence: 0.9, state: .final),
            afterLongSilence: false
        )
        let result = accumulator.append(
            RealtimeRecognitionResult(text: "绿色地冰先生我穿着这次堕落", confidence: 0.9, state: .final),
            afterLongSilence: false
        )

        #expect(result == "绿色地冰先生我穿着这次堕落")
        #expect(accumulator.committedText == "绿色地冰先生我穿着这次堕落")
        #expect(accumulator.partialText.isEmpty)
    }

    @Test("Commits unrelated Chinese partial recognition as a new phrase")
    func commitsUnrelatedChinesePartialRecognitionAsNewPhrase() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("绿色地冰先生", afterLongSilence: false)
        let result = accumulator.append("也许我的一", afterLongSilence: false)

        #expect(result == "绿色地冰先生\n\n也许我的一")
        #expect(accumulator.committedText == "绿色地冰先生")
        #expect(accumulator.partialText == "也许我的一")
    }

    @Test("Keeps partial recognition out of translation source")
    func keepsPartialRecognitionOutOfTranslationSource() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("I think this works. However I am not done", afterLongSilence: false)

        #expect(accumulator.translationSourceText.isEmpty)
        #expect(accumulator.pendingSentenceText == "I think this works. However I am not done")
    }

    @Test("Treats committed text as translation source after silence")
    func treatsCommittedTextAsTranslationSourceAfterSilence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("hello world", afterLongSilence: false)
        _ = accumulator.append("good morning", afterLongSilence: true)

        #expect(accumulator.translationSourceText == "hello world")
        #expect(accumulator.pendingSentenceText == "good morning")
    }

    @Test("Commits current partial when silence closes sentence")
    func commitsCurrentPartialWhenSilenceClosesSentence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append("hello world", afterLongSilence: false)
        let result = accumulator.commitPartial()

        #expect(result == "hello world")
        #expect(accumulator.translationSourceText == "hello world")
        #expect(accumulator.pendingSentenceText.isEmpty)
    }

    @Test("Final recognition commits text while partial recognition remains pending")
    func finalRecognitionCommitsTextWhilePartialRecognitionRemainsPending() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "hello wor", confidence: 0.5, state: .partial),
            afterLongSilence: false
        )
        #expect(accumulator.visibleText == "hello wor")
        #expect(accumulator.committedText.isEmpty)
        #expect(accumulator.partialText == "hello wor")

        _ = accumulator.append(
            RealtimeRecognitionResult(text: "hello world", confidence: 0.9, state: .final),
            afterLongSilence: false
        )
        #expect(accumulator.visibleText == "hello world")
        #expect(accumulator.committedText == "hello world")
        #expect(accumulator.partialText.isEmpty)
    }
}
