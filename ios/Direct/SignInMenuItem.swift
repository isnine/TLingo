//
//  SignInMenuItem.swift
//  TLingo-Direct
//
//  Menu commands for the Direct macOS build. All paths route through
//  OAuthCoordinator (see ShareCore/OAuth/).
//

#if DIRECT_DISTRIBUTION

import AppKit
import ShareCore
import SwiftUI

@MainActor
struct SignInMenuItem: View {
    @ObservedObject private var oauth = OAuthCoordinator.shared

    var body: some View {
        if let tokens = oauth.tokens {
            Menu(displayName(for: tokens)) {
                if tokens.isPremium {
                    Text("Plan: \(planLabel(tokens.plan))")
                } else {
                    Text("Plan: Free")
                    Button("Subscribe on Web…") {
                        oauth.startActivation(target: .pricing(email: nil))
                    }
                }
                Button("Refresh entitlement") {
                    Task { await oauth.refreshIfNeeded() }
                }
                Divider()
                Button("Sign Out") { oauth.signOut() }
            }
        } else {
            Menu("Account") {
                Button("Subscribe on Web…") {
                    oauth.startActivation(target: .pricing(email: nil))
                }
                Button("Restore Purchase…") {
                    oauth.startActivation(target: .activate)
                }
            }
        }
    }

    private func displayName(for tokens: OAuthTokens) -> String {
        tokens.email.isEmpty ? String(localized: "Account") : tokens.email
    }

    private func planLabel(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "yearly": return String(localized: "Pro (Yearly)")
        case "monthly": return String(localized: "Pro (Monthly)")
        case "lifetime": return String(localized: "Pro (Lifetime)")
        default: return String(localized: "Pro")
        }
    }
}

#endif
