//
//  WhatsNewPresentation.swift
//  TLingo
//

import ShareCore
import SwiftUI

extension View {
    /// Presents release notes once after an update.
    /// `isBlocked` is re-read after the launch delay so containers can defer while another sheet is up.
    func whatsNewPresentation(isBlocked: @escaping @MainActor () -> Bool) -> some View {
        modifier(WhatsNewPresentation(isBlocked: isBlocked))
    }
}

private struct WhatsNewPresentation: ViewModifier {
    /// macOS can restore several main windows, each with its own modifier instance.
    @MainActor private static var isPresenting = false

    let isBlocked: @MainActor () -> Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summary: WhatsNewSummary?
    @State private var presentedVersion: String?
    @State private var showsConfetti = false

    func body(content: Content) -> some View {
        content
            .sheet(
                item: $summary,
                onDismiss: {
                    if let presentedVersion {
                        WhatsNew.markSeen(presentedVersion)
                        Self.isPresenting = false
                    }
                    showsConfetti = false
                },
                content: { summary in
                    WhatsNewView(
                        summary: summary,
                        onDone: { self.summary = nil },
                        onWish: {
                            self.summary = nil
                            openURL(SettingsView.writeReviewURL)
                        }
                    )
                    .overlay {
                        if showsConfetti {
                            ConfettiBurst()
                        }
                    }
                    .task {
                        // Start once the sheet has settled; otherwise the burst plays during the slide-up.
                        try? await Task.sleep(for: .milliseconds(450))
                        showsConfetti = !reduceMotion
                    }
                    #if os(iOS)
                        .presentationDetents([.fraction(0.7), .large])
                        .presentationDragIndicator(.visible)
                    #endif
                }
            )
            .task {
                await presentIfNeeded()
            }
    }

    @MainActor
    private func presentIfNeeded() async {
        guard !HomeViewModel.isSnapshotMode, !RootTabView.forceOnboarding else { return }
        let preferences = AppPreferences.shared
        // Upgraders from builds without What's New have no stored version; onboarding (iOS, non-Pro)
        // or saved history marks them as existing users on either platform.
        let isExistingUser = preferences.hasSeenDefaultTranslationOnboarding
            || !TranslationHistoryService.shared.fetchTextRecords(offset: 0, limit: 1).isEmpty
        guard let pending = WhatsNew.pendingSummary(isExistingUser: isExistingUser) else { return }
        #if os(iOS)
            // First-run onboarding and its paywall own this launch; the notes wait for the next one.
            guard Entitlement.shared.isPro
                || (preferences.hasSeenDefaultTranslationOnboarding && preferences.hasSeenIOSPaywallOnboarding)
            else { return }
        #endif

        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, !isBlocked(), !Self.isPresenting else { return }

        Self.isPresenting = true
        presentedVersion = pending.version
        summary = pending
    }
}
