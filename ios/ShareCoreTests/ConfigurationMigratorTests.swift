//
//  ConfigurationMigratorTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("ConfigurationMigrator")
struct ConfigurationMigratorTests {
    // MARK: - Helpers

    /// The old-format translate prompt that was baked in by pre-refactor code.
    private static let oldTranslatePrompt =
        "If input is in 简体中文 (Chinese, Simplified), translate to English; otherwise translate to " +
        "简体中文 (Chinese, Simplified). Only provide the translated text without explanation."

    /// An alternative old prompt with different languages.
    private static let oldTranslatePromptAlt =
        "If input is in English, translate to Japanese; otherwise translate to English. Only provide the translated text without explanation."

    /// The double-brace variant from older DefaultConfiguration.json.
    private static let oldTranslatePromptDoubleBrace =
        "If input is in {{targetLanguage}}, translate to {{fallbackLanguage}}; otherwise translate to " +
        "{{targetLanguage}}. Only provide the translated text without explanation."

    /// The expected new translate prompt after migration.
    private static var newTranslatePrompt: String {
        builtInPrompt(named: "Translate")
    }

    /// A user-customized prompt that should NOT be migrated.
    private static let customPrompt =
        "You are a professional translator. Please translate the following text naturally."

    private static let currentVersion = AppConfiguration.currentVersion

    // MARK: - 1.2 -> 1.3 old prompts

    /// Old Sentence Translate prompt with {{fallbackLanguage}}.
    private static let oldSentenceTranslatePrompt =
        "If input is in {{targetLanguage}}, translate sentence by sentence to {{fallbackLanguage}}; " +
        "otherwise translate to {{targetLanguage}}. Return original-translation pairs. Keep meaning and style."

    /// Old Grammar Check prompt with {{fallbackLanguage}}.
    private static let oldGrammarCheckPrompt =
        "Check grammar: 1) Return polished text 2) Explain errors in {{fallbackLanguage}} " +
        "(❌ severe, ⚠️ minor) 3) Translate polished meaning into {{targetLanguage}}."

    /// Old Sentence Analysis prompt with {{fallbackLanguage}}.
    private static let oldSentenceAnalysisPrompt =
        "Analyze in {{fallbackLanguage}} using exactly these sections:\n\n## 📚语法分析\n- Sentence structure\n\n## ✍️ 搭配积累\n- Useful phrases\n\nBe concise."

    /// New Sentence Translate prompt (no fallbackLanguage and no target fallback).
    private static var newSentenceTranslatePrompt: String {
        builtInPrompt(named: "Sentence Translate")
    }

    /// Previous Sentence Translate prompt that redirected same-target input to English.
    private static let previousSentenceTranslatePrompt =
        "If input is in {{targetLanguage}}, translate sentence by sentence to English; " +
        "otherwise translate to {{targetLanguage}}. Return original-translation pairs. Keep meaning and style."

    /// New Grammar Check prompt (no fallbackLanguage).
    private static var newGrammarCheckPrompt: String {
        builtInPrompt(named: "Grammar Check")
    }

    /// New Sentence Analysis prompt (no fallbackLanguage).
    private static var newSentenceAnalysisPrompt: String {
        builtInPrompt(named: "Sentence Analysis")
    }

    private static func builtInPrompt(named name: String) -> String {
        AppConfigurationStore.builtInActions.first { $0.name == name }?.prompt ?? ""
    }

    /// Build a minimal 1.1.0 config with the given actions.
    private static func configV1_1(actions: [AppConfiguration.ActionEntry]) -> AppConfiguration {
        AppConfiguration(version: "1.1.0", actions: actions)
    }

    /// Build a 1.2.0 config with the given actions.
    private static func configV1_2(actions: [AppConfiguration.ActionEntry]) -> AppConfiguration {
        AppConfiguration(version: "1.2.0", actions: actions)
    }

    /// Build a translate action entry.
    private static func translateAction(prompt: String) -> AppConfiguration.ActionEntry {
        AppConfiguration.ActionEntry(
            name: "Translate",
            prompt: prompt,
            scenes: ["app", "contextRead", "contextEdit"]
        )
    }

    /// Build a non-translate action entry.
    private static func otherAction(
        name: String = "Grammar",
        prompt: String = "Fix grammar"
    ) -> AppConfiguration.ActionEntry {
        AppConfiguration.ActionEntry(name: name, prompt: prompt)
    }

    /// Build a Sentence Translate action entry.
    private static func sentenceTranslateAction(prompt: String) -> AppConfiguration.ActionEntry {
        AppConfiguration.ActionEntry(
            name: "Sentence Translate",
            prompt: prompt,
            outputType: "sentencePairs"
        )
    }

    /// Build a Grammar Check action entry.
    private static func grammarCheckAction(prompt: String) -> AppConfiguration.ActionEntry {
        AppConfiguration.ActionEntry(
            name: "Grammar Check",
            prompt: prompt,
            outputType: "grammarCheck"
        )
    }

    /// Build a Sentence Analysis action entry.
    private static func sentenceAnalysisAction(prompt: String) -> AppConfiguration.ActionEntry {
        AppConfiguration.ActionEntry(
            name: "Sentence Analysis",
            prompt: prompt
        )
    }

    // MARK: - 1.1 -> 1.2 Migration triggers

    @Test("1.1.0 config with old prompt is migrated to 1.3.0 with new prompt")
    func migratesOldPromptToNew() {
        let config = Self.configV1_1(actions: [
            Self.translateAction(prompt: Self.oldTranslatePrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions.count == 1)
        #expect(migrated.actions[0].prompt == Self.newTranslatePrompt)
    }

    @Test("Alternative old prompt pattern is also migrated")
    func migratesAlternativeOldPrompt() {
        let config = Self.configV1_1(actions: [
            Self.translateAction(prompt: Self.oldTranslatePromptAlt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.actions[0].prompt == Self.newTranslatePrompt)
    }

    @Test("Double-brace old prompt pattern is migrated")
    func migratesDoubleBraceOldPrompt() {
        let config = Self.configV1_1(actions: [
            Self.translateAction(prompt: Self.oldTranslatePromptDoubleBrace),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.actions[0].prompt == Self.newTranslatePrompt)
    }

    // MARK: - User-customized prompts preserved

    @Test("User-customized translate prompt is preserved")
    func preservesCustomPrompt() {
        let config = Self.configV1_1(actions: [
            Self.translateAction(prompt: Self.customPrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        // Version still bumps (migration ran), but prompt is untouched
        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions[0].prompt == Self.customPrompt)
    }

    // MARK: - Already-current configs

    @Test("Current config version is not migrated")
    func doesNotMigrateCurrentVersion() {
        let config = AppConfiguration(
            version: Self.currentVersion,
            actions: [Self.translateAction(prompt: Self.oldTranslatePrompt)]
        )

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(!didMigrate)
        #expect(migrated.version == Self.currentVersion)
        // Prompt stays as-is since no migration ran
        #expect(migrated.actions[0].prompt == Self.oldTranslatePrompt)
    }

    // MARK: - Edge cases

    @Test("Config with no actions migrates version only")
    func migratesEmptyActions() {
        let config = Self.configV1_1(actions: [])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions.isEmpty)
    }

    @Test("Only translate action is migrated, other actions untouched")
    func migratesOnlyTranslateAction() {
        let grammarAction = Self.otherAction(name: "Grammar", prompt: "Fix grammar issues")
        let summarizeAction = Self.otherAction(name: "Summarize", prompt: "Summarize the text")
        let config = Self.configV1_1(actions: [
            grammarAction,
            Self.translateAction(prompt: Self.oldTranslatePrompt),
            summarizeAction,
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.actions.count == 3)
        #expect(migrated.actions[0].name == "Grammar")
        #expect(migrated.actions[0].prompt == "Fix grammar issues")
        #expect(migrated.actions[1].name == "Translate")
        #expect(migrated.actions[1].prompt == Self.newTranslatePrompt)
        #expect(migrated.actions[2].name == "Summarize")
        #expect(migrated.actions[2].prompt == "Summarize the text")
    }

    @Test("Config with no translate action preserves all actions")
    func noTranslateAction() {
        let config = Self.configV1_1(actions: [
            Self.otherAction(name: "Grammar", prompt: "Fix grammar"),
            Self.otherAction(name: "Summarize", prompt: "Summarize"),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate) // version still bumps
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions.count == 2)
        #expect(migrated.actions[0].prompt == "Fix grammar")
        #expect(migrated.actions[1].prompt == "Summarize")
    }

    @Test("Scenes are removed and custom outputType is preserved through migration")
    func migratesActionMetadata() {
        let action = AppConfiguration.ActionEntry(
            name: "Translate",
            prompt: Self.oldTranslatePrompt,
            scenes: ["app", "contextRead"],
            outputType: "markdown"
        )
        let config = Self.configV1_1(actions: [action])

        let (migrated, _) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(migrated.actions[0].scenes == nil)
        #expect(migrated.actions[0].outputType == "markdown")
        #expect(migrated.actions[0].prompt == Self.newTranslatePrompt)
    }

    // MARK: - isOldTranslatePrompt

    @Test("isOldTranslatePrompt matches known patterns")
    func isOldTranslatePromptMatches() {
        #expect(ConfigurationMigrator.isOldTranslatePrompt(Self.oldTranslatePrompt))
        #expect(ConfigurationMigrator.isOldTranslatePrompt(Self.oldTranslatePromptAlt))
        #expect(ConfigurationMigrator.isOldTranslatePrompt(Self.oldTranslatePromptDoubleBrace))
        #expect(ConfigurationMigrator.isOldTranslatePrompt(
            "If input is in Korean, translate to English; otherwise translate to Korean."
        ))
    }

    @Test("isOldTranslatePrompt rejects non-matching prompts")
    func isOldTranslatePromptRejects() {
        #expect(!ConfigurationMigrator.isOldTranslatePrompt(Self.customPrompt))
        #expect(!ConfigurationMigrator.isOldTranslatePrompt(Self.newTranslatePrompt))
        #expect(!ConfigurationMigrator.isOldTranslatePrompt(""))
        #expect(!ConfigurationMigrator.isOldTranslatePrompt("Fix grammar issues"))
        #expect(!ConfigurationMigrator.isOldTranslatePrompt("Translate to {targetLanguage}"))
    }

    // MARK: - didMigrate flag accuracy

    @Test("didMigrate is false for current version")
    func didMigrateFalseForCurrent() {
        let config = AppConfiguration(version: Self.currentVersion, actions: [])
        let (_, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)
        #expect(!didMigrate)
    }

    @Test("didMigrate is true for older version even with no prompt changes")
    func didMigrateTrueForOlderVersion() {
        let config = Self.configV1_1(actions: [
            Self.translateAction(prompt: Self.customPrompt),
        ])
        let (_, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)
        #expect(didMigrate)
    }

    // MARK: - Version edge cases

    @Test("Version 1.0.0 is migrated")
    func migratesFromV1_0_0() {
        let config = AppConfiguration(
            version: "1.0.0",
            actions: [Self.translateAction(prompt: Self.oldTranslatePrompt)]
        )

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions[0].prompt == Self.newTranslatePrompt)
    }

    @Test("Version 1.1.5 (hypothetical patch) is migrated")
    func migratesFromPatchVersion() {
        let config = AppConfiguration(
            version: "1.1.5",
            actions: [Self.translateAction(prompt: Self.oldTranslatePrompt)]
        )

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
    }

    // MARK: - 1.2 -> 1.3 Migration: fallbackLanguage removal

    @Test("1.2.0 Sentence Translate with fallbackLanguage is migrated to 1.3.0")
    func migratesSentenceTranslateFallback() {
        let config = Self.configV1_2(actions: [
            Self.sentenceTranslateAction(prompt: Self.oldSentenceTranslatePrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions[0].prompt == Self.newSentenceTranslatePrompt)
    }

    @Test("1.5.0 Sentence Translate target fallback is removed")
    func migratesSentenceTranslateTargetFallback() {
        let config = AppConfiguration(version: "1.5.0", actions: [
            Self.sentenceTranslateAction(prompt: Self.previousSentenceTranslatePrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions[0].prompt == Self.newSentenceTranslatePrompt)
    }

    @Test("1.2.0 Grammar Check with fallbackLanguage is migrated to 1.3.0")
    func migratesGrammarCheckFallback() {
        let config = Self.configV1_2(actions: [
            Self.grammarCheckAction(prompt: Self.oldGrammarCheckPrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions[0].prompt == Self.newGrammarCheckPrompt)
    }

    @Test("1.2.0 Sentence Analysis with fallbackLanguage is migrated to 1.3.0")
    func migratesSentenceAnalysisFallback() {
        let config = Self.configV1_2(actions: [
            Self.sentenceAnalysisAction(prompt: Self.oldSentenceAnalysisPrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions[0].prompt == Self.newSentenceAnalysisPrompt)
    }

    @Test("1.2.0 actions without fallbackLanguage are preserved")
    func preservesNonFallbackPrompts() {
        let customSentencePrompt = "My custom sentence translation approach"
        let config = Self.configV1_2(actions: [
            Self.sentenceTranslateAction(prompt: customSentencePrompt),
            Self.grammarCheckAction(prompt: "My custom grammar check"),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate) // version bumps
        #expect(migrated.version == Self.currentVersion)
        #expect(migrated.actions[0].prompt == customSentencePrompt)
        #expect(migrated.actions[1].prompt == "My custom grammar check")
    }

    @Test("1.2.0 config with mixed fallback and non-fallback actions")
    func migratesMixedActions() {
        let config = Self.configV1_2(actions: [
            Self.translateAction(prompt: Self.newTranslatePrompt),
            Self.sentenceTranslateAction(prompt: Self.oldSentenceTranslatePrompt),
            Self.grammarCheckAction(prompt: "My custom grammar"),
            Self.sentenceAnalysisAction(prompt: Self.oldSentenceAnalysisPrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        // Translate prompt unchanged (already new)
        #expect(migrated.actions[0].prompt == Self.newTranslatePrompt)
        // Sentence Translate migrated
        #expect(migrated.actions[1].prompt == Self.newSentenceTranslatePrompt)
        // Grammar Check custom — preserved
        #expect(migrated.actions[2].prompt == "My custom grammar")
        // Sentence Analysis migrated
        #expect(migrated.actions[3].prompt == Self.newSentenceAnalysisPrompt)
    }

    @Test("OutputType preserved through 1.2 -> 1.3 migration")
    func preservesOutputTypeThroughFallbackMigration() {
        let config = Self.configV1_2(actions: [
            Self.sentenceTranslateAction(prompt: Self.oldSentenceTranslatePrompt),
            Self.grammarCheckAction(prompt: Self.oldGrammarCheckPrompt),
        ])

        let (migrated, _) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(migrated.actions[0].outputType == "sentencePairs")
        #expect(migrated.actions[1].outputType == "grammarCheck")
    }

    // MARK: - Full chain migration: 1.1 -> 1.3

    @Test("Full chain: 1.1.0 config migrates through both steps to 1.3.0")
    func fullChainMigration() {
        let config = Self.configV1_1(actions: [
            Self.translateAction(prompt: Self.oldTranslatePrompt),
            Self.sentenceTranslateAction(prompt: Self.oldSentenceTranslatePrompt),
            Self.grammarCheckAction(prompt: Self.oldGrammarCheckPrompt),
            Self.sentenceAnalysisAction(prompt: Self.oldSentenceAnalysisPrompt),
        ])

        let (migrated, didMigrate) = ConfigurationMigrator.migrateIfNeeded(config)

        #expect(didMigrate)
        #expect(migrated.version == Self.currentVersion)
        // Step 1: translate prompt migrated
        #expect(migrated.actions[0].prompt == Self.newTranslatePrompt)
        // Step 2: fallbackLanguage prompts migrated
        #expect(migrated.actions[1].prompt == Self.newSentenceTranslatePrompt)
        #expect(migrated.actions[2].prompt == Self.newGrammarCheckPrompt)
        #expect(migrated.actions[3].prompt == Self.newSentenceAnalysisPrompt)
    }

    // MARK: - containsFallbackLanguage

    @Test("containsFallbackLanguage detects single-brace")
    func containsFallbackSingleBrace() {
        #expect(ConfigurationMigrator.containsFallbackLanguage("translate to {fallbackLanguage}"))
    }

    @Test("containsFallbackLanguage detects double-brace")
    func containsFallbackDoubleBrace() {
        #expect(ConfigurationMigrator.containsFallbackLanguage("translate to {{fallbackLanguage}}"))
    }

    @Test("containsFallbackLanguage rejects prompts without fallback")
    func containsFallbackRejects() {
        #expect(!ConfigurationMigrator.containsFallbackLanguage("translate to {{targetLanguage}}"))
        #expect(!ConfigurationMigrator.containsFallbackLanguage(""))
        #expect(!ConfigurationMigrator.containsFallbackLanguage("just a plain prompt"))
    }
}
