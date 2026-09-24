//
//  ExtensionCompactView.swift
//  ShareCore
//
//  Created by AI Assistant on 2026/01/04.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
    import os
    import SwiftUI
    import TranslationUIProvider

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ExtCompactView")

    /// A compact view for iOS Translation Extension, mirroring the Mac MenuBarPopoverView style
    public struct ExtensionCompactView: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.openURL) private var openURL
        @StateObject private var viewModel: HomeViewModel
        @ObservedObject private var preferences = AppPreferences.shared
        @State private var hasTriggeredAutoRequest = false
        @State private var hasRecordedDefaultTranslationTrial = false
        @State private var activeConversationSession: ConversationSession?
        @State private var displayText: String = ""

        private let context: TranslationUIProviderContext

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        public init(context: TranslationUIProviderContext) {
            self.context = context
            // supportsAppleTranslate: false — extension context cannot use .translationTask();
            // falls back to TranslationSession(installedSource:target:) for installed packs.
            _viewModel = StateObject(wrappedValue: HomeViewModel(supportsAppleTranslate: false))
        }

        /// Reads the current input text from the translation context.
        private func readContextText() -> String {
            guard let text = context.inputText else { return "" }
            return String(text.characters)
        }

        /// Syncs context text into local state and triggers action if non-empty.
        private func syncContextText() {
            let text = readContextText()
            guard text != displayText else { return }
            displayText = text
            viewModel.inputText = text
            if !text.isEmpty {
                viewModel.performSelectedAction(
                    refreshEntitlement: false,
                    allowModelFallback: true
                )
            }
        }

        private func recordDefaultTranslationTrialIfNeeded() {
            guard !hasRecordedDefaultTranslationTrial else { return }
            hasRecordedDefaultTranslationTrial = true
            AppPreferences.shared.recordDefaultTranslationTrialInvocation()
        }

        public var body: some View {
            ZStack {
                if let session = activeConversationSession {
                    ConversationContentView(
                        session: session,
                        onBack: { activeConversationSession = nil },
                        backgroundColor: .clear
                    )
                    .transition(.move(edge: .trailing))
                } else {
                    translateContent
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: activeConversationSession != nil)
            .onAppear {
                AppPreferences.shared.refreshFromDefaults()
                // The extension being shown at all means the user picked TLingo
                // from the system Translate UI — that's the onboarding signal
                // we care about, regardless of whether the selected text has
                // resolved yet.
                recordDefaultTranslationTrialIfNeeded()
            }
            .task {
                if !hasTriggeredAutoRequest {
                    hasTriggeredAutoRequest = true
                    syncContextText()
                    logger.debug("onAppear — \(viewModel.actions.count, privacy: .public) actions loaded")
                    Task { await Entitlement.shared.refresh() }
                }

                // TranslationUIProviderContext doesn't always emit reliable SwiftUI/Observation
                // change notifications for inputText. To ensure we always pick up the selected
                // text from the host app, do a short best-effort poll on appear.
                //
                // We stop early once we have non-empty text.
                for delayMs in [150, 400, 800, 1500] {
                    if Task.isCancelled { break }
                    if delayMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    }
                    syncContextText()
                    if !displayText.isEmpty { break }
                }
            }
            .onChange(of: preferences.targetLanguage) {
                // Re-trigger translation when the user manually changes the target language
                guard hasTriggeredAutoRequest, !displayText.isEmpty else { return }
                viewModel.overrideTargetLanguage(
                    preferences.targetLanguage,
                    refreshEntitlement: false,
                    allowModelFallback: true
                )
            }
            .sheet(item: $viewModel.selectedDebugNetworkRecord) { record in
                NavigationStack {
                    NetworkRequestDetailView(record: record)
                }
            }
        }

        // MARK: - Translate Content

        private var translateContent: some View {
            CompactTranslationView(
                viewModel: viewModel,
                onReplace: context.allowsReplacement ? { text in
                    context.finish(translation: AttributedString(text))
                } : nil,
                onConversation: { session in
                    activeConversationSession = session
                },
                usesCachedRequestState: true,
                trailingFooter: { openInAppBar }
            )
        }

        private var openInAppBar: some View {
            Button {
                openInMainApp()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 14, weight: .medium))
                    Text("Open in TLingo", comment: "Button in extension to open selected text in the main app")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(colors.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colors.accent.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
        }

        private func openInMainApp() {
            guard let url = DeepLink.translateURL(
                text: displayText,
                actionName: viewModel.selectedAction?.name,
                configName: AppConfigurationStore.shared.currentConfigurationName
            ) else { return }
            openURL(url)
        }
    }
#endif
