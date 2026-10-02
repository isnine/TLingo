#if os(macOS)
    import ShareCore
    import SwiftUI

    struct RealtimeTransportBar: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject var store: RealtimeSessionStore
        @ObservedObject var preferences: AppPreferences
        @Binding var isInspectorPresented: Bool

        let isStarting: Bool
        let canStart: Bool
        let startHelp: String
        let onStart: () -> Void
        let onEnd: () -> Void
        let onImportAudio: () -> Void
        let onClearImportedAudio: () -> Void
        let onLanguageChanged: () -> Void

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        private var isBusy: Bool {
            store.isRunning || isStarting || store.isStopping
        }

        private var canClearTranscript: Bool {
            !store.sourceText.isEmpty || !store.translatedText.isEmpty || !store.pendingSourceText.isEmpty ||
                !store.pendingTranslatedText.isEmpty
        }

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    regularInputMenu
                    languageControls
                    Spacer(minLength: 12)
                    primaryActions
                    Spacer(minLength: 12)
                    trailingActions
                }

                HStack(spacing: 8) {
                    compactInputMenu
                    languageControls
                    Spacer(minLength: 8)
                    primaryActions
                    trailingActions
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .tlingoGlassSurface(.panel, cornerRadius: TLingoRadius.extraLarge)
        }

        private var regularInputMenu: some View {
            inputMenu
                .labelStyle(.titleAndIcon)
        }

        private var compactInputMenu: some View {
            inputMenu
                .labelStyle(.iconOnly)
        }

        private var inputMenu: some View {
            Menu {
                ForEach(RealtimeAudioInputSource.allCases) { source in
                    Button {
                        store.inputSource = source
                    } label: {
                        if source == store.inputSource {
                            Label(source.title, systemImage: "checkmark")
                        } else {
                            Label(source.title, systemImage: source.systemImage)
                        }
                    }
                }
            } label: {
                Label(store.inputSource.title, systemImage: store.inputSource.systemImage)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .disabled(isBusy)
            .help("Input")
        }

        private var languageControls: some View {
            LanguageSwitcherView(
                globeFont: .system(size: 10),
                textFont: .system(size: 12, weight: .semibold),
                chevronFont: .system(size: 8, weight: .semibold),
                foregroundColor: colors.textPrimary,
                showsControlBackgrounds: false,
                sourceOptions: SourceLanguageOption.realtimeSelectionOptions,
                targetOptions: TargetLanguageOption.realtimeSelectionOptions,
                disabledSourceOptions: unsupportedSourceLanguageOptions,
                preferenceScope: .realtime,
                sourceFallbackTitle: String(localized: "Source"),
                targetFallbackTitle: String(localized: "Target"),
                isSourceSelectionDisabled: isBusy,
                isTargetSelectionDisabled: isBusy,
                isSwapDisabled: isBusy,
                languageDependencies: PromptLanguageDependencies(
                    usesSourceLanguage: true,
                    usesTargetLanguage: true
                ),
                onSelectionChanged: onLanguageChanged
            )
        }

        private var unsupportedSourceLanguageOptions: Set<SourceLanguageOption> {
            Set(SourceLanguageOption.realtimeSelectionOptions.filter { option in
                store.laneConfigurations.contains { !$0.recognitionModel.supports(sourceLanguage: option) }
            })
        }

        @ViewBuilder
        private var primaryActions: some View {
            HStack(spacing: 8) {
                primaryAction
                importAudioButton
            }
        }

        @ViewBuilder
        private var primaryAction: some View {
            if store.isRunning {
                Button(
                    store.isStopping ? "Stopping" : "End",
                    systemImage: store.isStopping ? "hourglass" : "stop.fill",
                    action: onEnd
                )
                .frame(width: 88, height: 40)
                .buttonStyle(.plain)
                .disabled(store.isStopping)
                .foregroundStyle(.white)
                .tlingoGlassSurface(
                    cornerRadius: 20,
                    tint: colors.error.opacity(colorScheme == .dark ? 0.72 : 0.78),
                    interactive: !store.isStopping,
                    fallbackTint: colors.error.opacity(colorScheme == .dark ? 0.72 : 0.78),
                    fallbackStroke: colors.error.opacity(0.24)
                )
                .help(store.isStopping ? "Stopping realtime translation" : "End realtime translation")
            } else {
                Button(
                    isStarting ? "Starting" : (store.hasImportedAudio ? "Recognize Audio" : "Start"),
                    systemImage: isStarting ? "hourglass" : "play.fill",
                    action: onStart
                )
                .frame(width: store.hasImportedAudio ? 148 : 118, height: 40)
                .buttonStyle(.plain)
                .foregroundStyle(canStart && !isStarting ? Color.white : colors.textSecondary)
                .disabled(!canStart || isStarting || store.isStopping)
                .tlingoGlassSurface(canStart && !isStarting ? .prominent : .control, cornerRadius: TLingoRadius.large, interactive: canStart && !isStarting)
                .help(startHelp)
            }
        }

        private var importAudioButton: some View {
            Button(
                store.hasImportedAudio ? "Cancel" : "Import Audio",
                systemImage: store.hasImportedAudio ? "xmark" : "square.and.arrow.down",
                action: store.hasImportedAudio ? onClearImportedAudio : onImportAudio
            )
            .labelStyle(.iconOnly)
            .frame(width: 40, height: 40)
            .buttonStyle(.plain)
            .foregroundStyle(store.hasImportedAudio ? colors.accent : colors.textPrimary)
            .disabled(isBusy)
            .tlingoGlassSurface(.control, cornerRadius: TLingoRadius.large, interactive: !isBusy)
            .help(store.importedAudioURL?.lastPathComponent ?? String(localized: "Import Audio"))
        }

        private var trailingActions: some View {
            HStack(spacing: 8) {
                if store.isRunning {
                    transportButton(
                        store.isPaused ? "Resume" : "Pause",
                        systemImage: store.isPaused ? "play.fill" : "pause.fill",
                        isEnabled: !store.isStopping && store.canPauseCurrentSession
                    ) {
                        store.togglePaused()
                    }
                }

                if canClearTranscript {
                    transportButton(
                        "Clear",
                        systemImage: "trash",
                        isEnabled: !store.isStopping
                    ) {
                        if store.isRunning {
                            store.clearTranscriptDisplay()
                        } else {
                            store.resetTranscript()
                        }
                    }
                }

                Button("Realtime Options", systemImage: "sidebar.trailing") {
                    isInspectorPresented.toggle()
                }
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 40)
                .buttonStyle(.plain)
                .foregroundStyle(isInspectorPresented ? colors.accent : colors.textPrimary)
                .tlingoGlassSurface(.control, cornerRadius: TLingoRadius.large, interactive: true)
                .help(isInspectorPresented ? "Hide Realtime inspector" : "Show Realtime inspector")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        private func transportButton(
            _ title: LocalizedStringKey,
            systemImage: String,
            isEnabled: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Button(title, systemImage: systemImage, action: action)
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 40)
                .buttonStyle(.plain)
                .foregroundStyle(isEnabled ? colors.textPrimary : colors.textSecondary)
                .disabled(!isEnabled)
                .tlingoGlassSurface(.control, cornerRadius: TLingoRadius.large, interactive: isEnabled)
                .help(title)
        }
    }
#endif
