//
//  OAuthClientConfigurationTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("OAuthClientConfiguration")
struct OAuthClientConfigurationTests {
    @Test func appStoreRestoreClientsUseTlingoCallbackScheme() {
        #if os(iOS)
            let config = OAuthClientConfiguration.currentWebsiteRestore
            #expect(config.clientID == "tlingo-appstore-ios")
            #expect(config.redirectURI == "tlingo://oauth/callback")
        #elseif os(macOS)
            let config = OAuthClientConfiguration.currentWebsiteRestore
            #expect(config.clientID == "tlingo-appstore-mac")
            #expect(config.redirectURI == "tlingo://oauth/callback")
        #endif
    }

    @Test func directClientKeepsDedicatedCallbackScheme() {
        let config = OAuthClientConfiguration.directMac
        #expect(config.clientID == "tlingo-mac")
        #expect(config.redirectURI == "tlingo-direct://oauth/callback")
    }
}
