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
    // Child screens push value-based links, so these rows must use value-based routes too;
    // mixing them with view-destination links reorders the navigation stack.
    private enum Route: Hashable {
        case models
        case actions
    }

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
    @State private var feedbackDraft: FeedbackMailDraft?

    @State private var showNetworkDebug = false
    @State private var showLocalLog = false

    #if os(macOS)
        @ObservedObject private var hotKeyManager = HotKeyManager.shared
        @State private var recordingHotKeyType: HotKeyType?
        @State private var localEventMonitor: Any?
        @State private var showOnboarding = false
        #if DIRECT_DISTRIBUTION
            @State private var showAccessibilityOnboarding = false
            @StateObject private var accessibilityPermissionManager = AccessibilityPermissionManager()
        #endif
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
            Form {
                accountSection
                translationSection
                #if os(macOS)
                    macControlsSection
                    realtimeCaptionsSection
                #endif
                appearanceSection
                if DeveloperMode.isEnabled {
                    developerSection
                }
                helpSection
            }
            .formStyle(.grouped)
            #if os(macOS)
                // The macOS grouped form defaults to 13pt rows and 10pt subtitles, which read too small here.
                .font(.system(size: 15))
                .controlSize(.large)
            #endif
            .navigationTitle("Settings")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .models:
                    ModelsView(embedsInNavigationStack: false)
                case .actions:
                    ActionsView(configurationStore: configStore, embedsInNavigationStack: false)
                }
            }
            #if os(iOS)
                .toolbar {
                    if let onShowSidebarTap {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: onShowSidebarTap) {
                                Image(systemName: "sidebar.left")
                            }
                            .accessibilityLabel("Show Sidebar")
                            .accessibilityIdentifier("ipad_show_sidebar_button")
                        }
                    }
                }
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
        #if os(macOS) && DIRECT_DISTRIBUTION
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

    // MARK: - Sections

    private var accountSection: some View {
        Section("Account") {
            subscriptionRow
        }
    }

    private var translationSection: some View {
        Section("Translation") {
            NavigationLink(value: Route.models) {
                settingsLabel("Models", systemImage: "cpu", subtitle: Text("Choose translation models"))
            }
            .accessibilityIdentifier("settings_models_row")

            NavigationLink(value: Route.actions) {
                settingsLabel("Manage Actions", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("settings_actions_row")

            actionRow(value: voiceDisplayName) {
                isVoicePickerPresented = true
            } label: {
                settingsLabel("Voice", systemImage: "waveform")
            }

            #if os(iOS)
                actionRow {
                    showDefaultTranslationOnboarding = true
                } label: {
                    settingsLabel(
                        "Default Translation App",
                        systemImage: "translate",
                        subtitle: Text("Set TLingo as the system translator")
                    )
                }
            #endif
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            accentThemeRow
        }
    }

    private var developerSection: some View {
        Section("Developer") {
            actionRow {
                showLocalLog = true
            } label: {
                settingsLabel("Local Log", systemImage: "doc.text")
            }
            .accessibilityIdentifier("settings_local_log")

            actionRow {
                showNetworkDebug = true
            } label: {
                settingsLabel("Network Log", systemImage: "network", subtitle: Text("View all HTTP request history"))
            }
        }
    }

    private var helpSection: some View {
        Section {
            actionRow {
                composeFeedbackEmail()
            } label: {
                settingsLabel(
                    "Feedback",
                    systemImage: "envelope",
                    subtitle: Text("我们会回复你的每一封邮件 · iamzanderwang@outlook.com")
                )
            }

            #if os(macOS)
                actionRow {
                    showOnboarding = true
                } label: {
                    settingsLabel(
                        "Replay Onboarding",
                        systemImage: "sparkles",
                        subtitle: Text("Walk through the setup guide again")
                    )
                }
            #endif
        } header: {
            Text("Help")
        } footer: {
            versionLabel
        }
    }

    private var versionLabel: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        let label = Text("TLingo v\(version) (\(build))")
            .font(Self.subtitleFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .contentShape(Rectangle())
        // Premium is never granted by client-side toggles outside Debug builds;
        // the Worker verifies App Store transactions. TestFlight only toggles
        // developer tools.
        #if DIRECT_DISTRIBUTION
            return label
        #else
            return label.onTapGesture(count: 2) {
                #if DEBUG
                    let enabled = storeManager.toggleDebugPremium()
                    testFlightAlertMessage = enabled
                        ? "Premium activated (Debug)"
                        : "Premium deactivated (Debug)"
                #else
                    guard StoreManager.isTestFlight else { return }
                    let enabled = DeveloperMode.toggleTestFlightDeveloperMode()
                    testFlightAlertMessage = enabled
                        ? "Developer mode on (TestFlight)"
                        : "Developer mode off (TestFlight)"
                #endif
                showTestFlightAlert = true
            }
        #endif
    }

    // MARK: - Row Builders

    private func settingsLabel(
        _ title: LocalizedStringKey,
        systemImage: String,
        subtitle: Text? = nil
    ) -> some View {
        settingsLabel(Text(title), systemImage: systemImage, subtitle: subtitle)
    }

    private func settingsLabel(
        _ title: Text,
        systemImage: String,
        subtitle: Text? = nil
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .foregroundStyle(colors.textPrimary)
                if let subtitle {
                    subtitle
                        .font(Self.subtitleFont)
                        .foregroundStyle(colors.textSecondary)
                }
            }
            #if os(macOS)
            .padding(.vertical, 3)
            #endif
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(colors.accent)
            #if os(macOS)
                .font(.system(size: 17))
                .frame(width: 24)
            #endif
        }
    }

    #if os(macOS)
        private static let subtitleFont = Font.system(size: 13)
    #else
        private static let subtitleFont = Font.footnote
    #endif

    /// A tappable row that opens a sheet or performs an action, styled like a navigation row.
    private func actionRow(
        value: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            HStack {
                label()
                Spacer()
                if let value {
                    Text(value)
                        .foregroundStyle(colors.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension SettingsView {
    // MARK: - Rows

    private var voiceDisplayName: String {
        let voiceID = preferences.selectedVoiceID
        // Try to find voice name from defaults, otherwise capitalize the ID
        if let voice = VoiceConfig.defaultVoices.first(where: { $0.id == voiceID }) {
            return voice.name
        }
        return voiceID.capitalized
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
        LabeledContent {
            if entitlement.isPro {
                Button(subscriptionActionTitle, action: handleSubscriptionTap)
                    .buttonStyle(.bordered)
            } else {
                Button("Upgrade", action: handleSubscriptionTap)
                    .buttonStyle(.borderedProminent)
            }
        } label: {
            settingsLabel(
                "Subscription",
                systemImage: "crown",
                subtitle: Text(entitlement.state.settingsSubtitle)
            )
        }
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

    var accentThemeRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent {
                if !entitlement.isPro {
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            } label: {
                settingsLabel(
                    "Theme Color",
                    systemImage: "paintpalette",
                    subtitle: Text(
                        entitlement.isPro ? preferences.accentTheme.displayName : String(localized: "Premium Feature")
                    )
                )
            }

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
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(colors.onAccent)
                            }
                        }
                        .opacity(entitlement.isPro || theme == .default ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.displayName)
                }
            }
        }
        .padding(.vertical, 4)
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
        private func handleDefaultTranslationOnboardingDismiss() {
            preferences.setHasSeenDefaultTranslationOnboarding(true)

            guard pendingDefaultTranslationUpgrade else { return }
            pendingDefaultTranslationUpgrade = false
            showPaywall = true
        }
    #endif

    #if os(macOS)
        var macControlsSection: some View {
            Section("Mac Controls") {
                ForEach(HotKeyType.availableCases.filter { $0 != .screenshotOCR }, id: \.self) { type in
                    hotKeyRow(for: type)
                }
                #if DIRECT_DISTRIBUTION
                    textSelectionTranslationRow
                #endif
            }
        }

        func hotKeyRow(for type: HotKeyType) -> some View {
            let config = hotKeyManager.configuration(for: type)
            let isRecording = recordingHotKeyType == type

            return LabeledContent {
                HStack(spacing: 6) {
                    Button {
                        startRecordingHotKey(for: type)
                    } label: {
                        Text(isRecording ? String(localized: "Press keys...") : config.displayString)
                            .font(config.isEmpty ? .callout : .callout.monospaced())
                            .foregroundStyle(
                                isRecording ? colors.accent : (config.isEmpty ? colors.textSecondary : colors.textPrimary)
                            )
                    }
                    .buttonStyle(.bordered)

                    if !config.isEmpty {
                        Button {
                            hotKeyManager.clearConfiguration(for: type)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    settingsLabel(
                        Text(type.displayName),
                        systemImage: type.iconName,
                        subtitle: Text(type.description)
                    )
                    if hotKeyManager.unavailableHotKeys.contains(type) {
                        Text("This shortcut is used by another app.")
                            .font(Self.subtitleFont)
                            .foregroundStyle(colors.error)
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

        var realtimeCaptionsSection: some View {
            Section {
                Picker(selection: Binding(
                    get: { preferences.realtimeCaptionWindowMode },
                    set: { mode in
                        preferences.setRealtimeCaptionWindowMode(mode)
                        refreshRealtimeCaptionWindowIfVisible()
                    }
                )) {
                    ForEach(RealtimeCaptionWindowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    settingsLabel(
                        "Realtime Captions",
                        systemImage: "captions.bubble",
                        subtitle: Text(preferences.realtimeCaptionWindowMode.settingsDescription)
                    )
                }

                Toggle(isOn: Binding(
                    get: { preferences.realtimeCaptionPrivacyModeEnabled },
                    set: { enabled in
                        preferences.setRealtimeCaptionPrivacyModeEnabled(enabled)
                        refreshRealtimeCaptionWindowIfVisible()
                    }
                )) {
                    settingsLabel("Hide captions from screen sharing", systemImage: "eye.slash")
                }
            }
        }

        private func refreshRealtimeCaptionWindowIfVisible() {
            guard RealtimeFloatingCaptionWindowController.isOpen else { return }
            RealtimeFloatingCaptionWindowController.open(store: RealtimeSessionStore.shared)
        }

        #if DIRECT_DISTRIBUTION
            var textSelectionTranslationRow: some View {
                Toggle(isOn: Binding(
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
                )) {
                    settingsLabel(
                        "Text Selection Translation",
                        systemImage: "text.cursor",
                        subtitle: Text(textSelectionTranslationSubtitle)
                    )
                }
            }

            private var textSelectionTranslationSubtitle: LocalizedStringKey {
                if preferences.textSelectionTranslationEnabled {
                    return "Ready in other apps"
                }
                return accessibilityPermissionManager
                    .isAccessibilityGranted ? "Select text in any app to translate" : "Requires Accessibility Permission"
            }
        #endif
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
