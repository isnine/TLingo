#if os(iOS)
    import AVFoundation
    import Combine
    import ReplayKit
    import ShareCore
    import Speech
    import SwiftUI
    import UIKit

    struct RealtimeView: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.openURL) private var openURL
        @Environment(\.scenePhase) private var scenePhase
        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var store: RealtimeSessionStore
        @ObservedObject private var controlModel: RealtimeControlModel
        private let onShowSidebarTap: (() -> Void)?
        private let onHistoryTap: (() -> Void)?
        /// Set when presented full screen from Home; adds Close and an in-page start/stop control.
        private let onDismiss: (() -> Void)?
        @State private var isSettingsPresented = false
        @State private var showsSwapUnsupportedAlert = false

        private enum RealtimeTargetSelection: Hashable {
            case transcriptionOnly
            case language(TargetLanguageOption)
        }

        init(
            store: RealtimeSessionStore,
            controlModel: RealtimeControlModel,
            onShowSidebarTap: (() -> Void)? = nil,
            onHistoryTap: (() -> Void)? = nil,
            onDismiss: (() -> Void)? = nil
        ) {
            _store = ObservedObject(wrappedValue: store)
            _controlModel = ObservedObject(wrappedValue: controlModel)
            self.onShowSidebarTap = onShowSidebarTap
            self.onHistoryTap = onHistoryTap
            self.onDismiss = onDismiss
        }

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        private var captionLines: [RealtimeCaptionLine] {
            store.captionLines
        }

        private var isIPhoneAudioInput: Bool {
            store.inputSource == .iphoneAudio
        }

        var body: some View {
            captionPane
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    languageBar
                }
                .background(colors.background.ignoresSafeArea())
                .overlay {
                    if controlModel.isStartingRealtimeSession || store.isStopping {
                        realtimeProgressOverlay
                    }
                }
                .overlay(alignment: .topLeading) {
                    BroadcastPickerLauncher(trigger: $controlModel.broadcastPickerTrigger)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .accessibilityHidden(true)
                }
                .navigationTitle("Realtime")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar { realtimeToolbar }
                .sheet(isPresented: $isSettingsPresented) {
                    settingsSheet
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    guard !isIPhoneAudioInput else { return }
                    Task { await store.stop() }
                }
                .alert(
                    store.startFailureAlert?.title ?? "Realtime Failed",
                    isPresented: startFailureAlertPresentedBinding
                ) {
                    Button("OK", role: .cancel) {
                        store.dismissStartFailureAlert()
                    }
                } message: {
                    Text(store.startFailureAlert?.message ?? "")
                }
                .alert(
                    controlModel.startBlockedAlert?.title ?? "Cannot Start Realtime",
                    isPresented: startBlockedAlertPresentedBinding
                ) {
                    if controlModel.startBlockedAlert?.opensAppSettings == true {
                        Button("Open Settings") {
                            openAppSettings()
                            controlModel.startBlockedAlert = nil
                        }
                    }
                    Button("OK", role: .cancel) {
                        controlModel.startBlockedAlert = nil
                    }
                } message: {
                    Text(controlModel.startBlockedAlert?.message ?? "")
                }
        }

        @ToolbarContentBuilder
        private var realtimeToolbar: some ToolbarContent {
            if let onDismiss {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "chevron.down", action: onDismiss)
                        .accessibilityIdentifier("realtime_close_button")
                }
            }
            if let onShowSidebarTap {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Show Sidebar", systemImage: "sidebar.left", action: onShowSidebarTap)
                        .accessibilityIdentifier("ipad_show_sidebar_button")
                }
            }
            if let onHistoryTap {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Realtime History", systemImage: "clock.arrow.circlepath", action: onHistoryTap)
                        .accessibilityIdentifier("realtime_history_button")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.isRunning {
                    Button(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill") {
                        store.togglePaused()
                    }
                    .disabled(!controlModel.isPauseEnabled(for: store))
                    .accessibilityIdentifier("realtime_pause_button")
                }

                Button("Realtime Options", systemImage: "slider.horizontal.3") {
                    isSettingsPresented = true
                }
                .accessibilityIdentifier("realtime_options_button")
            }
        }

        // MARK: - Full-Screen Session

        private var sessionControlButton: some View {
            Button {
                Task {
                    await controlModel.handleStartButtonTapped(store: store, preferences: preferences)
                }
            } label: {
                Image(systemName: controlModel.startButtonSystemImage(for: store))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .tlingoGlassCircle(
                        tint: sessionControlTint,
                        interactive: true,
                        fallbackTint: sessionControlTint,
                        fallbackStroke: colors.divider.opacity(0.65)
                    )
            }
            .buttonStyle(.plain)
            .disabled(controlModel.isStartingRealtimeSession || store.isStopping)
            .accessibilityLabel(controlModel.startButtonTitle(for: store))
            .accessibilityIdentifier("realtime_session_control_button")
        }

        private var sessionControlTint: Color {
            if controlModel.isStartingRealtimeSession || store.isStopping {
                return colors.textSecondary.opacity(0.45)
            }
            return store.isRunning ? colors.error : colors.accent
        }

        // MARK: - Language Bar

        /// Bottom-docked language pair, following Apple Translate's conversation layout:
        /// the languages sit next to the Start control in the tab bar, within thumb reach.
        private var languageBar: some View {
            VStack(spacing: 10) {
                if shouldShowSetupHint {
                    Label(languageSelectionStatusText, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }

                // Languages are locked while running, so the pair only takes caption space.
                if !store.isRunning {
                    languagePairControls
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if onDismiss != nil {
                    sessionControlButton
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: shouldShowSetupHint)
            .animation(.snappy, value: store.isRunning)
        }

        @ViewBuilder
        private var languagePairControls: some View {
            let content = HStack(spacing: 8) {
                sourceLanguageMenu
                swapLanguagesButton
                targetLanguageMenu
            }

            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    content
                }
            } else {
                content
            }
        }

        private var sourceLanguageMenu: some View {
            Menu {
                Picker("Source Language", selection: realtimeSourceLanguageBinding) {
                    ForEach(SourceLanguageOption.realtimeSelectionOptions) { option in
                        Text(option.primaryLabel)
                            .tag(option)
                            .disabled(unsupportedRealtimeSourceLanguageOptions.contains(option))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                languageMenuLabel(
                    sourceLanguageDisplayName,
                    isMissing: preferences.realtimeSourceLanguage == .auto
                )
            }
            .disabled(store.isRunning)
            .accessibilityLabel("Source Language")
            .accessibilityValue(sourceLanguageDisplayName)
            .accessibilityIdentifier("realtime_source_language_menu")
        }

        private var targetLanguageMenu: some View {
            Menu {
                Picker("Target Language", selection: realtimeTargetSelectionBinding) {
                    Label(
                        RealtimeTranslationProvider.transcriptionOnly.title,
                        systemImage: RealtimeTranslationProvider.transcriptionOnly.systemImage
                    )
                    .tag(RealtimeTargetSelection.transcriptionOnly)
                    .disabled(store.isRunning)

                    Section {
                        ForEach(TargetLanguageOption.realtimeSelectionOptions) { option in
                            Text(option.primaryLabel)
                                .tag(RealtimeTargetSelection.language(option))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                languageMenuLabel(
                    targetLanguageDisplayName,
                    isMissing: preferences.realtimeTranslationProvider.performsTranslation &&
                        preferences.realtimeTargetLanguage == .appLanguage
                )
            }
            .disabled(targetLanguageSelectionDisabled)
            .accessibilityLabel("Target Language")
            .accessibilityValue(targetLanguageDisplayName)
            .accessibilityIdentifier("realtime_target_language_menu")
        }

        private func languageMenuLabel(_ title: String, isMissing: Bool) -> some View {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(colors.textSecondary)
            }
            .foregroundStyle(isMissing ? Color.orange : colors.textPrimary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Capsule())
            .tlingoGlassCapsule(
                tint: colors.cardBackground.opacity(colorScheme == .dark ? 0.12 : 0.40),
                interactive: true,
                fallbackTint: colors.cardBackground.opacity(colorScheme == .dark ? 0.16 : 0.92),
                fallbackStroke: colors.divider
            )
        }

        private var swapLanguagesButton: some View {
            Button {
                swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(canSwapLanguages ? colors.accent : colors.textSecondary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                    .tlingoGlassCircle(
                        tint: colors.cardBackground.opacity(colorScheme == .dark ? 0.12 : 0.40),
                        interactive: true,
                        fallbackTint: colors.cardBackground.opacity(colorScheme == .dark ? 0.16 : 0.92),
                        fallbackStroke: colors.divider
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSwapLanguages && !isSwapBlockedByRecognitionModel)
            .accessibilityLabel("Swap languages")
            .accessibilityIdentifier("realtime_swap_languages_button")
            .alert("Can't Swap Languages", isPresented: $showsSwapUnsupportedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The selected recognition model doesn't support the new source language. Choose another model in Settings.")
            }
        }

        private var sourceLanguageDisplayName: String {
            preferences.realtimeSourceLanguage == .auto
                ? String(localized: "Source")
                : preferences.realtimeSourceLanguage.primaryLabel
        }

        private var targetLanguageDisplayName: String {
            guard preferences.realtimeTranslationProvider.performsTranslation else {
                return RealtimeTranslationProvider.transcriptionOnly.title
            }
            return preferences.realtimeTargetLanguage == .appLanguage
                ? String(localized: "Target")
                : preferences.realtimeTargetLanguage.primaryLabel
        }

        private var targetLanguageSelectionDisabled: Bool {
            store.isRunning && preferences.realtimeTranslationProvider == .transcriptionOnly
        }

        private var canSwapLanguages: Bool {
            guard !store.isRunning,
                  preferences.realtimeTranslationProvider.performsTranslation,
                  preferences.realtimeSourceLanguage != .auto,
                  preferences.realtimeTargetLanguage != .appLanguage
            else {
                return false
            }
            let swapped = LanguageDirectionSwap.swapped(
                source: preferences.realtimeSourceLanguage,
                target: preferences.realtimeTargetLanguage
            )
            return SourceLanguageOption.realtimeSelectionOptions.contains(swapped.source) &&
                TargetLanguageOption.realtimeSelectionOptions.contains(swapped.target) &&
                !unsupportedRealtimeSourceLanguageOptions.contains(swapped.source)
        }

        private var isSwapBlockedByRecognitionModel: Bool {
            guard !store.isRunning,
                  preferences.realtimeTranslationProvider.performsTranslation,
                  preferences.realtimeSourceLanguage != .auto,
                  preferences.realtimeTargetLanguage != .appLanguage,
                  let swappedSource = SourceLanguageOption(rawValue: preferences.realtimeTargetLanguage.rawValue)
            else {
                return false
            }
            return unsupportedRealtimeSourceLanguageOptions.contains(swappedSource)
        }

        private func swapLanguages() {
            if isSwapBlockedByRecognitionModel {
                showsSwapUnsupportedAlert = true
                return
            }
            guard canSwapLanguages else { return }
            let swapped = LanguageDirectionSwap.swapped(
                source: preferences.realtimeSourceLanguage,
                target: preferences.realtimeTargetLanguage
            )
            preferences.setRealtimeSourceLanguage(swapped.source)
            preferences.setRealtimeTargetLanguage(swapped.target)
            store.languageSelectionDidChange()
        }

        private func selectTranscriptionOnly() {
            preferences.setRealtimeTranslationProvider(.transcriptionOnly)
            store.languageSelectionDidChange()
        }

        private func selectTargetLanguage(_ option: TargetLanguageOption) {
            preferences.setRealtimeTargetLanguage(option)
            if preferences.realtimeTranslationProvider == .transcriptionOnly {
                preferences.setRealtimeTranslationProvider(.appleTranslator)
            }
            store.languageSelectionDidChange()
        }

        private var languageSelectionStatusText: String {
            controlModel.languageSelectionStatusText(preferences: preferences)
        }

        private var shouldShowSetupHint: Bool {
            !store.hasRequiredLanguageSelection
        }

        private var unsupportedRealtimeSourceLanguageOptions: Set<SourceLanguageOption> {
            let model = RecognitionModelStore.selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
            return Set(SourceLanguageOption.realtimeSelectionOptions.filter { !model.supports(sourceLanguage: $0) })
        }

        private var captionPane: some View {
            let lines = captionLines
            let lineIDs = lines.map(\.id)

            return ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(lines) { line in
                            captionLine(line)
                                .id(line.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("realtime-transcript-bottom")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .overlay {
                    if lines.isEmpty {
                        ContentUnavailableView(
                            RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: store.isRunning),
                            systemImage: store.isRunning ? "waveform" : "captions.bubble"
                        )
                        .symbolEffect(.variableColor.iterative, isActive: store.isRunning)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .onChange(of: lineIDs) {
                    guard !lineIDs.isEmpty else { return }
                    proxy.scrollTo("realtime-transcript-bottom", anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.background)
        }

        private func captionLine(_ line: RealtimeCaptionLine) -> some View {
            Text(line.text)
                .font(captionFont(for: line.kind))
                .foregroundStyle(captionForegroundStyle(for: line))
                .lineSpacing(line.kind == .source ? 3 : 6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
        }

        private func captionForegroundStyle(for line: RealtimeCaptionLine) -> Color {
            if line.isPending {
                return colors.accent
            }
            return line.kind == .source ? colors.textSecondary : colors.textPrimary
        }

        private func captionFont(for kind: RealtimeCaptionLine.Kind) -> Font {
            switch kind {
            case .source:
                return .system(size: 17, weight: .medium, design: .rounded)
            case .translation:
                return .system(size: 24, weight: .semibold, design: .rounded)
            }
        }

        private var realtimeProgressOverlay: some View {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    ProgressView()
                    Text(realtimeProgressTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .realtimeGlassSurface(
                    cornerRadius: 20,
                    tint: colors.cardBackground.opacity(colorScheme == .dark ? 0.18 : 0.22),
                    fallbackStroke: colors.divider
                )
            }
            .transition(.opacity)
        }

        private var realtimeProgressTitle: String {
            store.isStopping ? store.statusText : String(localized: "Starting realtime translation...")
        }

        private var settingsSheet: some View {
            NavigationStack {
                Form {
                    if RealtimeAudioInputSource.allCases.count > 1 {
                        Section("Input") {
                            Picker("Input", selection: inputSourceBinding) {
                                ForEach(RealtimeAudioInputSource.allCases) { source in
                                    Label(source.title, systemImage: source.systemImage)
                                        .tag(source)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(store.isRunning)
                        }
                    }

                    Section("Translation") {
                        Picker("Translator", selection: translationProviderBinding) {
                            ForEach(store.inputSource.supportedTranslationProviders) { provider in
                                Label(provider.title, systemImage: provider.systemImage)
                                    .tag(provider)
                            }
                        }
                        .disabled(store.isRunning)
                    }

                    Section("Recognition Model") {
                        RecognitionModelListView(
                            preferences: preferences,
                            models: store.inputSource.supportedRecognitionModels,
                            isDisabled: store.isRunning || store.isStopping
                        )
                    }

                    Section("Captions") {
                        Picker("Display", selection: captionDisplayModeBinding) {
                            ForEach(RealtimeCaptionDisplayMode.allCases) { mode in
                                Label(captionDisplayModeTitle(for: mode), systemImage: mode.systemImageName)
                                    .tag(mode)
                            }
                        }
                    }
                }
                .navigationTitle("Realtime Options")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isSettingsPresented = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        private var inputSourceBinding: Binding<RealtimeAudioInputSource> {
            Binding(
                get: { store.inputSource },
                set: { source in
                    store.inputSource = source
                    if source == .iphoneAudio {
                        controlModel.enforceIPhoneAudioLocalRoute(store: store, preferences: preferences)
                    }
                }
            )
        }

        private var translationProviderBinding: Binding<RealtimeTranslationProvider> {
            Binding(
                get: { preferences.realtimeTranslationProvider },
                set: { provider in
                    preferences.setRealtimeTranslationProvider(provider)
                    store.languageSelectionDidChange()
                }
            )
        }

        private var realtimeSourceLanguageBinding: Binding<SourceLanguageOption> {
            Binding(
                get: { preferences.realtimeSourceLanguage },
                set: { option in
                    preferences.setRealtimeSourceLanguage(option)
                    store.languageSelectionDidChange()
                }
            )
        }

        private var realtimeTargetSelectionBinding: Binding<RealtimeTargetSelection> {
            Binding(
                get: {
                    preferences.realtimeTranslationProvider.performsTranslation
                        ? .language(preferences.realtimeTargetLanguage)
                        : .transcriptionOnly
                },
                set: { selection in
                    switch selection {
                    case .transcriptionOnly:
                        selectTranscriptionOnly()
                    case let .language(option):
                        selectTargetLanguage(option)
                    }
                }
            )
        }

        private var captionDisplayModeBinding: Binding<RealtimeCaptionDisplayMode> {
            Binding(
                get: { store.captionDisplayMode },
                set: { store.captionDisplayMode = $0 }
            )
        }

        private var startFailureAlertPresentedBinding: Binding<Bool> {
            Binding(
                get: { store.startFailureAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        store.dismissStartFailureAlert()
                    }
                }
            )
        }

        private var startBlockedAlertPresentedBinding: Binding<Bool> {
            Binding(
                get: { controlModel.startBlockedAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        controlModel.startBlockedAlert = nil
                    }
                }
            )
        }

        private func captionDisplayModeTitle(for mode: RealtimeCaptionDisplayMode) -> String {
            switch mode {
            case .sourceOnly:
                return String(localized: "Source")
            case .translationOnly:
                return String(localized: "Translation")
            case .bilingual:
                return String(localized: "Bilingual")
            }
        }

        private func openAppSettings() {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        }
    }

    @MainActor
    final class RealtimeControlModel: ObservableObject {
        @Published var isStartingRealtimeSession = false
        @Published var broadcastPickerTrigger: UUID?
        @Published fileprivate var startBlockedAlert: StartBlockedAlert?

        func startButtonTitle(for store: RealtimeSessionStore) -> LocalizedStringKey {
            if store.isStopping {
                return "Stopping"
            }
            if isStartingRealtimeSession {
                return "Starting"
            }
            return store.isRunning ? "Stop" : "Start"
        }

        func startButtonSystemImage(for store: RealtimeSessionStore) -> String {
            if store.isStopping {
                return "hourglass"
            }
            if isStartingRealtimeSession {
                return "hourglass"
            }
            return store.isRunning ? "stop.fill" : "play.fill"
        }

        func canUseStartButton(store: RealtimeSessionStore, preferences: AppPreferences) -> Bool {
            !isStartingRealtimeSession && !store.isStopping &&
                (store.isRunning || canStartRealtimeSession(store: store, preferences: preferences))
        }

        func isPauseEnabled(for store: RealtimeSessionStore) -> Bool {
            store.isRunning && !store.isStopping && store.inputSource != .iphoneAudio
        }

        func canClearTranscript(for store: RealtimeSessionStore) -> Bool {
            !store.sourceText.isEmpty || !store.translatedText.isEmpty
        }

        func languageSelectionStatusText(preferences: AppPreferences) -> String {
            if preferences.realtimeTranslationProvider == .transcriptionOnly {
                return String(localized: "Select a source language before starting realtime translation.")
            }
            return String(localized: "Choose source and target languages to start.")
        }

        func handleStartButtonTapped(store: RealtimeSessionStore, preferences: AppPreferences) async {
            guard !store.isStopping else { return }
            if let alert = startBlockedAlertForCurrentState(store: store, preferences: preferences) {
                startBlockedAlert = alert
                return
            }

            if store.inputSource == .iphoneAudio, !store.isRunning {
                await startIPhoneAudioSession(store: store, preferences: preferences)
                return
            }

            await toggleRealtimeSession(store: store)
        }

        private func canStartRealtimeSession(store: RealtimeSessionStore, preferences: AppPreferences) -> Bool {
            guard store.hasRequiredLanguageSelection else { return false }
            guard store.inputSource != .iphoneAudio else { return true }
            return RecognitionModelStore.isSelectable(
                RecognitionModelStore.selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
            )
        }

        private func startBlockedAlertForCurrentState(
            store: RealtimeSessionStore,
            preferences: AppPreferences
        ) -> StartBlockedAlert? {
            guard !store.isRunning else { return nil }
            if isStartingRealtimeSession {
                return StartBlockedAlert(
                    title: String(localized: "Realtime Is Starting"),
                    message: String(localized: "Wait for the current startup attempt to finish before trying again.")
                )
            }

            if !store.hasRequiredLanguageSelection {
                return missingLanguageSelectionAlert(preferences: preferences)
            }

            if let alert = deniedPermissionAlert(store: store, preferences: preferences) {
                return alert
            }

            return nil
        }

        private func deniedPermissionAlert(
            store: RealtimeSessionStore,
            preferences: AppPreferences
        ) -> StartBlockedAlert? {
            if store.inputSource == .iphoneAudio {
                switch SFSpeechRecognizer.authorizationStatus() {
                case .denied, .restricted:
                    return StartBlockedAlert(
                        title: String(localized: "Speech Recognition Permission Required"),
                        message: String(localized: "Enable Speech Recognition access in Settings before starting iPhone Audio."),
                        opensAppSettings: true
                    )
                case .authorized, .notDetermined:
                    return nil
                @unknown default:
                    return StartBlockedAlert(
                        title: String(localized: "Speech Recognition Permission Required"),
                        message: String(
                            localized: "TLingo could not confirm Speech Recognition access. Check Settings before starting."
                        ),
                        opensAppSettings: true
                    )
                }
            }

            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted:
                return StartBlockedAlert(
                    title: String(localized: "Microphone Permission Required"),
                    message: String(localized: "Enable Microphone access in Settings before starting realtime captions."),
                    opensAppSettings: true
                )
            case .authorized, .notDetermined:
                break
            @unknown default:
                return StartBlockedAlert(
                    title: String(localized: "Microphone Permission Required"),
                    message: String(
                        localized: "TLingo could not confirm Microphone access. Check Settings before starting realtime captions."
                    ),
                    opensAppSettings: true
                )
            }

            guard preferences.realtimeRecognitionEngine.requiresSpeechRecognitionPermission
            else {
                return nil
            }

            switch SFSpeechRecognizer.authorizationStatus() {
            case .denied, .restricted:
                return StartBlockedAlert(
                    title: String(localized: "Speech Recognition Permission Required"),
                    message: String(
                        localized: "Enable Speech Recognition access in Settings before starting Apple Speech realtime captions."
                    ),
                    opensAppSettings: true
                )
            case .authorized, .notDetermined:
                return nil
            @unknown default:
                return StartBlockedAlert(
                    title: String(localized: "Speech Recognition Permission Required"),
                    message: String(
                        localized: "TLingo could not confirm Speech Recognition access. Check Settings before starting."
                    ),
                    opensAppSettings: true
                )
            }
        }

        private func missingLanguageSelectionAlert(preferences: AppPreferences) -> StartBlockedAlert {
            let needsSourceLanguage = preferences.realtimeSourceLanguage == .auto
            let needsTargetLanguage = preferences.realtimeTranslationProvider.performsTranslation &&
                preferences.realtimeTargetLanguage == .appLanguage

            switch (needsSourceLanguage, needsTargetLanguage) {
            case (true, true):
                return StartBlockedAlert(
                    title: String(localized: "Choose Languages"),
                    message: String(localized: "Select both source and target languages before starting realtime translation.")
                )
            case (true, false):
                return StartBlockedAlert(
                    title: String(localized: "Choose Source Language"),
                    message: String(localized: "Select a source language before starting realtime translation.")
                )
            case (false, true):
                return StartBlockedAlert(
                    title: String(localized: "Choose Target Language"),
                    message: String(localized: "Select a target language before starting realtime translation.")
                )
            case (false, false):
                return StartBlockedAlert(
                    title: String(localized: "Choose Languages"),
                    message: languageSelectionStatusText(preferences: preferences)
                )
            }
        }

        private func toggleRealtimeSession(store: RealtimeSessionStore) async {
            guard !store.isStopping else { return }
            if store.isRunning {
                await store.toggleRunning()
                return
            }
            guard !isStartingRealtimeSession else { return }

            isStartingRealtimeSession = true
            defer {
                isStartingRealtimeSession = false
            }

            await store.start()
        }

        private func startIPhoneAudioSession(store: RealtimeSessionStore, preferences: AppPreferences) async {
            guard !isStartingRealtimeSession, !store.isStopping else { return }

            isStartingRealtimeSession = true
            defer {
                isStartingRealtimeSession = false
            }

            enforceIPhoneAudioLocalRoute(store: store, preferences: preferences)
            if let failure = await RealtimeIPhoneAudioPreflight.evaluateAfterRequestingSpeechAuthorization(
                sourceLanguage: preferences.realtimeSourceLanguage,
                targetLanguage: preferences.realtimeTargetLanguage
            ) {
                startBlockedAlert = StartBlockedAlert(
                    title: String(localized: "iPhone Audio Not Ready"),
                    message: failure
                        .errorDescription ?? String(localized: "iPhone Audio cannot start with the current settings."),
                    opensAppSettings: failure == .speechNotAuthorized
                )
                return
            }

            await store.start()
            guard store.startFailureAlert == nil else { return }
            broadcastPickerTrigger = UUID()
        }

        func enforceIPhoneAudioLocalRoute(store: RealtimeSessionStore, preferences: AppPreferences) {
            if preferences.realtimeRecognitionEngine != .appleSpeech {
                preferences.setRealtimeRecognitionEngine(.appleSpeech)
            }
            preferences.setRealtimeRecognitionModelID(RecognitionModelDescriptor.appleSpeech.id)
            if preferences.realtimeTranslationProvider != .appleTranslator {
                preferences.setRealtimeTranslationProvider(.appleTranslator)
                store.languageSelectionDidChange()
            }
        }
    }

    fileprivate struct StartBlockedAlert {
        let title: String
        let message: String
        var opensAppSettings = false
    }

    private struct BroadcastPickerLauncher: UIViewRepresentable {
        @Binding var trigger: UUID?

        func makeUIView(context _: Context) -> RPSystemBroadcastPickerView {
            let view = RPSystemBroadcastPickerView(frame: .zero)
            view.preferredExtension = RealtimeSessionStore.broadcastUploadExtensionBundleIdentifier
            view.showsMicrophoneButton = false
            return view
        }

        func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {
            guard let trigger, context.coordinator.lastTrigger != trigger else { return }
            context.coordinator.lastTrigger = trigger

            DispatchQueue.main.async {
                let button = view.subviews.compactMap { $0 as? UIButton }.first
                button?.sendActions(for: .touchUpInside)
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        final class Coordinator {
            var lastTrigger: UUID?
        }
    }

    private extension View {
        @ViewBuilder
        func realtimeGlassSurface(
            cornerRadius: CGFloat,
            tint: Color,
            interactive: Bool = false,
            fallbackStroke: Color
        ) -> some View {
            if #available(iOS 26.0, *) {
                if interactive {
                    glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
                } else {
                    glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
                }
            } else {
                background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(fallbackStroke, lineWidth: 1)
                    )
            }
        }
    }
#endif
