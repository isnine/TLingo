//
//  OAuthTokenStore.swift
//  ShareCore
//
//  Keychain wrapper for the TLingo Mac OAuth activation tokens.
//  Stored under a separate service from `KeychainTokenStore` (Supabase
//  session) so the two coexist during the migration period.
//

import Foundation
import Security
import os

private let logger = os.Logger(
    subsystem: "com.zanderwang.AITranslator",
    category: "OAuthTokenStore"
)

public struct OAuthTokens: Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Absolute expiry (`now + expires_in`) of `accessToken`.
    public let accessExpiresAt: Date
    public let userID: String
    public let email: String
    public let plan: String?
    public let isPremium: Bool
    /// Absolute expiry of the current website membership, when applicable.
    public let entitlementExpiresAt: Date?
    public let activationDiagnostics: OAuthActivationDiagnostics?

    public init(
        accessToken: String,
        refreshToken: String,
        accessExpiresAt: Date,
        userID: String,
        email: String,
        plan: String?,
        isPremium: Bool,
        entitlementExpiresAt: Date? = nil,
        activationDiagnostics: OAuthActivationDiagnostics? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.userID = userID
        self.email = email
        self.plan = plan
        self.entitlementExpiresAt = entitlementExpiresAt
        self.isPremium = isPremium || entitlementExpiresAt.map { $0 > Date() } == true
        self.activationDiagnostics = activationDiagnostics
    }

    public var isAccessTokenExpired: Bool {
        Date() >= accessExpiresAt.addingTimeInterval(-30)
    }
}

func parseOAuthEntitlementDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

public enum OAuthTokenStore {
    private static let service = "com.zanderwang.AITranslator.OAuthTokens"
    private static let legacyAccount = "default"

    public static func save(_ tokens: OAuthTokens, clientID: String = OAuthClientConfiguration.currentWebsiteRestore.clientID) {
        guard let data = try? JSONEncoder().encode(tokens) else {
            logger.error("Failed to encode tokens for keychain")
            return
        }
        let query = keychainQuery(account: account(for: clientID))
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Keychain add failed: \(addStatus, privacy: .public)")
            }
        } else if updateStatus != errSecSuccess {
            logger.error("Keychain update failed: \(updateStatus, privacy: .public)")
        }
    }

    public static func load(clientID: String = OAuthClientConfiguration.currentWebsiteRestore.clientID) -> OAuthTokens? {
        if let tokens = load(account: account(for: clientID)) {
            return tokens
        }
        guard clientID == OAuthClientConfiguration.directMac.clientID,
              let legacy = load(account: legacyAccount)
        else {
            return nil
        }
        save(legacy, clientID: clientID)
        return legacy
    }

    private static func load(account: String) -> OAuthTokens? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public static func clear(clientID: String = OAuthClientConfiguration.currentWebsiteRestore.clientID) {
        let query = keychainQuery(account: account(for: clientID))
        SecItemDelete(query as CFDictionary)
        if clientID == OAuthClientConfiguration.directMac.clientID {
            let legacyQuery = keychainQuery(account: legacyAccount)
            SecItemDelete(legacyQuery as CFDictionary)
        }
    }

    private static func account(for clientID: String) -> String {
        "oauth.\(clientID)"
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
