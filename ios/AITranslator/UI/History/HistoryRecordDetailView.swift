//
//  HistoryRecordDetailView.swift
//  TLingo
//

import AVFoundation
import os
import ShareCore
import SwiftUI
import UniformTypeIdentifiers

private let historyDetailLogger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HistoryDetail")

struct HistoryRecordDetailView: View {
    let record: TranslationRecord

    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var visibleRealtimeCaptionSources: [UUID: RealtimeHistoryAudioSource] = [:]
    @State private var activeConversationSession: ConversationSession?
    @State private var showFeaturePaywall = false
    #if os(macOS)
        @State private var chatInspectorWidth: CGFloat = InspectorColumnWidth.ideal
        @State private var chatInspectorDragStartWidth: CGFloat?
    #endif

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

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
    }

    @ViewBuilder
    private var detailContent: some View {
        if let session = record.realtimeSession {
            RealtimeHistoryDetailContent(
                record: record,
                session: session,
                visibleCaptionSource: visibleCaptionSourceBinding(for: session)
            )
            .id(record.id)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader
                    sourceHeader
                    if let annotation = record.annotation(for: record.id) {
                        detailRecordAnnotation(annotation)
                    }
                    ForEach(record.modelResults) { result in
                        HistoryResultCard(result: result, sourceText: record.sourceText)
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
        private static let minimumMainWidthWithChat: CGFloat = 560

        @ViewBuilder
        private var macOSDetailContent: some View {
            if let session = activeConversationSession {
                GeometryReader { proxy in
                    if proxy.size.width >= Self.minimumMainWidthWithChat + chatInspectorWidth {
                        HStack(spacing: 0) {
                            detailContent
                                .frame(minWidth: Self.minimumMainWidthWithChat, maxWidth: .infinity, maxHeight: .infinity)
                            chatPanel(session: session)
                        }
                    } else {
                        ZStack(alignment: .trailing) {
                            detailContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            chatPanel(session: session)
                        }
                    }
                }
            } else {
                detailContent
            }
        }

        private func chatPanel(session: ConversationSession) -> some View {
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
            .frame(width: chatInspectorWidth)
            .frame(maxHeight: .infinity)
            .background(Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .overlay(alignment: .leading) {
                        Divider()
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startWidth = chatInspectorDragStartWidth ?? chatInspectorWidth
                                chatInspectorDragStartWidth = startWidth
                                chatInspectorWidth = InspectorColumnWidth.clamped(startWidth - value.translation.width)
                            }
                            .onEnded { _ in
                                chatInspectorDragStartWidth = nil
                            }
                    )
                    .accessibilityHidden(true)
            }
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
        let models = historyConversationModels
        let model = models.first ?? Self.fallbackConversationModel
        let action = ActionConfig(name: "History Chat", prompt: "")
        return ConversationSession(
            model: model,
            action: action,
            availableModels: models,
            messages: historyConversationMessages,
            annotationContext: HistoryAnnotationContext(
                recordID: record.id,
                targetIDs: record.annotationTargetIDs
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
        let recordModels = record.modelResults
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

        \(record.historyConversationContext)
        """
    }

    private static let fallbackConversationModel = ModelConfig(
        id: "gpt-5-nano",
        displayName: "GPT-5 Nano",
        isDefault: true,
        isPremium: false
    )

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !record.actionName.isEmpty {
                    MetadataChipView(
                        AppConfigurationStore.displayName(forActionName: record.actionName),
                        icon: iconForAction(named: record.actionName),
                        isPrimary: true
                    )
                }
                if record.isConversation {
                    MetadataChipView("Chat", icon: "bubble.left.and.bubble.right.fill")
                }
                if record.modelResults.count > 1 {
                    MetadataChipView("\(record.modelResults.count) models", icon: "cpu")
                } else if let first = record.modelResults.first, !first.modelDisplayName.isEmpty {
                    MetadataChipView(first.modelDisplayName, icon: "cpu")
                }
                Spacer(minLength: 8)
            }

            Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundColor(colors.textSecondary)
        }
    }

    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Source", systemImage: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                Spacer()
                Button {
                    PasteboardHelper.copy(record.sourceText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textSecondary)
                }
                .buttonStyle(.plain)
            }

            HistoryMarkdownText(
                text: record.sourceText,
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

private func primaryRealtimeCaptionSource(for session: RealtimeHistorySession) -> RealtimeHistoryAudioSource {
    session.primaryAudioSource
}

private let mossRealtimeHistoryModelID = "moss-transcribe-diarize"

// MARK: - Realtime Detail

private struct RealtimeHistoryDetailContent: View {
    private enum TrackDisplayMode: String, CaseIterable, Identifiable {
        case compare
        case single

        var id: String { rawValue }
    }

    let record: TranslationRecord
    let session: RealtimeHistorySession

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentSession: RealtimeHistorySession
    @Binding private var visibleCaptionSource: RealtimeHistoryAudioSource
    @State private var exportDocument: RealtimeHistoryExportDocument?
    @State private var isExportPresented = false
    @State private var exportError: String?
    @State private var trackDisplayMode: TrackDisplayMode
    @State private var selectedTrackID: UUID?
    @State private var playbackTime: TimeInterval = 0
    @State private var scrollTargetSegmentID: UUID?
    #if os(macOS) && arch(arm64)
        @State private var reconstructionProgress: RealtimeHistoryMOSSProgress?
        @State private var reconstructionTask: Task<Void, Never>?
        @State private var pendingReconstructionSource: RealtimeHistoryAudioSource?
        @State private var showMOSSDownloadConfirmation = false
    #endif
    #if os(macOS)
        @State private var reconstructionMessage: String?
        @State private var isSpeakerEditorPresented = false
        @State private var speakerNameDrafts: [String: String] = [:]
        @State private var speakerEditorTrackID: UUID?
        @State private var pendingSpeakerFocusID: String?
    #endif

    init(
        record: TranslationRecord,
        session: RealtimeHistorySession,
        visibleCaptionSource: Binding<RealtimeHistoryAudioSource>
    ) {
        self.record = record
        self.session = session
        _currentSession = State(initialValue: session)
        _visibleCaptionSource = visibleCaptionSource
        _trackDisplayMode = State(initialValue: .single)
        _selectedTrackID = State(
            initialValue: Self.preferredTrackID(
                in: session,
                source: primaryRealtimeCaptionSource(for: session)
            )
        )
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sessionHeader
                    #if os(macOS)
                        reconstructionError
                    #endif
                    #if os(macOS) && arch(arm64)
                        mossUpgradeBanner
                    #endif
                    captionContent
                }
                .padding(20)
            }
            .onChange(of: scrollTargetSegmentID) { _, segmentID in
                guard let segmentID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(segmentID, anchor: .center)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if currentSession.audioRecordings.contains(where: \.hasPlayableAudio) {
                floatingAudioTimeline
            }
        }
        .background(colors.background.ignoresSafeArea())
        .fileExporter(
            isPresented: $isExportPresented,
            document: exportDocument,
            contentType: .folder,
            defaultFilename: exportFilename
        ) { result in
            handleExport(result)
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
        #if os(macOS) && arch(arm64)
        .alert("Download MOSS Model?", isPresented: $showMOSSDownloadConfirmation) {
            Button("Download") {
                guard let source = pendingReconstructionSource else { return }
                startMOSSReconstruction(source: source)
            }
            Button("Cancel", role: .cancel) {
                pendingReconstructionSource = nil
            }
        } message: {
            Text("MOSS Diarization requires a \(RealtimeHistoryMOSSReconstructor.modelSizeDisplayName) download.")
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: $isSpeakerEditorPresented) {
            speakerEditor
                .id(pendingSpeakerFocusID)
        }
        #endif
        #if os(iOS)
        .navigationTitle("Realtime")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: session) { _, updatedSession in
            currentSession = updatedSession
            if !displayTracks.contains(where: { $0.id == selectedTrackID }) {
                selectedTrackID = preferredTrackID
            }
        }
        .onDisappear {
            #if os(macOS) && arch(arm64)
                reconstructionTask?.cancel()
                reconstructionTask = nil
            #endif
        }
        #if os(macOS) && arch(arm64)
        .task {
            while !Task.isCancelled {
                if let progress = await RealtimeHistoryMOSSReconstructor.shared.currentProgress {
                    reconstructionProgress = progress
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #endif
        .onChange(of: visibleCaptionSource) {
            selectedTrackID = preferredTrackID
            trackDisplayMode = .single
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HistoryMarkdownText(
                text: currentSession.displayTitle(fallback: record.sourceText),
                font: .system(size: 22, weight: .bold),
                foregroundColor: colors.textPrimary,
                lineLimit: 1
            )

            HStack(spacing: 8) {
                Text(currentSession.metaLine)
                    .font(.system(size: 12))
                    .foregroundColor(colors.textSecondary)

                Spacer()

                if !displayTracks.isEmpty {
                    versionMenu

                    #if os(macOS)
                        moreMenu
                    #endif
                }
            }
        }
    }

    private var versionMenu: some View {
        Menu {
            ForEach(displayTracks) { track in
                Button {
                    selectedTrackID = track.id
                    trackDisplayMode = .single
                } label: {
                    Label(
                        versionTitle(for: track),
                        systemImage: selectedTrack?.id == track.id && trackDisplayMode == .single
                            ? "checkmark"
                            : versionIcon(for: track)
                    )
                }
            }

            if displayTracks.count > 1 {
                Divider()
                Button {
                    trackDisplayMode = .compare
                } label: {
                    Label(
                        "Compare Versions",
                        systemImage: trackDisplayMode == .compare ? "checkmark" : "rectangle.split.2x1"
                    )
                }
            }
        } label: {
            Label(
                trackDisplayMode == .compare ? "Compare Versions" : selectedVersionTitle,
                systemImage: "doc.text"
            )
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(colors.chipSecondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    #if os(macOS)
        private var moreMenu: some View {
            Menu {
                if let selectedTrack {
                    let text = copyText(for: selectedTrack)
                    Button {
                        PasteboardHelper.copy(text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(text.isEmpty)

                    if selectedTrack.segments.contains(where: { $0.speakerID != nil }) {
                        Button {
                            presentSpeakerEditor(for: selectedTrack)
                        } label: {
                            Label("Edit Speaker Names", systemImage: "person.2")
                        }
                    }

                    Divider()
                }

                #if arch(arm64)
                    Button(action: requestMOSSReconstruction) {
                        Label(hasBuiltCaptions ? "Rebuild" : "Build Caption", systemImage: "text.magnifyingglass")
                    }
                #endif

                Button {
                    exportDocument = RealtimeHistoryExportDocument(session: currentSession)
                    isExportPresented = true
                } label: {
                    Label("Export Realtime History", systemImage: "square.and.arrow.up")
                }
                .disabled(!currentSession.audioRecordings.contains(where: \.hasPlayableAudio))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .background(colors.chipSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .help("More")
            .accessibilityLabel("More")
        }
    #endif

    private var exportFilename: String {
        let title = ConfigurationFileManager.sanitizeFilename(
            currentSession.displayTitle(fallback: record.sourceText)
        )
        let date = Self.exportDateFormatter.string(from: currentSession.startedAt)
        return "TLingo-Realtime-\(title)-\(date)"
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    private func handleExport(_ result: Result<URL, Error>) {
        if case let .failure(error) = result {
            exportError = error.localizedDescription
        }
    }

    private var primaryCaptionSource: RealtimeHistoryAudioSource {
        primaryRealtimeCaptionSource(for: currentSession)
    }

    private var audioTimeline: some View {
        RealtimeHistoryAudioTimelineView(
            recordings: currentSession.audioRecordings.filter(\.hasPlayableAudio),
            selectedSource: $visibleCaptionSource,
            playbackTime: $playbackTime,
            onScrub: scrollToPlaybackTime
        )
    }

    private var floatingAudioTimeline: some View {
        audioTimeline
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    private func scrollToPlaybackTime(_ time: TimeInterval) {
        scrollTargetSegmentID = selectedTrack?.activeSegmentID(at: time) ?? selectedTrack?.closestSegmentID(to: time)
    }

    #if os(macOS)
        @ViewBuilder
        private var reconstructionError: some View {
            if let reconstructionMessage {
                Text(reconstructionMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }
        }
    #endif

    #if os(macOS) && arch(arm64)
        private var hasBuiltCaptions: Bool {
            currentSession.tracks.contains {
                $0.audioSource == visibleCaptionSource &&
                    $0.recognitionModelID == mossRealtimeHistoryModelID
            }
        }

        @ViewBuilder
        private var mossUpgradeBanner: some View {
            if let reconstructionProgress {
                HStack(spacing: 6) {
                    progressView(reconstructionProgress)
                    Text(progressTitle(reconstructionProgress))
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(colors.chipSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help(progressTitle(reconstructionProgress))
                .accessibilityLabel(progressTitle(reconstructionProgress))
            } else if !hasBuiltCaptions {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Improve with MOSS")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.textPrimary)
                        Text("Create a more accurate transcript with speaker separation. Your realtime draft stays available.")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.textSecondary)
                    }

                    Spacer(minLength: 16)

                    Button(action: requestMOSSReconstruction) {
                        Label("Improve", systemImage: "text.magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white)
                    .background(colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(12)
                .background(colors.chipSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }

        private var emptyCaptionPrompt: some View {
            Group {
                if reconstructionProgress == nil {
                    Button(action: requestMOSSReconstruction) {
                        Label("Improve with MOSS", systemImage: "text.magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white)
                    .background(colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }

        @ViewBuilder
        private func progressView(_ progress: RealtimeHistoryMOSSProgress) -> some View {
            switch progress {
            case let .downloading(fraction):
                ProgressView(value: fraction)
                    .frame(width: 72)
            case .loadingModel, .preparingAudio, .transcribing:
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 72)
            case let .translating(completed, total, _):
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .frame(width: 72)
            }
        }

        private func progressTitle(_ progress: RealtimeHistoryMOSSProgress) -> String {
            switch progress {
            case let .downloading(fraction):
                return String(localized: "Downloading \(Int((fraction * 100).rounded()))%")
            case .loadingModel:
                return String(localized: "Loading model")
            case .preparingAudio:
                return String(localized: "Preparing audio")
            case .transcribing:
                return String(localized: "Recognizing speech")
            case let .translating(completed, total, _):
                return String(localized: "Translating \(completed) of \(total)")
            }
        }

        private func requestMOSSReconstruction() {
            guard reconstructionProgress == nil else { return }
            reconstructionMessage = nil
            let source = visibleCaptionSource
            Task { @MainActor in
                if await RealtimeHistoryMOSSReconstructor.shared.isModelCached() {
                    startMOSSReconstruction(source: source)
                } else {
                    pendingReconstructionSource = source
                    showMOSSDownloadConfirmation = true
                }
            }
        }

        private func startMOSSReconstruction(source: RealtimeHistoryAudioSource) {
            pendingReconstructionSource = nil
            reconstructionProgress = .downloading(fraction: 0)
            reconstructionMessage = nil
            reconstructionTask = Task { @MainActor in
                defer {
                    reconstructionProgress = nil
                    reconstructionTask = nil
                }
                do {
                    let track = try await RealtimeHistoryMOSSReconstructor.shared.reconstruct(
                        session: currentSession,
                        source: source
                    ) { progress in
                        reconstructionProgress = progress
                    }
                    try Task.checkCancellation()
                    currentSession = try TranslationHistoryService.shared.saveRealtimeTrack(
                        requestID: currentSession.requestID,
                        track: track
                    )
                    visibleCaptionSource = source
                    selectedTrackID = currentSession.tracks.first {
                        $0.audioSource == source &&
                            $0.recognitionModelID == mossRealtimeHistoryModelID
                    }?.id
                    trackDisplayMode = .single
                } catch is CancellationError {
                    return
                } catch {
                    historyDetailLogger.error(
                        "MOSS reconstruction failed: \(String(describing: error), privacy: .public)"
                    )
                    reconstructionMessage = error.localizedDescription
                }
            }
        }
    #endif

    @ViewBuilder
    private var captionContent: some View {
        #if os(macOS) && arch(arm64)
            if !reconstructionSegments.isEmpty {
                reconstructionTranscriptList
            } else if trackDisplayMode == .compare,
                      displayTracks.count > 1
            {
                compareTracks
            } else if selectedTrack?.segments.isEmpty != false {
                if reconstructionProgress == nil {
                    emptyCaptionPrompt
                }
            } else {
                transcriptList
            }
        #else
            if trackDisplayMode == .compare,
               displayTracks.count > 1
            {
                compareTracks
            } else if selectedTrack?.segments.isEmpty != false {
                #if os(macOS) && arch(arm64)
                    if reconstructionProgress == nil {
                        emptyCaptionPrompt
                    }
                #endif
            } else {
                transcriptList
            }
        #endif
    }

    #if os(macOS) && arch(arm64)
        private var reconstructionSegments: [RealtimeHistoryTrackSegment] {
            switch reconstructionProgress {
            case let .transcribing(segments), let .translating(_, _, segments):
                return segments
            case .downloading, .loadingModel, .preparingAudio, nil:
                return []
            }
        }

        private var reconstructionTranscriptList: some View {
            let previewTrack = RealtimeHistoryTrack(
                recognitionModelID: mossRealtimeHistoryModelID,
                recognitionModelDisplayName: RealtimeHistoryMOSSReconstructor.modelDisplayName,
                translationProviderID: ModelConfig.appleTranslateID,
                translationProviderDisplayName: ModelConfig.appleTranslate.displayName,
                segments: reconstructionSegments
            )
            return VStack(alignment: .leading, spacing: 10) {
                ForEach(reconstructionSegments) { segment in
                    RealtimeTranscriptRow(
                        segment: displaySegment(from: segment),
                        duration: segment.duration,
                        speakerID: segment.speakerID,
                        speakerName: speakerName(for: segment, track: previewTrack),
                        alignment: previewAlignment(for: segment, track: previewTrack),
                        annotation: nil
                    )
                }
            }
        }

        private func previewAlignment(
            for segment: RealtimeHistoryTrackSegment,
            track: RealtimeHistoryTrack
        ) -> RealtimeTranscriptRow.Alignment {
            guard let rawSpeakerID = segment.speakerID,
                  let dominantSpeakers = track.dominantConversationSpeakerIDs
            else {
                return .leading
            }
            let speakerID = track.conversationSpeakerID(for: rawSpeakerID)
            return speakerID == dominantSpeakers[1] ? .trailing : .leading
        }
    #endif

    private var visibleTranscriptSegments: [RealtimeHistorySegment] {
        if !displayTracks.isEmpty {
            return selectedTrack?.segments.map(displaySegment(from:)) ?? currentSession.segments
        }
        return currentSession.delayedTranscriptSegments
            .filter { $0.source == visibleCaptionSource }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.offset < $1.offset }
            .map {
                RealtimeHistorySegment(
                    id: $0.id,
                    offset: $0.offset,
                    sourceText: $0.text,
                    translatedText: $0.translatedText
                )
            }
    }

    private var transcriptList: some View {
        let annotations = record.historyAnnotations
        return VStack(alignment: .leading, spacing: 10) {
            if let selectedTrack {
                ForEach(selectedTrack.segments) { segment in
                    transcriptRow(segment, annotation: annotations[segment.id.uuidString])
                        .id(segment.id)
                }
            } else {
                ForEach(visibleTranscriptSegments) { segment in
                    RealtimeTranscriptRow(
                        segment: segment,
                        annotation: annotations[segment.id.uuidString]
                    )
                }
            }
        }
    }

    private var compareTracks: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(displayTracks) { track in
                    VStack(alignment: .leading, spacing: 12) {
                        trackHeader(track)

                        ForEach(track.segments) { segment in
                            transcriptRow(
                                segment,
                                track: track,
                                annotation: record.historyAnnotations[segment.id.uuidString]
                            )
                            .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 560, alignment: .topLeading)

                    if track.id != displayTracks.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func trackHeader(_ track: RealtimeHistoryTrack) -> some View {
        let text = copyText(for: track)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(versionTitle(for: track))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(2)
                .help(track.title)

            Button {
                PasteboardHelper.copy(text)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .accessibilityLabel("Copy")

            #if os(macOS)
                if track.segments.contains(where: { $0.speakerID != nil }) {
                    Button {
                        presentSpeakerEditor(for: track)
                    } label: {
                        Image(systemName: "person.2")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit Speaker Names")
                }
            #endif

            Spacer()
        }
    }

    private var displayTracks: [RealtimeHistoryTrack] {
        let storedTracks = currentSession.tracks.filter {
            ($0.audioSource ?? primaryCaptionSource) == visibleCaptionSource
        }
        if visibleCaptionSource == primaryCaptionSource {
            if !storedTracks.isEmpty {
                return storedTracks
            }
            return [primaryFallbackTrack]
        }

        let sourceSegments = currentSession.delayedTranscriptSegments
            .filter { $0.source == visibleCaptionSource }
            .sorted { $0.offset < $1.offset }
        guard !sourceSegments.isEmpty else { return storedTracks }
        let fallback = RealtimeHistoryTrack(
            id: currentSession.requestID,
            audioSource: visibleCaptionSource,
            recognitionModelID: currentSession.transcriptionModel(for: visibleCaptionSource)?.modelID ??
                RecognitionModelDescriptor.appleSpeech.id,
            recognitionModelDisplayName: currentSession.transcriptionModel(for: visibleCaptionSource)?.modelDisplayName ??
                RecognitionModelDescriptor.appleSpeech.title,
            translationProviderID: currentSession.modelID,
            translationProviderDisplayName: currentSession.modelDisplayName,
            segments: sourceSegments.map {
                RealtimeHistoryTrackSegment(
                    id: $0.id,
                    offset: $0.offset,
                    duration: $0.duration,
                    sourceText: $0.text,
                    translatedText: $0.translatedText,
                    relation: $0.translatedText.isEmpty ? .sourceOnly : .paired
                )
            }
        )
        return [fallback] + storedTracks
    }

    private var primaryFallbackTrack: RealtimeHistoryTrack {
        RealtimeHistoryTrack(
            id: currentSession.primaryTrackID ?? currentSession.requestID,
            audioSource: primaryCaptionSource,
            recognitionModelID: currentSession.transcriptionModels.first?.modelID ??
                RecognitionModelDescriptor.appleSpeech.id,
            recognitionModelDisplayName: currentSession.transcriptionModels.first?.modelDisplayName ??
                RecognitionModelDescriptor.appleSpeech.title,
            translationProviderID: currentSession.modelID,
            translationProviderDisplayName: currentSession.modelDisplayName,
            segments: currentSession.segments.map {
                RealtimeHistoryTrackSegment(
                    id: $0.id,
                    offset: $0.offset,
                    sourceText: $0.sourceText,
                    translatedText: $0.translatedText,
                    relation: .paired
                )
            }
        )
    }

    private var selectedTrack: RealtimeHistoryTrack? {
        if let selectedTrackID,
           let track = displayTracks.first(where: { $0.id == selectedTrackID })
        {
            return track
        }
        return displayTracks.first(where: { $0.id == preferredTrackID }) ?? displayTracks.first
    }

    private var preferredTrackID: UUID? {
        Self.preferredTrackID(in: currentSession, source: visibleCaptionSource)
    }

    private static func preferredTrackID(
        in session: RealtimeHistorySession,
        source: RealtimeHistoryAudioSource
    ) -> UUID? {
        let tracks = session.tracks.filter {
            ($0.audioSource ?? session.primaryAudioSource) == source
        }
        return tracks.first(where: { $0.recognitionModelID == mossRealtimeHistoryModelID })?.id
            ?? tracks.first(where: { $0.id == session.primaryTrackID })?.id
            ?? tracks.first?.id
    }

    private var selectedVersionTitle: String {
        selectedTrack.map(versionTitle(for:)) ?? String(localized: "Transcript")
    }

    private func versionTitle(for track: RealtimeHistoryTrack) -> String {
        if track.recognitionModelID == mossRealtimeHistoryModelID {
            return String(localized: "MOSS Optimized")
        }
        let realtimeTracks = displayTracks.filter { $0.recognitionModelID != mossRealtimeHistoryModelID }
        if realtimeTracks.count > 1 {
            return String(localized: "Realtime Draft · \(track.recognitionModelDisplayName)")
        }
        return String(localized: "Realtime Draft")
    }

    private func versionIcon(for track: RealtimeHistoryTrack) -> String {
        track.recognitionModelID == mossRealtimeHistoryModelID ? "sparkles" : "waveform"
    }

    private func copyText(for track: RealtimeHistoryTrack) -> String {
        let hasTranslation = track.segments.contains {
            !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return track.segments.compactMap { segment in
            let source = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty || !translation.isEmpty else { return nil }
            if hasTranslation {
                return ["[\(segment.offsetLabel)]", source, translation]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
            return "[\(segment.offsetLabel)] \(source)"
        }
        .joined(separator: hasTranslation ? "\n\n" : "\n")
    }

    private func displaySegment(from segment: RealtimeHistoryTrackSegment) -> RealtimeHistorySegment {
        RealtimeHistorySegment(
            id: segment.id,
            offset: segment.offset,
            sourceText: segment.sourceText,
            translatedText: segment.translatedText
        )
    }

    private func transcriptRow(
        _ segment: RealtimeHistoryTrackSegment,
        track: RealtimeHistoryTrack? = nil,
        annotation: String?
    ) -> some View {
        let track = track ?? selectedTrack
        let isActive = track?.activeSegmentID(at: playbackTime) == segment.id
        let onSeek: (() -> Void)? = {
            playbackTime = segment.offset
        }
        #if os(macOS)
            let onRenameSpeaker = segment.speakerID.map { speakerID in
                { presentSpeakerEditor(for: speakerID, track: track) }
            }
        #else
            let onRenameSpeaker: (() -> Void)? = nil
        #endif
        return RealtimeTranscriptRow(
            segment: displaySegment(from: segment),
            duration: segment.duration,
            speakerID: segment.speakerID,
            speakerName: speakerName(for: segment, track: track),
            alignment: transcriptAlignment(for: segment, track: track),
            isActive: isActive,
            annotation: annotation,
            onSeek: onSeek,
            onRenameSpeaker: onRenameSpeaker
        )
    }

    private func transcriptAlignment(
        for segment: RealtimeHistoryTrackSegment,
        track: RealtimeHistoryTrack?
    ) -> RealtimeTranscriptRow.Alignment {
        guard let rawSpeakerID = segment.speakerID,
              let dominantSpeakers = track?.dominantConversationSpeakerIDs
        else {
            return .leading
        }
        let speakerID = track?.conversationSpeakerID(for: rawSpeakerID) ?? rawSpeakerID
        return speakerID == dominantSpeakers[1] ? .trailing : .leading
    }

    private func speakerName(
        for segment: RealtimeHistoryTrackSegment,
        track: RealtimeHistoryTrack?
    ) -> String? {
        guard let rawSpeakerID = segment.speakerID else { return nil }
        if let name = currentSession.speakerNames[rawSpeakerID] {
            return name
        }
        let groupedSpeakerID = track?.conversationSpeakerID(for: rawSpeakerID) ?? rawSpeakerID
        if let name = currentSession.speakerNames[groupedSpeakerID] {
            return name
        }
        guard let dominantSpeakers = track?.dominantConversationSpeakerIDs,
              let index = dominantSpeakers.firstIndex(of: groupedSpeakerID)
        else {
            guard let track,
                  track.recognitionModelID == mossRealtimeHistoryModelID
            else {
                return nil
            }

            var durationBySpeaker: [String: TimeInterval] = [:]
            for segment in track.segments {
                guard let speakerID = segment.speakerID else { continue }
                let groupedSpeakerID = track.conversationSpeakerID(for: speakerID)
                durationBySpeaker[groupedSpeakerID, default: 0] += max(segment.duration, 0)
            }
            let speakerIDs = durationBySpeaker.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.map(\.key)
            guard let index = speakerIDs.firstIndex(of: groupedSpeakerID) else { return nil }
            return Self.defaultSpeakerName(for: index)
        }
        return Self.defaultSpeakerName(for: index)
    }

    private static func defaultSpeakerName(for index: Int) -> String {
        var index = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(65 + index % 26)!) + letters
            index = index / 26 - 1
        } while index >= 0
        return "Person \(letters)"
    }

    #if os(macOS)
        private var speakerIDs: [String] {
            let track = displayTracks.first { $0.id == speakerEditorTrackID }
            return Array(Set(track?.segments.compactMap(\.speakerID) ?? [])).sorted()
        }

        private func presentSpeakerEditor(for track: RealtimeHistoryTrack) {
            speakerNameDrafts = currentSession.speakerNames
            speakerEditorTrackID = track.id
            pendingSpeakerFocusID = nil
            isSpeakerEditorPresented = true
        }

        private func presentSpeakerEditor(
            for speakerID: String,
            track: RealtimeHistoryTrack?
        ) {
            historyDetailLogger.debug(
                """
                Speaker rename tapped \
                id=\(speakerID, privacy: .public) \
                name=\(currentSession.speakerNames[speakerID] ?? "-", privacy: .public)
                """
            )
            speakerNameDrafts = currentSession.speakerNames
            speakerEditorTrackID = track?.id
            pendingSpeakerFocusID = speakerID
            isSpeakerEditorPresented = true
        }

        private var speakerEditor: some View {
            SpeakerNameEditor(
                speakerIDs: speakerIDs,
                names: $speakerNameDrafts,
                initialFocusID: pendingSpeakerFocusID,
                onCancel: {
                    isSpeakerEditorPresented = false
                },
                onSave: {
                    do {
                        currentSession = try TranslationHistoryService.shared.updateRealtimeSpeakerNames(
                            requestID: currentSession.requestID,
                            names: speakerNameDrafts
                        )
                        isSpeakerEditorPresented = false
                    } catch {
                        reconstructionMessage = error.localizedDescription
                    }
                }
            )
            .onDisappear {
                speakerEditorTrackID = nil
                pendingSpeakerFocusID = nil
            }
        }
    #endif
}

#if os(macOS)
    private struct SpeakerNameEditor: View {
        let speakerIDs: [String]
        @Binding var names: [String: String]
        let initialFocusID: String?
        let onCancel: () -> Void
        let onSave: () -> Void

        @Environment(\.colorScheme) private var colorScheme
        @FocusState private var focusedSpeakerID: String?

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Speaker Names")
                    .font(.system(size: 17, weight: .semibold))

                ForEach(speakerIDs, id: \.self) { speakerID in
                    HStack {
                        Text("Speaker \(speakerID)")
                            .foregroundStyle(colors.textSecondary)
                            .frame(width: 100, alignment: .leading)
                        TextField(
                            "Name",
                            text: Binding(
                                get: { names[speakerID] ?? "" },
                                set: { names[speakerID] = $0 }
                            )
                        )
                        .focused($focusedSpeakerID, equals: speakerID)
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onCancel)
                    Button("Save", action: onSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
            .task {
                historyDetailLogger.debug(
                    "Speaker editor appeared target=\(initialFocusID ?? "nil", privacy: .public)"
                )
                try? await Task.sleep(for: .milliseconds(100))
                focusedSpeakerID = initialFocusID
                historyDetailLogger.debug(
                    "Speaker focus requested id=\(focusedSpeakerID ?? "nil", privacy: .public)"
                )
            }
            .onChange(of: focusedSpeakerID) { _, speakerID in
                historyDetailLogger.debug(
                    "Speaker focus changed id=\(speakerID ?? "nil", privacy: .public)"
                )
            }
            .onDisappear {
                historyDetailLogger.debug(
                    """
                    Speaker editor disappeared \
                    target=\(initialFocusID ?? "nil", privacy: .public) \
                    focus=\(focusedSpeakerID ?? "nil", privacy: .public)
                    """
                )
            }
        }
    }
#endif

private struct RealtimeTranscriptRow: View {
    enum Alignment {
        case leading
        case trailing
    }

    let segment: RealtimeHistorySegment
    let duration: TimeInterval
    let speakerID: String?
    let speakerName: String?
    let alignment: Alignment
    let isActive: Bool
    let annotation: String?
    let onSeek: (() -> Void)?
    let onRenameSpeaker: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    init(
        segment: RealtimeHistorySegment,
        duration: TimeInterval = 0,
        speakerID: String? = nil,
        speakerName: String? = nil,
        alignment: Alignment = .leading,
        isActive: Bool = false,
        annotation: String?,
        onSeek: (() -> Void)? = nil,
        onRenameSpeaker: (() -> Void)? = nil
    ) {
        self.segment = segment
        self.duration = duration
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.alignment = alignment
        self.isActive = isActive
        self.annotation = annotation
        self.onSeek = onSeek
        self.onRenameSpeaker = onRenameSpeaker
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if alignment == .trailing {
                Spacer(minLength: 120)
            } else {
                timestampButton
            }

            VStack(alignment: .leading, spacing: 5) {
                HistoryMarkdownText(
                    text: segment.sourceText,
                    font: .system(size: 13),
                    foregroundColor: colors.textSecondary
                )
                if !segment.translatedText.isEmpty {
                    HistoryMarkdownText(
                        text: segment.translatedText,
                        font: .system(size: 15, weight: .medium),
                        foregroundColor: colors.textPrimary
                    )
                }
                if let annotation {
                    Rectangle()
                        .fill(colors.divider.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                        .padding(.vertical, 5)
                    HistoryMarkdownText(
                        text: annotation,
                        font: .system(size: 12),
                        foregroundColor: colors.textSecondary,
                        emphasizesStructure: true
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: speakerID == nil ? .infinity : 760, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? colors.accent.opacity(0.10) : colors.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? colors.accent.opacity(0.45) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSeek?()
            }

            if alignment == .leading {
                Spacer(minLength: 0)
            } else {
                timestampButton
            }
        }
    }

    private var timestampButton: some View {
        Group {
            if let onRenameSpeaker {
                sideLabelText
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onRenameSpeaker()
                    }
            } else {
                Button {
                    onSeek?()
                } label: {
                    sideLabelText
                }
                .buttonStyle(.plain)
                .disabled(onSeek == nil)
            }
        }
        .accessibilityLabel(onRenameSpeaker == nil ? "Seek" : "Rename Speaker")
    }

    private var sideLabelText: some View {
        Text(sideLabel)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(isActive ? colors.accent : colors.textSecondary)
            .frame(
                width: speakerID == nil ? 42 : 82,
                height: 32,
                alignment: alignment == .trailing ? .leading : .trailing
            )
            .padding(.top, 4)
    }

    private var sideLabel: String {
        guard let speakerID else { return segment.offsetLabel }
        if let speakerName {
            return speakerName
        }
        return speakerID.hasPrefix("S") ? "SP\(speakerID.dropFirst())" : speakerID
    }
}

// MARK: - Result Card

private struct HistoryResultCard: View {
    let result: ModelResult
    let sourceText: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

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
