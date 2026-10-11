//
//  VocabularyStore.swift
//  ShareCore
//

import Combine
import Darwin
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

    private let container: ModelContainer?
    private let storeURL: URL?
    private var context: ModelContext?

    init(storeURL: URL?) {
        self.storeURL = storeURL
        guard let storeURL else {
            container = nil
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
            container = try Self.withExclusiveAccess(to: storeURL) {
                try ModelContainer(for: schema, configurations: [configuration])
            }
            reload()
        } catch {
            logger.error("Vocabulary store init failed: \(error.localizedDescription, privacy: .public)")
            container = nil
            loadError = error.localizedDescription
        }
    }

    /// Re-reads the store; the translation extension may have written to it.
    public func reload() {
        do {
            try withFreshContext { context in
                entries = try fetchEntries(context)
            }
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
        try update { context, persisted in
            let matches = matching(draft, in: persisted)
            if let existing = matches.first {
                existing.translation = draft.translation
                existing.sourceLanguageCode = draft.sourceLanguageCode
                for duplicate in matches.dropFirst() {
                    context.delete(duplicate)
                }
            } else {
                context.insert(VocabularyEntry(draft: draft))
            }
        }
    }

    public func remove(_ draft: VocabularyDraft) throws {
        try update { context, persisted in
            for entry in matching(draft, in: persisted) {
                context.delete(entry)
            }
        }
    }

    /// Resolves bookmark state inside the same cross-process transaction as the mutation.
    public func toggle(_ draft: VocabularyDraft) throws {
        try update { context, persisted in
            let matches = matching(draft, in: persisted)
            if matches.isEmpty {
                context.insert(VocabularyEntry(draft: draft))
            } else {
                for entry in matches {
                    context.delete(entry)
                }
            }
        }
    }

    public func delete(_ entriesToDelete: [VocabularyEntry]) throws {
        let keys = Set(entriesToDelete.map {
            VocabularyDraft.key(normalizedTerm: $0.normalizedTerm, targetLanguageCode: $0.targetLanguageCode)
        })
        try update { context, persisted in
            for entry in persisted where keys.contains(
                VocabularyDraft.key(normalizedTerm: entry.normalizedTerm, targetLanguageCode: entry.targetLanguageCode)
            ) {
                context.delete(entry)
            }
        }
    }

    private func entry(for draft: VocabularyDraft) -> VocabularyEntry? {
        matching(draft, in: entries).first
    }

    private func matching(_ draft: VocabularyDraft, in entries: [VocabularyEntry]) -> [VocabularyEntry] {
        entries.filter {
            VocabularyDraft.key(normalizedTerm: $0.normalizedTerm, targetLanguageCode: $0.targetLanguageCode) == draft.key
        }
    }

    private func fetchEntries(_ context: ModelContext) throws -> [VocabularyEntry] {
        try context.fetch(FetchDescriptor<VocabularyEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
    }

    private func update(_ mutation: (ModelContext, [VocabularyEntry]) -> Void) throws {
        do {
            try withFreshContext { context in
                let persisted = try fetchEntries(context)
                mutation(context, persisted)
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
                entries = try fetchEntries(context)
            }
            loadError = nil
        } catch {
            logger.error("Vocabulary update failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
            throw error
        }
    }

    private func withFreshContext(_ operation: (ModelContext) throws -> Void) throws {
        guard let container, let storeURL else { throw VocabularyStoreError.unavailable }
        try Self.withExclusiveAccess(to: storeURL) {
            // A fetch on a long-lived context can return cached objects after another process writes.
            let freshContext = ModelContext(container)
            freshContext.autosaveEnabled = false
            try operation(freshContext)
            context = freshContext
        }
    }

    nonisolated static func withExclusiveAccess<T>(to storeURL: URL, _ operation: () throws -> T) throws -> T {
        // App and extension must serialize the entire read/modify/save, not just SQLite's save.
        let descriptor = open(storeURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
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
