import Foundation
import Testing

@testable import ShareCore

@MainActor
@Suite("TranslationHistoryService safety")
struct TranslationHistoryServiceSafetyTests {
    @Test("A current store survives a second launch without a migration marker")
    func currentStoreSurvivesSecondLaunchWithoutMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("TranslationHistory.store")
        let suiteName = "TranslationHistoryServiceSafetyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let requestID = UUID()

        do {
            let service = TranslationHistoryService(
                storeURL: storeURL,
                userDefaults: defaults,
                pruneAudioRecordings: false
            )
            try service.saveThrowing(
                requestID: requestID,
                sourceText: "Hello",
                resultText: "Hola",
                actionName: "Translate",
                targetLanguage: "Spanish",
                modelID: "test",
                modelDisplayName: "Test",
                duration: 0
            )
        }

        defaults.removeObject(forKey: TranslationHistoryService.migrationMarkerKey)
        let relaunched = TranslationHistoryService(
            storeURL: storeURL,
            userDefaults: defaults,
            pruneAudioRecordings: false
        )

        #expect(relaunched.fetchAll().map(\.requestID) == [requestID])
    }

    @Test("Unknown store open errors preserve existing files")
    func unknownOpenErrorPreservesExistingFiles() {
        var openAttempts = 0
        var marked = false

        #expect(throws: TestError.openFailed) {
            try TranslationHistoryService.openCurrentStore(
                storeExisted: true,
                migrationCompleted: false,
                open: {
                    openAttempts += 1
                    throw TestError.openFailed
                },
                markMigrationCompleted: {
                    marked = true
                }
            ) as String
        }

        #expect(openAttempts == 1)
        #expect(!marked)
    }

    @Test("Fetch failure skips audio pruning")
    func fetchFailureSkipsAudioPruning() {
        var pruned = false

        TranslationHistoryService.pruneUnreferencedAudioRecordings(
            fetchRecords: {
                throw TestError.fetchFailed
            },
            prune: { _ in
                pruned = true
            }
        )

        #expect(!pruned)
    }

    @Test("Corrupt realtime data skips audio pruning")
    func corruptRealtimeDataSkipsAudioPruning() {
        let record = TranslationRecord(sourceText: "Hello")
        record.realtimeSessionData = Data("not-json".utf8)
        var pruned = false

        TranslationHistoryService.pruneUnreferencedAudioRecordings(
            fetchRecords: { [record] },
            prune: { _ in
                pruned = true
            }
        )

        #expect(!pruned)
    }

    @Test("Failed record persistence keeps external audio")
    func failedPersistenceKeepsExternalAudio() {
        var deleted = false

        #expect(throws: TestError.persistFailed) {
            try TranslationHistoryService.deleteAudioAfterPersistence(
                recordings: [],
                persist: {
                    throw TestError.persistFailed
                },
                deleteAudio: { _ in
                    deleted = true
                }
            )
        }
        #expect(!deleted)
    }

    @Test("Microphone progress cannot overwrite a newer realtime autosave")
    func microphoneProgressMergesWithNewerAutosave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "TranslationHistoryServiceSafetyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = TranslationHistoryService(
            storeURL: directory.appendingPathComponent("TranslationHistory.store"),
            userDefaults: defaults,
            pruneAudioRecordings: false
        )
        let requestID = UUID()
        let latest = session(
            requestID: requestID,
            sourceText: "New primary",
            translatedText: "New translation",
            duration: 20
        )
        var staleProcessed = session(
            requestID: requestID,
            sourceText: "Old primary",
            translatedText: "Old translation",
            duration: 10
        )
        staleProcessed.delayedTranscriptSegments = [
            RealtimeHistoryTranscriptSegment(
                source: .microphone,
                offset: 3,
                duration: 2,
                text: "Microphone text"
            ),
        ]

        try service.saveRealtimeSession(latest)
        let merged = try service.saveMicrophonePostProcessing(staleProcessed)

        #expect(merged.segments == latest.segments)
        #expect(merged.duration == latest.duration)
        #expect(merged.delayedTranscriptSegments == staleProcessed.delayedTranscriptSegments)
        #expect(service.fetchAll().first?.realtimeSession == merged)
    }

    @Test("Updating a realtime title preserves the latest session")
    func realtimeTitleUpdatePreservesSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "TranslationHistoryServiceSafetyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = TranslationHistoryService(
            storeURL: directory.appendingPathComponent("TranslationHistory.store"),
            userDefaults: defaults,
            pruneAudioRecordings: false
        )
        let requestID = UUID()
        let latest = session(
            requestID: requestID,
            sourceText: "Latest complete transcript",
            translatedText: "Latest translation",
            duration: 30
        )

        try service.saveRealtimeSession(latest)
        try service.updateRealtimeGeneratedTitle(requestID: requestID, title: "Project status meeting")

        let stored = try #require(service.fetchAll().first?.realtimeSession)
        #expect(stored.generatedTitle == "Project status meeting")
        #expect(stored.sourceText == latest.sourceText)
        #expect(stored.translatedText == latest.translatedText)
        #expect(stored.duration == latest.duration)
    }

    @Test("Updating speaker names preserves the latest session")
    func speakerNameUpdatePreservesSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "TranslationHistoryServiceSafetyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = TranslationHistoryService(
            storeURL: directory.appendingPathComponent("TranslationHistory.store"),
            userDefaults: defaults,
            pruneAudioRecordings: false
        )
        let requestID = UUID()
        let latest = session(
            requestID: requestID,
            sourceText: "Latest transcript",
            translatedText: "Latest translation",
            duration: 30
        )

        try service.saveRealtimeSession(latest)
        let updated = try service.updateRealtimeSpeakerNames(
            requestID: requestID,
            names: ["S01": "Teacher", "S02": "  "]
        )

        #expect(updated.speakerNames == ["S01": "Teacher"])
        #expect(updated.sourceText == latest.sourceText)
        #expect(updated.duration == latest.duration)

        let relaunched = TranslationHistoryService(
            storeURL: directory.appendingPathComponent("TranslationHistory.store"),
            userDefaults: defaults,
            pruneAudioRecordings: false
        )
        #expect(relaunched.fetchAll().first?.realtimeSession?.speakerNames == ["S01": "Teacher"])
    }

    @Test("Reconstructed track updates only its matching source and model")
    func reconstructedTrackUpdatesMatchingTrack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "TranslationHistoryServiceSafetyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = TranslationHistoryService(
            storeURL: directory.appendingPathComponent("TranslationHistory.store"),
            userDefaults: defaults,
            pruneAudioRecordings: false
        )
        let requestID = UUID()
        let latest = session(
            requestID: requestID,
            sourceText: "Latest primary",
            translatedText: "Latest translation",
            duration: 20
        )
        try service.saveRealtimeSession(latest)

        let firstTrack = RealtimeHistoryTrack(
            audioSource: .microphone,
            recognitionModelID: "moss-transcribe-diarize",
            recognitionModelDisplayName: "MOSS Diarization",
            translationProviderID: "apple-translate",
            translationProviderDisplayName: "Apple Translate",
            segments: [
                RealtimeHistoryTrackSegment(
                    offset: 2,
                    duration: 3,
                    speakerID: "S01",
                    sourceText: "First",
                    translatedText: "Primero",
                    relation: .paired
                ),
            ]
        )
        let firstSaved = try service.saveRealtimeTrack(requestID: requestID, track: firstTrack)
        let savedTrackID = try #require(firstSaved.tracks.first {
            $0.recognitionModelID == "moss-transcribe-diarize"
        }?.id)

        var updatedTrack = firstTrack
        updatedTrack.id = UUID()
        updatedTrack.segments[0].sourceText = "Updated"
        let updated = try service.saveRealtimeTrack(requestID: requestID, track: updatedTrack)

        let mossTracks = updated.tracks.filter { $0.recognitionModelID == "moss-transcribe-diarize" }
        #expect(mossTracks.count == 1)
        #expect(mossTracks.first?.id == savedTrackID)
        #expect(mossTracks.first?.segments.first?.sourceText == "Updated")
        #expect(updated.sourceText == latest.sourceText)
        #expect(updated.duration == latest.duration)
    }

    private func session(
        requestID: UUID,
        sourceText: String,
        translatedText: String,
        duration: TimeInterval
    ) -> RealtimeHistorySession {
        RealtimeHistorySession(
            requestID: requestID,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 100 + duration),
            duration: duration,
            inputSource: "Mac Audio",
            inputSourceID: .macAudio,
            sourceLanguage: "English",
            targetLanguage: "Spanish",
            modelID: "apple-translate",
            modelDisplayName: "Apple Translate",
            segments: [
                RealtimeHistorySegment(offset: 0, sourceText: sourceText, translatedText: translatedText),
            ]
        )
    }
}

private enum TestError: Error, Equatable {
    case openFailed
    case fetchFailed
    case persistFailed
}
