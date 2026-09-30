#if os(iOS)
    import AVFoundation
    import Combine
    import ReplayKit
    import ShareCore
    import Speech
    import SwiftUI
    import Translation
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
        /// Set when presented full screen from Home; adds a Close button.
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
                .translationTask(store.appleTranslationDownloadConfiguration) { session in
                    await store.prepareAppleTranslationLanguageDownload(using: session)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    controlDock
                }
                .background(colors.background.ignoresSafeArea())
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
                .task(id: recognitionModelPrewarmKey) {
                    guard scenePhase == .active else { return }
                    await store.prewarmRecognitionModel()
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
                    if store.startFailureAlert?.offersAppleTranslationDownload == true {
                        Button("Download") {
                            store.dismissStartFailureAlert()
                            store.allowAppleTranslationDownloadOnNextStart()
                            Task { await controlModel.handleStartButtonTapped(store: store, preferences: preferences) }
                        }
                    }
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
                Button("Realtime Options", systemImage: "slider.horizontal.3") {
                    isSettingsPresented = true
                }
                .accessibilityIdentifier("realtime_options_button")
            }
        }

        // MARK: - Control Dock

        private static let dockHeight: CGFloat = 56

        private var isSessionActive: Bool {
            store.isRunning || controlModel.isStartingRealtimeSession || store.isStopping
        }

        private var isSessionTransitioning: Bool {
            controlModel.isStartingRealtimeSession || store.isStopping
        }

        /// Bottom dock within thumb reach: one capsule on the left, the session control on the right.
        /// The capsule answers "what will be translated" while idle, then turns into a live readout of
        /// "what is happening" once a session starts, so the eye never has to leave this spot.
        private var controlDock: some View {
            VStack(spacing: 0) {
                if shouldShowSetupHint, !isSessionActive {
                    Label(languageSelectionStatusText, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }

                if store.isRunning {
                    RealtimeFaintSpeechHint(level: store.inputLevel, isActive: !store.isPaused, color: .orange)
                }

                dockRow
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: shouldShowSetupHint)
            .animation(.smooth(duration: 0.35), value: isSessionActive)
            .animation(.snappy, value: store.isPaused)
            .sensoryFeedback(trigger: store.isRunning) { _, isRunning in
                isRunning ? .start : .stop
            }
        }

        @ViewBuilder
        private var dockRow: some View {
            let content = HStack(spacing: 10) {
                Group {
                    if isSessionActive {
                        liveStatusCapsule
                    } else {
                        languageCapsule
                    }
                }
                .transition(.blurReplace)

                sessionControlButton
            }

            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    content
                }
            } else {
                content
            }
        }

        private var dockCapsuleTint: Color {
            colors.cardBackground.opacity(colorScheme == .dark ? 0.12 : 0.40)
        }

        private var dockCapsuleFallbackTint: Color {
            colors.cardBackground.opacity(colorScheme == .dark ? 0.16 : 0.92)
        }

        /// Source and target share one capsule so the pair reads as a single direction, not two settings.
        private var languageCapsule: some View {
            HStack(spacing: 0) {
                sourceLanguageMenu
                swapLanguagesButton
                targetLanguageMenu
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: Self.dockHeight)
            .tlingoGlassCapsule(
                tint: dockCapsuleTint,
                fallbackTint: dockCapsuleFallbackTint,
                fallbackStroke: colors.divider
            )
        }

        /// Languages are locked while running, so the capsule shows level, status, and pause instead.
        private var liveStatusCapsule: some View {
            HStack(spacing: 12) {
                RealtimeInputLevelIndicator(
                    level: store.inputLevel,
                    isActive: store.isRunning && !store.isPaused,
                    tint: store.isPaused ? colors.textSecondary : colors.accent,
                    barWidth: 3,
                    maxHeight: 22
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(store.statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                        .contentTransition(.opacity)
                    if let modelLoad = store.recognitionModelLoad {
                        RealtimeModelLoadProgressView(
                            progress: modelLoad,
                            tint: colors.accent,
                            secondaryColor: colors.textSecondary
                        )
                    } else {
                        Text(languageDirectionSummary)
                            .font(.caption)
                            .foregroundStyle(colors.textSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                if store.isRunning, store.inputSource != .iphoneAudio {
                    pauseButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity)
            .frame(height: Self.dockHeight)
            .tlingoGlassCapsule(
                tint: dockCapsuleTint,
                fallbackTint: dockCapsuleFallbackTint,
                fallbackStroke: colors.divider
            )
        }

        private var recognitionModelPrewarmKey: String {
            "\(preferences.realtimeRecognitionModelID)|\(store.inputSource.rawValue)|\(scenePhase == .active)"
        }

        private var languageDirectionSummary: String {
            guard preferences.realtimeTranslationProvider.performsTranslation else {
                return sourceLanguageDisplayName
            }
            return "\(sourceLanguageDisplayName) → \(targetLanguageDisplayName)"
        }

        private var pauseButton: some View {
            Button {
                store.togglePaused()
            } label: {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .background(colors.textPrimary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!controlModel.isPauseEnabled(for: store))
            .accessibilityLabel(store.isPaused ? "Resume" : "Pause")
            .accessibilityIdentifier("realtime_pause_button")
            .sensoryFeedback(.selection, trigger: store.isPaused)
        }

        /// Start and stop stay in the same spot; a spinner replaces the glyph while the session
        /// starts or saves, instead of dimming the whole screen.
        private var sessionControlButton: some View {
            Button {
                Task {
                    await controlModel.handleStartButtonTapped(store: store, preferences: preferences)
                }
            } label: {
                ZStack {
                    if isSessionTransitioning {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: sessionControlSystemImage)
                            .font(.system(size: 22, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: Self.dockHeight, height: Self.dockHeight)
                .tlingoGlassCircle(
                    tint: sessionControlTint,
                    interactive: true,
                    fallbackTint: sessionControlTint,
                    fallbackStroke: colors.divider.opacity(0.65)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSessionTransitioning)
            .accessibilityLabel(controlModel.startButtonTitle(for: store))
            .accessibilityIdentifier("realtime_session_control_button")
        }

        private var sessionControlSystemImage: String {
            if store.isRunning {
                return "stop.fill"
            }
            return store.inputSource == .microphone ? "mic.fill" : "play.fill"
        }

        private var sessionControlTint: Color {
            let tint = store.isRunning || store.isStopping ? colors.error : colors.accent
            return isSessionTransitioning ? tint.opacity(0.7) : tint
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
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(colors.textSecondary)
            }
            .foregroundStyle(isMissing ? Color.orange : colors.textPrimary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }

        private var swapLanguagesButton: some View {
            Button {
                swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canSwapLanguages ? colors.accent : colors.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(colors.textPrimary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSwapLanguages && !isSwapBlockedByRecognitionModel)
            .sensoryFeedback(.selection, trigger: preferences.realtimeSourceLanguage)
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
                        if store.isRunning {
                            ContentUnavailableView {
                                VStack(spacing: 16) {
                                    RealtimeInputLevelIndicator(
                                        level: store.inputLevel,
                                        isActive: !store.isPaused,
                                        tint: colors.accent
                                    )
                                    Text(RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: true))
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: false),
                                systemImage: "captions.bubble"
                            )
                        }
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

                    Section {
                        NavigationLink {
                            RecognitionModelListView(
                                preferences: preferences,
                                models: store.inputSource.supportedRecognitionModels,
                                isDisabled: store.isRunning || store.isStopping
                            )
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            LabeledContent("Model", value: selectedRecognitionModel.title)
                        }
                    } header: {
                        Text("Speech Recognition")
                    } footer: {
                        Text(selectedRecognitionModel.recommendationText)
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

        private var selectedRecognitionModel: RecognitionModelDescriptor {
            RecognitionModelStore.selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
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

    /// Local model loads report no progress, so the bar extrapolates from the last measured load
    /// time; the first load only shows elapsed time.
    private struct RealtimeModelLoadProgressView: View {
        let progress: RealtimeModelLoadProgress
        let tint: Color
        let secondaryColor: Color

        var body: some View {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                HStack(spacing: 6) {
                    if let fraction = progress.fraction(at: context.date) {
                        ProgressView(value: fraction)
                            .tint(tint)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    } else {
                        Text(
                            Duration.seconds(Int(context.date.timeIntervalSince(progress.startedAt))),
                            format: .units(allowed: [.seconds], width: .abbreviated)
                        )
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(secondaryColor)
            }
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

#endif
