//
//  OnboardingStepTextSelectionTrial.swift
//  TLingo
//
//  Try TLingo's text selection translation flow.
//

#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    enum OnboardingTrialMode: Equatable {
        case translation
        case polish
    }

    struct OnboardingStepTextSelectionTrial: View {
        private enum GuidanceStep: Equatable {
            case selectText
            case moveToTrigger
            case clickAction
            case completed
        }

        @ObservedObject private var preferences = AppPreferences.shared
        @Binding var isCompleted: Bool
        let mode: OnboardingTrialMode
        let trialModels: [ModelConfig]
        @State private var sampleText = ""
        @State private var guidanceStep = GuidanceStep.selectText

        let colors: AppColorPalette

        init(
            mode: OnboardingTrialMode = .translation,
            isCompleted: Binding<Bool>,
            trialModels: [ModelConfig] = [],
            colors: AppColorPalette
        ) {
            self.mode = mode
            _isCompleted = isCompleted
            self.trialModels = trialModels
            self.colors = colors
        }

        var body: some View {
            VStack(spacing: 16) {
                OnboardingStepHeader(
                    systemImage: nil,
                    iconColor: colors.accent,
                    title: title,
                    subtitle: guidanceInstruction,
                    colors: colors
                )

                OnboardingSelectionTextEditor(text: $sampleText) { hasSelection in
                    updateTrigger(hasSelection: hasSelection)
                }
                    .padding(10)
                    .frame(height: 92)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colors.cardBackground)
                    )

                Spacer(minLength: 0)
            }
            .onAppear {
                if sampleText.isEmpty {
                    sampleText = trialSampleText
                }
                if isCompleted {
                    guidanceStep = .completed
                }
                configureGuidanceCallbacks()
            }
            .onDisappear {
                clearGuidanceCallbacks()
                dismissTrigger()
            }
            .overlay {
                if guidanceStep == .completed {
                    CelebrationOverlay(
                        colors: colors,
                        title: "Nice!",
                        subtitle: completionSubtitle
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }

        private func updateTrigger(hasSelection: Bool) {
            if hasSelection {
                advanceGuidance(to: .moveToTrigger)
            } else if guidanceStep != .completed {
                advanceGuidance(to: .selectText)
            }

            Task { @MainActor in
                if hasSelection {
                    AppDelegate.shared?.showSelectionTrigger(near: NSEvent.mouseLocation)
                } else {
                    AppDelegate.shared?.dismissSelectionTrigger()
                }
            }
        }

        private func dismissTrigger() {
            Task { @MainActor in
                AppDelegate.shared?.dismissSelectionTrigger()
            }
        }

        private func configureGuidanceCallbacks() {
            AppDelegate.shared?.setSelectionTrialCallbacks(
                actionName: actionName,
                trialModels: trialModels,
                onTriggerHovered: {
                    advanceGuidance(to: .clickAction)
                },
                onTranslationSucceeded: {
                    advanceGuidance(to: .completed)
                    isCompleted = true
                }
            )
        }

        private func clearGuidanceCallbacks() {
            AppDelegate.shared?.clearSelectionTrialCallbacks()
        }

        private func advanceGuidance(to step: GuidanceStep) {
            guard guidanceStep != .completed else { return }
            guard guidanceStep != step else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                guidanceStep = step
            }
        }

        private var trialSampleText: String {
            if mode == .polish {
                return "Please make this message clearer and more natural."
            }

            let target = preferences.targetLanguage == .appLanguage
                ? TargetLanguageOption.appLanguageIdentifier
                : preferences.targetLanguage.rawValue
            let languageCode = Locale.Language.Components(identifier: target).languageCode?.identifier
            return languageCode == "en"
                ? "好的工具会融入工作本身。"
                : "Good tools disappear into the work."
        }

        private var title: LocalizedStringKey {
            mode == .polish ? "Make your writing clearer" : "Translate without switching apps"
        }

        private var actionName: String? {
            mode == .polish ? "Polish" : nil
        }

        private var guidanceInstruction: LocalizedStringKey {
            switch guidanceStep {
            case .selectText:
                return "1. Select a sentence"
            case .moveToTrigger:
                return "2. Move to the blue dot"
            case .clickAction:
                return mode == .polish ? "3. Choose Polish" : "3. Choose Translate"
            case .completed:
                return completionSubtitle
            }
        }

        private var completionSubtitle: LocalizedStringKey {
            mode == .polish
                ? "Your writing is now clearer with TLingo."
                : "You just translated the selected text without switching apps."
        }
    }

    private struct OnboardingSelectionTextEditor: NSViewRepresentable {
        @Binding var text: String
        let onSelectionChanged: (Bool) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = NSTextView()
            textView.delegate = context.coordinator
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainer?.lineFragmentPadding = 0
            textView.font = NSFont.systemFont(ofSize: 14)
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.string = text

            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.contentView.drawsBackground = false
            scrollView.documentView = textView
            return scrollView
        }

        func updateNSView(_ nsView: NSScrollView, context _: Context) {
            guard let textView = nsView.documentView as? NSTextView else { return }
            if textView.string != text {
                textView.string = text
            }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            private let parent: OnboardingSelectionTextEditor

            init(parent: OnboardingSelectionTextEditor) {
                self.parent = parent
                super.init()
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                if parent.text != textView.string {
                    parent.text = textView.string
                }
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                parent.onSelectionChanged(textView.selectedRange.length > 0)
            }
        }
    }
#endif
