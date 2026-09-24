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

    public init(
        id: String,
        primaryLabel: String,
        secondaryLabel: String,
        isDisabled: Bool = false,
        disabledReason: String? = nil
    ) {
        self.id = id
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.isDisabled = isDisabled
        self.disabledReason = disabledReason
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
        rows = options.map { LanguageRow(id: $0.rawValue, primaryLabel: $0.primaryLabel, secondaryLabel: $0.secondaryLabel) }
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
            NavigationStack {
                List(selection: $highlightedCode) {
                    if filteredRows.isEmpty {
                        emptySearchState
                    } else {
                        ForEach(filteredRows) { row in
                            Button {
                                guard !row.isDisabled else { return }
                                selectedCode = row.id
                                isPresented = false
                            } label: {
                                languageRowContent(row)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(row.isDisabled)
                            .tag(row.id)
                            .selectionDisabled(row.isDisabled)
                        }
                    }
                }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            guard let highlightedCode else { return }
                            selectedCode = highlightedCode
                            isPresented = false
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!filteredRows.contains(where: { $0.id == highlightedCode && !$0.isDisabled }))
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isPresented = false
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search Languages")
            .onAppear {
                highlightedCode = selectedCode
            }
            .onChange(of: searchText) {
                if !filteredRows.contains(where: { $0.id == highlightedCode && !$0.isDisabled }) {
                    highlightedCode = filteredRows.first(where: { !$0.isDisabled })?.id
                }
            }
            .frame(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 480)
        }
    #endif

    #if os(iOS)
        private var iOSPicker: some View {
            NavigationStack {
                List {
                    Section {
                        if filteredRows.isEmpty {
                            emptySearchState
                                .listRowBackground(colors.cardBackground)
                        } else {
                            ForEach(filteredRows) { row in
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(row.isDisabled ? colors.textSecondary : colors.textPrimary)
                Text(row.secondaryLabel)
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                if let disabledReason = row.disabledReason {
                    Text(disabledReason)
                        .font(.system(size: 12))
                        .foregroundColor(colors.textSecondary)
                }
            }

            Spacer()

            if selectedCode == row.id {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors.accent)
            }
        }
        .opacity(row.isDisabled ? 0.55 : 1)
    }

    private var emptySearchState: some View {
        Text("No languages found")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}
