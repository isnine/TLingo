//
//  CompactTranslationView.swift
//  ShareCore
//
//  The compact translation surface shared between the iOS system Translation
//  extension and the onboarding "try premium" sheet. All UI (language pill,
//  action chips, streaming result cards, hint label, loading overlay) lives
//  here and is driven exclusively by `HomeViewModel`.
//
//  Hosts (`ExtensionCompactView`, `OnboardingTrialSheet`) wire the host-
//  specific bits in through closures: replacing the selected text in the
//  host app (`onReplace`), opening a conversation (`onConversation`), and
//  the trailing footer below the result list (`trailingFooter` — used by
//  the extension to surface "Open in TLingo").
//

#if os(iOS)
    import SwiftUI

    public struct CompactTranslationView<TrailingFooter: View>: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var viewModel: HomeViewModel

        private let onReplace: ((String) -> Void)?
        private let onConversation: ((ConversationSession) -> Void)?
        private let trailingFooter: () -> TrailingFooter
        private let usesCompactSnapshotMetrics: Bool
        private let usesCachedRequestState: Bool

        @State private var collapsedRunIDs: Set<String> = []

        @ThemeColors private var colors: AppColorPalette

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
                    // Fading the trailing edge signals that the row scrolls.
                    actionChips
                        .mask {
                            HStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(
                                    colors: [.black, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: Self.chipRowFadeWidth)
                            }
                        }

                    if !viewModel.modelRuns.isEmpty {
                        // Must touch the container's bottom edge so the scroll
                        // area can extend under the home-indicator safe area.
                        resultSection
                            .ignoresSafeArea(.container, edges: .bottom)
                    } else {
                        if !viewModel.isLoadingConfiguration {
                            hintLabel
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, usesCompactSnapshotMetrics ? 12 : 16)
                // The host sheet's navigation bar already separates the content.
                .padding(.top, usesCompactSnapshotMetrics ? 12 : 4)

                if viewModel.isLoadingConfiguration {
                    configurationLoadingOverlay
                }
            }
        }

        private static var chipRowFadeWidth: CGFloat { 28 }

        // MARK: - Language Pill

        private var languagePill: some View {
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
        }

        @ViewBuilder
        private var inputSpeakButton: some View {
            let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText || viewModel.isSpeakingInputText {
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
            }
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
                verticalPadding: 8,
                leading: AnyView(languagePill),
                trailing: AnyView(
                    HStack(spacing: 14) {
                        inputSpeakButton

                        chatButton
                    }
                    .padding(.leading, 6)
                    // Keeps the last items clear of the fade when scrolled to the end.
                    .padding(.trailing, Self.chipRowFadeWidth)
                )
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

                        let isCollapsed = collapsedRunIDs.contains(run.id)

                        Group {
                            if isCollapsed {
                                collapsedRow(for: run)
                            } else {
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
                        }
                        .transition(.opacity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.3)) {
                                if isCollapsed {
                                    collapsedRunIDs.remove(run.id)
                                } else {
                                    collapsedRunIDs.insert(run.id)
                                }
                            }
                        }
                        .accessibilityAction(named: isCollapsed ? Text("Expand") : Text("Collapse")) {
                            if isCollapsed {
                                collapsedRunIDs.remove(run.id)
                            } else {
                                collapsedRunIDs.insert(run.id)
                            }
                        }
                    }

                    trailingFooter()
                }
                .padding(.bottom, usesCompactSnapshotMetrics ? 12 : 16)
            }
        }

        // MARK: - Collapsed Row

        private func collapsedRow(for run: HomeViewModel.ModelRunViewState) -> some View {
            HStack(spacing: 8) {
                collapsedStatus(for: run)

                Text(collapsedPreview(for: run))
                    .font(.system(size: 14))
                    .foregroundColor(colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(run.modelDisplayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
            }
            .padding(.horizontal, usesCompactSnapshotMetrics ? TLingoSpacing.xs : TLingoSpacing.md)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                    .fill(colors.cardBackground)
            )
        }

        @ViewBuilder
        private func collapsedStatus(for run: HomeViewModel.ModelRunViewState) -> some View {
            switch run.status {
            case .idle, .running, .streaming, .streamingSentencePairs:
                ProgressView()
                    .controlSize(.mini)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(colors.success)
            case .failure:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(colors.error)
            }
        }

        private func collapsedPreview(for run: HomeViewModel.ModelRunViewState) -> String {
            let text: String = switch run.status {
            case let .success(result): result.copyText
            case let .streaming(text, _): text
            case let .streamingSentencePairs(pairs, _): pairs.map(\.translation).joined(separator: " ")
            case let .failure(message, _, _, _): message
            case .idle, .running: ""
            }
            return text.replacingOccurrences(of: "\n", with: " ")
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
