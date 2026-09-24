//
//  ConfigurationIdentityMigrationTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("Configuration identity migration")
struct ConfigurationIdentityMigrationTests {
    private static let oldTranslatePrompt =
        "If input is in English, translate to Simplified Chinese; otherwise translate to English. " +
        "Return only the translation."

    @Test("Migrated legacy built-in is filtered by semantic signature")
    func migratedLegacyBuiltInIsFiltered() {
        let config = legacyConfiguration(prompt: Self.oldTranslatePrompt)

        let migrated = ConfigurationMigrator.migrateIfNeeded(config).config
        let filtered = BuiltInActionCatalog.customConfiguration(from: migrated)

        #expect(filtered.removedBuiltInActions)
        #expect(filtered.config.actions.isEmpty)
    }

    @Test("Migrated same-name custom prompt is preserved")
    func migratedSameNameCustomPromptIsPreserved() {
        let customPrompt = "Use this custom translation workflow"
        let config = legacyConfiguration(prompt: customPrompt)

        let migrated = ConfigurationMigrator.migrateIfNeeded(config).config
        let filtered = BuiltInActionCatalog.customConfiguration(from: migrated)

        #expect(filtered.removedBuiltInActions == false)
        #expect(filtered.config.actions.count == 1)
        #expect(filtered.config.actions[0].prompt == customPrompt)
    }

    private func legacyConfiguration(prompt: String) -> AppConfiguration {
        AppConfiguration(
            version: "1.1.0",
            actions: [
                .init(
                    name: "Translate",
                    prompt: prompt,
                    scenes: ["app", "contextRead", "contextEdit"]
                ),
            ]
        )
    }
}
