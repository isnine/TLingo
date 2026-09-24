//
//  CompactTranslationView.swift
//  ShareCore
//
//  The compact translation surface shared between the iOS system Translation
//  extension and the onboarding "try premium" sheet. All UI (header bar,
//  action chips, streaming result cards, hint label, loading overlay) lives
//  here and is driven exclusively by `HomeViewModel`.
//
//  Hosts (`ExtensionCompactView`, `OnboardingTrialSheet`) wire the host-
//  specific bits in through closures: replacing the selected text in the
//  host app (`onReplace`), opening a conversation (`onConversation`), and
//  the trailing footer below the result list (`trailingFooter` — used by
//  the extension to surface "Open in TLingo").
//

#if os(iOS) && !targetEnvironment(macCatalyst)
    import SwiftUI

    public struct CompactTranslationView<TrailingFooter: View>: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var viewModel: HomeViewModel

        private let onReplace: ((String) -> Void)?
        private let onConversation: ((ConversationSession) -> Void)?
        private let trailingFooter: () -> TrailingFooter
        private let usesCompactSnapshotMetrics: Bool
        private let usesCachedRequestState: Bool

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        public init(
            viewModel: HomeViewModel,
            onReplace: ((String) -> Void)? = nil,
            onConversation: ((ConversationSession) -> Void)? = nil,
            usesCompactSnapshotMetrics: Bool = false,
            usesCachedRequestState: Bool = false,
            @ViewBuilder trailingFooter: @escaping () -> TrailingFooter = { EmptyView() }
        ) {
            self.viewModel = viewModel
            self.onReplace = onReplace
            self.onConversation = onConversation
            self.usesCompactSnapshotMetrics = usesCompactSnapshotMetrics
            self.usesCachedRequestState = usesCachedRequestState
            self.trailingFooter = trailingFooter
        }

        public var body: some View {
            ZStack {
                VStack(alignment: .leading, spacing: usesCompactSnapshotMetrics ? 8 : 12) {
                    headerBar

                    Divider()
                        .background(colors.divider)

                    actionChips

                    if !viewModel.modelRuns.isEmpty {
                        resultSection
                    } else if !viewModel.isLoadingConfiguration {
                        hintLabel
                    }

                    Spacer(minLength: 0)
                }
                .padding(usesCompactSnapshotMetrics ? 12 : 16)

                if viewModel.isLoadingConfiguration {
                    configurationLoadingOverlay
                }
            }
        }

        // MARK: - Header Bar

        private var headerBar: some View {
            HStack(spacing: 8) {
                Text("Translate to", comment: "Label before the target language picker in the extension")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)

                LanguageSwitcherView(
                    globeFont: .system(size: 12),
                    textFont: .system(size: 13, weight: .medium),
                    chevronFont: .system(size: 8),
                    foregroundColor: colors.accent,
                    languageDependencies: viewModel.selectedAction?.languageDependencies ?? .none,
                    resolvedTarget: viewModel.resolvedTargetLanguage,
                    onOverrideTarget: {
                        viewModel.overrideTargetLanguage(
                            $0,
                            refreshEntitlement: !usesCachedRequestState,
                            allowModelFallback: usesCachedRequestState
                        )
                    },
                    detectedSource: viewModel.detectedSourceLanguage,
                    onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
                )

                Spacer(minLength: 0)

                inputSpeakButton

                chatButton
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }

        @ViewBuilder
        private var inputSpeakButton: some View {
            let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                if viewModel.isSpeakingInputText {
                    viewModel.stopSpeaking()
                } else {
                    viewModel.speakInputText()
                }
            } label: {
                Image(systemName: viewModel.isSpeakingInputText ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(viewModel.isSpeakingInputText ? colors.error : colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(!hasText && !viewModel.isSpeakingInputText)
        }

        @ViewBuilder
        private var chatButton: some View {
            if let onConversation {
                Button {
                    if let session = viewModel.createContextConversation(contextText: viewModel.inputText) {
                        onConversation(session)
                    }
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 14))
                        .foregroundColor(colors.accent)
                }
                .buttonStyle(.plain)
            }
        }

        // MARK: - Action Chips

        private var actionChips: some View {
            ActionChipsView(
                actions: viewModel.actions,
                selectedActionID: viewModel.selectedAction?.id,
                spacing: 8,
                font: .system(size: 13, weight: .medium),
                textColor: { isSelected in
                    isSelected ? .white : colors.textSecondary
                },
                background: { isSelected in
                    chipBackground(isSelected: isSelected)
                },
                horizontalPadding: 14,
                verticalPadding: 8
            ) { action in
                if viewModel.selectAction(action) {
                    viewModel.performSelectedAction(
                        refreshEntitlement: !usesCachedRequestState,
                        allowModelFallback: usesCachedRequestState
                    )
                }
            }
        }

        // MARK: - Hint Label

        private var hintLabel: some View {
            Text(viewModel.placeholderHint)
                .font(.system(size: 13))
                .foregroundColor(colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
        }

        // MARK: - Result Section

        @ViewBuilder
        private var resultSection: some View {
            ScrollView {
                VStack(spacing: usesCompactSnapshotMetrics ? 6 : 12) {
                    ForEach(viewModel.displayedModelRuns) { run in
                        let inspectRequest: (() -> Void)? = DeveloperMode.isEnabled ? {
                            viewModel.presentDebugRequestDetails(for: run.id)
                        } : nil

                        ProviderResultCardView(
                            run: run,
                            showModelName: true,
                            viewModel: viewModel,
                            onCopy: { text in
                                PasteboardHelper.copy(text)
                            },
                            onReplace: onReplace,
                            onChat: chatHandler(for: run),
                            onSuggestedAction: suggestedActionHandler(for: run),
                            onInspectRequest: inspectRequest,
                            usesCompactSnapshotMetrics: usesCompactSnapshotMetrics
                        )
                    }

                    trailingFooter()
                }
            }
        }

        private func chatHandler(for run: HomeViewModel.ModelRunViewState) -> (() -> Void)? {
            guard let onConversation, !run.model.isDirectTranslation else { return nil }
            return {
                if let session = viewModel.createConversation(from: run) {
                    onConversation(session)
                }
            }
        }

        private func suggestedActionHandler(
            for run: HomeViewModel.ModelRunViewState
        ) -> ((String) -> Void)? {
            guard let onConversation, !run.model.isDirectTranslation else { return nil }
            return { action in
                if let session = viewModel.createConversationWithFollowUp(from: run, followUp: action) {
                    onConversation(session)
                }
            }
        }

        // MARK: - Loading Overlay

        private var configurationLoadingOverlay: some View {
            LoadingOverlay(
                backgroundColor: Color(UIColor.systemBackground).opacity(0.95),
                messageFont: .system(size: 13),
                textColor: colors.textSecondary,
                accentColor: colors.accent
            )
        }

        // MARK: - Backgrounds

        @ViewBuilder
        private func chipBackground(isSelected: Bool) -> some View {
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
