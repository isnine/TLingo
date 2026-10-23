//
//  RootTabView.swift
//  TLingo
//
//  Created by Codex on 2025/10/19.
//

import ShareCore
import SwiftUI
#if os(macOS)
    import AppKit
    import os
#elseif os(iOS)
    import UIKit
#endif

#if os(macOS)
    private let deepLinkLogger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "DeepLink")
#endif

struct RootTabView: View {
    @ObservedObject private var configStore: AppConfigurationStore
    @State private var homeInputRouteID = UUID()

    init(configStore: AppConfigurationStore = .shared) {
        self.configStore = configStore
    }

    /// Reads `-SNAPSHOT_TAB <name>` from launch arguments to select a tab at startup.
    static var initialTab: TabItem {
        #if os(macOS)
            if let scene = MacSnapshotScene.current() {
                return scene.initialTab
            }
        #endif
        if let tabName = SnapshotLaunchArguments.value(after: "-SNAPSHOT_TAB") {
            return TabItem(rawValue: tabName.lowercased()) ?? .home
        }
        return .home
    }

    static var forceOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-TLingoForceOnboarding")
    }

    /// TabItem enum defining the app's top-level destinations.
    /// Compact-width iOS shows Home only (realtime is a full-screen session); macOS and regular-width iPad use the sidebar.
    enum TabItem: String, CaseIterable, Identifiable {
        case home
        case history
        case vocabulary
        case actions
        case models
        case realtime
        case settings
        case debug

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .home:
                return "Text"
            case .history:
                return "History"
            case .vocabulary:
                return "Vocabulary"
            case .actions:
                return "Actions"
            case .models:
                return "Models"
            case .realtime:
                return "Realtime"
            case .settings:
                return "Settings"
            case .debug:
                return "Debug"
            }
        }

        var systemImage: String {
            switch self {
            case .home:
                return "text.alignleft"
            case .history:
                return "clock.arrow.circlepath"
            case .vocabulary:
                return "bookmark"
            case .actions:
                return "bolt.fill"
            case .models:
                return "cpu"
            case .realtime:
                return "waveform"
            case .settings:
                return "gearshape"
            case .debug:
                return "ladybug"
            }
        }
    }

    /// Debug tab visibility — visible when developer mode is enabled
    /// (Debug builds or the TestFlight override).
    static var isDebugTabVisible: Bool {
        DeveloperMode.isEnabled
    }

    var body: some View {
        #if os(macOS)
            SidebarLayoutView(initialTab: Self.initialTab, configStore: configStore)
                .modifier(DeepLinkHandler())
                .environment(\.homeInputRouteID, homeInputRouteID)
                .modifier(AppStoreSubscriptionManagementPresenter())
        #else
            if ProcessInfo.processInfo.arguments.contains("-SNAPSHOT_EXTENSION_PREVIEW") {
                DefaultTranslationSnapshotView()
            } else {
                AdaptiveNavigationView(initialTab: Self.initialTab, configStore: configStore)
                    .modifier(DeepLinkHandler())
                    .environment(\.homeInputRouteID, homeInputRouteID)
                    .modifier(AppStoreSubscriptionManagementPresenter())
            }
        #endif
    }
}

// MARK: - Deep Link Handling

extension RootTabView {
    struct DeepLinkHandler: ViewModifier {
        @Environment(\.homeInputRouteID) private var homeInputRouteID

        func body(content: Content) -> some View {
            content
                .onOpenURL { url in
                    #if os(macOS)
                        let winCount = NSApp.windows.count
                        let visibleCount = NSApp.windows.filter(\.isVisible).count
                        let safeURL = url.redactedLogDescription
                        deepLinkLogger
                            .info(
                                """
                                SwiftUI onOpenURL url=\(safeURL, privacy: .public) \
                                windows=\(winCount, privacy: .public) visible=\(visibleCount, privacy: .public)
                                """
                            )
                    #endif
                    if DeepLink.isRealtimeURL(url) {
                        NotificationCenter.default.post(
                            name: .deepLinkRealtimeRequested,
                            object: nil,
                            userInfo: [DeepLink.NotificationKey.opensRecognitionModels: DeepLink.isRealtimeModelsURL(url)]
                        )
                        return
                    }
                    guard let parsed = DeepLink.parse(url) else { return }
                    HomeInputRouter.shared.submit(
                        .deepLink(text: parsed.text, actionName: parsed.actionName, configName: parsed.configName),
                        routeID: homeInputRouteID
                    )
                }
        }
    }
}

// MARK: - iOS Adaptive Navigation

#if !os(macOS)
    private struct AdaptiveNavigationView: View {
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        let initialTab: RootTabView.TabItem
        @ObservedObject var configStore: AppConfigurationStore
        // Owned here so crossing the regular/compact boundary keeps Home and realtime state.
        @StateObject private var homeViewModel = HomeViewModel()
        @StateObject private var realtimeControlModel = RealtimeControlModel()

        private var usesSidebar: Bool {
            UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        }

        @ViewBuilder
        var body: some View {
            if usesSidebar {
                SidebarLayoutView(
                    initialTab: initialTab,
                    configStore: configStore,
                    homeViewModel: homeViewModel,
                    realtimeControlModel: realtimeControlModel
                )
            } else {
                CompactNavigationView(
                    initialTab: initialTab,
                    configStore: configStore,
                    homeViewModel: homeViewModel,
                    realtimeControlModel: realtimeControlModel
                )
            }
        }
    }

    /// Compact-width iOS layout: Home is the single root screen; realtime opens as a
    /// full-screen session from the Home input bar and ends when dismissed.
    private struct CompactNavigationView: View {
        @Environment(\.colorScheme) private var colorScheme
        @State private var showHistory = false
        @State private var showRealtime: Bool
        @State private var showActions = false
        @State private var showModels: Bool
        @State private var showSettings: Bool
        @ObservedObject var configStore: AppConfigurationStore
        @ObservedObject private var preferences = AppPreferences.shared
        // Not observed: high-frequency caption updates must not invalidate the root view.
        private let realtimeStore = RealtimeSessionStore.shared
        private let homeViewModel: HomeViewModel
        @ObservedObject private var realtimeControlModel: RealtimeControlModel
        @State private var showFeaturePaywall = false

        init(
            initialTab: RootTabView.TabItem,
            configStore: AppConfigurationStore,
            homeViewModel: HomeViewModel,
            realtimeControlModel: RealtimeControlModel
        ) {
            _showRealtime = State(initialValue: initialTab == .realtime)
            _showModels = State(initialValue: initialTab == .models)
            _showSettings = State(initialValue: initialTab == .settings)
            self.configStore = configStore
            self.homeViewModel = homeViewModel
            self.realtimeControlModel = realtimeControlModel
        }

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        var body: some View {
            NavigationStack {
                HomeView(context: nil, usesNativeNavigationHeader: true, onHistoryTap: {
                    showHistory = true
                }, onManageActionsTap: {
                    showActions = true
                }, onSettingsTap: {
                    showSettings = true
                }, onRealtimeTap: {
                    showRealtime = true
                }, onPremiumRequired: {
                    showFeaturePaywall = true
                }, viewModel: homeViewModel)
                .navigationDestination(isPresented: $showHistory) {
                    HistoryView()
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                NavigationLink {
                                    VocabularyView()
                                } label: {
                                    Label("Vocabulary", systemImage: "bookmark")
                                }
                                .tint(.primary)
                                .accessibilityIdentifier("history_vocabulary_button")
                            }
                        }
                }
            }
            .realtimeSavedNotice(store: realtimeStore) { _ in
                showRealtime = false
                showHistory = true
            }
            .fullScreenCover(isPresented: $showRealtime, onDismiss: stopRealtimeAfterDismiss) {
                NavigationStack {
                    RealtimeView(
                        store: realtimeStore,
                        controlModel: realtimeControlModel,
                        onDismiss: {
                            showRealtime = false
                        }
                    )
                    .realtimeSavedNotice(store: realtimeStore) { _ in
                        showRealtime = false
                        showHistory = true
                    }
                }
                .tint(colors.accent)
            }
            .sheet(isPresented: $showActions) {
                ActionsView(configurationStore: configStore, embedsInNavigationStack: true)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(configStore: configStore, showsDoneButton: true)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showModels) {
                NavigationStack {
                    ModelsView(embedsInNavigationStack: false)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showModels = false
                                }
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .firstRunOnboardingPresentation {
                showActions || showModels || showSettings || showRealtime
            }
            .sheet(isPresented: $showFeaturePaywall) {
                PaywallView(context: .featureLocked)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .tint(colors.accent)
            .onReceive(NotificationCenter.default.publisher(for: .deepLinkRealtimeRequested)) { notification in
                showActions = false
                showHistory = false
                showModels = false
                showSettings = false
                showRealtime = true
                realtimeControlModel.handleRealtimeDeepLink(notification)
            }
            .homeInputDestination {
                showActions = false
                showHistory = false
                showModels = false
                showSettings = false
                showRealtime = false
                showFeaturePaywall = false
            }
        }

        /// Closing the realtime screen ends the session; `stop()` saves it to History.
        private func stopRealtimeAfterDismiss() {
            guard realtimeStore.isRunning else { return }
            Task {
                await realtimeStore.stop()
            }
        }
    }
#endif
