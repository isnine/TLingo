//
//  HistoryRecordDetailView.swift
//  TLingo
//

import AVFoundation
import os
import ShareCore
import SwiftUI
import UniformTypeIdentifiers

let historyDetailLogger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HistoryDetail")

struct HistoryRecordDetailView: View {
    let record: TranslationRecord

    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var refreshedRecord: TranslationRecord?
    @State private var visibleRealtimeCaptionSources: [UUID: RealtimeHistoryAudioSource] = [:]
    @State private var activeConversationSession: ConversationSession?
    @State private var showFeaturePaywall = false

    private var activeRecord: TranslationRecord {
        refreshedRecord?.id == record.id ? (refreshedRecord ?? record) : record
    }

    @ThemeColors private var colors: AppColorPalette

    var body: some View {
        Group {
            #if os(macOS)
                macOSDetailContent
                    .toolbar {
                        ToolbarSpacer(.flexible)

                        ToolbarItem {
                            chatButton
                        }
                    }
                    .onAppear {
                        if MacSnapshotScene.current() == .historyChat,
                           activeConversationSession == nil
                        {
                            activeConversationSession = makeHistoryConversationSession()
                        }
                    }
                    .onChange(of: record.id) {
                        guard activeConversationSession != nil else { return }
                        activeConversationSession = makeHistoryConversationSession()
                    }
            #else
                detailContent
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            chatButton
                        }
                    }
                    .inspector(isPresented: conversationInspectorBinding) {
                        if let session = activeConversationSession {
                            ConversationContentView(
                                session: session,
                                onPremiumRequired: {
                                    showFeaturePaywall = true
                                }
                            )
                            .id(session.id)
                            .inspectorColumnWidth(
                                min: InspectorColumnWidth.min,
                                ideal: InspectorColumnWidth.ideal,
                                max: InspectorColumnWidth.max
                            )
                        }
                    }
                    .sheet(item: conversationSheetBinding) { session in
                        ConversationView(
                            session: session,
                            onPremiumRequired: {
                                showFeaturePaywall = true
                            }
                        )
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                    }
                    .onChange(of: record.id) {
                        guard activeConversationSession != nil else { return }
                        activeConversationSession = makeHistoryConversationSession()
                    }
            #endif
        }
        .sheet(isPresented: $showFeaturePaywall) {
            PaywallView(context: .featureLocked)
        }
        .onChange(of: record.id) {
            refreshedRecord = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .translationRecordSaved)) { _ in
            if let latest = TranslationHistoryService.shared.fetchRecord(id: record.id) {
                refreshedRecord = latest
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        let currentRecord = activeRecord
        if let session = currentRecord.realtimeSession {
            RealtimeHistoryDetailContent(
                record: currentRecord,
                session: session,
                visibleCaptionSource: visibleCaptionSourceBinding(for: session)
            )
            .id(currentRecord.id)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader
                    sourceHeader
                    if let annotation = currentRecord.annotation(for: currentRecord.id) {
                        detailRecordAnnotation(annotation)
                    }
                    ForEach(currentRecord.modelResults) { result in
                        HistoryResultCard(result: result, sourceText: currentRecord.sourceText)
                    }
                }
                .padding(20)
            }
            .background(colors.background.ignoresSafeArea())
        }
    }

    private func visibleCaptionSourceBinding(for session: RealtimeHistorySession) -> Binding<RealtimeHistoryAudioSource> {
        Binding(
            get: { visibleRealtimeCaptionSources[record.id] ?? primaryRealtimeCaptionSource(for: session) },
            set: { visibleRealtimeCaptionSources[record.id] = $0 }
        )
    }

    #if os(iOS)
        private var usesConversationInspectorPresentation: Bool {
            horizontalSizeClass == .regular
        }

        private var conversationInspectorBinding: Binding<Bool> {
            Binding(
                get: {
                    usesConversationInspectorPresentation && activeConversationSession != nil
                },
                set: { isPresented in
                    if !isPresented {
                        activeConversationSession = nil
                    }
                }
            )
        }

        private var conversationSheetBinding: Binding<ConversationSession?> {
            Binding(
                get: {
                    usesConversationInspectorPresentation ? nil : activeConversationSession
                },
                set: { session in
                    activeConversationSession = session
                }
            )
        }
    #endif

    #if os(macOS)
        private var macOSDetailContent: some View {
            detailContent
                .inspector(isPresented: macOSConversationInspectorBinding) {
                    if let session = activeConversationSession {
                        ConversationContentView(
                            session: session,
                            onDismiss: {
                                activeConversationSession = nil
                            },
                            onPremiumRequired: {
                                showFeaturePaywall = true
                            }
                        )
                        .id(session.id)
                        .inspectorColumnWidth(
                            min: InspectorColumnWidth.min,
                            ideal: InspectorColumnWidth.ideal,
                            max: InspectorColumnWidth.max
                        )
                    }
                }
        }

        private var macOSConversationInspectorBinding: Binding<Bool> {
            Binding(
                get: { activeConversationSession != nil },
                set: { isPresented in
                    if !isPresented {
                        activeConversationSession = nil
                    }
                }
            )
        }

    #endif

    private var chatButton: some View {
        Button(chatButtonTitle, systemImage: "text.bubble", action: toggleHistoryConversation)
            .labelStyle(.iconOnly)
            .help(chatButtonTitle)
            .accessibilityLabel(chatButtonTitle)
            .accessibilityIdentifier("history_detail_chat_button")
    }

    private var chatButtonTitle: String {
        activeConversationSession == nil ? "Continue in Chat" : "Hide Chat"
    }

    private func toggleHistoryConversation() {
        if activeConversationSession == nil {
            activeConversationSession = makeHistoryConversationSession()
        } else {
            activeConversationSession = nil
        }
    }

    private func makeHistoryConversationSession() -> ConversationSession {
        let currentRecord = activeRecord
        let models = historyConversationModels
        let model = models.first ?? Self.fallbackConversationModel
        let action = ActionConfig(name: "History Chat", prompt: "")
        return ConversationSession(
            model: model,
            action: action,
            availableModels: models,
            messages: historyConversationMessages,
            annotationContext: HistoryAnnotationContext(
                recordID: currentRecord.id,
                targetIDs: currentRecord.annotationTargetIDs
            )
        )
    }

    private var historyConversationMessages: [ChatMessage] {
        #if os(macOS)
            if MacSnapshotScene.current() == .historyChat {
                return MacSnapshotData.historyChatMessages()
            }
        #endif
        return [ChatMessage(role: "system", content: historyConversationContext)]
    }

    private var historyConversationModels: [ModelConfig] {
        let cachedModels = (ModelsService.shared.getCachedModels() ?? []).filter { !$0.isDirectTranslation }
        let defaultCachedModels = cachedModels.filter(\.isDefault)
        let recordModels = activeRecord.modelResults
            .filter {
                !ModelConfig.isDirectTranslationID($0.modelID)
                    && !ModelConfig.isFoundationModelID($0.modelID)
            }
            .map { result in
                cachedModels.first { $0.id == result.modelID } ?? ModelConfig(
                    id: result.modelID,
                    displayName: result.modelDisplayName.isEmpty ? result.modelID : result.modelDisplayName
                )
            }

        var models: [ModelConfig] = []
        for model in defaultCachedModels + recordModels + cachedModels + [Self.fallbackConversationModel] {
            guard !models.contains(where: { $0.id == model.id }) else { continue }
            models.append(model)
        }
        return models
    }

    private var historyConversationContext: String {
        """
        The user is viewing a TLingo history record. Use only this record as context for the conversation.
        When the user asks for a visual note or annotation, call save_history_annotation.
        For realtime audio records, save annotations to the matching Cell ID for each sentence.
        For non-realtime records, save annotations to the History Record ID.
        Annotations are rendered as CommonMark Markdown. Prefer concise Markdown: **bold** for key points, \
        - bullets or 1. steps for structure, `inline code` for terms, > block quotes for callouts, and links only when \
        useful. \
        Use short tables or task lists only when they add clarity; avoid images and large code blocks.
        Do not repeat the original/source text inside annotations; the history cell already shows it.

        \(activeRecord.historyConversationContext)
        """
    }

    private static let fallbackConversationModel = ModelConfig(
        id: "gpt-5-nano",
        displayName: "GPT-5 Nano",
        isDefault: true,
        isPremium: false
    )

    private var detailHeader: some View {
        let currentRecord = activeRecord
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !currentRecord.actionName.isEmpty {
                    MetadataChipView(
                        AppConfigurationStore.displayName(forActionName: currentRecord.actionName),
                        icon: iconForAction(named: currentRecord.actionName),
                        isPrimary: true
                    )
                }
                if currentRecord.isConversation {
                    MetadataChipView("Chat", icon: "bubble.left.and.bubble.right.fill")
                }
                if currentRecord.modelResults.count > 1 {
                    MetadataChipView("\(currentRecord.modelResults.count) models", icon: "cpu")
                } else if let first = currentRecord.modelResults.first, !first.modelDisplayName.isEmpty {
                    MetadataChipView(first.modelDisplayName, icon: "cpu")
                }
                Spacer(minLength: 8)
            }

            Text(currentRecord.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundColor(colors.textSecondary)
        }
    }

    private var sourceHeader: some View {
        let currentRecord = activeRecord
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Source", systemImage: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                Spacer()
                Button {
                    PasteboardHelper.copy(currentRecord.sourceText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textSecondary)
                }
                .buttonStyle(.plain)
            }

            HistoryMarkdownText(
                text: currentRecord.sourceText,
                font: .system(size: 16),
                foregroundColor: colors.textSecondary
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.cardBackground)
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(colors.accent.opacity(0.6))
            .frame(width: 3)
        }
    }

    private func detailRecordAnnotation(_ text: String) -> some View {
        HistoryMarkdownText(
            text: text,
            font: .system(size: 13),
            foregroundColor: colors.textSecondary,
            emphasizesStructure: true
        )
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.cardBackground)
        )
    }

    private func iconForAction(named name: String) -> String {
        TranslationRecord.systemImage(forActionNamed: name)
    }
}

// MARK: - Result Card

private struct HistoryResultCard: View {
    let result: ModelResult
    let sourceText: String

    @Environment(\.colorScheme) private var colorScheme

    @ThemeColors private var colors: AppColorPalette

    private var durationText: String? {
        guard result.duration > 0 else { return nil }
        return String(format: "%.1fs", result.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.modelDisplayName.isEmpty ? String(localized: "Result") : result.modelDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    if let duration = durationText {
                        Text(duration)
                            .font(.system(size: 12))
                            .foregroundColor(colors.textSecondary)
                    }
                }

                Spacer()

                Menu {
                    Button {
                        PasteboardHelper.copy(result.resultText)
                    } label: {
                        Label("Copy Result", systemImage: "doc.on.doc")
                    }
                    Button {
                        PasteboardHelper.copy(sourceText)
                    } label: {
                        Label("Copy Source", systemImage: "doc.on.doc")
                    }
                    Button {
                        PasteboardHelper.copy("\(sourceText)\n\n\(result.resultText)")
                    } label: {
                        Label("Copy Bilingual", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(colors.textSecondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }

            HistoryMarkdownText(
                text: result.resultText,
                font: .system(size: 15),
                foregroundColor: colors.textPrimary,
                emphasizesStructure: true
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.cardBackground)
        )
    }
}
