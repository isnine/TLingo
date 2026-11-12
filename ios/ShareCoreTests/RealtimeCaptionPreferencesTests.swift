import Foundation
@testable import ShareCore
import Testing

@MainActor
@Suite("Realtime caption preferences", .serialized)
struct RealtimeCaptionPreferencesTests {
    @Test("Defaults preserve platform appearance and bilingual captions")
    func defaultsPreserveAppearance() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.realtimeCaptionDisplayMode == .bilingual)
        #expect(preferences.realtimeCaptionAppearance == RealtimeCaptionAppearance())
        #if os(macOS)
            #expect(preferences.realtimeCaptionAppearance.fontDesign == .platformDefault)
        #else
            #expect(preferences.realtimeCaptionAppearance.fontDesign == .serif)
        #endif
    }

    @Test("Legacy typography survives decoding without new appearance fields")
    func legacyTypographySurvives() throws {
        let defaults = try makeDefaults()
        defaults.set(
            Data(#"{"fontDesign":"rounded","textSize":29,"spacing":"relaxed"}"#.utf8),
            forKey: "realtime_caption_appearance"
        )
        let appearance = AppPreferences(defaults: defaults).realtimeCaptionAppearance
        #expect(appearance.fontDesign == .rounded)
        #expect(appearance.textSize == 29)
        #expect(appearance.spacing == .relaxed)
        #expect(appearance.sourceColor == nil)
        #expect(appearance.translationColor == nil)
        #expect(appearance.backgroundColor == nil)
        #expect(appearance.floatingBackgroundOpacity == 0.48)
    }

    @Test("Appearance and display mode persist and refresh")
    func preferencesPersistAndRefresh() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)
        var appearance = RealtimeCaptionAppearance()
        appearance.fontDesign = .system
        appearance.textSize = 30
        appearance.spacing = .compact
        appearance.sourceColor = RealtimeCaptionColor(red: 0.2, green: 0.8, blue: 1)
        appearance.translationColor = RealtimeCaptionColor(red: 1, green: 0.8, blue: 0.1)
        appearance.backgroundColor = RealtimeCaptionColor(red: 0.1, green: 0.1, blue: 0.2)
        appearance.floatingBackgroundOpacity = 0.75
        preferences.setRealtimeCaptionAppearance(appearance)
        preferences.setRealtimeCaptionDisplayMode(.translationOnly)
        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.realtimeCaptionAppearance == appearance)
        #expect(reloaded.realtimeCaptionDisplayMode == .translationOnly)

        defaults.set("sourceOnly", forKey: "realtime_caption_display_mode")
        try defaults.set(JSONEncoder().encode(RealtimeCaptionAppearance()), forKey: "realtime_caption_appearance")
        preferences.refreshFromDefaults()
        #expect(preferences.realtimeCaptionDisplayMode == .sourceOnly)
        #expect(preferences.realtimeCaptionAppearance == RealtimeCaptionAppearance())
    }

    @Test("Resetting appearance does not reset display mode or translation provider")
    func appearanceResetIsIsolated() throws {
        let preferences = try AppPreferences(defaults: makeDefaults())
        preferences.setRealtimeCaptionDisplayMode(.translationOnly)
        let provider = preferences.realtimeTranslationProvider
        var appearance = RealtimeCaptionAppearance()
        appearance.textSize = 32
        preferences.setRealtimeCaptionAppearance(appearance)
        preferences.setRealtimeCaptionAppearance(RealtimeCaptionAppearance())
        #expect(preferences.realtimeCaptionDisplayMode == .translationOnly)
        #expect(preferences.realtimeTranslationProvider == provider)
    }

    @Test("Session restores mode and tracks external preference refresh")
    func sessionRestoresMode() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setRealtimeCaptionDisplayMode(.translationOnly)
        let store = RealtimeSessionStore(preferences: preferences)
        #expect(store.captionDisplayMode == .translationOnly)
        defaults.set("sourceOnly", forKey: "realtime_caption_display_mode")
        preferences.refreshFromDefaults()
        #expect(store.captionDisplayMode == .sourceOnly)
        store.captionDisplayMode = .bilingual
        #expect(preferences.realtimeCaptionDisplayMode == .bilingual)
    }

    @Test("Transcription temporarily resolves to source without changing chosen mode")
    func transcriptionPreservesMode() throws {
        let preferences = try AppPreferences(defaults: makeDefaults())
        preferences.setRealtimeCaptionDisplayMode(.translationOnly)
        let store = RealtimeSessionStore(preferences: preferences)
        #if os(macOS)
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .transcriptionOnly
            )
            store.applyLaneSnapshotFixture(
                [RealtimeLaneSnapshot(configuration: configuration)],
                primaryLaneID: configuration.id
            )
        #else
            preferences.setRealtimeTranslationProvider(.transcriptionOnly)
        #endif
        #expect(store.resolvedCaptionDisplayMode == .sourceOnly)
        #expect(store.captionDisplayMode == .translationOnly)
        #expect(preferences.realtimeCaptionDisplayMode == .translationOnly)
        #if os(macOS)
            let translatedConfiguration = RealtimeLaneConfiguration(
                recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                translationProvider: .appleTranslator
            )
            store.applyLaneSnapshotFixture(
                [RealtimeLaneSnapshot(configuration: translatedConfiguration)],
                primaryLaneID: translatedConfiguration.id
            )
        #else
            preferences.setRealtimeTranslationProvider(.appleTranslator)
        #endif
        #expect(store.resolvedCaptionDisplayMode == .translationOnly)
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "RealtimeCaptionPreferencesTests.\(UUID().uuidString)"))
    }

    #if os(macOS)
        @Test("Stopped lanes follow caption mode without changing backing text or primary lane")
        func stoppedLanesFollowMode() throws {
            let preferences = try AppPreferences(defaults: makeDefaults())
            preferences.setRealtimeCaptionDisplayMode(.translationOnly)
            let store = RealtimeSessionStore(preferences: preferences)
            let snapshots = [RecognitionModelDescriptor.appleSpeech.id, RecognitionModelDescriptor.parakeetEOU320.id].map {
                RealtimeLaneSnapshot(
                    configuration: RealtimeLaneConfiguration(
                        recognitionModelID: $0,
                        translationProvider: .appleTranslator
                    ),
                    sourceText: "Hello.",
                    translatedText: "你好。",
                    sentencePairs: [SentencePair(original: "Hello.", translation: "你好。")]
                )
            }
            let primary = try #require(snapshots.first?.id)
            store.applyLaneSnapshotFixture(snapshots, primaryLaneID: primary)
            #expect(store.laneSnapshots.allSatisfy { $0.captionLines.map(\.kind) == [.translation] })
            store.captionDisplayMode = .sourceOnly
            #expect(store.laneSnapshots.allSatisfy { $0.captionLines.map(\.kind) == [.source] })
            store.captionDisplayMode = .bilingual
            #expect(store.laneSnapshots.allSatisfy { $0.captionLines.map(\.kind) == [.source, .translation] })
            #expect(store.laneSnapshots.allSatisfy { $0.sourceText == "Hello." && $0.translatedText == "你好。" })
            #expect(store.primaryLaneID == primary)
            #expect(!store.isRunning)
        }
    #endif
}
