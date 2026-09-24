//
//  RealtimeSessionStoreHistoryTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Testing

    @testable import ShareCore

    @Suite("RealtimeSessionStore history")
    struct RealtimeSessionStoreHistoryTests {
        @Test("History snapshot includes pending translation visible at stop")
        func historySnapshotIncludesPendingTranslation() {
            var checkpoint = RealtimeHistoryCheckpoint()

            let snapshot = RealtimeSessionStore.historySnapshot(
                sourceText: "hello world",
                translatedText: "",
                pendingTranslatedText: "hola mundo",
                checkpoint: &checkpoint
            )

            #expect(snapshot?.sourceText == "hello world")
            #expect(snapshot?.translatedText == "hola mundo")
        }

        @Test("History snapshot appends pending translation after saved text")
        func historySnapshotAppendsPendingTranslationAfterSavedText() throws {
            var checkpoint = RealtimeHistoryCheckpoint()
            let firstSnapshot = RealtimeSessionStore.historySnapshot(
                sourceText: "hello world",
                translatedText: "hola mundo",
                pendingTranslatedText: "",
                checkpoint: &checkpoint
            )
            try checkpoint.acknowledge(#require(firstSnapshot))

            let snapshot = RealtimeSessionStore.historySnapshot(
                sourceText: "hello world\n\ngood morning",
                translatedText: "hola mundo",
                pendingTranslatedText: "buenos dias",
                checkpoint: &checkpoint
            )

            #expect(snapshot?.sourceText == "good morning")
            #expect(snapshot?.translatedText == "buenos dias")
        }

        @Test("History pairs use the projected realtime sentence pairs")
        func historyPairsUseProjectedSentencePairs() {
            let pairs = RealtimeSessionStore.historyPairs(
                sentencePairs: [
                    SentencePair(original: "First.", translation: "第一句。"),
                    SentencePair(original: "Second.", translation: "第二句。"),
                ],
                pendingSourceText: "Pending.",
                pendingTranslatedText: "待处理。",
                sourceText: "First. Second.",
                translatedText: "第一句。\n第二句。"
            )

            #expect(pairs.map(\.original) == ["First.", "Second.", "Pending."])
            #expect(pairs.map(\.translation) == ["第一句。", "第二句。", "待处理。"])
        }
    }
#endif
