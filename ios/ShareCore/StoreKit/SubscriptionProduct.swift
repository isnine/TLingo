//
//  SubscriptionProduct.swift
//  ShareCore
//
//  Created by Codex on 2025/02/07.
//

import Foundation

/// Product identifiers for premium subscriptions.
public enum SubscriptionProduct: String, CaseIterable, Sendable {
    case monthly = "com.zanderwang.AITranslator.premium.monthly"
    case annual = "com.zanderwang.AITranslator.premium.annual"

    /// All product identifiers as a set for StoreKit queries.
    public static let allIdentifiers: Set<String> =
        Set(allCases.map(\.rawValue))
}

/// Product identifiers for one-time purchases.
public enum LifetimeProduct: String, Sendable {
    case lifetime = "com.zanderwang.AITranslator.lifetime"
}

/// All premium product identifiers (subscriptions + lifetime).
public enum PremiumProduct {
    public static let allIdentifiers: Set<String> =
        SubscriptionProduct.allIdentifiers.union([LifetimeProduct.lifetime.rawValue])

    public static func tierDisplayName(for productID: String) -> String? {
        switch productID {
        case SubscriptionProduct.monthly.rawValue: return String(localized: "Monthly")
        case SubscriptionProduct.annual.rawValue: return String(localized: "Annual")
        case LifetimeProduct.lifetime.rawValue: return String(localized: "Lifetime")
        default: return nil
        }
    }

    public static func tierPriority(for productID: String) -> Int {
        switch productID {
        case SubscriptionProduct.monthly.rawValue: return 0
        case SubscriptionProduct.annual.rawValue: return 1
        case LifetimeProduct.lifetime.rawValue: return 2
        default: return -1
        }
    }
}
