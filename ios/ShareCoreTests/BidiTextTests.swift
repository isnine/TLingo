//
//  BidiTextTests.swift
//  ShareCoreTests
//

import SwiftUI
import Testing

@testable import ShareCore

@Suite("BidiText")
struct BidiTextTests {

    // MARK: - isRTLLanguage

    @Test("Recognises core RTL primary subtags")
    func rtlPrimarySubtags() {
        for code in ["ar", "he", "fa", "ur", "ps", "ckb", "sd", "ug", "yi", "dv"] {
            #expect(BidiText.isRTLLanguage(code), "Expected RTL for \(code)")
        }
    }

    @Test("Recognises BCP-47 regional variants")
    func rtlRegionalVariants() {
        #expect(BidiText.isRTLLanguage("ar-EG"))
        #expect(BidiText.isRTLLanguage("ar_SA"))
        #expect(BidiText.isRTLLanguage("fa-IR"))
        #expect(BidiText.isRTLLanguage("AR"))  // case-insensitive
    }

    @Test("LTR languages are not flagged")
    func ltrLanguages() {
        for code in ["en", "zh-Hans", "ja", "ko", "fr", "de", "es", "ru", "tr"] {
            #expect(!BidiText.isRTLLanguage(code), "Expected LTR for \(code)")
        }
    }

    @Test("Nil / empty input returns false")
    func nilAndEmpty() {
        #expect(!BidiText.isRTLLanguage(nil))
        #expect(!BidiText.isRTLLanguage(""))
    }

    // MARK: - layoutDirection / textAlignment

    @Test("layoutDirection maps to .rightToLeft for RTL")
    func layoutDirectionMapping() {
        #expect(BidiText.layoutDirection(forLanguageCode: "ar") == .rightToLeft)
        #expect(BidiText.layoutDirection(forLanguageCode: "en") == .leftToRight)
    }

    @Test("textAlignment maps to .trailing for RTL")
    func textAlignmentMapping() {
        #expect(BidiText.textAlignment(forLanguageCode: "he") == .trailing)
        #expect(BidiText.textAlignment(forLanguageCode: "ja") == .leading)
    }

    // MARK: - wrapBidiIsolated

    @Test("Wraps plain text with FSI / PDI")
    func wrapsPlainText() {
        let wrapped = BidiText.wrapBidiIsolated("hello 123")
        #expect(wrapped.first == BidiText.firstStrongIsolate)
        #expect(wrapped.last == BidiText.popDirectionalIsolate)
        #expect(wrapped.contains("hello 123"))
    }

    @Test("Empty string returns empty")
    func wrapEmpty() {
        #expect(BidiText.wrapBidiIsolated("") == "")
    }

    @Test("Already-isolated text is left untouched")
    func wrapIdempotent() {
        let pre = "\(BidiText.firstStrongIsolate)abc\(BidiText.popDirectionalIsolate)"
        #expect(BidiText.wrapBidiIsolated(pre) == pre)
    }
}
