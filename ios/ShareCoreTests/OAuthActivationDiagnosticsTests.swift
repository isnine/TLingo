//
//  OAuthActivationDiagnosticsTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("OAuthActivationDiagnostics")
struct OAuthActivationDiagnosticsTests {
    @Test func feedbackMailtoIncludesActivationContext() throws {
        let diagnostics = OAuthActivationDiagnostics(
            email: "buyer@example.com",
            userID: "user_123",
            isPremium: false,
            errorCode: "no_active_entitlement",
            errorDescription: "Entitlement is not active",
            activationURL: URL(string: "https://tlingo.zanderwang.com/activate?from=checkout")!,
            callbackURL: URL(string: "tlingo-direct://oauth/callback?code=abc&state=state")!,
            appVersion: "3.3.0",
            buildNumber: "461",
            operatingSystemVersion: "macOS 26.4.1"
        )

        let url = try #require(diagnostics.feedbackMailtoURL)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        let decodedBody = body.removingPercentEncoding ?? body

        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.contains("iamzanderwang@outlook.com"))
        #expect(body.contains("buyer@example.com"))
        #expect(body.contains("user_123"))
        #expect(body.contains("no_active_entitlement"))
        #expect(body.contains("Entitlement is not active"))
        #expect(body.contains("macOS 26.4.1"))
        #expect(body.contains("3.3.0 (461)"))
        // Callback `code` query item is redacted to avoid leaking auth code via email.
        #expect(decodedBody.contains("<redacted>"))
        #expect(!body.contains("code=abc"))
    }

    @Test func withErrorPreservesIdentityFields() throws {
        let base = OAuthActivationDiagnostics(
            email: "x@y.com",
            userID: "u",
            isPremium: true,
            errorCode: nil,
            errorDescription: nil,
            activationURL: nil,
            callbackURL: nil
        )
        let updated = base.withError(code: "token_exchange_failed", description: "boom")
        #expect(updated.email == "x@y.com")
        #expect(updated.userID == "u")
        #expect(updated.isPremium == true)
        #expect(updated.errorCode == "token_exchange_failed")
        #expect(updated.errorDescription == "boom")
    }
}
