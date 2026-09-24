//
//  InputTextNormalizerTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("InputTextNormalizer")
struct InputTextNormalizerTests {
    @Test("Splits camelCase and snake_case identifiers")
    func splitsIdentifiers() {
        #expect(InputTextNormalizer.normalize("getUserName") == "get user name")
        #expect(InputTextNormalizer.normalize("max_retry_count") == "max retry count")
        #expect(InputTextNormalizer.normalize("parseHTTPResponse") == "parse HTTP response")
        #expect(InputTextNormalizer.normalize("Hello") == "Hello")
        #expect(InputTextNormalizer.normalize("JavaScript") == "JavaScript")
        #expect(InputTextNormalizer.normalize("macOS") == "macOS")
        #expect(InputTextNormalizer.normalize("iPhone 16") == "iPhone 16")
    }

    @Test("Strips comment markers and merges wrapped comment lines")
    func stripsComments() {
        let lineComment = """
        // Returns the cached value when the
        // request has not expired.
        """
        #expect(InputTextNormalizer.normalize(lineComment) == "Returns the cached value when the request has not expired.")

        let blockComment = """
        /**
         * Loads the file.
         * Throws on failure.
         */
        """
        #expect(InputTextNormalizer.normalize(blockComment) == "Loads the file.\nThrows on failure.")
    }

    @Test("Keeps single markdown heading and list text")
    func keepsMarkdown() {
        #expect(InputTextNormalizer.normalize("# Title") == "# Title")
        #expect(InputTextNormalizer.normalize("* one\n* two") == "* one\n* two")
    }

    @Test("Merges PDF hard wraps and hyphenation but keeps paragraphs")
    func mergesHardWraps() {
        let text = "The quick brown fox jumps over the lazy dog and keeps infor-\nmation in\nmind.\n\nNew paragraph."
        #expect(InputTextNormalizer.normalize(text) == "The quick brown fox jumps over the lazy dog and keeps information in mind.\n\nNew paragraph.")
        #expect(InputTextNormalizer.normalize("First line.\nsecond line") == "First line.\nsecond line")
    }

    @Test("Removes Apple Books excerpt notice")
    func removesBooksExcerpt() {
        let text = "“Stay hungry.”\n\nExcerpt From\nSome Book\nSomeone\nThis material may be protected by copyright."
        #expect(InputTextNormalizer.normalize(text) == "Stay hungry.")
    }
}

@Suite("WordLookupDetector")
struct WordLookupDetectorTests {
    @Test("Detects words and short phrases")
    func detectsWords() {
        for text in ["serendipity", "Apple", "look up", "state-of-the-art", "don't", "翻译", "ねこ"] {
            #expect(WordLookupDetector.isWordOrPhrase(text), "Expected word: \(text)")
        }
    }

    @Test("Rejects sentences and identifiers")
    func rejectsSentences() {
        for text in ["Hello world.", "How are you today my friend", "getUserName", "今天天气很好", "a\nb", "iPhone 16"] {
            #expect(!WordLookupDetector.isWordOrPhrase(text), "Expected non-word: \(text)")
        }
    }
}
