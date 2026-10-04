//
//  PopupTranslationView.swift
//  TLingo
//
//  Compact SwiftUI view for text selection translation results.
//

#if os(macOS)
    import ShareCore
    import SwiftUI

    struct PopupTranslationView: View {
        @ObservedObject var viewModel: HomeViewModel
        @State private var showDataConsent = false
        var onResizeDrag: ((CGSize) -> Void)?
        var onResizeEnded: (() -> Void)?
        var onTranslationSucceeded: (() -> Void)?
        var onReplace: ((String) -> Void)?
        @Environment(\.colorScheme) private var colorScheme

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: AppPreferences.shared.accentTheme)
        }

        var body: some View {
            popupGlassContainer
                .sheet(isPresented: $showDataConsent) {
                    DataConsentView {
                        AppPreferences.shared.setHasAcceptedDataSharing(true)
                        viewModel.performSelectedAction(
                            refreshEntitlement: false,
                            allowModelFallback: true
                        )
                    }
                    .interactiveDismissDisabled()
                }
                .onChange(of: viewModel.showDataConsentRequest) { _, requested in
                    if requested {
                        showDataConsent = true
                        viewModel.showDataConsentRequest = false
                    }
                }
                .onReceive(viewModel.$modelRuns) { runs in
                    guard runs.contains(where: { run in
                        if case .success = run.status { return true }
                        return false
                    }) else { return }
                    onTranslationSucceeded?()
                }
        }

        @ViewBuilder
        private var popupGlassContainer: some View {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    popupContent
                }
            } else {
                popupContent
            }
        }

        private var popupContent: some View {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection

                    Divider().opacity(0.72)

                    actionChips
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    Divider().opacity(0.72)

                    HomeView(
                        viewModel: viewModel,
                        showsOnlyResults: true,
                        onResultReplace: onReplace
                    )
                    .padding(.bottom, 28)
                }
                .frame(minWidth: 320, minHeight: 200)
                .tlingoGlassSurface(.panel, cornerRadius: TLingoRadius.medium)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 18, x: 0, y: 8)

                SelectionPopupResizeGrabber(
                    onDrag: { delta in onResizeDrag?(delta) },
                    onEnded: { onResizeEnded?() }
                )
            }
        }

        private var headerSection: some View {
            HStack(alignment: .center, spacing: 8) {
                Text(viewModel.inputText)
                    .font(.system(size: 13))
                    .foregroundColor(colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                inputSpeakButton

                languageSwitcher
            }
            .padding(12)
        }

        private var inputSpeakButton: some View {
            Button {
                if viewModel.isSpeakingInputText {
                    viewModel.stopSpeaking()
                } else {
                    viewModel.speakInputText()
                }
            } label: {
                Image(systemName: viewModel.isSpeakingInputText ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(viewModel.isSpeakingInputText ? colors.error : colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(viewModel.isSpeakingInputText ? "Stop speaking" : "Speak text")
            .accessibilityLabel(viewModel.isSpeakingInputText ? "Stop speaking" : "Speak text")
        }

        private var languageSwitcher: some View {
            LanguageSwitcherView(
                globeFont: .system(size: 10),
                textFont: .system(size: 11, weight: .medium),
                chevronFont: .system(size: 7),
                foregroundColor: colors.textSecondary,
                languageDependencies: viewModel.selectedAction?.languageDependencies ?? .none,
                resolvedTarget: viewModel.resolvedTargetLanguage,
                onOverrideTarget: {
                    viewModel.overrideTargetLanguage(
                        $0,
                        refreshEntitlement: false,
                        allowModelFallback: true
                    )
                },
                detectedSource: viewModel.detectedSourceLanguage,
                onSourceChanged: { viewModel.clearDetectedSourceLanguage() },
                onSelectionChanged: {
                    viewModel.performSelectedAction(
                        refreshEntitlement: false,
                        allowModelFallback: true
                    )
                }
            )
        }

        private var actionChips: some View {
            ActionChipsView(
                actions: viewModel.actions,
                selectedActionID: viewModel.selectedAction?.id,
                spacing: 8,
                font: .system(size: 12, weight: .medium),
                textColor: { isSelected in
                    isSelected ? .white : colors.textSecondary
                },
                background: { isSelected in
                    actionChipBackground(isSelected: isSelected)
                },
                horizontalPadding: 12,
                verticalPadding: 6
            ) { action in
                if viewModel.selectAction(action) {
                    viewModel.performSelectedAction(
                        refreshEntitlement: false,
                        allowModelFallback: true
                    )
                }
            }
        }

        @ViewBuilder
        private func actionChipBackground(isSelected: Bool) -> some View {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colors.accent)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
    }
#endif
