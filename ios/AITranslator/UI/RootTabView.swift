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
    /// iPhone exposes Text and Realtime in the tab bar; macOS and regular-width iPad use the sidebar.
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
                        NotificationCenter.default.post(name: .deepLinkRealtimeRequested, object: nil)
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

        private var usesSidebar: Bool {
            UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        }

        @ViewBuilder
        var body: some View {
            if usesSidebar {
                SidebarLayoutView(initialTab: initialTab, configStore: configStore)
            } else {
                TabBarNavigationView(initialTab: initialTab, configStore: configStore)
            }
        }
    }

    private struct TabBarNavigationView: View {
        @Environment(\.colorScheme) private var colorScheme
        @State private var selection: TabBarItem
        @State private var showHistory = false
        @State private var showRealtimeHistory = false
        @State private var showActions = false
        @State private var showModels: Bool
        @State private var showSettings: Bool
        @ObservedObject var configStore: AppConfigurationStore
        @ObservedObject private var preferences = AppPreferences.shared
        @StateObject private var realtimeStore = RealtimeSessionStore.shared
        @StateObject private var realtimeControlModel = RealtimeControlModel()
        @State private var showFeaturePaywall = false

        init(initialTab: RootTabView.TabItem, configStore: AppConfigurationStore) {
            let initialSelection = TabBarItem.initialSelection(for: initialTab)
            _selection = State(initialValue: initialSelection)
            _showModels = State(initialValue: initialTab == .models)
            _showSettings = State(initialValue: initialTab == .settings)
            self.configStore = configStore
        }

        private enum TabBarItem: Hashable {
            case text
            case realtime
            case contextualAction

            static func initialSelection(for tab: RootTabView.TabItem) -> TabBarItem {
                tab == .realtime ? .realtime : .text
            }
        }

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        private var usesFloatingRealtimeButton: Bool {
            UIDevice.current.userInterfaceIdiom == .pad
        }

        private var shouldShowContextualActionTab: Bool {
            !usesFloatingRealtimeButton
        }

        private var contextualActionTabRole: TabRole {
            if #available(iOS 27.0, *) {
                return .prominent
            }
            return .search
        }

        var body: some View {
            tabContent
                .overlay(alignment: .bottomTrailing) {
                    if usesFloatingRealtimeButton, selection == .realtime {
                        floatingRealtimeButton
                            .padding(.trailing, 24)
                            .padding(.bottom, 32)
                    }
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
                    showActions || showModels || showSettings
                }
                .sheet(isPresented: $showFeaturePaywall) {
                    PaywallView(context: .featureLocked)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
                .tint(colors.accent)
                .onReceive(NotificationCenter.default.publisher(for: .deepLinkRealtimeRequested)) { _ in
                    showActions = false
                    showHistory = false
                    showModels = false
                    showSettings = false
                    showRealtimeHistory = false
                    selection = .realtime
                }
        }

        private func startRealtimeFromFloatingButton() {
            selection = .realtime
            Task {
                await realtimeControlModel.handleStartButtonTapped(store: realtimeStore, preferences: preferences)
            }
        }

        private var floatingRealtimeButton: some View {
            Button {
                startRealtimeFromFloatingButton()
            } label: {
                Image(systemName: realtimeControlModel.startButtonSystemImage(for: realtimeStore))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .tlingoGlassCircle(
                        tint: floatingRealtimeButtonTint,
                        interactive: true,
                        fallbackTint: floatingRealtimeButtonTint,
                        fallbackStroke: colors.divider.opacity(0.65)
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.14), radius: 18, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(realtimeStore.isStopping)
            .accessibilityLabel(realtimeControlModel.startButtonTitle(for: realtimeStore))
            .accessibilityIdentifier("ipad_floating_realtime_button")
        }

        private var floatingRealtimeButtonTint: Color {
            if realtimeControlModel.isStartingRealtimeSession || realtimeStore.isStopping {
                return colors.textSecondary.opacity(0.30)
            }
            return realtimeStore.isRunning ? colors.error.opacity(0.32) : colors.accent.opacity(0.40)
        }

        @ViewBuilder
        private var tabContent: some View {
            if #available(iOS 26.0, *) {
                tabView
                    .tabBarMinimizeBehavior(.onScrollUp)
            } else {
                tabView
            }
        }

        private var tabView: some View {
            TabView(selection: Binding(
                get: { selection },
                set: { newSelection in
                    if newSelection == .contextualAction {
                        performContextualAction()
                    } else {
                        selection = newSelection
                    }
                }
            )) {
                Tab(value: TabBarItem.text) {
                    NavigationStack {
                        HomeView(context: nil, usesNativeNavigationHeader: true, onHistoryTap: {
                            showHistory = true
                        }, onManageActionsTap: {
                            showActions = true
                        }, onSettingsTap: {
                            showSettings = true
                        }, onPremiumRequired: {
                            showFeaturePaywall = true
                        })
                        .navigationDestination(isPresented: $showHistory) {
                            HistoryView()
                        }
                    }
                } label: {
                    Label(RootTabView.TabItem.home.title, systemImage: RootTabView.TabItem.home.systemImage)
                        .accessibilityIdentifier("tab_home")
                }

                Tab(value: TabBarItem.realtime) {
                    NavigationStack {
                        RealtimeView(
                            store: realtimeStore,
                            controlModel: realtimeControlModel,
                            onHistoryTap: {
                                showRealtimeHistory = true
                            }
                        )
                        .navigationDestination(isPresented: $showRealtimeHistory) {
                            HistoryView(initialFilter: .realtime)
                        }
                    }
                } label: {
                    Label(RootTabView.TabItem.realtime.title, systemImage: RootTabView.TabItem.realtime.systemImage)
                        .accessibilityIdentifier("tab_realtime")
                }

                if shouldShowContextualActionTab {
                    Tab(value: TabBarItem.contextualAction, role: contextualActionTabRole) {
                        EmptyView()
                    } label: {
                        Label(contextualActionTitle, systemImage: contextualActionSystemImage)
                            .accessibilityIdentifier(contextualActionAccessibilityIdentifier)
                    }
                }
            }
        }

        private var contextualActionTitle: LocalizedStringKey {
            switch selection {
            case .text, .contextualAction:
                return RootTabView.TabItem.models.title
            case .realtime:
                return realtimeControlModel.startButtonTitle(for: realtimeStore)
            }
        }

        private var contextualActionSystemImage: String {
            selection == .realtime
                ? realtimeControlModel.startButtonSystemImage(for: realtimeStore)
                : RootTabView.TabItem.models.systemImage
        }

        private var contextualActionAccessibilityIdentifier: String {
            selection == .realtime ? "tab_realtime_control" : "tab_models"
        }

        private func performContextualAction() {
            switch selection {
            case .text, .contextualAction:
                showModels = true
            case .realtime:
                Task {
                    await realtimeControlModel.handleStartButtonTapped(
                        store: realtimeStore,
                        preferences: preferences
                    )
                }
            }
        }
    }
#endif
