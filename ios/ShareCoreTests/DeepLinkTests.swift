//
//  DeepLinkTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("Deep links")
struct DeepLinkTests {
    @Test func realtimeParserAcceptsRealtimeURL() throws {
        let url = try #require(URL(string: "tlingo://realtime"))

        #expect(DeepLink.isRealtimeURL(url))
    }

    @Test func realtimeParserRejectsTranslateAndOAuthURLs() throws {
        let translateURL = try #require(DeepLink.translateURL(text: "Hello"))
        let oauthURL = try #require(URL(string: "tlingo://oauth/callback"))

        #expect(!DeepLink.isRealtimeURL(translateURL))
        #expect(!DeepLink.isRealtimeURL(oauthURL))
    }
}
