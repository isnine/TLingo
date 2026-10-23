//
//  EntitlementState.swift
//  ShareCore
//

import Foundation

public struct EntitlementState: Equatable {
    public let hasAppStoreEntitlement: Bool
    public let appStoreTierName: String?

    public init(hasAppStoreEntitlement: Bool, appStoreTierName: String?) {
        self.hasAppStoreEntitlement = hasAppStoreEntitlement
        self.appStoreTierName = appStoreTierName
    }

    public var isPro: Bool {
        hasAppStoreEntitlement
    }

    public var settingsSubtitle: String {
        guard isPro else { return String(localized: "Free") }
        if let appStoreTierName, !appStoreTierName.isEmpty {
            return String(localized: "Premium · \(appStoreTierName)")
        }
        return String(localized: "Premium · App Store")
    }
}
