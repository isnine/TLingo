//
//  LanguagePickerView.swift
//  ShareCore
//
//  Created by AI Assistant on 2026/01/22.
//

import SwiftUI

/// A row model for language option display.
public struct LanguageRow: Equatable, Identifiable {
    public let id: String
    public let primaryLabel: String
    public let secondaryLabel: String
    public let isDisabled: Bool
    public let disabledReason: String?
    /// Extra names that match a search, such as the language name in the app language.
    public let searchTerms: [String]

    public init(
        id: String,
        primaryLabel: String,
        secondaryLabel: String,
        isDisabled: Bool = false,
        disabledReason: String? = nil,
        searchTerms: [String] = []
    ) {
        self.id = id
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.isDisabled = isDisabled
        self.disabledReason = disabledReason
        self.searchTerms = searchTerms
    }
}

public extension LanguageRow {
    /// Row for a source language; a non-nil `disabledReason` disables it.
    init(source option: SourceLanguageOption, disabledReason: String? = nil) {
        self.init(
            id: option.rawValue,
            primaryLabel: option.primaryLabel,
            secondaryLabel: option.secondaryLabel,
            isDisabled: disabledReason != nil,
            disabledReason: disabledReason,
            searchTerms: [option.localizedName]
        )
    }

    init(target option: TargetLanguageOption, isDisabled: Bool = false) {
        self.init(
            id: option.rawValue,
            primaryLabel: option.primaryLabel,
            secondaryLabel: option.secondaryLabel,
            isDisabled: isDisabled,
            searchTerms: [option.localizedName]
        )
    }
}

public enum LanguagePickerSearch {
    public static func filteredRows(_ rows: [LanguageRow], query: String) -> [LanguageRow] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return rows }

        return rows.filter { row in
            normalized(row.id).contains(normalizedQuery)
                || normalized(row.primaryLabel).contains(normalizedQuery)
                || normalized(row.secondaryLabel).contains(normalizedQuery)
                || row.searchTerms.contains { normalized($0).contains(normalizedQuery) }
        }
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// A language picker view presented as a sheet. Accepts generic LanguageRow data.
public struct LanguagePickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedCode: String
    @Binding var isPresented: Bool
    @State private var searchText = ""
    #if os(macOS)
        @State private var highlightedCode: String?
    #endif
    private let rows: [LanguageRow]
    private let title: String
    private static let iOSListTopContentMargin: CGFloat = 8

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var filteredRows: [LanguageRow] {
        LanguagePickerSearch.filteredRows(rows, query: searchText)
    }

    private struct RowSection: Identifiable {
        let title: String?
        let rows: [LanguageRow]
        var id: String { rows.first?.id ?? "" }
    }

    /// Pins automatic options and common languages above the full list; search shows one flat list.
    private var sections: [RowSection] {
        let rows = filteredRows
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [RowSection(title: nil, rows: rows)]
        }
        let commonCodes = Set(LanguageCatalog.commonCodes)
        let isPinned: (LanguageRow) -> Bool = {
            commonCodes.contains($0.id) || !LanguageCatalog.allCodeSet.contains($0.id)
        }
        let pinned = rows.filter(isPinned)
        let others = rows.filter { !isPinned($0) }
        guard !pinned.isEmpty, !others.isEmpty else {
            return [RowSection(title: nil, rows: rows)]
        }
        return [
            RowSection(title: String(localized: "Common Languages"), rows: pinned),
            RowSection(title: String(localized: "All Languages"), rows: others),
        ]
    }

    /// Generic initialiser — caller provides rows and an optional title.
    public init(
        selectedCode: Binding<String>,
        isPresented: Binding<Bool>,
        rows: [LanguageRow],
        title: String = String(localized: "Select Language")
    ) {
        _selectedCode = selectedCode
        _isPresented = isPresented
        self.rows = rows
        self.title = title
    }

    /// Convenience initialiser for target language options.
    public init(
        selectedCode: Binding<String>,
        isPresented: Binding<Bool>,
        availableOptions: [TargetLanguageOption]? = nil,
        title: String = String(localized: "Select Target Language")
    ) {
        _selectedCode = selectedCode
        _isPresented = isPresented
        let options = availableOptions ?? TargetLanguageOption.selectionOptions
        rows = options.map { LanguageRow(target: $0) }
        self.title = title
    }

    public var body: some View {
        #if os(macOS)
            macOSPicker
        #else
            iOSPicker
        #endif
    }

    #if os(macOS)
        private var macOSPicker: some View {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                    TextField("Search Languages", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                List(selection: $highlightedCode) {
                    if filteredRows.isEmpty {
                        emptySearchState
                    } else {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    languageRowContent(row)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .padding(.vertical, 2)
                                        .tag(row.id)
                                        .selectionDisabled(row.isDisabled)
                                }
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { _ in
                    EmptyView()
                } primaryAction: { codes in
                    // Double-click or Return on a row commits it.
                    guard let code = codes.first, rows.contains(where: { $0.id == code && !$0.isDisabled }) else { return }
                    selectedCode = code
                    isPresented = false
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Done") {
                        guard let highlightedCode else { return }
                        selectedCode = highlightedCode
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!filteredRows.contains(where: { $0.id == highlightedCode && !$0.isDisabled }))
                }
                .controlSize(.large)
                .padding(16)
            }
            .onAppear {
                highlightedCode = selectedCode
            }
            .onChange(of: searchText) {
                if !filteredRows.contains(where: { $0.id == highlightedCode && !$0.isDisabled }) {
                    highlightedCode = filteredRows.first(where: { !$0.isDisabled })?.id
                }
            }
            .frame(minWidth: 420, idealWidth: 460, minHeight: 380, idealHeight: 500)
        }
    #endif

    #if os(iOS)
        private var iOSPicker: some View {
            NavigationStack {
                List {
                    if filteredRows.isEmpty {
                        Section {
                            emptySearchState
                                .listRowBackground(colors.cardBackground)
                        }
                    } else {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    Button {
                                        guard !row.isDisabled else { return }
                                        selectedCode = row.id
                                        isPresented = false
                                    } label: {
                                        languageRowContent(row)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(row.isDisabled)
                                    .listRowBackground(colors.cardBackground)
                                }
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(colors.background.ignoresSafeArea())
                .navigationTitle(title)
                .listStyle(.insetGrouped)
                .navigationBarTitleDisplayMode(.inline)
                .contentMargins(.top, Self.iOSListTopContentMargin, for: .scrollContent)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Languages")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isPresented = false
                        }
                    }
                }
            }
            .tint(colors.accent)
        }
    #endif

    private func languageRowContent(_ row: LanguageRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.primaryLabel)
                    .font(.system(size: rowTitleSize, weight: .medium))
                    .foregroundStyle(row.isDisabled ? secondaryStyle : primaryStyle)
                Text(row.secondaryLabel)
                    .font(.system(size: rowSubtitleSize))
                    .foregroundStyle(secondaryStyle)
                if let disabledReason = row.disabledReason {
                    Text(disabledReason)
                        .font(.system(size: 12))
                        .foregroundStyle(secondaryStyle)
                }
            }

            Spacer()

            if selectedCode == row.id {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(checkmarkStyle)
            }
        }
        .opacity(row.isDisabled ? 0.55 : 1)
    }

    // macOS uses hierarchical styles so text and checkmark invert inside the selection highlight.
    #if os(macOS)
        private var rowTitleSize: CGFloat { 14 }
        private var rowSubtitleSize: CGFloat { 12 }
        private var primaryStyle: AnyShapeStyle { AnyShapeStyle(.primary) }
        private var secondaryStyle: AnyShapeStyle { AnyShapeStyle(.secondary) }
        private var checkmarkStyle: AnyShapeStyle { AnyShapeStyle(.primary) }
    #else
        private var rowTitleSize: CGFloat { 16 }
        private var rowSubtitleSize: CGFloat { 13 }
        private var primaryStyle: AnyShapeStyle { AnyShapeStyle(colors.textPrimary) }
        private var secondaryStyle: AnyShapeStyle { AnyShapeStyle(colors.textSecondary) }
        private var checkmarkStyle: AnyShapeStyle { AnyShapeStyle(colors.accent) }
    #endif

    private var emptySearchState: some View {
        Text("No languages found")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}
