//
//  PaywallDirectContent.swift
//  TLingo
//
//  Direct (non-MAS) target paywall body. The user buys via the marketing
//  site (`Subscribe on Web`) and the Mac app is activated via the OAuth
//  PKCE flow that bounces back through `tlingo-direct://oauth/callback`.
//
//  Three states:
//    1. No tokens                → Subscribe on Web + Restore Purchase
//    2. Tokens, isPro=true       → Manage Subscription + Refresh + Sign Out
//    3. Tokens, isPro=false      → Subscribe on Web + Refresh + Sign Out
//
//  StoreKit is intentionally never invoked here — `StoreManager.isPremium`
//  on Direct is bridged from `WebEntitlementProvider.isPro` (see
//  ShareCore/Entitlement/WebEntitlementProvider.swift).
//
//  Inert in App Store builds — `PaywallView` only instantiates this when
//  `BuildEnvironment.isDirectDistribution == true`.
//

import ShareCore
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

struct PaywallDirectContent: View {
    let colors: AppColorPalette

    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var oauthCoordinator = OAuthCoordinator.shared

    @State private var showSignOutConfirm = false
    @State private var isRefreshing = false
    @State private var refreshAlert: RefreshAlert?

    private struct RefreshAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 16) {
            let tokens = oauthCoordinator.tokens
            let isPro = storeManager.isPremium

            Text(directStatusText(activated: tokens != nil, isPro: isPro))
                .font(.system(size: 15))
                .foregroundColor(colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if let activationError = oauthCoordinator.lastError, tokens == nil {
                activationErrorBanner(message: activationError)
            }

            if tokens == nil {
                signedOutActions
            } else {
                signedInActions(isPro: isPro)
            }
        }
        .alert(item: $refreshAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: activationIssueBinding) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                primaryButton: .default(Text("Contact Support")) {
                    openSupportEmail(issue.diagnostics)
                    OAuthCoordinator.shared.clearActivationIssue()
                },
                secondaryButton: .default(Text("Try Again")) {
                    OAuthCoordinator.shared.clearActivationIssue()
                    OAuthCoordinator.shared.retryActivation()
                }
            )
        }
    }

    // MARK: - Signed-out (no OAuth tokens yet)

    private var signedOutActions: some View {
        VStack(spacing: 16) {
            Button {
                OAuthCoordinator.shared.startActivation(target: .pricing(email: nil))
            } label: {
                HStack(spacing: 8) {
                    Text("Subscribe on Web")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .tlingoGlassSurface(
                        cornerRadius: 15,
                        tint: colors.accent.opacity(0.76),
                        interactive: true,
                        fallbackTint: colors.accent,
                        fallbackStroke: colors.accent.opacity(0.25)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .shadow(color: colors.accent.opacity(0.20), radius: 14, x: 0, y: 6)

            HStack(spacing: 8) {
                Text("Already purchased?")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                Button {
                    OAuthCoordinator.shared.startActivation(target: .activate)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Restore")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colors.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .tlingoGlassCapsule(
                        tint: colors.cardBackground.opacity(0.12),
                        interactive: true,
                        fallbackTint: colors.chipSecondaryBackground.opacity(0.45),
                        fallbackStroke: colors.divider
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Signed-in (have tokens; isPro routes the primary CTA)

    private func signedInActions(isPro: Bool) -> some View {
        VStack(spacing: 16) {
            Button {
                if isPro {
                    OAuthCoordinator.shared.startActivation(
                        target: .manage(email: oauthCoordinator.tokens?.email)
                    )
                } else {
                    // Pass the signed-in email so the web page can pre-fill
                    // Stripe Checkout, skipping the email-entry step.
                    OAuthCoordinator.shared.startActivation(
                        target: .pricing(email: oauthCoordinator.tokens?.email)
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    Text(isPro ? String(localized: "Manage Subscription") : String(localized: "Subscribe on Web"))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .tlingoGlassSurface(
                        cornerRadius: 15,
                        tint: colors.accent.opacity(0.76),
                        interactive: true,
                        fallbackTint: colors.accent,
                        fallbackStroke: colors.accent.opacity(0.25)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .shadow(color: colors.accent.opacity(0.20), radius: 14, x: 0, y: 6)

            Button {
                Task { await runForceRefresh() }
            } label: {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Refresh subscription status")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isRefreshing ? colors.textSecondary : colors.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .tlingoGlassCapsule(
                    tint: colors.cardBackground.opacity(0.12),
                    interactive: !isRefreshing,
                    fallbackTint: colors.chipSecondaryBackground.opacity(0.45),
                    fallbackStroke: colors.divider
                )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            // Signed in but Stripe says no entitlement → offer a direct path
            // to support so the user doesn't dead-end on "Refresh / Sign out".
            if !isPro {
                Button {
                    openSupportEmail(currentSupportDiagnostics)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "envelope")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Contact support")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colors.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .tlingoGlassCapsule(
                        tint: colors.cardBackground.opacity(0.12),
                        interactive: true,
                        fallbackTint: colors.chipSecondaryBackground.opacity(0.45),
                        fallbackStroke: colors.divider
                    )
                }
                .buttonStyle(.plain)
            }

            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Text("Sign out of this Mac")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .tlingoGlassCapsule(
                        tint: Color.red.opacity(0.10),
                        interactive: true,
                        fallbackTint: Color.red.opacity(0.08),
                        fallbackStroke: Color.red.opacity(0.18)
                    )
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Sign out of TLingo on this Mac?",
                isPresented: $showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    OAuthCoordinator.shared.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pro features will be locked until you activate again. Your subscription on the web is unaffected.")
            }
        }
    }

    // MARK: - Helpers

    private func runForceRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let ok = await OAuthCoordinator.shared.refreshIfNeeded(force: true)
        if !ok {
            refreshAlert = RefreshAlert(
                title: String(localized: "Couldn't refresh"),
                message: OAuthCoordinator.shared.lastError
                    ?? String(localized: "Network error. Please try again.")
            )
            return
        }

        let plan = OAuthCoordinator.shared.tokens?.plan ?? String(localized: "Free")
        let email = OAuthCoordinator.shared.tokens?.email ?? ""
        let emailSuffix = email.isEmpty ? "" : "\n\n\(String(localized: "Signed in as")): \(email)"
        let message: String
        if storeManager.isPremium {
            message = String(format: String(localized: "You're activated as Pro (plan: %@)."), plan) + emailSuffix
        } else {
            // Be explicit about *which* account was checked — most "Restore
            // doesn't work" reports turn out to be the user signed in with a
            // different email than the one that paid.
            message = String(localized: "This account has no active subscription on Stripe.") + emailSuffix
        }
        refreshAlert = RefreshAlert(
            title: String(localized: "Subscription status updated"),
            message: message
        )
    }

    private func activationErrorBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    OAuthCoordinator.shared.retryActivation()
                } label: {
                    Text("Try Again")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
        )
        .padding(.horizontal, 20)
    }

    private var activationIssueBinding: Binding<OAuthActivationIssue?> {
        Binding(
            get: { oauthCoordinator.activationIssue },
            set: { issue in
                if issue == nil {
                    OAuthCoordinator.shared.clearActivationIssue()
                }
            }
        )
    }

    private func openSupportEmail(_ diagnostics: OAuthActivationDiagnostics) {
        guard let url = diagnostics.feedbackMailtoURL else { return }
        #if canImport(AppKit)
            NSWorkspace.shared.open(url)
        #endif
    }

    /// Diagnostics for the "signed in, no Pro" support flow. We don't have
    /// an OAuth activation error to report here — the failure is on the
    /// billing side — so we synthesize a minimal struct from the current
    /// tokens so support gets the right email + user ID to look up.
    private var currentSupportDiagnostics: OAuthActivationDiagnostics {
        let tokens = oauthCoordinator.tokens
        return OAuthActivationDiagnostics(
            email: tokens?.email ?? "",
            userID: tokens?.userID ?? "",
            isPremium: storeManager.isPremium,
            errorCode: "no_entitlement",
            errorDescription: "Signed in but Stripe has no active subscription for this email.",
            activationURL: nil,
            callbackURL: nil
        )
    }

    private func directStatusText(activated: Bool, isPro: Bool) -> String {
        if !activated {
            return String(localized: "Subscribe on the web to unlock Pro on this Mac.")
        }
        let email = oauthCoordinator.tokens?.email ?? ""
        let signedInLine = email.isEmpty
            ? ""
            : "\n\n" + String(format: String(localized: "Signed in as %@"), email)
        if isPro {
            return String(localized: "You're activated as Pro.") + signedInLine
        }
        // Signed in, but no entitlement on Stripe. Tell the user the three
        // things they can try before opening a support ticket.
        return String(
            localized: """
            This account has no active subscription on Stripe. Possible reasons:

            • You haven't subscribed yet — tap “Subscribe on Web”.
            • You subscribed with a different email — sign out and try the other one.
            • You just paid and the state hasn't synced yet — tap “Refresh subscription status”.

            Still stuck? Tap “Contact support” below.
            """
        ) + signedInLine
    }
}
