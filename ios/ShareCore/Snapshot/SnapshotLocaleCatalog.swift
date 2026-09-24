//
//  SnapshotLocaleCatalog.swift
//  ShareCore
//

import Foundation

public struct SnapshotLocaleConfiguration {
    public let id: String
    public let appleLanguage: String
    public let appleLocale: String
    public let targetLanguage: TargetLanguageOption
    public let targetLanguageLabel: String
    public let grammarExplanation: String
    public let documentTitle: String
    public let extensionTitle: String
    public let realtimeTranslations: [String]
    fileprivate let translations: [String: String]
    fileprivate let extensionTranslations: [String: String]?

    public var sourceText: String {
        sourceTextOverride ?? SnapshotLocaleCatalog.sourceText
    }

    public var extensionSourceText: String {
        extensionSourceTextOverride ?? sourceText
    }

    fileprivate let sourceTextOverride: String?
    fileprivate let extensionSourceTextOverride: String?

    public func translation(for modelID: String, extensionPreview: Bool = false) -> String {
        let values = extensionPreview ? (extensionTranslations ?? translations) : translations
        guard let translation = values[modelID], !translation.isEmpty else {
            preconditionFailure("Missing snapshot translation for \(id) / \(modelID)")
        }
        return translation
    }
}

public struct SnapshotChatMessageFixture {
    public let role: String
    public let content: String
}

public struct SnapshotMacRealtimeSegmentFixture {
    public let source: String
    public let translation: String
}

public struct SnapshotMacRealtimeLaneFixture {
    public let recognitionModelID: String
    public let translationProviderID: String
    public let segments: [SnapshotMacRealtimeSegmentFixture]
    public let pendingSource: String
    public let pendingTranslation: String
}

public struct SnapshotMacConversationFixture {
    public let messages: [SnapshotChatMessageFixture]
}

public struct SnapshotMacHistoryFixture {
    public let sourceText: String
    public let actionName: String
    public let targetLanguage: String
    public let modelID: String
    public let modelDisplayName: String
    public let resultText: String
    public let annotation: String
    public let chatMessages: [SnapshotChatMessageFixture]
    public let sidebarRecords: [SnapshotMacHistoryRecordFixture]
}

public struct SnapshotMacHistoryRecordFixture {
    public let kind: String
    public let sourceText: String
    public let actionName: String
    public let targetLanguage: String
    public let modelID: String
    public let modelDisplayName: String
    public let resultText: String
}

public struct SnapshotMacSceneConfiguration {
    public let realtimeLanes: [SnapshotMacRealtimeLaneFixture]
    public let conversation: SnapshotMacConversationFixture
    public let history: SnapshotMacHistoryFixture
}

public enum SnapshotLocaleCatalog {
    public static var supportedIDs: [String] { document.localeOrder }
    public static var sourceText: String { document.sourceText }
    public static var writingPolishedText: String { document.writingPolishedText }
    public static var writingPolishedResults: [String: String] { document.writingPolishedResults }
    public static var realtimeSourceTexts: [String] { document.realtimeSourceTexts }
    public static var grammarSourceText: String { document.grammar.sourceText }
    public static var grammarCorrectedText: String { document.grammar.correctedText }

    public static func macScenes(for localeID: String? = nil) -> SnapshotMacSceneConfiguration {
        let id = localeID ?? current().id
        guard let scenes = document.macScenes[id] else {
            preconditionFailure("Missing macOS snapshot scenes for \(id)")
        }
        return scenes.configuration
    }

    public static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> SnapshotLocaleConfiguration {
        if let explicit = SnapshotLaunchArguments.value(after: "-SNAPSHOT_LOCALE", in: arguments) {
            return configuration(for: explicit)
        }

        let preferred = Locale.preferredLanguages.first ?? ""
        if document.locales[preferred] != nil {
            return configuration(for: preferred)
        }
        if preferred.hasPrefix("zh-Hant") {
            return configuration(for: "zh-Hant")
        }
        if preferred.hasPrefix("zh") {
            return configuration(for: "zh-Hans")
        }

        let languageCode = preferred.split(separator: "-").first.map(String.init) ?? preferred
        if let id = document.localeOrder.first(where: {
            document.locales[$0]?.appleLanguage == languageCode
        }) {
            return configuration(for: id)
        }
        return configuration(for: "en-US")
    }

    public static func configuration(for id: String?) -> SnapshotLocaleConfiguration {
        let resolvedID: String
        if let id {
            guard document.locales[id] != nil else {
                preconditionFailure("Missing snapshot locale configuration: \(id)")
            }
            resolvedID = id
        } else {
            resolvedID = "en-US"
        }
        guard let fixture = document.locales[resolvedID],
              let targetLanguage = TargetLanguageOption(rawValue: fixture.targetLanguage)
        else {
            preconditionFailure("Invalid snapshot locale configuration: \(resolvedID)")
        }
        return SnapshotLocaleConfiguration(
            id: resolvedID,
            appleLanguage: fixture.appleLanguage,
            appleLocale: fixture.appleLocale,
            targetLanguage: targetLanguage,
            targetLanguageLabel: fixture.targetLanguageLabel,
            grammarExplanation: fixture.grammarExplanation,
            documentTitle: fixture.documentTitle,
            extensionTitle: fixture.extensionTitle,
            realtimeTranslations: fixture.realtimeTranslations,
            translations: fixture.translations,
            extensionTranslations: fixture.extensionTranslations,
            sourceTextOverride: fixture.sourceText,
            extensionSourceTextOverride: fixture.extensionSourceText
        )
    }

    public static func validate() throws {
        let expectedModels = Set(document.modelOrder)
        guard document.localeOrder.count == 19 else {
            throw SnapshotCatalogError.invalidLocaleCount(document.localeOrder.count)
        }
        guard document.realtimeSourceTexts.count == 3 else {
            throw SnapshotCatalogError.invalidRealtimeTranslations("source")
        }
        for (id, scenes) in document.macScenes {
            guard document.locales[id] != nil else {
                throw SnapshotCatalogError.missingLocale(id)
            }
            try validateMacScenes(scenes, locale: id)
        }
        for id in document.localeOrder {
            guard let locale = document.locales[id] else {
                throw SnapshotCatalogError.missingLocale(id)
            }
            let actualModels = Set(locale.translations.keys)
            guard actualModels == expectedModels else {
                throw SnapshotCatalogError.invalidModels(
                    locale: id,
                    missing: Array(expectedModels.subtracting(actualModels)).sorted(),
                    unexpected: Array(actualModels.subtracting(expectedModels)).sorted()
                )
            }
            guard locale.translations.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw SnapshotCatalogError.emptyTranslation(id)
            }
            guard Set(locale.translations.values).count == expectedModels.count else {
                throw SnapshotCatalogError.duplicateTranslations(id)
            }
            if let extensionTranslations = locale.extensionTranslations {
                guard Set(extensionTranslations.keys) == expectedModels else {
                    throw SnapshotCatalogError.invalidModels(
                        locale: "\(id)/extension",
                        missing: Array(expectedModels.subtracting(extensionTranslations.keys)).sorted(),
                        unexpected: Array(Set(extensionTranslations.keys).subtracting(expectedModels)).sorted()
                    )
                }
                guard extensionTranslations.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      Set(extensionTranslations.values).count == expectedModels.count
                else {
                    throw SnapshotCatalogError.duplicateTranslations("\(id)/extension")
                }
                for translation in extensionTranslations.values {
                    guard (locale.extensionRequiredTerms ?? []).allSatisfy({ translation.contains($0) }) else {
                        throw SnapshotCatalogError.missingRequiredTerm(
                            locale: "\(id)/extension",
                            translation: translation
                        )
                    }
                    guard (locale.extensionRequiredConcepts ?? []).allSatisfy({ alternatives in
                        alternatives.contains(where: translation.contains)
                    }) else {
                        throw SnapshotCatalogError.missingRequiredConcept(
                            locale: "\(id)/extension",
                            translation: translation
                        )
                    }
                }
            }
            guard !locale.grammarExplanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SnapshotCatalogError.emptyGrammarExplanation(id)
            }
            guard locale.realtimeTranslations.count == 3,
                  locale.realtimeTranslations.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  })
            else {
                throw SnapshotCatalogError.invalidRealtimeTranslations(id)
            }
            for translation in locale.translations.values {
                guard locale.requiredTerms.allSatisfy({ translation.contains($0) }) else {
                    throw SnapshotCatalogError.missingRequiredTerm(locale: id, translation: translation)
                }
                guard locale.requiredConcepts.allSatisfy({ alternatives in
                    alternatives.contains(where: translation.contains)
                }) else {
                    throw SnapshotCatalogError.missingRequiredConcept(locale: id, translation: translation)
                }
            }
        }
    }

    private static func validateMacScenes(
        _ scenes: SnapshotMacSceneFixture,
        locale: String
    ) throws {
        let expectedLanes = if locale == "ms" {
            [
                (
                    RecognitionModelDescriptor.appleSpeech.id,
                    RealtimeTranslationProvider.appleTranslationRealtime.rawValue
                ),
                (
                    RecognitionModelDescriptor.nemotronStreaming1120.id,
                    RealtimeTranslationProvider.appleTranslationRealtime.rawValue
                ),
                (
                    RecognitionModelDescriptor.nemotronStreaming560.id,
                    RealtimeTranslationProvider.appleTranslationRealtime.rawValue
                ),
            ]
        } else {
            [
                (RecognitionModelDescriptor.appleSpeech.id, RealtimeTranslationProvider.appleTranslator.rawValue),
                (
                    RecognitionModelDescriptor.nemotronStreaming1120.id,
                    RealtimeTranslationProvider.appleTranslationRealtime.rawValue
                ),
                (
                    RecognitionModelDescriptor.nemotronStreaming560.id,
                    RealtimeTranslationProvider.appleTranslationRealtime.rawValue
                ),
            ]
        }
        let actualLanes = scenes.realtimeLanes.map {
            ($0.recognitionModelID, $0.translationProviderID)
        }
        guard actualLanes.elementsEqual(expectedLanes, by: {
            $0.0 == $1.0 && $0.1 == $1.1
        }) else {
            throw SnapshotCatalogError.invalidMacRealtimeLanes(locale)
        }
        guard scenes.realtimeLanes.allSatisfy({
            !$0.segments.isEmpty &&
                $0.segments.allSatisfy {
                    !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }) else {
            throw SnapshotCatalogError.invalidMacRealtimeLanes(locale)
        }
        guard scenes.conversation.messages.contains(where: { $0.role == "user" }),
              scenes.conversation.messages.contains(where: { $0.role == "assistant" })
        else {
            throw SnapshotCatalogError.invalidMacConversation(locale)
        }
        guard !scenes.history.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scenes.history.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scenes.history.annotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scenes.history.sidebarRecords.isEmpty,
              scenes.history.sidebarRecords.allSatisfy({
                  !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !$0.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              scenes.history.chatMessages.contains(where: { $0.role == "user" }),
              scenes.history.chatMessages.contains(where: { $0.role == "assistant" })
        else {
            throw SnapshotCatalogError.invalidMacHistory(locale)
        }
    }

    private static let document: SnapshotCatalogDocument = {
        let bundles = [
            Bundle(for: SnapshotBundleToken.self),
            Bundle.main,
        ]
        for bundle in bundles {
            guard let url = bundle.url(forResource: "SnapshotTranslations", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(SnapshotCatalogDocument.self, from: data)
            else {
                continue
            }
            return decoded
        }
        preconditionFailure("SnapshotTranslations.json is missing from the app bundle")
    }()
}

public enum SnapshotCatalogError: Error, Equatable {
    case invalidLocaleCount(Int)
    case missingLocale(String)
    case invalidModels(locale: String, missing: [String], unexpected: [String])
    case emptyTranslation(String)
    case duplicateTranslations(String)
    case emptyGrammarExplanation(String)
    case invalidRealtimeTranslations(String)
    case missingRequiredTerm(locale: String, translation: String)
    case missingRequiredConcept(locale: String, translation: String)
    case missingMacScenes(String)
    case invalidMacRealtimeLanes(String)
    case invalidMacConversation(String)
    case invalidMacHistory(String)
}

private final class SnapshotBundleToken {}

private struct SnapshotCatalogDocument: Decodable {
    let version: Int
    let sourceText: String
    let writingPolishedText: String
    let writingPolishedResults: [String: String]
    let realtimeSourceTexts: [String]
    let modelOrder: [String]
    let localeOrder: [String]
    let grammar: SnapshotGrammarFixture
    let macScenes: [String: SnapshotMacSceneFixture]
    let locales: [String: SnapshotLocaleFixture]
}

private struct SnapshotGrammarFixture: Decodable {
    let sourceText: String
    let correctedText: String
}

private struct SnapshotLocaleFixture: Decodable {
    let appleLanguage: String
    let appleLocale: String
    let targetLanguage: String
    let targetLanguageLabel: String
    let documentTitle: String
    let extensionTitle: String
    let grammarExplanation: String
    let realtimeTranslations: [String]
    let sourceText: String?
    let extensionSourceText: String?
    let requiredTerms: [String]
    let requiredConcepts: [[String]]
    let extensionRequiredTerms: [String]?
    let extensionRequiredConcepts: [[String]]?
    let translations: [String: String]
    let extensionTranslations: [String: String]?
}

private struct SnapshotChatMessageDocument: Decodable {
    let role: String
    let content: String

    var fixture: SnapshotChatMessageFixture {
        SnapshotChatMessageFixture(role: role, content: content)
    }
}

private struct SnapshotMacRealtimeSegmentDocument: Decodable {
    let source: String
    let translation: String

    var fixture: SnapshotMacRealtimeSegmentFixture {
        SnapshotMacRealtimeSegmentFixture(source: source, translation: translation)
    }
}

private struct SnapshotMacRealtimeLaneDocument: Decodable {
    let recognitionModelID: String
    let translationProviderID: String
    let segments: [SnapshotMacRealtimeSegmentDocument]
    let pendingSource: String
    let pendingTranslation: String

    var fixture: SnapshotMacRealtimeLaneFixture {
        SnapshotMacRealtimeLaneFixture(
            recognitionModelID: recognitionModelID,
            translationProviderID: translationProviderID,
            segments: segments.map(\.fixture),
            pendingSource: pendingSource,
            pendingTranslation: pendingTranslation
        )
    }
}

private struct SnapshotMacConversationDocument: Decodable {
    let messages: [SnapshotChatMessageDocument]

    var fixture: SnapshotMacConversationFixture {
        SnapshotMacConversationFixture(messages: messages.map(\.fixture))
    }
}

private struct SnapshotMacHistoryDocument: Decodable {
    let sourceText: String
    let actionName: String
    let targetLanguage: String
    let modelID: String
    let modelDisplayName: String
    let resultText: String
    let annotation: String
    let chatMessages: [SnapshotChatMessageDocument]
    let sidebarRecords: [SnapshotMacHistoryRecordDocument]

    var fixture: SnapshotMacHistoryFixture {
        SnapshotMacHistoryFixture(
            sourceText: sourceText,
            actionName: actionName,
            targetLanguage: targetLanguage,
            modelID: modelID,
            modelDisplayName: modelDisplayName,
            resultText: resultText,
            annotation: annotation,
            chatMessages: chatMessages.map(\.fixture),
            sidebarRecords: sidebarRecords.map(\.fixture)
        )
    }
}

private struct SnapshotMacHistoryRecordDocument: Decodable {
    let kind: String
    let sourceText: String
    let actionName: String
    let targetLanguage: String
    let modelID: String
    let modelDisplayName: String
    let resultText: String

    var fixture: SnapshotMacHistoryRecordFixture {
        SnapshotMacHistoryRecordFixture(
            kind: kind,
            sourceText: sourceText,
            actionName: actionName,
            targetLanguage: targetLanguage,
            modelID: modelID,
            modelDisplayName: modelDisplayName,
            resultText: resultText
        )
    }
}

private struct SnapshotMacSceneFixture: Decodable {
    let realtimeLanes: [SnapshotMacRealtimeLaneDocument]
    let conversation: SnapshotMacConversationDocument
    let history: SnapshotMacHistoryDocument

    var configuration: SnapshotMacSceneConfiguration {
        SnapshotMacSceneConfiguration(
            realtimeLanes: realtimeLanes.map(\.fixture),
            conversation: conversation.fixture,
            history: history.fixture
        )
    }
}
