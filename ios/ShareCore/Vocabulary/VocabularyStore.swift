//
//  VocabularyStore.swift
//  ShareCore
//

import Combine
import Foundation
import os
import SwiftData

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "Vocabulary")

public enum VocabularyStoreError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        String(localized: "Vocabulary storage is unavailable.")
    }
}

@MainActor
public final class VocabularyStore: ObservableObject {
    public static let shared = VocabularyStore(storeURL: VocabularyStore.defaultStoreURL())

    /// Newest first.
    @Published public private(set) var entries: [VocabularyEntry] = []
    @Published public private(set) var loadError: String?

    private let context: ModelContext?

    init(storeURL: URL?) {
        guard let storeURL else {
            context = nil
            loadError = VocabularyStoreError.unavailable.localizedDescription
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let schema = Schema([VocabularyEntry.self])
            let configuration = ModelConfiguration("Vocabulary", schema: schema, url: storeURL, cloudKitDatabase: .none)
            context = try ModelContext(ModelContainer(for: schema, configurations: [configuration]))
            reload()
        } catch {
            logger.error("Vocabulary store init failed: \(error.localizedDescription, privacy: .public)")
            context = nil
            loadError = error.localizedDescription
        }
    }

    /// Re-reads the store; the translation extension may have written to it.
    public func reload() {
        guard let context else { return }
        do {
            entries = try context.fetch(FetchDescriptor<VocabularyEntry>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            loadError = nil
        } catch {
            logger.error("Vocabulary fetch failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    public func contains(_ draft: VocabularyDraft) -> Bool {
        entry(for: draft) != nil
    }

    /// Saves the draft, replacing the translation of an existing entry for the same term and target language.
    public func save(_ draft: VocabularyDraft) throws {
        guard let context else { throw VocabularyStoreError.unavailable }
        if let existing = entry(for: draft) {
            existing.translation = draft.translation
            existing.sourceLanguageCode = draft.sourceLanguageCode
        } else {
            context.insert(VocabularyEntry(draft: draft))
        }
        try commit()
    }

    public func remove(_ draft: VocabularyDraft) throws {
        guard let existing = entry(for: draft) else { return }
        try delete([existing])
    }

    public func delete(_ entriesToDelete: [VocabularyEntry]) throws {
        guard let context else { throw VocabularyStoreError.unavailable }
        for entry in entriesToDelete {
            context.delete(entry)
        }
        try commit()
    }

    private func entry(for draft: VocabularyDraft) -> VocabularyEntry? {
        let key = draft.key
        return entries.first {
            VocabularyDraft.key(normalizedTerm: $0.normalizedTerm, targetLanguageCode: $0.targetLanguageCode) == key
        }
    }

    private func commit() throws {
        guard let context else { throw VocabularyStoreError.unavailable }
        do {
            try context.save()
        } catch {
            context.rollback()
            reload()
            throw error
        }
        reload()
    }

    private static func defaultStoreURL() -> URL? {
        #if os(macOS)
            // Application Support avoids the App Group access prompt, matching History.
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Vocabulary", isDirectory: true)
                .appendingPathComponent("Vocabulary.store")
        #else
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppPreferences.appGroupSuiteName)?
                .appendingPathComponent("Vocabulary", isDirectory: true)
                .appendingPathComponent("Vocabulary.store")
        #endif
    }
}
