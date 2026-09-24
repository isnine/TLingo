//
//  DefaultConfigurationTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("DefaultConfiguration")
struct DefaultConfigurationTests {
    @Test("Bundled default configuration is an empty user template")
    func bundledDefaultConfigurationIsEmptyUserTemplate() throws {
        let url = try #require(ConfigurationFileManager.bundledDefaultConfigURL())
        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)

        #expect(configuration.version == AppConfiguration.currentVersion)
        #expect(configuration.actions.isEmpty)
    }

    @Test("Built-in actions include current managed defaults")
    func builtInActionsIncludeCurrentManagedDefaults() throws {
        let builtInActions = AppConfigurationStore.builtInActions
        let names = builtInActions.map(\.name)

        #expect(names == [
            "Translate",
            "Sentence Translate",
            "Simplify",
            "Grammar Check",
            "Polish",
            "Sentence Analysis",
        ])

        for action in builtInActions {
            #expect(action.prompt.contains("{{text}}"), "\(action.name) should include text placeholder")
            #expect(PromptSubstitution.containsTextPlaceholder(action.prompt), "\(action.name) should use inline text mode")
        }

        let grammarCheck = try #require(builtInActions.first { $0.name == "Grammar Check" })
        #expect(grammarCheck.outputType == .grammarCheck)
        #expect(grammarCheck.prompt.localizedCaseInsensitiveContains("revised_text"))
        #expect(grammarCheck.prompt.localizedCaseInsensitiveContains("additional_text"))
        #expect(grammarCheck.prompt.contains("{appLanguage}"))
        #expect(!grammarCheck.prompt.contains("{{targetLanguage}}"))
        #expect(grammarCheck.languageDependencies.usesAppLanguage)
        #expect(!grammarCheck.languageDependencies.usesTargetLanguage)

        let polish = try #require(builtInActions.first { $0.name == "Polish" })
        #expect(polish.outputType == .diff)
        #expect(polish.prompt.localizedCaseInsensitiveContains("preserve the input language"))
        #expect(!polish.languageDependencies.usesSourceLanguage)
        #expect(!polish.languageDependencies.usesTargetLanguage)
        #expect(!polish.languageDependencies.usesAppLanguage)
        #expect(polish.prompt.localizedCaseInsensitiveContains("return only the polished text"))

        let simplify = try #require(builtInActions.first { $0.name == "Simplify" })
        #expect(simplify.outputType == .plain)
        #expect(simplify.category == .general)
        #expect(simplify.prompt.localizedCaseInsensitiveContains("preserve the input language"))
        #expect(!simplify.languageDependencies.usesSourceLanguage)
        #expect(!simplify.languageDependencies.usesTargetLanguage)
        #expect(!simplify.languageDependencies.usesAppLanguage)
        #expect(simplify.prompt.localizedCaseInsensitiveContains("Do NOT translate"))
        #expect(simplify.prompt.localizedCaseInsensitiveContains("preserve the original meaning"))
        #expect(simplify.prompt.localizedCaseInsensitiveContains("simpler and more concise"))
        #expect(simplify.prompt.localizedCaseInsensitiveContains("natural, coherent, and grammatically correct"))

        let sentenceAnalysis = try #require(builtInActions.first { $0.name == "Sentence Analysis" })
        #expect(sentenceAnalysis.prompt.contains("{{appLanguage}}"))
        #expect(sentenceAnalysis.languageDependencies.usesAppLanguage)
        #expect(!sentenceAnalysis.languageDependencies.usesTargetLanguage)
        #expect(sentenceAnalysis.prompt.localizedCaseInsensitiveContains("output format"))
    }

    @Test("Built-in action display names do not change stored names")
    func builtInActionDisplayNamesDoNotChangeStoredNames() {
        for action in AppConfigurationStore.builtInActions {
            #expect(action.displayName == NSLocalizedString(action.name, comment: "Built-in action name"))
            #expect(
                AppConfigurationStore.displayName(forActionName: action.name) ==
                    NSLocalizedString(action.name, comment: "Built-in action name")
            )
        }

        let customCollision = ActionConfig(name: "Polish", prompt: "Use my custom prompt")
        #expect(customCollision.displayName == customCollision.name)
        #expect(!BuiltInActionCatalog.isBuiltInAction(customCollision))
        #expect(AppConfigurationStore.displayName(forActionName: "Custom") == "Custom")
    }

    @Test("Built-in translation prompts include source and target languages")
    func builtInTranslationPromptsIncludeSourceAndTargetLanguages() throws {
        let builtInActions = AppConfigurationStore.builtInActions

        let translate = try #require(builtInActions.first { $0.name == "Translate" })
        #expect(translate.prompt.contains("{{text}}"))
        #expect(translate.prompt.contains("{{sourceLanguage}}"))
        #expect(translate.prompt.contains("{{targetLanguage}}"))
        #expect(PromptSubstitution.containsTextPlaceholder(translate.prompt))
        #expect(translate.languageDependencies.usesSourceLanguage)
        #expect(translate.languageDependencies.usesTargetLanguage)
        #expect(translate.prompt.localizedCaseInsensitiveContains("return only the translated text"))

        let sentenceTranslate = try #require(builtInActions.first { $0.name == "Sentence Translate" })
        #expect(sentenceTranslate.prompt.contains("{{text}}"))
        #expect(sentenceTranslate.prompt.contains("{{sourceLanguage}}"))
        #expect(sentenceTranslate.prompt.contains("{{targetLanguage}}"))
        #expect(PromptSubstitution.containsTextPlaceholder(sentenceTranslate.prompt))
        #expect(sentenceTranslate.languageDependencies.usesSourceLanguage)
        #expect(sentenceTranslate.languageDependencies.usesTargetLanguage)
        #expect(sentenceTranslate.prompt.localizedCaseInsensitiveContains("return original-translation pairs only"))
    }

    @Test("Custom actions preserve display-name collisions")
    func customActionsPreserveBuiltInNameCollisions() {
        let builtIn = AppConfigurationStore.builtInActions[0]
        let collision = ActionConfig(name: "Translate", prompt: "User edited translate", outputType: .plain)
        let actions = [
            builtIn,
            collision,
            ActionConfig(name: "Custom Rewrite", prompt: "Rewrite this", outputType: .diff),
        ]

        let customActions = AppConfigurationStore.customActions(from: actions)

        #expect(customActions.map(\.name) == ["Translate", "Custom Rewrite"])
        #expect(customActions[0].id == collision.id)
        #expect(customActions[0].prompt == "User edited translate")
        #expect(customActions[1].outputType == .diff)
    }

    @Test("Import preserves a custom action named like a built-in")
    func importPreservesBuiltInNameCollision() throws {
        let config = AppConfiguration(actions: [
            .init(name: "Translate", prompt: "Use my custom translation prompt"),
        ])
        let data = try JSONEncoder().encode(config)

        let imported = try ConfigurationService.shared.importConfiguration(from: data).get()

        #expect(imported.actions.count == 1)
        #expect(imported.actions[0].name == "Translate")
        #expect(imported.actions[0].prompt == "Use my custom translation prompt")
    }

    @Test("Action identity survives configuration round-trip")
    func actionIdentitySurvivesRoundTrip() throws {
        let action = ActionConfig(name: "Custom", prompt: "Prompt")
        let config = AppConfiguration(actions: [.from(action)])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        let entry = try #require(decoded.actions.first)
        let restored = entry.toActionConfig()

        #expect(restored.id == action.id)
    }

    @Test("Persisted built-ins use identity and legacy semantic matching")
    func persistedBuiltInsUseIdentityAndLegacySemanticMatching() throws {
        let builtIn = try #require(AppConfigurationStore.builtInActions.first { $0.name == "Translate" })
        let customCollision = AppConfiguration.ActionEntry(
            name: builtIn.name,
            prompt: "Use my custom prompt",
            outputType: builtIn.outputType.rawValue,
            category: builtIn.category.rawValue
        )
        let legacyBuiltIn = AppConfiguration.ActionEntry(
            name: builtIn.name,
            prompt: builtIn.prompt,
            outputType: builtIn.outputType.rawValue,
            category: builtIn.category.rawValue
        )
        let config = AppConfiguration(actions: [
            .from(builtIn),
            legacyBuiltIn,
            customCollision,
        ])

        let filtered = BuiltInActionCatalog.customConfiguration(from: config)

        #expect(filtered.removedBuiltInActions)
        #expect(filtered.config.actions.count == 1)
        #expect(filtered.config.actions[0].prompt == "Use my custom prompt")
        #expect(filtered.config.actions[0].id == nil)
    }

    @MainActor
    @Test("Legacy summarize action is updated to inline text mode")
    func legacySummarizeActionUsesInlineTextMode() throws {
        let store = AppConfigurationStore.makeSnapshotStore()
        store.applyActionsDirectly([
            ActionConfig(
                name: "Summarize",
                prompt: "Provide a concise summary of the selected text, preserving the key meaning.",
                outputType: .plain
            ),
        ])

        let summarize = try #require(store.customActions.first { $0.name == "Summarize" })
        #expect(summarize.prompt.contains("{{text}}"))
        #expect(summarize.prompt.contains("{{targetLanguage}}"))
        #expect(PromptSubstitution.containsTextPlaceholder(summarize.prompt))
    }

    @MainActor
    @Test("Export writes only custom actions")
    func exportWritesOnlyCustomActions() throws {
        let store = AppConfigurationStore.makeSnapshotStore()
        let builtIn = try #require(AppConfigurationStore.builtInActions.first { $0.name == "Translate" })
        let collision = ActionConfig(name: "Translate", prompt: "User edited translate", outputType: .plain)
        let customAction = ActionConfig(name: "Custom Rewrite", prompt: "Rewrite this", outputType: .diff)

        store.applyActionsDirectly([
            builtIn,
            collision,
            customAction,
        ])

        let data = try #require(ConfigurationService.shared.exportConfiguration(from: store, preferences: .shared))
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)

        #expect(configuration.actions.map(\.name) == ["Translate", "Custom Rewrite"])
        #expect(configuration.actions[0].prompt == "User edited translate")
        #expect(configuration.actions[1].prompt == "Rewrite this")
        #expect(store.customActions.map(\.id) == [collision.id, customAction.id])
        #expect(store.isBuiltInAction(builtIn))
        #expect(store.isBuiltInAction(collision) == false)
    }
}
