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
            static let scrollFooterSpacing: CGFloat = 14
            static let scrollFooterTopPadding: CGFloat = 20
            static let footerControlsSpacing: CGFloat = 10

            static let introSpacing: CGFloat = 20
            static let introTextReservedHeight: CGFloat = 176
            static let introMediaHeightRatio: CGFloat = 0.64
            static let textBlockSpacing: CGFloat = 8
            static let bodyLineSpacing: CGFloat = 2
            static let settingsSpacing: CGFloat = 22
            static let settingsTitleSpacing: CGFloat = 12
            static let setupStepsSpacing: CGFloat = 10
            static let cardPadding: CGFloat = 16
            static let tryItSpacing: CGFloat = 18
            static let practiceCardMinHeight: CGFloat = 150
            static let practiceCardPadding: CGFloat = 14
            static let practiceCardBottomSpacing: CGFloat = 20
            static let statusSpacing: CGFloat = 8
            static let successSpacing: CGFloat = 20
            static let successSealSize: CGFloat = 88
            static let benefitsSpacing: CGFloat = 12
            static let benefitsCardTopPadding: CGFloat = 4
            static let successTopPadding: CGFloat = 40

            static let primaryButtonHeight: CGFloat = 50
            static let secondaryButtonHeight: CGFloat = 42
            static let stepBadgeSize: CGFloat = 22
            static let setupStepSpacing: CGFloat = 10
            static let benefitRowSpacing: CGFloat = 12
            static let benefitIconSize: CGFloat = 26
            static let benefitTextSpacing: CGFloat = 2

            static let dotSpacing: CGFloat = 8
            static let dotActiveWidth: CGFloat = 20
            static let dotSize: CGFloat = 7
            static let dotTouchHeight: CGFloat = dotSize + 16
        }

        enum Media {
            static let heroAspectRatio: CGFloat = 640.0 / 854.0
            static let introGifMinHeight: CGFloat = 280
            static let settingsAspectRatio: CGFloat = 720.0 / 440.0
            static let settingsImageMaxHeight: CGFloat = 240
            static let tryItGifMaxHeight: CGFloat = 220
        }

        enum FontSize {
            static let introTitle: CGFloat = 28
            static let pageTitle: CGFloat = 26
            static let successTitle: CGFloat = 30
            static let body: CGFloat = 15
            static let caption: CGFloat = 14
            static let small: CGFloat = 12
            static let primaryButton: CGFloat = 17
            static let secondaryButton: CGFloat = 15
            static let statusIcon: CGFloat = 15
            static let benefitIcon: CGFloat = 17
            static let successSeal: CGFloat = 60
        }

        enum Radius {
            static let card: CGFloat = 14
            static let button: CGFloat = 12
            static let media: CGFloat = 18
        }

        enum Stroke {
            static let hairline: CGFloat = 1
        }

        enum Shadow {
            static let radius: CGFloat = 16
            static let yOffset: CGFloat = 8
            static let darkOpacity: Double = 0.24
            static let lightOpacity: Double = 0.08
        }

        enum Opacity {
            static let inactiveDot: Double = 0.25
            static let disabledButton: Double = 0.28
            static let sealTint: Double = 0.14
            static let sealFallbackTint: Double = 0.10
            static let sealFallbackStroke: Double = 0.24
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
            static let sectionSpacing: CGFloat = 18
            static let rowVerticalPadding: CGFloat = 13
            static let rowHorizontalPadding: CGFloat = 16
            static let rowIconWidth: CGFloat = 24
            static let ctaTopSpacing: CGFloat = 8
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
        @State private var trialCompletedAtEntry = false
        @State private var showSkipOption = false
        @State private var premiumStage: PremiumStage?
        @State private var premiumModels: [ModelConfig] = []
        @State private var selectedPremiumIDs: Set<String> = []
        @State private var trialProduct: Product?
        /// Editable text the user can preview through the picked premium model.
        @State private var trialInputText: String = Self.practiceText
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
                topPadding = max(Constants.Layout.safeAreaPaddingFloor, safeAreaInsets.top + Constants.Layout.topPaddingExtra)
                contentTopSpacing = size.height < Constants.Layout.compactHeightThreshold
                    ? Constants.Layout.contentTopSpacingCompact
                    : Constants.Layout.contentTopSpacingRegular
                footerBottomPadding = max(
                    Constants.Layout.safeAreaPaddingFloor,
                    safeAreaInsets.bottom + Constants.Layout.footerBottomPaddingExtra
                )

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

            func introMediaSize() -> CGSize {
                let naturalHeight = mediaWidth / Constants.Media.heroAspectRatio
                let availableHeight = fixedContentHeight
                    - Constants.Layout.introSpacing
                    - Constants.Layout.introTextReservedHeight
                let preferredHeight = min(naturalHeight, fixedContentHeight * Constants.Layout.introMediaHeightRatio)
                let height = availableHeight >= Constants.Media.introGifMinHeight
                    ? min(preferredHeight, availableHeight)
                    : max(0, availableHeight)
                return CGSize(width: min(mediaWidth, height * Constants.Media.heroAspectRatio), height: height)
            }
        }

        private static let practiceText = "The quickest way to learn a language is to use it in real moments."

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        private var hasCompletedTrial: Bool {
            preferences.hasCompletedDefaultTranslationTrial
        }

        var body: some View {
            GeometryReader { proxy in
                let metrics = LayoutMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)

                ZStack {
                    colors.background
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissKeyboard()
                        }

                    ViewThatFits(in: .vertical) {
                        fixedLayout(metrics: metrics)
                        scrollingLayout(metrics: metrics)
                    }

                    if showCelebration {
                        CelebrationOverlay(
                            colors: colors,
                            title: celebrationTitle,
                            subtitle: celebrationSubtitle
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .tint(colors.accent)
            .onAppear {
                preferences.refreshFromDefaults()
                advanceToSuccessIfNeeded()
                if trialNotifierToken == nil {
                    trialNotifierToken = DefaultTranslationTrialNotifier.addObserver {
                        preferences.refreshFromDefaults()
                        advanceToSuccessIfNeeded()
                    }
                }
            }
            .onDisappear {
                if let token = trialNotifierToken {
                    DefaultTranslationTrialNotifier.removeObserver(token)
                    trialNotifierToken = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
            }
            .onChange(of: step) { _, newStep in
                switch newStep {
                case .tryIt:
                    preferences.refreshFromDefaults()
                    trialCompletedAtEntry = preferences.hasCompletedDefaultTranslationTrial
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

                footerControls
                    .padding(.top, Constants.Layout.footerTopSpacing)
                    .padding(.bottom, Constants.Layout.footerBottomPadding)

                progressDots
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
                VStack(spacing: Constants.Layout.scrollFooterSpacing) {
                    footerControls
                    progressDots
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, metrics.footerBottomPadding)
                .padding(.top, Constants.Layout.scrollFooterTopPadding)
                .background(colors.background)
            }
        }

        @ViewBuilder
        private func pageContent(metrics: LayoutMetrics, fill: Bool) -> some View {
            switch step {
            case .intro:
                centeredContent(fill: fill) { introPage(metrics: metrics) }
            case .settings:
                centeredContent(fill: fill) { settingsPage(metrics: metrics) }
            case .tryIt:
                tryItPage(metrics: metrics, fill: fill)
            case .success:
                switch premiumStage {
                case .none:
                    successPageContent(fill: fill)
                case .tryPremium:
                    centeredContent(fill: fill) { tryPremiumPage(metrics: metrics) }
                case .trialOffer:
                    centeredContent(fill: fill) { trialOfferPage }
                }
            }
        }

        @ViewBuilder
        private func successPageContent(fill: Bool) -> some View {
            if fill {
                VStack(spacing: 0) {
                    successPage
                    Spacer(minLength: 0)
                }
            } else {
                successPage
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
                                index == progressIndex ? colors.accent : colors.textSecondary
                                    .opacity(Constants.Opacity.inactiveDot)
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
                    .disabled(index >= progressIndex)
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
            let heroSize = metrics.introMediaSize()

            return VStack(spacing: Constants.Layout.introSpacing) {
                animatedScreenshot(
                    "DefaultTranslationHeroAnimation",
                    width: heroSize.width,
                    height: heroSize.height
                )

                VStack(spacing: Constants.Layout.textBlockSpacing) {
                    Text("Translate without leaving the app you're in")
                        .font(.system(size: Constants.FontSize.introTitle, weight: .bold))
                        .foregroundColor(colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Select text anywhere and translate it from the text menu.")
                        .font(.system(size: Constants.FontSize.body))
                        .foregroundColor(colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Constants.Layout.bodyLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func settingsPage(metrics: LayoutMetrics) -> some View {
            let settingsHeight = metrics.mediaHeight(
                aspectRatio: Constants.Media.settingsAspectRatio,
                maxHeight: Constants.Media.settingsImageMaxHeight
            )

            return VStack(spacing: Constants.Layout.settingsSpacing) {
                screenshot(
                    "DefaultTranslationSettings",
                    width: settingsHeight * Constants.Media.settingsAspectRatio,
                    height: settingsHeight
                )

                VStack(spacing: Constants.Layout.settingsTitleSpacing) {
                    Text("Choose TLingo in Settings")
                        .font(.system(size: Constants.FontSize.pageTitle, weight: .bold))
                        .foregroundColor(colors.textPrimary)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: Constants.Layout.setupStepsSpacing) {
                        setupStep(number: 1, text: "Open Settings > Apps > Default Apps > Translation")
                        setupStep(number: 2, text: "Select TLingo")
                    }
                    .padding(Constants.Layout.cardPadding)
                    .background(cardBackground)
                }
            }
        }

        private func tryItPage(metrics: LayoutMetrics, fill: Bool) -> some View {
            let gifHeight = metrics.mediaHeight(
                aspectRatio: Constants.Media.heroAspectRatio,
                maxHeight: Constants.Media.tryItGifMaxHeight
            )

            return VStack(spacing: Constants.Layout.tryItSpacing) {
                animatedScreenshot(
                    "DefaultTranslationHeroAnimation",
                    width: gifHeight * Constants.Media.heroAspectRatio,
                    height: gifHeight
                )

                VStack(spacing: Constants.Layout.textBlockSpacing) {
                    Text("Translate this sentence now")
                        .font(.system(size: Constants.FontSize.pageTitle, weight: .bold))
                        .foregroundColor(colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Select this sentence, then tap Translate from the text menu.")
                        .font(.system(size: Constants.FontSize.body))
                        .foregroundColor(colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Constants.Layout.bodyLineSpacing)
                }

                SelectablePracticeTextView(text: Self.practiceText)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Constants.Layout.practiceCardMinHeight,
                        maxHeight: fill ? .infinity : nil,
                        alignment: .topLeading
                    )
                    .padding(Constants.Layout.practiceCardPadding)
                    .background(cardBackground)
                    .frame(maxWidth: metrics.mediaWidth)
                    .padding(.bottom, Constants.Layout.practiceCardBottomSpacing)
            }
            .frame(maxWidth: .infinity)
        }

        private var trialStatusIndicator: some View {
            HStack(spacing: Constants.Layout.statusSpacing) {
                Image(systemName: hasCompletedTrial ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: Constants.FontSize.statusIcon, weight: .semibold))
                Text(
                    hasCompletedTrial ? String(localized: "TLingo opened successfully.") :
                        String(localized: "Waiting for you to try it...")
                )
                .font(.system(size: Constants.FontSize.caption, weight: .medium))

                if !hasCompletedTrial, showSkipOption {
                    Button("Skip for now") {
                        onFinished(.dismissed)
                    }
                    .font(.system(size: Constants.FontSize.caption, weight: .semibold))
                    .foregroundColor(colors.accent)
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .foregroundColor(hasCompletedTrial ? colors.success : colors.textSecondary)
        }

        private var successPage: some View {
            VStack(spacing: Constants.Layout.successSpacing) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: Constants.FontSize.successSeal, weight: .bold))
                    .foregroundStyle(colors.success)
                    .frame(width: Constants.Layout.successSealSize, height: Constants.Layout.successSealSize)
                    .tlingoGlassCircle(
                        tint: colors.success.opacity(Constants.Opacity.sealTint),
                        fallbackTint: colors.success.opacity(Constants.Opacity.sealFallbackTint),
                        fallbackStroke: colors.success.opacity(Constants.Opacity.sealFallbackStroke)
                    )

                VStack(spacing: Constants.Layout.textBlockSpacing) {
                    Text("You're ready to translate")
                        .font(.system(size: Constants.FontSize.successTitle, weight: .bold))
                        .foregroundColor(colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Translate selected text without copying and pasting. Try a model that preserves your meaning.")
                        .font(.system(size: Constants.FontSize.body))
                        .foregroundColor(colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Constants.Layout.bodyLineSpacing)
                }

                premiumModelPickerCard
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - Premium try branch

        @ViewBuilder
        private var premiumModelPickerCard: some View {
            if selectablePremiumModels.isEmpty, isLoadingPremiumModels {
                premiumModelsLoadingPlaceholder
            } else {
                ModelSectionCard(
                    title: "Premium Models",
                    icon: "crown.fill",
                    tint: .orange,
                    models: selectablePremiumModels,
                    dividerLeadingPadding: Constants.Premium.rowHorizontalPadding * 2 + Constants.Premium.rowIconWidth
                ) { model in
                    premiumModelRow(model)
                }
            }
        }

        private func premiumModelRow(_ model: ModelConfig) -> some View {
            let isSelected = selectedPremiumIDs.contains(model.id)
            return SelectableModelRow(
                model: model,
                isSelected: isSelected,
                style: .compact,
                showsDefaultBadge: false,
                showsModelTags: false
            ) {
                togglePremiumModel(model)
            }
        }

        private var premiumModelsLoadingPlaceholder: some View {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.85)
                Text("Loading models…")
                    .font(.system(size: Constants.FontSize.caption, weight: .medium))
                    .foregroundColor(colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Constants.Premium.rowHorizontalPadding)
            .padding(.vertical, Constants.Premium.rowVerticalPadding * 3)
            .background(cardBackground)
        }

        @ViewBuilder
        private func tryPremiumPage(metrics: LayoutMetrics) -> some View {
            VStack(spacing: Constants.Premium.sectionSpacing) {
                tryPremiumHeader
                tryPremiumComposer
                    .frame(maxWidth: metrics.mediaWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, Constants.Layout.successTopPadding)
        }

        @ViewBuilder
        private var tryPremiumHeader: some View {
            VStack(spacing: Constants.Layout.textBlockSpacing) {
                Text("Try a more natural translation")
                    .font(.system(size: Constants.FontSize.pageTitle, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Select this sentence, then tap Translate from the text menu.")
                    .font(.system(size: Constants.FontSize.body))
                    .foregroundColor(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Constants.Layout.bodyLineSpacing)

                Text("Compare a translation that preserves your meaning and sounds natural.")
                    .font(.system(size: Constants.FontSize.body))
                    .foregroundColor(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Constants.Layout.bodyLineSpacing)
            }
        }

        @ViewBuilder
        private var tryPremiumComposer: some View {
            OnboardingTrialTextEditor(
                text: $trialInputText,
                font: .preferredFont(forTextStyle: .body),
                customActionTitle: String(localized: "Translate"),
                onCustomAction: { selectedText in
                    presentTrialSheet(inputText: selectedText)
                },
                onFeedback: {
                    composeFeedbackEmail()
                }
            )
            .frame(minHeight: Constants.Layout.practiceCardMinHeight)
            .padding(Constants.Layout.practiceCardPadding)
            .background(cardBackground)
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

        private var trialOfferPage: some View {
            VStack(spacing: Constants.Layout.successSpacing) {
                Image(systemName: "crown.fill")
                    .font(.system(size: Constants.FontSize.successSeal, weight: .bold))
                    .foregroundStyle(colors.accent)
                    .frame(width: Constants.Layout.successSealSize, height: Constants.Layout.successSealSize)
                    .tlingoGlassCircle(
                        tint: colors.accent.opacity(Constants.Opacity.sealTint),
                        fallbackTint: colors.accent.opacity(Constants.Opacity.sealFallbackTint),
                        fallbackStroke: colors.accent.opacity(Constants.Opacity.sealFallbackStroke)
                    )

                VStack(spacing: Constants.Layout.textBlockSpacing) {
                    Text("Keep using these models after your free trial")
                        .font(.system(size: Constants.FontSize.successTitle, weight: .bold))
                        .foregroundColor(colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(trialSubtitle)
                        .font(.system(size: Constants.FontSize.body))
                        .foregroundColor(colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Constants.Layout.bodyLineSpacing)
                }

                reminderCard
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Constants.Layout.successTopPadding)
        }

        @ViewBuilder
        private var reminderCard: some View {
            let options = reminderOptions
            VStack(alignment: .leading, spacing: Constants.Layout.benefitsSpacing) {
                HStack(alignment: .top, spacing: Constants.Layout.benefitRowSpacing) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: Constants.FontSize.benefitIcon, weight: .semibold))
                        .foregroundColor(colors.accent)
                        .frame(width: Constants.Layout.benefitIconSize, height: Constants.Layout.benefitIconSize)
                    Text("Remind me before the trial ends, so I can cancel in time.")
                        .font(.system(size: Constants.FontSize.caption, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Picker("Trial reminder", selection: $selectedReminderDaysBefore) {
                    ForEach(options, id: \.daysBefore) { option in
                        Text(option.segmentLabel).tag(Optional(option.daysBefore))
                    }
                    Text("Off").tag(Int?.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: selectedReminderDaysBefore) { _, newValue in
                    if newValue != nil { requestNotificationPermission() }
                }

                if let dateText = options.first(where: { $0.daysBefore == selectedReminderDaysBefore })?.dateText {
                    Text("We'll remind you on \(dateText).")
                        .font(.system(size: Constants.FontSize.small, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                }
            }
            .padding(Constants.Layout.cardPadding)
            .background(cardBackground)
        }

        private var trialSubtitle: LocalizedStringKey {
            if let price = storeManager.annualProduct?.displayPrice {
                return "Then \(price) per year. Cancel anytime."
            }
            return "Cancel anytime."
        }

        private var trialPrimaryTitle: LocalizedStringKey {
            if storeManager.isPurchasing { return "Starting…" }
            if let duration = trialDurationText {
                return "Start \(duration) free trial"
            }
            return "Start free trial"
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
            guard let trialProduct,
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
            let dateText: String
        }

        private static let reminderDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMMdj")
            return formatter
        }()

        /// When the free trial would end, relative to now. nil when the
        /// resolved product carries no free-trial introductory offer.
        private var trialEndDate: Date? {
            guard let offer = trialProduct?.subscription?.introductoryOffer,
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
                    segmentLabel: segmentLabel,
                    dateText: Self.reminderDateFormatter.string(from: fireDate)
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
            if selectedPremiumIDs.isEmpty, let first = powerModels.first {
                selectedPremiumIDs = [first.id]
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
            preferences.setEnabledModelIDs(preferences.enabledModelIDs.union(selectedPremiumIDs))
            scheduleSelectedReminders()
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
                    primaryButton("Set up TLingo") {
                        withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                            step = .settings
                        }
                    }
                case .settings:
                    primaryButton("Open Settings") {
                        openDefaultTranslationSettings()
                    }
                    secondaryButton("I've set it up") {
                        withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                            step = .tryIt
                        }
                    }
                case .tryIt:
                    trialStatusIndicator
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

        @ViewBuilder
        private var successFooter: some View {
            switch premiumStage {
            case .none:
                primaryButton("Try a more natural translation", isDisabled: selectedPremiumIDs.isEmpty) {
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
            }
        }

        private func primaryButton(
            _ title: LocalizedStringKey,
            isDisabled: Bool = false,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: Constants.FontSize.primaryButton, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: Constants.Layout.primaryButtonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Constants.Radius.button, style: .continuous)
                            .fill(isDisabled ? colors.textSecondary.opacity(Constants.Opacity.disabledButton) : colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }

        private func secondaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: Constants.FontSize.secondaryButton, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Constants.Layout.secondaryButtonHeight)
            }
            .buttonStyle(.plain)
        }

        private func screenshot(_ name: String, width: CGFloat, height: CGFloat) -> some View {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Constants.Radius.media, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Constants.Radius.media, style: .continuous)
                        .stroke(colors.divider, lineWidth: Constants.Stroke.hairline)
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? Constants.Shadow.darkOpacity : Constants.Shadow.lightOpacity),
                    radius: Constants.Shadow.radius,
                    x: 0,
                    y: Constants.Shadow.yOffset
                )
                .accessibilityHidden(true)
        }

        private func animatedScreenshot(_ name: String, width: CGFloat, height: CGFloat) -> some View {
            AnimatedGIFView(assetName: name)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Constants.Radius.media, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Constants.Radius.media, style: .continuous)
                        .stroke(colors.divider, lineWidth: Constants.Stroke.hairline)
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? Constants.Shadow.darkOpacity : Constants.Shadow.lightOpacity),
                    radius: Constants.Shadow.radius,
                    x: 0,
                    y: Constants.Shadow.yOffset
                )
                .accessibilityHidden(true)
        }

        private func setupStep(number: Int, text: LocalizedStringKey) -> some View {
            HStack(alignment: .top, spacing: Constants.Layout.setupStepSpacing) {
                Text("\(number)")
                    .font(.system(size: Constants.FontSize.small, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: Constants.Layout.stepBadgeSize, height: Constants.Layout.stepBadgeSize)
                    .background(Circle().fill(colors.accent))

                Text(text)
                    .font(.system(size: Constants.FontSize.caption, weight: .medium))
                    .foregroundColor(colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }

        private func benefitRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
            HStack(alignment: .top, spacing: Constants.Layout.benefitRowSpacing) {
                Image(systemName: icon)
                    .font(.system(size: Constants.FontSize.benefitIcon, weight: .semibold))
                    .foregroundColor(colors.accent)
                    .frame(width: Constants.Layout.benefitIconSize, height: Constants.Layout.benefitIconSize)

                VStack(alignment: .leading, spacing: Constants.Layout.benefitTextSpacing) {
                    Text(title)
                        .font(.system(size: Constants.FontSize.caption, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: Constants.FontSize.small))
                        .foregroundColor(colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }

        private var cardBackground: some View {
            RoundedRectangle(cornerRadius: Constants.Radius.card, style: .continuous)
                .fill(colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Constants.Radius.card, style: .continuous)
                        .stroke(colors.divider, lineWidth: Constants.Stroke.hairline)
                )
        }

        private func openDefaultTranslationSettings() {
            let settingsURL: URL?
            if #available(iOS 18.4, *) {
                settingsURL = URL(string: UIApplication.openDefaultApplicationsSettingsURLString)
            } else {
                settingsURL = URL(string: UIApplication.openSettingsURLString)
            }

            guard let settingsURL else { return }
            UIApplication.shared.open(settingsURL)
        }

        private func advanceToSuccessIfNeeded() {
            guard step == .tryIt, preferences.hasCompletedDefaultTranslationTrial else { return }
            guard !trialCompletedAtEntry else { return }
            withAnimation(.easeInOut(duration: Constants.Animation.stepTransition)) {
                step = .success
            }
        }

        private func handleScenePhaseChange(_ phase: ScenePhase) {
            guard phase == .active else { return }
            preferences.refreshFromDefaults()
            advanceToSuccessIfNeeded()
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
                if preferences.hasCompletedDefaultTranslationTrial {
                    advanceToSuccessIfNeeded()
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

    private struct SelectablePracticeTextView: UIViewRepresentable {
        let text: String

        func makeUIView(context _: Context) -> UITextView {
            let textView = UITextView()
            textView.isEditable = false
            textView.isSelectable = true
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textColor = .label
            textView.font = .preferredFont(forTextStyle: .body)
            textView.adjustsFontForContentSizeCategory = true
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            return textView
        }

        func updateUIView(_ textView: UITextView, context _: Context) {
            textView.text = text
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize? {
            let width = proposal.width ?? 0
            guard width > 0 else { return nil }
            let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: size.height)
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
