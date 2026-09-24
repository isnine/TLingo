//
//  OAuthInstallIdentifier.swift
//  ShareCore
//

import Foundation

enum OAuthInstallIdentifier {
    private static let key = "oauth.install_id"

    static var current: String {
        if let existing = AppPreferences.sharedDefaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        AppPreferences.sharedDefaults.set(value, forKey: key)
        return value
    }
}
