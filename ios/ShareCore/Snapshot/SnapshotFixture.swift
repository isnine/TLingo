//
//  SnapshotFixture.swift
//  ShareCore
//

import Foundation

public enum SnapshotFixture: String, Sendable {
    case multiModelTranslation = "multi-model-translation"
    case realtimeBilingualLive = "realtime-bilingual-live"
    case realtimeAppleValidation = "realtime-apple-validation"
    case offlineAppleTranslation = "offline-apple-translation"
    case googleTranslation = "google-translation"
    case aiModels = "ai-models"
    case macRealtimeMultiLane = "mac-realtime-multi-lane"
    case macRichConversation = "mac-rich-conversation"
    case macHistoryChat = "mac-history-chat"
}

public enum SnapshotLaunchArguments {
    public static func isSnapshotMode(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("-FASTLANE_SNAPSHOT")
    }

    public static func fixture(in arguments: [String] = ProcessInfo.processInfo.arguments) -> SnapshotFixture? {
        guard let value = value(after: "-SNAPSHOT_FIXTURE", in: arguments) else { return nil }
        return SnapshotFixture(rawValue: value)
    }

    public static func value(after flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

public struct SnapshotRealtimeBilingualLiveFixture {
    public let translationProvider: RealtimeTranslationProvider
    public let sourceLanguage: SourceLanguageOption
    public let targetLanguage: TargetLanguageOption
    public let captionDisplayMode: RealtimeCaptionDisplayMode
    public let sentencePairs: [SentencePair]
    public let pendingSource: String
    public let pendingTranslation: String
    public let sourceTextOverride: String?
    public let translatedTextOverride: String?

    public var sourceText: String {
        sourceTextOverride ?? sentencePairs.map(\.original).joined(separator: "\n\n")
    }

    public var translatedText: String {
        translatedTextOverride ?? sentencePairs.map(\.translation).joined(separator: "\n\n")
    }
}

public enum SnapshotFixtureData {
    private static let defaultTranslatePrompt = "Translate the following text"
    private static let directionalTranslatePrompt =
        [
            "Translate the text below from {{sourceLanguage}} to {{targetLanguage}}.",
            "",
            "Text:",
            "{{text}}",
            "",
            "Rules:",
            "- Preserve the original meaning, tone, and formatting.",
            "- Use natural, fluent {{targetLanguage}}.",
            "- Do NOT add explanations or alternatives.",
            "- Return only the translated text.",
        ].joined(separator: "\n")

    public static let cloudModels: [ModelConfig] = [
        ModelConfig(id: "gpt-5.4", displayName: "GPT-5.4", isPremium: true, tags: ["latest"]),
        ModelConfig(id: "gpt-5", displayName: "GPT-5", isPremium: true),
        ModelConfig(id: "gpt-4.1", displayName: "GPT-4.1", isDefault: true),
        ModelConfig(id: "gpt-5-nano", displayName: "GPT-5 Nano", isDefault: true),
        ModelConfig(id: "deepseek-v3", displayName: "DeepSeek V3"),
        ModelConfig(id: "deepseek-r1", displayName: "DeepSeek R1", isPremium: true),
        ModelConfig(id: "DeepSeek-V4-Pro", displayName: "DeepSeek V4 Pro", isPremium: true),
        ModelConfig(id: "Kimi-K2.6", displayName: "Kimi K2.6", isPremium: true),
    ]

    public static let extensionShowcaseModels: [ModelConfig] = [
        .appleTranslate,
        .googleTranslate,
        cloudModels[0],
        cloudModels[6],
        cloudModels[7],
    ]

    public static func cloudModels(for fixture: SnapshotFixture) -> [ModelConfig] {
        switch fixture {
        case .offlineAppleTranslation, .googleTranslation:
            return []
        case .multiModelTranslation, .realtimeBilingualLive, .realtimeAppleValidation,
             .aiModels, .macRealtimeMultiLane,
             .macRichConversation, .macHistoryChat:
            return cloudModels
        }
    }

    public static func translatePrompt(for fixture: SnapshotFixture) -> String {
        switch fixture {
        case .offlineAppleTranslation, .googleTranslation, .multiModelTranslation:
            return directionalTranslatePrompt
        case .realtimeBilingualLive, .realtimeAppleValidation, .aiModels,
             .macRealtimeMultiLane, .macRichConversation, .macHistoryChat:
            return defaultTranslatePrompt
        }
    }

    public static func resultModels(for fixture: SnapshotFixture) -> [ModelConfig] {
        switch fixture {
        case .multiModelTranslation, .macRichConversation:
            if SnapshotLocaleCatalog.current().id == "ms" {
                return extensionShowcaseModels.filter { $0.id != ModelConfig.appleTranslateID }
            }
            return extensionShowcaseModels
        case .offlineAppleTranslation:
            return [ModelConfig.appleTranslate]
        case .googleTranslation:
            return [ModelConfig.googleTranslate]
        case .realtimeBilingualLive, .realtimeAppleValidation, .aiModels,
             .macRealtimeMultiLane, .macHistoryChat:
            return []
        }
    }

    public static func enabledModelIDs(for fixture: SnapshotFixture) -> Set<String> {
        Set(resultModels(for: fixture).map(\.id))
    }

    public static var inputText: String {
        let locale = SnapshotLocaleCatalog.current()
        return SnapshotLaunchArguments.isExtensionPreview() ? locale.extensionSourceText : locale.sourceText
    }

    public static func resultText(for model: ModelConfig, fixture: SnapshotFixture) -> String {
        let locale = SnapshotLocaleCatalog.current()
        switch fixture {
        case .multiModelTranslation, .macRichConversation:
            return locale.translation(
                for: model.id,
                extensionPreview: SnapshotLaunchArguments.isExtensionPreview()
            )
        case .offlineAppleTranslation:
            return locale.translation(for: ModelConfig.appleTranslateID)
        case .googleTranslation:
            return locale.translation(for: ModelConfig.googleTranslateID)
        case .realtimeBilingualLive, .realtimeAppleValidation, .aiModels,
             .macRealtimeMultiLane, .macHistoryChat:
            return ""
        }
    }

    public static func realtimeFixture(for fixture: SnapshotFixture) -> SnapshotRealtimeBilingualLiveFixture? {
        switch fixture {
        case .realtimeBilingualLive:
            return realtimeBilingualLive()
        case .realtimeAppleValidation:
            return realtimeAppleValidation()
        case .multiModelTranslation, .offlineAppleTranslation, .googleTranslation, .aiModels, .macRealtimeMultiLane,
             .macRichConversation, .macHistoryChat:
            return nil
        }
    }

    public static func macRealtimeLaneSnapshots(
        localeID: String? = nil
    ) -> (snapshots: [RealtimeLaneSnapshot], primaryLaneID: UUID) {
        let lanes = SnapshotLocaleCatalog.macScenes(for: localeID).realtimeLanes.map { fixture in
            guard let provider = RealtimeTranslationProvider(rawValue: fixture.translationProviderID) else {
                preconditionFailure("Invalid snapshot realtime provider: \(fixture.translationProviderID)")
            }
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: fixture.recognitionModelID,
                translationProvider: provider
            )
            let pairs = fixture.segments.map {
                SentencePair(original: $0.source, translation: $0.translation)
            }
            let sourceText = pairs.map(\.original).joined(separator: "\n\n")
            let translatedText = pairs.map(\.translation).joined(separator: "\n\n")
            let captionLines = RealtimeCaptionDisplay.resolvedLines(
                pairs: pairs,
                translatedSource: sourceText,
                translatedText: translatedText,
                pendingSource: fixture.pendingSource,
                pendingTranslation: fixture.pendingTranslation,
                sourceText: sourceText,
                mode: .bilingual
            )
            return RealtimeLaneSnapshot(
                configuration: configuration,
                phase: .translating,
                sourceText: sourceText,
                translatedText: translatedText,
                pendingSourceText: fixture.pendingSource,
                pendingTranslatedText: fixture.pendingTranslation,
                sentencePairs: pairs,
                captionLines: captionLines
            )
        }
        guard let primaryLaneID = lanes.first?.id else {
            preconditionFailure("macOS realtime snapshot requires at least one lane")
        }
        return (lanes, primaryLaneID)
    }

    public static func macConversationMessages(localeID: String? = nil) -> [ChatMessage] {
        SnapshotLocaleCatalog.macScenes(for: localeID).conversation.messages.map {
            ChatMessage(role: $0.role, content: $0.content)
        }
    }

    public static func realtimeBilingualLive(localeID: String? = nil) -> SnapshotRealtimeBilingualLiveFixture {
        let locale = localeID.map(SnapshotLocaleCatalog.configuration(for:)) ?? SnapshotLocaleCatalog.current()
        let translations = locale.realtimeTranslations
        let sources = SnapshotLocaleCatalog.realtimeSourceTexts
        return SnapshotRealtimeBilingualLiveFixture(
            translationProvider: .appleTranslator,
            sourceLanguage: .english,
            targetLanguage: locale.targetLanguage,
            captionDisplayMode: .bilingual,
            sentencePairs: [
                SentencePair(
                    original: sources[0],
                    translation: translations[0]
                ),
                SentencePair(
                    original: sources[1],
                    translation: translations[1]
                ),
            ],
            pendingSource: sources[2],
            pendingTranslation: translations[2],
            sourceTextOverride: nil,
            translatedTextOverride: nil
        )
    }

    public static func realtimeAppleValidation() -> SnapshotRealtimeBilingualLiveFixture {
        let source =
            "This validation recording keeps moving through a long English sentence without giving the caption renderer " +
            "a convenient newline boundary so the display layer has to wrap it while the transcript stays intact"
        let translation =
            "这段验证录音会持续输出一段很长的英文句子，不给字幕渲染器方便的换行边界，因此显示层必须自行换行，同时保持转录文本本身不被改写"
        return SnapshotRealtimeBilingualLiveFixture(
            translationProvider: .appleTranslator,
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese,
            captionDisplayMode: .bilingual,
            sentencePairs: [
                SentencePair(original: source, translation: translation),
            ],
            pendingSource: "The current partial recognition result is also deliberately long and does not contain punctuation",
            pendingTranslation: "当前的部分识别结果也故意很长并且没有标点",
            sourceTextOverride: nil,
            translatedTextOverride: nil
        )
    }
}

private extension SnapshotLaunchArguments {
    static func isExtensionPreview(
        in arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("-SNAPSHOT_EXTENSION_PREVIEW")
    }
}
