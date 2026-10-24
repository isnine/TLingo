//
//  AppleTranslationErrorFormatterTests.swift
//  ShareCoreTests
//

import Foundation
import Testing
import Translation

@testable import ShareCore

@Suite("AppleTranslationErrorFormatter")
struct AppleTranslationErrorFormatterTests {
    @Test("Apple Translate errors include current language pair")
    func describeIncludesLanguagePair() {
        let error = NSError(
            domain: "TranslationErrorDomain",
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: "Translation could not be completed"]
        )

        let message = AppleTranslationErrorFormatter.describe(
            error,
            sourceCode: "en",
            target: .simplifiedChinese
        )

        #expect(message.contains("English -> 简体中文"))
        #expect(message.contains("Translation could not be completed"))
    }

    @Test("Same source and target errors include current language pair")
    func sameSourceAndTargetIncludesLanguagePair() {
        let error = LocalProviderError.sameSourceAndTarget(
            language: "English",
            languagePair: "English -> English"
        )

        let message = error.localizedDescription

        #expect(message.contains("English -> English"))
        #expect(message.contains("Source and target are both English"))
    }

    @Test("Missing Apple Translate language pack errors point to the download action")
    func missingLanguagePackPointsToDownload() {
        let error = LocalProviderError.languagePackNotInstalled(languagePair: "English -> 简体中文")

        let message = error.localizedDescription

        #expect(message.contains("English -> 简体中文"))
        #expect(message.contains("Choose Download"))
    }

    @Test("Not installed errors are recognized as missing language packs")
    func notInstalledErrorsAreRecognizedAsMissingLanguagePacks() {
        let error = NSError(
            domain: "TranslationErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "TranslationError.notInstalled"]
        )

        #expect(AppleTranslationErrorFormatter.isLanguagePackMissing(error))
    }

    @Test("Structured notInstalled errors are recognized as missing language packs")
    func structuredNotInstalledIsRecognized() {
        #expect(AppleTranslationErrorFormatter.isLanguagePackMissing(TranslationError.notInstalled))
    }

    @Test("Unrelated errors that mention a device or download are not treated as missing packs")
    func unrelatedErrorsAreNotMissingPacks() {
        let error = NSError(
            domain: "TranslationErrorDomain",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Unable to reach the device to download results"]
        )

        #expect(!AppleTranslationErrorFormatter.isLanguagePackMissing(error))
    }

    @Test("A diagnosed transient failure is not reported as a missing pack")
    func diagnosedFailureIsNotMissingPack() {
        let error = LocalProviderError.translationFailed("Language pack not installed [Translation.TranslationError 1]")

        #expect(!AppleTranslationErrorFormatter.isLanguagePackMissing(error))
    }
}
