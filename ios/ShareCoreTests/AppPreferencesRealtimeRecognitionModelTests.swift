//
//  AppPreferencesRealtimeRecognitionModelTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("AppPreferences recognition model")
    struct AppPreferencesRecognitionModelTests {
        @Test("Defaults to the preferred realtime model")
        func defaultsToPreferredRealtimeModel() throws {
            let defaults = try makeDefaults()
            let preferences = AppPreferences(defaults: defaults)

            #expect(preferences.realtimeRecognitionModelID == RecognitionModelStore.defaultRealtimeModel.id)
        }

        @Test("Falls back from unknown model IDs")
        func fallsBackFromUnknownModelIDs() throws {
            let defaults = try makeDefaults()
            defaults.set("missing-model", forKey: "realtime_recognition_model_id")

            let preferences = AppPreferences(defaults: defaults)

            #expect(preferences.realtimeRecognitionModelID == RecognitionModelDescriptor.appleSpeech.id)
        }

        @Test("Migrates retired TDT model IDs")
        func migratesRetiredTDTModelIDs() throws {
            let defaults = try makeDefaults()
            defaults.set("parakeet-tdt-0.6b-v3", forKey: "realtime_recognition_model_id")

            let preferences = AppPreferences(defaults: defaults)

            #expect(preferences.realtimeRecognitionModelID == RecognitionModelStore.defaultRealtimeModel.id)
        }

        @Test("Migrates retired Parakeet Flash")
        func migratesRetiredParakeetFlash() throws {
            let defaults = try makeDefaults()
            defaults.set("parakeet-flash", forKey: "realtime_recognition_model_id")

            let preferences = AppPreferences(defaults: defaults)

            #expect(preferences.realtimeRecognitionModelID == RecognitionModelStore.defaultRealtimeModel.id)
        }

        @Test("Migrates retired Qwen model")
        func migratesRetiredQwen() throws {
            let defaults = try makeDefaults()
            defaults.set("qwen3-asr-int8", forKey: "realtime_recognition_model_id")

            let preferences = AppPreferences(defaults: defaults)

            #expect(preferences.realtimeRecognitionModelID == RecognitionModelStore.defaultRealtimeModel.id)
        }

        private func makeDefaults() throws -> UserDefaults {
            let suiteName = "AppPreferencesRealtimeRecognitionModelTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
    }
#endif
