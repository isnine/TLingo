//
//  OAuthErrorTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("OAuthError")
struct OAuthErrorTests {
    @Test func invalidGrantInvalidatesStoredWebsiteEntitlement() {
        #expect(OAuthError.server(code: "invalid_grant", message: "Refresh token expired").invalidatesStoredWebsiteEntitlement)
        #expect(OAuthError.server(code: "invalid_grant", message: "Client mismatch").invalidatesStoredWebsiteEntitlement)
        #expect(
            OAuthError.server(code: "invalid_grant", message: "Refresh token not recognized")
                .invalidatesStoredWebsiteEntitlement
        )
    }

    @Test func transientServerErrorsDoNotInvalidateStoredWebsiteEntitlement() {
        #expect(!OAuthError.invalidResponse.invalidatesStoredWebsiteEntitlement)
        #expect(!OAuthError.server(code: "server_error", message: "Internal error").invalidatesStoredWebsiteEntitlement)
        #expect(!OAuthError.server(code: nil, message: "HTTP 502").invalidatesStoredWebsiteEntitlement)
    }

    @Test func terminalRefreshFailureDoesNotClearNewerStoredToken() {
        #expect(OAuthRefreshFailurePolicy.shouldClearStoredWebsiteEntitlement(
            failedRefreshToken: "old",
            inMemoryRefreshToken: "old",
            storedRefreshToken: "old"
        ))
        #expect(!OAuthRefreshFailurePolicy.shouldClearStoredWebsiteEntitlement(
            failedRefreshToken: "old",
            inMemoryRefreshToken: "new",
            storedRefreshToken: "new"
        ))
        #expect(!OAuthRefreshFailurePolicy.shouldClearStoredWebsiteEntitlement(
            failedRefreshToken: "old",
            inMemoryRefreshToken: "old",
            storedRefreshToken: "new"
        ))
        #expect(OAuthRefreshFailurePolicy.shouldClearStoredWebsiteEntitlement(
            failedRefreshToken: "old",
            inMemoryRefreshToken: "old",
            storedRefreshToken: nil
        ))
    }
}
