import Foundation
@testable import ShareCore
import Testing
import Translation

struct ChineseScriptConversionTests {
    @Test("Chinese script aliases convert locally in both directions", arguments: [
        (
            "zh-Hant", "zh-Hans", "為什麼我是好的\n為什麼在大陸都是好的.. English 123🙂",
            "为什么我是好的\n为什么在大陆都是好的.. English 123🙂"
        ),
        ("zh-TW", "zh-CN", "為什麼在大陸都是好的..", "为什么在大陆都是好的.."),
        ("zh-Hans", "zh-Hant", "为什么在大陆都是好的..", "為什麼在大陸都是好的.."),
        ("zh", "zh-HK", "为什么在大陆都是好的..", "為什麼在大陸都是好的.."),
    ])
    func convertsChineseScripts(source: String, target: String, text: String, expected: String) async throws {
        let service = AppleTranslationService.shared
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let status = try await service.languageAvailabilityStatus(source: sourceLanguage, target: targetLanguage)
        #expect(status == .installed)

        let result = try await service.translateWithInstalledLanguages(
            text: text, source: sourceLanguage, target: targetLanguage
        )
        #expect(try result.response.get() == expected)
        #expect(result.modelID == ModelConfig.appleTranslateID)
        #expect(result.providerDisplayName == String(localized: "Local Chinese script conversion"))
        #expect(result.sentencePairs.isEmpty)
    }

    @Test("Other language pairs and identical scripts do not use script conversion", arguments: [
        ("ja", "zh-Hans"), ("en", "zh-Hant"), ("zh-Hant", "en"),
        ("zh-Hans", "zh-CN"), ("zh-Hant", "zh-TW"),
    ])
    func otherPairsAreNotConverted(source: String, target: String) {
        #expect(ChineseScriptConverter(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        ) == nil)
    }

    @Test("Unresolved sources do not claim a Chinese script pair")
    func unresolvedSource() {
        #expect(ChineseScriptConverter(source: nil, target: Locale.Language(identifier: "zh-Hans")) == nil)
    }

    @Test("Script conversion preserves whitespace and only changes character forms")
    func preservesFormattingAndVocabulary() throws {
        let converter = try #require(ChineseScriptConverter(
            source: Locale.Language(identifier: "zh-Hant"),
            target: Locale.Language(identifier: "zh-Hans")
        ))
        #expect(try converter.convert("  軟體\tEnglish 123🙂\n\n大陸  ") == "  软体\tEnglish 123🙂\n\n大陆  ")
        #expect(try converter.convert("").isEmpty)
    }

    @Test("Automatic source detection can convert Traditional Chinese to Simplified Chinese")
    func autoDetectedSource() async throws {
        let result = try await AppleTranslationService.shared.translateWithInstalledLanguages(
            text: "為什麼我是好的\n為什麼在大陸都是好的..",
            source: nil,
            target: Locale.Language(identifier: "zh-Hans")
        )
        #expect(try result.response.get() == "为什么我是好的\n为什么在大陆都是好的..")
        #expect(result.providerDisplayName != nil)
    }

    @Test("Sentence and realtime conversion keep originals paired in order", arguments: [false, true])
    func sentencePairs(useRealtime: Bool) async throws {
        let service = AppleTranslationService.shared
        let text = "為什麼我是好的。為什麼在大陸都是好的？"
        let source = Locale.Language(identifier: "zh-Hant")
        let target = Locale.Language(identifier: "zh-Hans")
        let result = if useRealtime {
            try await service.translateRealtimeSentencesWithInstalledLanguages(text: text, source: source, target: target)
        } else {
            try await service.translateSentencesWithInstalledLanguages(text: text, source: source, target: target)
        }
        #expect(result.sentencePairs.map(\.original) == service.splitIntoSentences(text))
        #expect(result.sentencePairs.map(\.translation) == ["为什么我是好的。", "为什么在大陆都是好的？"])
        #expect(try result.response.get() == result.sentencePairs.map(\.translation).joined(separator: "\n"))
        #expect(result.providerDisplayName != nil)
    }
}
