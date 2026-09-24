//
//  EntitlementState.swift
//  ShareCore
//

import Foundation

public struct EntitlementState: Equatable {
    public let hasAppStoreEntitlement: Bool
    public let appStoreTierName: String?
    public let hasWebsiteEntitlement: Bool
    public let websiteTierName: String?
    public let expiresAt: Date?

    public init(
        hasAppStoreEntitlement: Bool,
        appStoreTierName: String?,
        hasWebsiteEntitlement: Bool,
        websiteTierName: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.hasAppStoreEntitlement = hasAppStoreEntitlement
        self.appStoreTierName = appStoreTierName
        self.hasWebsiteEntitlement = hasWebsiteEntitlement
        self.websiteTierName = websiteTierName
        self.expiresAt = expiresAt
    }

    public var isPro: Bool {
        hasAppStoreEntitlement || hasWebsiteEntitlement
    }

    public var sourceDescription: String? {
        switch (hasAppStoreEntitlement, hasWebsiteEntitlement) {
        case (true, true):
            return "App Store + Website"
        case (true, false):
            return "App Store"
        case (false, true):
            return "Website"
        case (false, false):
            return nil
        }
    }

    public var settingsSubtitle: String {
        guard isPro else { return String(localized: "Free") }
        if hasAppStoreEntitlement, hasWebsiteEntitlement {
            return String(localized: "Premium · App Store + Website")
        }
        if hasWebsiteEntitlement {
            if let websiteTierName, !websiteTierName.isEmpty {
                return String(localized: "Premium · \(websiteTierName) · Website")
            }
            return String(localized: "Premium · Website")
        }
        if let appStoreTierName, !appStoreTierName.isEmpty {
            return String(localized: "Premium · \(appStoreTierName)")
        }
        return String(localized: "Premium · App Store")
    }

    /// True when website-restored Pro should suppress the App Store upgrade
    /// list — Apple doesn't allow charging again for an entitlement the user
    /// already paid for on the web.
    public var suppressesAppStoreUpgrades: Bool {
        hasWebsiteEntitlement && !hasAppStoreEntitlement
    }
}
