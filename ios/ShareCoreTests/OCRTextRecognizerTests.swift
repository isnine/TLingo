//
//  OCRTextRecognizerTests.swift
//  ShareCoreTests
//

import CoreGraphics
import Testing

@testable import ShareCore

@Suite("OCRTextRecognizer")
struct OCRTextRecognizerTests {
    private func line(_ text: String, top: CGFloat, minX: CGFloat = 0.1, maxX: CGFloat = 0.9) -> OCRTextRecognizer.Line {
        OCRTextRecognizer.Line(text: text, box: CGRect(x: minX, y: top - 0.05, width: maxX - minX, height: 0.05))
    }

    @Test("Joins wrapped lines, hyphenation, and CJK without spaces")
    func joinsWrappedLines() {
        let english = [line("keeps infor-", top: 0.9), line("mation in the", top: 0.84), line("cache.", top: 0.78)]
        #expect(OCRTextRecognizer.mergeLines(english) == "keeps information in the cache.")

        let chinese = [line("今天天气", top: 0.9), line("很好。", top: 0.84)]
        #expect(OCRTextRecognizer.mergeLines(chinese) == "今天天气很好。")
    }

    @Test("Starts new paragraphs on gaps, indentation, and short lines")
    func splitsParagraphs() {
        let gap = [line("First paragraph.", top: 0.9), line("Second paragraph.", top: 0.7)]
        #expect(OCRTextRecognizer.mergeLines(gap) == "First paragraph.\nSecond paragraph.")

        let shortLine = [line("Title", top: 0.9, maxX: 0.3), line("Body text", top: 0.84)]
        #expect(OCRTextRecognizer.mergeLines(shortLine) == "Title\nBody text")

        let indented = [line("End of one.", top: 0.9), line("Start of two", top: 0.84, minX: 0.2)]
        #expect(OCRTextRecognizer.mergeLines(indented) == "End of one.\nStart of two")
    }
}
