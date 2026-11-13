//
//  HomeView.swift
//  TLingo
//
//  Created by Zander Wang on 2025/10/19.
//

import os
import StoreKit
import SwiftUI
import Translation
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif
#if os(iOS)
    import TranslationUIProvider
#endif

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HomeView")

#if os(iOS)
    public typealias AppTranslationContext = TranslationUIProviderContext
#else
    public typealias AppTranslationContext = Never
#endif

public struct HomeView: View {
    @Environment(\.homeInputRouteID) var homeInputRouteID
    @State var inputReceiverID = UUID()
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.requestReview) var requestReview
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    #if os(iOS)
        @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif
    @StateObject var viewModel: HomeViewModel
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var entitlement = Entitlement.shared
    @State var hasTriggeredAutoRequest = false
    /// The waveform alone reads as voice input, so it carries a label until first use.
    @AppStorage("home.hasUsedRealtimeButton") var hasUsedRealtimeButton = false
    @State var recentTextRecords: [HomeRecentRecord] = []
    @State var isInputExpanded: Bool
    @State var showingProviderInfo: String?
    @State var isFallbackTargetPickerPresented = false
    @State var activeConversationSession: ConversationSession?
    @State var isConversationInspectorPresented = false
    @State var showSatisfactionToast = false
    @State var showModelSelectionSheet = false
    @State var showAIModelRequiredAlert = false
    @State var feedbackDraft: FeedbackMailDraft?
    @State var pendingPremiumPresentation = false
    @State var bottomComposerActionChipsHeight: CGFloat = 0
    @State var bottomComposerLanguageSelectorHeight: CGFloat = 0
    @State var bottomComposerWordLookupHintHeight: CGFloat = 0
    @State var bottomComposerEditorContentHeight: CGFloat = 0
    @State var isComparingResults = false
    /// Settled content height per result row, and the height held while a row reloads,
    /// so switching to sentence pairs never collapses the row before new content streams in.
    @State var resultContentHeights: [String: CGFloat] = [:]
    @State var heldResultHeights: [String: CGFloat] = [:]
    /// Flat panel and its collapsed preview block, measured to size previews to the visible area.
    @State var flatResultsPanelHeight: CGFloat = 0
    @State var collapsedResultsSize: CGSize = .zero
    #if os(iOS)
        @State var selectedResult: SelectedResult?
        @State var resultDetailDetent: PresentationDetent = .medium
    #endif
    @State var appleTranslationConfig: TranslationSession.Configuration?
    @State var appleTranslationConfigLanguagePair: (source: String?, target: String)?
    #if os(macOS)
        @State var showDataConsent = false
    #endif

    var usesConversationInspectorPresentation: Bool {
        #if os(macOS)
            return true
        #elseif os(iOS)
            return usesNativeNavigationChrome && horizontalSizeClass == .regular
        #else
            return false
        #endif
    }

    var usesNativeNavigationChrome: Bool {
        #if os(iOS)
            return usesNativeNavigationHeader && !openFromExtension
        #else
            return false
        #endif
    }

    var isConversationInspectorVisible: Bool {
        usesConversationInspectorPresentation
            && activeConversationSession != nil
            && isConversationInspectorPresented
    }

    var conversationInspectorBinding: Binding<Bool> {
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
        var conversationSheetBinding: Binding<ConversationSession?> {
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

    var usesSimplifiedTextLayout: Bool {
        #if os(iOS)
            return !openFromExtension
        #else
            return false
        #endif
    }

    var usesBottomComposerLayout: Bool {
        HomeTextLayoutPolicy.usesBottomComposerLayout(
            openFromExtension: openFromExtension,
            idiom: currentTextLayoutIdiom
        )
    }

    var satisfactionPromptPlacement: HomeSatisfactionPromptPlacement {
        HomeTextLayoutPolicy.satisfactionPromptPlacement(
            usesBottomComposerLayout: usesBottomComposerLayout,
            hasResults: !viewModel.modelRuns.isEmpty,
            openFromExtension: openFromExtension
        )
    }

    var satisfactionPromptChrome: HomeSatisfactionPromptChrome {
        HomeTextLayoutPolicy.satisfactionPromptChrome(for: satisfactionPromptPlacement)
    }

    var shouldShowSatisfactionOverlay: Bool {
        showSatisfactionToast && satisfactionPromptChrome == .toast
    }

    var shouldShowInlineSatisfactionPrompt: Bool {
        showSatisfactionToast && satisfactionPromptChrome == .resultCell
    }

    var languageSelectorPlacement: HomeLanguageSelectorPlacement {
        HomeTextLayoutPolicy.languageSelectorPlacement(
            usesBottomComposerLayout: usesBottomComposerLayout,
            usesSimplifiedTextLayout: usesSimplifiedTextLayout,
            idiom: currentTextLayoutIdiom
        )
    }

    var shouldShowLanguageSelectorAboveInput: Bool {
        languageSelectorPlacement == .aboveInput
    }

    var shouldShowLanguageSelectorInsideInput: Bool {
        languageSelectorPlacement == .insideInput
    }

    var bottomComposerPlacement: HomeBottomComposerPlacement {
        HomeTextLayoutPolicy.bottomComposerPlacement(
            usesBottomComposerLayout: usesBottomComposerLayout,
            hasResults: !viewModel.modelRuns.isEmpty,
            hasAttachments: false,
            idiom: currentTextLayoutIdiom
        )
    }

    var shouldCenterEmptyComposer: Bool {
        bottomComposerPlacement == .centeredEmptyState
    }

    /// iPhone app chrome: language pair in the navigation bar, results as a flat panel,
    /// and the realtime entry sharing the send button slot.
    var usesPhoneComposerChrome: Bool {
        usesNativeNavigationChrome && currentTextLayoutIdiom == .phone
    }

    /// iPhone and Mac show results as a flat panel with per-row sentence pairs; iPad keeps cards.
    var usesFlatResultsPanel: Bool {
        #if os(macOS)
            return true
        #else
            return usesPhoneComposerChrome
        #endif
    }

    var currentTextLayoutIdiom: HomeTextLayoutIdiom {
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
    var showsManageActionsButton: Bool {
        #if os(macOS)
            return true
        #else
            return usesSimplifiedTextLayout && !usesPhoneComposerChrome
        #endif
    }

    let context: AppTranslationContext?
    let onHistoryTap: (() -> Void)?
    let onManageActionsTap: (() -> Void)?
    let onSettingsTap: (() -> Void)?
    let onShowSidebarTap: (() -> Void)?
    let onRealtimeTap: (() -> Void)?
    let onPremiumRequired: (() -> Void)?
    let usesNativeNavigationHeader: Bool
    let showsOnlyResults: Bool
    let onResultReplace: ((String) -> Void)?
    let onResultConversation: ((ConversationSession) -> Void)?

    @ThemeColors var colors: AppColorPalette

    /// Hides the keyboard on iOS
    func hideKeyboard() {
        #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    var initialContextInput: String? {
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
    var embeddedResultsContent: some View {
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

    var fullHomeContent: some View {
        ZStack {
            homeContentLayout.erasedForLaunch()

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
                                    .tint(.primary)
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
            .erasedForLaunch()
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
                    let needsAppleConfig = appleTranslationConfig == nil
                        && preferences.enabledModelIDs.contains(ModelConfig.appleTranslateID)
                    if needsAppleConfig {
                        let target = AppPreferences.shared.targetLanguage
                        let sourceLocale = AppPreferences.shared.sourceLanguage.localeLanguage
                        let sourceKey = sourceLocale?.minimalIdentifier
                        let targetKey = target.localeLanguage.minimalIdentifier
                        appleTranslationConfigLanguagePair = (sourceKey, targetKey)
                        appleTranslationConfig = .init(source: sourceLocale, target: target.localeLanguage)
                    }
                #endif
            }
            .onAppear {
                guard !openFromExtension, let homeInputRouteID else { return }
                HomeInputRouter.shared.registerReceiver(id: inputReceiverID, routeID: homeInputRouteID) { request in
                    switch request {
                    case let .serviceText(text):
                        viewModel.inputText = text
                        viewModel.performSelectedAction()
                    case let .handoff(snapshot):
                        viewModel.adoptStateSnapshot(snapshot)
                    case let .deepLink(text, actionName, configName):
                        viewModel.applyDeepLink(text: text, actionName: actionName, configName: configName)
                    }
                    isInputExpanded = true
                }
            }
            .onDisappear {
                HomeInputRouter.shared.unregisterReceiver(id: inputReceiverID)
            }
            .erasedForLaunch()
        #if os(macOS)
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
            .erasedForLaunch()
            .translationTask(appleTranslationConfig) { session in
                logger.debug(".translationTask fired, session received")
                await viewModel.executeAppleTranslation(session: session)
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
                        let sourceKey = sourceLocale?.minimalIdentifier
                        let targetKey = target.localeLanguage.minimalIdentifier
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
    }

    @ViewBuilder
    var homeContentLayout: some View {
        if usesBottomComposerLayout {
            bottomComposerTextLayout
        } else {
            stackedTextLayout
        }
    }

    var stackedTextLayout: some View {
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

    var bottomComposerTextLayout: some View {
        GeometryReader { geometry in
            ScrollView {
                if !shouldCenterEmptyComposer {
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
                            #if os(iOS)
                                if usesPhoneComposerChrome, context == nil,
                                   viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                {
                                    phoneEmptyStateSuggestions
                                }
                            #endif
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
                    .erasedForLaunch()
                }
            }
            #if os(iOS)
            // A bar (not an inset) lets results fade under the composer instead of showing through it.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                bottomComposerDock(availableHeight: geometry.size.height, isCentered: shouldCenterEmptyComposer)
                    .erasedForLaunch()
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #else
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomComposerDock(availableHeight: geometry.size.height, isCentered: shouldCenterEmptyComposer)
            }
            #endif
            .background(colors.background.ignoresSafeArea())
            .scrollIndicators(.hidden)
            #if os(iOS)
                .onTapGesture {
                    hideKeyboard()
                }
            #endif
        }
    }

    var bottomComposerResultsTopPadding: CGFloat {
        usesPhoneComposerChrome ? 8 : 28
    }

    var bottomComposerResultsBottomPadding: CGFloat {
        16
    }

    /// Both placements share this single view tree. Swapping trees when an edit clears the results
    /// would rebuild the text view and drop its focus and IME composition (e.g. Pinyin).
    func bottomComposerDock(availableHeight: CGFloat, isCentered: Bool) -> some View {
        VStack(spacing: 14) {
            if isCentered {
                #if os(macOS)
                    // Optical center sits above the geometric one; the editor placeholder replaces the hint.
                    Spacer(minLength: 0)
                        .frame(maxHeight: availableHeight * 0.22)
                #else
                    keyboardDismissingSpacer
                #endif
            }

            bottomComposerContent(availableHeight: availableHeight)

            if isCentered {
                #if os(macOS)
                    Spacer(minLength: 0)
                #else
                    hintLabel
                        .padding(.top, 2)
                    keyboardDismissingSpacer
                #endif
            }
        }
        .frame(maxHeight: isCentered ? .infinity : nil)
        .padding(.horizontal, 20)
        .padding(.top, isCentered ? 0 : bottomComposerDockTopPadding)
        .padding(.bottom, isCentered ? 0 : bottomComposerDockBottomPadding)
        #if !os(macOS)
            .overlay(alignment: .top) {
                if isCentered, !openFromExtension, !usesNativeNavigationChrome {
                    header
                        .frame(maxWidth: bottomComposerContentMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                }
            }
        #endif
        #if os(macOS)
        .background(colors.background.opacity(colorScheme == .dark ? 0.96 : 0.94).ignoresSafeArea(edges: .bottom))
        #else
        // Opaque ground with a short fade on top, so results never read through the chips.
        .background {
            colors.background
                .mask {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .padding(.top, -20)
                .ignoresSafeArea(edges: .bottom)
        }
        #endif
    }

    #if os(iOS)
        var keyboardDismissingSpacer: some View {
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    hideKeyboard()
                }
        }
    #endif

    func bottomComposerContent(availableHeight: CGFloat) -> some View {
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

    var bottomComposerContentMaxWidth: CGFloat {
        #if os(macOS)
            return 820
        #else
            return 760
        #endif
    }

    var bottomComposerDockSpacing: CGFloat {
        10
    }

    var bottomComposerDockTopPadding: CGFloat {
        10
    }

    var bottomComposerDockBottomPadding: CGFloat {
        16
    }

    var bottomComposerInputHeight: CGFloat {
        #if os(macOS)
            return 104
        #else
            return 112
        #endif
    }

    func bottomComposerHeights(availableHeight: CGFloat) -> HomeBottomComposerHeights {
        HomeTextLayoutPolicy.bottomComposerHeights(
            availableHeight: availableHeight,
            chromeHeight: bottomComposerChromeHeight,
            compactInputHeight: bottomComposerInputHeight,
            compactEditorMinHeight: inputEditorMinHeight,
            compactEditorMaxHeight: inputEditorMaxHeight,
            measuredEditorContentHeight: bottomComposerEditorContentHeight
        )
    }

    var bottomComposerChromeHeight: CGFloat {
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

    func updateBottomComposerActionChipsHeight(_ height: CGFloat) {
        updateMeasuredHeight(height, current: bottomComposerActionChipsHeight) {
            bottomComposerActionChipsHeight = $0
        }
    }

    func updateBottomComposerLanguageSelectorHeight(_ height: CGFloat) {
        updateMeasuredHeight(height, current: bottomComposerLanguageSelectorHeight) {
            bottomComposerLanguageSelectorHeight = $0
        }
    }

    func updateBottomComposerEditorContentHeight(_ height: CGFloat) {
        updateMeasuredHeight(height, current: bottomComposerEditorContentHeight) {
            bottomComposerEditorContentHeight = $0
        }
    }

    func updateMeasuredHeight(
        _ height: CGFloat,
        current: CGFloat,
        assign: (CGFloat) -> Void
    ) {
        guard height.isFinite else { return }
        let roundedHeight = max(0, height.rounded(.up))
        guard abs(current - roundedHeight) > 0.5 else { return }
        assign(roundedHeight)
    }

    var satisfactionToastAlignment: Alignment {
        #if os(macOS)
            .bottomTrailing
        #else
            .bottom
        #endif
    }

    func dismissSatisfactionToast() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showSatisfactionToast = false
        }
    }

    func composeFeedbackEmail() {
        let draft = FeedbackMail.makeDraft()
        #if os(iOS)
            feedbackDraft = draft
        #elseif os(macOS)
            FeedbackMail.openMacComposer(draft)
        #else
            FeedbackMail.openFallback(draft)
        #endif
    }

    func satisfactionPrompt(style: SatisfactionPromptView.Style) -> some View {
        SatisfactionPromptView(
            colors: colors,
            style: style,
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

    var satisfactionPromptOverlay: some View {
        satisfactionPrompt(style: .toast)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        #if os(macOS)
            .padding(20)
        #else
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        #endif
    }

    var satisfactionPromptResultCell: some View {
        satisfactionPrompt(style: .resultCard)
    }

    var configurationLoadingOverlay: some View {
        LoadingOverlay(
            message: "Loading configuration...",
            backgroundColor: colors.background.opacity(0.9),
            messageFont: .system(size: 14),
            textColor: colors.textSecondary,
            accentColor: colors.accent,
            ignoresSafeArea: true
        )
    }
}
