#if os(macOS)
    import Foundation
    @testable import ShareCore
    import Testing

    @MainActor
    @Suite("Cloud provider consent", .serialized)
    struct AppPreferencesDataConsentTests {
        @Test("Azure-only acceptance requires renewed consent")
        func legacyAcceptanceRequiresRenewal() throws {
            let suite = "AppPreferencesDataConsentTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "has_accepted_data_sharing")

            let preferences = AppPreferences(defaults: defaults)
            #expect(!preferences.hasAcceptedDataSharing)

            preferences.setHasAcceptedDataSharing(true)
            #expect(AppPreferences(defaults: defaults).hasAcceptedDataSharing)
        }

        @Test("Revocation refreshes another preferences instance")
        func revocationRefreshes() throws {
            let suite = "AppPreferencesDataConsentTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = AppPreferences(defaults: defaults)
            preferences.setHasAcceptedDataSharing(true)
            let other = AppPreferences(defaults: defaults)

            preferences.setHasAcceptedDataSharing(false)
            other.refreshFromDefaults()
            #expect(!other.hasAcceptedDataSharing)
            #expect(!AppPreferences(defaults: defaults).hasAcceptedDataSharing)
        }
    }
#endif
