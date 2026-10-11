//
//  VocabularyStoreTests.swift
//  ShareCoreTests
//

import Foundation
@testable import ShareCore
import SwiftData
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

    @Test func staleWriterReplacesPersistedNaturalKey() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let app = VocabularyStore(storeURL: url)
        let extensionStore = VocabularyStore(storeURL: url)
        try extensionStore.save(draft("Shared term", translation: "extension"))
        try app.save(draft(" SHARED  term ", translation: "app"))

        let reopened = VocabularyStore(storeURL: url)
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries.first?.translation == "app")
        extensionStore.reload()
        #expect(extensionStore.entries.first?.translation == "app")
    }

    @Test func staleRemovalFindsExternallySavedTerm() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let app = VocabularyStore(storeURL: url)
        let extensionStore = VocabularyStore(storeURL: url)
        try extensionStore.save(draft("Shared term"))
        try app.remove(draft("shared term"))
        #expect(VocabularyStore(storeURL: url).entries.isEmpty)
        extensionStore.reload()
        #expect(extensionStore.contains(draft("shared term")) == false)
    }

    @Test func savingAfterExternalDeletionCreatesPersistedEntry() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let app = VocabularyStore(storeURL: url)
        try app.save(draft("Shared term"))
        let extensionStore = VocabularyStore(storeURL: url)
        try extensionStore.remove(draft("shared term"))
        try app.save(draft("Shared term", translation: "saved again"))
        #expect(VocabularyStore(storeURL: url).entries.first?.translation == "saved again")
    }

    @Test func bookmarkToggleUsesPersistedStateRatherThanStaleCache() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let app = VocabularyStore(storeURL: url)
        let extensionStore = VocabularyStore(storeURL: url)
        try extensionStore.save(draft("Shared"))
        try app.toggle(draft("Shared"))
        #expect(app.contains(draft("Shared")) == false)
        #expect(VocabularyStore(storeURL: url).entries.isEmpty)
        try extensionStore.toggle(draft("Shared"))
        #expect(extensionStore.contains(draft("Shared")))
        #expect(VocabularyStore(storeURL: url).entries.count == 1)
    }

    @Test func savingLegacyDuplicatesPreservesOtherTermsAndTargets() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema([VocabularyEntry.self])
        let configuration = ModelConfiguration("Vocabulary", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(VocabularyEntry(draft: draft("Shared", translation: "old")))
        context.insert(VocabularyEntry(draft: draft("SHARED", translation: "duplicate")))
        context.insert(VocabularyEntry(draft: draft("Shared", target: "ja")))
        context.insert(VocabularyEntry(draft: draft("Unrelated")))
        try context.save()

        let store = VocabularyStore(storeURL: url)
        try store.save(draft("shared", translation: "replacement"))
        #expect(store.entries.count == 3)
        #expect(store.entries.filter { $0.normalizedTerm == "shared" && $0.targetLanguageCode == "zh-Hans" }
            .map(\.translation) == ["replacement"])
        #expect(store.contains(draft("Shared", target: "ja")))
        #expect(store.contains(draft("Unrelated")))
    }

    @Test func persistenceLockSerializesConcurrentReadModifyWrite() async throws {
        let url = makeStoreURL()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let counterURL = directory.appendingPathComponent("counter")
        try "0".write(to: counterURL, atomically: true, encoding: .utf8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try VocabularyStore.withExclusiveAccess(to: url) {
                        let value = try Int(String(contentsOf: counterURL, encoding: .utf8)) ?? 0
                        try String(value + 1).write(to: counterURL, atomically: true, encoding: .utf8)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try String(contentsOf: counterURL, encoding: .utf8) == "20")
    }

    @Test func previewStripsMarkdownMarkers() {
        #expect(VocabularyText.preview(of: "## **serendipity** /ˌser.ənˈdɪp.ə.ti/\n- noun") == "serendipity /ˌser.ənˈdɪp.ə.ti/")
        #expect(VocabularyText.preview(of: "\n---\n1. 意外发现") == "意外发现")
        #expect(VocabularyText.preview(of: "**Serendipity**\n- *noun* lucky find", term: "serendipity") == "noun lucky find")
    }
}
