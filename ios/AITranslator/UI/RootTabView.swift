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
            case .actions:
                return "bolt.fill"
            case .models:
                return "cpu"
            case .realtime:
                return "waveform.and.mic"
            case .settings:
                return "gearshape.fill"
            case .debug:
                return "ladybug.fill"
            }
        }
    }

    /// Debug tab visibility — visible when developer mode is enabled
    /// (TestFlight override on App Store/TestFlight, or developer email
    /// signed in on Direct).
    static var isDebugTabVisible: Bool {
        DeveloperMode.isEnabled
    }

    var body: some View {
        #if os(macOS)
            SidebarLayoutView(initialTab: Self.initialTab, configStore: configStore)
                .modifier(DeepLinkHandler())
                .modifier(WebsiteEntitlementRefreshHandler())
                .modifier(AppStoreSubscriptionManagementPresenter())
                .directUpdateAvailabilityProbe()
        #else
            if ProcessInfo.processInfo.arguments.contains("-SNAPSHOT_EXTENSION_PREVIEW") {
                DefaultTranslationSnapshotView()
            } else {
                AdaptiveNavigationView(initialTab: Self.initialTab, configStore: configStore)
                    .modifier(DeepLinkHandler())
                    .modifier(WebsiteEntitlementRefreshHandler())
                    .modifier(AppStoreSubscriptionManagementPresenter())
            }
        #endif
    }
}

// MARK: - Website entitlement refresh

/// Keeps restored website entitlements reasonably fresh between launches.
/// Stripe webhook updates have no client push channel, so we poll on a leash.
private struct WebsiteEntitlementRefreshHandler: ViewModifier {
    /// Polling cadence. Six hours balances "users notice cancellation /
    /// renewal in a usable time" against API quota and battery.
    private static let staleAfter: TimeInterval = 6 * 3600

    func body(content: Content) -> some View {
        content
            .task {
                await OAuthCoordinator.shared.refreshIfStale(maxAge: 0, reason: "launch")
            }
            .task {
                let nanos = UInt64(Self.staleAfter * 1_000_000_000)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: nanos)
                    await OAuthCoordinator.shared.refreshIfStale(maxAge: Self.staleAfter, reason: "timer")
                }
            }
            .onReceive(Self.activeNotificationPublisher) { _ in
                Task { await OAuthCoordinator.shared.refreshIfStale(maxAge: Self.staleAfter, reason: "foreground") }
            }
    }

    private static let activeNotificationPublisher: NotificationCenter.Publisher = {
        #if os(macOS)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        #else
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        #endif
    }()
}

#if os(macOS)
    private extension View {
        @ViewBuilder
        func directUpdateAvailabilityProbe() -> some View {
            #if DIRECT_DISTRIBUTION
                modifier(DirectUpdateAvailabilityProbe())
            #else
                self
            #endif
        }
    }
#endif

#if os(macOS) && DIRECT_DISTRIBUTION
    private struct DirectUpdateAvailabilityProbe: ViewModifier {
        private static let staleAfter: TimeInterval = 6 * 3600

        @State private var lastProbeDate: Date?

        func body(content: Content) -> some View {
            content
                .task {
                    await probe(force: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await probe(force: false) }
                }
        }

        @MainActor
        private func probe(force: Bool) {
            let now = Date()
            if !force, let lastProbeDate, now.timeIntervalSince(lastProbeDate) < Self.staleAfter {
                return
            }

            lastProbeDate = now
            UpdaterController.shared.checkForUpdateInformationIfAllowed()
        }
    }
#endif

// MARK: - Deep Link Handling

extension RootTabView {
    struct DeepLinkHandler: ViewModifier {
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
                    // OAuth activation callback (Mac Direct only).
                    if OAuthCoordinator.shared.handleCallbackIfMatching(url) {
                        return
                    }
                    if DeepLink.isRealtimeURL(url) {
                        NotificationCenter.default.post(
                            name: .deepLinkRealtimeRequested,
                            object: nil,
                            userInfo: [DeepLink.NotificationKey.opensRecognitionModels: DeepLink.isRealtimeModelsURL(url)]
                        )
                        return
                    }
                    guard let parsed = DeepLink.parse(url) else { return }
                    var userInfo: [String: Any] = [DeepLink.NotificationKey.text: parsed.text]
                    if let actionName = parsed.actionName {
                        userInfo[DeepLink.NotificationKey.actionName] = actionName
                    }
                    if let configName = parsed.configName {
                        userInfo[DeepLink.NotificationKey.configName] = configName
                    }
                    NotificationCenter.default.post(
                        name: .deepLinkTextReceived,
                        object: nil,
                        userInfo: userInfo
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
                SettingsView(configStore: configStore)
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
