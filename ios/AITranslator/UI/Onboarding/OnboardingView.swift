//
//  OnboardingView.swift
//  TLingo
//
//  First-launch onboarding wizard (macOS-only).
//

#if os(macOS)
    import Foundation
    import ShareCore
    import StoreKit
    import SwiftUI
    import UserNotifications

    struct OnboardingView: View {
        @Binding var isPresented: Bool
        @Environment(\.colorScheme) private var colorScheme

        #if DIRECT_DISTRIBUTION
            @StateObject private var permissionManager = AccessibilityPermissionManager()
        #endif
        @StateObject private var realtimePermissionManager = RealtimePermissionManager()
        @ObservedObject private var prefs = AppPreferences.shared
        @ObservedObject private var hotKeyManager = HotKeyManager.shared
        @ObservedObject private var storeManager = StoreManager.shared

        @State private var step: Int = OnboardingView.firstStep
        @State private var premiumModels: [ModelConfig] = []
        @State private var selectedModelIDs: Set<String> = []
        @State private var isRecordingHotKey = false
        @State private var hotKeyMonitor: Any?
        @State private var isNavigatingBack = false
        @State private var isTextSelectionTrialCompleted = false
        @State private var isPolishTrialCompleted = false
        @State private var showSubscriptionPaywall = false
        private let hadExistingModelSelection: Bool
        private let isSingleStep: Bool

        #if DIRECT_DISTRIBUTION
            private static let firstStep = 0
        #else
            private static let firstStep = 1
        #endif

        private static let lastStep = 5

        private static let progressHeight: CGFloat = 28
        private static let contentHeight: CGFloat = 384
        private static let footerHeight: CGFloat = 40

        init(isPresented: Binding<Bool>, initialStep: Int? = nil, isSingleStep: Bool = false) {
            let existingModelIDs = AppPreferences.shared.enabledModelIDs
            _isPresented = isPresented
            _step = State(initialValue: initialStep ?? Self.firstStep)
            _selectedModelIDs = State(initialValue: existingModelIDs)
            hadExistingModelSelection = !existingModelIDs.isEmpty
            self.isSingleStep = isSingleStep
        }

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: prefs.accentTheme)
        }

        var body: some View {
            VStack(spacing: 20) {
                ProgressDotsView(
                    current: step - Self.firstStep,
                    total: Self.lastStep - Self.firstStep + 1,
                    colors: colors
                )
                .frame(height: Self.progressHeight, alignment: .bottom)

                ZStack {
                    stepContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                .frame(height: Self.contentHeight)
                .clipped()
                .animation(.easeInOut(duration: 0.25), value: step)

                footer
                    .frame(height: Self.footerHeight)
            }
            .padding(24)
            .frame(width: 520, height: 540)
            .background(colors.background)
            .overlay(alignment: .topTrailing) {
                if isSingleStep {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(colors.textSecondary.opacity(0.6))
                            .frame(width: 32, height: 32)
                            .tlingoGlassCircle(.control, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
                    .padding(16)
                }
            }
            .interactiveDismissDisabled(true)
            .onChange(of: step, initial: true) {
                if isNavigatingBack {
                    isNavigatingBack = false
                } else {
                    advancePastCompletedSetup()
                }
            }
            #if DIRECT_DISTRIBUTION
            .onChange(of: permissionManager.isAccessibilityGranted) {
                advancePastCompletedSetup()
            }
            #endif
            .onChange(of: hotKeyManager.quickTranslateConfiguration) {
                advancePastCompletedSetup()
            }
            .task {
                guard !isSingleStep else { return }
                await loadPremiumModels()
            }
            .task(id: step) {
                guard !isSingleStep, step == Self.lastStep, storeManager.annualProduct == nil else { return }
                await storeManager.loadProducts()
            }
            .sheet(isPresented: $showSubscriptionPaywall, onDismiss: finishAfterSubscriptionPaywallDismiss) {
                PaywallView(context: .standard) {
                    showSubscriptionPaywall = false
                }
            }
        }

        @ViewBuilder
        private var stepContent: some View {
            switch step {
            case 0:
                #if DIRECT_DISTRIBUTION
                    OnboardingStep1TextSelection(
                        permissionManager: permissionManager,
                        colors: colors
                    )
                #else
                    EmptyView()
                #endif
            case 1:
                OnboardingStepTextSelectionTrial(
                    isCompleted: $isTextSelectionTrialCompleted,
                    colors: colors
                )
            case 2:
                if isSingleStep {
                    OnboardingStepRealtimePermissions(
                        permissionManager: realtimePermissionManager,
                        colors: colors
                    )
                } else {
                    OnboardingStep2Hotkey(
                        hotKeyManager: hotKeyManager,
                        isRecording: $isRecordingHotKey,
                        monitor: $hotKeyMonitor,
                        colors: colors
                    )
                }
            case 3:
                OnboardingStep3Models(
                    selectedModelIDs: $selectedModelIDs,
                    models: selectableModels,
                    colors: colors
                )
            case 4:
                OnboardingStepTextSelectionTrial(
                    mode: .polish,
                    isCompleted: $isPolishTrialCompleted,
                    trialModels: selectedAIModels,
                    colors: colors
                )
            case 5:
                OnboardingTrialOfferView(
                    trialDuration: trialDurationText,
                    annualPrice: storeManager.annualProduct?.displayPrice,
                    colors: colors
                )
            default:
                EmptyView()
            }
        }

        private var footer: some View {
            HStack(spacing: 12) {
                if !isSingleStep && step > Self.firstStep {
                    Button {
                        isNavigatingBack = true
                        withAnimation { step -= 1 }
                    } label: {
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 20)
                            .tlingoGlassCapsule(.control, interactive: true)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if showsSkipButton {
                    Button {
                        handleSkip()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 20)
                            .tlingoGlassCapsule(.control, interactive: true)
                    }
                    .buttonStyle(.plain)
                }

                if step == Self.lastStep {
                    Button {
                        showSubscriptionPaywall = true
                    } label: {
                        Text("View all plans")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 20)
                            .tlingoGlassCapsule(.control, interactive: true)
                    }
                    .buttonStyle(.plain)
                }

                if showsPrimaryButton {
                    Button {
                        handlePrimary()
                    } label: {
                        Text(primaryButtonTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(primaryButtonEnabled ? .white : colors.textSecondary)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 28)
                            .tlingoGlassCapsule(primaryButtonEnabled ? .prominent : .control, interactive: primaryButtonEnabled)
                    }
                    .buttonStyle(.plain)
                    .disabled(!primaryButtonEnabled)
                }
            }
        }

        private var primaryButtonTitle: LocalizedStringKey {
            switch step {
            case 0:
                #if DIRECT_DISTRIBUTION
                    return permissionManager.isAccessibilityGranted ? "Try translating selected text" : "Open System Settings"
                #else
                    return "Continue"
                #endif
            case 1:
                return "Continue"
            case 2:
                if isSingleStep {
                    return realtimePermissionManager.allGranted ? "Done" : (
                        realtimePermissionManager.hasRequestedInitialPermissions
                            ? "Open System Settings"
                            : "Grant Permissions"
                    )
                }
                return "Continue"
            case 3:
                return "Polish your writing"
            case 4:
                return "Continue"
            case 5:
                if storeManager.isPurchasing {
                    return "Starting…"
                }
                if let duration = trialDurationText {
                    return "Try for \(duration)"
                }
                return "Try free"
            default:
                return "Start"
            }
        }

        private var showsPrimaryButton: Bool {
            step != 2 || isSingleStep || !hotKeyManager.quickTranslateConfiguration.isEmpty
        }

        private var showsSkipButton: Bool {
            !isSingleStep
                && step < Self.lastStep
                && (step != 1 || !isTextSelectionTrialCompleted)
                && (step != 2 || hotKeyManager.quickTranslateConfiguration.isEmpty)
                && step != 3
        }

        private var primaryButtonEnabled: Bool {
            switch step {
            case 0:
                return true
            case 1:
                return isTextSelectionTrialCompleted
            case 2:
                return true
            case 3:
                return !selectedAIModels.isEmpty
            case 4:
                return isPolishTrialCompleted
            case 5:
                return storeManager.annualProduct != nil && !storeManager.isPurchasing
            default:
                return true
            }
        }

        private func handlePrimary() {
            switch step {
            case 0:
                #if DIRECT_DISTRIBUTION
                    if permissionManager.isAccessibilityGranted {
                        prefs.setTextSelectionTranslationEnabled(true)
                        withAnimation { step = 1 }
                    } else {
                        permissionManager.openAccessibilitySettings()
                    }
                #endif
            case 1:
                withAnimation { step = 2 }
            case 2:
                if isSingleStep, realtimePermissionManager.allGranted {
                    isPresented = false
                } else if isSingleStep {
                    Task { await realtimePermissionManager.requestInitialPermissionsIfNeeded() }
                } else {
                    withAnimation { step = 3 }
                }
            case 3:
                withAnimation { step = 4 }
            case 4:
                withAnimation { step = 5 }
            case 5:
                Task { await startFreeTrial() }
            default:
                break
            }
        }

        private func handleSkip() {
            switch step {
            case 0, 1:
                withAnimation { step = 2 }
            case 2:
                if !isSingleStep {
                    withAnimation { step = 3 }
                }
            case 4:
                showSubscriptionPaywall = true
            default:
                break
            }
        }

        private func advancePastCompletedSetup() {
            guard !isSingleStep else { return }

            let nextStep: Int
            switch step {
            #if DIRECT_DISTRIBUTION
                case 0 where permissionManager.isAccessibilityGranted:
                    nextStep = 1
            #endif
            case 2 where !hotKeyManager.quickTranslateConfiguration.isEmpty:
                nextStep = 3
            case 3 where hadExistingModelSelection:
                nextStep = 4
            default:
                return
            }

            withAnimation { step = nextStep }
        }

        private func finish() {
            var enabledModelIDs = selectedModelIDs
            if !(Entitlement.shared.isPro || storeManager.isPremium) {
                enabledModelIDs.subtract(Set(premiumModels.map(\.id)))
            }
            if enabledModelIDs.isEmpty {
                enabledModelIDs.insert(ModelConfig.microsoftTranslateID)
            }
            prefs.setEnabledModelIDs(enabledModelIDs)
            prefs.setHasCompletedOnboarding(true)
            prefs.setLastCompletedOnboardingVersion(AITranslatorApp.currentAppVersion)
            isPresented = false
        }

        private func finishAfterSubscriptionPaywallDismiss() {
            finish()
        }

        private func startFreeTrial() async {
            guard let product = storeManager.annualProduct else { return }
            guard await storeManager.purchase(product) else { return }
            await Entitlement.shared.refresh()
            if Entitlement.shared.isPro || storeManager.isPremium {
                await scheduleTrialReminder(for: product)
                finish()
            }
        }

        private func loadPremiumModels() async {
            let cached = (ModelsService.shared.getCachedModels() ?? []).filter {
                $0.isPremium && (!$0.hidden || selectedModelIDs.contains($0.id))
            }
            if !cached.isEmpty {
                applyPremiumModels(cached)
                return
            }

            let fetched = (try? await ModelsService.shared.fetchModels(forceRefresh: false)) ?? []
            applyPremiumModels(fetched.filter {
                $0.isPremium && (!$0.hidden || selectedModelIDs.contains($0.id))
            })
        }

        private func applyPremiumModels(_ models: [ModelConfig]) {
            premiumModels = models
            if !hadExistingModelSelection, selectedModelIDs.isEmpty {
                selectedModelIDs = [ModelConfig.nanoModelID, ModelConfig.microsoftTranslateID]
            }
        }

        private var selectableModels: [ModelConfig] {
            var seen = Set<String>()
            return ([ModelConfig.microsoftTranslate, ModelConfig.appleTranslate, ModelConfig.nanoModel]
                + ModelConfig.appleIntelligenceModels + premiumModels)
                .filter { seen.insert($0.id).inserted }
                .filter { model in
                    if model.id == ModelConfig.appleTranslateID {
                        return AppleTranslationService.shared.isAvailable
                    }
                    if model.isFoundationModel {
                        return FoundationModelService.availability(for: model).isAvailable
                    }
                    return true
                }
        }

        private var selectedAIModels: [ModelConfig] {
            selectableModels.filter {
                selectedModelIDs.contains($0.id) && ($0.isPremium || $0.id == ModelConfig.nanoModelID)
            }
        }

        private func scheduleTrialReminder(for product: Product) async {
            guard let trialEndDate = trialEndDate(for: product),
                  let reminderDay = Calendar.current.date(byAdding: .day, value: -1, to: trialEndDate),
                  let reminderDate = Calendar.current.date(
                      bySettingHour: 9,
                      minute: 0,
                      second: 0,
                      of: reminderDay
                  ),
                  reminderDate > Date()
            else { return }

            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Your TLingo trial is ending")
            content.body = String(localized: "Your free trial ends tomorrow. Open TLingo to manage your subscription.")
            content.sound = .default

            let triggerComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminderDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
            let request = UNNotificationRequest(
                identifier: TrialReminderNotification.identifier,
                content: content,
                trigger: trigger
            )
            center.removePendingNotificationRequests(withIdentifiers: [TrialReminderNotification.identifier])
            try? await center.add(request)
        }

        private func trialEndDate(for product: Product) -> Date? {
            guard let offer = product.subscription?.introductoryOffer,
                  offer.paymentMode == .freeTrial,
                  let components = trialPeriodComponents(offer.period)
            else { return nil }
            return Calendar.current.date(byAdding: components, to: Date())
        }

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
            guard let offer = storeManager.annualProduct?.subscription?.introductoryOffer,
                  offer.paymentMode == .freeTrial,
                  let components = trialPeriodComponents(offer.period)
            else { return nil }

            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.day, .weekOfMonth, .month, .year]
            formatter.maximumUnitCount = 1
            return formatter.string(from: components)
        }
    }

    struct OnboardingTrialOfferView: View {
        let trialDuration: String?
        let annualPrice: String?
        let colors: AppColorPalette

        var body: some View {
            VStack(spacing: 18) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(colors.accent)
                    .frame(width: 88, height: 88)
                    .tlingoGlassCircle(
                        tint: colors.accent.opacity(0.14),
                        fallbackTint: colors.accent.opacity(0.10),
                        fallbackStroke: colors.accent.opacity(0.24)
                    )

                VStack(spacing: 8) {
                    Text("Keep using these models after your free trial")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("We'll remind you before your trial ends, so you can cancel in time.")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textSecondary)
                        .multilineTextAlignment(.center)

                    if let annualPrice {
                        Text("Then \(annualPrice) per year. Cancel anytime.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    if let trialDuration {
                        Text("Your free trial: \(trialDuration)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(colors.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
        }
    }

    struct OnboardingStepHeader: View {
        let systemImage: String?
        let iconColor: Color
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey?
        let colors: AppColorPalette

        var body: some View {
            VStack(spacing: 18) {
                Group {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 48))
                            .foregroundStyle(iconColor)
                    }
                }
                .frame(height: 48)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(colors.textPrimary)

                    Group {
                        if let subtitle {
                            Text(subtitle)
                        } else {
                            Text(" ")
                                .hidden()
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                }
            }
            .frame(height: 115, alignment: .top)
        }
    }

    private struct ProgressDotsView: View {
        let current: Int
        let total: Int
        let colors: AppColorPalette

        var body: some View {
            HStack(spacing: 10) {
                ForEach(0 ..< total, id: \.self) { index in
                    Circle()
                        .fill(index <= current ? colors.accent : colors.textSecondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: current)
                }
            }
        }
    }
#endif
