//
//  LanguagePickerSearchTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("Language picker search")
struct LanguagePickerSearchTests {
    private let rows = [
        LanguageRow(id: "ja", primaryLabel: "日本語", secondaryLabel: "Japanese"),
        LanguageRow(id: "pt-BR", primaryLabel: "Português (Brasil)", secondaryLabel: "Portuguese (Brazil)"),
        LanguageRow(id: "zh-Hans", primaryLabel: "简体中文", secondaryLabel: "Chinese (Simplified)"),
    ]

    @Test("Empty query returns all rows")
    func emptyQueryReturnsAllRows() {
        #expect(LanguagePickerSearch.filteredRows(rows, query: "").map(\.id) == ["ja", "pt-BR", "zh-Hans"])
    }

    @Test("Search matches labels and language codes")
    func searchMatchesLabelsAndLanguageCodes() {
        #expect(LanguagePickerSearch.filteredRows(rows, query: "jap").map(\.id) == ["ja"])
        #expect(LanguagePickerSearch.filteredRows(rows, query: "pt-br").map(\.id) == ["pt-BR"])
        #expect(LanguagePickerSearch.filteredRows(rows, query: "simplified").map(\.id) == ["zh-Hans"])
    }

    @Test("Search preserves disabled state")
    func searchPreservesDisabledState() throws {
        let rows = [
            LanguageRow(
                id: "de",
                primaryLabel: "Deutsch",
                secondaryLabel: "German",
                isDisabled: true,
                disabledReason: "Not supported"
            ),
        ]

        let result = LanguagePickerSearch.filteredRows(rows, query: "german")
        let first = try #require(result.first)

        #expect(first.isDisabled)
        #expect(first.disabledReason == "Not supported")
    }
}
