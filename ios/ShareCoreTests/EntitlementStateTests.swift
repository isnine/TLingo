//
//  EntitlementStateTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("EntitlementState")
struct EntitlementStateTests {
    @Test func mergeUsesUnionOfStoreKitAndWebsiteSources() {
        let appStoreOnly = EntitlementState(
            hasAppStoreEntitlement: true,
            appStoreTierName: "Annual",
            hasWebsiteEntitlement: false
        )
        #expect(appStoreOnly.isPro)
        #expect(appStoreOnly.sourceDescription == "App Store")
        #expect(appStoreOnly.settingsSubtitle == "Premium · Annual")

        let websiteOnly = EntitlementState(
            hasAppStoreEntitlement: false,
            appStoreTierName: nil,
            hasWebsiteEntitlement: true,
            websiteTierName: "Annual"
        )
        #expect(websiteOnly.isPro)
        #expect(websiteOnly.sourceDescription == "Website")
        #expect(websiteOnly.settingsSubtitle == "Premium · Annual · Website")

        let both = EntitlementState(
            hasAppStoreEntitlement: true,
            appStoreTierName: "Lifetime",
            hasWebsiteEntitlement: true
        )
        #expect(both.isPro)
        #expect(both.sourceDescription == "App Store + Website")
        #expect(both.settingsSubtitle == "Premium · App Store + Website")
    }

    @Test func mergeReportsFreeWhenNoSourceIsActive() {
        let state = EntitlementState(
            hasAppStoreEntitlement: false,
            appStoreTierName: nil,
            hasWebsiteEntitlement: false
        )

        #expect(!state.isPro)
        #expect(state.sourceDescription == nil)
        #expect(state.settingsSubtitle == "Free")
    }

    @Test func appStoreBackdoorSourcesUseTheirDisplayName() {
        let debug = EntitlementState(
            hasAppStoreEntitlement: true,
            appStoreTierName: "Debug",
            hasWebsiteEntitlement: false
        )
        let testFlight = EntitlementState(
            hasAppStoreEntitlement: true,
            appStoreTierName: "TestFlight",
            hasWebsiteEntitlement: false
        )

        #expect(debug.settingsSubtitle == "Premium · Debug")
        #expect(testFlight.settingsSubtitle == "Premium · TestFlight")
    }

    @Test func websitePlanNamesMatchAppPlanLanguage() {
        #expect(PremiumProduct.tierDisplayName(forWebsitePlan: "monthly") == "Monthly")
        #expect(PremiumProduct.tierDisplayName(forWebsitePlan: "yearly") == "Annual")
        #expect(PremiumProduct.tierDisplayName(forWebsitePlan: "lifetime") == "Lifetime")
        #expect(PremiumProduct.tierDisplayName(forWebsitePlan: "weekly") == nil)
    }
}
