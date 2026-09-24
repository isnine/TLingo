#if os(macOS) || os(iOS)
    import Foundation
    import Security

    enum RetiredRealtimeAzureMigration {
        private static let cleanupCompletedKey = "retired_realtime_azure_cleanup_completed"
        private static let providerKey = "realtime_translation_provider"
        private static let endpointKey = "realtime_whisper_endpoint"
        private static let generatedVoiceKey = "realtime_gpt_generated_voice_enabled"
        private static let retiredProviderID = "azure_gpt_realtime_translator"

        static func cleanup(
            defaults: UserDefaults,
            deleteCredential: () -> OSStatus = RetiredRealtimeAzureMigration.deleteCredential
        ) {
            guard !defaults.bool(forKey: cleanupCompletedKey) else { return }

            if defaults.string(forKey: providerKey) == retiredProviderID {
                defaults.set(RealtimeTranslationProvider.default.rawValue, forKey: providerKey)
            }
            defaults.removeObject(forKey: endpointKey)
            defaults.removeObject(forKey: generatedVoiceKey)

            let status = deleteCredential()
            guard status == errSecSuccess || status == errSecItemNotFound else { return }
            defaults.set(true, forKey: cleanupCompletedKey)
        }

        private static func deleteCredential() -> OSStatus {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.zanderwang.AITranslator.RealtimeWhisper",
                kSecAttrAccount as String: "apiKey",
            ] as CFDictionary)
        }
    }
#endif
