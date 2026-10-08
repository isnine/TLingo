//
//  VocabularyStoreTests.swift
//  ShareCoreTests
//

import Foundation
@testable import ShareCore
import Testing

@MainActor
@Suite("VocabularyStore")
struct VocabularyStoreTests {
    private func makeStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabularyStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Vocabulary.store")
    }

    private func draft(_ term: String, translation: String = "translation", target: String = "zh-Hans") -> VocabularyDraft {
        VocabularyDraft(term: term, translation: translation, sourceLanguageCode: "en", targetLanguageCode: target)
    }

    @Test func savingSameTermUpdatesTranslationInsteadOfDuplicating() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = VocabularyStore(storeURL: url)

        try store.save(draft("Serendipity", translation: "old"))
        try store.save(draft("  serendipity ", translation: "new"))
        try store.save(draft("serendipity", translation: "other target", target: "ja"))

        #expect(store.entries.count == 2)
        #expect(store.contains(draft("SERENDIPITY")))
        #expect(store.entries.first { $0.targetLanguageCode == "zh-Hans" }?.translation == "new")
    }

    @Test func entriesPersistAcrossStoreInstances() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try VocabularyStore(storeURL: url).save(draft("ephemeral"))
        let reopened = VocabularyStore(storeURL: url)

        #expect(reopened.entries.map(\.term) == ["ephemeral"])
        try reopened.remove(draft("Ephemeral"))
        #expect(VocabularyStore(storeURL: url).entries.isEmpty)
    }

    @Test func reviewGradingAdjustsFamiliarity() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = VocabularyStore(storeURL: url)
        try store.save(draft("word"))
        let entry = try #require(store.entries.first)

        for _ in 0 ..< 7 {
            try store.recordReview(entry, remembered: true)
        }
        #expect(entry.familiarity == VocabularyEntry.learnedFamiliarity)
        #expect(entry.reviewCount == 7)

        try store.recordReview(entry, remembered: false)
        #expect(entry.familiarity == 0)
    }

    @Test func reviewQueuePrefersUnfamiliarAndLeastRecentlyReviewed() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = VocabularyStore(storeURL: url)
        for term in ["learned", "familiar", "stale", "fresh"] {
            try store.save(draft(term))
        }
        func entry(_ term: String) throws -> VocabularyEntry {
            try #require(store.entries.first { $0.term == term })
        }
        let now = Date()
        for _ in 0 ..< VocabularyEntry.learnedFamiliarity {
            try store.recordReview(entry("learned"), remembered: true, at: now)
        }
        try store.recordReview(entry("familiar"), remembered: true, at: now)
        try store.recordReview(entry("stale"), remembered: false, at: now.addingTimeInterval(-3600))
        try store.recordReview(entry("fresh"), remembered: false, at: now)

        #expect(store.reviewQueue().map(\.term) == ["stale", "fresh", "familiar"])
        #expect(try VocabularyStore.reviewOrder([entry("learned")], limit: 20).map(\.term) == ["learned"])
    }

    @Test func previewStripsMarkdownMarkers() {
        #expect(VocabularyText.preview(of: "## **serendipity** /ˌser.ənˈdɪp.ə.ti/\n- noun") == "serendipity /ˌser.ənˈdɪp.ə.ti/")
        #expect(VocabularyText.preview(of: "\n---\n1. 意外发现") == "意外发现")
        #expect(VocabularyText.preview(of: "**Serendipity**\n- *noun* lucky find", term: "serendipity") == "noun lucky find")
    }
}
