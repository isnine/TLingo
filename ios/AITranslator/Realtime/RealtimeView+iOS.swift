#if os(iOS)
    import AVFoundation
    import AVKit
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
        @StateObject private var pictureInPicture: RealtimePictureInPictureController
        @StateObject private var liveActivity: RealtimeLiveActivityController
        private let onShowSidebarTap: (() -> Void)?
        private let onHistoryTap: (() -> Void)?
        /// Set when presented full screen from Home; adds a Close button.
        private let onDismiss: (() -> Void)?
        @State private var isSettingsPresented = false
        @State private var settingsPath: [RealtimeSettingsRoute] = []
        @State private var settingsDetent: PresentationDetent = .medium
        @State private var showsSwapUnsupportedAlert = false
        @State private var isSourceLanguagePickerPresented = false
        @State private var isTargetLanguagePickerPresented = false
        @State private var controlDockHeight: CGFloat = 0
        @State private var translationPack: TranslationPackState = .ready
        @State private var translationPackDownloadConfiguration: TranslationSession.Configuration?

        /// Apple Translate language pack readiness, checked before Start so a missing pack is
        /// downloaded up front instead of failing the start and offering a download afterwards.
        private enum TranslationPackState: Equatable {
            /// Installed, or no Apple Translate pack is needed for the current settings.
            case ready
            case needsDownload
            /// Waiting on the system download prompt.
            case downloading
            /// iOS keeps downloading after its prompt is dismissed while `LanguageAvailability`
            /// still reports `.supported`, so this state polls until the pack is installed.
            case downloadingInBackground
            case unsupported
        }

        private enum RealtimeSettingsRoute: Hashable {
            case recognitionModels
            case captionAppearance
        }

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
            _pictureInPicture = StateObject(wrappedValue: RealtimePictureInPictureController(store: store))
            _liveActivity = StateObject(wrappedValue: RealtimeLiveActivityController(store: store))
            self.onShowSidebarTap = onShowSidebarTap
            self.onHistoryTap = onHistoryTap
            self.onDismiss = onDismiss
        }

        @ThemeColors private var colors: AppColorPalette

        private var captionLines: [RealtimeCaptionLine] {
            store.captionLines
        }

        var body: some View {
            captionPane
                .background {
                    // PiP can only start from an attached layer, so keep it out of the window until recording starts.
                    if preferences.realtimePictureInPictureEnabled, store.isRunning {
                        RealtimePictureInPictureSourceView(controller: pictureInPicture)
                            .accessibilityHidden(true)
                    }
                }
                .translationTask(store.appleTranslationDownloadConfiguration) { session in
                    await store.prepareAppleTranslationLanguageDownload(using: session)
                }
                .translationTask(translationPackDownloadConfiguration) { session in
                    await downloadTranslationPack(using: session)
                }
                .task(id: translationPackKey) {
                    await refreshTranslationPack()
                }
                .task(id: translationPack) {
                    // Catches a download that finishes in the background or from Settings.
                    guard translationPack == .needsDownload || translationPack == .downloadingInBackground else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        await refreshTranslationPack()
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    controlDock
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlDockHeight = $0 }
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
                .onChange(of: controlModel.opensRecognitionModels, initial: true) { _, opens in
                    guard opens else { return }
                    controlModel.opensRecognitionModels = false
                    settingsPath = [.recognitionModels]
                    settingsDetent = .large
                    isSettingsPresented = true
                }
                .onAppear(perform: repairSameLanguageDirection)
                .task(id: recognitionModelPrewarmKey) {
                    guard scenePhase == .active else { return }
                    await store.prewarmRecognitionModel()
                }
                .alert(
                    store.startFailureAlert?.title ?? "Realtime Failed",
                    isPresented: startFailureAlertPresentedBinding
                ) {
                    if store.startFailureAlert?.offersAppleTranslationDownload == true {
                        Button("Download") {
                            store.dismissStartFailureAlert()
                            store.allowAppleTranslationDownloadOnNextStart()
                            controlModel.sessionButtonTapped(store: store, preferences: preferences)
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
                        .tint(.primary)
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
                        .tint(.primary)
                        .accessibilityIdentifier("realtime_history_button")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                RealtimeCaptionModeMenu(store: store) {
                    settingsPath = [.captionAppearance]
                    settingsDetent = .large
                    isSettingsPresented = true
                }
                .tint(.primary)
                Button("Realtime Options", systemImage: "slider.horizontal.3") {
                    settingsPath = []
                    settingsDetent = .medium
                    isSettingsPresented = true
                }
                .tint(.primary)
                .accessibilityIdentifier("realtime_options_button")
            }
        }

        // MARK: - Control Dock

        private static let dockHeight: CGFloat = 56

        private var isSessionActive: Bool {
            store.isRunning || controlModel.isStartingRealtimeSession || store.isStopping
        }

        private var isSessionTransitioning: Bool {
            controlModel.isHandlingSessionTap || controlModel.isStartingRealtimeSession || store.isStopping
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
                } else if let hint = translationPackHint, !isSessionActive {
                    Label(hint, systemImage: translationPackHintSystemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(translationPack == .unsupported ? .orange : colors.textSecondary)
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
            .animation(.snappy, value: translationPack)
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
                    Group {
                        if let modelTitle = store.loadingRecognitionModelTitle {
                            RealtimeModelLoadingStatusText(modelTitle: modelTitle)
                        } else {
                            Text(store.statusText)
                        }
                    }
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
                RealtimeLog.log(
                    "session",
                    "pause button tapped running=\(store.isRunning) paused=\(store.isPaused) stopping=\(store.isStopping)"
                )
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
                RealtimeLog.log(
                    "session",
                    """
                    session button tapped running=\(store.isRunning) starting=\(controlModel.isStartingRealtimeSession) \
                    stopping=\(store.isStopping) pending=\(controlModel.isHandlingSessionTap) pack=\(translationPack)
                    """
                )
                if !store.isRunning, translationPack == .needsDownload {
                    requestTranslationPackDownload()
                    return
                }
                controlModel.sessionButtonTapped(store: store, preferences: preferences)
            } label: {
                ZStack {
                    if isSessionTransitioning || isTranslationPackDownloading {
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
            .disabled(isSessionTransitioning || (!store.isRunning && !canStartWithTranslationPack))
            .accessibilityLabel(sessionControlAccessibilityLabel)
            .accessibilityIdentifier("realtime_session_control_button")
        }

        private var sessionControlSystemImage: String {
            if store.isRunning {
                return "stop.fill"
            }
            if translationPack == .needsDownload {
                return "arrow.down"
            }
            return store.inputSource == .microphone ? "mic.fill" : "play.fill"
        }

        private var sessionControlAccessibilityLabel: LocalizedStringKey {
            if !store.isRunning, translationPack == .needsDownload {
                return "Download Languages"
            }
            return controlModel.startButtonTitle(for: store)
        }

        private var sessionControlTint: Color {
            let tint = store.isRunning || store.isStopping ? colors.error : colors.accent
            let isDimmed = isSessionTransitioning || (!store.isRunning && !canStartWithTranslationPack)
            return isDimmed ? tint.opacity(0.7) : tint
        }

        // MARK: - Apple Translate Language Pack

        private var translationPackKey: String {
            [
                preferences.realtimeSourceLanguage.rawValue,
                preferences.realtimeTargetLanguage.rawValue,
                preferences.realtimeTranslationProvider.rawValue,
                "\(scenePhase == .active)",
            ].joined(separator: "|")
        }

        private var translationPackStrategy: AppleTranslationAvailabilityStrategy {
            preferences.realtimeTranslationProvider == .appleTranslationRealtime ? .lowLatency : .automatic
        }

        private var isTranslationPackDownloading: Bool {
            !store.isRunning && (translationPack == .downloading || translationPack == .downloadingInBackground)
        }

        /// Start stays enabled for a missing pack because that tap downloads it.
        private var canStartWithTranslationPack: Bool {
            translationPack == .ready || translationPack == .needsDownload
        }

        private var translationPackHint: String? {
            switch translationPack {
            case .ready:
                nil
            case .needsDownload:
                String(localized: "Download \(sourceLanguageDisplayName) and \(targetLanguageDisplayName) for Apple Translate to start.")
            case .downloading:
                String(localized: "Tap Download in the iOS prompt.")
            case .downloadingInBackground:
                String(localized: "iOS is downloading these languages. Realtime starts when they are ready.")
            case .unsupported:
                String(localized: "Apple Translate does not support \(sourceLanguageDisplayName) to \(targetLanguageDisplayName). Pick another pair.")
            }
        }

        private var translationPackHintSystemImage: String {
            switch translationPack {
            case .unsupported: "exclamationmark.circle.fill"
            case .downloading, .downloadingInBackground: "arrow.down.circle"
            default: "arrow.down.circle.fill"
            }
        }

        private func refreshTranslationPack() async {
            guard scenePhase == .active, !store.isRunning,
                  preferences.realtimeTranslationProvider.usesAppleTextTranslation,
                  !LanguageDirectionSwap.isSameLanguage(
                      source: preferences.realtimeSourceLanguage,
                      target: preferences.realtimeTargetLanguage
                  ),
                  let source = preferences.realtimeSourceLanguage.localeLanguage,
                  AppleTranslationService.shared.isAvailable
            else {
                translationPack = .ready
                return
            }
            // Unknown statuses fall back to the start preflight, which reports its own errors.
            let status = try? await AppleTranslationService.shared.languageAvailabilityStatus(
                source: source,
                target: preferences.realtimeTargetLanguage.localeLanguage,
                strategy: translationPackStrategy
            )
            guard !Task.isCancelled else { return }
            switch status {
            case .supported:
                // Keep showing the download while iOS finishes it, and never interrupt a prompt.
                if translationPack != .downloadingInBackground, translationPack != .downloading {
                    translationPack = .needsDownload
                }
            case .unsupported:
                translationPack = .unsupported
            default:
                translationPack = .ready
            }
        }

        private func requestTranslationPackDownload() {
            guard let source = preferences.realtimeSourceLanguage.localeLanguage else { return }
            let target = preferences.realtimeTargetLanguage.localeLanguage
            var configuration: TranslationSession.Configuration = if #available(iOS 26.4, *),
                                                                     translationPackStrategy == .lowLatency
            {
                .init(source: source, target: target, preferredStrategy: .lowLatency)
            } else {
                .init(source: source, target: target)
            }
            // An unchanged configuration does not re-run the task; invalidate it to show the prompt again.
            if var previous = translationPackDownloadConfiguration,
               previous.source == configuration.source,
               previous.target == configuration.target
            {
                previous.invalidate()
                configuration = previous
            }
            RealtimeLog.log("session", "apple translate pack download requested strategy=\(translationPackStrategy)")
            translationPack = .downloading
            translationPackDownloadConfiguration = configuration
        }

        private func downloadTranslationPack(using session: TranslationSession) async {
            guard translationPack == .downloading else { return }
            do {
                try await session.prepareTranslation()
                RealtimeLog.log("session", "apple translate pack download prepared")
            } catch {
                // Includes a cancelled prompt; leave Download available to try again.
                RealtimeLog.log("session", "apple translate pack download failed error=\(error)")
                translationPack = .needsDownload
                await refreshTranslationPack()
                return
            }
            translationPack = .downloadingInBackground
            await refreshTranslationPack()
            if translationPack == .downloadingInBackground {
                RealtimeLog.log("session", "apple translate pack still downloading in background")
            }
        }

        private var sourceLanguageMenu: some View {
            Button {
                isSourceLanguagePickerPresented = true
            } label: {
                languageMenuLabel(
                    sourceLanguageDisplayName,
                    isMissing: preferences.realtimeSourceLanguage == .auto
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isRunning)
            .accessibilityLabel("Source Language")
            .accessibilityValue(sourceLanguageDisplayName)
            .accessibilityIdentifier("realtime_source_language_menu")
            .sheet(isPresented: $isSourceLanguagePickerPresented) {
                LanguagePickerView(
                    selectedCode: realtimeSourceLanguageCodeBinding,
                    isPresented: $isSourceLanguagePickerPresented,
                    rows: realtimeSourceLanguageRows,
                    title: String(localized: "Select Source Language")
                )
                .presentationDetents([.medium, .large])
            }
        }

        private var targetLanguageMenu: some View {
            Button {
                isTargetLanguagePickerPresented = true
            } label: {
                languageMenuLabel(
                    targetLanguageDisplayName,
                    isMissing: preferences.realtimeTranslationProvider.performsTranslation &&
                        preferences.realtimeTargetLanguage == .appLanguage
                )
            }
            .buttonStyle(.plain)
            .disabled(targetLanguageSelectionDisabled)
            .accessibilityLabel("Target Language")
            .accessibilityValue(targetLanguageDisplayName)
            .accessibilityIdentifier("realtime_target_language_menu")
            .sheet(isPresented: $isTargetLanguagePickerPresented) {
                LanguagePickerView(
                    selectedCode: realtimeTargetCodeBinding,
                    isPresented: $isTargetLanguagePickerPresented,
                    rows: realtimeTargetLanguageRows,
                    title: String(localized: "Select Target Language")
                )
                .presentationDetents([.medium, .large])
            }
        }

        private static let transcriptionOnlyRowID = "transcription-only"

        private var realtimeSourceLanguageRows: [LanguageRow] {
            let unsupported = unsupportedRealtimeSourceLanguageOptions
            return SourceLanguageOption.realtimeSelectionOptions.map {
                LanguageRow(
                    source: $0,
                    disabledReason: unsupported.contains($0) ?
                        String(localized: "Not supported by selected recognition model") :
                        nil
                )
            }
        }

        private var realtimeTargetLanguageRows: [LanguageRow] {
            let transcriptionOnly = RealtimeTranslationProvider.transcriptionOnly
            let transcriptionRow = LanguageRow(
                id: Self.transcriptionOnlyRowID,
                primaryLabel: transcriptionOnly.title,
                secondaryLabel: String(localized: "Show captions without translation"),
                isDisabled: store.isRunning
            )
            return [transcriptionRow] + TargetLanguageOption.realtimeSelectionOptions.map {
                LanguageRow(
                    target: $0,
                    isDisabled: LanguageDirectionSwap.isSameLanguage(
                        source: preferences.realtimeSourceLanguage,
                        target: $0
                    )
                )
            }
        }

        private var realtimeSourceLanguageCodeBinding: Binding<String> {
            Binding(
                get: { preferences.realtimeSourceLanguage.rawValue },
                set: { code in
                    guard let option = SourceLanguageOption(rawValue: code),
                          option != preferences.realtimeSourceLanguage
                    else { return }
                    realtimeSourceLanguageBinding.wrappedValue = option
                }
            )
        }

        private var realtimeTargetCodeBinding: Binding<String> {
            Binding(
                get: {
                    switch realtimeTargetSelectionBinding.wrappedValue {
                    case .transcriptionOnly: Self.transcriptionOnlyRowID
                    case let .language(option): option.rawValue
                    }
                },
                set: { code in
                    if code == Self.transcriptionOnlyRowID {
                        realtimeTargetSelectionBinding.wrappedValue = .transcriptionOnly
                    } else if let option = TargetLanguageOption(rawValue: code) {
                        realtimeTargetSelectionBinding.wrappedValue = .language(option)
                    }
                }
            )
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
                    .foregroundStyle(canSwapLanguages ? colors.textPrimary : colors.textSecondary)
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

        /// Older settings could pair a language with itself (English → English (US)); pick a real target.
        private func repairSameLanguageDirection() {
            let source = preferences.realtimeSourceLanguage
            guard !store.isRunning,
                  LanguageDirectionSwap.isSameLanguage(source: source, target: preferences.realtimeTargetLanguage)
            else { return }
            let replacement = TargetLanguageOption.matchCandidates.first {
                TargetLanguageOption.realtimeSelectionOptions.contains($0)
                    && !LanguageDirectionSwap.isSameLanguage(source: source, target: $0)
            } ?? .appLanguage
            preferences.setRealtimeTargetLanguage(replacement)
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

            // Extends under the navigation bar and control dock; their heights become content insets
            // so captions scroll beneath both while the latest line stays above the dock.
            return ZStack {
                RealtimeCaptionTextView(
                    lines: lines,
                    style: captionStyle,
                    bottomAccessoryHeight: controlDockHeight,
                    revision: store.captionRevision
                )
                .ignoresSafeArea(.container, edges: .vertical)

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
                        ContentUnavailableView {
                            Label("Start Realtime Translation", systemImage: "captions.bubble")
                        } description: {
                            Text(emptyStateDescription)
                        } actions: {
                            emptyStateOptions
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(preferences.realtimeCaptionAppearance.captionBackgroundColor(fallback: colors.background))
        }

        private var emptyStateDescription: LocalizedStringKey {
            switch store.inputSource {
            case .iphoneAudio:
                "Captures sound playing on your iPhone. Great for videos and podcasts."
            case .microphone:
                "Captures audio from your microphone. Great for travel."
            }
        }

        private var emptyStateOptions: some View {
            VStack(spacing: 0) {
                // A menu-style Picker swallows the next tap after a selection (the play button
                // ignored its first tap), and its chevron can't match the row below.
                Menu {
                    Picker("Input", selection: inputSourceBinding) {
                        ForEach(RealtimeAudioInputSource.allCases) { source in
                            Text(source.title)
                                .tag(source)
                        }
                    }
                } label: {
                    emptyStateOptionRow("Input", value: store.inputSource.title)
                }
                .buttonStyle(.plain)

                Divider()

                // Model choice needs download and language checks, so it opens the model list.
                Button {
                    settingsPath = [.recognitionModels]
                    settingsDetent = .large
                    isSettingsPresented = true
                } label: {
                    emptyStateOptionRow("Speech Recognition", value: selectedRecognitionModel.title)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, TLingoSpacing.md)
            .background(
                colors.cardBackground,
                in: .rect(cornerRadius: TLingoRadius.medium, style: .continuous)
            )
            .frame(maxWidth: 320)
        }

        private func emptyStateOptionRow(_ title: LocalizedStringKey, value: String) -> some View {
            LabeledContent(title) {
                HStack(spacing: TLingoSpacing.xxs) {
                    Text(value)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(colors.textSecondary)
            }
            .foregroundStyle(colors.textPrimary)
            .padding(.vertical, TLingoSpacing.sm)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }

        private var captionStyle: RealtimeCaptionTextView.Style {
            RealtimeCaptionTextView.Style(
                palette: colors,
                appearance: preferences.realtimeCaptionAppearance,
                mode: store.resolvedCaptionDisplayMode
            )
        }

        private var settingsSheet: some View {
            NavigationStack(path: $settingsPath) {
                Form {
                    Section("Captions") {
                        RealtimeCaptionModePicker(store: store)
                        NavigationLink("Appearance", value: RealtimeSettingsRoute.captionAppearance)
                    }

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
                        NavigationLink(value: RealtimeSettingsRoute.recognitionModels) {
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
                                Text(provider.title)
                                    .tag(provider)
                            }
                        }
                        .disabled(store.isRunning)
                    }

                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        Section {
                            Toggle("Picture in Picture", isOn: pictureInPictureBinding)
                            if preferences.realtimePictureInPictureEnabled {
                                Picker("Window Size", selection: pictureInPictureSizeBinding) {
                                    Text("Standard").tag(RealtimePictureInPictureSize.standard)
                                    Text("Compact").tag(RealtimePictureInPictureSize.compact)
                                }
                            }
                        } footer: {
                            Text("Keep showing microphone captions in a floating window after leaving TLingo.")
                        }
                    }
                }
                .navigationTitle("Realtime Options")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: RealtimeSettingsRoute.self) { route in
                    switch route {
                    case .recognitionModels:
                        RecognitionModelListView(
                            preferences: preferences,
                            models: store.inputSource.supportedRecognitionModels,
                            isDisabled: store.isRunning || store.isStopping
                        )
                        .navigationBarTitleDisplayMode(.inline)
                    case .captionAppearance:
                        RealtimeCaptionAppearanceEditor(
                            preferences: preferences,
                            mode: store.resolvedCaptionDisplayMode
                        )
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    isSettingsPresented = false
                                }
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isSettingsPresented = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large], selection: $settingsDetent)
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

        private var pictureInPictureBinding: Binding<Bool> {
            Binding(
                get: { preferences.realtimePictureInPictureEnabled },
                set: { preferences.setRealtimePictureInPictureEnabled($0) }
            )
        }

        private var pictureInPictureSizeBinding: Binding<RealtimePictureInPictureSize> {
            Binding(
                get: { preferences.realtimePictureInPictureSize },
                set: { preferences.setRealtimePictureInPictureSize($0) }
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
                    // Choosing the target as the source swaps the pair rather than translating into itself.
                    if LanguageDirectionSwap.isSameLanguage(source: option, target: preferences.realtimeTargetLanguage),
                       preferences.realtimeSourceLanguage != .auto
                    {
                        let swapped = LanguageDirectionSwap.swapped(
                            source: preferences.realtimeSourceLanguage,
                            target: preferences.realtimeTargetLanguage
                        )
                        preferences.setRealtimeTargetLanguage(swapped.target)
                    }
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

        private func openAppSettings() {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        }
    }

    /// Shortens the model title (dropping the latency suffix, then trailing words) until the
    /// status fits one line, so the sentence itself is never truncated.
    private struct RealtimeModelLoadingStatusText: View {
        let modelTitle: String

        var body: some View {
            let candidates = abbreviatedTitles
            ViewThatFits(in: .horizontal) {
                ForEach(candidates.dropLast(), id: \.self) { title in
                    Text(RealtimeSessionStore.loadingRecognitionModelStatus(modelTitle: title))
                }
                Text(RealtimeSessionStore.loadingRecognitionModelStatus(modelTitle: candidates.last ?? modelTitle))
                    .truncationMode(.middle)
            }
        }

        private var abbreviatedTitles: [String] {
            var words = modelTitle.split(separator: " ")
            var titles = [modelTitle]
            if let last = words.last, last.hasSuffix("ms"), last.dropLast(2).allSatisfy(\.isNumber), words.count > 1 {
                words.removeLast()
                titles.append(words.joined(separator: " "))
            }
            while words.count > 1 {
                words.removeLast()
                titles.append(words.joined(separator: " "))
            }
            return titles
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
        /// Set synchronously on tap so the button turns into a spinner before the async work begins.
        @Published private(set) var isHandlingSessionTap = false
        @Published var broadcastPickerTrigger: UUID?
        @Published var startBlockedAlert: StartBlockedAlert?
        /// Set by a `tlingo://realtime/models` deep link; consumed by `RealtimeView`.
        @Published var opensRecognitionModels = false

        func handleRealtimeDeepLink(_ notification: Notification) {
            if notification.userInfo?[DeepLink.NotificationKey.opensRecognitionModels] as? Bool == true {
                opensRecognitionModels = true
            }
        }

        func startButtonTitle(for store: RealtimeSessionStore) -> LocalizedStringKey {
            if store.isStopping {
                return "Stopping"
            }
            if isStartingRealtimeSession {
                return "Starting"
            }
            return store.isRunning ? "Stop" : "Start"
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

        func sessionButtonTapped(store: RealtimeSessionStore, preferences: AppPreferences) {
            guard !isHandlingSessionTap else {
                RealtimeLog.log("session", "session tap ignored reason=pending")
                return
            }
            isHandlingSessionTap = true
            let tappedAt = Date()
            Task {
                RealtimeLog.log("session", "session tap handling delayMs=\(Int(Date().timeIntervalSince(tappedAt) * 1000))")
                await handleStartButtonTapped(store: store, preferences: preferences)
                isHandlingSessionTap = false
                RealtimeLog.log(
                    "session",
                    """
                    session tap finished totalMs=\(Int(Date().timeIntervalSince(tappedAt) * 1000)) \
                    running=\(store.isRunning)
                    """
                )
            }
        }

        func handleStartButtonTapped(store: RealtimeSessionStore, preferences: AppPreferences) async {
            guard !store.isStopping else {
                RealtimeLog.log("session", "session tap ignored reason=stopping")
                return
            }
            if let alert = startBlockedAlertForCurrentState(store: store, preferences: preferences) {
                RealtimeLog.log("session", "session tap blocked alert=\(alert.title)")
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
            if store.isIPhoneAudioBroadcastLive {
                // The picker's Stop Broadcast ends ReplayKit cleanly; the host finishes once it
                // polls the extension's stopped state.
                RealtimeLog.log("session", "stop via broadcast picker")
                broadcastPickerTrigger = UUID()
                return
            }
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
            // A missing language pack falls through: store.start() shows the alert that offers the download.
            if let failure = await RealtimeIPhoneAudioPreflight.evaluateAfterRequestingSpeechAuthorization(
                sourceLanguage: preferences.realtimeSourceLanguage,
                targetLanguage: preferences.realtimeTargetLanguage,
                requiresTranslation: preferences.realtimeTranslationProvider.performsTranslation
            ), failure != .translationPackNotInstalled {
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
            let model = RecognitionModelStore.selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
            if model.runtime != .fluidAudio {
                preferences.setRealtimeRecognitionModelID(RecognitionModelDescriptor.appleSpeech.id)
            }
        }
    }

    struct StartBlockedAlert {
        let title: String
        let message: String
        var opensAppSettings = false
    }

    struct BroadcastPickerLauncher: UIViewRepresentable {
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
