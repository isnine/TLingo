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
    case all
    case text
    case chat
    case realtime

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all:
            return "All"
        case .text:
            return "Text"
        case .chat:
            return "Chat"
        case .realtime:
            return "Realtime"
        }
    }
}

struct HistoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var records: [TranslationRecord] = []
    @State private var filter: HistoryFilter
    @State private var expandedRecordIDs: Set<UUID> = []
    @State private var showDeleteAllConfirmation = false
    @State private var showFeaturePaywall = false
    @State private var isVisible = false
    private let locksFilter: Bool
    private let onConversationSelected: ((TranslationRecord) -> Void)?

    init(
        initialFilter: HistoryFilter = .all,
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

    private var filteredRecords: [TranslationRecord] {
        records.filter { record in
            switch filter {
            case .all:
                return true
            case .text:
                return !record.isRealtimeRecord && !record.isConversation
            case .chat:
                return record.isConversation
            case .realtime:
                return record.isRealtimeRecord
            }
        }
    }

    var body: some View {
        let visibleRecords = filteredRecords
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                    headerSection(visibleCount: visibleRecords.count)
                #endif
                if records.isEmpty {
                    emptyState
                } else {
                    if !locksFilter {
                        filterPicker
                    }
                    if visibleRecords.isEmpty {
                        emptyState
                    } else {
                        recordsList(visibleRecords)
                    }
                }
                privacyFooter
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(colors.background.ignoresSafeArea())
        .tint(colors.accent)
        #if os(iOS)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if !records.isEmpty {
                        Button("Clear All History", systemImage: "trash") {
                            showDeleteAllConfirmation = true
                        }
                    }
                }
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
                            expandedRecordIDs.removeAll()
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
        }
    #endif

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateTitle, systemImage: "clock.arrow.circlepath")
        } description: {
            Text(emptyStateMessage)
        }
        .padding(.top, 40)
    }

    private var emptyStateTitle: LocalizedStringKey {
        switch filter {
        case .all:
            return "No history yet"
        case .text:
            return "No text history yet"
        case .chat:
            return "No history yet"
        case .realtime:
            return "No realtime history yet"
        }
    }

    private var emptyStateMessage: LocalizedStringKey {
        switch filter {
        case .all:
            return "Your translations will appear here"
        case .text:
            return "Text translations will appear here"
        case .chat:
            return "Your translations will appear here"
        case .realtime:
            return "Realtime sessions will appear here"
        }
    }

    // MARK: - Records List

    private var filterPicker: some View {
        Picker("History Filter", selection: $filter) {
            ForEach(HistoryFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    private func recordsList(_ visibleRecords: [TranslationRecord]) -> some View {
        let sections = HistoryDaySection.group(visibleRecords)
        return LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(sections) { section in
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.leading, 4)
                    .padding(.top, section.id == sections.first?.id ? 0 : 14)
                ForEach(section.records, id: \.id) { record in
                    recordCard(record)
                }
            }
        }
    }

    // MARK: - Record Card

    @ViewBuilder
    private func recordCard(_ record: TranslationRecord) -> some View {
        if let session = record.realtimeSession {
            NavigationLink {
                HistoryRecordDetailView(record: record)
            } label: {
                RealtimeHistoryCard(record: record, session: session)
            }
            .buttonStyle(.plain)
            .contextMenu { cardContextMenu(record) }
        } else if record.isConversation {
            if let onConversationSelected {
                Button {
                    onConversationSelected(record)
                } label: {
                    legacyRecordContent(record, isExpanded: false)
                }
                .buttonStyle(.plain)
                .contextMenu { cardContextMenu(record) }
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
                    legacyRecordContent(record, isExpanded: false)
                }
                .buttonStyle(.plain)
                .contextMenu { cardContextMenu(record) }
            }
        } else {
            legacyRecordCard(record)
        }
    }

    private func legacyRecordCard(_ record: TranslationRecord) -> some View {
        let hasMultipleModels = record.modelResults.count > 1
        let isExpanded = expandedRecordIDs.contains(record.id)

        return legacyRecordContent(record, isExpanded: isExpanded)
            .contextMenu { cardContextMenu(record) }
            .onTapGesture {
                guard hasMultipleModels else { return }
                withAnimation(.snappy) {
                    if isExpanded {
                        expandedRecordIDs.remove(record.id)
                    } else {
                        expandedRecordIDs.insert(record.id)
                    }
                }
            }
    }

    private func legacyRecordContent(_ record: TranslationRecord, isExpanded: Bool) -> some View {
        let results = record.modelResults
        let hasMultipleModels = results.count > 1

        return VStack(alignment: .leading, spacing: 8) {
            HistoryMarkdownText(
                text: record.sourceText,
                font: .subheadline,
                foregroundColor: colors.textSecondary,
                lineLimit: isExpanded ? nil : 2
            )
            .allowsHitTesting(false)
            resultsSection(results, hasMultipleModels: hasMultipleModels, isExpanded: isExpanded)
            if let annotation = record.annotation(for: record.id) {
                recordAnnotationView(annotation)
            }
            HistoryCardFooter(
                systemImage: footerSystemImage(for: record),
                text: footerText(for: record, isExpanded: isExpanded),
                date: record.timestamp,
                disclosure: hasMultipleModels ? (isExpanded ? "chevron.up" : "chevron.down") : nil
            )
            .padding(.top, 2)
        }
        .historyCardStyle(colors)
    }

    @ViewBuilder
    private func resultsSection(
        _ results: [ModelResult],
        hasMultipleModels: Bool,
        isExpanded: Bool
    ) -> some View {
        if hasMultipleModels, isExpanded {
            ForEach(Array(results.enumerated()), id: \.element.id) { idx, modelResult in
                if idx > 0 {
                    Divider()
                }
                modelResultRow(modelResult)
            }
        } else if let first = results.first {
            resultText(first.resultText, lineLimit: 3)
        }
    }

    @ViewBuilder
    private func cardContextMenu(_ record: TranslationRecord) -> some View {
        if let first = record.modelResults.first {
            Button {
                PasteboardHelper.copy(first.resultText)
            } label: {
                Label("Copy Result", systemImage: "doc.on.doc")
            }
        }
        Button {
            PasteboardHelper.copy(record.sourceText)
        } label: {
            Label("Copy Source", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            TranslationHistoryService.shared.delete(record)
            withAnimation { records.removeAll { $0.id == record.id } }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Model Result Views

    private func resultText(_ text: String, lineLimit: Int?) -> some View {
        HistoryMarkdownText(
            text: text,
            font: .body,
            foregroundColor: colors.textPrimary,
            lineLimit: lineLimit
        )
        .allowsHitTesting(false)
    }

    private func modelResultRow(_ result: ModelResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(result.modelDisplayName)
                if result.duration > 0 {
                    Text("· \(String(format: "%.1fs", result.duration))")
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(colors.textSecondary)
            resultText(result.resultText, lineLimit: nil)
        }
    }

    private func recordAnnotationView(_ text: String) -> some View {
        HistoryMarkdownText(
            text: text,
            font: .caption,
            foregroundColor: colors.textSecondary,
            lineLimit: 4,
            emphasizesStructure: true
        )
        .allowsHitTesting(false)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.chipSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private func footerSystemImage(for record: TranslationRecord) -> String {
        if record.isConversation {
            return "bubble.left.and.bubble.right"
        }
        return record.actionName.isEmpty ? "text.bubble" : iconForAction(named: record.actionName)
    }

    private func footerText(for record: TranslationRecord, isExpanded: Bool) -> String {
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

    // MARK: - Privacy Footer

    private var privacyFooter: some View {
        Label("All history is stored locally on your device.", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(colors.textSecondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    // MARK: - Helpers

    private func iconForAction(named name: String) -> String {
        TranslationRecord.systemImage(forActionNamed: name)
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

private struct HistoryCardFooter: View {
    let systemImage: String
    let text: String
    let date: Date
    var disclosure: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
            if let disclosure {
                Image(systemName: disclosure)
                    .imageScale(.small)
                    .fontWeight(.semibold)
            }
            Spacer(minLength: 8)
            Text(date, format: .dateTime.hour().minute())
                .monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(AppColors.palette(for: colorScheme).textSecondary)
    }
}

private extension View {
    func historyCardStyle(_ colors: AppColorPalette) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct RealtimeHistoryCard: View {
    let record: TranslationRecord
    let session: RealtimeHistorySession

    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HistoryMarkdownText(
                text: session.displayTitle(fallback: record.sourceText),
                font: .headline,
                foregroundColor: colors.textPrimary,
                lineLimit: 2
            )
            .allowsHitTesting(false)
            HistoryMarkdownText(
                text: session.translatedText,
                font: .subheadline,
                foregroundColor: colors.textPrimary,
                lineLimit: 2
            )
            .allowsHitTesting(false)
            HistoryMarkdownText(
                text: session.sourceText,
                font: .subheadline,
                foregroundColor: colors.textSecondary,
                lineLimit: 2
            )
            .allowsHitTesting(false)
            HistoryCardFooter(
                systemImage: TranslationRecord.realtimeSystemImageName,
                text: session.durationLabel,
                date: session.startedAt
            )
            .padding(.top, 4)
        }
        .historyCardStyle(colors)
    }
}
