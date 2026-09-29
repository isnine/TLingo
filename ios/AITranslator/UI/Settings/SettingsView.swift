//
//  SettingsView.swift
//  TLingo
//
//  Created by Codex on 2025/10/27.
//

import os
import ShareCore
import SwiftUI

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ConfigEditor")
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
    import Carbon
#endif

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var configStore: AppConfigurationStore
    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var entitlement = Entitlement.shared
    private let onShowSidebarTap: (() -> Void)?
    @State private var isVoicePickerPresented = false
    @State private var showPaywall = false

    @State private var showTestFlightAlert = false
    @State private var testFlightAlertMessage = ""
    @State private var showDefaultTranslationOnboarding = false
    @State private var pendingDefaultTranslationUpgrade = false
    @State private var showModels = false
    @State private var showActions = false
    @State private var feedbackDraft: FeedbackMailDraft?

    @State private var showNetworkDebug = false
    @State private var showLocalLog = false

    #if os(macOS)
        @ObservedObject private var hotKeyManager = HotKeyManager.shared
        @State private var recordingHotKeyType: HotKeyType?
        @State private var localEventMonitor: Any?
        @State private var showOnboarding = false
        @State private var showAccessibilityOnboarding = false
        @StateObject private var accessibilityPermissionManager = AccessibilityPermissionManager()
    #endif

    private var colors: AppColorPalette {
        AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
    }

    init(
        preferences: AppPreferences = .shared,
        configStore: AppConfigurationStore = .shared,
        onShowSidebarTap: (() -> Void)? = nil
    ) {
        _preferences = ObservedObject(wrappedValue: preferences)
        _configStore = ObservedObject(wrappedValue: configStore)
        self.onShowSidebarTap = onShowSidebarTap
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    preferencesSection
                    versionLabel
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationDestination(isPresented: $showModels) {
                ModelsView(embedsInNavigationStack: false)
            }
            .navigationDestination(isPresented: $showActions) {
                ActionsView(configurationStore: configStore, embedsInNavigationStack: false)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .tint(colors.accent)
        .sheet(isPresented: $isVoicePickerPresented) {
            VoicePickerView(
                isPresented: $isVoicePickerPresented
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(context: .settingsUpgrade)
        }
        #if os(iOS)
        .sheet(item: $feedbackDraft) { draft in
            FeedbackMailComposerView(draft: draft) {
                feedbackDraft = nil
            }
        }
        #endif
        #if os(iOS)
        .fullScreenCover(
            isPresented: $showDefaultTranslationOnboarding,
            onDismiss: handleDefaultTranslationOnboardingDismiss
        ) {
            DefaultTranslationOnboardingView { outcome in
                pendingDefaultTranslationUpgrade = outcome == .upgrade
                showDefaultTranslationOnboarding = false
            }
        }
        #endif
        .sheet(isPresented: $showLocalLog) {
            NavigationStack {
                LocalLogView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLocalLog = false }
                        }
                    }
            }
            .presentationDetents([.large])
            #if os(macOS)
                .frame(minWidth: 600, minHeight: 500)
            #endif
        }
        .sheet(isPresented: $showNetworkDebug) {
            NavigationStack {
                NetworkDebugView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showNetworkDebug = false }
                        }
                    }
            }
            .presentationDetents([.large])
            #if os(macOS)
                .frame(minWidth: 600, minHeight: 500)
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $showAccessibilityOnboarding) {
            AccessibilityOnboardingView(
                permissionManager: accessibilityPermissionManager,
                onPermissionGranted: {
                    preferences.setTextSelectionTranslationEnabled(true)
                }
            )
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
        #endif
        .onAppear {
            preferences.refreshFromDefaults()
        }
        .alert("TestFlight", isPresented: $showTestFlightAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(testFlightAlertMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            #if os(iOS)
                if let onShowSidebarTap {
                    Button(action: onShowSidebarTap) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 20))
                            .foregroundColor(colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show Sidebar")
                    .accessibilityIdentifier("ipad_show_sidebar_button")
                    .padding(.top, 6)
                }
            #endif

            VStack(alignment: .leading, spacing: 8) {
                Text("Settings")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(colors.textPrimary)

                Text("App Preferences")
                    .font(.system(size: 16))
                    .foregroundColor(colors.textSecondary)
            }
        }
    }

    private var generalSectionContent: some View {
        VStack(spacing: 0) {
            subscriptionRow
            Divider()
                .padding(.leading, 52)
            modelManagementRow
            Divider()
                .padding(.leading, 52)
            actionManagementRow
            Divider()
                .padding(.leading, 52)
            accentThemeRow
            #if os(iOS)
                Divider()
                    .padding(.leading, 52)
                defaultTranslationAppRow
            #endif
            Divider()
                .padding(.leading, 52)
            voicePreferenceRow
            #if os(macOS)
                Divider()
                    .padding(.leading, 52)
                hotKeyPreferenceRow
                Divider()
                    .padding(.leading, 52)
                realtimeCaptionPreferencesRow
                Divider()
                    .padding(.leading, 52)
                replayOnboardingRow
                Divider()
                    .padding(.leading, 52)
                textSelectionTranslationRow
            #endif
        }
    }

    private var preferencesSection: some View {
        VStack(spacing: 32) {
            #if os(macOS)
                settingsSection(title: "Account", icon: "person.crop.circle") {
                    subscriptionRow
                }

                settingsSection(title: "Translation", icon: "translate") {
                    modelManagementRow
                    Divider()
                        .padding(.leading, 52)
                    actionManagementRow
                    Divider()
                        .padding(.leading, 52)
                    voicePreferenceRow
                }

                settingsSection(title: "Appearance", icon: "paintpalette") {
                    accentThemeRow
                }

                settingsSection(title: "Mac Controls", icon: "keyboard") {
                    hotKeyPreferenceRow
                    Divider()
                        .padding(.leading, 52)
                    textSelectionTranslationRow
                }

                settingsSection(title: "Realtime Captions", icon: "captions.bubble") {
                    realtimeCaptionPreferencesRow
                }

                settingsSection(title: "Help", icon: "questionmark.circle") {
                    feedbackRow
                    Divider()
                        .padding(.leading, 52)
                    replayOnboardingRow
                }
            #else

                // MARK: - Feedback Section

                settingsSection(title: "Feedback", icon: "envelope") {
                    feedbackRow
                }

                // MARK: - General Section

                settingsSection(title: "General", icon: "gearshape") {
                    generalSectionContent
                }
            #endif

            if DeveloperMode.isEnabled {
                // MARK: - Developer Section

                settingsSection(title: "Developer", icon: "ladybug") {
                    Button {
                        showLocalLog = true
                    } label: {
                        HStack(spacing: 16) {
                            SettingsIconBadge(icon: "doc.text", color: .orange)
                            Text("Local Log")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(colors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(colors.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings_local_log")

                    Button {
                        showNetworkDebug = true
                    } label: {
                        HStack(spacing: 16) {
                            SettingsIconBadge(icon: "network", color: .red)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Network Log")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(colors.textPrimary)
                                Text("View all HTTP request history")
                                    .font(.system(size: 13))
                                    .foregroundColor(colors.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(colors.textSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var versionLabel: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        let label = Text("TLingo v\(version) (\(build))")
            .font(.system(size: 12))
            .foregroundColor(colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .contentShape(Rectangle())
        // Direct distribution intentionally has no premium backdoor — entitlement
        // there is owned by the web subscription, not by client-side toggles.
        #if DIRECT_DISTRIBUTION
            return label
        #else
            return label.onTapGesture(count: 2) {
                if StoreManager.isTestFlight {
                    let enabled = storeManager.toggleTestFlightPremium()
                    testFlightAlertMessage = enabled
                        ? "Premium activated (TestFlight)"
                        : "Premium deactivated (TestFlight)"
                } else {
                    #if DEBUG
                        let enabled = storeManager.toggleTestFlightPremium()
                        testFlightAlertMessage = enabled
                            ? "Premium activated (Debug)"
                            : "Premium deactivated (Debug)"
                    #else
                        testFlightAlertMessage = "TestFlight override is only available in TestFlight builds."
                    #endif
                }
                showTestFlightAlert = true
            }
        #endif
    }

    // MARK: - Section Builder

    private func settingsSection<Content: View>(
        title: LocalizedStringKey,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .padding(.horizontal, 4)

            // Section Content
            content()
                .background(sectionCardBackground)
        }
    }

    @ViewBuilder
    private var sectionCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(colors.cardBackground)
    }
}

private extension SettingsView {
    // MARK: - Row Style Components

    var voicePreferenceRow: some View {
        Button {
            isVoicePickerPresented = true
        } label: {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "waveform", color: .purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text(voiceDisplayName)
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var voiceDisplayName: String {
        let voiceID = preferences.selectedVoiceID
        // Try to find voice name from defaults, otherwise capitalize the ID
        if let voice = VoiceConfig.defaultVoices.first(where: { $0.id == voiceID }) {
            return voice.name
        }
        return voiceID.capitalized
    }

    var subscriptionSubtitle: String {
        entitlement.state.settingsSubtitle
    }

    private var hasManageableAppStoreSubscription: Bool {
        guard entitlement.state.hasAppStoreEntitlement,
              let activeProductID = storeManager.activePremiumProductID
        else { return false }
        return SubscriptionProduct.allIdentifiers.contains(activeProductID)
    }

    private var subscriptionActionTitle: String {
        if hasManageableAppStoreSubscription || entitlement.state.hasWebsiteEntitlement {
            return String(localized: "Manage")
        }
        if entitlement.isPro {
            return String(localized: "Active")
        }
        return String(localized: "Upgrade")
    }

    var subscriptionRow: some View {
        Button {
            handleSubscriptionTap()
        } label: {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "crown.fill", color: .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Subscription")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text(subscriptionSubtitle)
                        .font(.system(size: 13))
                        .foregroundColor(entitlement.isPro ? .orange : colors.textSecondary)
                }

                Spacer()

                if entitlement.isPro {
                    Text(subscriptionActionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.15))
                        )
                } else {
                    Text("Upgrade")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.orange)
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleSubscriptionTap() {
        #if os(iOS)
            if hasManageableAppStoreSubscription {
                AppStoreSubscriptionManagementRouter.shared.present()
                return
            }
        #endif
        showPaywall = true
    }

    var modelManagementRow: some View {
        Button {
            showModels = true
        } label: {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "cpu", color: .blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Models")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text("Choose translation models")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings_models_row")
    }

    var actionManagementRow: some View {
        Button {
            showActions = true
        } label: {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "slider.horizontal.3", color: .orange)

                Text("Manage Actions")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(colors.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings_actions_row")
    }

    var accentThemeRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "paintpalette.fill", color: preferences.accentTheme.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Theme Color")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text(entitlement.isPro ? preferences.accentTheme.displayName : String(localized: "Premium Feature"))
                        .font(.system(size: 13))
                        .foregroundColor(entitlement.isPro ? colors.textSecondary : colors.accent)
                }

                Spacer()

                if !entitlement.isPro {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(colors.textSecondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Color swatches
            HStack(spacing: 10) {
                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        if entitlement.isPro {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                preferences.setAccentTheme(theme)
                            }
                        } else {
                            showPaywall = true
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 28, height: 28)

                            if preferences.accentTheme == theme {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 2.5)
                                    .frame(width: 28, height: 28)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .opacity(entitlement.isPro || theme == .default ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    var feedbackRow: some View {
        Button {
            composeFeedbackEmail()
        } label: {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "envelope", color: .cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Feedback")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text("我们会回复你的每一封邮件 · iamzanderwang@outlook.com")
                        .font(.system(size: 12))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func composeFeedbackEmail() {
        let draft = FeedbackMail.makeDraft(isPremium: entitlement.isPro)
        #if os(iOS)
            feedbackDraft = draft
        #elseif os(macOS)
            FeedbackMail.openMacComposer(draft)
        #else
            FeedbackMail.openFallback(draft)
        #endif
    }

    #if os(iOS)
        var defaultTranslationAppRow: some View {
            Button {
                showDefaultTranslationOnboarding = true
            } label: {
                HStack(spacing: 16) {
                    SettingsIconBadge(icon: "translate", color: .blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default Translation App")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                        Text("Set TLingo as the system translator")
                            .font(.system(size: 12))
                            .foregroundColor(colors.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(colors.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private func handleDefaultTranslationOnboardingDismiss() {
            preferences.setHasSeenDefaultTranslationOnboarding(true)

            guard pendingDefaultTranslationUpgrade else { return }
            pendingDefaultTranslationUpgrade = false
            showPaywall = true
        }
    #endif

    #if os(macOS)
        var hotKeyPreferenceRow: some View {
            let visibleHotKeyTypes = HotKeyType.allCases.filter { $0 != .screenshotOCR }

            return VStack(spacing: 0) {
                ForEach(visibleHotKeyTypes, id: \.self) { type in
                    let config = hotKeyManager.configuration(for: type)
                    let isRecording = recordingHotKeyType == type

                    HStack(spacing: 16) {
                        SettingsIconBadge(
                            icon: type.iconName,
                            color: type == .mainApp ? .purple : (type == .quickTranslate ? .orange : .blue)
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(colors.textPrimary)
                            Text(type.description)
                                .font(.system(size: 12))
                                .foregroundColor(colors.textSecondary)
                            if hotKeyManager.unavailableHotKeys.contains(type) {
                                Text("This shortcut is used by another app.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                        }

                        Spacer()

                        Button {
                            startRecordingHotKey(for: type)
                        } label: {
                            Text(isRecording ? String(localized: "Press keys...") : config.displayString)
                                .font(.system(size: 13, weight: .medium, design: config.isEmpty ? .default : .monospaced))
                                .foregroundColor(
                                    isRecording ? colors
                                        .accent : (config.isEmpty ? colors.textSecondary : colors.textPrimary)
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .tlingoGlassCapsule(
                                    tint: isRecording ? colors.accent.opacity(0.18) : colors.cardBackground.opacity(0.12),
                                    interactive: true,
                                    fallbackTint: isRecording
                                        ? colors.accent.opacity(0.12)
                                        : colors.inputBackground.opacity(0.86),
                                    fallbackStroke: isRecording ? colors.accent.opacity(0.45) : colors.divider
                                )
                        }
                        .buttonStyle(.plain)

                        if !config.isEmpty {
                            Button {
                                hotKeyManager.clearConfiguration(for: type)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16))
                                    .foregroundColor(colors.textSecondary.opacity(0.5))
                                    .frame(width: 28, height: 28)
                                    .tlingoGlassCircle(
                                        tint: colors.cardBackground.opacity(0.10),
                                        interactive: true,
                                        fallbackTint: colors.inputBackground.opacity(0.82),
                                        fallbackStroke: colors.divider
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if type != visibleHotKeyTypes.last {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
        }

        private func startRecordingHotKey(for type: HotKeyType) {
            recordingHotKeyType = type

            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [self] event in
                if event.type == .keyDown {
                    let modifiers = event.modifierFlags.carbonModifiers
                    let keyCode = UInt32(event.keyCode)

                    // Escape to cancel
                    if keyCode == 53 {
                        stopRecordingHotKey()
                        return nil
                    }

                    // Need at least one modifier (except for function keys)
                    let isFunctionKey = (keyCode >= 122 && keyCode <= 135) || (keyCode >= 96 && keyCode <= 111)
                    if modifiers == 0, !isFunctionKey {
                        return nil
                    }

                    let config = HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
                    if hotKeyManager.conflictingType(for: config, excluding: type) != nil {
                        NSSound.beep()
                        return nil
                    }
                    hotKeyManager.updateConfiguration(config, for: type)
                    stopRecordingHotKey()
                    return nil
                }
                return event
            }
        }

        private func stopRecordingHotKey() {
            recordingHotKeyType = nil
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
                localEventMonitor = nil
            }
        }

        var realtimeCaptionPreferencesRow: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    SettingsIconBadge(icon: "captions.bubble", color: .blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Realtime Captions")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                        Text(preferences.realtimeCaptionWindowMode.settingsDescription)
                            .font(.system(size: 12))
                            .foregroundColor(colors.textSecondary)
                    }

                    Spacer()

                    Picker("", selection: Binding(
                        get: { preferences.realtimeCaptionWindowMode },
                        set: { mode in
                            preferences.setRealtimeCaptionWindowMode(mode)
                            refreshRealtimeCaptionWindowIfVisible()
                        }
                    )) {
                        ForEach(RealtimeCaptionWindowMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Toggle(isOn: Binding(
                    get: { preferences.realtimeCaptionPrivacyModeEnabled },
                    set: { enabled in
                        preferences.setRealtimeCaptionPrivacyModeEnabled(enabled)
                        refreshRealtimeCaptionWindowIfVisible()
                    }
                )) {
                    Text("Hide captions from screen sharing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                }
                .toggleStyle(.switch)
                .padding(.leading, 52)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }

        private func refreshRealtimeCaptionWindowIfVisible() {
            guard RealtimeFloatingCaptionWindowController.isOpen else { return }
            RealtimeFloatingCaptionWindowController.open(store: RealtimeSessionStore.shared)
        }

        var replayOnboardingRow: some View {
            Button {
                showOnboarding = true
            } label: {
                HStack(spacing: 16) {
                    SettingsIconBadge(icon: "sparkles", color: .blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replay Onboarding")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                        Text("Walk through the setup guide again")
                            .font(.system(size: 12))
                            .foregroundColor(colors.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(colors.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }

        var textSelectionTranslationRow: some View {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "text.cursor", color: .green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Text Selection Translation")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text(textSelectionTranslationSubtitle)
                        .font(.system(size: 12))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { preferences.textSelectionTranslationEnabled },
                    set: { newValue in
                        if newValue {
                            if AXIsProcessTrusted() {
                                preferences.setTextSelectionTranslationEnabled(true)
                            } else {
                                showAccessibilityOnboarding = true
                            }
                        } else {
                            preferences.setTextSelectionTranslationEnabled(false)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }

        private var textSelectionTranslationSubtitle: LocalizedStringKey {
            if preferences.textSelectionTranslationEnabled {
                return "Ready in other apps"
            }
            return accessibilityPermissionManager
                .isAccessibilityGranted ? "Select text in any app to translate" : "Requires Accessibility Permission"
        }

    #endif
}

#Preview {
    SettingsView(configStore: .makeSnapshotStore())
        .preferredColorScheme(.dark)
}

// MARK: - Configuration Editor View

struct ConfigurationEditorView: View {
    let configInfo: ConfigurationFileInfo
    let initialText: String
    let colors: AppColorPalette
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    @State private var editableText: String
    @State private var hasChanges = false
    @State private var showDiscardAlert = false
    @State private var showResetConfirmation = false
    @State private var showValidationError = false
    @State private var validationErrorMessage = ""
    @Environment(\.dismiss) private var dismiss

    init(
        configInfo: ConfigurationFileInfo,
        initialText: String,
        colors: AppColorPalette,
        onSave: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.configInfo = configInfo
        self.initialText = initialText
        self.colors = colors
        self.onSave = onSave
        self.onDismiss = onDismiss
        _editableText = State(initialValue: initialText)
    }

    var body: some View {
        #if os(macOS)
            macOSEditor
        #else
            iOSEditor
        #endif
    }

    #if os(macOS)
        private var macOSEditor: some View {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(configInfo.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(colors.textPrimary)
                        Text("Edit JSON configuration")
                            .font(.system(size: 13))
                            .foregroundColor(colors.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        Button {
                            showResetConfirmation = true
                        } label: {
                            Label("Reset to Default", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(colors.textSecondary)

                        Button("Cancel") {
                            handleCancel()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(colors.inputBackground)
                        )

                        Button("Save") {
                            validateAndSave()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(colors.accent)
                        )
                        .disabled(!hasChanges)
                        .opacity(hasChanges ? 1 : 0.5)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(colors.cardBackground)

                Divider()

                // Editor
                TextEditor(text: $editableText)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(colors.background)
                    .padding(12)
            }
            .frame(minWidth: 600, minHeight: 500)
            .background(colors.background)
            .onChange(of: editableText) {
                hasChanges = editableText != initialText
            }
            .alert("Discard Changes?", isPresented: $showDiscardAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    onDismiss()
                }
            } message: {
                Text("You have unsaved changes. Are you sure you want to discard them?")
            }
            .alert("Reset to Default?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetToDefaultText()
                }
            } message: {
                Text("This will replace the editor content with the built-in default configuration. Save to apply.")
            }
            .alert("Validation Failed", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationErrorMessage)
            }
        }
    #endif

    #if os(iOS)
        private var iOSEditor: some View {
            NavigationStack {
                TextEditor(text: $editableText)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(colors.background)
                    .padding(.horizontal, 12)
                    .navigationTitle(configInfo.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                handleCancel()
                            }
                        }
                        ToolbarItem(placement: .principal) {
                            Menu {
                                Button(role: .destructive) {
                                    showResetConfirmation = true
                                } label: {
                                    Label("Reset to Default", systemImage: "arrow.counterclockwise")
                                }
                            } label: {
                                Text(configInfo.name)
                                    .font(.headline)
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                validateAndSave()
                            }
                            .disabled(!hasChanges)
                        }
                    }
                    .background(colors.background.ignoresSafeArea())
            }
            .onChange(of: editableText) {
                hasChanges = editableText != initialText
            }
            .alert("Discard Changes?", isPresented: $showDiscardAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    onDismiss()
                }
            } message: {
                Text("You have unsaved changes. Are you sure you want to discard them?")
            }
            .alert("Reset to Default?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetToDefaultText()
                }
            } message: {
                Text("This will replace the editor content with the built-in default configuration. Save to apply.")
            }
            .alert("Validation Failed", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationErrorMessage)
            }
        }
    #endif

    private func handleCancel() {
        if hasChanges {
            showDiscardAlert = true
        } else {
            onDismiss()
        }
    }

    private func resetToDefaultText() {
        guard let url = ConfigurationFileManager.bundledDefaultConfigURL(),
              let data = try? Data(contentsOf: url)
        else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Re-encode to get consistent pretty-printed output
        if let config = try? JSONDecoder().decode(AppConfiguration.self, from: data),
           let formatted = try? encoder.encode(config),
           let text = String(data: formatted, encoding: .utf8)
        {
            editableText = text
            return
        }
        // Fall back to raw file content
        if let text = String(data: data, encoding: .utf8) {
            editableText = text
        }
    }

    private func validateAndSave() {
        // Validate JSON format
        guard let data = editableText.data(using: .utf8) else {
            validationErrorMessage = "Invalid text encoding"
            showValidationError = true
            return
        }

        do {
            // Try to parse JSON
            let config = try JSONDecoder().decode(AppConfiguration.self, from: data)

            // Validate configuration using ConfigurationValidator
            let validationResult = ConfigurationValidator.shared.validate(config)

            if validationResult.hasErrors {
                validationErrorMessage = validationResult.errors.map(\.message).joined(separator: "\n")
                showValidationError = true
                return
            }

            // Show warnings but still allow save
            if validationResult.hasWarnings {
                logger.warning("⚠️ Saving with warnings:")
                for warning in validationResult.warnings {
                    logger.warning("  - \(warning.message, privacy: .public)")
                }
            }

            // Call onSave only if validation passed
            onSave(editableText)
        } catch let decodingError as DecodingError {
            // Provide more helpful error messages for JSON errors
            switch decodingError {
            case let .dataCorrupted(context):
                validationErrorMessage = "JSON format error: \(context.debugDescription)"
            case let .keyNotFound(key, context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                validationErrorMessage = "Missing required field '\(key.stringValue)' at \(path)"
            case let .typeMismatch(type, context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                validationErrorMessage = "Type mismatch for \(type) at \(path): \(context.debugDescription)"
            case let .valueNotFound(type, context):
                validationErrorMessage =
                    "Missing value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            @unknown default:
                validationErrorMessage = "JSON parsing error: \(decodingError.localizedDescription)"
            }
            showValidationError = true
        } catch {
            validationErrorMessage = "Invalid configuration: \(error.localizedDescription)"
            showValidationError = true
        }
    }
}

// MARK: - Config Editor Item

struct ConfigEditorItem: Identifiable {
    let id = UUID()
    let configInfo: ConfigurationFileInfo
    let text: String
}

// MARK: - NSEvent Modifier Flags Extension

#if os(macOS)
    import Carbon

    extension NSEvent.ModifierFlags {
        var carbonModifiers: UInt32 {
            var modifiers: UInt32 = 0
            if contains(.control) { modifiers |= UInt32(controlKey) }
            if contains(.option) { modifiers |= UInt32(optionKey) }
            if contains(.shift) { modifiers |= UInt32(shiftKey) }
            if contains(.command) { modifiers |= UInt32(cmdKey) }
            return modifiers
        }
    }
#endif

// MARK: - Settings Icon Badge

private struct SettingsIconBadge: View {
    let icon: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(color)
        }
    }
}
