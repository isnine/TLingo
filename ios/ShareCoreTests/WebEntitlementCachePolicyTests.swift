//
//  WebEntitlementCachePolicyTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("WebEntitlementCachePolicy")
struct WebEntitlementCachePolicyTests {
    @Test func mainAppRejectsCachedPremiumWithoutOAuthTokens() {
        let now = Date()

        #expect(!WebEntitlementCachePolicy.canHydrateCachedPremium(
            cachedAt: now,
            now: now,
            hasOAuthTokens: false,
            isAppExtension: false,
            offlineGrace: 60
        ))
    }

    @Test func appExtensionCanUseFreshSharedPremiumCacheWithoutOAuthTokens() {
        let now = Date()

        #expect(WebEntitlementCachePolicy.canHydrateCachedPremium(
            cachedAt: now.addingTimeInterval(-30),
            now: now,
            hasOAuthTokens: false,
            isAppExtension: true,
            offlineGrace: 60
        ))
    }

    @Test func appExtensionRejectsStaleSharedPremiumCache() {
        let now = Date()

        #expect(!WebEntitlementCachePolicy.canHydrateCachedPremium(
            cachedAt: now.addingTimeInterval(-61),
            now: now,
            hasOAuthTokens: false,
            isAppExtension: true,
            offlineGrace: 60
        ))
    }
}
