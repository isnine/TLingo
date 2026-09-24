#if os(macOS) || os(iOS)
    import Foundation
    import Security
    @testable import ShareCore
    import Testing

    @Suite("Retired realtime Azure migration")
    struct RetiredRealtimeAzureMigrationTests {
        @Test("Clears retired credentials and preserves the cleanup result")
        func clearsRetiredCredentials() throws {
            let suiteName = "RetiredRealtimeAzureMigrationTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            defaults.set("azure_gpt_realtime_translator", forKey: "realtime_translation_provider")
            defaults.set("https://example.openai.azure.com", forKey: "realtime_whisper_endpoint")
            defaults.set(true, forKey: "realtime_gpt_generated_voice_enabled")
            var deletionCount = 0

            RetiredRealtimeAzureMigration.cleanup(defaults: defaults) {
                deletionCount += 1
                return errSecSuccess
            }
            RetiredRealtimeAzureMigration.cleanup(defaults: defaults) {
                deletionCount += 1
                return errSecSuccess
            }

            #expect(defaults.string(forKey: "realtime_translation_provider") == "apple_translator")
            #expect(defaults.object(forKey: "realtime_whisper_endpoint") == nil)
            #expect(defaults.object(forKey: "realtime_gpt_generated_voice_enabled") == nil)
            #expect(deletionCount == 1)
        }
    }
#endif
