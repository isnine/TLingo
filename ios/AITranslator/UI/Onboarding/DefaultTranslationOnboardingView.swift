//
//  DefaultTranslationOnboardingView.swift
//  TLingo
//

#if os(iOS)
    import Combine
    import ImageIO
    import os
    import ShareCore
    import StoreKit
    import SwiftUI
    import UIKit
    import UserNotifications

    enum DefaultTranslationOnboardingOutcome {
        case dismissed
        case upgrade
    }

    private let defaultTranslationOnboardingLogger = os.Logger(
        subsystem: "com.zanderwang.AITranslator",
        category: "DefaultTranslationOnboarding"
    )

    private enum Constants {
        enum Layout {
            static let wideWidthThreshold: CGFloat = 430
            static let horizontalPaddingWide: CGFloat = 28
            static let horizontalPaddingNarrow: CGFloat = 20
            static let mediaWidthMax: CGFloat = 380
            static let safeAreaPaddingFloor: CGFloat = 16
            static let topPaddingExtra: CGFloat = 12
            static let footerBottomPaddingExtra: CGFloat = 8
            static let compactHeightThreshold: CGFloat = 780
            static let contentTopSpacingCompact: CGFloat = 18
            static let contentTopSpacingRegular: CGFloat = 24

            static let footerBottomPadding: CGFloat = 14
            static let footerTopSpacing: CGFloat = 20
            static let scrollBottomInset: CGFloat = 110
            static let scrollFooterTopPadding: CGFloat = 20
            static let footerControlsSpacing: CGFloat = 10
            static let legalTopPadding: CGFloat = 12
            static let legalSpacing: CGFloat = 6
            static let legalLinkSpacing: CGFloat = 6

            static let introSpacing: CGFloat = 26
            static let introTextReservedHeight: CGFloat = 176
            static let textBlockSpacing: CGFloat = 8
            static let bodyLineSpacing: CGFloat = 2

            static let primaryButtonHeight: CGFloat = 50
            static let secondaryButtonHeight: CGFloat = 42

            static let dotsBottomSpacing: CGFloat = 10
            static let receiptTitleSpacing: CGFloat = 28
            static let reminderTopSpacing: CGFloat = 22
            static let trialTitleTopSpacing: CGFloat = 24

            static let dotSpacing: CGFloat = 8
            static let dotActiveWidth: CGFloat = 20
            static let dotSize: CGFloat = 7
            static let dotTouchHeight: CGFloat = dotSize + 16
        }

        enum Media {
            static let tryItGifSize = CGSize(width: 150, height: 200)
        }

        enum Receipt {
            static let settingsWidth: CGFloat = 310
            static let tryItWidth: CGFloat = 290
            static let modelsWidth: CGFloat = 290
            static let tryPremiumWidth: CGFloat = 300
            static let trialWidth: CGFloat = 270
            static let reminderWidth: CGFloat = 300
        }

        enum FontSize {
            static let pageTitle: CGFloat = 28
            static let body: CGFloat = 15
            static let caption: CGFloat = 14
            static let legalLink: CGFloat = 11
            static let legalDisclosure: CGFloat = 10
            static let primaryButton: CGFloat = 17
            static let secondaryButton: CGFloat = 15
        }

        enum Radius {
            static let receiptMedia: CGFloat = 10
            static let receiptGif: CGFloat = 8
        }

        enum Stroke {
            static let hairline: CGFloat = 1
        }

        enum Opacity {
            static let legalDisclosure: Double = 0.7
        }

        enum Animation {
            static let stepTransition: Double = 0.2
            static let celebrationIn: Double = 0.25
        }

        enum Timing {
            static let pollIntervalSeconds = 1
            static let skipRevealSecond = 8
            static let celebrationVisibleMs = 1400
            static let reviewDelayMs = 500
        }

        enum GIF {
            static let defaultFrameDuration: TimeInterval = 0.08
            static let minimumFrameDuration: TimeInterval = 0.02
        }

        enum Premium {
            static let loadingVerticalPadding: CGFloat = 20
            static let monogramSize: CGFloat = 30
        }
    }

    struct DefaultTranslationOnboardingView: View {
        let onFinished: (DefaultTranslationOnboardingOutcome) -> Void

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.requestReview) private var requestReview
        @Environment(\.scenePhase) private var scenePhase
        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var storeManager = StoreManager.shared
        @ObservedObject private var entitlement = Entitlement.shared

        @State private var step: Step = .intro
        @State private var showCelebration = false
        @State private var didTriggerSuccessEffects = false
        @State private var showTrialCelebration = false
        @State private var didCelebrateTrialInvocation = false
        @State private var trialInvocationAtEntry: Date?
        @State private var showSkipOption = false
        @State private var hasSelectedPracticeText = false
        @State private var premiumStage: PremiumStage?
        @State private var premiumModels: [ModelConfig] = []
        @State private var selectedPremiumIDs: Set<String> = []
        @State private var trialProduct: Product?
        /// Editable text the user can preview through the picked premium model.
        @State private var trialInputText: String = Self.grammarPracticeText
        @State private var trialSheetRequest: TrialSheetRequest?
        @State private var feedbackDraft: FeedbackMailDraft?
        /// nil = not resolved yet, true/false once `loadTrialProduct()` ran.
        @State private var hasFreeTrialOffer: Bool?
        @State private var showSubscriptionPaywall = false
        @State private var finishAfterSubscriptionPaywallDismiss = false
        @State private var trialNotifierToken: NSObjectProtocol?
        @State private var purchaseFailureAlert: PurchaseFailureAlert?
        /// True only while a network fetch is in flight for the premium model
        /// list. Cache-only loads keep this false so the picker doesn't flash a
        /// loading state on return visits.
        @State private var isLoadingPremiumModels = false
        /// Days-before-trial-end the user wants to be reminded. nil means no
        /// reminder ("Off") and is the default, so switching to a concrete day
        /// is what surfaces the notification permission prompt, in context.
        @State private var selectedReminderDaysBefore: Int?
        @State private var isOpeningSettings = false
        @State private var didLeaveForSettings = false

        private enum Step: Int, CaseIterable {
            case intro
            case settings
            case tryIt
            case success
        }

        private enum PremiumStage: Int, CaseIterable {
            case tryPremium
            case trialOffer
        }

        private struct TrialSheetRequest: Identifiable {
            let id = UUID()
            let inputText: String
            let models: [ModelConfig]
        }

        private struct PurchaseFailureAlert: Identifiable {
            let id = UUID()
            let title: String
            let message: String
        }

        private var selectablePremiumModels: [ModelConfig] {
            premiumModels.filter { $0.isPremium && (!$0.hidden || selectedPremiumIDs.contains($0.id)) }
        }

        private var trialModels: [ModelConfig] {
            selectablePremiumModels.filter { selectedPremiumIDs.contains($0.id) }
        }

        private struct LayoutMetrics {
            let horizontalPadding: CGFloat
            let mediaWidth: CGFloat
            let topPadding: CGFloat
            let contentTopSpacing: CGFloat
            let footerBottomPadding: CGFloat
            let fixedContentHeight: CGFloat

            init(size: CGSize, safeAreaInsets: EdgeInsets) {
                horizontalPadding = size.width >= Constants.Layout.wideWidthThreshold
                    ? Constants.Layout.horizontalPaddingWide
                    : Constants.Layout.horizontalPaddingNarrow
                mediaWidth = min(size.width - horizontalPadding * 2, Constants.Layout.mediaWidthMax)
                // The GeometryReader already sits inside the safe area, so only pad
                // by the full floor where the device has no inset of its own.
                topPadding = safeAreaInsets.top > 0 ? Constants.Layout.topPaddingExtra : Constants.Layout.safeAreaPaddingFloor
                contentTopSpacing = size.height < Constants.Layout.compactHeightThreshold
                    ? Constants.Layout.contentTopSpacingCompact
                    : Constants.Layout.contentTopSpacingRegular
                footerBottomPadding = safeAreaInsets.bottom > 0
                    ? Constants.Layout.footerBottomPaddingExtra
                    : Constants.Layout.safeAreaPaddingFloor

                let fixedFooterHeight = Constants.Layout.footerTopSpacing
                    + Constants.Layout.primaryButtonHeight
                    + Constants.Layout.footerBottomPadding
                    + Constants.Layout.dotTouchHeight
                    + footerBottomPadding
                fixedContentHeight = max(0, size.height - topPadding - fixedFooterHeight)
            }

            func mediaHeight(aspectRatio: CGFloat, maxHeight: CGFloat) -> CGFloat {
                min(mediaWidth / aspectRatio, maxHeight)
            }

            func heroScale() -> CGFloat {
                let hero = TypewriterHero.size
                let availableHeight = fixedContentHeight
                    - Constants.Layout.introSpacing
                    - Constants.Layout.introTextReservedHeight
                return max(0, min(1, mediaWidth / hero.width, availableHeight / hero.height))
            }
        }

        private static let practiceText = "The quickest way to learn a language is to use it in real moments."
        private static let grammarPracticeText = "Yesterday I go to the library to study English. " +
            "My friend help me with my homework, and we was happy with the progress. " +
            "I want to practice more so I can speaks confidently."

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        private var paper: OnboardingPaperPalette {
            OnboardingPaperPalette(colorScheme: colorScheme)
        }

        private var hasCompletedTrial: Bool {
            preferences.hasCompletedDefaultTranslationTrial
        }

        var body: some View {
            GeometryReader { proxy in
                let metrics = LayoutMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)

                ZStack {
                    paper.background
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissKeyboard()
                        }

                    ViewThatFits(in: .vertical) {
                        fixedLayout(metrics: metrics)
                        scrollingLayout(metrics: metrics)
                    }

                    if showCelebration || showTrialCelebration {
                        CelebrationOverlay(
                            colors: colors,
                            title: showTrialCelebration ? "TLingo is ready" : celebrationTitle,
                            subtitle: showTrialCelebration ? "Selected text translation is working." : celebrationSubtitle,
                            toastTopInset: showTrialCelebration ? proxy.safeAreaInsets.top + 24 : nil
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .tint(OnboardingPaperPalette.accent)
            .onAppear {
                #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-TLingoOnboardingTrialOffer") {
                        step = .success
                        premiumStage = .trialOffer
                        Task { await loadTrialProduct() }
                    }
                    if let page = UserDefaults.standard.string(forKey: "TLingoOnboardingPage") {
                        applyDebugPage(page)
                    }
                #endif
                preferences.refreshFromDefaults()
                celebrateTrialInvocationIfNeeded()
                if trialNotifierToken == nil {
                    trialNotifierToken = DefaultTranslationTrialNotifier.addObserver {
                        preferences.refreshFromDefaults()
                        celebrateTrialInvocationIfNeeded()
                    }
                }
            }
            .onDisappear {
                showTrialCelebration = false
                if let token = trialNotifierToken {
                    DefaultTranslationTrialNotifier.removeObserver(token)
                    trialNotifierToken = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
            }
            .onChange(of: step) { _, newStep in
                showTrialCelebration = false
                switch newStep {
                case .tryIt:
                    preferences.refreshFromDefaults()
                    trialInvocationAtEntry = preferences.lastDefaultTranslationTrialAt
                    didCelebrateTrialInvocation = false
                    showSkipOption = false
                case .settings:
                    // Warm the ModelsService cache the moment the user heads
                    // to system Settings — the network round-trip can finish
                    // while they're outside the app, so the premium picker
                    // shows real data immediately when they return instead of
                    // flashing an empty card.
                    if premiumModels.isEmpty {
                        Task { await loadPremiumModels() }
                    }
                default:
                    break
                }
            }
            .task(id: step) {
                guard step == .tryIt else { return }
                await pollForTrialCompletion()
            }
            .task(id: showTrialCelebration) {
                guard showTrialCelebration else { return }
                do {
                    try await Task.sleep(for: .milliseconds(Constants.Timing.celebrationVisibleMs))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                    showTrialCelebration = false
                }
            }
            .onChange(of: storeManager.isPremium) { _, isPremium in
                guard isPremium else { return }
                Task { await handlePremiumUnlocked() }
            }
            .task(id: step == .success && premiumStage == nil) {
                guard step == .success, premiumStage == nil else { return }
                if premiumModels.isEmpty {
                    await loadPremiumModels()
                }
                if hasFreeTrialOffer == nil {
                    await loadTrialProduct()
                }
            }
            .fullScreenCover(
                isPresented: $showSubscriptionPaywall,
                onDismiss: finishAfterSubscriptionPaywallDismissIfNeeded
            ) {
                PaywallView(context: .standard) {
                    finishAfterSubscriptionPaywallDismiss = true
                    showSubscriptionPaywall = false
                }
            }
            .sheet(item: $trialSheetRequest) { request in
                OnboardingTrialSheet(inputText: request.inputText, trialModels: request.models)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $feedbackDraft) { draft in
                FeedbackMailComposerView(draft: draft) {
                    feedbackDraft = nil
                }
            }
            .alert(item: $purchaseFailureAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        private func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        @ViewBuilder
        private func fixedLayout(metrics: LayoutMetrics) -> some View {
            VStack(spacing: 0) {
                pageContent(metrics: metrics, fill: true)
                    .padding(.top, metrics.topPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                progressDots
                    .padding(.top, Constants.Layout.footerTopSpacing)
                    .padding(.bottom, Constants.Layout.dotsBottomSpacing)

                footerControls
                    .padding(.bottom, metrics.footerBottomPadding)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func scrollingLayout(metrics: LayoutMetrics) -> some View {
            ScrollView {
                VStack(spacing: 0) {
                    pageContent(metrics: metrics, fill: false)
                        .padding(.top, metrics.topPadding)
                        .padding(.bottom, Constants.Layout.scrollBottomInset)
                }
                .padding(.horizontal, metrics.horizontalPadding)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Constants.Layout.dotsBottomSpacing) {
                    progressDots
                    footerControls
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, metrics.footerBottomPadding)
                .padding(.top, Constants.Layout.scrollFooterTopPadding)
                .background(paper.solidBackground)
            }
        }

        @ViewBuilder
        private func pageContent(metrics: LayoutMetrics, fill: Bool) -> some View {
            switch step {
            case .intro:
                centeredContent(fill: fill) { introPage(metrics: metrics) }
            case .settings:
                centeredContent(fill: fill) { settingsPage }
            case .tryIt:
                centeredContent(fill: fill) { tryItPage }
            case .success:
                switch premiumStage {
                case .none:
                    centeredContent(fill: fill) { modelsPage }
                case .tryPremium:
                    centeredContent(fill: fill) { tryPremiumPage }
                case .trialOffer:
                    centeredContent(fill: fill) { trialOfferPage }
                }
            }
        }

        @ViewBuilder
        private func centeredContent(fill: Bool, @ViewBuilder _ content: () -> some View) -> some View {
            if fill {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    content()
                    Spacer(minLength: 0)
                }
            } else {
                content()
            }
        }

        /// Total pages across the whole onboarding, including the premium
        /// sub-flow that follows the success step.
        private var progressTotal: Int {
            Step.allCases.count + PremiumStage.allCases.count
        }

        private var progressIndex: Int {
            if let premiumStage {
                return Step.allCases.count + premiumStage.rawValue
            }
            return step.rawValue
        }

        private var progressDots: some View {
            HStack(spacing: 0) {
                ForEach(0 ..< progressTotal, id: \.self) { index in
                    Button {
                        goToPage(index)
                    } label: {
                        Capsule()
                            .fill(
                                index == progressIndex ? paper.dotActive : paper.dotInactive
                            )
                            .frame(
                                width: index == progressIndex ? Constants.Layout.dotActiveWidth : Constants.Layout.dotSize,
                                height: Constants.Layout.dotSize
                            )
                            .padding(.horizontal, Constants.Layout.dotSpacing / 2)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .animation(.easeInOut(duration: Constants.Animation.stepTransition), value: progressIndex)
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(index < progressIndex)
                    .accessibilityLabel("Go to step \(index + 1) of \(progressTotal)")
                }
            }
        }

        /// Tap a progress dot to jump back to an earlier page. Forward jumps are
        /// disabled so required steps (e.g. the system-translation trial) aren't
        /// skipped.
        private func goToPage(_ index: Int) {
            guard index < progressIndex else { return }
            withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                let baseStepCount = Step.allCases.count
                if index < baseStepCount {
                    premiumStage = nil
                    step = Step(rawValue: index) ?? step
                } else {
                    step = .success
                    premiumStage = PremiumStage(rawValue: index - baseStepCount)
                }
            }
        }

        private func introPage(metrics: LayoutMetrics) -> some View {
            let scale = metrics.heroScale()

            return VStack(spacing: Constants.Layout.introSpacing) {
                TypewriterHero()
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: TypewriterHero.size.width * scale, height: TypewriterHero.size.height * scale)

                VStack(spacing: Constants.Layout.textBlockSpacing) {
                    pageTitle("Translate without leaving the app you're in")

                    Text("Select text anywhere and translate it from the text menu.")
                        .font(.system(size: Constants.FontSize.body))
                        .foregroundStyle(paper.subtitle)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Constants.Layout.bodyLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func pageTitle(_ title: LocalizedStringKey) -> some View {
            Text(title)
                .font(.system(size: Constants.FontSize.pageTitle, weight: .bold))
                .foregroundStyle(paper.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }

        private func receiptPage(
            _ title: LocalizedStringKey,
            @ViewBuilder receipt: () -> some View
        ) -> some View {
            VStack(spacing: Constants.Layout.receiptTitleSpacing) {
                receipt()
                pageTitle(title)
            }
            .frame(maxWidth: .infinity)
        }

        private var settingsPage: some View {
            receiptPage("Set TLingo as your translator") {
                ReceiptPaper(width: Constants.Receipt.settingsWidth) {
                    ReceiptHeader(number: 2)
                    ReceiptRule()
                    Text("Settings › Apps › Default Apps")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OnboardingPaperPalette.inkSecondary)
                    Image("DefaultTranslationSettings")
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Constants.Radius.receiptMedia, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Constants.Radius.receiptMedia, style: .continuous)
                                .stroke(.black.opacity(0.06), lineWidth: Constants.Stroke.hairline)
                        )
                        .accessibilityLabel(Text("Translation set to TLingo in Default Apps"))
                }
            }
        }

        private var tryItPage: some View {
            receiptPage(hasCompletedTrial ? "Ready" : "Try it now") {
                ReceiptPaper(width: Constants.Receipt.tryItWidth) {
                    ReceiptHeader(number: 3, leading: { EmptyView() }, trailing: {
                        TrialWaitingDot(isDone: hasCompletedTrial)
                    })
                    ReceiptRule()
                    AnimatedGIFView(assetName: "DefaultTranslationHeroAnimation")
                        .frame(width: Constants.Media.tryItGifSize.width, height: Constants.Media.tryItGifSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.Radius.receiptGif, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Constants.Radius.receiptGif, style: .continuous)
                                .stroke(.black.opacity(0.08), lineWidth: Constants.Stroke.hairline)
                        )
                        .shadow(color: paper.shadow, radius: 3, x: 0, y: 2)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    ReceiptRule()
                    SelectablePracticeTextView(text: Self.practiceText) {
                        hasSelectedPracticeText = true
                    }
                        .overlay(alignment: .topLeading) {
                            if !hasCompletedTrial, !hasSelectedPracticeText {
                                PracticeSelectionHint(phrase: "The quickest way", font: SelectablePracticeTextView.font)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: hasSelectedPracticeText)
                        .overlay(alignment: .bottomTrailing) {
                            if hasCompletedTrial {
                                ReceiptStamp(title: "RECEIVED ✓")
                                    .offset(x: 6, y: 12)
                            }
                        }
                }
            }
        }

        // MARK: - Premium try branch

        private var modelsPage: some View {
            receiptPage("Pick models to try") {
                ReceiptPaper(
                    width: Constants.Receipt.modelsWidth,
                    spacing: 6,
                    insets: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)
                ) {
                    ReceiptHeader(number: 4) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(OnboardingPaperPalette.accent)
                            .accessibilityLabel(Text("Premium Models"))
                    }
                    ReceiptRule()
                        .padding(.bottom, 4)
                    if selectablePremiumModels.isEmpty, isLoadingPremiumModels {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.85)
                            Text("Loading models…")
                                .font(.system(size: Constants.FontSize.caption, weight: .medium))
                                .foregroundStyle(OnboardingPaperPalette.inkSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Constants.Premium.loadingVerticalPadding)
                    } else {
                        ForEach(selectablePremiumModels, id: \.id) { model in
                            premiumModelRow(model)
                        }
                    }
                }
            }
        }

        private func premiumModelRow(_ model: ModelConfig) -> some View {
            let isSelected = selectedPremiumIDs.contains(model.id)
            return Button {
                togglePremiumModel(model)
            } label: {
                HStack(spacing: 12) {
                    Text(verbatim: String(model.displayName.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: Constants.Premium.monogramSize, height: Constants.Premium.monogramSize)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OnboardingPaperPalette.ink)
                        )
                        .accessibilityHidden(true)
                    Text(model.displayName)
                        .font(.system(size: Constants.FontSize.body, weight: .semibold))
                        .foregroundStyle(OnboardingPaperPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? OnboardingPaperPalette.accent : OnboardingPaperPalette.rule)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        private var tryPremiumPage: some View {
            receiptPage("Try Grammar Check") {
                ReceiptPaper(width: Constants.Receipt.tryPremiumWidth) {
                    ReceiptHeader(number: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    ReceiptRule()
                    OnboardingTrialTextEditor(
                        text: $trialInputText,
                        font: UIFontMetrics(forTextStyle: .body)
                            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular)),
                        textColor: UIColor(OnboardingPaperPalette.ink),
                        customActionTitle: String(localized: "Translate"),
                        onCustomAction: { selectedText in
                            presentTrialSheet(inputText: selectedText)
                        },
                        onFeedback: {
                            composeFeedbackEmail()
                        }
                    )
                    .padding(.horizontal, -8)
                }
            }
        }

        private func composeFeedbackEmail() {
            let draft = FeedbackMail.makeDraft(isPremium: entitlement.isPro)
            feedbackDraft = draft
        }

        private func presentTrialSheet(inputText: String) {
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let models = trialModels
            guard !trimmed.isEmpty, !models.isEmpty else { return }
            trialSheetRequest = TrialSheetRequest(inputText: trimmed, models: models)
        }

        private var isEligibleForFreeTrial: Bool {
            hasFreeTrialOffer == true
        }

        private var trialOfferPage: some View {
            VStack(spacing: 0) {
                ReceiptPaper(
                    width: Constants.Receipt.trialWidth,
                    spacing: 8,
                    insets: EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20)
                ) {
                    ReceiptHeader(number: 6) {
                        Text(verbatim: "PRO")
                    }
                    ReceiptRule()
                    if let trialEnd = trialEndDate, let price = storeManager.annualProduct?.displayPrice {
                        TrialTimeline(
                            startDate: Self.timelineDateFormatter.string(from: Date()).uppercased(),
                            reminderDate: selectedReminderDate.map { Self.timelineDateFormatter.string(from: $0).uppercased() },
                            renewDate: Self.timelineDateFormatter.string(from: trialEnd).uppercased(),
                            renewPrice: String(localized: "\(price)/yr")
                        )
                        .padding(.vertical, 4)
                        ReceiptRule()
                    }
                    HStack {
                        Text("DUE TODAY")
                        Spacer(minLength: 8)
                        Text(verbatim: dueTodayText)
                    }
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                }

                if isEligibleForFreeTrial, !reminderOptions.isEmpty {
                    reminderPicker
                        .frame(width: Constants.Receipt.reminderWidth)
                        .padding(.top, Constants.Layout.reminderTopSpacing)
                }

                pageTitle(trialOfferHeadline)
                    .padding(.top, Constants.Layout.trialTitleTopSpacing)
            }
            .frame(maxWidth: .infinity)
        }

        private var trialOfferHeadline: LocalizedStringKey {
            isEligibleForFreeTrial
                ? "Try Pro free"
                : "Unlock every AI translation model"
        }

        private var dueTodayText: String {
            guard let product = trialProduct ?? storeManager.annualProduct else { return "" }
            if isEligibleForFreeTrial {
                return Decimal.zero.formatted(product.priceFormatStyle)
            }
            return String(localized: "\(product.displayPrice)/yr")
        }

        private var selectedReminderDate: Date? {
            guard let days = selectedReminderDaysBefore, let trialEnd = trialEndDate else { return nil }
            return reminderFireDate(daysBefore: days, trialEnd: trialEnd)
        }

        private var reminderPicker: some View {
            HStack(spacing: 10) {
                Image(systemName: "bell")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(paper.title)
                    .accessibilityHidden(true)

                Picker("Trial reminder", selection: $selectedReminderDaysBefore) {
                    ForEach(reminderOptions, id: \.daysBefore) { option in
                        Text(option.segmentLabel).tag(Optional(option.daysBefore))
                    }
                    Text("Off").tag(Int?.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: selectedReminderDaysBefore) { _, newValue in
                    if newValue != nil { requestNotificationPermission() }
                }
            }
        }

        private var trialPrimaryTitle: LocalizedStringKey {
            if isEligibleForFreeTrial {
                if storeManager.isPurchasing {
                    return "Starting…"
                }
                if let duration = trialDurationText {
                    return "Start \(duration) free trial"
                }
                return "Start free trial"
            }
            return storeManager.isPurchasing ? "Subscribing…" : "Continue"
        }

        /// Maps a free-trial introductory offer's period to `DateComponents`,
        /// shared by the duration label and the trial-end date math so the two
        /// stay in sync. `.week` uses `weekOfMonth` (== `day * 7` for arithmetic)
        /// so the formatter can render "1 week" rather than "7 days".
        private func trialPeriodComponents(_ period: Product.SubscriptionPeriod) -> DateComponents? {
            var components = DateComponents()
            switch period.unit {
            case .day: components.day = period.value
            case .week: components.weekOfMonth = period.value
            case .month: components.month = period.value
            case .year: components.year = period.value
            @unknown default: return nil
            }
            return components
        }

        private var trialDurationText: String? {
            guard isEligibleForFreeTrial,
                  let trialProduct,
                  let offer = trialProduct.subscription?.introductoryOffer,
                  offer.paymentMode == .freeTrial,
                  let components = trialPeriodComponents(offer.period)
            else { return nil }
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.day, .weekOfMonth, .month, .year]
            formatter.maximumUnitCount = 1
            return formatter.string(from: components)
        }

        private struct ReminderOption {
            let daysBefore: Int
            let segmentLabel: String
        }

        private static let timelineDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            return formatter
        }()

        /// When the free trial would end, relative to now. nil when the
        /// resolved product carries no free-trial introductory offer.
        private var trialEndDate: Date? {
            guard isEligibleForFreeTrial,
                  let offer = trialProduct?.subscription?.introductoryOffer,
                  offer.paymentMode == .freeTrial,
                  let components = trialPeriodComponents(offer.period)
            else { return nil }
            return Calendar.current.date(byAdding: components, to: Date())
        }

        /// Reminder fires at 9 AM local on the day `daysBefore` the trial ends.
        private func reminderFireDate(daysBefore: Int, trialEnd: Date) -> Date? {
            let calendar = Calendar.current
            guard let shifted = calendar.date(byAdding: .day, value: -daysBefore, to: trialEnd) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: shifted)
        }

        private var reminderOptions: [ReminderOption] {
            guard let trialEnd = trialEndDate else { return [] }
            let now = Date()
            return [2, 1].compactMap { days in
                guard let fireDate = reminderFireDate(daysBefore: days, trialEnd: trialEnd), fireDate > now else {
                    return nil
                }
                let segmentLabel = days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
                return ReminderOption(
                    daysBefore: days,
                    segmentLabel: segmentLabel
                )
            }
        }

        /// Requests local-notification authorization. Local notifications need
        /// no entitlement or Info.plist key — only this runtime authorization,
        /// and asking again once the status is determined is a no-op.
        @discardableResult
        private func requestNotificationAuthorization() async -> Bool {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }

        /// Surface the notification permission prompt in context the moment the
        /// user opts into a reminder, rather than deferring it to schedule time.
        private func requestNotificationPermission() {
            Task { await requestNotificationAuthorization() }
        }

        private func scheduleSelectedReminders() {
            guard let days = selectedReminderDaysBefore,
                  let trialEnd = trialEndDate,
                  let fireDate = reminderFireDate(daysBefore: days, trialEnd: trialEnd),
                  fireDate > Date()
            else { return }

            Task {
                guard await requestNotificationAuthorization() else { return }
                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Your TLingo trial is ending")
                content.body = days == 1
                    ? String(localized: "Your free trial ends tomorrow. Tap to manage your subscription.")
                    : String(localized: "Your free trial ends in \(days) days. Tap to manage your subscription.")
                content.sound = .default
                TrialReminderNotification.configure(content)
                let triggerComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: fireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
                let request = UNNotificationRequest(
                    identifier: TrialReminderNotification.identifier,
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }

        private func togglePremiumModel(_ model: ModelConfig) {
            if selectedPremiumIDs.contains(model.id) {
                guard selectedPremiumIDs.count > 1 else { return }
                selectedPremiumIDs.remove(model.id)
            } else {
                selectedPremiumIDs.insert(model.id)
            }
        }

        private func loadPremiumModels() async {
            let cached = (ModelsService.shared.getCachedModels() ?? []).filter { $0.isPremium && !$0.hidden }
            if !cached.isEmpty {
                applyPremiumModels(cached)
                return
            }
            isLoadingPremiumModels = true
            defer { isLoadingPremiumModels = false }
            let fetched = (try? await ModelsService.shared.fetchModels()) ?? []
            applyPremiumModels(fetched.filter { $0.isPremium && !$0.hidden })
        }

        private func applyPremiumModels(_ models: [ModelConfig]) {
            // The picker showcases "power" models, so exclude nano-tier models.
            // Matched by naming convention (id contains "nano") since the model
            // list is fetched dynamically and carries no explicit tier field.
            let powerModels = models.filter { !$0.id.lowercased().contains("nano") }
            premiumModels = powerModels
            if selectedPremiumIDs.isEmpty {
                selectedPremiumIDs = Set(powerModels.prefix(4).map(\.id))
            }
        }

        private func loadTrialProduct() async {
            if storeManager.annualProduct == nil {
                await storeManager.loadProducts()
            }

            guard let annualProduct = storeManager.annualProduct else {
                trialProduct = nil
                hasFreeTrialOffer = false
                defaultTranslationOnboardingLogger
                    .error("Annual product missing for onboarding trial")
                return
            }

            trialProduct = annualProduct
            guard let subscription = annualProduct.subscription,
                  let offer = subscription.introductoryOffer,
                  offer.paymentMode == .freeTrial,
                  await subscription.isEligibleForIntroOffer
            else {
                hasFreeTrialOffer = false
                defaultTranslationOnboardingLogger
                    .info("Annual product available without eligible free trial; continuing annual onboarding purchase flow")
                return
            }
            hasFreeTrialOffer = true
        }

        private func advanceToTryPremium() {
            withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                premiumStage = .tryPremium
            }
        }

        /// Resolve trial eligibility once, then keep the user inside the
        /// onboarding flow. Lack of free-trial eligibility only changes copy;
        /// it should not jump to the full subscription sheet.
        private func advanceFromTryPremium() {
            Task {
                if hasFreeTrialOffer == nil {
                    await loadTrialProduct()
                }
                if trialProduct == nil {
                    defaultTranslationOnboardingLogger
                        .error("Annual product missing; opening full subscription paywall fallback")
                    showSubscriptionPaywall = true
                } else {
                    withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                        premiumStage = .trialOffer
                    }
                }
            }
        }

        private func startFreeTrial() async {
            guard let trialProduct else {
                defaultTranslationOnboardingLogger
                    .error("Annual product unavailable at purchase start; opening full subscription paywall fallback")
                showSubscriptionPaywall = true
                return
            }
            await storeManager.purchase(trialProduct)
            await entitlement.refresh()
            #if DEBUG
                let shouldFinishForDebugDeviceVerification = storeManager.purchaseFailedDeviceVerification
            #else
                let shouldFinishForDebugDeviceVerification = false
            #endif
            if entitlement.isPro || storeManager.isPremium {
                defaultTranslationOnboardingLogger.info("Premium detected after onboarding annual purchase; finishing onboarding")
                await handlePremiumUnlocked()
            } else if shouldFinishForDebugDeviceVerification {
                defaultTranslationOnboardingLogger
                    .warning("Debug StoreKit invalidDeviceVerification; finishing onboarding test flow")
                await handlePremiumUnlocked()
            } else if let message = storeManager.purchaseError {
                defaultTranslationOnboardingLogger
                    .error("Onboarding annual purchase failed without premium after refresh: \(message, privacy: .public)")
                purchaseFailureAlert = PurchaseFailureAlert(
                    title: String(localized: "Purchase Not Verified"),
                    message: String(
                        localized: "The App Store could not verify this purchase. Simulator StoreKit may fail test verification."
                    )
                )
            } else {
                defaultTranslationOnboardingLogger
                    .info("Onboarding annual purchase returned without premium or error; waiting for transaction updates")
            }
        }

        private func handlePremiumUnlocked() async {
            defaultTranslationOnboardingLogger.info("Premium unlocked during onboarding; finishing onboarding")
            // Persist the picked premium models only once the user actually
            // subscribes — browsing other plans must leave their model list
            // untouched.
            let catalog = ModelsService.shared.getCachedModels() ?? []
            let base = preferences.enabledModelIDs.isEmpty
                ? ModelConfig.defaultEnabledModelIDs(cloudModels: catalog)
                : preferences.enabledModelIDs
            preferences.setEnabledModelIDs(base.union(selectedPremiumIDs))
            if isEligibleForFreeTrial {
                scheduleSelectedReminders()
            }
            // Reuse the success celebration + review prompt so an in-flow
            // trial purchase gets the same confetti and rating ask as the
            // "Start translating" path. celebrateThenFinish self-guards
            // against duplicate triggers, so the fullScreenCover paywall
            // route stays correct too.
            await celebrateThenFinish()
        }

        private func finishAfterSubscriptionPaywallDismissIfNeeded() {
            guard finishAfterSubscriptionPaywallDismiss else { return }
            finishAfterSubscriptionPaywallDismiss = false
            onFinished(.dismissed)
        }

        @ViewBuilder
        private var footerControls: some View {
            VStack(spacing: Constants.Layout.footerControlsSpacing) {
                switch step {
                case .intro:
                    primaryButton("Continue") {
                        withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                            step = .settings
                        }
                    }
                case .settings:
                    if didLeaveForSettings {
                        primaryButton("I've set it up", action: advanceToTryIt)
                        secondaryButton("Open Settings", action: openDefaultTranslationSettings)
                    } else {
                        primaryButton("Open Settings", action: openDefaultTranslationSettings)
                        secondaryButton("I've set it up", action: advanceToTryIt)
                    }
                case .tryIt:
                    if !hasCompletedTrial, showSkipOption {
                        Button("Skip for now") {
                            withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                                step = .success
                            }
                        }
                        .font(.system(size: Constants.FontSize.caption, weight: .semibold))
                        .foregroundStyle(OnboardingPaperPalette.accentDeep)
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                    primaryButton("Continue", isDisabled: !hasCompletedTrial) {
                        withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                            step = .success
                        }
                    }
                    secondaryButton("Back to setup") {
                        withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                            step = .settings
                        }
                    }
                case .success:
                    successFooter
                }
            }
        }

        private func advanceToTryIt() {
            withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                step = .tryIt
            }
        }

        @ViewBuilder
        private var successFooter: some View {
            switch premiumStage {
            case .none:
                primaryButton("Try Grammar Check", isDisabled: selectedPremiumIDs.isEmpty) {
                    advanceToTryPremium()
                }
                secondaryButton("Start translating") {
                    Task { await celebrateThenFinish() }
                }
            case .tryPremium:
                primaryButton("Continue") {
                    advanceFromTryPremium()
                }
                secondaryButton("Back") {
                    withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                        premiumStage = nil
                    }
                }
            case .trialOffer:
                primaryButton(trialPrimaryTitle, isDisabled: storeManager.isPurchasing) {
                    Task { await startFreeTrial() }
                }
                secondaryButton("View other subscription plans") {
                    showSubscriptionPaywall = true
                }
                trialLegalFooter
            }
        }

        private static let privacyPolicyURL = URL(
            string: "https://tlingo.zanderwang.com/privacy/"
        )!
        private static let termsOfUseURL = URL(
            string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
        )!

        private var trialLegalFooter: some View {
            VStack(spacing: Constants.Layout.legalSpacing) {
                HStack(spacing: Constants.Layout.legalLinkSpacing) {
                    Button("Restore") {
                        Task {
                            await storeManager.restorePurchases()
                            await entitlement.refresh()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(storeManager.isPurchasing)

                    Text(verbatim: "·")
                    Link("Terms of Use", destination: Self.termsOfUseURL)
                    Text(verbatim: "·")
                    Link("Privacy Policy", destination: Self.privacyPolicyURL)
                }
                .font(.system(size: Constants.FontSize.legalLink, weight: .medium))
                .foregroundStyle(paper.subtitle)

                let renewalText = String(localized: "Subscriptions renew automatically.")
                let cancellationText = String(
                    localized: "Cancel at least 24 hours before the end of the current period to avoid renewal."
                )
                Text("\(renewalText) \(cancellationText)")
                    .font(.system(size: Constants.FontSize.legalDisclosure))
                    .foregroundStyle(paper.subtitle.opacity(Constants.Opacity.legalDisclosure))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Constants.Layout.legalTopPadding)
        }

        private func primaryButton(
            _ title: LocalizedStringKey,
            isDisabled: Bool = false,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: Constants.FontSize.primaryButton, weight: .semibold))
                    .foregroundStyle(paper.buttonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: Constants.Layout.primaryButtonHeight)
                    .background(Capsule().fill(isDisabled ? paper.disabledButtonFill : paper.buttonFill))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }

        private func secondaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: Constants.FontSize.secondaryButton, weight: .medium))
                    .foregroundStyle(paper.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: Constants.Layout.secondaryButtonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private func openDefaultTranslationSettings() {
            let settingsURL: URL?
            if #available(iOS 18.4, *) {
                settingsURL = URL(string: UIApplication.openDefaultApplicationsSettingsURLString)
            } else {
                settingsURL = URL(string: UIApplication.openSettingsURLString)
            }

            guard let settingsURL else { return }
            isOpeningSettings = true
            UIApplication.shared.open(settingsURL)
        }

        private func handleScenePhaseChange(_ phase: ScenePhase) {
            if phase == .background, isOpeningSettings {
                isOpeningSettings = false
                didLeaveForSettings = true
            }
            guard phase == .active else { return }
            preferences.refreshFromDefaults()
            celebrateTrialInvocationIfNeeded()
        }

        private func celebrateTrialInvocationIfNeeded() {
            guard step == .tryIt, !didCelebrateTrialInvocation else { return }
            // Only an invocation recorded after entering .tryIt counts; a late
            // notification from an earlier invocation must not celebrate.
            guard preferences.lastDefaultTranslationTrialAt != trialInvocationAtEntry else { return }
            didCelebrateTrialInvocation = true
            withAnimation(.easeOut(duration: Constants.Animation.celebrationIn)) {
                showTrialCelebration = true
            }
        }

        private func pollForTrialCompletion() async {
            // Darwin notification + scenePhase already drive the fast path;
            // this poll is the safety net for the rare case where neither
            // fires (e.g. notification delivery is throttled). Keep it running
            // for the lifetime of the .tryIt step instead of timing out after
            // a fixed window — a 24s cap left late returners stuck on a
            // greyed-out Continue button.
            var second = 0
            while !Task.isCancelled {
                preferences.refreshFromDefaults()
                celebrateTrialInvocationIfNeeded()
                // Continue is gated on the completion flag, so keep polling until
                // it is visible even if a notification already triggered the toast.
                if didCelebrateTrialInvocation, hasCompletedTrial {
                    return
                }
                if second == Constants.Timing.skipRevealSecond {
                    withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                        showSkipOption = true
                    }
                }
                try? await Task.sleep(for: .seconds(Constants.Timing.pollIntervalSeconds))
                second += Constants.Timing.pollIntervalSeconds
            }
        }

        #if DEBUG
            private func applyDebugPage(_ page: String) {
                switch page {
                case "settings":
                    step = .settings
                case "tryIt":
                    step = .tryIt
                case "models":
                    step = .success
                case "tryPremium":
                    step = .success
                    premiumStage = .tryPremium
                    Task { await loadPremiumModels() }
                case "trialOffer":
                    step = .success
                    premiumStage = .trialOffer
                    Task { await loadTrialProduct() }
                default:
                    break
                }
            }
        #endif

        private var celebrationTitle: LocalizedStringKey {
            storeManager.isPremium ? "Thank You for Subscribing!" : "TLingo is ready"
        }

        private var celebrationSubtitle: LocalizedStringKey {
            storeManager.isPremium
                ? "Premium features are now unlocked."
                : "Selected text translation is working."
        }

        private func celebrateThenFinish() async {
            guard !didTriggerSuccessEffects else { return }
            didTriggerSuccessEffects = true
            withAnimation(.easeOut(duration: Constants.Animation.celebrationIn)) {
                showCelebration = true
            }
            try? await Task.sleep(for: .milliseconds(Constants.Timing.celebrationVisibleMs))
            withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                showCelebration = false
            }
            try? await Task.sleep(for: .milliseconds(Constants.Timing.reviewDelayMs))
            requestReview()
            onFinished(.dismissed)
        }
    }

    private struct TrialWaitingDot: View {
        let isDone: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Circle()
                .fill(isDone ? OnboardingPaperPalette.success : OnboardingPaperPalette.accentDeep)
                .frame(width: 7, height: 7)
                .phaseAnimator([1.0, 0.25]) { content, opacity in
                    content.opacity(isDone || reduceMotion ? 1 : opacity)
                } animation: { _ in
                    .linear(duration: 0.5)
                }
                .accessibilityHidden(true)
        }
    }

    private struct SelectablePracticeTextView: UIViewRepresentable {
        static var font: UIFont {
            UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .semibold))
        }

        let text: String
        var onSelect: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onSelect: onSelect)
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.delegate = context.coordinator
            textView.isEditable = false
            textView.isSelectable = true
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textColor = UIColor(OnboardingPaperPalette.ink)
            textView.font = Self.font
            textView.adjustsFontForContentSizeCategory = true
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            textView.text = text
            context.coordinator.onSelect = onSelect
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var onSelect: () -> Void

            init(onSelect: @escaping () -> Void) {
                self.onSelect = onSelect
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                guard textView.selectedRange.length > 0 else { return }
                onSelect()
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize? {
            let width = proposal.width ?? 0
            guard width > 0 else { return nil }
            let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: size.height)
        }
    }

    /// Looping finger that long-presses and drags across the practice text so people know it is selectable.
    private struct PracticeSelectionHint: View {
        let phrase: String
        let font: UIFont

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let cycle: TimeInterval = 3.4

        var body: some View {
            if reduceMotion {
                frame(progress: 0.75)
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    frame(progress: time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle)
                }
            }
        }

        private func frame(progress: Double) -> some View {
            let lineHeight = font.lineHeight
            let phraseWidth = (phrase as NSString).size(withAttributes: [.font: font]).width
            let firstWordWidth = ((phrase.split(separator: " ").first.map(String.init) ?? phrase) as NSString)
                .size(withAttributes: [.font: font]).width

            let approach = Self.ramp(progress, from: 0.05, to: 0.22)
            let pressed = progress > 0.24 && progress < 0.72
            let drag = Self.ramp(progress, from: 0.3, to: 0.62)
            let fadeOut = 1 - Self.ramp(progress, from: 0.86, to: 0.98)
            let highlightWidth = progress < 0.24 ? 0 : firstWordWidth + (phraseWidth - firstWordWidth) * drag
            let fingerX = (progress < 0.3 ? firstWordWidth / 2 : firstWordWidth / 2 + (phraseWidth - firstWordWidth / 2) * drag)
            let fingerY = lineHeight * 0.55 + 36 * (1 - approach)

            return ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(OnboardingPaperPalette.accent.opacity(0.22))
                    .frame(width: max(highlightWidth, 0), height: lineHeight)
                    .opacity(highlightWidth > 0 ? fadeOut : 0)

                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(OnboardingPaperPalette.ink)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    .scaleEffect(pressed ? 0.88 : 1, anchor: .topLeading)
                    .offset(x: fingerX - 6, y: fingerY)
                    .opacity(approach * fadeOut)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        private static func ramp(_ value: Double, from start: Double, to end: Double) -> Double {
            let t = min(max((value - start) / (end - start), 0), 1)
            return t * t * (3 - 2 * t)
        }
    }

    private struct AnimatedGIFView: UIViewRepresentable {
        let assetName: String

        func makeUIView(context _: Context) -> UIImageView {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.backgroundColor = .clear
            imageView.image = animatedImage()
            imageView.startAnimating()
            return imageView
        }

        func updateUIView(_ imageView: UIImageView, context _: Context) {
            if imageView.image == nil {
                imageView.image = animatedImage()
            }
            imageView.startAnimating()
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView _: UIImageView, context _: Context) -> CGSize? {
            guard let width = proposal.width, let height = proposal.height else { return nil }
            return CGSize(width: width, height: height)
        }

        private func animatedImage() -> UIImage? {
            guard let data = NSDataAsset(name: assetName)?.data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }

            let frameCount = CGImageSourceGetCount(source)
            var frames: [UIImage] = []
            var duration = 0.0

            for index in 0 ..< frameCount {
                guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                frames.append(UIImage(cgImage: cgImage))
                duration += frameDuration(at: index, source: source)
            }

            guard !frames.isEmpty else { return nil }
            return UIImage.animatedImage(with: frames, duration: duration)
        }

        private func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            else { return Constants.GIF.defaultFrameDuration }

            let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval
            let delay = gifProperties[kCGImagePropertyGIFDelayTime] as? TimeInterval
            let duration = unclampedDelay ?? delay ?? Constants.GIF.defaultFrameDuration
            return duration < Constants.GIF.minimumFrameDuration ? Constants.GIF.defaultFrameDuration : duration
        }
    }

    #Preview {
        DefaultTranslationOnboardingView { _ in }
    }
#endif
