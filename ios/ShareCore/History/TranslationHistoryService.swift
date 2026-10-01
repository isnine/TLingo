//
//  TranslationHistoryService.swift
//  ShareCore
//
//  Created by Zander Wang on 2026/03/13.
//

import Foundation
import os
import SwiftData

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "History")

public extension Notification.Name {
    static let translationRecordSaved = Notification.Name("com.tlingo.translationRecordSaved")
}

public enum TranslationHistoryAnnotationError: LocalizedError, Equatable {
    case recordNotFound
    case invalidTarget
    case emptyMarkdown

    public var errorDescription: String? {
        switch self {
        case .recordNotFound:
            return String(localized: "History record was not found.")
        case .invalidTarget:
            return String(localized: "Annotation target is not part of this history record.")
        case .emptyMarkdown:
            return String(localized: "Annotation markdown is empty.")
        }
    }
}

public enum TranslationHistoryPersistenceError: Error, Equatable {
    case historyUnavailable
    case recordNotFound
}

@MainActor
public final class TranslationHistoryService {
    public static let shared = TranslationHistoryService()

    private static let appGroupIdentifier = AppPreferences.appGroupSuiteName
    static let migrationMarkerKey = "history.v2.migrated"

    private let modelContainer: ModelContainer?
    private let persistentContext: ModelContext?

    private convenience init() {
        self.init(storeURL: Self.historyStoreURL())
    }

    init(
        storeURL: URL?,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        pruneAudioRecordings: Bool = true
    ) {
        guard let storeURL else {
            logger.debug("Could not determine storage directory — history disabled")
            modelContainer = nil
            persistentContext = nil
            return
        }

        let directory = storeURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let storeExisted = fileManager.fileExists(atPath: storeURL.path)
            let container = try Self.openCurrentStore(
                storeExisted: storeExisted,
                migrationCompleted: userDefaults.bool(forKey: Self.migrationMarkerKey),
                open: {
                    try Self.makeModelContainer(at: storeURL)
                },
                markMigrationCompleted: {
                    userDefaults.set(true, forKey: Self.migrationMarkerKey)
                }
            )
            let context = ModelContext(container)
            modelContainer = container
            persistentContext = context
            if pruneAudioRecordings {
                Self.pruneUnreferencedAudioRecordings(using: context)
            }
            logger.info("Initialized at \(storeURL.path, privacy: .public)")
        } catch {
            logger.error("ModelContainer init failed: \(error.localizedDescription, privacy: .public)")
            modelContainer = nil
            persistentContext = nil
        }
    }

    // MARK: - Save

    // Saves or appends a model result to the record identified by `requestID`.
    // swiftlint:disable:next function_parameter_count
    public func save(
        requestID: UUID,
        sourceText: String,
        resultText: String,
        actionName: String,
        targetLanguage: String,
        modelID: String,
        modelDisplayName: String,
        duration: TimeInterval,
        isConversation: Bool = false,
        conversationMessages: [ChatMessage]? = nil
    ) {
        do {
            try saveThrowing(
                requestID: requestID,
                sourceText: sourceText,
                resultText: resultText,
                actionName: actionName,
                targetLanguage: targetLanguage,
                modelID: modelID,
                modelDisplayName: modelDisplayName,
                duration: duration,
                isConversation: isConversation,
                conversationMessages: conversationMessages
            )
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // swiftlint:disable:next function_parameter_count
    public func saveThrowing(
        requestID: UUID,
        sourceText: String,
        resultText: String,
        actionName: String,
        targetLanguage: String,
        modelID: String,
        modelDisplayName: String,
        duration: TimeInterval,
        isConversation: Bool = false,
        conversationMessages: [ChatMessage]? = nil
    ) throws {
        guard let persistentContext else { throw TranslationHistoryPersistenceError.historyUnavailable }

        let newResult = (!resultText.isEmpty || conversationMessages == nil) ? ModelResult(
            modelID: modelID,
            modelDisplayName: modelDisplayName,
            resultText: resultText,
            duration: duration
        ) : nil

        // Try to find existing record for this request
        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1

        if let existing = try persistentContext.fetch(descriptor).first {
            if let newResult {
                var results = try existing.decodedModelResults()
                results.append(newResult)
                existing.modelResults = results
            }
            if let conversationMessages { existing.conversationMessages = conversationMessages }
        } else {
            let record = TranslationRecord(
                requestID: requestID,
                sourceText: sourceText,
                actionName: actionName,
                targetLanguage: targetLanguage,
                isConversation: isConversation,
                modelResults: newResult.map { [$0] } ?? [],
                conversationMessages: conversationMessages ?? []
            )
            persistentContext.insert(record)
        }

        try persistentContext.save()
        logger.debug("Saved translation record for request \(requestID.uuidString.prefix(8), privacy: .public)")
        NotificationCenter.default.post(name: .translationRecordSaved, object: nil)
    }

    public func saveRealtimeSession(_ session: RealtimeHistorySession) throws {
        guard let persistentContext else { throw TranslationHistoryPersistenceError.historyUnavailable }

        let newResult = ModelResult(
            modelID: session.modelID,
            modelDisplayName: session.modelDisplayName,
            resultText: session.translatedText,
            duration: session.duration
        )

        let requestID = session.requestID
        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1

        if let existing = try persistentContext.fetch(descriptor).first {
            let session = try Self.mergingRealtimeAutosave(session, into: existing.decodedRealtimeSession())
            existing.sourceText = session.sourceText
            existing.actionName = TranslationRecord.realtimeActionName
            existing.targetLanguage = session.targetLanguage
            existing.timestamp = session.startedAt
            existing.isConversation = false
            existing.modelResults = [newResult]
            existing.realtimeSession = session
        } else {
            let record = TranslationRecord(
                requestID: session.requestID,
                sourceText: session.sourceText,
                actionName: TranslationRecord.realtimeActionName,
                targetLanguage: session.targetLanguage,
                timestamp: session.startedAt,
                modelResults: [newResult]
            )
            record.realtimeSession = session
            persistentContext.insert(record)
        }

        try persistentContext.save()
        logger.debug("Saved realtime session for request \(session.requestID.uuidString.prefix(8), privacy: .public)")
        NotificationCenter.default.post(name: .translationRecordSaved, object: nil)
    }

    public func updateRealtimeGeneratedTitle(requestID: UUID, title: String) throws {
        guard let persistentContext else { throw TranslationHistoryPersistenceError.historyUnavailable }

        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1

        guard let record = try persistentContext.fetch(descriptor).first,
              var session = record.realtimeSession
        else {
            throw TranslationHistoryPersistenceError.recordNotFound
        }

        session.generatedTitle = title
        record.realtimeSession = session
        try persistentContext.save()
        NotificationCenter.default.post(name: .translationRecordSaved, object: nil)
    }

    static func mergingRealtimeAutosave(
        _ incoming: RealtimeHistorySession,
        into current: RealtimeHistorySession?
    ) -> RealtimeHistorySession {
        guard let current else { return incoming }
        var merged = incoming

        if merged.delayedTranscriptSegments.isEmpty {
            merged.delayedTranscriptSegments = current.delayedTranscriptSegments
        }
        if merged.delayedConversationItems.isEmpty {
            merged.delayedConversationItems = current.delayedConversationItems
        }
        if merged.transcriptionModels.isEmpty {
            merged.transcriptionModels = current.transcriptionModels
        }
        if merged.generatedTitle == nil {
            merged.generatedTitle = current.generatedTitle
        }
        if merged.speakerNames.isEmpty {
            merged.speakerNames = current.speakerNames
        }

        var mergedTracksByID = Dictionary(uniqueKeysWithValues: current.tracks.map { ($0.id, $0) })
        for incomingTrack in merged.tracks {
            if let currentTrack = mergedTracksByID[incomingTrack.id],
               let currentUpdatedAt = currentTrack.updatedAt,
               let incomingUpdatedAt = incomingTrack.updatedAt,
               currentUpdatedAt > incomingUpdatedAt
            {
                continue
            }
            mergedTracksByID[incomingTrack.id] = incomingTrack
        }
        let incomingOrder = merged.tracks.map(\.id)
        let preservedOrder = current.tracks.map(\.id).filter { !incomingOrder.contains($0) }
        merged.tracks = (incomingOrder + preservedOrder).compactMap { mergedTracksByID[$0] }
        if merged.primaryTrackID == nil {
            merged.primaryTrackID = current.primaryTrackID
        }
        return merged
    }

    public func saveMicrophonePostProcessing(
        _ processedSession: RealtimeHistorySession
    ) throws -> RealtimeHistorySession {
        guard let persistentContext else { throw TranslationHistoryPersistenceError.historyUnavailable }
        let requestID = processedSession.requestID
        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1

        guard let record = try persistentContext.fetch(descriptor).first,
              let currentSession = record.realtimeSession
        else {
            throw TranslationHistoryPersistenceError.recordNotFound
        }

        let mergedSession = RealtimeHistoryAudioPostProcessor.mergingMicrophonePostProcessing(
            processedSession,
            into: currentSession
        )
        record.realtimeSession = mergedSession
        try persistentContext.save()
        NotificationCenter.default.post(name: .translationRecordSaved, object: nil)
        return mergedSession
    }

    public func saveAnnotation(
        recordID: UUID,
        targetID: UUID,
        markdown: String
    ) throws {
        guard let persistentContext else { throw TranslationHistoryAnnotationError.recordNotFound }
        let trimmedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMarkdown.isEmpty else { throw TranslationHistoryAnnotationError.emptyMarkdown }

        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1

        guard let record = try persistentContext.fetch(descriptor).first else {
            throw TranslationHistoryAnnotationError.recordNotFound
        }
        guard record.annotationTargetIDs.contains(targetID) else {
            throw TranslationHistoryAnnotationError.invalidTarget
        }

        var annotations = record.historyAnnotations
        annotations[targetID.uuidString] = trimmedMarkdown
        record.historyAnnotations = annotations

        do {
            try persistentContext.save()
            NotificationCenter.default.post(name: .translationRecordSaved, object: nil)
        } catch {
            logger.error("Annotation save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Fetch

    public func fetchAll() -> [TranslationRecord] {
        guard let persistentContext else { return [] }
        var descriptor = FetchDescriptor<TranslationRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        return (try? persistentContext.fetch(descriptor)) ?? []
    }

    public func fetchSince(_ date: Date) -> [TranslationRecord] {
        guard let persistentContext else { return [] }
        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.timestamp >= date },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        return (try? persistentContext.fetch(descriptor)) ?? []
    }

    // MARK: - Delete

    public func delete(_ record: TranslationRecord) {
        guard let persistentContext else { return }
        let recordID = record.id
        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        do {
            guard let found = try persistentContext.fetch(descriptor).first else { return }
            let audioRecordings = found.realtimeSession?.audioRecordings ?? []
            persistentContext.delete(found)
            try Self.deleteAudioAfterPersistence(
                recordings: audioRecordings,
                persist: {
                    try persistentContext.save()
                },
                deleteAudio: { recordings in
                    RealtimeHistoryAudioStorage.deleteRecordings(recordings)
                }
            )
        } catch {
            persistentContext.rollback()
            logger.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func deleteAll() {
        guard let persistentContext else { return }
        do {
            let recordings = try persistentContext.fetch(FetchDescriptor<TranslationRecord>())
                .flatMap { $0.realtimeSession?.audioRecordings ?? [] }
            try persistentContext.delete(model: TranslationRecord.self)
            try Self.deleteAudioAfterPersistence(
                recordings: recordings,
                persist: {
                    try persistentContext.save()
                },
                deleteAudio: { recordings in
                    RealtimeHistoryAudioStorage.deleteRecordings(recordings)
                }
            )
            logger.info("Deleted all records")
        } catch {
            persistentContext.rollback()
            logger.error("Delete all failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Store URL

    private static func historyStoreURL() -> URL? {
        #if os(macOS)
            // Use Application Support on macOS to avoid the "Access Data from Other Apps"
            // permission dialog that App Group containers trigger.
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return nil
            }
            return appSupport
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("TranslationHistory.store")
        #else
            guard let groupContainer = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            ) else {
                return nil
            }
            return groupContainer
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("TranslationHistory.store")
        #endif
    }
}

// MARK: - Migration

extension TranslationHistoryService {
    public func updateRealtimeSpeakerNames(
        requestID: UUID,
        names: [String: String]
    ) throws -> RealtimeHistorySession {
        guard let persistentContext else { throw TranslationHistoryPersistenceError.historyUnavailable }
        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1

        guard let record = try persistentContext.fetch(descriptor).first,
              var session = record.realtimeSession
        else {
            throw TranslationHistoryPersistenceError.recordNotFound
        }

        session.speakerNames = names.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        record.realtimeSession = session
        try persistentContext.save()
        NotificationCenter.default.post(name: .translationRecordSaved, object: nil)
        return session
    }

    public func saveRealtimeTrack(
        requestID: UUID,
        track incomingTrack: RealtimeHistoryTrack
    ) throws -> RealtimeHistorySession {
        guard let persistentContext else { throw TranslationHistoryPersistenceError.historyUnavailable }
        var descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1

        guard let record = try persistentContext.fetch(descriptor).first,
              var session = record.realtimeSession
        else {
            throw TranslationHistoryPersistenceError.recordNotFound
        }

        var track = incomingTrack
        if let index = session.tracks.firstIndex(where: { existing in
            existing.id == track.id ||
                existing.audioSource == track.audioSource &&
                existing.recognitionModelID == track.recognitionModelID &&
                existing.translationProviderID == track.translationProviderID
        }) {
            track.id = session.tracks[index].id
            session.tracks[index] = track
        } else {
            session.tracks.append(track)
        }

        record.realtimeSession = session
        try persistentContext.save()
        NotificationCenter.default.post(name: .translationRecordSaved, object: nil)
        return session
    }

    static func openCurrentStore<Store>(
        storeExisted: Bool,
        migrationCompleted: Bool,
        open: () throws -> Store,
        markMigrationCompleted: () -> Void
    ) throws -> Store {
        do {
            let store = try open()
            markMigrationCompleted()
            return store
        } catch {
            logger.error(
                """
                History store open failed; preserving existing files and deferring legacy migration. \
                storeExisted=\(storeExisted, privacy: .public) \
                migrationCompleted=\(migrationCompleted, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
            throw error
        }
    }

    static func deleteAudioAfterPersistence(
        recordings: [RealtimeHistoryAudioRecording],
        persist: () throws -> Void,
        deleteAudio: ([RealtimeHistoryAudioRecording]) -> Void
    ) throws {
        try persist()
        deleteAudio(recordings)
    }

    static func pruneUnreferencedAudioRecordings(
        fetchRecords: () throws -> [TranslationRecord],
        prune: (Set<String>) -> Void
    ) {
        do {
            let records = try fetchRecords()
            let referenced = try Set(records.flatMap { record -> [String] in
                guard let data = record.realtimeSessionData else { return [] }
                return try JSONDecoder()
                    .decode(RealtimeHistorySession.self, from: data)
                    .audioRecordings
                    .map(\.directoryName)
            })
            prune(referenced)
        } catch {
            logger.error("Skipped realtime audio pruning: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeModelContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema([TranslationRecord.self])
        let config = ModelConfiguration(
            "TranslationHistory",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    private static func pruneUnreferencedAudioRecordings(using context: ModelContext) {
        pruneUnreferencedAudioRecordings(
            fetchRecords: {
                try context.fetch(FetchDescriptor<TranslationRecord>())
            },
            prune: { referencedDirectoryNames in
                RealtimeHistoryAudioStorage.pruneUnreferencedRecordings(
                    referencedDirectoryNames: referencedDirectoryNames
                )
            }
        )
    }
}
