//
//  SourceLanguageDetector.swift
//  ShareCore
//
//  Created by Zander on 2025/2/9.
//

import Foundation
import NaturalLanguage
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "SourceLanguageDetector")

/// Result of language detection with confidence scoring.
public struct LanguageDetectionResult: Sendable {
    public let language: NLLanguage?
    public let confidence: Double
    public let isReliable: Bool
}

/// Detects the source text language and resolves the target language
/// to avoid translating into the same language as the source.
public enum SourceLanguageDetector {
    // Languages matching TargetLanguageOption/SourceLanguageOption.
    private static let supportedNLLanguages: [NLLanguage] = [
        .english, .arabic, NLLanguage(rawValue: "bn"), .simplifiedChinese, .traditionalChinese,
        NLLanguage(rawValue: "cs"), NLLanguage(rawValue: "da"), .dutch, NLLanguage(rawValue: "fi"),
        .french, .german, NLLanguage(rawValue: "el"), NLLanguage(rawValue: "he"), .hindi,
        NLLanguage(rawValue: "hu"), .indonesian, .italian, .japanese, .korean,
        NLLanguage(rawValue: "ms"), NLLanguage(rawValue: "nb"), .polish, .portuguese,
        NLLanguage(rawValue: "ro"), .russian, .spanish, NLLanguage(rawValue: "sv"),
        NLLanguage(rawValue: "ta"), NLLanguage(rawValue: "te"), .thai, .turkish,
        .ukrainian, NLLanguage(rawValue: "ur"), .vietnamese,
    ]

    // Prior probability hints — common languages get a slight boost
    // to improve detection accuracy for short or ambiguous text.
    private static let languageHints: [NLLanguage: Double] = [
        .english: 2.0,
        .simplifiedChinese: 1.5,
        .traditionalChinese: 0.8,
        .japanese: 0.6,
        .korean: 0.5,
        .french: 0.4, .spanish: 0.4, .italian: 0.4,
        .portuguese: 0.3, .german: 0.3, .russian: 0.3,
        .arabic: 0.2, .thai: 0.2, .vietnamese: 0.2,
        .dutch: 0.2, .polish: 0.2, .turkish: 0.2,
        .indonesian: 0.2, .hindi: 0.2, .ukrainian: 0.2,
        NLLanguage(rawValue: "bn"): 0.1, NLLanguage(rawValue: "cs"): 0.1,
        NLLanguage(rawValue: "da"): 0.1, NLLanguage(rawValue: "el"): 0.1,
        NLLanguage(rawValue: "fi"): 0.1, NLLanguage(rawValue: "he"): 0.1,
        NLLanguage(rawValue: "hu"): 0.1, NLLanguage(rawValue: "ms"): 0.1,
        NLLanguage(rawValue: "nb"): 0.1, NLLanguage(rawValue: "ro"): 0.1,
        NLLanguage(rawValue: "sv"): 0.1, NLLanguage(rawValue: "ta"): 0.1,
        NLLanguage(rawValue: "te"): 0.1, NLLanguage(rawValue: "ur"): 0.1,
    ]

    private static let defaultThreshold: Double = 0.3
    private static let shortTextThreshold: Double = 0.5
    private static let shortTextMaxLength = 10
    private static let shortTextMaxWords = 3
    private static let scriptFallbackMinimumHanScalars = 2
    private static let maxHypotheses = 5

    /// Attempts to detect the dominant language of the given text.
    /// Returns `nil` when confidence is too low.
    public static func detectLanguage(of text: String) -> NLLanguage? {
        detectWithConfidence(of: text).language
    }

    /// Full detection with confidence scoring.
    public static func detectWithConfidence(of text: String) -> LanguageDetectionResult {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = supportedNLLanguages
        recognizer.languageHints = languageHints
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: maxHypotheses)
        let best = hypotheses.max(by: { $0.value < $1.value })

        guard let best else {
            logger.debug("detect characters=\(text.count, privacy: .public) → no hypotheses")
            return LanguageDetectionResult(language: nil, confidence: 0, isReliable: false)
        }

        let isShort = isShortText(text)
        let effectiveThreshold = isShort ? shortTextThreshold : defaultThreshold
        let isReliable = best.value >= effectiveThreshold

        if isReliable {
            let corrected = correctChineseScript(best.key)
            logger
                .debug(
                    """
                    detect chars=\(text.count, privacy: .public) short=\(isShort, privacy: .public) \
                    lang=\(corrected.rawValue, privacy: .public) confidence=\(best.value, privacy: .public)
                    """
                )
            return LanguageDetectionResult(
                language: corrected,
                confidence: best.value,
                isReliable: true
            )
        }

        logger
            .debug(
                "detect chars=\(text.count, privacy: .public) short=\(isShort, privacy: .public) confidence=\(best.value, privacy: .public)"
            )
        return LanguageDetectionResult(
            language: nil,
            confidence: best.value,
            isReliable: false
        )
    }

    /// Detects the source language and returns it as a `Locale.Language`.
    /// Useful when callers need a `Locale.Language` without importing NaturalLanguage.
    public static func detectLocaleLanguage(of text: String) -> Locale.Language? {
        guard let detected = detectLanguage(of: text) else { return nil }
        return Locale.Language(identifier: detected.rawValue)
    }

    /// Detects source language with NLLanguageRecognizer constrained to the given candidates only.
    /// Used in Match mode to improve short-text accuracy.
    public static func detectLocaleLanguageConstrained(
        of text: String,
        candidateCodes: [String]
    ) -> Locale.Language? {
        let constraints = candidateCodes.compactMap { nlLanguage(forCode: $0) }
        guard !constraints.isEmpty else { return detectLocaleLanguage(of: text) }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.languageHints = languageHints.filter { constraints.contains($0.key) }
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: maxHypotheses)
        let sorted = hypotheses.sorted { $0.value > $1.value }
        let isShort = isShortText(text)
        let threshold = isShort ? shortTextThreshold : defaultThreshold

        guard let top = sorted.first, top.value >= threshold else { return nil }
        let corrected = correctChineseScript(top.key)
        return Locale.Language(identifier: corrected.rawValue)
    }

    /// Picks the best target from `candidates` that differs from `sourceCode`.
    /// Priority: iterate candidates in order (app language first, then preferred, then English).
    public static func resolveMatchTarget(
        sourceCode: String?,
        candidates: [TargetLanguageOption]
    ) -> TargetLanguageOption {
        guard let sourceCode, !candidates.isEmpty else {
            return candidates.first ?? .english
        }
        for candidate in candidates {
            if !translationLanguagesAreSame(sourceCode, candidate.rawValue) {
                return candidate
            }
        }
        return candidates.first ?? .english
    }

    ///
    /// Returns the BCP 47 source language code (e.g. "en", "zh-Hans") that auto-detection
    /// resolves to, given the user's target language and preferred language list.
    ///
    /// - Parameters:
    ///   - text: Source text.
    ///   - targetCode: The user-selected target language code (used to bias detection
    ///     away from source == target).
    ///   - preferredLanguages: The user's system language list (for Chinese script correction).
    ///     Defaults to `Locale.preferredLanguages`.
    /// - Returns: A BCP 47 code, or `nil` when detection is inconclusive.
    public static func resolveAutoSourceCode(
        text: String,
        targetCode: String?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String? {
        guard let targetCode, !targetCode.isEmpty else {
            guard let detected = detectLanguage(of: text) else { return nil }
            let corrected = correctChineseScript(detected, preferredLanguages: preferredLanguages)
            return corrected.rawValue
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = supportedNLLanguages
        recognizer.languageHints = languageHints
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: maxHypotheses)
        guard !hypotheses.isEmpty else { return nil }

        let isShort = isShortText(text)
        let threshold = isShort ? shortTextThreshold : defaultThreshold
        let minimumExclusionConfidence = 0.15
        let excludedTopRelativeRatio = 0.3

        let sorted = hypotheses.sorted { $0.value > $1.value }
        let excludedTopConfidence = sorted.first {
            detectionLanguagesAreEquivalent($0.key.rawValue, targetCode)
        }?.value ?? 0
        let relativeFloor = excludedTopConfidence * excludedTopRelativeRatio

        for (lang, confidence) in sorted {
            if detectionLanguagesAreEquivalent(lang.rawValue, targetCode) { continue }
            if confidence < minimumExclusionConfidence { break }
            if confidence < relativeFloor { break }
            let corrected = correctChineseScript(lang, preferredLanguages: preferredLanguages)
            return corrected.rawValue
        }

        if let scriptSourceCode = scriptBasedNonTargetSourceCode(
            in: text,
            excludingTargetCode: targetCode,
            preferredLanguages: preferredLanguages
        ) {
            return scriptSourceCode
        }

        if let top = sorted.first, top.value >= threshold {
            let corrected = correctChineseScript(top.key, preferredLanguages: preferredLanguages)
            return corrected.rawValue
        }
        return nil
    }

    /// Like `detectLocaleLanguage(of:)`, but skips any hypothesis whose base language
    /// matches `targetCode`. Delegates to `resolveAutoSourceCode` for the core logic;
    /// adds full logging.
    public static func detectLocaleLanguage(
        of text: String,
        excludingTargetCode targetCode: String?
    ) -> Locale.Language? {
        guard let targetCode, !targetCode.isEmpty else {
            return detectLocaleLanguage(of: text)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = supportedNLLanguages
        recognizer.languageHints = languageHints
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: maxHypotheses)
        guard !hypotheses.isEmpty else {
            logger
                .debug(
                    "detectExcluding target=\(targetCode, privacy: .public) chars=\(text.count, privacy: .public) no hypotheses"
                )
            return nil
        }

        let isShort = isShortText(text)
        let threshold = isShort ? shortTextThreshold : defaultThreshold
        let minimumExclusionConfidence = 0.15
        let excludedTopRelativeRatio = 0.3

        let sorted = hypotheses.sorted { $0.value > $1.value }
        let excludedTopConfidence = sorted.first {
            detectionLanguagesAreEquivalent($0.key.rawValue, targetCode)
        }?.value ?? 0
        let relativeFloor = excludedTopConfidence * excludedTopRelativeRatio

        for (lang, confidence) in sorted {
            if detectionLanguagesAreEquivalent(lang.rawValue, targetCode) { continue }
            if confidence < minimumExclusionConfidence {
                logger
                    .debug(
                        """
                        detectExcluding target=\(targetCode, privacy: .public) chars=\(text.count, privacy: .public) \
                        rejected=\(lang.rawValue, privacy: .public) confidence=\(confidence, privacy: .public)
                        """
                    )
                break
            }
            if confidence < relativeFloor {
                logger
                    .debug(
                        """
                        detectExcluding target=\(targetCode, privacy: .public) chars=\(text.count, privacy: .public) \
                        rejected=\(lang.rawValue, privacy: .public) confidence=\(confidence, privacy: .public) \
                        floor=\(relativeFloor, privacy: .public)
                        """
                    )
                break
            }
            let corrected = correctChineseScript(lang)
            logger
                .debug(
                    """
                    detectExcluding target=\(targetCode, privacy: .public) chars=\(text.count, privacy: .public) \
                    picked=\(corrected.rawValue, privacy: .public) confidence=\(confidence, privacy: .public)
                    """
                )
            return Locale.Language(identifier: corrected.rawValue)
        }

        if let scriptSourceCode = scriptBasedNonTargetSourceCode(in: text, excludingTargetCode: targetCode) {
            logger.debug(
                "detectExcluding(target=\(targetCode, privacy: .public)) → script=\(scriptSourceCode, privacy: .public)"
            )
            return Locale.Language(identifier: scriptSourceCode)
        }

        // No non-target candidate qualifies — return the unfiltered top hypothesis if reliable.
        if let top = sorted.first, top.value >= threshold {
            let corrected = correctChineseScript(top.key)
            logger
                .debug(
                    """
                    detectExcluding target=\(targetCode, privacy: .public) chars=\(text.count, privacy: .public) \
                    fallback=\(corrected.rawValue, privacy: .public) confidence=\(top.value, privacy: .public)
                    """
                )
            return Locale.Language(identifier: corrected.rawValue)
        }
        logger
            .debug(
                "detectExcluding target=\(targetCode, privacy: .public) chars=\(text.count, privacy: .public) threshold=\(threshold, privacy: .public)"
            )
        return nil
    }

    /// Fallback chain when source detection is inconclusive:
    /// 1. user-pinned `sourceLanguage` (if not `.auto`)
    /// 2. first supported entry in `Locale.preferredLanguages`
    /// 3. English
    public static func fallbackSourceLanguage(
        userPreference: SourceLanguageOption? = nil
    ) -> Locale.Language {
        let preference = userPreference ?? AppPreferences.shared.sourceLanguage
        if preference != .auto {
            return Locale.Language(identifier: preference.rawValue)
        }
        for identifier in Locale.preferredLanguages {
            let components = Locale.Language.Components(identifier: identifier)
            guard let langCode = components.languageCode else { continue }
            var candidate = langCode.identifier
            if let script = components.script {
                candidate += "-" + script.identifier
            }
            if SourceLanguageOption(rawValue: candidate) != nil
                || SourceLanguageOption(rawValue: langCode.identifier) != nil
            {
                return Locale.Language(identifier: candidate)
            }
        }
        return Locale.Language(identifier: "en")
    }

    /// Returns true when two BCP 47 codes refer to the same translation language.
    static func languagesAreSame(_ firstCode: String, _ secondCode: String) -> Bool {
        translationLanguagesAreSame(firstCode, secondCode)
    }

    // MARK: - Private Helpers

    /// Reconciles zh-Hans / zh-Hant detection against the user's
    /// `preferredLanguages`. NLLanguageRecognizer cannot reliably
    /// distinguish scripts for short Han text like "你好"; if the detected
    /// script is absent from the user's preferred list but the other script
    /// is present, swap to what the user actually has.
    static func correctChineseScript(
        _ detected: NLLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> NLLanguage {
        guard detected == .simplifiedChinese || detected == .traditionalChinese else {
            return detected
        }
        var hasHans = false
        var hasHant = false
        for identifier in preferredLanguages {
            let components = Locale.Language.Components(identifier: identifier)
            guard components.languageCode?.identifier == "zh" else { continue }
            switch components.script?.identifier {
            case "Hans": hasHans = true
            case "Hant": hasHant = true
            default: break
            }
        }
        if detected == .traditionalChinese, !hasHant, hasHans {
            return .simplifiedChinese
        }
        if detected == .simplifiedChinese, !hasHans, hasHant {
            return .traditionalChinese
        }
        return detected
    }

    /// Treats text as "short" when either the character count or the
    /// word count is small. Word count uses Unicode word boundaries so
    /// that languages without spaces (CJK) are not mis-classified.
    private static func isShortText(_ text: String) -> Bool {
        if text.count <= shortTextMaxLength { return true }
        var wordCount = 0
        text.enumerateSubstrings(
            in: text.startIndex ..< text.endIndex,
            options: [.byWords, .localized]
        ) { _, _, _, stop in
            wordCount += 1
            if wordCount > shortTextMaxWords {
                stop = true
            }
        }
        return wordCount <= shortTextMaxWords
    }

    private static func scriptBasedNonTargetSourceCode(
        in text: String,
        excludingTargetCode targetCode: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String? {
        guard hanScalarCount(in: text) >= scriptFallbackMinimumHanScalars else {
            return nil
        }
        // Kana means Japanese, not Chinese; let the regular fallback decide.
        let containsKana = text.unicodeScalars.contains {
            (0x3041 ... 0x3096).contains($0.value) || (0x30A1 ... 0x30FA).contains($0.value)
        }
        guard !containsKana else {
            return nil
        }

        let corrected = correctChineseScript(.simplifiedChinese, preferredLanguages: preferredLanguages)
        let code = corrected.rawValue
        guard !detectionLanguagesAreEquivalent(code, targetCode) else {
            return nil
        }
        return code
    }

    private static func hanScalarCount(in text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where isHanScalar(scalar) {
            count += 1
            if count >= scriptFallbackMinimumHanScalars {
                return count
            }
        }
        return count
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400 ... 0x4DBF,
             0x4E00 ... 0x9FFF,
             0xF900 ... 0xFAFF,
             0x20000 ... 0x2A6DF,
             0x2A700 ... 0x2B73F,
             0x2B740 ... 0x2B81F,
             0x2B820 ... 0x2CEAF,
             0x2CEB0 ... 0x2EBEF,
             0x30000 ... 0x3134F:
            return true
        default:
            return false
        }
    }

    static func detectionLanguagesAreEquivalent(_ firstCode: String, _ secondCode: String) -> Bool {
        if translationLanguagesAreSame(firstCode, secondCode) {
            return true
        }

        let firstComponents = Locale.Language.Components(identifier: firstCode)
        let secondComponents = Locale.Language.Components(identifier: secondCode)
        guard firstComponents.languageCode == secondComponents.languageCode else {
            return false
        }

        return firstComponents.script != nil && secondComponents.script != nil
    }

    private static func translationLanguagesAreSame(_ firstCode: String, _ secondCode: String) -> Bool {
        if firstCode == secondCode { return true }

        let firstBase = baseLanguage(firstCode)
        let secondBase = baseLanguage(secondCode)
        if firstBase == secondBase { return true }

        let firstComponents = Locale.Language.Components(identifier: firstCode)
        let secondComponents = Locale.Language.Components(identifier: secondCode)
        guard let firstLanguage = firstComponents.languageCode?.identifier,
              let secondLanguage = secondComponents.languageCode?.identifier,
              firstLanguage == secondLanguage
        else {
            return false
        }

        let firstScript = effectiveTranslationScript(
            components: firstComponents,
            languageCode: firstLanguage
        )
        let secondScript = effectiveTranslationScript(
            components: secondComponents,
            languageCode: secondLanguage
        )
        if firstScript != nil || secondScript != nil {
            return firstScript == secondScript
        }

        return true
    }

    private static func effectiveTranslationScript(
        components: Locale.Language.Components,
        languageCode: String
    ) -> String? {
        if let script = components.script?.identifier {
            return script
        }
        if languageCode == "zh" {
            switch components.region?.identifier {
            case "TW", "HK", "MO":
                return "Hant"
            case "CN", "SG":
                return "Hans"
            default:
                return "Hans"
            }
        }
        return defaultScript(forLanguageCode: languageCode)
    }

    /// Default script for a language code, used to ignore redundant script tags
    /// (e.g. "en-Latn" is just "en"). Only languages whose detector output may
    /// include a script tag need to be listed here.
    private static func defaultScript(forLanguageCode code: String) -> String? {
        switch code {
        case "en", "fr", "de", "es", "it", "pt", "nl", "pl", "tr", "id", "vi":
            return "Latn"
        case "ru", "uk":
            return "Cyrl"
        case "ar":
            return "Arab"
        case "ja":
            return "Jpan"
        case "ko":
            return "Kore"
        case "th":
            return "Thai"
        case "hi":
            return "Deva"
        default:
            return nil
        }
    }

    /// Extracts the base language (language + script if present) from an identifier.
    /// "en-US" → "en", "zh-Hans-CN" → "zh-Hans", "zh-Hans" → "zh-Hans"
    private static func baseLanguage(_ identifier: String) -> String {
        let components = Locale.Language.Components(identifier: identifier)
        guard let langCode = components.languageCode else { return identifier }
        var base = langCode.identifier
        if let script = components.script {
            base += "-" + script.identifier
        }
        return base
    }

    /// Maps a BCP 47 code to `NLLanguage` by matching against `supportedNLLanguages`.
    private static func nlLanguage(forCode code: String) -> NLLanguage? {
        let language = NLLanguage(rawValue: code)
        if supportedNLLanguages.contains(language) { return language }
        let base = baseLanguage(code)
        let baseLanguage = NLLanguage(rawValue: base)
        if supportedNLLanguages.contains(baseLanguage) { return baseLanguage }
        return nil
    }
}
