//
//  MenuBarPopoverView.swift
//  TLingo
//
//  Created by AI Assistant on 2025/12/31.
//

#if os(macOS)
    import AppKit
    import Combine
    import os
    import ShareCore
    import SwiftUI

    private let languageShortcutLogger = os.Logger(
        subsystem: "com.zanderwang.AITranslator",
        category: "LanguageShortcut"
    )

    /// A compact popover view for menu bar quick translation
    struct MenuBarPopoverView: View {
        @Environment(\.colorScheme) private var colorScheme
        @StateObject private var viewModel: HomeViewModel
        @ObservedObject private var hotKeyManager = HotKeyManager.shared
        @ObservedObject private var preferences = AppPreferences.shared
        @State private var showHotkeyHint: Bool = true
        @State private var activeConversationSession: ConversationSession?
        @State private var showFeaturePaywall = false
        // Focus is managed via AppKit's first responder, not SwiftUI's @FocusState,
        // because @FocusState on NSViewRepresentable competes with AppKit's responder chain.
        let onClose: () -> Void

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        /// Whether the quick translate hotkey is configured
        private var isHotkeyConfigured: Bool {
            !hotKeyManager.quickTranslateConfiguration.isEmpty
        }

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
            // supportsAppleTranslate: false — menu bar popover cannot use .translationTask()
            // reliably (NSPopover lacks a proper NSWindowScene). Falls back to
            // TranslationSession(installedSource:target:) for pre-installed language packs.
            _viewModel = StateObject(wrappedValue: HomeViewModel(supportsAppleTranslate: false))
        }

        var body: some View {
            popoverGlassContainer {
                popoverLayout
                    .frame(width: preferences.menuBarPopoverWidth, height: preferences.menuBarPopoverHeight)
                    .tlingoGlassSurface(
                        cornerRadius: 18,
                        tint: colors.cardBackground.opacity(colorScheme == .dark ? 0.12 : 0.20),
                        fallbackTint: colors.background.opacity(colorScheme == .dark ? 0.78 : 0.62),
                        fallbackStroke: colors.divider
                    )
            }
            .animation(.easeInOut(duration: 0.25), value: activeConversationSession != nil)
            .onAppear {
                AppPreferences.shared.refreshFromDefaults()
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuBarPopoverDidShow)) { _ in
                viewModel.refreshConfiguration()
                loadClipboardAndExecute()
            }
            .sheet(isPresented: $showFeaturePaywall) {
                PaywallView(context: .featureLocked)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }

        @ViewBuilder
        private func popoverGlassContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    content()
                }
            } else {
                content()
            }
        }

        private var popoverLayout: some View {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        if let session = activeConversationSession {
                            inlineConversationView(session: session)
                                .transition(.move(edge: .trailing))
                        } else {
                            translateContent
                                .transition(.move(edge: .leading))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    MenuBarPopoverResizeGrabber()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                MenuBarPopoverWidthResizeGrabber()
            }
        }

        private var configurationLoadingOverlay: some View {
            LoadingOverlay(
                backgroundColor: colors.background.opacity(0.95),
                messageFont: .system(size: 13),
                textColor: colors.textSecondary,
                accentColor: colors.accent
            )
        }

        // MARK: - Translate Content

        private var translateContent: some View {
            ZStack {
                VStack(alignment: .leading, spacing: 12) {
                    headerSection

                    Divider()
                        .background(colors.divider)

                    inputSection
                    actionChips

                    if !viewModel.modelRuns.isEmpty {
                        Divider()
                            .background(colors.divider)
                        resultSection
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isLoadingConfiguration {
                    configurationLoadingOverlay
                }
            }
        }

        // MARK: - Inline Conversation View

        private func inlineConversationView(session: ConversationSession) -> some View {
            ConversationContentView(
                session: session,
                onBack: {
                    activeConversationSession = nil
                },
                onDismiss: onClose,
                onPremiumRequired: {
                    showFeaturePaywall = true
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func loadClipboardAndExecute() {
            let pb = NSPasteboard.general
            let clipboardContent = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasRecentClipboard = ClipboardMonitor.shared.hasRecentContent(within: 5)

            guard hasRecentClipboard, !clipboardContent.isEmpty else {
                // Fallback: only fill empty input with whatever's on the clipboard.
                if viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.inputText = clipboardContent
                    viewModel.clearUserEditMark()
                }
                return
            }

            // Protect the user's in-progress text from accidental overwrite:
            // if the input is non-empty AND the user typed within the last 3 minutes,
            // keep their text and skip both the overwrite and the auto-translation.
            let currentTrimmed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let userEditWindow: TimeInterval = 3 * 60
            let isProtected: Bool = {
                guard !currentTrimmed.isEmpty else { return false }
                guard let lastEdit = viewModel.lastUserEditAt else { return false }
                return Date().timeIntervalSince(lastEdit) < userEditWindow
            }()
            if isProtected { return }

            viewModel.inputText = clipboardContent
            viewModel.clearUserEditMark()
            viewModel.performSelectedAction()
        }

        private func executeTranslation() {
            let trimmedText = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }
            viewModel.inputText = trimmedText
            viewModel.performSelectedAction()
        }

        /// Hand off the current input / selected action / translation results to
        /// the main window's HomeView, then bring the main window to the front.
        private func openInMainApp() {
            let snapshot = viewModel.captureStateSnapshot()
            onClose()
            AppDelegate.shared?.openMainWindow()
            // Post after a tick so the main HomeView has mounted (cold launch case)
            // and its `.onReceive(.homeStateHandoff)` subscription is active.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(
                    name: .homeStateHandoff,
                    object: nil,
                    userInfo: ["snapshot": snapshot]
                )
            }
        }

        // MARK: - Header Section

        private var headerSection: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Quick Translate")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(colors.textPrimary)

                    Spacer()

                    Button {
                        openInMainApp()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "macwindow.on.rectangle")
                                .font(.system(size: 12))
                            Text("Open Main App")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .tlingoGlassCapsule(
                            tint: colors.accent.opacity(0.10),
                            interactive: true,
                            fallbackTint: colors.cardBackground.opacity(0.72),
                            fallbackStroke: colors.divider
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open current translation in the main app window")

                    Menu {
                        ForEach(MenuBarAction.availableCases, id: \.self) { action in
                            if action.startsSection {
                                Divider()
                            }

                            Button(role: action == .quit ? .destructive : nil) {
                                MenuBarManager.shared.perform(action)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(colors.textSecondary)
                            .frame(width: 30, height: 30)
                            .tlingoGlassCircle(.control, interactive: true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                if !isHotkeyConfigured && showHotkeyHint {
                    hotkeyHintView
                }
            }
        }

        private var hotkeyHintView: some View {
            HStack(spacing: 4) {
                Image(systemName: "keyboard")
                    .font(.system(size: 10))
                    .foregroundColor(colors.textSecondary.opacity(0.8))

                Text("Set a shortcut in Settings → Hotkeys")
                    .font(.system(size: 11))
                    .foregroundColor(colors.textSecondary.opacity(0.8))

                Spacer()

                Button {
                    showHotkeyHint = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(colors.textSecondary.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .tlingoGlassCircle(
                            tint: colors.cardBackground.opacity(colorScheme == .dark ? 0.08 : 0.12),
                            interactive: true,
                            fallbackTint: colors.cardBackground.opacity(0.52),
                            fallbackStroke: Color.clear
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .tlingoGlassCapsule(
                tint: colors.accent.opacity(0.08),
                fallbackTint: colors.cardBackground.opacity(0.58),
                fallbackStroke: colors.divider.opacity(0.8)
            )
            .padding(.top, 4)
        }

        // MARK: - Input Section

        private var inputSection: some View {
            VStack(spacing: 8) {
                SelectableTextEditor(
                    text: $viewModel.inputText,
                    textColor: colors.textPrimary,
                    onUserEdit: { viewModel.markUserEditedInput() },
                    onSwapLanguages: { viewModel.swapInputLanguages() }
                )
                .font(.system(size: 13))
                .frame(height: 60)
                .padding(8)
                .background(inputSectionBackground)

                HStack(spacing: 8) {
                    LanguageSwitcherView(
                        globeFont: .system(size: 10),
                        textFont: .system(size: 11, weight: .medium),
                        chevronFont: .system(size: 7),
                        foregroundColor: colors.textSecondary.opacity(0.7),
                        languageDependencies: viewModel.selectedAction?.languageDependencies ?? .none,
                        resolvedTarget: viewModel.resolvedTargetLanguage,
                        onOverrideTarget: { viewModel.overrideTargetLanguage($0) },
                        detectedSource: viewModel.detectedSourceLanguage,
                        onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
                    )

                    Spacer()

                    inputSpeakButton

                    let canTranslate = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        executeTranslation()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 12))
                            Text("Send")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(canTranslate ? .white : colors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .tlingoGlassCapsule(canTranslate ? .prominent : .control, interactive: canTranslate)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canTranslate)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
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
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.isSpeakingInputText ? colors.error : colors.accent)
                    .frame(width: 28, height: 28)
                    .tlingoGlassCircle(
                        tint: (viewModel.isSpeakingInputText ? colors.error : colors.accent).opacity(0.10),
                        interactive: hasText || viewModel.isSpeakingInputText,
                        fallbackTint: colors.cardBackground.opacity(0.54),
                        fallbackStroke: colors.divider
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasText && !viewModel.isSpeakingInputText)
            .help(viewModel.isSpeakingInputText ? "Stop speaking" : "Speak input text")
        }

        // MARK: - Action Chips

        private var actionChips: some View {
            ActionChipsView(
                actions: viewModel.actions,
                selectedActionID: viewModel.selectedAction?.id,
                spacing: 8,
                font: .system(size: 13, weight: .medium),
                textColor: { isSelected in
                    chipTextColor(isSelected: isSelected)
                },
                background: { isSelected in
                    chipBackground(isSelected: isSelected)
                },
                horizontalPadding: 14,
                verticalPadding: 8
            ) { action in
                if viewModel.selectAction(action) {
                    viewModel.performSelectedAction()
                }
            }
        }

        // MARK: - Result Section

        private var resultSection: some View {
            HomeView(
                viewModel: viewModel,
                showsOnlyResults: true,
                onResultConversation: { session in
                    activeConversationSession = session
                }
            )
        }

        // MARK: - Liquid Glass Backgrounds

        private func chipTextColor(isSelected: Bool) -> Color {
            return isSelected ? .white : colors.textPrimary
        }

        @ViewBuilder
        private var inputSectionBackground: some View {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.inputBackground.opacity(colorScheme == .dark ? 0.78 : 0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(colors.divider, lineWidth: 1)
                )
        }

        @ViewBuilder
        private func chipBackground(isSelected: Bool) -> some View {
            Color.clear
                .tlingoGlassCapsule(isSelected ? .prominent : .control, interactive: true)
        }
    }

    // MARK: - SelectableTextEditor

    /// A custom TextEditor wrapper that ensures selected text is always readable
    /// by setting high-contrast selection colors.
    private struct SelectableTextEditor: NSViewRepresentable {
        @Binding var text: String
        let textColor: Color
        var onUserEdit: () -> Void = {}
        var onSwapLanguages: (() -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = LanguageSwapTextView()
            textView.onSwapLanguages = onSwapLanguages
            textView.languageShortcutContext = "quickTranslate"
            textView.delegate = context.coordinator
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.textContainer?.lineFragmentPadding = 0
            textView.font = NSFont.systemFont(ofSize: 13)
            textView.textColor = NSColor(textColor)
            textView.insertionPointColor = NSColor(textColor)
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.string = text

            textView.selectedTextAttributes = [
                .backgroundColor: NSColor.controlAccentColor,
                .foregroundColor: NSColor.white,
            ]

            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.contentView.drawsBackground = false
            scrollView.documentView = textView

            // Make the text view first responder via AppKit after the view is installed
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }

            context.coordinator.textView = textView

            return scrollView
        }

        func updateNSView(_ nsView: NSScrollView, context _: Context) {
            guard let textView = nsView.documentView as? LanguageSwapTextView else { return }
            textView.onSwapLanguages = onSwapLanguages
            if textView.string != text {
                textView.string = text
            }
            textView.textColor = NSColor(textColor)
            textView.insertionPointColor = NSColor(textColor)
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            private let parent: SelectableTextEditor
            private var eventMonitor: Any?
            weak var textView: NSTextView?

            init(parent: SelectableTextEditor) {
                self.parent = parent
                super.init()
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 48,
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                          let textView = self?.textView,
                          textView.window?.isKeyWindow == true,
                          textView.window?.firstResponder === textView,
                          !textView.hasMarkedText(),
                          let onSwapLanguages = (textView as? LanguageSwapTextView)?.onSwapLanguages
                    else {
                        return event
                    }
                    languageShortcutLogger.notice(
                        "Tab consumed by popover monitor context=quickTranslate"
                    )
                    onSwapLanguages()
                    return nil
                }
            }

            deinit {
                if let eventMonitor {
                    NSEvent.removeMonitor(eventMonitor)
                }
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                let updated = textView.string
                if parent.text != updated {
                    parent.text = updated
                    parent.onUserEdit()
                }
            }
        }
    }

#endif
