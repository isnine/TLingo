//
//  TextDiffBuilderTests.swift
//  ShareCoreTests
//

@testable import ShareCore
import Testing

@Suite("TextDiffBuilder")
struct TextDiffBuilderTests {
    @Test("Single CJK character change produces a character-level diff")
    func cjkSingleCharacterChange() throws {
        let presentation = try #require(TextDiffBuilder.build(original: "我今天去学校上课了。", revised: "我明天去学校上课了。"))

        #expect(presentation.originalSegments.map(\.text) == ["我", "今", "天去学校上课了。"])
        #expect(presentation.originalSegments.map(\.kind) == [.equal, .removed, .equal])
        #expect(presentation.revisedSegments.map(\.text) == ["我", "明", "天去学校上课了。"])
        #expect(presentation.revisedSegments.map(\.kind) == [.equal, .added, .equal])
    }
}
