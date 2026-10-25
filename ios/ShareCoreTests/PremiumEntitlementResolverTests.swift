//
//  PremiumEntitlementResolverTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("PremiumEntitlementResolver")
struct PremiumEntitlementResolverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var future: Date { now.addingTimeInterval(86400) }
    private var past: Date { now.addingTimeInterval(-86400) }

    private let monthlyID = SubscriptionProduct.monthly.rawValue
    private let annualID = SubscriptionProduct.annual.rawValue
    private let lifetimeID = LifetimeProduct.lifetime.rawValue

    private func candidate(
        _ productID: String,
        jws: String = "jws",
        expires: Date? = nil,
        revoked: Bool = false
    ) -> PremiumEntitlementCandidate {
        PremiumEntitlementCandidate(productID: productID, jws: jws, expirationDate: expires, isRevoked: revoked)
    }

    private func resolve(
        verified: PremiumEntitlementCandidate? = nil,
        current: [PremiumEntitlementCandidate] = [],
        cache: CachedPremiumEntitlement? = nil,
        wasPremium: Bool = false
    ) -> PremiumEntitlementResolution {
        PremiumEntitlementResolver.resolve(
            verified: verified,
            currentEntitlements: current,
            cache: cache,
            wasPremium: wasPremium,
            now: now
        )
    }

    @Test("A verified purchase is active when currentEntitlements is empty")
    func verifiedPurchaseSurvivesEmptyEntitlements() {
        let purchase = candidate(annualID, jws: "purchase-jws", expires: future)
        #expect(resolve(verified: purchase) == .active(purchase))
    }

    @Test("An expired verified transaction does not grant premium")
    func expiredVerifiedTransactionIsIgnored() {
        #expect(resolve(verified: candidate(monthlyID, expires: past)) == .inactive)
    }

    @Test("Entitlements in billing grace period stay active past expiration")
    func currentEntitlementsAreNotExpiryChecked() {
        let grace = candidate(monthlyID, expires: past)
        #expect(resolve(current: [grace]) == .active(grace))
    }

    @Test("The highest tier wins")
    func highestTierWins() {
        let lifetime = candidate(lifetimeID, jws: "lifetime")
        let result = resolve(
            verified: candidate(monthlyID, jws: "monthly", expires: future),
            current: [candidate(annualID, jws: "annual", expires: future), lifetime]
        )
        #expect(result == .active(lifetime))
    }

    @Test("Same tier keeps the just-verified transaction's JWS")
    func sameTierPrefersVerified() {
        let purchase = candidate(annualID, jws: "purchase", expires: future)
        let result = resolve(verified: purchase, current: [candidate(annualID, jws: "older", expires: future)])
        #expect(result == .active(purchase))
    }

    @Test("Non-premium products are ignored")
    func unknownProductsIgnored() {
        #expect(resolve(verified: candidate("com.example.other"), current: [candidate("com.example.other")]) == .inactive)
    }

    @Test("Existing premium is kept from an unexpired cache when StoreKit returns nothing")
    func keepsUnexpiredCache() {
        let cache = CachedPremiumEntitlement(productID: annualID, expirationDate: future)
        #expect(resolve(cache: cache, wasPremium: true) == .cached(productID: annualID))
    }

    @Test("Cached lifetime never expires")
    func keepsLifetimeCache() {
        let cache = CachedPremiumEntitlement(productID: lifetimeID, expirationDate: nil)
        #expect(resolve(cache: cache, wasPremium: true) == .cached(productID: lifetimeID))
    }

    @Test("An expired cache downgrades")
    func expiredCacheDowngrades() {
        let cache = CachedPremiumEntitlement(productID: monthlyID, expirationDate: past)
        #expect(resolve(cache: cache, wasPremium: true) == .inactive)
    }

    @Test("The cache never grants premium to a free user")
    func cacheRequiresExistingPremium() {
        let cache = CachedPremiumEntitlement(productID: lifetimeID, expirationDate: nil)
        #expect(resolve(cache: cache, wasPremium: false) == .inactive)
    }

    @Test("Premium cached by builds without the entitlement cache downgrades")
    func missingCacheDowngrades() {
        #expect(resolve(wasPremium: true) == .inactive)
    }

    @Test("A refund delivered through Transaction.updates overrides the cache")
    func revokedVerifiedOverridesCache() {
        let cache = CachedPremiumEntitlement(productID: lifetimeID, expirationDate: nil)
        let refund = candidate(lifetimeID, revoked: true)
        #expect(resolve(verified: refund, cache: cache, wasPremium: true) == .inactive)
    }

    @Test("A refund of one product keeps another active entitlement")
    func revokedProductKeepsOtherEntitlement() {
        let annual = candidate(annualID, expires: future)
        #expect(resolve(verified: candidate(lifetimeID, revoked: true), current: [annual], wasPremium: true) == .active(annual))
    }
}
