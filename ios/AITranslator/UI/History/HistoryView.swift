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
            VStack(alignment: .leading, spacing: 28) {
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
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background(colors.background.ignoresSafeArea())
        .tint(colors.accent)
        #if os(iOS)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if !records.isEmpty {
                        Button {
                            showDeleteAllConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                                .foregroundColor(colors.textSecondary)
                        }
                        .buttonStyle(.plain)
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
                    Button {
                        showDeleteAllConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundColor(colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    #endif

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(colors.textSecondary.opacity(0.5))
            Text(emptyStateTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(colors.textPrimary)
            Text(emptyStateMessage)
                .font(.system(size: 15))
                .foregroundColor(colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
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
        LazyVStack(spacing: 12) {
            ForEach(visibleRecords, id: \.id) { record in
                recordCard(record)
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
        let results = record.modelResults
        let hasMultipleModels = results.count > 1
        let isExpanded = expandedRecordIDs.contains(record.id)

        return legacyRecordContent(record, isExpanded: isExpanded)
            .contextMenu { cardContextMenu(record) }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasMultipleModels else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
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
        let annotation = record.annotation(for: record.id)

        return VStack(alignment: .leading, spacing: 0) {
            sourceSection(record, isExpanded: isExpanded)
            resultsSection(results, hasMultipleModels: hasMultipleModels, isExpanded: isExpanded)
            metadataRow(record, hasMultipleModels: hasMultipleModels, isExpanded: isExpanded)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, annotation == nil ? 16 : 8)
            if let annotation {
                recordAnnotationView(annotation)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sourceSection(_ record: TranslationRecord, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HistoryMarkdownText(
                text: record.sourceText,
                font: .system(size: 15),
                foregroundColor: colors.textSecondary,
                lineLimit: isExpanded ? nil : 3
            )
            .allowsHitTesting(false)
            Rectangle()
                .fill(colors.divider)
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func resultsSection(
        _ results: [ModelResult],
        hasMultipleModels: Bool,
        isExpanded: Bool
    ) -> some View {
        if hasMultipleModels, !isExpanded {
            collapsedResult(results[0])
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        } else {
            ForEach(Array(results.enumerated()), id: \.element.id) { idx, modelResult in
                modelResultRow(modelResult, showLabel: true, expanded: hasMultipleModels)
                    .padding(.horizontal, 16)
                if hasMultipleModels, idx < results.count - 1 {
                    Rectangle()
                        .fill(colors.divider.opacity(0.5))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
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

    private func collapsedResult(_ result: ModelResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HistoryMarkdownText(
                text: result.resultText,
                font: .system(size: 15),
                foregroundColor: colors.accent,
                lineLimit: 3
            )
            .allowsHitTesting(false)
        }
    }

    private func modelResultRow(_ result: ModelResult, showLabel: Bool, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showLabel {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    Text(result.modelDisplayName)
                        .font(.system(size: 12, weight: .medium))
                    if result.duration > 0 {
                        Text("· \(String(format: "%.1fs", result.duration))")
                            .font(.system(size: 12))
                    }
                }
                .foregroundColor(colors.textSecondary)
            }
            HistoryMarkdownText(
                text: result.resultText,
                font: .system(size: 15),
                foregroundColor: colors.accent,
                lineLimit: expanded ? nil : 3
            )
            .allowsHitTesting(false)
        }
        .padding(.vertical, 4)
    }

    private func recordAnnotationView(_ text: String) -> some View {
        HistoryMarkdownText(
            text: text,
            font: .system(size: 12),
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

    // MARK: - Metadata Row

    private func metadataRow(
        _ record: TranslationRecord,
        hasMultipleModels: Bool,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if !record.actionName.isEmpty {
                MetadataChipView(
                    AppConfigurationStore.displayName(forActionName: record.actionName),
                    icon: iconForAction(named: record.actionName)
                )
            }
            if record.isConversation {
                MetadataChipView("Chat", icon: "bubble.left.and.bubble.right.fill")
            }
            if hasMultipleModels {
                let models = record.modelResults
                MetadataChipView(
                    "\(models.count) models",
                    icon: isExpanded ? "chevron.up" : "chevron.down"
                )
            } else if let first = record.modelResults.first, !first.modelDisplayName.isEmpty {
                MetadataChipView(first.modelDisplayName, icon: "cpu")
            }
            Spacer()
            Text(record.timestamp, style: .relative)
                .font(.system(size: 12))
                .foregroundColor(colors.textSecondary)
        }
    }

    // MARK: - Privacy Footer

    private var privacyFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
            Text("All history is stored locally on your device.")
                .font(.system(size: 12))
        }
        .foregroundColor(colors.textSecondary.opacity(0.6))
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func iconForAction(named name: String) -> String {
        TranslationRecord.systemImage(forActionNamed: name)
    }

    private func refreshRecords() {
        records = TranslationHistoryService.shared.fetchAll()
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: TranslationRecord.realtimeSystemImageName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(colors.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 5) {
                    HistoryMarkdownText(
                        text: session.displayTitle(fallback: record.sourceText),
                        font: .system(size: 15, weight: .semibold),
                        foregroundColor: colors.textPrimary,
                        lineLimit: 2
                    )
                    .allowsHitTesting(false)
                    Text(session.metaLine)
                        .font(.system(size: 12))
                        .foregroundColor(colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                HistoryMarkdownText(
                    text: session.translatedText,
                    font: .system(size: 14, weight: .medium),
                    foregroundColor: colors.textPrimary,
                    lineLimit: 2
                )
                .allowsHitTesting(false)
                HistoryMarkdownText(
                    text: session.sourceText,
                    font: .system(size: 13),
                    foregroundColor: colors.textSecondary,
                    lineLimit: 2
                )
                .allowsHitTesting(false)
            }

            HStack(spacing: 7) {
                MetadataChipView("Realtime", icon: TranslationRecord.realtimeSystemImageName, isPrimary: true)
                MetadataChipView(session.inputSource, icon: "mic.fill")
                if session.audioRecordings.contains(where: \.hasPlayableAudio) {
                    MetadataChipView("Recording", icon: "play.circle.fill")
                }
                if !session.modelDisplayName.isEmpty {
                    MetadataChipView(session.modelDisplayName, icon: "cpu")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
