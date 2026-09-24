//
//  RealtimeCaptionDisplayTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("RealtimeCaptionDisplay")
struct RealtimeCaptionDisplayTests {
    @Test("Cycles through source, translation, and bilingual modes")
    func cyclesThroughCaptionModes() {
        #expect(RealtimeCaptionDisplayMode.sourceOnly.next == .translationOnly)
        #expect(RealtimeCaptionDisplayMode.translationOnly.next == .bilingual)
        #expect(RealtimeCaptionDisplayMode.bilingual.next == .sourceOnly)
    }

    @Test("Uses visually distinct caption mode icons")
    func usesVisuallyDistinctCaptionModeIcons() {
        #expect(RealtimeCaptionDisplayMode.sourceOnly.systemImageName == "quote.bubble")
        #expect(RealtimeCaptionDisplayMode.translationOnly.systemImageName == "quote.bubble")
        #expect(RealtimeCaptionDisplayMode.bilingual.systemImageName == "translate")
    }

    @Test("Uses selected language names for single-language caption mode titles")
    func usesSelectedLanguageNamesForSingleLanguageCaptionModeTitles() {
        #expect(
            RealtimeCaptionDisplayMode.sourceOnly.buttonTitle(
                sourceLanguageName: "English",
                targetLanguageName: "日本語"
            ) == "English"
        )
        #expect(
            RealtimeCaptionDisplayMode.translationOnly.buttonTitle(
                sourceLanguageName: "English",
                targetLanguageName: "日本語"
            ) == "日本語"
        )
        #expect(
            RealtimeCaptionDisplayMode.bilingual.buttonTitle(
                sourceLanguageName: "English",
                targetLanguageName: "日本語"
            ) == nil
        )
    }

    @Test("Limits caption display window to the latest lines")
    func limitsCaptionDisplayWindowToLatestLines() {
        let lines = (0 ..< 6).map { index in
            RealtimeCaptionLine(id: "\(index)", kind: .source, text: "Line \(index)")
        }

        let window = RealtimeCaptionDisplay.displayWindow(lines, limit: 3)

        #expect(window.map(\.text) == ["Line 3", "Line 4", "Line 5"])
    }

    @Test("Builds alternating source and translation lines from sentence pairs")
    func buildsAlternatingLines() {
        let firstPair = SentencePair(
            original: "I think people should talk about what has worked for them.",
            translation: "我认为人们应该谈论什么对他们有用。"
        )
        let secondPair = SentencePair(
            original: "However, I don't think people should propose something as the absolute best technique.",
            translation: "然而，我认为人们不应该把某种方法说成绝对最好的技巧。"
        )

        let lines = RealtimeCaptionDisplay.lines(from: [firstPair, secondPair])

        #expect(lines.count == 4)
        #expect(lines.map(\.kind) == [.source, .translation, .source, .translation])
        #expect(lines[0].text == "I think people should talk about what has worked for them.")
        #expect(lines[1].text == "我认为人们应该谈论什么对他们有用。")
        #expect(lines[2].text == "However, I don't think people should propose something as the absolute best technique.")
        #expect(lines[3].text == "然而，我认为人们不应该把某种方法说成绝对最好的技巧。")
    }

    @Test("Filters caption lines by display mode")
    func filtersLinesByDisplayMode() {
        let pair = SentencePair(
            original: "I think people should talk about what has worked for them.",
            translation: "我认为人们应该谈论什么对他们有用。"
        )

        let sourceOnlyLines = RealtimeCaptionDisplay.lines(from: [pair], mode: .sourceOnly)
        let translationOnlyLines = RealtimeCaptionDisplay.lines(from: [pair], mode: .translationOnly)
        let bilingualLines = RealtimeCaptionDisplay.lines(from: [pair], mode: .bilingual)

        #expect(sourceOnlyLines.map(\.kind) == [.source])
        #expect(sourceOnlyLines.map(\.text) == ["I think people should talk about what has worked for them."])
        #expect(translationOnlyLines.map(\.kind) == [.translation])
        #expect(translationOnlyLines.map(\.text) == ["我认为人们应该谈论什么对他们有用。"])
        #expect(bilingualLines.map(\.kind) == [.source, .translation])
    }

    @Test("Appends pending source sentence after completed pairs")
    func appendsPendingSourceSentence() {
        let pair = SentencePair(
            original: "I think people should talk about what has worked for them.",
            translation: "我认为人们应该谈论什么对他们有用。"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [pair],
            pendingSource: "However, I don't think people should"
        )

        #expect(lines.count == 3)
        #expect(lines.map(\.kind) == [.source, .translation, .source])
        #expect(lines[0].text == "I think people should talk about what has worked for them.")
        #expect(lines[1].text == "我认为人们应该谈论什么对他们有用。")
        #expect(lines[2].text == "However, I don't think people should")
        #expect(lines[0].isPending == false)
        #expect(lines[1].isPending == false)
        #expect(lines[2].isPending == true)
    }

    @Test("Keeps in-flight source visible before translation arrives")
    func keepsInFlightSourceVisibleBeforeTranslationArrives() {
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedSource: "I think people should talk about what has worked for them.",
            pendingSource: "However, I don't think people should",
            showsUntranslatedSource: true
        )

        #expect(lines.count == 2)
        #expect(lines.map(\.kind) == [.source, .source])
        #expect(lines[0].text == "I think people should talk about what has worked for them.")
        #expect(lines[1].text == "However, I don't think people should")
    }

    @Test("Hides in-flight source during translation grace delay")
    func hidesInFlightSourceDuringTranslationGraceDelay() {
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedSource: "I think people should talk about what has worked for them.",
            pendingSource: "However, I don't think people should",
            showsUntranslatedSource: false
        )

        #expect(lines.isEmpty)
    }

    @Test("Shows paired translation during source grace delay")
    func showsPairedTranslationDuringSourceGraceDelay() {
        let pair = SentencePair(
            original: "I think people should talk about what has worked for them.",
            translation: "我认为人们应该谈论什么对他们有用。"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [pair],
            translatedSource: "I think people should talk about what has worked for them.",
            showsUntranslatedSource: false
        )

        #expect(lines.map(\.kind) == [.source, .translation])
        #expect(lines.map(\.text) == [
            "I think people should talk about what has worked for them.",
            "我认为人们应该谈论什么对他们有用。",
        ])
    }

    @Test("Hides newer untranslated source while keeping translated pairs")
    func hidesNewerUntranslatedSourceWhileKeepingTranslatedPairs() {
        let pair = SentencePair(
            original: "Hello world.",
            translation: "你好。"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [pair],
            translatedSource: "Hello world.\n\nThis is still awaiting translation.",
            translatedText: "你好。",
            showsUntranslatedSource: false
        )

        #expect(lines.map(\.kind) == [.source, .translation])
        #expect(lines.map(\.text) == ["Hello world.", "你好。"])
    }

    @Test("Recent untranslated signature ignores older untranslated segments")
    func recentUntranslatedSignatureIgnoresOlderUntranslatedSegments() {
        let signature = RealtimeCaptionDisplay.recentUntranslatedSourceSignature(
            pairs: [
                SentencePair(original: "Translated latest.", translation: "最新译文。"),
            ],
            translatedSourceSegments: [
                "Old untranslated.",
                "Translated latest.",
            ],
            translatedText: "最新译文。",
            pendingSource: "",
            pendingTranslation: "",
            sourceText: "Old untranslated.\n\nTranslated latest.",
            segmentLimit: 1
        )

        #expect(signature == nil)
    }

    @Test("Keeps pending source visible in translation-only mode until translation arrives")
    func keepsPendingSourceVisibleInTranslationOnlyMode() {
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            pendingSource: "But",
            mode: .translationOnly
        )

        #expect(lines == [RealtimeCaptionLine(id: "pending-source", kind: .source, text: "But", isPending: true)])
    }

    @Test("Aligns translated current sentence after untranslated earlier source")
    func alignsTranslatedCurrentSentenceAfterUntranslatedEarlierSource() {
        let pair = SentencePair(
            original: "However, I don't think people should",
            translation: "然而，我认为人们不应该"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [pair],
            translatedSource: "I think people should talk about what has worked for them.\n\nHowever, I don't think people should"
        )

        #expect(lines.count == 3)
        #expect(lines.map(\.kind) == [.source, .source, .translation])
        #expect(lines[0].text == "I think people should talk about what has worked for them.")
        #expect(lines[1].text == "However, I don't think people should")
        #expect(lines[2].text == "然而，我认为人们不应该")
    }

    @Test("Keeps previous translation visible while current source is awaiting translation")
    func keepsPreviousTranslationVisibleWhileCurrentSourceAwaitsTranslation() {
        let stalePair = SentencePair(
            original: "Hello world.",
            translation: "你好。"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [stalePair],
            translatedSource: "This is a newer recognition result",
            translatedText: "你好。"
        )

        #expect(lines.count == 2)
        #expect(lines.map(\.kind) == [.source, .translation])
        #expect(lines.map(\.text) == ["This is a newer recognition result", "你好。"])
    }

    @Test("Shows partial translation preview after finalized sentence pairs")
    func showsPartialTranslationPreviewAfterFinalizedSentencePairs() {
        let pair = SentencePair(
            original: "Hello world.",
            translation: "你好。"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [pair],
            translatedSource: "Hello world.",
            translatedText: "你好。",
            pendingSource: "This is still changing",
            pendingTranslation: "这还在变化"
        )

        #expect(lines.map(\.kind) == [.source, .translation, .source, .translation])
        #expect(lines.map(\.text) == ["Hello world.", "你好。", "This is still changing", "这还在变化"])
    }

    @Test("Keeps latest previous translation when older pairs are still aligned")
    func keepsLatestPreviousTranslationWhenOlderPairsAreStillAligned() {
        let olderPair = SentencePair(
            original: "The first sentence.",
            translation: "第一句。"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [olderPair],
            translatedSource: "The first sentence.\n\nThe current sentence is still changing",
            translatedText: "第一句。\n当前句。"
        )

        #expect(lines.map(\.kind) == [.source, .translation, .source, .translation])
        #expect(lines.map(\.text) == [
            "The first sentence.",
            "第一句。",
            "The current sentence is still changing",
            "当前句。",
        ])
    }

    @Test("Does not append previous translation lines already present in a multiline pair")
    func doesNotAppendPreviousTranslationLinesAlreadyPresentInMultilinePair() {
        let pair = SentencePair(
            original: "And was hesitating as he, uh, was approaching me.",
            translation: "当他，呃，向我走来时，犹豫不决。\n当他看到我，终于看到我是谁时，他松了一口气，哦，好吧。"
        )

        let lines = RealtimeCaptionDisplay.lines(
            from: [pair],
            translatedSource: "And was hesitating as he, uh, was approaching me.",
            translatedText: "当他，呃，向我走来时，犹豫不决。\n当他看到我，终于看到我是谁时，他松了一口气，哦，好吧。"
        )

        #expect(lines.map(\.kind) == [.source, .translation])
        #expect(lines.map(\.text) == [
            "And was hesitating as he, uh, was approaching me.",
            "当他，呃，向我走来时，犹豫不决。\n当他看到我，终于看到我是谁时，他松了一口气，哦，好吧。",
        ])
    }

    @Test("Shows plain translated text when provider returns no sentence pairs")
    func showsPlainTranslatedTextWithoutSentencePairs() {
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedSource: "I think people should talk about what has worked for them.",
            translatedText: "我认为人们应该谈论对他们有用的东西。"
        )

        #expect(lines.count == 2)
        #expect(lines.map(\.kind) == [.source, .translation])
        #expect(lines[0].text == "I think people should talk about what has worked for them.")
        #expect(lines[1].text == "我认为人们应该谈论对他们有用的东西。")
    }

    @Test("Leaves Apple Translator captions intact for view-width wrapping")
    func leavesAppleValidationCaptionsIntact() {
        let fixture = SnapshotFixtureData.realtimeAppleValidation()

        let lines = RealtimeCaptionDisplay.resolvedLines(
            pairs: fixture.sentencePairs,
            translatedSource: fixture.sourceText,
            translatedText: fixture.translatedText,
            pendingSource: fixture.pendingSource,
            pendingTranslation: fixture.pendingTranslation,
            sourceText: fixture.sourceText,
            mode: fixture.captionDisplayMode
        )

        #expect(lines.count == 4)
        #expect(lines.map(\.kind) == [.source, .translation, .source, .translation])
        #expect(lines[0].text == fixture.sourceText)
        #expect(lines[1].text == fixture.translatedText)
        #expect(lines[2].text == fixture.pendingSource)
        #expect(lines[3].text == fixture.pendingTranslation)
    }

    @Test("Keeps translation captions unchanged after Chinese sentence punctuation")
    func keepsTranslationCaptionsUnchangedAfterChineseSentencePunctuation() {
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedText: "第一句。第二句？第三句。"
        )

        #expect(lines.map(\.text) == ["第一句。第二句？第三句。"])
    }

    @Test("Keeps explicit single source segment unchanged")
    func keepsExplicitSingleSourceSegmentUnchanged() {
        let text = "First. Second? 第三句。"

        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedSourceSegments: [text],
            translatedSource: text
        )

        #expect(lines == [
            RealtimeCaptionLine(id: "plain-source", kind: .source, text: text),
        ])
    }

    @Test("Keeps plain translation text unchanged across punctuation and newlines")
    func keepsPlainTranslationTextUnchangedAcrossPunctuationAndNewlines() {
        let text = "第一句。\n第二句？\nThird."

        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedText: text
        )

        #expect(lines == [
            RealtimeCaptionLine(id: "plain-translation", kind: .translation, text: text),
        ])
    }

    @Test("Splits visible source captions by source sentence punctuation")
    func splitsVisibleSourceCaptionsBySourceSentencePunctuation() {
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedSource: "First. Second? 第三句。"
        )

        #expect(lines.map(\.kind) == [.source, .source, .source])
        #expect(lines.map(\.text) == ["First.", "Second?", "第三句。"])
    }

    @Test("Keeps pending source captions as one pending line")
    func keepsPendingSourceCaptionsAsOnePendingLine() {
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen"
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            pendingSource: text
        )

        #expect(lines == [
            RealtimeCaptionLine(id: "pending-source", kind: .source, text: text, isPending: true),
        ])
    }

    @Test("Keeps long plain translation text unchanged without punctuation")
    func keepsLongPlainTranslationTextUnchangedWithoutPunctuation() {
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen"
        let lines = RealtimeCaptionDisplay.lines(
            from: [],
            translatedText: text
        )

        #expect(lines == [
            RealtimeCaptionLine(id: "plain-translation", kind: .translation, text: text),
        ])
    }

    @Test("Clear anchor hides already visible captions while preserving source lines")
    func clearAnchorHidesAlreadyVisibleCaptionsWhilePreservingSourceLines() {
        let existingLines = [
            RealtimeCaptionLine(id: "0-source", kind: .source, text: "First source"),
            RealtimeCaptionLine(id: "0-translation", kind: .translation, text: "第一句。"),
        ]
        let currentLines = existingLines + [
            RealtimeCaptionLine(id: "1-source", kind: .source, text: "Second source"),
            RealtimeCaptionLine(id: "1-translation", kind: .translation, text: "第二句。"),
        ]

        let visibleLines = RealtimeCaptionDisplay.linesVisibleAfterClear(
            currentLines,
            anchor: RealtimeCaptionDisplayClearAnchor(lines: existingLines)
        )

        #expect(visibleLines == Array(currentLines.dropFirst(2)))
        #expect(currentLines.map(\.text) == ["First source", "第一句。", "Second source", "第二句。"])
    }

    @Test("Display clear leaves the backing transcript unchanged")
    func displayClearLeavesBackingTranscriptUnchanged() {
        let transcriptLines = [
            RealtimeCaptionLine(id: "0-source", kind: .source, text: "Persisted source"),
            RealtimeCaptionLine(id: "0-translation", kind: .translation, text: "持久化译文"),
        ]
        let anchor = RealtimeCaptionDisplayClearAnchor(lines: transcriptLines)

        let visibleLines = RealtimeCaptionDisplay.linesVisibleAfterClear(transcriptLines, anchor: anchor)

        #expect(visibleLines.isEmpty)
        #expect(transcriptLines.map(\.text) == ["Persisted source", "持久化译文"])
    }

    @Test("Clear anchor covers resolved history beyond the display window")
    func clearAnchorCoversFullResolvedHistory() {
        let existingLines = (0 ..< 200).map { index in
            RealtimeCaptionLine(id: "\(index)-source", kind: .source, text: "Line \(index)")
        }
        let anchor = RealtimeCaptionDisplayClearAnchor(lines: existingLines)
        let currentLines = existingLines + [
            RealtimeCaptionLine(id: "200-source", kind: .source, text: "Line 200"),
        ]

        #expect(RealtimeCaptionDisplay.linesVisibleAfterClear(existingLines, anchor: anchor).isEmpty)
        #expect(RealtimeCaptionDisplay.linesVisibleAfterClear(currentLines, anchor: anchor) == [
            RealtimeCaptionLine(id: "200-source", kind: .source, text: "Line 200"),
        ])
    }

    @Test("Clear anchor shows only newly appended text for a continuing caption line")
    func clearAnchorShowsOnlyNewlyAppendedTextForContinuingCaptionLine() {
        let anchor = RealtimeCaptionDisplayClearAnchor(lines: [
            RealtimeCaptionLine(id: "plain-translation", kind: .translation, text: "第一句。"),
        ])
        let visibleLines = RealtimeCaptionDisplay.linesVisibleAfterClear(
            [
                RealtimeCaptionLine(id: "plain-translation", kind: .translation, text: "第一句。\n第二句。"),
            ],
            anchor: anchor
        )

        #expect(visibleLines == [
            RealtimeCaptionLine(id: "plain-translation", kind: .translation, text: "第二句。"),
        ])
    }

    @Test("Shows listening placeholder while captions are empty and session is running")
    func showsListeningPlaceholderWhileRunning() {
        #expect(RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: true) == "Listening...")
        #expect(RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: false) == "Live captions will appear here.")
    }
}
