//
//  FirstRunOnboardingPresentation.swift
//  TLingo
//

#if os(iOS)
    import ShareCore
    import SwiftUI

    extension View {
        /// Presents the first-run onboarding (scenario picker, Realtime setup, default translation),
        /// then the first-run paywall.
        /// `isBlocked` is re-read after the launch delay so containers can defer while another sheet is up.
        func firstRunOnboardingPresentation(isBlocked: @escaping @MainActor () -> Bool) -> some View {
            modifier(FirstRunOnboardingPresentation(isBlocked: isBlocked))
        }
    }

    private struct FirstRunOnboardingPresentation: ViewModifier {
        let isBlocked: @MainActor () -> Bool

        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var entitlement = Entitlement.shared
        @State private var showDefaultTranslationOnboarding = false
        @State private var showDefaultTranslationPaywall = false
        @State private var pendingResult: OnboardingFlowResult = .dismissed
        @State private var showFirstRunPaywall = false

        func body(content: Content) -> some View {
            content
                .fullScreenCover(
                    isPresented: $showDefaultTranslationOnboarding,
                    onDismiss: handleDefaultTranslationOnboardingDismiss
                ) {
                    OnboardingFlowContainer { result in
                        pendingResult = result
                        showDefaultTranslationOnboarding = false
                    }
                }
                .sheet(isPresented: $showDefaultTranslationPaywall) {
                    PaywallView(context: .standard)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
                .sheet(
                    isPresented: $showFirstRunPaywall,
                    onDismiss: {
                        preferences.setHasSeenIOSPaywallOnboarding(true)
                    },
                    content: {
                        PaywallView(context: .firstRunOnboarding) {
                            preferences.setHasSeenIOSPaywallOnboarding(true)
                        }
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                    }
                )
                .task {
                    await presentInitialOnboardingIfNeeded()
                }
        }

        @MainActor
        private func presentInitialOnboardingIfNeeded() async {
            if await presentDefaultTranslationOnboardingIfNeeded() {
                return
            }

            await presentFirstRunPaywallIfNeeded()
        }

        @MainActor
        private func presentDefaultTranslationOnboardingIfNeeded() async -> Bool {
            let forceOnboarding = RootTabView.forceOnboarding
            guard !HomeViewModel.isSnapshotMode else { return false }
            guard forceOnboarding || !entitlement.isPro else { return false }
            guard forceOnboarding || !preferences.hasSeenDefaultTranslationOnboarding else { return false }

            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return false }
            guard forceOnboarding || !preferences.hasSeenDefaultTranslationOnboarding else { return false }
            guard !isBlocked() else { return false }

            showDefaultTranslationOnboarding = true
            return true
        }

        @MainActor
        private func presentFirstRunPaywallIfNeeded() async {
            guard !HomeViewModel.isSnapshotMode else { return }
            guard !entitlement.isPro else { return }
            guard preferences.hasSeenDefaultTranslationOnboarding else { return }
            guard !preferences.hasSeenIOSPaywallOnboarding else { return }

            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            guard !entitlement.isPro,
                  preferences.hasSeenDefaultTranslationOnboarding,
                  !preferences.hasSeenIOSPaywallOnboarding
            else { return }
            guard !isBlocked() else { return }

            showFirstRunPaywall = true
        }

        @MainActor
        private func handleDefaultTranslationOnboardingDismiss() {
            let result = pendingResult
            pendingResult = .dismissed
            preferences.setHasSeenDefaultTranslationOnboarding(true)

            switch result {
            case .dismissed:
                preferences.setHasSeenIOSPaywallOnboarding(true)
            case .upgrade:
                preferences.setHasSeenIOSPaywallOnboarding(true)
                showDefaultTranslationPaywall = true
            case .firstRunPaywall:
                // Realtime-only users never saw the words flow's premium offer, so show the first-run paywall.
                guard !entitlement.isPro, !preferences.hasSeenIOSPaywallOnboarding else { return }
                showFirstRunPaywall = true
            }
        }
    }

    /// How the onboarding cover ended.
    enum OnboardingFlowResult {
        case dismissed
        case upgrade
        case firstRunPaywall
    }

    /// Runs the scenario picker, then the Realtime and words flows the picked scenarios need.
    struct OnboardingFlowContainer: View {
        private enum Stage: Equatable {
            case picker
            case realtime
            case words
        }

        let onFinished: (OnboardingFlowResult) -> Void

        @State private var stage: Stage = .picker
        @State private var route = OnboardingRoute(scenarios: [])
        @State private var selection: Set<OnboardingScenario> = []

        var body: some View {
            ZStack {
                switch stage {
                case .picker:
                    OnboardingScenarioPickerView(
                        initialSelection: selection,
                        onContinue: { scenarios in
                            selection = scenarios
                            start(OnboardingRoute(scenarios: scenarios))
                        },
                        onSkip: {
                            selection = []
                            start(OnboardingRoute(scenarios: []))
                        }
                    )
                    .transition(.opacity)
                case .realtime:
                    RealtimeOnboardingView(
                        inputs: route.realtimeInputs,
                        onBack: { move(to: .picker) },
                        onFinished: { advance(after: .realtime) }
                    )
                    .transition(.opacity)
                case .words:
                    DefaultTranslationOnboardingView { outcome in
                        onFinished(outcome == .upgrade ? .upgrade : .dismissed)
                    }
                    .transition(.opacity)
                }
            }
        }

        private func start(_ route: OnboardingRoute) {
            self.route = route
            guard let first = route.phases.first else {
                onFinished(.dismissed)
                return
            }
            move(to: stage(for: first))
        }

        private func advance(after phase: OnboardingRoute.Phase) {
            guard let index = route.phases.firstIndex(of: phase),
                  route.phases.indices.contains(index + 1)
            else {
                onFinished(route.endsWithFirstRunPaywall ? .firstRunPaywall : .dismissed)
                return
            }
            move(to: stage(for: route.phases[index + 1]))
        }

        private func stage(for phase: OnboardingRoute.Phase) -> Stage {
            switch phase {
            case .realtime: .realtime
            case .words: .words
            }
        }

        private func move(to newStage: Stage) {
            withAnimation(.easeInOut(duration: OnboardingMetrics.stepTransition)) {
                stage = newStage
            }
        }
    }
#endif
