//
//  SnapshotFixtureTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("SnapshotFixture")
struct SnapshotFixtureTests {
    @Test("Parses snapshot fixture launch argument")
    func parsesSnapshotFixtureLaunchArgument() {
        let fixture = SnapshotLaunchArguments.fixture(in: [
            "TLingo",
            "-FASTLANE_SNAPSHOT",
            "-SNAPSHOT_FIXTURE",
            "realtime-bilingual-live",
        ])

        #expect(fixture == .realtimeBilingualLive)
    }

    @Test("Multi-model translation fixture uses supported services and model families")
    func multiModelTranslationUsesSupportedServicesAndModelFamilies() {
        let displayNames = SnapshotFixtureData.resultModels(for: .multiModelTranslation).map(\.displayName)

        #expect(displayNames.contains("Apple Translate"))
        #expect(displayNames.contains("Google Translate"))
        #expect(displayNames.contains("GPT-5.4"))
        #expect(displayNames.contains("DeepSeek V4 Pro"))
        #expect(displayNames.contains("Kimi K2.6"))
        #expect(!displayNames.contains { $0.localizedCaseInsensitiveContains("Claude") })
        #expect(!displayNames.contains { $0.localizedCaseInsensitiveContains("Gemini") })
    }

    @Test("Snapshot translation catalog is complete")
    func snapshotTranslationCatalogIsComplete() throws {
        try SnapshotLocaleCatalog.validate()

        #expect(SnapshotLocaleCatalog.supportedIDs.count == 19)
        #expect(SnapshotLocaleCatalog.sourceText.contains("iPhone, iPad, and Mac"))
        #expect(SnapshotLocaleCatalog.sourceText.contains("multiple AI models"))
        #expect(SnapshotLocaleCatalog.sourceText.contains("real-time bilingual voice captions"))
        #expect(SnapshotLocaleCatalog.grammarSourceText.contains("Our team are preparing"))
        #expect(SnapshotLocaleCatalog.grammarCorrectedText.contains("Our team is preparing"))
    }

    @Test("Each snapshot model has a distinct Simplified Chinese translation")
    func simplifiedChineseTranslationsAreDistinct() {
        let locale = SnapshotLocaleCatalog.configuration(for: "zh-Hans")
        let translations = SnapshotFixtureData.resultModels(for: .multiModelTranslation).map {
            locale.translation(for: $0.id)
        }
        let extensionTranslations = SnapshotFixtureData.resultModels(for: .multiModelTranslation).map {
            locale.translation(for: $0.id, extensionPreview: true)
        }

        #expect(translations.count == 5)
        #expect(Set(translations).count == translations.count)
        #expect(translations.allSatisfy {
            $0.contains("TLingo")
                && $0.contains("iPhone")
                && $0.contains("iPad")
                && $0.contains("Mac")
                && (
                    $0.contains("多个 AI 模型")
                        || $0.contains("多种 AI 模型")
                        || $0.contains("多模型")
                )
        })
        #expect(locale.sourceText.contains("multiple AI models"))
        #expect(locale.extensionSourceText.contains("local offline recognition"))
        #expect(Set(extensionTranslations).count == extensionTranslations.count)
        #expect(extensionTranslations.allSatisfy {
            $0.contains("TLingo")
                && $0.contains("本地离线识别")
                && $0.contains("语音识别")
                && $0.contains("实时双语字幕")
        })
    }

    @Test("Offline translation fixture only shows Apple Translate result")
    func offlineTranslationOnlyShowsAppleTranslateResult() {
        let modelIDs = SnapshotFixtureData.resultModels(for: .offlineAppleTranslation).map(\.id)

        #expect(modelIDs == [ModelConfig.appleTranslateID])
    }

    @Test("Google translation fixture only shows Google Translate result")
    func googleTranslationOnlyShowsGoogleTranslateResult() {
        let modelIDs = SnapshotFixtureData.resultModels(for: .googleTranslation).map(\.id)

        #expect(modelIDs == [ModelConfig.googleTranslateID])
    }

    @Test("Offline translation fixture shows explicit source and target language controls")
    func offlineTranslationUsesExplicitLanguageControls() {
        let dependencies = PromptSubstitution.languageDependencies(
            in: SnapshotFixtureData.translatePrompt(for: .offlineAppleTranslation)
        )

        #expect(dependencies.usesSourceLanguage)
        #expect(dependencies.usesTargetLanguage)
    }

    @Test("English realtime fixture keeps English source and target")
    func englishRealtimeFixtureUsesEnglishTarget() {
        let realtime = SnapshotFixtureData.realtimeBilingualLive(localeID: "en-US")

        #expect(realtime.sourceLanguage == .english)
        #expect(realtime.targetLanguage == .englishUnitedStates)
        #expect(realtime.captionDisplayMode == .bilingual)
        #expect(realtime.sentencePairs.first?.original == "The meeting starts in five minutes.")
        #expect(realtime.sentencePairs.first?.translation == "The meeting begins in five minutes.")
        #expect(realtime.pendingSource == "Please open the quarterly report.")
        #expect(realtime.pendingTranslation == "Please open the quarterly report.")
    }

    @Test("Japanese realtime fixture uses Japanese translations")
    func japaneseRealtimeFixtureUsesJapaneseTranslation() {
        let realtime = SnapshotFixtureData.realtimeBilingualLive(localeID: "ja")

        #expect(realtime.sourceLanguage == .english)
        #expect(realtime.targetLanguage == .japanese)
        #expect(realtime.sentencePairs.first?.translation == "会議は5分後に始まります。")
        #expect(realtime.pendingTranslation == "四半期報告書を開いてください。")
    }

    @Test("English macOS scenes include three realtime lanes and rich content")
    func englishMacScenesAreComplete() {
        let scenes = SnapshotLocaleCatalog.macScenes(for: "en-US")

        #expect(scenes.realtimeLanes.count == 3)
        #expect(scenes.realtimeLanes.map(\.recognitionModelID) == [
            RecognitionModelDescriptor.appleSpeech.id,
            RecognitionModelDescriptor.nemotronStreaming1120.id,
            RecognitionModelDescriptor.nemotronStreaming560.id,
        ])
        #expect(scenes.realtimeLanes.map(\.translationProviderID) == [
            RealtimeTranslationProvider.appleTranslator.rawValue,
            RealtimeTranslationProvider.appleTranslationRealtime.rawValue,
            RealtimeTranslationProvider.appleTranslationRealtime.rawValue,
        ])
        #expect(scenes.conversation.messages.last?.content.contains("## Launch update") == true)
        #expect(scenes.history.annotation.contains("### Key decisions"))
        #expect(scenes.history.chatMessages.count == 2)
        #expect(scenes.history.sidebarRecords.count == 4)
        #expect(Set(scenes.history.sidebarRecords.map(\.kind)) == Set(["text", "realtime"]))
    }

    @Test(
        "Localized macOS scenes include complete realtime and history fixtures",
        arguments: ["tr", "id", "ja", "de-DE", "fr-FR", "es-ES", "ko", "pt-BR", "zh-Hant", "ar-SA", "it", "pl", "ms"]
    )
    func localizedMacScenesAreComplete(localeID: String) {
        let scenes = SnapshotLocaleCatalog.macScenes(for: localeID)

        #expect(scenes.realtimeLanes.count == 3)
        #expect(scenes.conversation.messages.count == 4)
        #expect(scenes.history.chatMessages.count == 2)
        #expect(scenes.history.sidebarRecords.count == 4)
        #expect(scenes.history.targetLanguage != "English")
    }

    @Test("macOS realtime fixture builds three populated lane snapshots")
    func macRealtimeFixtureBuildsThreeLanes() {
        let fixture = SnapshotFixtureData.macRealtimeLaneSnapshots(localeID: "en-US")

        #expect(fixture.snapshots.count == 3)
        #expect(fixture.snapshots.first?.id == fixture.primaryLaneID)
        #expect(fixture.snapshots.allSatisfy { !$0.captionLines.isEmpty })
        #expect(fixture.snapshots.allSatisfy { $0.phase == .translating })
    }

    @Test("Polish snapshot includes three distinct model results")
    func polishSnapshotIncludesThreeModels() {
        let results = SnapshotLocaleCatalog.writingPolishedResults

        #expect(Set(results.keys) == Set(["gpt-5.4", "DeepSeek-V4-Pro", "Kimi-K2.6"]))
        #expect(Set(results.values).count == 3)
    }
}
