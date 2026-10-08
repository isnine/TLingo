//
//  HomeView.swift
//  TLingo
//
//  Created by Zander Wang on 2025/10/19.
//

import os
import StoreKit
import SwiftStreamingMarkdown
import SwiftUI

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HomeView")
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif
#if os(iOS) && !targetEnvironment(macCatalyst)
    import TranslationUIProvider
#endif
import UniformTypeIdentifiers
import WebKit
#if canImport(Translation)
    import Translation
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
    public typealias AppTranslationContext = TranslationUIProviderContext
#else
    public typealias AppTranslationContext = Never
#endif

public struct HomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.requestReview) private var requestReview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @StateObject private var viewModel: HomeViewModel
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var entitlement = Entitlement.shared
    @State private var hasTriggeredAutoRequest = false
    @State private var isInputExpanded: Bool
    @State private var showingProviderInfo: String?
    @State private var activeConversationSession: ConversationSession?
    @State private var isConversationInspectorPresented = false
    @State private var showSatisfactionToast = false
    @State private var showModelSelectionSheet = false
    @State private var showAIModelRequiredAlert = false
    @State private var feedbackDraft: FeedbackMailDraft?
    @State private var pendingPremiumPresentation = false
    @State private var bottomComposerActionChipsHeight: CGFloat = 0
    @State private var bottomComposerLanguageSelectorHeight: CGFloat = 0
    @State private var bottomComposerWordLookupHintHeight: CGFloat = 0
    @State private var bottomComposerEditorContentHeight: CGFloat = 0
    @State private var isComparingResults = false
    /// Settled content height per result row, and the height held while a row reloads,
    /// so switching to sentence pairs never collapses the row before new content streams in.
    @State private var resultContentHeights: [String: CGFloat] = [:]
    @State private var heldResultHeights: [String: CGFloat] = [:]
    /// Flat panel and its collapsed preview block, measured to size previews to the visible area.
    @State private var flatResultsPanelHeight: CGFloat = 0
    @State private var collapsedResultsSize: CGSize = .zero
    #if os(iOS)
        @State private var selectedResult: SelectedResult?
        @State private var resultDetailDetent: PresentationDetent = .medium
    #endif
    #if canImport(Translation)
        @State private var appleTranslationConfig: TranslationSession.Configuration?
        @State private var appleTranslationConfigLanguagePair: (source: String?, target: String)?
    #endif
    #if os(macOS)
        @State private var showDataConsent = false
    #endif
    @Namespace private var chipNamespace

    private var usesConversationInspectorPresentation: Bool {
        #if os(macOS)
            return true
        #elseif os(iOS)
            return usesNativeNavigationChrome && horizontalSizeClass == .regular
        #else
            return false
        #endif
    }

    private var usesNativeNavigationChrome: Bool {
        #if os(iOS)
            return usesNativeNavigationHeader && !openFromExtension
        #else
            return false
        #endif
    }

    private var isConversationInspectorVisible: Bool {
        usesConversationInspectorPresentation
            && activeConversationSession != nil
            && isConversationInspectorPresented
    }

    private var conversationInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                isConversationInspectorVisible
            },
            set: { newValue in
                isConversationInspectorPresented = newValue
            }
        )
    }

    #if os(iOS)
        private var conversationSheetBinding: Binding<ConversationSession?> {
            Binding(
                get: {
                    usesConversationInspectorPresentation ? nil : activeConversationSession
                },
                set: { newValue in
                    activeConversationSession = newValue
                }
            )
        }
    #endif

    var openFromExtension: Bool {
        #if os(iOS)
            return context != nil
        #else
            return false
        #endif
    }

    private var usesSimplifiedTextLayout: Bool {
        #if os(iOS)
            return !openFromExtension
        #else
            return false
        #endif
    }

    private var usesBottomComposerLayout: Bool {
        HomeTextLayoutPolicy.usesBottomComposerLayout(
            openFromExtension: openFromExtension,
            idiom: currentTextLayoutIdiom
        )
    }

    private var satisfactionPromptPlacement: HomeSatisfactionPromptPlacement {
        HomeTextLayoutPolicy.satisfactionPromptPlacement(
            usesBottomComposerLayout: usesBottomComposerLayout,
            hasResults: !viewModel.modelRuns.isEmpty,
            openFromExtension: openFromExtension
        )
    }

    private var satisfactionPromptChrome: HomeSatisfactionPromptChrome {
        HomeTextLayoutPolicy.satisfactionPromptChrome(for: satisfactionPromptPlacement)
    }

    private var shouldShowSatisfactionOverlay: Bool {
        showSatisfactionToast && satisfactionPromptChrome == .toast
    }

    private var shouldShowInlineSatisfactionPrompt: Bool {
        showSatisfactionToast && satisfactionPromptChrome == .resultCell
    }

    private var languageSelectorPlacement: HomeLanguageSelectorPlacement {
        HomeTextLayoutPolicy.languageSelectorPlacement(
            usesBottomComposerLayout: usesBottomComposerLayout,
            usesSimplifiedTextLayout: usesSimplifiedTextLayout,
            idiom: currentTextLayoutIdiom
        )
    }

    private var shouldShowLanguageSelectorAboveInput: Bool {
        languageSelectorPlacement == .aboveInput
    }

    private var shouldShowLanguageSelectorInsideInput: Bool {
        languageSelectorPlacement == .insideInput
    }

    private var bottomComposerPlacement: HomeBottomComposerPlacement {
        HomeTextLayoutPolicy.bottomComposerPlacement(
            usesBottomComposerLayout: usesBottomComposerLayout,
            hasResults: !viewModel.modelRuns.isEmpty,
            hasAttachments: false,
            idiom: currentTextLayoutIdiom
        )
    }

    private var shouldCenterEmptyComposer: Bool {
        bottomComposerPlacement == .centeredEmptyState
    }

    /// iPhone app chrome: language pair in the navigation bar, results as a flat panel,
    /// and the realtime entry sharing the send button slot.
    private var usesPhoneComposerChrome: Bool {
        usesNativeNavigationChrome && currentTextLayoutIdiom == .phone
    }

    /// iPhone and Mac show results as a flat panel with per-row sentence pairs; iPad keeps cards.
    private var usesFlatResultsPanel: Bool {
        #if os(macOS)
            return true
        #else
            return usesPhoneComposerChrome
        #endif
    }

    private var currentTextLayoutIdiom: HomeTextLayoutIdiom {
        #if os(macOS)
            return .mac
        #elseif os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #else
            return .phone
        #endif
    }

    /// Whether to show the "…" Manage Actions button at the end of the action chips.
    /// On macOS the sidebar no longer exposes an Actions tab, so Home is the entry
    /// point (mirroring iPhone). On iOS it follows the simplified text layout.
    private var showsManageActionsButton: Bool {
        #if os(macOS)
            return true
        #else
            return usesSimplifiedTextLayout && !usesPhoneComposerChrome
        #endif
    }

    private let context: AppTranslationContext?
    private let onHistoryTap: (() -> Void)?
    private let onManageActionsTap: (() -> Void)?
    private let onSettingsTap: (() -> Void)?
    private let onShowSidebarTap: (() -> Void)?
    private let onRealtimeTap: (() -> Void)?
    private let onPremiumRequired: (() -> Void)?
    private let usesNativeNavigationHeader: Bool
    private let showsOnlyResults: Bool
    private let onResultReplace: ((String) -> Void)?
    private let onResultConversation: ((ConversationSession) -> Void)?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    /// Hides the keyboard on iOS
    private func hideKeyboard() {
        #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private var initialContextInput: String? {
        #if os(iOS)
            guard let inputText = context?.inputText else { return nil }
            return String(inputText.characters)
        #else
            return nil
        #endif
    }

    public init(
        context: AppTranslationContext? = nil,
        usesNativeNavigationHeader: Bool = false,
        onHistoryTap: (() -> Void)? = nil,
        onManageActionsTap: (() -> Void)? = nil,
        onSettingsTap: (() -> Void)? = nil,
        onShowSidebarTap: (() -> Void)? = nil,
        onRealtimeTap: (() -> Void)? = nil,
        onPremiumRequired: (() -> Void)? = nil,
        viewModel: HomeViewModel? = nil,
        showsOnlyResults: Bool = false,
        onResultReplace: ((String) -> Void)? = nil,
        onResultConversation: ((ConversationSession) -> Void)? = nil
    ) {
        self.context = context
        self.showsOnlyResults = showsOnlyResults
        self.onResultReplace = onResultReplace
        self.onResultConversation = onResultConversation
        self.usesNativeNavigationHeader = usesNativeNavigationHeader
        self.onHistoryTap = onHistoryTap
        self.onManageActionsTap = onManageActionsTap
        self.onSettingsTap = onSettingsTap
        self.onShowSidebarTap = onShowSidebarTap
        self.onRealtimeTap = onRealtimeTap
        self.onPremiumRequired = onPremiumRequired
        // A host-owned model keeps input and results across layout switches.
        _viewModel = StateObject(wrappedValue: viewModel ?? HomeViewModel())
        #if os(iOS)
            _isInputExpanded = State(initialValue: context == nil)
        #else
            _isInputExpanded = State(initialValue: true)
        #endif
    }

    public var body: some View {
        if showsOnlyResults {
            embeddedResultsContent
        } else {
            fullHomeContent
        }
    }

    /// Compact hosts reuse the result UI while keeping input, consent and request routing in the host.
    private var embeddedResultsContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.isWordLookupFallback {
                        wordLookupFallbackHint
                    }
                    flatResultsPanel(viewportHeight: max(0, geometry.size.height - 24))
                }
                .padding(12)
            }
        }
        .onAppear {
            preferences.refreshFromDefaults()
        }
        .sheet(item: $viewModel.selectedDebugNetworkRecord) { record in
            NavigationStack {
                NetworkRequestDetailView(record: record)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 520)
            #endif
        }
    }

    private var fullHomeContent: some View {
        ZStack {
            homeContentLayout

            // Loading overlay when configuration is loading
            if viewModel.isLoadingConfiguration {
                configurationLoadingOverlay
            }

            if shouldShowSatisfactionOverlay {
                satisfactionPromptOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: satisfactionToastAlignment)
            }
        }
        .homeNavigationChrome(usesNativeNavigationHeader: usesNativeNavigationChrome, colors: colors)
        #if os(iOS)
        .toolbarVisibility(activeConversationSession == nil ? .automatic : .hidden, for: .tabBar)
        #endif
            .toolbar {
                #if os(macOS)
                    if activeConversationSession != nil {
                        ToolbarItem(placement: .primaryAction) {
                            conversationInspectorToggleButton
                        }
                    }
                #elseif os(iOS)
                    if usesPhoneComposerChrome {
                        if let onHistoryTap {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("History", systemImage: "clock.arrow.circlepath", action: onHistoryTap)
                                    .accessibilityIdentifier("home_history_button")
                            }
                        }
                        ToolbarItem(placement: .principal) {
                            navigationBarLanguageSelector
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            phoneSettingsButton
                        }
                    } else if usesNativeNavigationChrome {
                        ToolbarItem(placement: .topBarLeading) {
                            resultOrderMenu
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if let onHistoryTap {
                                Button("History", systemImage: "clock.arrow.circlepath", action: onHistoryTap)
                                    .accessibilityIdentifier("home_history_button")
                            }
                            if let onSettingsTap {
                                Button("Settings", systemImage: "gearshape", action: onSettingsTap)
                                    .accessibilityIdentifier("tab_settings")
                            }
                        }
                    }
                    if usesConversationInspectorPresentation, activeConversationSession != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            conversationInspectorToggleButton
                        }
                    }
                #endif
            }
        .overlay(alignment: .trailing) {
            if isConversationInspectorVisible {
                Rectangle()
                    .fill(colors.textSecondary.opacity(0.22))
                    .frame(width: 1)
                    .ignoresSafeArea(.all, edges: .vertical)
            }
        }
        #if os(iOS)
        .sheet(item: $selectedResult) { selectedResult in
            resultDetailSheet(for: selectedResult.id)
                .presentationDetents([.medium, .fraction(0.92)], selection: $resultDetailDetent)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $feedbackDraft) { draft in
            FeedbackMailComposerView(draft: draft) {
                feedbackDraft = nil
            }
        }
        #endif
        .onAppear {
            AppPreferences.shared.refreshFromDefaults()

            // In snapshot conversation mode, auto-present the conversation
            // sheet so the UI test doesn't need to find and tap the chat button.
            if HomeViewModel.isSnapshotConversationMode {
                // On macOS the inspector binding needs the view hierarchy to be
                // fully laid out before it will open. A short async delay ensures
                // the window and splitter have finished first layout.
                #if os(macOS)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if let session = viewModel.createSnapshotConversationSession() {
                            presentConversation(session)
                        }
                    }
                #else
                    if let session = viewModel.createSnapshotConversationSession() {
                        presentConversation(session)
                    }
                #endif
            }

            #if os(iOS)
                // For extension context: refresh configuration first, then execute
                if openFromExtension, !hasTriggeredAutoRequest {
                    viewModel.refreshConfiguration()
                    if let inputText = initialContextInput {
                        viewModel.inputText = inputText
                    }
                    hasTriggeredAutoRequest = true
                    viewModel.performSelectedAction()
                }
                #if canImport(Translation)
                    let needsAppleConfig = appleTranslationConfig == nil
                        && preferences.enabledModelIDs.contains(ModelConfig.appleTranslateID)
                    if #available(iOS 17.4, *), needsAppleConfig {
                        let target = AppPreferences.shared.targetLanguage
                        let sourceLocale = AppPreferences.shared.sourceLanguage.localeLanguage
                        let sourceKey = sourceLocale?.languageCode?.identifier
                        let targetKey = target.localeLanguage.languageCode?.identifier ?? target.rawValue
                        appleTranslationConfigLanguagePair = (sourceKey, targetKey)
                        appleTranslationConfig = .init(source: sourceLocale, target: target.localeLanguage)
                    }
                #endif
            #endif
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .serviceTextReceived)) { notification in
            if let text = notification.userInfo?["text"] as? String {
                viewModel.inputText = text
                isInputExpanded = true
                viewModel.performSelectedAction()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeStateHandoff)) { notification in
            if let snapshot = notification.userInfo?["snapshot"] as? HomeViewModel.StateSnapshot {
                viewModel.adoptStateSnapshot(snapshot)
                isInputExpanded = true
            }
        }
        .onAppear {
            // Notify the host app (macOS only) so AppleTranslationWindowManager can register
            // this viewModel with the hidden translation window bridge.
            NotificationCenter.default.post(
                name: .appleTranslationViewModelRegister,
                object: nil,
                userInfo: ["viewModel": viewModel]
            )
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .deepLinkTextReceived)) { notification in
            if let text = notification.userInfo?[DeepLink.NotificationKey.text] as? String {
                let configName = notification.userInfo?[DeepLink.NotificationKey.configName] as? String
                let actionName = notification.userInfo?[DeepLink.NotificationKey.actionName] as? String

                // Switch configuration if needed before looking up the action
                viewModel.applyDeepLink(text: text, actionName: actionName, configName: configName)
                isInputExpanded = true
            }
        }
        .onChange(of: viewModel.showSatisfactionPrompt) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSatisfactionToast = true
                }
                viewModel.showSatisfactionPrompt = false
            }
        }
        .onChange(of: viewModel.requestSystemReview) { _, newValue in
            if newValue {
                requestReview()
                viewModel.requestSystemReview = false
            }
        }
        .onChange(of: satisfactionPromptChrome) { oldValue, newValue in
            if oldValue == .resultCell, newValue == .none, showSatisfactionToast {
                dismissSatisfactionToast()
            }
        }
        .sheet(
            isPresented: $showModelSelectionSheet,
            onDismiss: {
                presentPendingPremiumIfNeeded()
            },
            content: {
                ModelSelectionSheet(cloudModels: viewModel.models) {
                    pendingPremiumPresentation = true
                    showModelSelectionSheet = false
                }
            }
        )
        .alert("This action needs an AI model", isPresented: $showAIModelRequiredAlert) {
            Button("Choose Model") {
                showModelSelectionSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Microsoft Translate and Apple Translate can only translate. Select an AI model to use this action.")
        }
        #if os(macOS) || os(iOS)
        .inspector(isPresented: conversationInspectorBinding) {
            if let session = activeConversationSession {
                ConversationContentView(session: session, onPremiumRequired: {
                    onPremiumRequired?()
                })
                .id(session.id)
                .inspectorColumnWidth(
                    min: InspectorColumnWidth.min,
                    ideal: InspectorColumnWidth.ideal,
                    max: InspectorColumnWidth.max
                )
            }
        }
        #endif
        #if os(iOS)
        .sheet(
            item: conversationSheetBinding,
            onDismiss: {
                presentPendingPremiumIfNeeded()
            },
            content: { session in
                ConversationView(session: session, onPremiumRequired: {
                    pendingPremiumPresentation = true
                    activeConversationSession = nil
                })
                .presentationDetents(
                    HomeViewModel.isSnapshotConversationMode ? [.large] : [.medium, .large]
                )
                .presentationDragIndicator(
                    HomeViewModel.isSnapshotConversationMode ? .hidden : .visible
                )
            }
        )
        #endif
        .sheet(item: $viewModel.selectedDebugNetworkRecord) { record in
            NavigationStack {
                NetworkRequestDetailView(record: record)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 520)
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $showDataConsent) {
            DataConsentView {
                preferences.setHasAcceptedDataSharing(true)
                viewModel.performSelectedAction()
            }
            .interactiveDismissDisabled()
        }
        .onChange(of: viewModel.showDataConsentRequest) { _, newValue in
            if newValue {
                showDataConsent = true
                viewModel.showDataConsentRequest = false
            }
        }
        #endif
        #if canImport(Translation)
        .translationTask(appleTranslationConfig) { session in
            logger.debug(".translationTask fired, session received")
            if #available(iOS 17.4, macOS 14.4, *) {
                await viewModel.executeAppleTranslation(session: session)
            }
        }
        .onChange(of: viewModel.appleTranslateTargetLanguage) { newTarget in
            logger
                .debug(
                    "Apple target changed, hasConfig=\(appleTranslationConfig != nil, privacy: .public)"
                )
            #if os(macOS)
                // On macOS, Apple Translate is routed through the hidden translation window
                // (AppleTranslationBridge) to avoid Code=14 / _EXUISceneSession errors.
                // HomeView's .translationTask is iOS-only; skip config updates on macOS.
                _ = newTarget
            #else
                if let target = newTarget {
                    let sourceLocale = viewModel.appleTranslateSourceLanguage
                    let sourceKey = sourceLocale?.languageCode?.identifier
                    let targetKey = target.localeLanguage.languageCode?.identifier ?? target.rawValue
                    logger
                        .debug(
                            "Apple config source=\(sourceKey ?? "auto", privacy: .public), target=\(targetKey, privacy: .public)"
                        )
                    let pairChanged = appleTranslationConfigLanguagePair?.source != sourceKey
                        || appleTranslationConfigLanguagePair?.target != targetKey
                    if pairChanged || appleTranslationConfig == nil {
                        // Language pair changed (or first use): replace config without going through nil
                        // to avoid the system sheet flash on every request.
                        appleTranslationConfigLanguagePair = (sourceKey, targetKey)
                        appleTranslationConfig = .init(source: sourceLocale, target: target.localeLanguage)
                    } else {
                        // Same language pair: invalidate to re-trigger .translationTask for the new request.
                        appleTranslationConfig?.invalidate()
                    }
                }
            #endif
        }
        #endif
    }

    @ViewBuilder
    private var homeContentLayout: some View {
        if usesBottomComposerLayout {
            bottomComposerTextLayout
        } else {
            stackedTextLayout
        }
    }

    private var stackedTextLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !openFromExtension {
                    #if !os(macOS)
                        if !usesNativeNavigationChrome {
                            header
                        }
                    #endif
                    topLanguageSelector
                    inputComposer()
                }
                actionChips
                if viewModel.isWordLookupFallback {
                    wordLookupFallbackHint
                }
                if viewModel.modelRuns.isEmpty {
                    hintLabel
                } else {
                    providerResultsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background(colors.background.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #if os(iOS)
            .onTapGesture {
                hideKeyboard()
            }
        #endif
    }

    private var bottomComposerTextLayout: some View {
        GeometryReader { geometry in
            if shouldCenterEmptyComposer {
                centeredEmptyComposerLayout(availableHeight: geometry.size.height)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        #if !os(macOS)
                            if !openFromExtension, !usesNativeNavigationChrome {
                                header
                            }
                        #endif

                        if viewModel.modelRuns.isEmpty {
                            if !usesPhoneComposerChrome {
                                hintLabel
                                    .padding(.top, 24)
                            }
                        } else if usesFlatResultsPanel {
                            flatResultsPanel(
                                viewportHeight: geometry.size.height
                                    - bottomComposerHeights(availableHeight: geometry.size.height).dockHeight
                                    - bottomComposerResultsTopPadding
                                    - bottomComposerResultsBottomPadding
                            )
                        } else {
                            providerResultsSection
                        }
                    }
                    .frame(maxWidth: bottomComposerContentMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .padding(.top, bottomComposerResultsTopPadding)
                    .padding(.bottom, bottomComposerResultsBottomPadding)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomComposerDock(availableHeight: geometry.size.height)
                }
                .background(colors.background.ignoresSafeArea())
                .scrollIndicators(.hidden)
                #if os(iOS)
                    .onTapGesture {
                        hideKeyboard()
                    }
                #endif
            }
        }
    }

    private var bottomComposerResultsTopPadding: CGFloat {
        usesPhoneComposerChrome ? 8 : 28
    }

    private var bottomComposerResultsBottomPadding: CGFloat {
        16
    }

    private func centeredEmptyComposerLayout(availableHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            colors.background.ignoresSafeArea()

            #if !os(macOS)
                if !openFromExtension, !usesNativeNavigationChrome {
                    header
                        .frame(maxWidth: bottomComposerContentMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                }
            #endif

            centeredEmptyComposer(availableHeight: availableHeight)
        }
        #if os(iOS)
        .onTapGesture {
            hideKeyboard()
        }
        #endif
    }

    private func centeredEmptyComposer(availableHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            bottomComposerContent(availableHeight: availableHeight)

            hintLabel
                .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func bottomComposerDock(availableHeight: CGFloat) -> some View {
        bottomComposerContent(availableHeight: availableHeight)
            .padding(.horizontal, 20)
            .padding(.top, bottomComposerDockTopPadding)
            .padding(.bottom, bottomComposerDockBottomPadding)
            .background(colors.background.opacity(colorScheme == .dark ? 0.96 : 0.94).ignoresSafeArea(edges: .bottom))
    }

    private func bottomComposerContent(availableHeight: CGFloat) -> some View {
        let heights = bottomComposerHeights(availableHeight: availableHeight)

        return VStack(alignment: .leading, spacing: bottomComposerDockSpacing) {
            if viewModel.isWordLookupFallback {
                wordLookupFallbackHint
                    .onHeightChange { height in
                        updateMeasuredHeight(height, current: bottomComposerWordLookupHintHeight) {
                            bottomComposerWordLookupHintHeight = $0
                        }
                    }
                    .transition(.opacity)
            }
            #if os(iOS)
                if shouldShowMatchFallbackHint,
                   let source = viewModel.detectedSourceLanguage,
                   let target = viewModel.resolvedTargetLanguage
                {
                    matchFallbackHint(source: source, target: target)
                        .transition(.opacity)
                }
            #endif
            actionChips
                .onHeightChange { updateBottomComposerActionChipsHeight($0) }
            topLanguageSelector
                .onHeightChange { updateBottomComposerLanguageSelectorHeight($0) }
            inputComposer(editorHeight: heights.editorHeight)
                .frame(height: heights.inputHeight)
        }
        .frame(maxWidth: bottomComposerContentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var bottomComposerContentMaxWidth: CGFloat {
        #if os(macOS)
            return 820
        #else
            return 760
        #endif
    }

    private var bottomComposerDockSpacing: CGFloat {
        10
    }

    private var bottomComposerDockTopPadding: CGFloat {
        10
    }

    private var bottomComposerDockBottomPadding: CGFloat {
        16
    }

    private var bottomComposerInputHeight: CGFloat {
        #if os(macOS)
            return 104
        #else
            return 112
        #endif
    }

    private func bottomComposerHeights(availableHeight: CGFloat) -> HomeBottomComposerHeights {
        HomeTextLayoutPolicy.bottomComposerHeights(
            availableHeight: availableHeight,
            chromeHeight: bottomComposerChromeHeight,
            compactInputHeight: bottomComposerInputHeight,
            compactEditorMinHeight: inputEditorMinHeight,
            compactEditorMaxHeight: inputEditorMaxHeight,
            measuredEditorContentHeight: bottomComposerEditorContentHeight
        )
    }

    private var bottomComposerChromeHeight: CGFloat {
        let measuredRows = [
            viewModel.isWordLookupFallback ? bottomComposerWordLookupHintHeight : 0,
            bottomComposerActionChipsHeight,
            bottomComposerLanguageSelectorHeight,
        ].filter { $0 > 0 }
        let spacingCount = measuredRows.isEmpty ? 0 : measuredRows.count
        return measuredRows.reduce(0, +)
            + CGFloat(spacingCount) * bottomComposerDockSpacing
            + bottomComposerDockTopPadding
            + bottomComposerDockBottomPadding
    }

    private func updateBottomComposerActionChipsHeight(_ height: CGFloat) {
        updateMeasuredHeight(height, current: bottomComposerActionChipsHeight) {
            bottomComposerActionChipsHeight = $0
        }
    }

    private func updateBottomComposerLanguageSelectorHeight(_ height: CGFloat) {
        updateMeasuredHeight(height, current: bottomComposerLanguageSelectorHeight) {
            bottomComposerLanguageSelectorHeight = $0
        }
    }

    private func updateBottomComposerEditorContentHeight(_ height: CGFloat) {
        updateMeasuredHeight(height, current: bottomComposerEditorContentHeight) {
            bottomComposerEditorContentHeight = $0
        }
    }

    private func updateMeasuredHeight(
        _ height: CGFloat,
        current: CGFloat,
        assign: (CGFloat) -> Void
    ) {
        guard height.isFinite else { return }
        let roundedHeight = max(0, height.rounded(.up))
        guard abs(current - roundedHeight) > 0.5 else { return }
        assign(roundedHeight)
    }

    private var satisfactionToastAlignment: Alignment {
        #if os(macOS)
            .bottomTrailing
        #else
            .bottom
        #endif
    }

    private func dismissSatisfactionToast() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showSatisfactionToast = false
        }
    }

    private func composeFeedbackEmail() {
        let draft = FeedbackMail.makeDraft()
        #if os(iOS)
            feedbackDraft = draft
        #elseif os(macOS)
            FeedbackMail.openMacComposer(draft)
        #else
            FeedbackMail.openFallback(draft)
        #endif
    }

    private var satisfactionPrompt: some View {
        SatisfactionPromptView(
            colors: colors,
            onSatisfied: {
                dismissSatisfactionToast()
                AppPreferences.shared.markSatisfactionPromptResponded()
                requestReview()
            },
            onFeedback: {
                dismissSatisfactionToast()
                AppPreferences.shared.markSatisfactionPromptResponded()
                composeFeedbackEmail()
            },
            onDismiss: dismissSatisfactionToast
        )
        .task(id: showSatisfactionToast) {
            guard showSatisfactionToast else { return }
            try? await Task.sleep(for: .seconds(10))
            dismissSatisfactionToast()
        }
    }

    private var satisfactionPromptOverlay: some View {
        satisfactionPrompt
            .transition(.move(edge: .bottom).combined(with: .opacity))
        #if os(macOS)
            .padding(20)
        #else
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        #endif
    }

    private var satisfactionPromptResultCell: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(colors.accent)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Was TLingo helpful today?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(colors.textPrimary)

                    Text("Share quick feedback so the translation experience keeps improving.")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    dismissSatisfactionToast()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(colors.inputBackground.opacity(colorScheme == .dark ? 0.70 : 0.85))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            HStack(spacing: 10) {
                Button {
                    dismissSatisfactionToast()
                    AppPreferences.shared.markSatisfactionPromptResponded()
                    requestReview()
                } label: {
                    Label("Love it", systemImage: "heart.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colors.accentFill)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    dismissSatisfactionToast()
                    AppPreferences.shared.markSatisfactionPromptResponded()
                    composeFeedbackEmail()
                } label: {
                    Label("Feedback", systemImage: "envelope")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colors.inputBackground.opacity(colorScheme == .dark ? 0.70 : 0.86))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(colors.divider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    dismissSatisfactionToast()
                } label: {
                    Text("Later")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.88)
        }
        .padding(TLingoSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(providerResultCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                .stroke(colors.divider, lineWidth: 1)
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        .task(id: showSatisfactionToast) {
            guard showSatisfactionToast else { return }
            try? await Task.sleep(for: .seconds(10))
            dismissSatisfactionToast()
        }
    }

    private var configurationLoadingOverlay: some View {
        LoadingOverlay(
            message: "Loading configuration...",
            backgroundColor: colors.background.opacity(0.9),
            messageFont: .system(size: 14),
            textColor: colors.textSecondary,
            accentColor: colors.accent,
            ignoresSafeArea: true
        )
    }

    private var header: some View {
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
    private var topLanguageSelector: some View {
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
                    onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .tlingoGlassSurface(.chrome, cornerRadius: TLingoRadius.large)
        }
    }

    private var inputComposerBackground: some View {
        Color.clear
            .tlingoGlassSurface(.chrome, cornerRadius: TLingoRadius.large)
    }

    private var inputEditorMinHeight: CGFloat {
        usesBottomComposerLayout ? 44 : 140
    }

    private var inputEditorMaxHeight: CGFloat {
        usesBottomComposerLayout ? 56 : 160
    }

    private var inputComposerBottomPadding: CGFloat {
        usesBottomComposerLayout ? 42 : 48
    }

    private func inputComposer(editorHeight: CGFloat? = nil) -> some View {
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
    private func inputComposerControls(isCollapsed: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                inputComposerControlsContent(isCollapsed: isCollapsed)
            }
        } else {
            inputComposerControlsContent(isCollapsed: isCollapsed)
        }
    }

    private func inputComposerControlsContent(isCollapsed: Bool) -> some View {
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
                        onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
                    )
                }

                #if os(iOS)
                    if usesPhoneComposerChrome {
                        modelSelectionButton
                        Spacer()
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
    private var defaultInputTrailingControls: some View {
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

    private var modelSelectionButton: some View {
        Button {
            showModelSelectionSheet = true
        } label: {
            modelSelectionButtonLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Models")
        .accessibilityIdentifier("home_model_picker")
    }

    private var resultOrderPicker: some View {
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

    private var resultOrderMenu: some View {
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
    private func resultOptionsMenuContent(showsResultOrder: Bool) -> some View {
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
    private var modelSelectionButtonLabel: some View {
        HStack(spacing: 7) {
            Text(modelSelectionTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.65)
        }
        .foregroundColor(colors.textPrimary)
        #if os(macOS)
            .frame(width: 170, alignment: .trailing)
            .contentShape(Rectangle())
        #else
            .frame(width: usesPhoneComposerChrome ? nil : 170, alignment: .trailing)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        #endif
    }

    private var shouldShowModelSelectionInsideInput: Bool {
        #if os(macOS)
            return true
        #else
            return usesSimplifiedTextLayout
        #endif
    }

    private var modelSelectionTitle: String {
        let selected = selectedDisplayModels
        guard !selected.isEmpty else {
            return String(localized: "Models")
        }
        if selected.count == 1 {
            return selected[0].displayName
        }
        return String(localized: "\(selected.count) Models")
    }

    private func presentPendingPremiumIfNeeded() {
        guard pendingPremiumPresentation else { return }
        pendingPremiumPresentation = false
        onPremiumRequired?()
    }

    private func presentConversation(_ session: ConversationSession) {
        if showsOnlyResults {
            onResultConversation?(session)
            return
        }
        activeConversationSession = session
        isConversationInspectorPresented = usesConversationInspectorPresentation
    }

    private func toggleConversationInspector() {
        guard activeConversationSession != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isConversationInspectorPresented.toggle()
        }
    }

    private var conversationInspectorToggleButton: some View {
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

    private var selectedDisplayModels: [ModelConfig] {
        let enabledIDs = preferences.enabledModelIDs
        var displayModels: [ModelConfig] = []
        if enabledIDs.contains(ModelConfig.microsoftTranslateID) {
            displayModels.append(ModelConfig.microsoftTranslate)
        }
        if enabledIDs.contains(ModelConfig.appleTranslateID), AppleTranslationService.shared.isAvailable {
            displayModels.append(ModelConfig.appleTranslate)
        }
        if enabledIDs.contains(ModelConfig.foundationModelID) {
            displayModels.append(ModelConfig.foundationModel)
        }
        if !BuildEnvironment.isDirectDistribution,
           enabledIDs.contains(ModelConfig.privateCloudModelID)
        {
            displayModels.append(ModelConfig.privateCloudModel)
        }
        displayModels.append(contentsOf: viewModel.models.filter { enabledIDs.contains($0.id) })
        displayModels = displayModels.filter { entitlement.isPro || !$0.isPremium }
        if displayModels.isEmpty {
            displayModels = viewModel.models.filter {
                $0.isDefault && (entitlement.isPro || !$0.isPremium)
            }
        }
        if displayModels.isEmpty, !viewModel.isLoadingModels, AppleTranslationService.shared.isAvailable {
            displayModels = [ModelConfig.appleTranslate]
        }
        return displayModels
    }

    private var inputSendButton: some View {
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
    private var inputSendButtonLabel: some View {
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

    private var inputSendButtonStyle: some PrimitiveButtonStyle {
        #if os(macOS)
            return .plain
        #else
            return .glassProminent
        #endif
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
                if viewModel.isSpeakingInputText {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                }
            }
            .buttonStyle(.glass)
            .tint(viewModel.isSpeakingInputText ? colors.error : colors.accent)
            .buttonBorderShape(.circle)
        }
    }

    private var collapsedInputSummary: some View {
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

    private func expandedInputEditor(editorHeight: CGFloat? = nil) -> some View {
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
                #elseif os(iOS)
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
                #else
                    TextEditor(text: $viewModel.inputText)
                        .scrollContentBackground(.hidden)
                        .foregroundColor(colors.textPrimary)
                        .padding(12)
                        .frame(minHeight: editorHeight ?? inputEditorMinHeight, maxHeight: editorHeight ?? inputEditorMaxHeight)
                        .onPasteCommand(of: [.plainText]) { providers in
                            handlePasteCommand(providers: providers)
                        }
                #endif
            }
        }
    }

    #if os(iOS)
        // MARK: - iPhone chrome

        private var navigationBarLanguageSelector: some View {
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
                onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
            )
        }

        @ViewBuilder
        private var phoneSettingsButton: some View {
            if let onSettingsTap {
                Button("Settings", systemImage: "gearshape", action: onSettingsTap)
                    .accessibilityIdentifier("tab_settings")
            }
        }

        /// Main app only, and only while the input is empty so it never competes with speak and send.
        @ViewBuilder
        private var imageTextInputButton: some View {
            if context == nil, viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ImageTextInputButton(tint: colors.accent) { text in
                    viewModel.inputText = text
                    isInputExpanded = true
                }
            }
        }

        private var clearInputButton: some View {
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

        /// The input's trailing slot: realtime entry while empty, send once text exists,
        /// and "translate again" while the input still matches the shown result.
        @ViewBuilder
        private var phonePrimaryInputButton: some View {
            let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if !hasText, let onRealtimeTap {
                Button(action: onRealtimeTap) {
                    phonePrimaryInputButtonIcon("waveform")
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(colors.accent)
                .accessibilityLabel("Realtime Translation")
                .accessibilityIdentifier("home_realtime_button")
            } else {
                let isShowingCurrentResult = !viewModel.modelRuns.isEmpty
                    && viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    == viewModel.currentRequestInputText.trimmingCharacters(in: .whitespacesAndNewlines)

                Button(action: performInputActionIfPossible) {
                    phonePrimaryInputButtonIcon(isShowingCurrentResult ? "arrow.clockwise" : "arrow.up")
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(colors.accent)
                .disabled(!viewModel.canSend)
                .accessibilityLabel(isShowingCurrentResult ? "Translate Again" : "Send")
                .accessibilityIdentifier("home_send_button")
            }
        }

        private func phonePrimaryInputButtonIcon(_ systemName: String) -> some View {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 22, height: 22)
        }

        private var shouldShowMatchFallbackHint: Bool {
            usesPhoneComposerChrome
                && viewModel.isMatchTargetFallback
                && viewModel.selectedAction?.languageDependencies.usesTargetLanguage == true
        }

        /// Explains why the automatic target skipped the first language, with a one-tap override.
        private func matchFallbackHint(source: SourceLanguageOption, target: TargetLanguageOption) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("Source is \(source.primaryLabel), translating to \(target.primaryLabel)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                Menu {
                    ForEach(TargetLanguageOption.selectionOptions.filter { $0 != .appLanguage && $0 != target }) { option in
                        Button(option.primaryLabel) {
                            viewModel.overrideTargetLanguage(option)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Change")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(colors.accent)
                }
                .accessibilityIdentifier("home_match_fallback_change")
            }
            .font(.system(size: 13))
            .foregroundColor(colors.textSecondary)
            .padding(.horizontal, 4)
        }
    #endif

    private var wordLookupFallbackHint: some View {
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

    // MARK: - Flat result panel

    /// The first result stays in place while the remaining models expand below it.
    private func flatResultsPanel(viewportHeight: CGFloat) -> some View {
        let runs = viewModel.displayedModelRuns
        let showsComparison = isComparingResults && runs.count > 1

        return VStack(alignment: .leading, spacing: 0) {
            if let primaryRun = runs.first {
                flatResultRow(for: primaryRun, isPrimary: true)
                if runs.count > 1 {
                    let remainingRuns = Array(runs.dropFirst())
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        if showsComparison {
                            comparisonHeader(remainingModelCount: remainingRuns.count)
                                .padding(.top, Self.collapsedResultsVerticalPadding)
                            ForEach(Array(remainingRuns.enumerated()), id: \.element.id) { index, run in
                                if index > 0 {
                                    Divider()
                                }
                                flatResultRow(for: run, isPrimary: false)
                            }
                        } else {
                            collapsedResults(
                                remainingRuns,
                                lineLimits: collapsedPreviewLineLimits(for: remainingRuns, viewportHeight: viewportHeight)
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: showsComparison)
                }
            }

            if !runs.isEmpty {
                resultOptionsFooter(showsResultOrder: runs.count > 1)
            }

            if shouldShowInlineSatisfactionPrompt {
                satisfactionPromptResultCell
                    .padding(.top, 16)
            }
        }
        .onHeightChange { height in
            updateMeasuredHeight(height, current: flatResultsPanelHeight) {
                flatResultsPanelHeight = $0
            }
        }
    }

    @ViewBuilder
    private func flatResultRow(for run: HomeViewModel.ModelRunViewState, isPrimary: Bool) -> some View {
        let runID = run.id
        let isLoading = isRunLoading(run)
        let row = VStack(alignment: .leading, spacing: 8) {
            flatResultHeader(for: run)
            content(for: run, textPreset: .compact, showsInlineActions: false)
                .frame(maxWidth: .infinity, minHeight: heldResultHeights[runID], alignment: .topLeading)
                // Outgoing content fades inside the row instead of overlapping the next one.
                .clipped()
                .onHeightChange { height in
                    guard heldResultHeights[runID] == nil else { return }
                    updateMeasuredHeight(height, current: resultContentHeights[runID] ?? 0) {
                        resultContentHeights[runID] = $0
                    }
                }
        }
        .padding(.vertical, isPrimary ? 8 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isLoading) { _, loading in
            guard !loading, heldResultHeights[runID] != nil else { return }
            withAnimation(.smooth(duration: 0.35)) {
                heldResultHeights[runID] = nil
            }
        }

        #if os(iOS)
            if isSuccessfulRun(run) {
                row
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture()
                            .onEnded {
                                presentResultDetail(runID: runID)
                            },
                        including: .gesture
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: Text("Open Result")) {
                        presentResultDetail(runID: runID)
                    }
            } else {
                row
            }
        #else
            // macOS has no result detail sheet; the text stays selectable in place.
            row
        #endif
    }

    private func flatResultHeader(for run: HomeViewModel.ModelRunViewState) -> some View {
        HStack(spacing: 8) {
            Text(run.modelDisplayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(colors.textSecondary)
                .lineLimit(1)

            switch run.status {
            case .idle, .running, .streaming, .streamingSentencePairs:
                ProgressView()
                    .controlSize(.mini)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(colors.error)
            case .success:
                EmptyView()
            }

            if DeveloperMode.isEnabled {
                providerInfoButton(runID: run.id)
            }

            Spacer(minLength: 8)

            HStack(spacing: 16) {
                if viewModel.canShowSentencePairs(for: run) {
                    sentencePairsToggle(for: run)
                }

                switch run.status {
                case let .success(result):
                    speakResultButton(text: result.copyText, runID: run.id)
                    // On iPhone the conversation entry lives in the result detail sheet.
                    actionButtons(
                        copyText: result.copyText,
                        runID: run.id,
                        showsChat: !usesPhoneComposerChrome && (!showsOnlyResults || onResultConversation != nil)
                    )
                case .failure:
                    retryButton(runID: run.id)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// Switches this row between the whole translation and sentence pairs; other rows stay as they are.
    private func sentencePairsToggle(for run: HomeViewModel.ModelRunViewState) -> some View {
        let isOn = run.presentation == .sentencePairs

        return Button {
            toggleSentencePairs(runID: run.id)
        } label: {
            Image(systemName: "rectangle.split.1x2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isOn ? colors.onAccent : colors.accent)
                .frame(width: 28, height: 22)
                .background {
                    if isOn {
                        Capsule(style: .continuous)
                            .fill(colors.accentFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sentence by Sentence")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("home_sentence_pairs_toggle")
    }

    /// Content swaps without a cross-fade; only the row height animates, from the held height
    /// to the new content once it is ready.
    private func toggleSentencePairs(runID: String) {
        heldResultHeights[runID] = resultContentHeights[runID]
        viewModel.toggleSentencePairs(runID: runID)
        // A cached result is ready now; release the hold after one frame so the height animates.
        if let run = viewModel.modelRuns.first(where: { $0.id == runID }), !isRunLoading(run) {
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.3)) {
                    heldResultHeights[runID] = nil
                }
            }
        }
    }

    private func isRunLoading(_ run: HomeViewModel.ModelRunViewState) -> Bool {
        switch run.status {
        case .idle, .running, .streaming, .streamingSentencePairs:
            return true
        case .success, .failure:
            return false
        }
    }

    private func speakResultButton(text: String, runID: String) -> some View {
        let isSpeaking = viewModel.isSpeaking(runID: runID)

        return Button {
            if isSpeaking {
                viewModel.stopSpeaking()
            } else {
                viewModel.speakResult(text, runID: runID)
            }
        } label: {
            Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2")
                .font(.system(size: 14))
                .foregroundColor(colors.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSpeaking ? "Stop Speaking" : "Speak")
    }

    private static let collapsedPreviewFontSize: CGFloat = 14
    private static let collapsedPreviewLabelWidth: CGFloat = 92
    private static let collapsedPreviewColumnSpacing: CGFloat = 12
    private static let collapsedResultsRowSpacing: CGFloat = 10
    private static let collapsedResultsVerticalPadding: CGFloat = 14

    private func collapsedResults(
        _ runs: [HomeViewModel.ModelRunViewState],
        lineLimits: [String: Int]
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isComparingResults = true
            }
        } label: {
            VStack(alignment: .leading, spacing: Self.collapsedResultsRowSpacing) {
                HStack(spacing: 4) {
                    Text("\(runs.count) more models")
                    Spacer()
                    Text("Compare")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(colors.textSecondary)

                ForEach(runs) { run in
                    HStack(alignment: .firstTextBaseline, spacing: Self.collapsedPreviewColumnSpacing) {
                        Text(run.modelDisplayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                            .lineLimit(1)
                            .frame(width: Self.collapsedPreviewLabelWidth, alignment: .leading)
                        Text(resultPreview(for: run))
                            .font(.system(size: Self.collapsedPreviewFontSize))
                            .foregroundColor(colors.textPrimary.opacity(0.8))
                            .lineLimit(lineLimits[run.id] ?? 1)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, Self.collapsedResultsVerticalPadding)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard abs(size.width - collapsedResultsSize.width) > 0.5
                    || abs(size.height - collapsedResultsSize.height) > 0.5
                else { return }
                collapsedResultsSize = size
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home_compare_results_button")
    }

    private func resultOptionsFooter(showsResultOrder: Bool) -> some View {
        HStack {
            Spacer()
            Menu {
                resultOptionsMenuContent(showsResultOrder: showsResultOrder)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Result Options")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(colors.textSecondary)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .accessibilityIdentifier("home_result_order")
            .accessibilityValue(preferences.modelResultOrder.title)
        }
        .padding(.top, 4)
    }

    private func comparisonHeader(remainingModelCount: Int) -> some View {
        HStack(spacing: 14) {
            Text("\(remainingModelCount) more models")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(colors.textSecondary)

            Spacer()

            // Result order lives in the result options menu below the results.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isComparingResults = false
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(colors.accent)
            .accessibilityLabel("Collapse")
        }
        .padding(.bottom, 4)
    }

    /// Model output is Markdown, so previews render its inline styling instead of raw markers.
    private func resultPreview(for run: HomeViewModel.ModelRunViewState) -> AttributedString {
        let text: String
        switch run.status {
        case .idle, .running:
            text = String(localized: "Generating...")
        case let .streaming(streamedText, _):
            if streamedText.isEmpty {
                text = String(localized: "Generating...")
            } else {
                return MarkdownPreviewText.attributed(from: streamedText)
            }
        case let .streamingSentencePairs(pairs, _):
            text = pairs.isEmpty
                ? String(localized: "Translating...")
                : pairs.map(\.translation).joined(separator: " ")
        case let .success(result):
            return MarkdownPreviewText.attributed(from: result.copyText)
        case .failure:
            text = String(localized: "Request Failed")
        }
        return AttributedString(text.replacingOccurrences(of: "\n", with: " "))
    }

    /// On Mac, collapsed previews grow to fill the visible area below the primary result,
    /// so comparing models rarely needs scrolling. iPhone keeps one line per preview.
    private func collapsedPreviewLineLimits(
        for runs: [HomeViewModel.ModelRunViewState],
        viewportHeight: CGFloat
    ) -> [String: Int] {
        #if os(macOS)
            let font = NSFont.systemFont(ofSize: Self.collapsedPreviewFontSize)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let textWidth = collapsedResultsSize.width - Self.collapsedPreviewLabelWidth
                - Self.collapsedPreviewColumnSpacing
            guard textWidth > 0, lineHeight > 0, flatResultsPanelHeight > 0, collapsedResultsSize.height > 0 else {
                return [:]
            }

            // Everything in the panel except the collapsed block keeps its height whatever the line limits are.
            let fixedHeight = flatResultsPanelHeight - collapsedResultsSize.height
            let blockChromeHeight = Self.collapsedResultsVerticalPadding * 2 + lineHeight
                + Self.collapsedResultsRowSpacing * CGFloat(runs.count)
            let previewHeight = viewportHeight - fixedHeight - blockChromeHeight
            let lineBudget = previewHeight.isFinite ? Int((previewHeight / lineHeight).rounded(.down)) : 0

            let neededLines = runs.map { run in
                let text = String(resultPreview(for: run).characters) as NSString
                let height = text.boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                ).height
                return max(1, Int((height / lineHeight).rounded(.up)))
            }
            let limits = HomeTextLayoutPolicy.collapsedPreviewLineLimits(
                neededLines: neededLines,
                lineBudget: lineBudget
            )
            return Dictionary(zip(runs.map(\.id), limits)) { first, _ in first }
        #else
            return [:]
        #endif
    }

    private func performInputActionIfPossible() {
        guard viewModel.canSend else { return }
        hideKeyboard()
        viewModel.performSelectedAction()
    }

    private var actionChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                actionChipsStack { actionID in
                    scrollActionChip(actionID, proxy: proxy)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
            }
            // Bleed past the container's 20pt padding to the screen edge on iPhone,
            // while resting content stays aligned with the rows above and below.
            .contentMargins(.horizontal, actionChipsEdgeBleed, for: .scrollContent)
            .padding(.horizontal, -actionChipsEdgeBleed)
            .onChange(of: viewModel.selectedActionID) { _, actionID in
                scrollActionChip(actionID, proxy: proxy)
            }
        }
    }

    /// Wide layouts center a width-limited column, so bleeding there would overshoot it.
    private var actionChipsEdgeBleed: CGFloat {
        #if os(iOS)
            horizontalSizeClass == .compact ? 20 : 0
        #else
            0
        #endif
    }

    private func actionChipsStack(onActionSelected: @escaping (ActionConfig.ID) -> Void) -> some View {
        HStack(spacing: TLingoSpacing.sm) {
            ForEach(chipActions) { action in
                let isSelected = action.id == viewModel.selectedAction?.id

                Button {
                    onActionSelected(action.id)
                    if viewModel.selectAction(action) {
                        if viewModel.requiresAIModelSelection(for: action) {
                            showAIModelRequiredAlert = true
                        } else {
                            viewModel.performSelectedAction()
                        }
                    }
                } label: {
                    Text(action.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? colors.chipPrimaryText : colors.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, TLingoSpacing.md)
                        .padding(.vertical, 10)
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    isSelected
                                        ? colors.chipPrimaryBackground
                                        : (
                                            colorScheme == .dark
                                                ? colors.chipSecondaryBackground.opacity(0.72)
                                                : colors.cardBackground.opacity(0.78)
                                        )
                                )
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .id(action.id)
            }

            if let onManageActionsTap, showsManageActionsButton {
                manageActionsButton(action: onManageActionsTap)
            }
        }
    }

    /// With the flat result panel, sentence pairs live on each result row instead of in the chip row
    /// (kept while it is the selected action so the selection stays visible).
    private var chipActions: [ActionConfig] {
        guard usesFlatResultsPanel else { return viewModel.actions }
        let sentenceID = BuiltInActionCatalog.sentenceTranslateActionID
        return viewModel.actions.filter { $0.id != sentenceID || $0.id == viewModel.selectedAction?.id }
    }

    private func scrollActionChip(_ actionID: ActionConfig.ID?, proxy: ScrollViewProxy) {
        guard let actionID else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(actionID, anchor: .center)
        }
    }

    private func manageActionsButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(colors.textPrimary)
                .frame(width: 40, height: 40)
                .background {
                    Circle()
                        .fill(
                            colorScheme == .dark
                                ? colors.chipSecondaryBackground.opacity(0.72)
                                : colors.cardBackground.opacity(0.78)
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage Actions")
        .accessibilityIdentifier("home_manage_actions_button")
    }

    private var hintLabel: some View {
        Text(viewModel.placeholderHint)
            .font(.system(size: 14))
            .foregroundColor(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    @ViewBuilder
    private var providerResultCardBackground: some View {
        RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
            .fill(colors.cardBackground)
    }

    private var providerResultsSection: some View {
        VStack(spacing: 16) {
            ForEach(viewModel.displayedModelRuns) { run in
                providerResultCard(for: run)
            }

            if shouldShowInlineSatisfactionPrompt {
                satisfactionPromptResultCell
            }
        }
    }

    @ViewBuilder
    private func providerResultCard(for run: HomeViewModel.ModelRunViewState) -> some View {
        let runID = run.id
        let cardContent = VStack(alignment: .leading, spacing: 12) {
            content(for: run)

            // Bottom info bar
            bottomInfoBar(for: run)
        }
        .padding(16)

        #if os(iOS)
            if isSuccessfulRun(run) {
                cardContent
                    .background(providerResultCardBackground)
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture()
                            .onEnded {
                                presentResultDetail(runID: runID)
                            },
                        including: .gesture
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: Text("Open Result")) {
                        presentResultDetail(runID: runID)
                    }
            } else {
                cardContent
                    .background(providerResultCardBackground)
            }
        #else
            cardContent
                .background(providerResultCardBackground)
        #endif
    }

    private func isSuccessfulRun(_ run: HomeViewModel.ModelRunViewState) -> Bool {
        if case .success = run.status {
            return true
        }
        return false
    }

    #if os(iOS)
        private struct SelectedResult: Identifiable {
            let id: String
        }

        private func presentResultDetail(runID: String) {
            resultDetailDetent = .medium
            selectedResult = SelectedResult(id: runID)
        }

        @ViewBuilder
        private func resultDetailSheet(for runID: String) -> some View {
            NavigationStack {
                if let run = viewModel.modelRuns.first(where: { $0.id == runID }),
                   case let .success(result) = run.status
                {
                    TranslationResultDetailView(
                        sourceText: resultDetailSourceText,
                        actionName: viewModel.selectedAction?.displayName,
                        actionIcon: viewModel.selectedAction?.outputType.systemImageName,
                        modelDisplayName: run.modelDisplayName,
                        durationText: run.durationText,
                        result: result
                    )
                } else {
                    Text("Result unavailable")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .navigationTitle("Result")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                }
            }
        }

        private var resultDetailSourceText: String {
            let requestText = viewModel.currentRequestInputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestText.isEmpty {
                return viewModel.currentRequestInputText
            }
            return viewModel.inputText
        }
    #endif

    @ViewBuilder
    private func bottomInfoBar(
        for run: HomeViewModel.ModelRunViewState
    ) -> some View {
        let runID = run.id

        switch run.status {
        case .idle, .running:
            EmptyView()

        case let .streaming(_, start):
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(colors.accent)
                Text(run.modelDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                Text("Generating...")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                Spacer()
                liveTimer(start: start)
            }

        case let .streamingSentencePairs(_, start):
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(colors.accent)
                Text(run.modelDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                Text("Translating...")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                Spacer()
                liveTimer(start: start)
            }

        case let .success(result):
            HStack(spacing: 12) {
                // Status + Duration + Model Name + Info
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(colors.success)
                        .font(.system(size: 14))

                    if let duration = run.durationText {
                        Text(duration)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                    }

                    Text(run.modelDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colors.textSecondary)

                    providerInfoButton(runID: runID)
                }

                Spacer()

                // Action buttons (only show here when no supplementalTexts, i.e., plain text mode)
                if result.sentencePairs.isEmpty && result.supplementalTexts.isEmpty {
                    actionButtons(copyText: result.copyText, runID: runID)
                }
            }

        case .failure:
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(colors.error)
                        .font(.system(size: 14))

                    if let duration = run.durationText {
                        Text(duration)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                    }

                    Text(run.modelDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colors.textSecondary)

                    providerInfoButton(runID: runID)
                }

                Spacer()

                // Retry button (retry only this run)
                retryButton(runID: runID)
            }
        }
    }

    /// Retries one run, or asks for the Apple Translate language download when that is what failed.
    private func retryButton(runID: String) -> some View {
        let downloadsLanguage = runID == ModelConfig.appleTranslateID && viewModel.appleTranslateNeedsLanguageDownload
        return Button {
            if downloadsLanguage {
                viewModel.downloadAppleTranslateLanguage(runID: runID)
            } else {
                viewModel.retryRun(runID: runID)
            }
        } label: {
            Group {
                if downloadsLanguage {
                    Label("Download", systemImage: "arrow.down.circle")
                } else {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(colors.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionButtons(copyText: String, runID: String, showsChat: Bool = true) -> some View {
        // Full action buttons for bottom bar (plain text mode)
        diffToggleButton(for: runID)
        compactCopyButton(for: copyText)
        if showsChat {
            chatButton(for: runID)
        }
        #if os(macOS)
            if let onResultReplace {
                Button {
                    onResultReplace(copyText)
                } label: {
                    Label("Replace", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(colors.accent)
            }
        #elseif os(iOS)
            if let context, context.allowsReplacement {
                Button {
                    context.finish(translation: AttributedString(copyText))
                } label: {
                    Label("Replace", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(colors.accent)
            }
        #endif
    }

    @ViewBuilder
    private func diffToggleButton(for runID: String) -> some View {
        if viewModel.hasDiff(for: runID) {
            let isShowingDiff = viewModel.isDiffShown(for: runID)
            Button {
                viewModel.toggleDiffDisplay(for: runID)
            } label: {
                Image(systemName: isShowingDiff ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundColor(colors.accent)
            }
            .buttonStyle(.plain)
            .help(isShowingDiff ? "Hide changes" : "Show changes")
        }
    }

    @ViewBuilder
    private func providerInfoButton(runID: String) -> some View {
        Button {
            if DeveloperMode.isEnabled {
                // Developer mode: jump straight to the recorded request details
                // (provider meta is still available via logs).
                viewModel.presentDebugRequestDetails(for: runID)
            } else {
                showingProviderInfo = showingProviderInfo == runID ? nil : runID
            }
        } label: {
            if DeveloperMode.isEnabled {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: providerInfoBinding(for: runID)) {
            if let run = viewModel.modelRuns.first(where: { $0.id == runID }) {
                providerInfoPopover(for: run)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func providerInfoBinding(for runID: String) -> Binding<Bool> {
        Binding(
            get: { showingProviderInfo == runID },
            set: { isPresented in
                if !isPresented, showingProviderInfo == runID {
                    showingProviderInfo = nil
                }
            }
        )
    }

    @ViewBuilder
    private func providerInfoPopover(for run: HomeViewModel.ModelRunViewState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.modelDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(colors.textPrimary)
            if let duration = run.durationText {
                Text(
                    String(
                        format: NSLocalizedString("Duration: %@", comment: "Provider run duration"),
                        duration
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(colors.textSecondary)
            }
            if let breakdown = run.status.latencyBreakdown {
                Divider()
                HStack(spacing: 4) {
                    Text("Client → Azure:")
                        .font(.system(size: 11))
                        .foregroundColor(colors.textSecondary)
                    Text(breakdown.clientToAzureText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(colors.textPrimary)
                }
                HStack(spacing: 4) {
                    Text("Azure → Model:")
                        .font(.system(size: 11))
                        .foregroundColor(colors.textSecondary)
                    Text(breakdown.upstreamText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(colors.textPrimary)
                }
            }
        }
        .fixedSize()
        .padding(12)
    }

    private func liveTimer(start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Text(String(format: "%.0fs", elapsed))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(colors.textSecondary)
        }
    }

    private func skeletonPlaceholder() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0 ..< 3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colors.skeleton)
                    .frame(height: 10)
                    .frame(maxWidth: index == 2 ? 180 : .infinity)
                    .shimmer()
            }
        }
    }

    @ViewBuilder
    private func compactCopyButton(for text: String) -> some View {
        Button {
            copyToPasteboard(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14))
                .foregroundColor(colors.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func chatButton(for runID: String) -> some View {
        if let run = viewModel.modelRuns.first(where: { $0.id == runID }),
           !run.model.isDirectTranslation
        {
            Button {
                if let session = viewModel.createConversation(from: run) {
                    presentConversation(session)
                }
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 14))
                    .foregroundColor(colors.accent)
            }
            .buttonStyle(.plain)
            .help("Continue conversation")
            .accessibilityIdentifier("chat_button")
        }
    }

    @ViewBuilder
    private func suggestedActionChips(actions: [String], runID: String) -> some View {
        SuggestedActionChips(actions: actions) { action in
            if let run = viewModel.modelRuns.first(where: { $0.id == runID }),
               let session = viewModel.createConversationWithFollowUp(from: run, followUp: action)
            {
                presentConversation(session)
            }
        }
    }

    @ViewBuilder
    private func content(
        for run: HomeViewModel.ModelRunViewState,
        textPreset: MarkdownContentPreset = .compact,
        showsInlineActions: Bool = true
    ) -> some View {
        switch run.status {
        case .idle, .running:
            skeletonPlaceholder()

        case let .streaming(text, _):
            if text.isEmpty {
                skeletonPlaceholder()
            } else {
                StreamedMarkdownView(
                    source: run.markdownStreamSource,
                    config: MarkdownTypography.renderConfig(
                        preset: .compact,
                        textColor: colors.textPrimary,
                        secondaryTextColor: colors.textSecondary,
                        accentColor: colors.accent,
                        animatesText: true
                    )
                )
                .contentDirectionAware(text)
            }

        case let .streamingSentencePairs(pairs, _):
            if pairs.isEmpty {
                skeletonPlaceholder()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pair.original)
                                .font(.system(size: 14))
                                .foregroundColor(colors.textSecondary)
                                .textSelection(.enabled)
                            Text(pair.translation)
                                .font(.system(size: 14))
                                .foregroundColor(colors.textPrimary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 8)
                        .transition(.opacity)

                        if index < pairs.count - 1 {
                            Divider()
                        }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: pairs.count)
            }

        case let .success(result):
            let showDiff = run.showDiff
            let runID = run.id
            VStack(alignment: .leading, spacing: 12) {
                if !result.sentencePairs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(result.sentencePairs.enumerated()), id: \.offset) { index, pair in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(pair.original)
                                    .font(.system(size: 14))
                                    .foregroundColor(colors.textSecondary)
                                    .textSelection(.enabled)
                                Text(pair.translation)
                                    .font(.system(size: 14))
                                    .foregroundColor(colors.textPrimary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 8)

                            if index < result.sentencePairs.count - 1 {
                                Divider()
                            }
                        }
                    }
                } else if let diff = result.diff, showDiff {
                    StyledDiffView(diff: diff)
                } else {
                    let mainText = !result.supplementalTexts.isEmpty ? result.copyText : result.text
                    MarkdownContentView(text: mainText, preset: textPreset)
                }

                // Suggested action chips
                if !result.suggestedActions.isEmpty, !showsOnlyResults || onResultConversation != nil {
                    suggestedActionChips(actions: result.suggestedActions, runID: runID)
                }

                // Action buttons above divider (only when supplementalTexts exist)
                if showsInlineActions, result.sentencePairs.isEmpty, !result.supplementalTexts.isEmpty {
                    HStack(spacing: 12) {
                        Spacer()
                        actionButtons(copyText: result.copyText, runID: runID)
                    }
                }

                if !result.supplementalTexts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(result.supplementalTexts.enumerated()), id: \.offset) { entry in
                            CompactMarkdownContent(text: entry.element)
                        }
                    }
                }
            }

        case let .failure(message, _, _):
            VStack(alignment: .leading, spacing: 10) {
                Text("Request Failed")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(colors.error)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        PasteboardHelper.copy(text)
    }

    private func handlePasteCommand(providers: [NSItemProvider]) {
        if let clipboardText = readImmediatePasteboardText() {
            Task { @MainActor in
                applyPastedTextIfNeeded(clipboardText)
            }
            return
        }

        guard !providers.isEmpty else { return }

        let plainTextIdentifier = UTType.plainText.identifier

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(plainTextIdentifier) {
                provider.loadItem(forTypeIdentifier: plainTextIdentifier, options: nil) { item, _ in
                    guard let text = Self.coerceLoadedItemToString(item) else { return }
                    Task { @MainActor in
                        applyPastedTextIfNeeded(text)
                    }
                }
                return
            }

            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    Task { @MainActor in
                        applyPastedTextIfNeeded(text)
                    }
                }
                return
            }
        }
    }

    private func readImmediatePasteboardText() -> String? {
        #if canImport(AppKit)
            if let text = NSPasteboard.general.string(forType: .string) {
                return text
            }
        #endif
        #if canImport(UIKit)
            if let text = UIPasteboard.general.string {
                return text
            }
        #endif
        return nil
    }

    @MainActor
    private func applyPastedTextIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        viewModel.inputText = text
        isInputExpanded = true
        viewModel.performSelectedAction()
    }

    private static func coerceLoadedItemToString(_ item: NSSecureCoding?) -> String? {
        switch item {
        case let data as Data:
            return String(data: data, encoding: .utf8)
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        default:
            return nil
        }
    }
}

#if os(iOS)
    private struct TranslationResultDetailView: View {
        @Environment(\.colorScheme) private var colorScheme

        let sourceText: String
        let actionName: String?
        let actionIcon: String?
        let modelDisplayName: String
        let durationText: String?
        let result: HomeViewModel.ModelRunViewState.SuccessResult

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        private var resultText: String {
            result.supplementalTexts.isEmpty ? result.text : result.copyText
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceSection
                    resultSection
                    supplementalSection
                }
                .padding(20)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        PasteboardHelper.copy(result.copyText)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }

        private var sourceSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(sourceText)
                    .font(.system(size: 16))
                    .foregroundStyle(colors.textPrimary)
                    .textSelection(.enabled)

                metadataRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionBackground)
        }

        private var metadataRow: some View {
            HStack(spacing: 8) {
                if let actionName, !actionName.isEmpty {
                    MetadataChipView(actionName, icon: actionIcon ?? "bolt.fill")
                }
                MetadataChipView(modelDisplayName, icon: "cpu")
                if let durationText {
                    MetadataChipView(durationText, icon: "timer")
                }
            }
        }

        @ViewBuilder
        private var resultSection: some View {
            if !result.sentencePairs.isEmpty {
                detailSection(title: "Translation") {
                    sentencePairsView
                }
            } else if let diff = result.diff {
                detailSection(title: "Result") {
                    diffView(diff)
                }
            } else {
                detailSection(title: "Result") {
                    CompactMarkdownContent(text: resultText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        @ViewBuilder
        private var supplementalSection: some View {
            if !result.supplementalTexts.isEmpty {
                detailSection(title: "More") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(result.supplementalTexts.enumerated()), id: \.offset) { entry in
                            CompactMarkdownContent(text: entry.element)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }

        private var sentencePairsView: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.sentencePairs.enumerated()), id: \.offset) { index, pair in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pair.original)
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textSecondary)
                            .textSelection(.enabled)
                        Text(pair.translation)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(colors.textPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 8)

                    if index < result.sentencePairs.count - 1 {
                        Divider()
                    }
                }
            }
        }

        private func diffView(_ diff: TextDiffBuilder.Presentation) -> some View {
            StyledDiffView(diff: diff)
        }

        private func detailSection<Content: View>(
            title: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionBackground)
        }

        private var sectionBackground: some View {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.cardBackground)
        }
    }
#endif

// MARK: - Shimmer Animation

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, .white.opacity(0.4), .clear]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.6)
                    .offset(x: -geometry.size.width * 0.3 + phase * geometry.size.width * 1.6)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    @ViewBuilder
    func homeNavigationChrome(usesNativeNavigationHeader: Bool, colors: AppColorPalette) -> some View {
        #if os(macOS)
            toolbarBackground(colors.background, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        #elseif os(iOS)
            if usesNativeNavigationHeader {
                navigationTitle("Text")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbarBackground(colors.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            } else {
                toolbar(.hidden, for: .navigationBar)
            }
        #else
            self
        #endif
    }

    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }

    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: ViewHeightPreferenceKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ViewHeightPreferenceKey.self, perform: action)
    }
}

#Preview {
    HomeView(context: nil)
        .preferredColorScheme(.dark)
}

#if os(macOS)
    public extension Notification.Name {
        /// Notification posted when text is received from macOS Services (right-click menu)
        static let serviceTextReceived = Notification.Name("serviceTextReceived")
        /// Notification posted by AppleTranslationWindowManager to register a HomeViewModel
        /// with the hidden translation window bridge. userInfo["register"] is (HomeViewModel) -> Void.
        static let appleTranslationViewModelRegister = Notification.Name("appleTranslationViewModelRegister")
        /// Notification posted by the menu bar popover to hand off its current translation
        /// state (input text, selected action, model runs) to the main window's HomeViewModel.
        /// userInfo["snapshot"] is a `HomeViewModel.StateSnapshot`.
        static let homeStateHandoff = Notification.Name("homeStateHandoff")
    }
#endif

public extension Notification.Name {
    /// Notification posted when text is received via deep link (tlingo://translate?text=...)
    static let deepLinkTextReceived = Notification.Name("deepLinkTextReceived")
}
