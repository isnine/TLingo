//
//  EntitlementStateTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("EntitlementState")
struct EntitlementStateTests {
    @Test func appStoreEntitlementShowsTierName() {
        let state = EntitlementState(hasAppStoreEntitlement: true, appStoreTierName: "Annual")
        #expect(state.isPro)
        #expect(state.settingsSubtitle == "Premium · Annual")
    }

    @Test func reportsFreeWithoutEntitlement() {
        let state = EntitlementState(hasAppStoreEntitlement: false, appStoreTierName: nil)
        #expect(!state.isPro)
        #expect(state.settingsSubtitle == "Free")
    }

    @Test func appStoreBackdoorSourcesUseTheirDisplayName() {
        let debug = EntitlementState(hasAppStoreEntitlement: true, appStoreTierName: "Debug")
        let testFlight = EntitlementState(hasAppStoreEntitlement: true, appStoreTierName: "TestFlight")

        #expect(debug.settingsSubtitle == "Premium · Debug")
        #expect(testFlight.settingsSubtitle == "Premium · TestFlight")
    }
}
