#if os(macOS) || os(iOS)
    import Foundation

    public enum RealtimeTranslationProvider: String, CaseIterable, Codable, Identifiable, Sendable {
        case appleTranslator = "apple_translator"
        case appleTranslationRealtime = "apple_translation_realtime"
        case transcriptionOnly = "none"

        public static let `default`: RealtimeTranslationProvider = .appleTranslator

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .appleTranslator:
                return String(localized: "Apple Translator")
            case .appleTranslationRealtime:
                return String(localized: "Apple Translation Realtime")
            case .transcriptionOnly:
                return String(localized: "None")
            }
        }

        public var systemImage: String {
            switch self {
            case .appleTranslator:
                return "apple.logo"
            case .appleTranslationRealtime:
                return "captions.bubble.fill"
            case .transcriptionOnly:
                return "text.alignleft"
            }
        }

        public var usesAppleTextTranslation: Bool {
            switch self {
            case .appleTranslator, .appleTranslationRealtime:
                return true
            case .transcriptionOnly:
                return false
            }
        }

        public var performsTranslation: Bool {
            self != .transcriptionOnly
        }

        public var isAvailableOnCurrentOS: Bool {
            switch self {
            case .appleTranslationRealtime:
                if #available(iOS 26.4, macOS 26.4, *) {
                    return true
                }
                return false
            case .appleTranslator, .transcriptionOnly:
                return true
            }
        }

        public static var availableCases: [RealtimeTranslationProvider] {
            allCases.filter(\.isAvailableOnCurrentOS)
        }

        public var modelID: String {
            model.id
        }

        public var model: ModelConfig {
            switch self {
            case .appleTranslator:
                return .appleTranslate
            case .appleTranslationRealtime:
                return ModelConfig(
                    id: "apple-translation-realtime",
                    displayName: "Apple Translation Realtime",
                    isDefault: true,
                    isPremium: false
                )
            case .transcriptionOnly:
                return ModelConfig(
                    id: rawValue,
                    displayName: "None",
                    isDefault: true,
                    isPremium: false
                )
            }
        }
    }

    enum RealtimeLanguageMatcher {
        static func matches(_ source: Locale.Language, _ target: Locale.Language) -> Bool {
            SourceLanguageDetector.languagesAreSame(
                source.maximalIdentifier,
                target.maximalIdentifier
            )
        }
    }

    enum RealtimeTranslationError: Error {
        case transcriptionOnly
    }

    enum RealtimeTranslationService {
        static func translate(_ request: RealtimeTextTranslationRequest) async throws -> ModelExecutionResult {
            switch request.provider {
            case .appleTranslator:
                return try await AppleTranslationService.shared.translateSentencesWithInstalledLanguages(
                    text: request.translationText,
                    source: request.source,
                    target: request.targetLanguage.localeLanguage
                )
            case .appleTranslationRealtime:
                return try await AppleTranslationService.shared.translateRealtimeSentencesWithInstalledLanguages(
                    text: request.translationText,
                    source: request.source,
                    target: request.targetLanguage.localeLanguage
                )
            case .transcriptionOnly:
                throw RealtimeTranslationError.transcriptionOnly
            }
        }
    }
#endif
