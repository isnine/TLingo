//
//  SourceLanguageDetectorTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("SourceLanguageDetector.resolveAutoSourceCode")
struct SourceLanguageDetectorTests {
    // MARK: - Mixed language with target exclusion

    @Test("Predominantly Chinese text with target=en → zh-Hans")
    func mixedChineseEnglish_targetEnglish() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "今天天气很好，我们一起去散步吧，阳光明媚。",
            targetCode: "en",
            preferredLanguages: ["en", "zh-Hans"]
        )
        #expect(result == "zh-Hans")
    }

    @Test("Chinese+English text with target=zh-Hans → en")
    func mixedChineseEnglish_targetChinese() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "你好, hello",
            targetCode: "zh-Hans",
            preferredLanguages: ["en", "zh-Hans"]
        )
        #expect(result == "en")
    }

    @Test("English sentence with Chinese segments and target=en → zh-Hans")
    func englishSentenceWithChineseSegments_targetEnglish() {
        let mixedText = "i noticed that there have a issue about the sentence/text 可能突然闪烁一下, " +
            "especifily when the one sentence is 即将结束的时候。"
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: mixedText,
            targetCode: "en",
            preferredLanguages: ["en", "zh-Hans"]
        )
        #expect(result == "zh-Hans")
    }

    @Test("Locale detection excludes English and uses Chinese segments")
    func localeDetectionWithChineseSegments_targetEnglish() {
        let mixedText = "i noticed that there have a issue about the sentence/text 可能突然闪烁一下, " +
            "especifily when the one sentence is 即将结束的时候。"
        let result = SourceLanguageDetector.detectLocaleLanguage(
            of: mixedText,
            excludingTargetCode: "en"
        )
        #expect(result == Locale.Language(identifier: "zh-Hans"))
    }

    // MARK: - Short text

    @Test("'hey' with target=en returns en (source==target fallback)")
    func shortEnglishWord_targetEnglish() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "hey",
            targetCode: "en",
            preferredLanguages: ["en"]
        )
        #expect(result == "en")
    }

    @Test("'hey' with target=zh-Hans returns en")
    func shortEnglishWord_targetChinese() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "hey",
            targetCode: "zh-Hans",
            preferredLanguages: ["en"]
        )
        #expect(result == "en")
    }

    @Test("Short ASCII text with target=zh-Hans → en")
    func shortAscii_targetChinese() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "good morning",
            targetCode: "zh-Hans",
            preferredLanguages: ["en", "zh-Hans"]
        )
        #expect(result == "en")
    }

    // MARK: - Chinese script correction

    @Test("Pure Chinese with preferredLanguages=[zh-Hant] → zh-Hant")
    func chineseText_traditionalPreference() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "你好世界",
            targetCode: "en",
            preferredLanguages: ["zh-Hant"]
        )
        #expect(result == "zh-Hant")
    }

    @Test("Pure Chinese with preferredLanguages=[zh-Hans] → zh-Hans")
    func chineseText_simplifiedPreference() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "你好世界",
            targetCode: "en",
            preferredLanguages: ["zh-Hans"]
        )
        #expect(result == "zh-Hans")
    }

    @Test("Detection treats explicit Chinese scripts as equivalent")
    func detectionTreatsChineseScriptsAsEquivalent() {
        #expect(SourceLanguageDetector.detectionLanguagesAreEquivalent("zh-Hans", "zh-Hant"))
        #expect(SourceLanguageDetector.detectionLanguagesAreEquivalent("zh-Hant", "zh-Hans"))
    }

    @Test("Translation preserves explicit Chinese scripts")
    func translationPreservesChineseScripts() {
        #expect(!SourceLanguageDetector.languagesAreSame("zh-Hans", "zh-Hant"))
        #expect(!SourceLanguageDetector.languagesAreSame("zh-Hant", "zh-Hans"))
    }

    @Test("Translation ignores region and redundant default scripts")
    func translationIgnoresRegionAndDefaultScript() {
        #expect(SourceLanguageDetector.languagesAreSame("en-US", "en"))
        #expect(SourceLanguageDetector.languagesAreSame("en-Latn", "en"))
    }

    @Test("Match can select the other Chinese script")
    func matchCanSelectOtherChineseScript() {
        let simplifiedTarget = SourceLanguageDetector.resolveMatchTarget(
            sourceCode: "zh-Hant",
            candidates: [.traditionalChinese, .simplifiedChinese, .english]
        )
        let traditionalTarget = SourceLanguageDetector.resolveMatchTarget(
            sourceCode: "zh-Hans",
            candidates: [.simplifiedChinese, .traditionalChinese, .english]
        )

        #expect(simplifiedTarget == .simplifiedChinese)
        #expect(traditionalTarget == .traditionalChinese)
    }

    // MARK: - Unambiguous languages

    @Test("Japanese text detected as ja")
    func japaneseText() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "こんにちは世界",
            targetCode: "en",
            preferredLanguages: ["en", "ja"]
        )
        #expect(result == "ja")
    }

    @Test("Korean text detected as ko")
    func koreanText() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "안녕하세요 세계",
            targetCode: "en",
            preferredLanguages: ["en", "ko"]
        )
        #expect(result == "ko")
    }

    // MARK: - Edge cases

    @Test("Empty text returns nil")
    func emptyText() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "",
            targetCode: "en",
            preferredLanguages: ["en"]
        )
        #expect(result == nil)
    }

    @Test("Whitespace-only text returns nil")
    func whitespaceOnly() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "   \n  ",
            targetCode: "en",
            preferredLanguages: ["en"]
        )
        #expect(result == nil)
    }

    @Test("Nil targetCode still detects language")
    func nilTargetCode() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "Bonjour le monde",
            targetCode: nil,
            preferredLanguages: ["en", "fr"]
        )
        #expect(result == "fr")
    }

    // MARK: - Longer text

    @Test("Long English paragraph → en")
    func longEnglishText() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "The quick brown fox jumps over the lazy dog. This is a longer sentence to ensure reliable detection.",
            targetCode: "zh-Hans",
            preferredLanguages: ["en", "zh-Hans"]
        )
        #expect(result == "en")
    }

    @Test("Long Chinese paragraph → zh-Hans")
    func longChineseText() {
        let result = SourceLanguageDetector.resolveAutoSourceCode(
            text: "今天天气很好，我们一起去公园散步吧。阳光明媚，微风轻拂，非常适合户外活动。",
            targetCode: "en",
            preferredLanguages: ["zh-Hans", "en"]
        )
        #expect(result == "zh-Hans")
    }
}
