//
//  FirstRunOnboardingPresentation.swift
//  TLingo
//

#if os(iOS)
    import ShareCore
    import SwiftUI

    extension View {
        /// Presents the default-translation onboarding, then the first-run paywall.
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
        @State private var pendingDefaultTranslationUpgrade = false
        @State private var showFirstRunPaywall = false

        func body(content: Content) -> some View {
            content
                .fullScreenCover(
                    isPresented: $showDefaultTranslationOnboarding,
                    onDismiss: handleDefaultTranslationOnboardingDismiss
                ) {
                    DefaultTranslationOnboardingView { outcome in
                        pendingDefaultTranslationUpgrade = outcome == .upgrade
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
            preferences.setHasSeenDefaultTranslationOnboarding(true)
            preferences.setHasSeenIOSPaywallOnboarding(true)

            guard pendingDefaultTranslationUpgrade else { return }
            pendingDefaultTranslationUpgrade = false
            showDefaultTranslationPaywall = true
        }
    }
#endif
