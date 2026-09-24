//
//  SidebarLayoutView.swift
//  TLingo
//
//  Created by Codex on 2026/03/27.
//

import ShareCore
import SwiftUI

private let sidebarHistoryPageSize = 5

private enum SidebarHistoryKind: CaseIterable, Identifiable {
    case text
    case chat
    case realtime

    var id: Self { self }

    var sortOrder: Int {
        switch self {
        case .text: 0
        case .chat: 1
        case .realtime: 2
        }
    }
}

private func sidebarHistorySectionOrder(
    textRecords: [TranslationRecord],
    chatRecords: [TranslationRecord],
    realtimeRecords: [TranslationRecord]
) -> [SidebarHistoryKind] {
    func latestTimestamp(for kind: SidebarHistoryKind) -> Date? {
        switch kind {
        case .text:
            return textRecords.first?.timestamp
        case .chat:
            return chatRecords.first?.timestamp
        case .realtime:
            return realtimeRecords.first?.timestamp
        }
    }

    return SidebarHistoryKind.allCases.sorted { lhs, rhs in
        switch (latestTimestamp(for: lhs), latestTimestamp(for: rhs)) {
        case let (lhsTimestamp?, rhsTimestamp?):
            return lhsTimestamp == rhsTimestamp ? lhs.sortOrder < rhs.sortOrder : lhsTimestamp > rhsTimestamp
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.sortOrder < rhs.sortOrder
        }
    }
}

private struct HistorySidebarLabel: View {
    let record: TranslationRecord

    var body: some View {
        let session = record.realtimeSession
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session?.displayTitle(fallback: record.sourceText) ?? record.sourceText)
                    .lineLimit(1)
                if let session {
                    Text("\(session.clockDurationLabel) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }
}

@MainActor
func conversationSession(for record: TranslationRecord) -> ConversationSession {
    let cachedModels = (ModelsService.shared.getCachedModels() ?? []).filter { !$0.isDirectTranslation }
    let recordModels = record.modelResults.map { result in
        cachedModels.first { $0.id == result.modelID } ?? ModelConfig(
            id: result.modelID,
            displayName: result.modelDisplayName.isEmpty ? result.modelID : result.modelDisplayName
        )
    }
    var availableModels: [ModelConfig] = []
    for model in recordModels + cachedModels {
        guard !availableModels.contains(where: { $0.id == model.id }) else { continue }
        availableModels.append(model)
    }
    let model = availableModels.first ?? ModelConfig(
        id: "gpt-5-nano",
        displayName: "GPT-5 Nano",
        isDefault: true,
        isPremium: false
    )
    let legacyMessages = [ChatMessage(role: "user", content: record.sourceText)]
        + record.modelResults.map { ChatMessage(role: "assistant", content: $0.resultText) }
    let messages = record.conversationMessages.isEmpty ? legacyMessages : record.conversationMessages
    return ConversationSession(
        id: record.requestID,
        model: model,
        action: ActionConfig(name: "Chat", prompt: ""),
        availableModels: availableModels.isEmpty ? [model] : availableModels,
        messages: messages
    )
}

private struct SidebarHistorySection<SelectionValue: Hashable>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let records: [TranslationRecord]
    let visibleCount: Int
    let tag: (UUID) -> SelectionValue
    let onShowMore: () -> Void

    @ViewBuilder
    var body: some View {
        if !records.isEmpty {
            Section {
                ForEach(records.prefix(visibleCount)) { record in
                    HistorySidebarLabel(record: record).tag(tag(record.id))
                }

                if records.count > visibleCount {
                    Button(action: onShowMore) {
                        Label("Show More", systemImage: "chevron.down")
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Image(systemName: systemImage)
                    Text(title)
                }
            }
        }
    }
}

#if os(macOS)

    // MARK: - Sidebar Selection

    enum SidebarSelection: Hashable {
        case tab(RootTabView.TabItem)
        case historyRecord(UUID)
    }

    // MARK: - SidebarLayoutView

    struct SidebarLayoutView: View {
        @Environment(\.colorScheme) private var colorScheme
        @State private var selection: SidebarSelection?
        @State private var columnVisibility: NavigationSplitViewVisibility
        @State private var historyRecords: [TranslationRecord] = []
        @State private var historyRefreshTask: Task<Void, Never>?
        @State private var visibleTextHistoryCount = sidebarHistoryPageSize
        @State private var visibleChatHistoryCount = sidebarHistoryPageSize
        @State private var visibleRealtimeHistoryCount = sidebarHistoryPageSize
        @State private var showActions = false
        @State private var showFeaturePaywall = false
        @StateObject private var realtimeStore = RealtimeSessionStore.shared
        @ObservedObject private var configStore: AppConfigurationStore
        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var storeManager = StoreManager.shared
        #if DIRECT_DISTRIBUTION
            @ObservedObject private var updater = UpdaterController.shared
        #endif

        init(initialTab: RootTabView.TabItem, configStore: AppConfigurationStore) {
            let scene = MacSnapshotScene.current()
            _columnVisibility = State(initialValue: scene?.showsSidebar == false ? .detailOnly : .all)
            if let scene {
                let records = MacSnapshotData.historyRecords()
                _historyRecords = State(initialValue: records)
                if scene == .historyChat, let record = records.first {
                    _selection = State(initialValue: .historyRecord(record.id))
                } else {
                    _selection = State(initialValue: .tab(initialTab))
                }
            } else {
                _selection = State(initialValue: .tab(initialTab))
            }
            self.configStore = configStore
        }

        private var sidebarTabs: [RootTabView.TabItem] {
            RootTabView.TabItem.allCases.filter { item in
                switch item {
                // Actions and Models are reached from Home ("…" button) and
                // Settings respectively, mirroring the iPhone layout — not as
                // top-level sidebar tabs.
                case .history, .actions, .models: return false
                case .debug: return RootTabView.isDebugTabVisible
                default: return true
                }
            }
        }

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        var body: some View {
            let textHistoryRecords = historyRecords.filter { !$0.isRealtimeRecord && !$0.isConversation }
            let chatHistoryRecords = historyRecords.filter { !$0.isRealtimeRecord && $0.isConversation }
            let realtimeHistoryRecords = historyRecords.filter { $0.isRealtimeRecord }
            let historySectionOrder = sidebarHistorySectionOrder(
                textRecords: textHistoryRecords,
                chatRecords: chatHistoryRecords,
                realtimeRecords: realtimeHistoryRecords
            )

            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(selection: $selection) {
                    Section {
                        ForEach(sidebarTabs) { item in
                            Label(item.title, systemImage: item.systemImage)
                                .tag(SidebarSelection.tab(item))
                        }
                    }

                    ForEach(historySectionOrder) { kind in
                        switch kind {
                        case .text:
                            SidebarHistorySection(
                                title: "Text Translation", systemImage: "globe", records: textHistoryRecords,
                                visibleCount: visibleTextHistoryCount, tag: SidebarSelection.historyRecord
                            ) { visibleTextHistoryCount += sidebarHistoryPageSize }
                        case .chat:
                            SidebarHistorySection(
                                title: "Chat", systemImage: "bubble.left.and.bubble.right.fill",
                                records: chatHistoryRecords,
                                visibleCount: visibleChatHistoryCount, tag: SidebarSelection.historyRecord
                            ) { visibleChatHistoryCount += sidebarHistoryPageSize }
                        case .realtime:
                            SidebarHistorySection(
                                title: "Realtime Translation", systemImage: "waveform",
                                records: realtimeHistoryRecords,
                                visibleCount: visibleRealtimeHistoryCount, tag: SidebarSelection.historyRecord
                            ) { visibleRealtimeHistoryCount += sidebarHistoryPageSize }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(colors.background)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
                .navigationTitle("TLingo")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PremiumSidebarFooter()
                        .frame(height: 72)
                }
            } detail: {
                contentView(for: selection ?? .tab(.home))
            }
            .toolbarBackground(colors.background, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .onAppear {
                refreshHistory()
            }
            .onReceive(NotificationCenter.default.publisher(for: .translationRecordSaved)) { _ in
                historyRefreshTask?.cancel()
                historyRefreshTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    refreshHistory()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deepLinkRealtimeRequested)) { _ in
                showActions = false
                selection = .tab(.realtime)
            }
            .sheet(isPresented: $showFeaturePaywall) {
                PaywallView(context: .featureLocked)
            }
        }

        @ViewBuilder
        private func contentView(for selection: SidebarSelection) -> some View {
            switch selection {
            case let .tab(tab):
                tabContentView(for: tab)
            case let .historyRecord(id):
                if let record = historyRecords.first(where: { $0.id == id }) {
                    if record.isConversation {
                        ConversationContentView(
                            session: conversationSession(for: record),
                            onPremiumRequired: {
                                showFeaturePaywall = true
                            }
                        )
                        .id(record.id)
                    } else {
                        HistoryRecordDetailView(record: record)
                    }
                } else {
                    ContentUnavailableView("Record Not Found", systemImage: "clock.arrow.circlepath")
                }
            }
        }

        @ViewBuilder
        private func tabContentView(for tab: RootTabView.TabItem) -> some View {
            switch tab {
            case .home:
                homeTabContent
            case .history:
                let _ = assertionFailure("History tab should not appear in macOS sidebar")
                EmptyView()
            case .actions:
                ActionsView(configurationStore: configStore)
            case .models:
                ModelsView()
            case .realtime:
                RealtimeView(store: realtimeStore)
            case .settings:
                SettingsView(configStore: configStore)
            case .debug:
                NetworkDebugView()
            }
        }

        @ViewBuilder
        private var homeTabContent: some View {
            let content = HomeView(context: nil, onManageActionsTap: { showActions = true }, onPremiumRequired: {
                showFeaturePaywall = true
            })
            .sheet(isPresented: $showActions) {
                ActionsView(configurationStore: configStore, embedsInNavigationStack: true)
            }

            #if DIRECT_DISTRIBUTION
                content
                    .toolbar {
                        if let update = updater.availableUpdate {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    updater.checkForUpdates()
                                } label: {
                                    Text("Update to \(update.displayVersion)")
                                        .foregroundStyle(preferences.accentTheme.color)
                                }
                                .help("Update to \(update.fullVersionDescription)")
                                .accessibilityIdentifier("direct_update_available_button")
                            }
                        }
                    }
            #else
                content
            #endif
        }

        private func refreshHistory() {
            guard MacSnapshotScene.current() == nil else { return }
            let cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            historyRecords = TranslationHistoryService.shared.fetchSince(cutoff)
        }
    }

#else

    // MARK: - SidebarLayoutView (iOS)

    struct SidebarLayoutView: View {
        private enum Selection: Hashable {
            case tab(RootTabView.TabItem)
            case historyRecord(UUID)
        }

        @State private var selection: Selection?
        @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
        @State private var historyRecords: [TranslationRecord] = []
        @State private var historyRefreshTask: Task<Void, Never>?
        @State private var visibleTextHistoryCount = sidebarHistoryPageSize
        @State private var visibleChatHistoryCount = sidebarHistoryPageSize
        @State private var visibleRealtimeHistoryCount = sidebarHistoryPageSize
        @State private var showActions = false
        @StateObject private var realtimeStore = RealtimeSessionStore.shared
        @StateObject private var realtimeControlModel = RealtimeControlModel()
        @ObservedObject private var configStore: AppConfigurationStore
        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var storeManager = StoreManager.shared
        @State private var showFeaturePaywall = false

        init(initialTab: RootTabView.TabItem, configStore: AppConfigurationStore) {
            _selection = State(initialValue: .tab(initialTab))
            self.configStore = configStore
        }

        private var sidebarTabs: [RootTabView.TabItem] {
            RootTabView.TabItem.allCases.filter { item in
                switch item {
                case .history, .actions, .models:
                    return false
                case .debug:
                    return RootTabView.isDebugTabVisible
                default:
                    return true
                }
            }
        }

        private var sidebarRevealAction: (() -> Void)? {
            guard columnVisibility == .detailOnly else { return nil }
            return { showSidebar() }
        }

        var body: some View {
            let textHistoryRecords = historyRecords.filter { !$0.isRealtimeRecord && !$0.isConversation }
            let chatHistoryRecords = historyRecords.filter { !$0.isRealtimeRecord && $0.isConversation }
            let realtimeHistoryRecords = historyRecords.filter { $0.isRealtimeRecord }
            let historySectionOrder = sidebarHistorySectionOrder(
                textRecords: textHistoryRecords,
                chatRecords: chatHistoryRecords,
                realtimeRecords: realtimeHistoryRecords
            )

            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(selection: $selection) {
                    Section {
                        ForEach(sidebarTabs) { item in
                            Label(item.title, systemImage: item.systemImage)
                                .tag(Selection.tab(item))
                        }
                    }

                    ForEach(historySectionOrder) { kind in
                        switch kind {
                        case .text:
                            SidebarHistorySection(
                                title: "Text Translation", systemImage: "globe", records: textHistoryRecords,
                                visibleCount: visibleTextHistoryCount, tag: Selection.historyRecord
                            ) { visibleTextHistoryCount += sidebarHistoryPageSize }
                        case .chat:
                            SidebarHistorySection(
                                title: "Chat", systemImage: "bubble.left.and.bubble.right.fill",
                                records: chatHistoryRecords,
                                visibleCount: visibleChatHistoryCount, tag: Selection.historyRecord
                            ) { visibleChatHistoryCount += sidebarHistoryPageSize }
                        case .realtime:
                            SidebarHistorySection(
                                title: "Realtime Translation", systemImage: "waveform",
                                records: realtimeHistoryRecords,
                                visibleCount: visibleRealtimeHistoryCount, tag: Selection.historyRecord
                            ) { visibleRealtimeHistoryCount += sidebarHistoryPageSize }
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
                .navigationTitle("TLingo")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PremiumSidebarFooter()
                        .frame(height: 72)
                }
            } detail: {
                let currentSelection = selection ?? .tab(.home)
                contentView(for: currentSelection)
                    .toolbar {
                        if shouldShowNavigationBarSidebarButton(for: currentSelection) {
                            ToolbarItem(placement: .topBarLeading) {
                                sidebarRevealButton
                            }
                        }
                    }
            }
            .onAppear {
                refreshHistory()
            }
            .onReceive(NotificationCenter.default.publisher(for: .translationRecordSaved)) { _ in
                historyRefreshTask?.cancel()
                historyRefreshTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    refreshHistory()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deepLinkRealtimeRequested)) { _ in
                showActions = false
                selection = .tab(.realtime)
            }
            .sheet(isPresented: $showActions) {
                ActionsView(configurationStore: configStore, embedsInNavigationStack: true)
            }
            .firstRunOnboardingPresentation {
                showActions
            }
            .sheet(isPresented: $showFeaturePaywall) {
                PaywallView(context: .featureLocked)
            }
        }

        private var sidebarRevealButton: some View {
            Button(action: showSidebar) {
                Image(systemName: "sidebar.left")
            }
            .accessibilityLabel("Show Sidebar")
            .accessibilityIdentifier("ipad_show_sidebar_button")
        }

        @ViewBuilder
        private func contentView(for selection: Selection) -> some View {
            switch selection {
            case let .tab(tab):
                tabContentView(for: tab)
            case let .historyRecord(id):
                if let record = historyRecords.first(where: { $0.id == id }) {
                    if record.isConversation {
                        ConversationContentView(
                            session: conversationSession(for: record),
                            onPremiumRequired: {
                                showFeaturePaywall = true
                            }
                        )
                        .id(record.id)
                    } else {
                        HistoryRecordDetailView(record: record)
                    }
                } else {
                    ContentUnavailableView("Record Not Found", systemImage: "clock.arrow.circlepath")
                }
            }
        }

        @ViewBuilder
        private func tabContentView(for tab: RootTabView.TabItem) -> some View {
            switch tab {
            case .home:
                HomeView(
                    context: nil,
                    usesNativeNavigationHeader: true,
                    onManageActionsTap: {
                        showActions = true
                    },
                    onShowSidebarTap: sidebarRevealAction,
                    onPremiumRequired: {
                        showFeaturePaywall = true
                    }
                )
            case .history:
                HistoryView()
            case .actions:
                ActionsView(configurationStore: configStore)
            case .models:
                ModelsView()
            case .realtime:
                RealtimeView(
                    store: realtimeStore,
                    controlModel: realtimeControlModel,
                    onShowSidebarTap: sidebarRevealAction
                )
            case .settings:
                SettingsView(configStore: configStore, onShowSidebarTap: sidebarRevealAction)
            case .debug:
                NetworkDebugView()
            }
        }

        private func shouldShowNavigationBarSidebarButton(for selection: Selection) -> Bool {
            guard columnVisibility == .detailOnly else { return false }

            switch selection {
            case .historyRecord:
                return true
            case .tab(.debug):
                return true
            case .tab:
                return false
            }
        }

        private func showSidebar() {
            withAnimation {
                columnVisibility = .all
            }
        }

        private func refreshHistory() {
            let cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            historyRecords = TranslationHistoryService.shared.fetchSince(cutoff)
        }
    }

#endif

// MARK: - Premium Footer

private struct PremiumSidebarFooter: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var oauth = OAuthCoordinator.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showPaywall = false

    private var accentColor: Color {
        preferences.accentTheme.color
    }

    private var fadeGradient: LinearGradient {
        #if canImport(AppKit)
            let base = Color(NSColor.windowBackgroundColor)
        #else
            let base = Color(.systemBackground)
        #endif
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0),
                .init(color: base.opacity(0.85), location: 0.4),
                .init(color: base, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            fadeGradient
                .allowsHitTesting(false)

            if Entitlement.shared.isPro {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 13))
                        Text("Premium")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("Active")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(accentColor)
                    signedInEmailLine
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .tlingoGlassSurface(
                    cornerRadius: 14,
                    tint: accentColor.opacity(0.05),
                    fallbackTint: accentColor.opacity(0.04),
                    fallbackStroke: accentColor.opacity(0.14)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            } else {
                Button {
                    showPaywall = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 13))
                            Text("Upgrade to Premium")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(accentColor)
                        // Surface the signed-in email when not Pro so users can
                        // tell whether "Restore" is checking the right account.
                        signedInEmailLine
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tlingoGlassSurface(
                        cornerRadius: 14,
                        tint: accentColor.opacity(0.12),
                        interactive: true,
                        fallbackTint: accentColor.opacity(0.08),
                        fallbackStroke: accentColor.opacity(0.22)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .oauthCallbackNeedsActivation)) { _ in
            showPaywall = true
            oauth.acknowledgeActivationPrompt()
        }
        .onChange(of: oauth.needsActivationPrompt) { needs in
            if needs {
                showPaywall = true
                oauth.acknowledgeActivationPrompt()
            }
        }
        .onAppear {
            // Cold-launch catch-up: callback may have arrived before the
            // sidebar mounted, in which case the notification was lost but
            // the sticky flag still holds.
            if oauth.needsActivationPrompt {
                showPaywall = true
                oauth.acknowledgeActivationPrompt()
            }
        }
    }

    @ViewBuilder
    private var signedInEmailLine: some View {
        if let email = oauth.tokens?.email, !email.isEmpty {
            Text(email)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
