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

    @Test func previewStripsMarkdownMarkers() {
        #expect(VocabularyText.preview(of: "## **serendipity** /ˌser.ənˈdɪp.ə.ti/\n- noun") == "serendipity /ˌser.ənˈdɪp.ə.ti/")
        #expect(VocabularyText.preview(of: "\n---\n1. 意外发现") == "意外发现")
        #expect(VocabularyText.preview(of: "**Serendipity**\n- *noun* lucky find", term: "serendipity") == "noun lucky find")
    }
}
