//
//  HomeView+InputAndChrome.swift
//  TLingo
//

import os
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HomeView")

extension HomeView {
    var header: some View {
        HStack {
            #if !os(macOS)
                if let onShowSidebarTap {
                    Button(action: onShowSidebarTap) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 20))
                            .foregroundColor(colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show Sidebar")
                    .accessibilityIdentifier("ipad_show_sidebar_button")
                }
            #endif

            Text("TLingo")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(colors.textPrimary)
            Spacer()
            #if !os(macOS)
                HStack(spacing: 18) {
                    if let onHistoryTap {
                        Button(action: onHistoryTap) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 20))
                                .foregroundColor(colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("History")
                        .accessibilityIdentifier("home_history_button")
                    }

                    if let onSettingsTap {
                        Button(action: onSettingsTap) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 20))
                                .foregroundColor(colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("tab_settings")
                    }
                }
            #endif
        }
    }

    @ViewBuilder
    var topLanguageSelector: some View {
        if shouldShowLanguageSelectorAboveInput {
            let languageDependencies = viewModel.selectedAction?.languageDependencies ?? .none

            HStack {
                if languageDependencies.usesSourceLanguage || !languageDependencies.usesTargetLanguage {
                    Spacer(minLength: 0)
                }
                LanguageSwitcherView(
                    globeFont: .system(size: 13),
                    textFont: .system(size: 15, weight: .semibold),
                    chevronFont: .system(size: 8, weight: .semibold),
                    foregroundColor: colors.textPrimary,
                    showsControlBackgrounds: false,
                    languageDependencies: languageDependencies,
                    resolvedTarget: viewModel.resolvedTargetLanguage,
                    onOverrideTarget: { viewModel.overrideTargetLanguage($0) },
                    detectedSource: viewModel.detectedSourceLanguage,
                    suggestedSources: viewModel.suggestedSourceLanguages,
                    suggestedSourceOverride: viewModel.sourceLanguageOverride,
                    onSuggestedSource: { viewModel.selectSuggestedSource($0) },
                    alternativeTarget: viewModel.alternativeTargetLanguage,
                    onAlternativeTarget: { viewModel.selectAlternativeTarget($0) },
                    hasTemporaryTarget: viewModel.hasCurrentTextTarget,
                    onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .tlingoGlassSurface(.chrome, cornerRadius: TLingoRadius.large)
        }
    }

    @ViewBuilder
    var inputComposerBackground: some View {
        #if os(macOS)
            // Solid card on the app ground, matching the design canvas.
            RoundedRectangle(cornerRadius: TLingoRadius.large, style: .continuous)
                .fill(colors.cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: TLingoRadius.large, style: .continuous)
                        .stroke(colors.divider, lineWidth: 1)
                }
        #else
            Color.clear
                .tlingoGlassSurface(.chrome, cornerRadius: TLingoRadius.large)
        #endif
    }

    var inputEditorMinHeight: CGFloat {
        usesBottomComposerLayout ? 44 : 140
    }

    var inputEditorMaxHeight: CGFloat {
        usesBottomComposerLayout ? 56 : 160
    }

    var inputComposerBottomPadding: CGFloat {
        usesBottomComposerLayout ? 42 : 48
    }

    func inputComposer(editorHeight: CGFloat? = nil) -> some View {
        let isCollapsed = openFromExtension && !isInputExpanded

        return ZStack {
            inputComposerBackground

            VStack(alignment: .leading, spacing: 0) {
                if isCollapsed {
                    collapsedInputSummary
                } else {
                    expandedInputEditor(editorHeight: editorHeight)
                }

                if !isCollapsed {
                    Spacer(minLength: 0)
                }
            }
            .padding(.bottom, isCollapsed ? 0 : inputComposerBottomPadding)

            VStack {
                Spacer()
                inputComposerControls(isCollapsed: isCollapsed)
                    .padding(.horizontal, 16)
                    .padding(.bottom, isCollapsed ? 0 : 12)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: isInputExpanded)
        .animation(.easeInOut(duration: 0.25), value: viewModel.resolvedTargetLanguage)
    }

    @ViewBuilder
    func inputComposerControls(isCollapsed: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                inputComposerControlsContent(isCollapsed: isCollapsed)
            }
        } else {
            inputComposerControlsContent(isCollapsed: isCollapsed)
        }
    }

    func inputComposerControlsContent(isCollapsed: Bool) -> some View {
        HStack {
            if openFromExtension && !isCollapsed {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isInputExpanded = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Collapse")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .tlingoGlassCapsule(.control, interactive: true)
                }
                .buttonStyle(.plain)
                .foregroundColor(colors.textSecondary)
            }

            if !isCollapsed {
                if shouldShowLanguageSelectorInsideInput {
                    LanguageSwitcherView(
                        globeFont: .system(size: 12),
                        textFont: .system(size: 13, weight: .medium),
                        foregroundColor: colors.accent,
                        languageDependencies: viewModel.selectedAction?.languageDependencies ?? .none,
                        resolvedTarget: viewModel.resolvedTargetLanguage,
                        onOverrideTarget: { viewModel.overrideTargetLanguage($0) },
                        detectedSource: viewModel.detectedSourceLanguage,
                        suggestedSources: viewModel.suggestedSourceLanguages,
                        suggestedSourceOverride: viewModel.sourceLanguageOverride,
                        onSuggestedSource: { viewModel.selectSuggestedSource($0) },
                        alternativeTarget: viewModel.alternativeTargetLanguage,
                        onAlternativeTarget: { viewModel.selectAlternativeTarget($0) },
                        hasTemporaryTarget: viewModel.hasCurrentTextTarget,
                        onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
                    )
                }

                #if os(iOS)
                    if usesPhoneComposerChrome {
                        modelSelectionButton
                        Spacer()
                        if viewModel.selectedAction?.languageDependencies.usesTargetLanguage == true,
                           let alternative = viewModel.alternativeTargetLanguage
                        {
                            Button {
                                viewModel.selectAlternativeTarget(alternative)
                            } label: {
                                Text("Translate to \(alternative.primaryLabel)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(colors.accent)
                            .accessibilityLabel(Text("Translate to \(alternative.primaryLabel)"))
                            .accessibilityIdentifier("language_switcher_alternative_target")
                        }
                        imageTextInputButton
                        inputSpeakButton
                        phonePrimaryInputButton
                    } else {
                        defaultInputTrailingControls
                    }
                #else
                    defaultInputTrailingControls
                #endif
            }
        }
    }

    @ViewBuilder
    var defaultInputTrailingControls: some View {
        Spacer()

        if shouldShowModelSelectionInsideInput {
            modelSelectionButton
        }

        #if os(iOS)
            imageTextInputButton
        #endif
        inputSpeakButton
        inputSendButton
    }

    var modelSelectionButton: some View {
        Button {
            showModelSelectionSheet = true
        } label: {
            modelSelectionButtonLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Models")
        .accessibilityIdentifier("home_model_picker")
    }

    var resultOrderPicker: some View {
        Picker("Result Order", selection: Binding(
            get: { preferences.modelResultOrder },
            set: { preferences.setModelResultOrder($0) }
        )) {
            ForEach(ModelResultOrder.allCases, id: \.self) { order in
                Text(order.title).tag(order)
            }
        }
        // Lists the options directly in the enclosing menu instead of a nested submenu.
        .pickerStyle(.inline)
    }

    var resultOrderMenu: some View {
        Menu {
            resultOptionsMenuContent(showsResultOrder: true)
        } label: {
            Label("Result Options", systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("home_result_order")
        .accessibilityValue(preferences.modelResultOrder.title)
    }

    /// Result preferences offered next to the results; they mirror the Translation settings.
    @ViewBuilder
    func resultOptionsMenuContent(showsResultOrder: Bool) -> some View {
        if showsResultOrder {
            resultOrderPicker
        }
        Section {
            Toggle("Look Up Single Words", isOn: Binding(
                get: { preferences.wordLookupEnabled },
                set: { preferences.setWordLookupEnabled($0) }
            ))
            Toggle("Sentence by Sentence by Default", isOn: Binding(
                get: { preferences.defaultsToSentencePairs },
                set: { preferences.setDefaultsToSentencePairs($0) }
            ))
        }
    }

    @ViewBuilder
    var modelSelectionButtonLabel: some View {
        #if os(macOS)
            HStack(spacing: 5) {
                Text(modelSelectionTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundColor(colors.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .tlingoGlassCapsule(.control, interactive: true)
            .frame(maxWidth: 200, alignment: .trailing)
        #else
            modelSelectionButtonLegacyLabel
        #endif
    }

    var modelSelectionButtonLegacyLabel: some View {
        HStack(spacing: 5) {
            // Lead with the icon and name the model, so the label says which one is used.
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colors.textSecondary)
            Text(modelSelectionTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.65)
        }
        .foregroundColor(colors.textPrimary)
        .frame(width: usesPhoneComposerChrome ? nil : 170, alignment: .trailing)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }

    var shouldShowModelSelectionInsideInput: Bool {
        #if os(macOS)
            return true
        #else
            return usesSimplifiedTextLayout
        #endif
    }

    var modelSelectionTitle: String {
        let selected = selectedDisplayModels
        guard !selected.isEmpty else {
            return String(localized: "Models")
        }
        return selected.count == 1 ? selected[0].displayName : "\(selected[0].displayName) +\(selected.count - 1)"
    }

    func presentPendingPremiumIfNeeded() {
        guard pendingPremiumPresentation else { return }
        pendingPremiumPresentation = false
        onPremiumRequired?()
    }

    func presentConversation(_ session: ConversationSession) {
        if showsOnlyResults {
            onResultConversation?(session)
            return
        }
        activeConversationSession = session
        isConversationInspectorPresented = usesConversationInspectorPresentation
    }

    func toggleConversationInspector() {
        guard activeConversationSession != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isConversationInspectorPresented.toggle()
        }
    }

    var conversationInspectorToggleButton: some View {
        let isPresented = activeConversationSession != nil && isConversationInspectorPresented

        return Button {
            toggleConversationInspector()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(isPresented ? "Hide Conversation Inspector" : "Show Conversation Inspector")
        .accessibilityLabel(isPresented ? "Hide Conversation Inspector" : "Show Conversation Inspector")
        .accessibilityIdentifier("home_conversation_inspector_toggle")
    }

    var selectedDisplayModels: [ModelConfig] {
        viewModel.selectedDisplayModels(
            enabledIDs: preferences.enabledModelIDs,
            isPro: entitlement.isPro || HomeViewModel.isSnapshotMode
        )
    }

    var inputSendButton: some View {
        Button(action: performInputActionIfPossible) {
            inputSendButtonLabel
        }
        .buttonStyle(inputSendButtonStyle)
        #if !os(macOS)
            .tint(colors.accent)
        #endif
            .disabled(!viewModel.canSend)
            .opacity(viewModel.canSend ? 1.0 : 0.5)
    }

    @ViewBuilder
    var inputSendButtonLabel: some View {
        #if os(macOS)
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(viewModel.canSend ? colors.onAccent : colors.textSecondary.opacity(0.45))
                .frame(width: 32, height: 32)
                .tlingoGlassCircle(viewModel.canSend ? .prominent : .control, interactive: viewModel.canSend)
        #else
            HStack(spacing: 6) {
                Text("Send")
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
        #endif
    }

    var inputSendButtonStyle: some PrimitiveButtonStyle {
        #if os(macOS)
            return .plain
        #else
            return .glassProminent
        #endif
    }

    @ViewBuilder
    var inputSpeakButton: some View {
        let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasText || viewModel.isSpeakingInputText {
            Button {
                if viewModel.isSpeakingInputText {
                    viewModel.stopSpeaking()
                } else {
                    viewModel.speakInputText()
                }
            } label: {
                if viewModel.isSpeakingInputText {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                }
            }
            .buttonStyle(.glass)
            .tint(viewModel.isSpeakingInputText ? colors.error : colors.textPrimary)
            .buttonBorderShape(.circle)
        }
    }

    var collapsedInputSummary: some View {
        let displayText = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isInputExpanded = true
            }
        } label: {
            HStack(spacing: 12) {
                Text(displayText.isEmpty ? viewModel.inputPlaceholder : displayText)
                    .font(.system(size: 15))
                    .foregroundColor(displayText.isEmpty ? colors.textSecondary : colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .tlingoGlassSurface(.control, cornerRadius: TLingoRadius.medium, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func expandedInputEditor(editorHeight: CGFloat? = nil) -> some View {
        let contentHeightChangeHandler: ((CGFloat) -> Void)? = usesBottomComposerLayout ? { height in
            updateBottomComposerEditorContentHeight(height)
        } : nil

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                #if !os(macOS)
                    if viewModel.inputText.isEmpty {
                        Text(viewModel.inputPlaceholder)
                            .foregroundColor(colors.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                    }
                #endif

                #if os(macOS)
                    AutoPasteTextEditor(
                        text: $viewModel.inputText,
                        placeholder: viewModel.inputPlaceholder,
                        onPaste: { pastedText in
                            applyPastedTextIfNeeded(pastedText)
                        },
                        onImagePaste: { _ in },
                        onContentHeightChange: contentHeightChangeHandler,
                        onSubmit: performInputActionIfPossible,
                        onSwapLanguages: { viewModel.swapInputLanguages() }
                    )
                    .frame(minHeight: editorHeight ?? inputEditorMinHeight, maxHeight: editorHeight ?? inputEditorMaxHeight)
                    .padding(12)
                #else
                    AutoPasteTextEditor(
                        text: $viewModel.inputText,
                        placeholder: viewModel.inputPlaceholder,
                        onPaste: { pastedText in
                            applyPastedTextIfNeeded(pastedText)
                        },
                        onImagePaste: { _ in },
                        onContentHeightChange: contentHeightChangeHandler,
                        onSubmit: performInputActionIfPossible,
                        onSwapLanguages: { viewModel.swapInputLanguages() }
                    )
                    .frame(minHeight: editorHeight ?? inputEditorMinHeight, maxHeight: editorHeight ?? inputEditorMaxHeight)
                    .padding(12)
                    .padding(.trailing, usesPhoneComposerChrome ? 24 : 0)
                    .overlay(alignment: .topTrailing) {
                        if usesPhoneComposerChrome, !viewModel.inputText.isEmpty {
                            clearInputButton
                        }
                    }
                #endif
            }
        }
    }

    #if os(iOS)

        // MARK: - iPhone chrome

        var navigationBarLanguageSelector: some View {
            LanguageSwitcherView(
                globeFont: .system(size: 13),
                textFont: .system(size: 16, weight: .semibold),
                chevronFont: .system(size: 9, weight: .semibold),
                foregroundColor: colors.textPrimary,
                showsControlBackgrounds: false,
                languageDependencies: viewModel.selectedAction?.languageDependencies ?? .none,
                resolvedTarget: viewModel.resolvedTargetLanguage,
                onOverrideTarget: { viewModel.overrideTargetLanguage($0) },
                detectedSource: viewModel.detectedSourceLanguage,
                suggestedSources: viewModel.suggestedSourceLanguages,
                suggestedSourceOverride: viewModel.sourceLanguageOverride,
                onSuggestedSource: { viewModel.selectSuggestedSource($0) },
                hasTemporaryTarget: viewModel.hasCurrentTextTarget,
                onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
            )
        }

        @ViewBuilder
        var phoneSettingsButton: some View {
            if let onSettingsTap {
                Button("Settings", systemImage: "gearshape", action: onSettingsTap)
                    .tint(.primary)
                    .accessibilityIdentifier("tab_settings")
            }
        }

        /// Main app only, and only while the input is empty so it never competes with speak and send.
        @ViewBuilder
        var imageTextInputButton: some View {
            if context == nil, viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ImageTextInputButton(tint: colors.textPrimary) { text in
                    viewModel.inputText = text
                    isInputExpanded = true
                }
            }
        }

        var clearInputButton: some View {
            Button {
                viewModel.inputText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(colors.textSecondary.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.trailing, 8)
            .accessibilityLabel("Clear Text")
            .accessibilityIdentifier("home_clear_input_button")
        }

        /// The input's trailing slot, like Messages: voice while empty, send once text exists.
        /// Sending the same text again re-runs it; per-result retry lives on each result row.
        @ViewBuilder
        var phonePrimaryInputButton: some View {
            let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if !hasText, let onRealtimeTap {
                Button {
                    hasUsedRealtimeButton = true
                    onRealtimeTap()
                } label: {
                    if hasUsedRealtimeButton {
                        phonePrimaryInputButtonIcon("waveform")
                    } else {
                        Label("Live Translate", systemImage: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(height: 22)
                    }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(hasUsedRealtimeButton ? .circle : .capsule)
                .tint(colors.accent)
                .accessibilityLabel("Realtime Translation")
                .accessibilityIdentifier("home_realtime_button")
            } else {
                Button(action: performInputActionIfPossible) {
                    phonePrimaryInputButtonIcon("arrow.up")
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(colors.accent)
                .disabled(!viewModel.canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("home_send_button")
            }
        }

        func phonePrimaryInputButtonIcon(_ systemName: String) -> some View {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 22, height: 22)
        }

        /// Empty Home offers a way to continue: the latest translations and the clipboard.
        var phoneEmptyStateSuggestions: some View {
            VStack(alignment: .leading, spacing: 10) {
                if !recentTextRecords.isEmpty {
                    HStack {
                        Text("Recent")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colors.textSecondary)
                        Spacer()
                        if let onHistoryTap {
                            Button("Show All", action: onHistoryTap)
                                .font(.subheadline)
                                .accessibilityIdentifier("home_recent_show_all")
                        }
                    }
                    .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(recentTextRecords) { record in
                            if record.id != recentTextRecords.first?.id {
                                Divider()
                                    .padding(.leading, 16)
                            }
                            Button {
                                viewModel.inputText = record.sourceText
                                isInputExpanded = true
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.sourceText)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(colors.textPrimary)
                                    if let result = record.resultText {
                                        Text(result)
                                            .font(.subheadline)
                                            .foregroundStyle(colors.textSecondary)
                                    }
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(
                        colors.cardBackground,
                        in: RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                    )
                }

                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty
                    else { return }
                    Task { @MainActor in
                        viewModel.inputText = text
                        isInputExpanded = true
                        performInputActionIfPossible()
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            // `.task` runs after the first frame commits, so opening the history store doesn't delay launch.
            .task { refreshRecentTextRecords() }
            .onReceive(NotificationCenter.default.publisher(for: .translationRecordSaved)) { _ in
                refreshRecentTextRecords()
            }
        }

        func refreshRecentTextRecords() {
            let pageSize = 20
            // Repeated lookups of the same text show once.
            var seen = Set<String>()
            var recents: [HomeRecentRecord] = []
            var offset = 0
            pages: while offset < 500 {
                let records = TranslationHistoryService.shared.fetchTextRecords(offset: offset, limit: pageSize)
                for record in records {
                    let recent = HomeRecentRecord(record)
                    guard seen.insert(recent.sourceText).inserted else { continue }
                    recents.append(recent)
                    if recents.count == 3 {
                        break pages
                    }
                }
                guard records.count == pageSize else { break }
                offset += pageSize
            }
            if recents != recentTextRecords {
                recentTextRecords = recents
            }
        }

        var shouldShowMatchFallbackHint: Bool {
            usesPhoneComposerChrome
                && viewModel.isMatchTargetFallback
                && viewModel.selectedAction?.languageDependencies.usesTargetLanguage == true
        }

        /// Explains why the automatic target skipped the first language, with a one-tap override.
        func matchFallbackHint(source: SourceLanguageOption, target: TargetLanguageOption) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("Source is \(source.primaryLabel), translating to \(target.primaryLabel)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                Button {
                    isFallbackTargetPickerPresented = true
                } label: {
                    HStack(spacing: 3) {
                        Text("Change")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(colors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home_match_fallback_change")
                .sheet(isPresented: $isFallbackTargetPickerPresented) {
                    LanguagePickerView(
                        selectedCode: Binding(
                            get: { target.rawValue },
                            set: { code in
                                guard let option = TargetLanguageOption(rawValue: code), option != target else { return }
                                viewModel.overrideTargetLanguage(option)
                            }
                        ),
                        isPresented: $isFallbackTargetPickerPresented,
                        availableOptions: TargetLanguageOption.selectionOptions.filter { $0 != .appLanguage }
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            .font(.system(size: 13))
            .foregroundColor(colors.textSecondary)
            .padding(.horizontal, 4)
        }
    #endif

    var wordLookupFallbackHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
            Text("Switched to word lookup")

            Spacer(minLength: 8)

            Menu {
                resultOptionsMenuContent(showsResultOrder: viewModel.modelRuns.count > 1)
            } label: {
                HStack(spacing: 3) {
                    Text("Result Options")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(colors.accent)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .accessibilityIdentifier("home_word_lookup_options")
        }
        .font(.system(size: 13))
        .foregroundColor(colors.textSecondary)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("home_word_lookup_fallback_hint")
    }
}
