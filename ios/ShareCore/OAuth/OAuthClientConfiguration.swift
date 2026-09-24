//
//  OAuthClientConfiguration.swift
//  ShareCore
//

import Foundation

public struct OAuthClientConfiguration: Equatable {
    public let clientID: String
    public let redirectURI: String

    public init(clientID: String, redirectURI: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    public static let directMac = OAuthClientConfiguration(
        clientID: "tlingo-mac",
        redirectURI: "tlingo-direct://oauth/callback"
    )

    public static var currentWebsiteRestore: OAuthClientConfiguration {
        if BuildEnvironment.isDirectDistribution {
            return directMac
        }
        #if os(iOS)
            return OAuthClientConfiguration(
                clientID: "tlingo-appstore-ios",
                redirectURI: "tlingo://oauth/callback"
            )
        #else
            return OAuthClientConfiguration(
                clientID: "tlingo-appstore-mac",
                redirectURI: "tlingo://oauth/callback"
            )
        #endif
    }
}
