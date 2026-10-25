//
//  PremiumEntitlementResolver.swift
//  ShareCore
//
//  Pure premium decision used by `StoreManager`, kept free of StoreKit types so it can be tested.
//

import Foundation

struct PremiumEntitlementCandidate: Equatable {
    let productID: String
    let jws: String
    let expirationDate: Date?
    let isRevoked: Bool
}

/// Last verified premium entitlement persisted in the App Group.
struct CachedPremiumEntitlement: Equatable {
    let productID: String
    /// `nil` for lifetime.
    let expirationDate: Date?
}

enum PremiumEntitlementResolution: Equatable {
    case active(PremiumEntitlementCandidate)
    /// StoreKit returned nothing but the cached entitlement hasn't expired or been revoked.
    case cached(productID: String)
    case inactive
}

enum PremiumEntitlementResolver {
    /// - Parameters:
    ///   - verified: A transaction just delivered by `Product.purchase` or `Transaction.updates`.
    ///     `currentEntitlements` can omit it (storekitd `noAccount` in TestFlight), so it counts on its own
    ///     unless revoked or expired.
    ///   - currentEntitlements: Verified `Transaction.currentEntitlements`. Not expiry-checked because
    ///     StoreKit includes subscriptions in their billing grace period.
    ///   - wasPremium: Only an existing premium state is kept from `cache`.
    static func resolve(
        verified: PremiumEntitlementCandidate?,
        currentEntitlements: [PremiumEntitlementCandidate],
        cache: CachedPremiumEntitlement?,
        wasPremium: Bool,
        now: Date
    ) -> PremiumEntitlementResolution {
        var sawRevoked = false
        var best: PremiumEntitlementCandidate?

        func consider(_ candidate: PremiumEntitlementCandidate) {
            let priority = PremiumProduct.tierPriority(for: candidate.productID)
            if best.map({ priority > PremiumProduct.tierPriority(for: $0.productID) }) ?? true {
                best = candidate
            }
        }

        if let verified, PremiumProduct.allIdentifiers.contains(verified.productID) {
            if verified.isRevoked {
                sawRevoked = true
            } else if verified.expirationDate.map({ $0 > now }) ?? true {
                consider(verified)
            }
        }

        for candidate in currentEntitlements where PremiumProduct.allIdentifiers.contains(candidate.productID) {
            if candidate.isRevoked {
                sawRevoked = true
            } else {
                consider(candidate)
            }
        }

        if let best { return .active(best) }

        if wasPremium, !sawRevoked, let cache,
           PremiumProduct.allIdentifiers.contains(cache.productID),
           cache.expirationDate.map({ $0 > now }) ?? true
        {
            return .cached(productID: cache.productID)
        }
        return .inactive
    }
}
