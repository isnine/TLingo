#if os(iOS)
    import Foundation
    import Speech
    #if canImport(Translation)
        import Translation
    #endif

    public enum RealtimeIPhoneAudioSpeechAuthorization: Equatable, Sendable {
        case authorized
        case notDetermined
        case denied
        case restricted
        case unknown
    }

    public enum RealtimeIPhoneAudioTranslationPackStatus: Equatable, Sendable {
        case installed
        case supported
        case unsupported
        case unavailable
        case timedOut
        case unknown
    }

    public enum RealtimeIPhoneAudioPreflightFailure: Equatable, LocalizedError, Sendable {
        case missingSourceLanguage
        case missingTargetLanguage
        case speechNotAuthorized
        case translationPackNotInstalled
        case translationPairUnsupported
        case appleTranslateTimedOut
        case appleTranslateUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingSourceLanguage:
                return String(localized: "Select a source language before starting iPhone Audio.")
            case .missingTargetLanguage:
                return String(localized: "Select a target language before starting iPhone Audio.")
            case .speechNotAuthorized:
                return String(localized: "Enable Speech Recognition access in Settings before starting iPhone Audio.")
            case .translationPackNotInstalled:
                return String(localized: "Apple Translate has not downloaded this language pair. Use Apple Translate in the main app once, then start iPhone Audio again.")
            case .translationPairUnsupported:
                return String(localized: "Apple Translate does not support the selected language pair.")
            case .appleTranslateTimedOut:
                let format = String(localized: "Apple Translate did not respond within %d seconds. Please try again.")
                return String(format: format, AppleTranslationService.operationTimeoutSeconds)
            case .appleTranslateUnavailable:
                return AppleTranslationService.shared.availabilityStatus
            }
        }
    }

    public enum RealtimeIPhoneAudioPreflight {
        public static func validate(
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption,
            speechAuthorization: RealtimeIPhoneAudioSpeechAuthorization,
            translationPackStatus: RealtimeIPhoneAudioTranslationPackStatus
        ) -> RealtimeIPhoneAudioPreflightFailure? {
            guard sourceLanguage != .auto else { return .missingSourceLanguage }
            guard targetLanguage != .appLanguage else { return .missingTargetLanguage }
            guard speechAuthorization == .authorized else { return .speechNotAuthorized }
            if let source = sourceLanguage.localeLanguage,
               RealtimeLanguageMatcher.matches(source, targetLanguage.localeLanguage) {
                return nil
            }

            switch translationPackStatus {
            case .installed:
                return nil
            case .supported:
                return .translationPackNotInstalled
            case .unsupported:
                return .translationPairUnsupported
            case .timedOut:
                return .appleTranslateTimedOut
            case .unavailable, .unknown:
                return .appleTranslateUnavailable
            }
        }

        public static func currentSpeechAuthorization() -> RealtimeIPhoneAudioSpeechAuthorization {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                return .authorized
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            @unknown default:
                return .unknown
            }
        }

        public static func requestSpeechAuthorizationIfNeeded() async -> RealtimeIPhoneAudioSpeechAuthorization {
            guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
                return currentSpeechAuthorization()
            }

            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume(returning: currentSpeechAuthorization())
                }
            }
        }

        public static func evaluateAfterRequestingSpeechAuthorization(
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption
        ) async -> RealtimeIPhoneAudioPreflightFailure? {
            let speechAuthorization = await requestSpeechAuthorizationIfNeeded()
            guard sourceLanguage != .auto else {
                return validate(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    speechAuthorization: speechAuthorization,
                    translationPackStatus: .unknown
                )
            }
            guard targetLanguage != .appLanguage else {
                return validate(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    speechAuthorization: speechAuthorization,
                    translationPackStatus: .unknown
                )
            }

            let packStatus = await translationPackStatus(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            return validate(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                speechAuthorization: speechAuthorization,
                translationPackStatus: packStatus
            )
        }

        public static func evaluate(
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption
        ) async -> RealtimeIPhoneAudioPreflightFailure? {
            guard sourceLanguage != .auto else {
                return validate(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    speechAuthorization: currentSpeechAuthorization(),
                    translationPackStatus: .unknown
                )
            }
            guard targetLanguage != .appLanguage else {
                return validate(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    speechAuthorization: currentSpeechAuthorization(),
                    translationPackStatus: .unknown
                )
            }

            let packStatus = await translationPackStatus(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            return validate(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                speechAuthorization: currentSpeechAuthorization(),
                translationPackStatus: packStatus
            )
        }

        public static func translationPackStatus(
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption
        ) async -> RealtimeIPhoneAudioTranslationPackStatus {
            guard AppleTranslationService.shared.isAvailable else { return .unavailable }
            guard let source = sourceLanguage.localeLanguage else { return .unknown }
            let target = targetLanguage.localeLanguage

            #if canImport(Translation)
                guard #available(iOS 17.4, *) else { return .unavailable }
                let status: LanguageAvailability.Status
                do {
                    status = try await AppleTranslationService.shared.languageAvailabilityStatus(source: source, target: target)
                } catch is CancellationError {
                    return .unknown
                } catch {
                    return .timedOut
                }
                switch status {
                case .installed:
                    return .installed
                case .supported:
                    return .supported
                case .unsupported:
                    return .unsupported
                @unknown default:
                    return .unknown
                }
            #else
                return .unavailable
            #endif
        }
    }
#endif
