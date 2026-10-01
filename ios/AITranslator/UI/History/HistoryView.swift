//
//  HistoryView.swift
//  TLingo
//
//  Created by Zander Wang on 2026/03/13.
//

import ShareCore
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

enum HistoryFilter: String, CaseIterable, Identifiable {
    case text
    case realtime

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .text:
            return "Text"
        case .realtime:
            return "Realtime"
        }
    }

    /// Chat records are text translations continued as a conversation, so they
    /// share the Text category.
    func includes(_ record: TranslationRecord) -> Bool {
        switch self {
        case .text:
            return !record.isRealtimeRecord
        case .realtime:
            return record.isRealtimeRecord
        }
    }
}

struct HistoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var records: [TranslationRecord] = []
    @State private var filter: HistoryFilter
    @State private var searchText = ""
    @State private var showDeleteAllConfirmation = false
    @State private var showFeaturePaywall = false
    @State private var isVisible = false
    private let locksFilter: Bool
    private let onConversationSelected: ((TranslationRecord) -> Void)?

    init(
        initialFilter: HistoryFilter = .text,
        locksFilter: Bool = false,
        onConversationSelected: ((TranslationRecord) -> Void)? = nil
    ) {
        _filter = State(initialValue: initialFilter)
        self.locksFilter = locksFilter
        self.onConversationSelected = onConversationSelected
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredRecords: [TranslationRecord] {
        let query = trimmedSearchText
        return records.filter { record in
            filter.includes(record) && (query.isEmpty || matches(record, query: query))
        }
    }

    var body: some View {
        let visibleRecords = filteredRecords
        return List {
            ForEach(HistoryDaySection.group(visibleRecords)) { section in
                Section {
                    ForEach(section.records, id: \.id) { record in
                        recordRow(record)
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textSecondary)
                        .textCase(nil)
                }
            }
            if !visibleRecords.isEmpty {
                privacyFooter
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(colors.background.ignoresSafeArea())
        .overlay {
            if visibleRecords.isEmpty {
                emptyState
            }
        }
        .animation(.snappy, value: filter)
        .tint(colors.accent)
        .searchable(text: $searchText, prompt: Text("Search History"))
        #if os(iOS)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !locksFilter {
                    ToolbarItem(placement: .principal) {
                        filterPicker
                            .fixedSize()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !records.isEmpty {
                        Button("Clear All History", systemImage: "trash") {
                            showDeleteAllConfirmation = true
                        }
                    }
                }
            }
        #else
            .safeAreaInset(edge: .top, spacing: 0) {
                headerSection(visibleCount: visibleRecords.count)
            }
        #endif
            .onAppear {
                isVisible = true
                refreshRecords()
            }
            .onDisappear {
                isVisible = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .translationRecordSaved)) { _ in
                guard isVisible else { return }
                refreshRecords()
            }
        #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                guard isVisible else { return }
                refreshRecords()
            }
        #else
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    guard isVisible else { return }
                    refreshRecords()
                }
        #endif
                .confirmationDialog(
                    "Clear All History",
                    isPresented: $showDeleteAllConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        TranslationHistoryService.shared.deleteAll()
                        withAnimation {
                            records.removeAll()
                        }
                    }
                } message: {
                    Text("This action cannot be undone.")
                }
                .sheet(isPresented: $showFeaturePaywall) {
                    PaywallView(context: .featureLocked)
                }
    }

    // MARK: - Header (macOS)

    #if os(macOS)
        private func headerSection(visibleCount: Int) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("History")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(colors.textPrimary)
                        Text("\(visibleCount) translations")
                            .font(.system(size: 16))
                            .foregroundColor(colors.textSecondary)
                    }
                    Spacer()
                    if !records.isEmpty {
                        Button("Clear All History", systemImage: "trash") {
                            showDeleteAllConfirmation = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(colors.textSecondary)
                    }
                }
                if !locksFilter {
                    filterPicker
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(colors.background)
        }
    #endif

    // MARK: - Filter

    private var filterPicker: some View {
        Picker("History Filter", selection: $filter) {
            ForEach(HistoryFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if !trimmedSearchText.isEmpty {
            ContentUnavailableView.search(text: trimmedSearchText)
        } else {
            ContentUnavailableView {
                Label(emptyStateTitle, systemImage: emptyStateSystemImage)
            } description: {
                Text(emptyStateMessage)
            }
        }
    }

    private var emptyStateTitle: LocalizedStringKey {
        switch filter {
        case .text:
            return "No text history yet"
        case .realtime:
            return "No realtime history yet"
        }
    }

    private var emptyStateMessage: LocalizedStringKey {
        switch filter {
        case .text:
            return "Text translations will appear here"
        case .realtime:
            return "Realtime sessions will appear here"
        }
    }

    private var emptyStateSystemImage: String {
        switch filter {
        case .text:
            return "clock.arrow.circlepath"
        case .realtime:
            return "waveform"
        }
    }

    // MARK: - Rows

    private func recordRow(_ record: TranslationRecord) -> some View {
        recordLink(record)
            .listRowBackground(colors.cardBackground)
            .contextMenu { rowContextMenu(record) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    delete(record)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                if let result = copyableResult(for: record) {
                    Button {
                        PasteboardHelper.copy(result)
                    } label: {
                        Label("Copy Result", systemImage: "doc.on.doc")
                    }
                    .tint(colors.accent)
                }
            }
    }

    @ViewBuilder
    private func recordLink(_ record: TranslationRecord) -> some View {
        if let session = record.realtimeSession {
            NavigationLink {
                HistoryRecordDetailView(record: record)
            } label: {
                RealtimeHistoryRow(record: record, session: session)
            }
        } else if record.isConversation {
            if let onConversationSelected {
                Button {
                    onConversationSelected(record)
                } label: {
                    TextHistoryRow(record: record)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    ConversationContentView(
                        session: conversationSession(for: record),
                        onPremiumRequired: {
                            showFeaturePaywall = true
                        }
                    )
                    .id(record.id)
                } label: {
                    TextHistoryRow(record: record)
                }
            }
        } else {
            NavigationLink {
                HistoryRecordDetailView(record: record)
            } label: {
                TextHistoryRow(record: record)
            }
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ record: TranslationRecord) -> some View {
        if let result = copyableResult(for: record) {
            Button {
                PasteboardHelper.copy(result)
            } label: {
                Label("Copy Result", systemImage: "doc.on.doc")
            }
        }
        Button {
            PasteboardHelper.copy(record.realtimeSession?.sourceTextForCopy ?? record.sourceText)
        } label: {
            Label("Copy Source", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            delete(record)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Privacy Footer

    private var privacyFooter: some View {
        Label("All history is stored locally on your device.", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(colors.textSecondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    // MARK: - Helpers

    private func copyableResult(for record: TranslationRecord) -> String? {
        let text = record.realtimeSession?.translatedTextForCopy ?? record.modelResults.first?.resultText
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private func matches(_ record: TranslationRecord, query: String) -> Bool {
        if record.sourceText.localizedStandardContains(query) {
            return true
        }
        if let session = record.realtimeSession {
            return session.displayTitle(fallback: "").localizedStandardContains(query)
                || session.translatedText.localizedStandardContains(query)
        }
        return record.modelResults.contains { $0.resultText.localizedStandardContains(query) }
    }

    private func delete(_ record: TranslationRecord) {
        TranslationHistoryService.shared.delete(record)
        withAnimation { records.removeAll { $0.id == record.id } }
    }

    private func refreshRecords() {
        records = TranslationHistoryService.shared.fetchAll()
    }
}

private struct HistoryDaySection: Identifiable {
    let id: Date
    var records: [TranslationRecord]

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var title: String {
        Self.titleFormatter.string(from: id)
    }

    static func group(_ records: [TranslationRecord]) -> [HistoryDaySection] {
        var sections: [HistoryDaySection] = []
        for record in records {
            let day = Calendar.current.startOfDay(for: record.timestamp)
            if let index = sections.firstIndex(where: { $0.id == day }) {
                sections[index].records.append(record)
            } else {
                sections.append(HistoryDaySection(id: day, records: [record]))
            }
        }
        return sections
    }
}

private struct TextHistoryRow: View {
    let record: TranslationRecord

    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HistoryMarkdownText(
                text: record.sourceText,
                font: .subheadline,
                foregroundColor: colors.textSecondary,
                lineLimit: 2
            )
            if let result = record.modelResults.first?.resultText, !result.isEmpty {
                HistoryMarkdownText(
                    text: result,
                    font: .body,
                    foregroundColor: colors.textPrimary,
                    lineLimit: 3
                )
            }
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                Text(metadata)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(record.timestamp, format: .dateTime.hour().minute())
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(colors.textSecondary)
            .padding(.top, 2)
        }
        .allowsHitTesting(false)
        .padding(.vertical, 4)
    }

    private var systemImage: String {
        if record.isConversation {
            return "bubble.left.and.bubble.right"
        }
        return record.actionName.isEmpty
            ? "text.bubble"
            : TranslationRecord.systemImage(forActionNamed: record.actionName)
    }

    private var metadata: String {
        var parts: [String] = []
        if !record.actionName.isEmpty {
            parts.append(AppConfigurationStore.displayName(forActionName: record.actionName))
        } else if record.isConversation {
            parts.append(String(localized: "Chat"))
        }
        let results = record.modelResults
        if results.count > 1 {
            parts.append(String(localized: "\(results.count) models"))
        } else if let first = results.first, !first.modelDisplayName.isEmpty {
            parts.append(first.modelDisplayName)
        }
        return parts.joined(separator: " · ")
    }
}

private struct RealtimeHistoryRow: View {
    let record: TranslationRecord
    let session: RealtimeHistorySession

    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colors.accent)
                .frame(width: 36, height: 36)
                .background(colors.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.displayTitle(fallback: record.sourceText))
                        .font(.headline)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(session.startedAt, format: .dateTime.hour().minute())
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(colors.textSecondary)
                }
                let preview = session.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Label(session.durationLabel, systemImage: "clock")
                    Label(session.languageDirection, systemImage: "globe")
                        .lineLimit(1)
                }
                .labelStyle(HistoryMetadataLabelStyle())
                .font(.caption)
                .foregroundStyle(colors.textSecondary)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryMetadataLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}
