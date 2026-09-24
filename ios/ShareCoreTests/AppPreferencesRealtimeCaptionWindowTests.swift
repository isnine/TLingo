#if os(macOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @MainActor
    @Suite("Realtime caption window preferences", .serialized)
    struct AppPreferencesRealtimeCaptionWindowTests {
        @Test("Caption window preferences default to floating and private")
        func defaultsToFloatingAndPrivate() throws {
            let defaults = try makeDefaults()
            let preferences = AppPreferences(defaults: defaults)

            #expect(preferences.realtimeCaptionWindowMode == .floating)
            #expect(preferences.realtimeCaptionPrivacyModeEnabled)
        }

        @Test("Caption window preferences persist")
        func preferencesPersist() throws {
            let defaults = try makeDefaults()
            let preferences = AppPreferences(defaults: defaults)

            preferences.setRealtimeCaptionWindowMode(.notch)
            preferences.setRealtimeCaptionPrivacyModeEnabled(false)

            let reloaded = AppPreferences(defaults: defaults)
            #expect(reloaded.realtimeCaptionWindowMode == .notch)
            #expect(!reloaded.realtimeCaptionPrivacyModeEnabled)
        }

        @Test("Refresh updates caption window preferences")
        func refreshUpdatesCaptionWindowPreferences() throws {
            let defaults = try makeDefaults()
            let preferences = AppPreferences(defaults: defaults)

            defaults.set("notch", forKey: "realtime_caption_window_mode")
            defaults.set(false, forKey: "realtime_caption_privacy_mode_enabled")
            preferences.refreshFromDefaults()

            #expect(preferences.realtimeCaptionWindowMode == .notch)
            #expect(!preferences.realtimeCaptionPrivacyModeEnabled)
        }

        private func makeDefaults() throws -> UserDefaults {
            let suiteName = "AppPreferencesRealtimeCaptionWindowTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
    }
#endif
